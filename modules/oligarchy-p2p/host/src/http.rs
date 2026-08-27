//! The Nix binary cache protocol, as much of it as a substituter needs.
//!
//! Nix issues exactly two verbs against a binary cache — `HEAD` for existence
//! and `GET` for content (http-binary-cache-store.cc:117-224). It never sends
//! `Range`, never issues conditional requests, and never `PUT`s unless you are
//! copying *to* the cache, which we do not support. So the surface is small:
//! `nix-cache-info`, `<hashpart>.narinfo`, and the NAR body.
//!
//! Routing is done by hand in `dispatch` rather than through a router DSL. The
//! paths are three fixed shapes, one of which has a suffix inside a segment
//! (`.narinfo`) that router syntaxes handle differently across versions; a
//! `match` on the path is both shorter and version-proof.

use crate::cache::Cache;
use crate::decompress::Codec;
use crate::narinfo::NarInfo;
use crate::resolve::{self, Source};
use crate::route::{self, Route};
use crate::upstream::Upstream;
use crate::verify::Verifier;
use futures_util::StreamExt;
use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct AppState {
    pub upstream: Upstream,
    pub artifacts: std::sync::Arc<Cache>,
    pub store_dir: String,
    pub priority: u32,
    pub narinfo_timeout: Duration,
    pub cache_downloaded: bool,
    pub serve_from_store: bool,
    cache: Mutex<NarInfoCache>,
}

/// A deliberately crude bounded cache: Nix asks for a narinfo and then, moments
/// later, for its NAR, and re-fetching upstream in between doubles latency on
/// every single path. It is not a persistence layer and must not become one —
/// Stage 2's on-disk cache is where that belongs.
struct NarInfoCache {
    map: std::collections::HashMap<String, (Instant, Option<(String, NarInfo)>)>,
    ttl: Duration,
    cap: usize,
}

impl NarInfoCache {
    fn get(&mut self, k: &str) -> Option<Option<(String, NarInfo)>> {
        match self.map.get(k) {
            Some((t, v)) if t.elapsed() < self.ttl => Some(v.clone()),
            Some(_) => {
                self.map.remove(k);
                None
            }
            None => None,
        }
    }
    fn put(&mut self, k: String, v: Option<(String, NarInfo)>) {
        if self.map.len() >= self.cap {
            self.map.clear();
        }
        self.map.insert(k, (Instant::now(), v));
    }
}

impl AppState {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        upstream: Upstream,
        artifacts: Cache,
        store_dir: String,
        priority: u32,
        narinfo_timeout: Duration,
        cache_downloaded: bool,
        serve_from_store: bool,
    ) -> Self {
        Self {
            upstream,
            artifacts: std::sync::Arc::new(artifacts),
            store_dir,
            priority,
            narinfo_timeout,
            cache_downloaded,
            serve_from_store,
            cache: Mutex::new(NarInfoCache {
                map: Default::default(),
                // Short. A narinfo is immutable for a given store path, but a
                // *negative* answer is not, and caching those for long would
                // reproduce Nix's own hour-long negative TTL inside us.
                ttl: Duration::from_secs(60),
                cap: 4096,
            }),
        }
    }

    /// Resolve a hash part to `(upstream base, narinfo)`.
    ///
    /// Memory, then disk, then upstream. The **disk** layer is what makes the
    /// artifact cache usable when upstream is unreachable: a NAR request has to
    /// resolve its narinfo first, so without persisted metadata a fully
    /// populated cache answers 404 the moment the network goes away — which is
    /// precisely the case it exists for. That was observed, not theorised.
    ///
    /// The upstream base is empty for a disk hit. Nothing needs it unless we go
    /// on to fetch the body, and if we do, that fetch re-resolves.
    async fn resolve(&self, hash_part: &str) -> anyhow::Result<Option<(String, NarInfo)>> {
        if let Some(hit) = self.cache.lock().unwrap().get(hash_part) {
            return Ok(hit);
        }
        if let Some(text) = self.artifacts.get_narinfo(hash_part) {
            match NarInfo::parse(&text) {
                Ok(ni) => {
                    let found = Some((String::new(), ni));
                    self.cache.lock().unwrap().put(hash_part.to_string(), found.clone());
                    return Ok(found);
                }
                Err(e) => {
                    tracing::warn!(hash_part, error = %e, "unparseable cached narinfo; refetching");
                }
            }
        }

        let rel = format!("{hash_part}.narinfo");
        let found = match self.upstream.get_text(&rel, self.narinfo_timeout).await? {
            None => None,
            Some((base, text)) => {
                let ni = NarInfo::parse(&text)?;
                // Persist upstream's narinfo verbatim, signatures and all.
                if let Err(e) = self.artifacts.put_narinfo(hash_part, &text) {
                    tracing::warn!(hash_part, error = %e, "could not persist narinfo");
                }
                Some((base, ni))
            }
        };
        // Negative answers stay in memory only. Upstream may gain the path, and
        // a 404 written to disk would outlive the reason for it.
        self.cache.lock().unwrap().put(hash_part.to_string(), found.clone());
        Ok(found)
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
    match route::parse(uri.path()) {
        Some(Route::CacheInfo) => cache_info(&st, head_only),
        Some(Route::NarInfo { hash_part }) => narinfo(&st, &hash_part, head_only).await,
        Some(Route::Nar { hash_part, name }) => nar(&st, &hash_part, &name, head_only).await,
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

fn text(body: &str, ctype: &str, head_only: bool) -> Response {
    let mut h = HeaderMap::new();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_str(ctype).unwrap());
    h.insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    if head_only {
        (StatusCode::OK, h).into_response()
    } else {
        (StatusCode::OK, h, body.to_string()).into_response()
    }
}

fn cache_info(st: &AppState, head_only: bool) -> Response {
    // `StoreDir` must match the local store or Nix refuses the cache outright.
    // `WantMassQuery` lets Nix bulk-query us the way it does cache.nixos.org.
    // `Priority` is how we get consulted before upstream: lower wins, and
    // cache.nixos.org publishes 40.
    let body = format!(
        "StoreDir: {}\nWantMassQuery: 1\nPriority: {}\n",
        st.store_dir, st.priority
    );
    text(&body, "text/x-nix-cache-info", head_only)
}

async fn narinfo(st: &AppState, hash_part: &str, head_only: bool) -> Response {
    match st.resolve(hash_part).await {
        Err(e) => {
            // Fail closed. A 404 sends Nix to the next substituter; a 500 or a
            // half-truth would make an adapter bug look like a missing path.
            tracing::warn!(hash_part, error = %e, "narinfo lookup failed; answering 404");
            StatusCode::NOT_FOUND.into_response()
        }
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Ok(Some((_base, ni))) => {
            // We can only promise the canonical uncompressed NAR if we can
            // decode what upstream holds. Refusing here — rather than at the
            // NAR fetch, after Nix has committed to us — costs one round trip
            // and sends Nix to the next substituter cleanly.
            if let Err(e) = Codec::parse(ni.compression()) {
                tracing::warn!(hash_part, error = %e, "cannot canonicalise; declining the path");
                return StatusCode::NOT_FOUND.into_response();
            }
            let Ok(nar_size) = ni.nar_size() else {
                return StatusCode::NOT_FOUND.into_response();
            };

            tracing::debug!(hash_part, sigs = ni.get_all("Sig").len(), "serving narinfo");
            let mut out = ni.clone();
            // The canonicalisation. Every transport field we emit is now a
            // function of NarHash and NarSize — both SIGNED, both immutable for
            // a given store path — so this narinfo stays true for as long as
            // Nix caches it, no matter what upstream does to its compression.
            out.rewrite_transport(
                route::nar_url(&ni),
                Some("none"),
                Some(ni.nar_hash()),
                Some(nar_size),
            );
            text(&out.to_text(), "text/x-nix-narinfo", head_only)
        }
    }
}

async fn nar(st: &AppState, hash_part: &str, name: &str, head_only: bool) -> Response {
    let (base, ni) = match st.resolve(hash_part).await {
        Err(e) => {
            tracing::warn!(hash_part, error = %e, "nar lookup failed; answering 404");
            return StatusCode::NOT_FOUND.into_response();
        }
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Ok(Some(v)) => v,
    };

    // Re-derive the name and compare. This is what stops the route being an
    // open proxy: the only NAR reachable through `/nar/<hp>/<name>` is the one
    // this hash part's own narinfo points at.
    let expected = route::nar_url(&ni);
    if expected != format!("nar/{hash_part}/{name}") {
        tracing::warn!(hash_part, name, expected, "NAR name does not match the narinfo");
        return StatusCode::NOT_FOUND.into_response();
    }

    // We serve the canonical uncompressed NAR, so what describes the bytes on
    // our wire is NarHash/NarSize — the pair the upstream signature covers. No
    // unsigned field is anywhere in the trust path.
    let digest = ni.nar_hash();
    let len = match ni.nar_size() {
        Ok(l) => l,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
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

    // ── Sources 1 and 2: local, verified IN FULL before a byte goes out ─────
    if let Some((source, path)) =
        resolve::local(&st.artifacts, &ni, &st.store_dir, st.serve_from_store)
    {
        match tokio::fs::File::open(&path).await {
            Ok(f) => {
                // INFO, not DEBUG. Which source answered is the single most
                // useful operational fact this daemon produces — it is how you
                // tell a working cache from an expensive proxy — and a line per
                // substituted path is not noise.
                tracing::info!(hash_part, source = source.as_str(), bytes = len, "serving verified");
                let body = Body::from_stream(tokio_util::io::ReaderStream::new(f));
                return (StatusCode::OK, h, body).into_response();
            }
            Err(e) => {
                // Verified a moment ago and now unopenable — concurrent
                // eviction, most likely. Fall through rather than 500.
                tracing::warn!(error = %e, "verified artifact vanished; falling through");
            }
        }
    }

    // ── Source 3: upstream, streamed with lookahead and teed into the cache ─
    let codec = match Codec::parse(ni.compression()) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(hash_part, error = %e, "cannot decode upstream compression");
            return StatusCode::NOT_FOUND.into_response();
        }
    };

    // A narinfo resolved from disk carries no upstream base. Recover one: any
    // configured upstream can serve the body, and `ni.url()` may be absolute
    // anyway.
    let base = if base.is_empty() {
        match st.upstream.first_base() {
            Some(b) => b,
            None => return StatusCode::NOT_FOUND.into_response(),
        }
    } else {
        base
    };

    let body = match st.upstream.get_stream(&base, ni.url()).await {
        Err(e) => {
            tracing::warn!(hash_part, error = %e, "upstream NAR fetch failed");
            return StatusCode::NOT_FOUND.into_response();
        }
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Ok(Some(b)) => b,
    };

    let slot = if st.cache_downloaded {
        match st.artifacts.slot(&digest) {
            Ok(s) => Some(s),
            Err(e) => {
                tracing::warn!(error = %e, "cannot reserve a cache slot; serving uncached");
                None
            }
        }
    } else {
        None
    };

    tracing::info!(
        hash_part,
        source = Source::Upstream.as_str(),
        compression = ni.compression(),
        compressed = ni.file_size().unwrap_or(0),
        uncompressed = len,
        "streaming from upstream"
    );

    let verifier = Verifier::new(digest, len, body.source.clone());
    let inner = body.stream.map(|r| r.map_err(std::io::Error::other));
    let stream =
        resolve::upstream_stream(Box::pin(inner), codec, verifier, slot, Some(st.artifacts.clone()));

    (StatusCode::OK, h, Body::from_stream(stream)).into_response()
}
