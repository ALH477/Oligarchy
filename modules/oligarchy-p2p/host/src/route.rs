//! The URL space we hand to Nix, and how a NAR request finds its narinfo again.
//!
//! The adapter is stateless across requests by construction. Nix fetches a
//! narinfo, then some time later fetches the NAR named by that narinfo's `URL`
//! field — possibly after the daemon has restarted. Rather than remember the
//! mapping, we **encode it in the URL**: the store path's hash part is a path
//! segment, so the NAR handler can re-resolve the narinfo from scratch.
//!
//! The second segment is not decoration. It is re-derived from the freshly
//! fetched narinfo and compared against what was requested, so this route
//! cannot be used to make the adapter fetch an arbitrary upstream URL. Without
//! that check the daemon would be an open proxy bound to loopback — which is
//! less bad than an open proxy on the LAN, and still not something to ship.

use crate::narinfo::NarInfo;

/// File extension a cache uses for a given `Compression` value. Nix picks the
/// decompressor from `Compression`, never from the extension.
///
/// No longer used for our own URLs — see `nar_url` for why that was a mistake —
/// but kept because it is how an upstream URL is recognised in a log line.
#[allow(dead_code)]
pub fn compression_suffix(compression: &str) -> &'static str {
    match compression {
        "none" => "",
        "xz" => ".xz",
        "bzip2" => ".bz2",
        "br" => ".br",
        "zstd" => ".zst",
        "gzip" => ".gz",
        // An unknown compression is passed through untouched upstream, so the
        // name just needs to not collide.
        _ => ".bin",
    }
}

/// The `URL:` value we put in a narinfo we re-emit.
///
/// Keyed on **`NarHash`**, with no compression suffix, because both halves must
/// be functions of data the upstream signature covers.
///
/// Stage 1 keyed this on `FileHash` plus the compression suffix, and that was a
/// real bug rather than a stylistic choice. Both describe upstream's
/// *compressed* bytes, which upstream may change at any time — cache.nixos.org
/// moved `hello` from xz to zstd during development. Nix caches a narinfo for
/// `narinfo-cache-positive-ttl`, thirty days, so after such a change every
/// cached narinfo named a NAR this adapter would refuse to serve, and it 404'd
/// until the TTL expired.
///
/// `NarHash` is immutable for a given store path. Since stage 2 serves the
/// canonical uncompressed NAR, this URL is now stable forever.
pub fn nar_url(ni: &NarInfo) -> String {
    format!("nar/{}/{}.nar", ni.hash_part(), ni.nar_hash().to_nix32())
}

/// What a request path decomposed into, or `None` if it is not ours.
#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    CacheInfo,
    NarInfo { hash_part: String },
    Nar { hash_part: String, name: String },
}

/// A store path hash part is 32 characters of Nix base32.
fn is_hash_part(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|c| b"0123456789abcdfghijklmnpqrsvwxyz".contains(&c))
}

pub fn parse(path: &str) -> Option<Route> {
    let p = path.strip_prefix('/').unwrap_or(path);
    if p == "nix-cache-info" {
        return Some(Route::CacheInfo);
    }
    if let Some(stem) = p.strip_suffix(".narinfo") {
        return is_hash_part(stem).then(|| Route::NarInfo {
            hash_part: stem.to_string(),
        });
    }
    if let Some(rest) = p.strip_prefix("nar/") {
        let (hp, name) = rest.split_once('/')?;
        // No traversal, no nesting: the name is one opaque segment that we are
        // about to re-derive and compare anyway.
        if !is_hash_part(hp) || name.is_empty() || name.contains('/') || name.contains("..") {
            return None;
        }
        return Some(Route::Nar {
            hash_part: hp.to_string(),
            name: name.to_string(),
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const HP: &str = "lcxc2z1h2g8wq8dxfpizy1di85kyxnqx";

    const HELLO: &str = "\
StorePath: /nix/store/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-hello-2.12.3
URL: nar/174fba8vinrah6iyhp92kmz7r5kx6habnc4qb1rs0657sx224zvn.nar.xz
Compression: xz
FileHash: sha256:174fba8vinrah6iyhp92kmz7r5kx6habnc4qb1rs0657sx224zvn
FileSize: 58484
NarHash: sha256:1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2
NarSize: 279624
References: lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-hello-2.12.3
";

    #[test]
    fn the_nar_url_carries_its_own_hash_part() {
        // This is what makes the daemon stateless across a restart: a NAR
        // request re-resolves its narinfo instead of consulting memory.
        let ni = NarInfo::parse(HELLO).unwrap();
        let url = nar_url(&ni);
        assert_eq!(
            url,
            "nar/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx/1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2.nar"
        );
        assert_eq!(
            parse(&format!("/{url}")),
            Some(Route::Nar {
                hash_part: HP.into(),
                name: "1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2.nar".into()
            })
        );
    }

    #[test]
    fn the_nar_url_does_not_move_when_upstream_recompresses() {
        // THE regression test for stage 1's bug. cache.nixos.org really did
        // switch this path from xz to zstd mid-development; a URL derived from
        // FileHash or the compression suffix changes underneath Nix's 30-day
        // narinfo cache and the adapter 404s until it expires.
        let xz = NarInfo::parse(HELLO).unwrap();
        let zstd = NarInfo::parse(
            &HELLO
                .replace("Compression: xz", "Compression: zstd")
                .replace(
                    "FileHash: sha256:174fba8vinrah6iyhp92kmz7r5kx6habnc4qb1rs0657sx224zvn",
                    "FileHash: sha256:12w6fp8y5haw9w1wznyfrk884ldm85ccf6b40psiih0yzg8a4l58",
                )
                .replace("FileSize: 58484", "FileSize: 75355"),
        )
        .unwrap();
        assert_eq!(nar_url(&xz), nar_url(&zstd));
    }

    #[test]
    fn nar_url_is_a_pure_function_of_the_narinfo() {
        // Two independently parsed copies must agree, or a daemon restart
        // between the narinfo and the NAR fetch produces a 404.
        let a = nar_url(&NarInfo::parse(HELLO).unwrap());
        let b = nar_url(&NarInfo::parse(HELLO).unwrap());
        assert_eq!(a, b);
    }

    #[test]
    fn routes_we_serve() {
        assert_eq!(parse("/nix-cache-info"), Some(Route::CacheInfo));
        assert_eq!(
            parse(&format!("/{HP}.narinfo")),
            Some(Route::NarInfo { hash_part: HP.into() })
        );
    }

    #[test]
    fn refuses_traversal_and_junk() {
        // The name segment reaches a comparison, never a filesystem or a URL
        // join, but these are refused at the door regardless.
        for bad in [
            "/nar/../../etc/passwd",
            "/nar/short/x.nar",
            &format!("/nar/{HP}/sub/dir.nar"),
            &format!("/nar/{HP}/"),
            "/",
            "/index.html",
            "/notahash.narinfo",
            // 'e', 'o', 't', 'u' are not in Nix's base32 alphabet.
            "/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.narinfo",
        ] {
            assert_eq!(parse(bad), None, "accepted {bad}");
        }
    }

    #[test]
    fn compression_suffixes_are_stable() {
        assert_eq!(compression_suffix("none"), "");
        assert_eq!(compression_suffix("xz"), ".xz");
        assert_eq!(compression_suffix("zstd"), ".zst");
    }
}
