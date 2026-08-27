//! The peer surface: what other Oligarchy hosts on the LAN may ask of us.
//!
//! A **second, separate listener** from the substituter surface, and the
//! separation is the point. The substituter surface is loopback-only and will
//! proxy anything its upstreams hold; exposing that to a network would publish
//! an open cache proxy for the whole of cache.nixos.org. The peer surface binds
//! a real interface and therefore answers a deliberately smaller question:
//! *do you already have this, and may I have a copy?*
//!
//! Three rules, all of which exist so that this cannot become the other thing:
//!
//! 1. **Local sources only.** A peer request never triggers an upstream fetch.
//!    If we do not already hold the artifact, the answer is 404 — not "hold on
//!    while I get it". Otherwise one peer asking for a path it invented turns
//!    this host into a proxy.
//! 2. **No narinfo we did not get from upstream.** We serve back exactly what
//!    upstream signed, so a peer receives something Nix can verify. We do not
//!    mint metadata.
//! 3. **Everything it serves is verified first**, by the same funnel the
//!    substituter surface uses. We do not hand a neighbour bytes we have not
//!    checked, even though they will check them too.

use crate::http::AppState;
use crate::resolve;
use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use std::sync::Arc;

/// Routes on the peer surface. Versioned from the start: this is a wire
/// protocol between machines that will not upgrade in lockstep.
#[derive(Debug, PartialEq, Eq)]
pub enum PeerRoute {
    Info,
    Have { hash_part: String, nar_hash: String },
    NarInfo { hash_part: String },
    Nar { hash_part: String, nar_hash: String },
    /// The canonical `.torrent` for an artifact we hold. A peer cannot derive
    /// an infohash from a `NarHash` without already having the file, so
    /// whoever has it has to publish the mapping.
    Torrent { hash_part: String, nar_hash: String },
}

fn is_hash_part(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|c| b"0123456789abcdfghijklmnpqrsvwxyz".contains(&c))
}

fn is_nar_hash(s: &str) -> bool {
    s.len() == 52 && s.bytes().all(|c| b"0123456789abcdfghijklmnpqrsvwxyz".contains(&c))
}

pub fn parse(path: &str) -> Option<PeerRoute> {
    let p = path.strip_prefix('/').unwrap_or(path);
    let rest = p.strip_prefix("peer/v1/")?;
    let parts: Vec<&str> = rest.split('/').collect();
    match parts.as_slice() {
        ["info"] => Some(PeerRoute::Info),
        ["narinfo", hp] if is_hash_part(hp) => Some(PeerRoute::NarInfo {
            hash_part: (*hp).to_string(),
        }),
        ["have", hp, nh] if is_hash_part(hp) && is_nar_hash(nh) => Some(PeerRoute::Have {
            hash_part: (*hp).to_string(),
            nar_hash: (*nh).to_string(),
        }),
        ["nar", hp, nh] if is_hash_part(hp) && is_nar_hash(nh) => Some(PeerRoute::Nar {
            hash_part: (*hp).to_string(),
            nar_hash: (*nh).to_string(),
        }),
        ["torrent", hp, nh] if is_hash_part(hp) && is_nar_hash(nh) => Some(PeerRoute::Torrent {
            hash_part: (*hp).to_string(),
            nar_hash: (*nh).to_string(),
        }),
        _ => None,
    }
}

pub fn router(state: Arc<AppState>) -> axum::Router {
    axum::Router::new().fallback(dispatch).with_state(state)
}

async fn dispatch(State(st): State<Arc<AppState>>, method: Method, uri: Uri) -> Response {
    let head_only = method == Method::HEAD;
    if !(method == Method::GET || head_only) {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    match parse(uri.path()) {
        Some(PeerRoute::Info) => info(&st),
        Some(PeerRoute::NarInfo { hash_part }) => narinfo(&st, &hash_part).await,
        Some(PeerRoute::Have { hash_part, nar_hash }) => have(&st, &hash_part, &nar_hash).await,
        Some(PeerRoute::Nar { hash_part, nar_hash }) => {
            nar(&st, &hash_part, &nar_hash, head_only).await
        }
        Some(PeerRoute::Torrent { hash_part, nar_hash }) => {
            torrent(&st, &hash_part, &nar_hash).await
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

fn info(st: &AppState) -> Response {
    // `swarm_port` is how a peer learns where to dial for BitTorrent. Absent
    // (null) when no swarm is configured, which is the default — a peer that
    // does not advertise one is simply not dialled.
    let body = format!(
        "{{\"impl\":\"oligarchy-p2pd\",\"version\":\"{}\",\"artifacts\":{},\"swarm_port\":{}}}\n",
        env!("CARGO_PKG_VERSION"),
        st.artifacts.total_bytes().unwrap_or(0),
        match st.swarm_port {
            Some(p) => p.to_string(),
            None => "null".into(),
        }
    );
    let mut h = HeaderMap::new();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    (StatusCode::OK, h, body).into_response()
}

/// Serve upstream's narinfo verbatim, but **only from what we already hold**.
///
/// Rule 1: `AppState::resolve` would happily go upstream. A peer must not be
/// able to drive that, so this reads the on-disk copy directly.
async fn narinfo(st: &AppState, hash_part: &str) -> Response {
    match st.artifacts.get_narinfo(hash_part) {
        None => StatusCode::NOT_FOUND.into_response(),
        Some(text) => {
            let mut h = HeaderMap::new();
            h.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/x-nix-narinfo"),
            );
            (StatusCode::OK, h, text).into_response()
        }
    }
}

/// Cheap availability check: no body, no verification, no fetch.
///
/// Deliberately answers from metadata plus an existence check rather than by
/// hashing: `discover` is on the latency path for every substitution, and a
/// peer that says yes and then fails verification costs one retry, which is the
/// designed-for case anyway.
async fn have(st: &AppState, hash_part: &str, nar_hash: &str) -> Response {
    let Some(text) = st.artifacts.get_narinfo(hash_part) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Ok(ni) = crate::narinfo::NarInfo::parse(&text) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if ni.nar_hash().to_nix32() != nar_hash {
        return StatusCode::NOT_FOUND.into_response();
    }
    let holds_it = st.artifacts.get(&ni.nar_hash(), ni.nar_size().unwrap_or(0)).is_some()
        || (st.serve_from_store
            && crate::nixstore::is_dumpable(&st.store_dir, ni.store_path())
            && std::path::Path::new(ni.store_path()).exists());
    if holds_it {
        StatusCode::OK.into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

/// Hand over the canonical NAR — verified, and only from local sources.
async fn nar(st: &AppState, hash_part: &str, nar_hash: &str, head_only: bool) -> Response {
    let Some(text) = st.artifacts.get_narinfo(hash_part) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Ok(ni) = crate::narinfo::NarInfo::parse(&text) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // The requested digest must be the one this narinfo names. Otherwise a peer
    // could ask for hash part A while naming digest B and get whatever A holds
    // labelled as B.
    if ni.nar_hash().to_nix32() != nar_hash {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(len) = ni.nar_size() else {
        return StatusCode::NOT_FOUND.into_response();
    };

    // Rule 1 again, and this is the load-bearing line of the whole module: only
    // `local`. Never the upstream path.
    let Some((source, path)) = resolve::local(&st.artifacts, &ni, &st.store_dir, st.serve_from_store)
    else {
        return StatusCode::NOT_FOUND.into_response();
    };

    let mut h = HeaderMap::new();
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-nix-nar"),
    );
    h.insert(header::CONTENT_LENGTH, HeaderValue::from(len));
    if head_only {
        return (StatusCode::OK, h).into_response();
    }
    match tokio::fs::File::open(&path).await {
        Ok(f) => {
            tracing::info!(hash_part, source = source.as_str(), bytes = len, "serving a peer");
            (
                StatusCode::OK,
                h,
                Body::from_stream(tokio_util::io::ReaderStream::new(f)),
            )
                .into_response()
        }
        Err(e) => {
            tracing::warn!(error = %e, "verified artifact vanished before serving a peer");
            StatusCode::NOT_FOUND.into_response()
        }
    }
}

/// Hand over the canonical `.torrent`, built on demand from a verified local
/// copy. Same rule as every other route here: local sources only.
async fn torrent(st: &AppState, hash_part: &str, nar_hash: &str) -> Response {
    let Some(text) = st.artifacts.get_narinfo(hash_part) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Ok(ni) = crate::narinfo::NarInfo::parse(&text) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if ni.nar_hash().to_nix32() != nar_hash {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(len) = ni.nar_size() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some((_source, path)) =
        resolve::local(&st.artifacts, &ni, &st.store_dir, st.serve_from_store)
    else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match crate::torrent::build(&path, &ni.nar_hash(), len).await {
        Ok(bytes) => {
            let mut h = HeaderMap::new();
            h.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/x-bittorrent"),
            );
            (StatusCode::OK, h, bytes).into_response()
        }
        Err(e) => {
            tracing::warn!(hash_part, error = %e, "could not build a torrent");
            StatusCode::NOT_FOUND.into_response()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HP: &str = "lcxc2z1h2g8wq8dxfpizy1di85kyxnqx";
    const NH: &str = "1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2";

    #[test]
    fn routes_we_answer() {
        assert_eq!(parse("/peer/v1/info"), Some(PeerRoute::Info));
        assert_eq!(
            parse(&format!("/peer/v1/narinfo/{HP}")),
            Some(PeerRoute::NarInfo { hash_part: HP.into() })
        );
        assert_eq!(
            parse(&format!("/peer/v1/have/{HP}/{NH}")),
            Some(PeerRoute::Have { hash_part: HP.into(), nar_hash: NH.into() })
        );
        assert_eq!(
            parse(&format!("/peer/v1/nar/{HP}/{NH}")),
            Some(PeerRoute::Nar { hash_part: HP.into(), nar_hash: NH.into() })
        );
    }

    #[test]
    fn the_torrent_route_parses() {
        assert_eq!(
            parse(&format!("/peer/v1/torrent/{HP}/{NH}")),
            Some(PeerRoute::Torrent { hash_part: HP.into(), nar_hash: NH.into() })
        );
    }

    #[test]
    fn the_substituter_routes_are_not_reachable_from_a_peer() {
        // The two surfaces are separate listeners AND separate route sets. A
        // peer that finds the wrong port must still not be able to drive the
        // proxying surface.
        for p in [
            "/nix-cache-info",
            &format!("/{HP}.narinfo"),
            &format!("/nar/{HP}/{NH}.nar"),
        ] {
            assert_eq!(parse(p), None, "peer surface accepted {p}");
        }
    }

    #[test]
    fn refuses_malformed_and_traversing_paths() {
        for bad in [
            "/peer/v1/nar/../../etc/passwd",
            &format!("/peer/v1/nar/{HP}"),
            &format!("/peer/v1/nar/{HP}/short"),
            &format!("/peer/v1/narinfo/{NH}"),
            "/peer/v2/info",
            "/peer/v1/",
            "/",
        ] {
            assert_eq!(parse(bad), None, "accepted {bad}");
        }
    }
}
