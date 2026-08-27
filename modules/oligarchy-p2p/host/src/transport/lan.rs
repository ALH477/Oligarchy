//! The LAN transport: other Oligarchy hosts, reachable directly.
//!
//! Deliberately the least clever thing that works — plain HTTP against each
//! peer's peer-surface. No swarm, no piece scheduling, no DHT. For the case
//! this is actually for (a handful of machines on one network, one of which
//! just rebuilt) a swarm buys nothing that a direct copy does not.
//!
//! **Peer addresses are restricted to private ranges**, and that is a security
//! control rather than a convenience. Oligarchy's egress firewall
//! (`modules/security/strict-egress.nix`) puts RFC1918, CGNAT/tailnet and
//! link-local in its *static* allow set and drops everything else, so a LAN
//! transport needs no firewall change at all. Accepting a routable peer address
//! would quietly step outside that — and it would be an easy thing for a
//! malicious index to suggest later — so the check is here, in code, not left
//! to the firewall to catch.

use super::{ArtifactRef, ArtifactTransport, PeerRef, TransportStatus};
use crate::cache::Slot;
use crate::verify::Verifier;
use anyhow::{bail, Context, Result};
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::time::Duration;

/// Is this an address a LAN peer may legitimately have?
///
/// Mirrors `privateNets4`/`privateNets6` in strict-egress.nix. Loopback is
/// allowed so a single host can be tested against itself.
pub fn is_lan_address(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_private()          // 10/8, 172.16/12, 192.168/16
                || v4.is_loopback()
                || v4.is_link_local() // 169.254/16
                // 100.64/10, RFC 6598 — CGNAT, and where tailscale lives.
                || (v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]))
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || (v6.segments()[0] & 0xfe00) == 0xfc00 // fc00::/7 ULA
                || (v6.segments()[0] & 0xffc0) == 0xfe80 // fe80::/10 link-local
        }
    }
}

pub struct LanTransport {
    peers: Vec<SocketAddr>,
    client: ureq_like::Client,
    /// What a peer key may vouch for. Applied here, in the loop, rather than
    /// only by the caller — see `narinfo`.
    scope: crate::scope::PeerScope,
}

impl LanTransport {
    /// Build from configured peers, dropping any that are not LAN-local.
    ///
    /// Dropping rather than failing: a peer list is operational data that can
    /// drift, and refusing to start because one entry went public would take
    /// the substituter down over a transport that is meant to be optional.
    pub fn new(
        peers: &[String],
        connect_timeout: Duration,
        scope: crate::scope::PeerScope,
    ) -> Result<Self> {
        let mut ok = Vec::new();
        for p in peers {
            let addr: SocketAddr = p
                .parse()
                .with_context(|| format!("peer {p:?} is not an ip:port"))?;
            if !is_lan_address(&addr.ip()) {
                tracing::error!(
                    peer = %addr,
                    "REFUSED a peer outside the private address ranges; \
                     the LAN transport does not leave the local network"
                );
                continue;
            }
            ok.push(addr);
        }
        Ok(Self {
            peers: ok,
            client: ureq_like::Client::new(connect_timeout),
            scope,
        })
    }

}

impl LanTransport {
    /// A peer's BitTorrent port, from its `/peer/v1/info`.
    ///
    /// Queried rather than configured: the swarm port is the peer's business,
    /// and requiring the operator to keep two ports in sync per peer is the
    /// kind of configuration that goes wrong quietly. A peer that advertises
    /// none is simply not dialled.
    pub fn swarm_port(&self, peer: &SocketAddr) -> Option<u16> {
        let text = self
            .client
            .get_text(
                &format!("http://{peer}/peer/v1/info"),
                Duration::from_secs(5),
                64 * 1024,
            )
            .ok()??;
        // Deliberately not a JSON dependency for one integer.
        let after = text.split("\"swarm_port\":").nth(1)?;
        let digits: String = after
            .trim_start()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        digits.parse().ok()
    }

    /// The canonical `.torrent` for an artifact, from the first peer that has
    /// one. Untrusted: its piece hashes are only as good as the peer, which is
    /// why the completed download is hashed against the signed `NarHash`.
    pub fn torrent_for(
        &self,
        art: &ArtifactRef,
        peers: &[PeerRef],
        deadline: Duration,
    ) -> Option<Vec<u8>> {
        for p in peers {
            let url = format!(
                "http://{}/peer/v1/torrent/{}/{}",
                p.address,
                art.hash_part,
                art.nar_hash.to_nix32()
            );
            match self.client.get_bytes(&url, deadline, 16 * 1024 * 1024) {
                Ok(Some(b)) if !b.is_empty() => return Some(b),
                Ok(_) => {}
                Err(e) => tracing::debug!(peer = %p.address, error = %e, "no torrent from peer"),
            }
        }
        None
    }
}

impl ArtifactTransport for LanTransport {
    fn name(&self) -> &'static str {
        "lan"
    }

    fn discover(&self, art: &ArtifactRef, deadline: Duration) -> Vec<PeerRef> {
        let mut found = Vec::new();
        for p in &self.peers {
            let url = format!(
                "http://{p}/peer/v1/have/{}/{}",
                art.hash_part,
                art.nar_hash.to_nix32()
            );
            match self.client.head_ok(&url, deadline) {
                Ok(true) => found.push(PeerRef {
                    transport: "lan",
                    address: p.to_string(),
                }),
                Ok(false) => {}
                Err(e) => tracing::debug!(peer = %p, error = %e, "peer unreachable"),
            }
        }
        found
    }

    fn fetch(
        &self,
        art: &ArtifactRef,
        peers: &[PeerRef],
        slot: Slot,
        deadline: Duration,
    ) -> Result<PathBuf> {
        let mut last = None;
        for peer in peers {
            let url = format!(
                "http://{}/peer/v1/nar/{}/{}",
                peer.address,
                art.hash_part,
                art.nar_hash.to_nix32()
            );
            match self.fetch_one(&url, art, slot.temp_path(), deadline) {
                Ok(()) => {
                    let p = slot.commit()?;
                    tracing::info!(peer = %peer.address, path = %p.display(), "fetched from a peer");
                    return Ok(p);
                }
                Err(e) => {
                    // A peer that fails verification is a peer that wasted our
                    // time, not a security event: the bytes never got a name.
                    tracing::warn!(peer = %peer.address, error = %e, "peer fetch failed");
                    last = Some(e);
                }
            }
        }
        bail!(
            "no peer supplied {}: {}",
            art.nar_hash.to_nix32(),
            last.map(|e| e.to_string()).unwrap_or_else(|| "no peers".into())
        )
    }

    fn narinfo(&self, hash_part: &str, deadline: Duration) -> Option<String> {
        for p in &self.peers {
            let url = format!("http://{p}/peer/v1/narinfo/{hash_part}");
            match self.client.get_text(&url, deadline, 1 << 20) {
                Ok(Some(text)) => {
                    // A peer supplies metadata, so two things are re-checked
                    // before it is handed on: that it names the path that was
                    // asked for, and that a peer key is not vouching for
                    // something outside the scope its operator granted. The
                    // signature itself is Nix's problem and is untouched — we
                    // never verify one, only notice whose name is on it.
                    match crate::narinfo::NarInfo::parse(&text) {
                        Ok(ni) if ni.hash_part() != hash_part => tracing::warn!(
                            peer = %p,
                            asked = hash_part,
                            got = ni.hash_part(),
                            "REFUSED a peer narinfo for a different store path"
                        ),
                        // The scope check belongs HERE, in the loop, and not
                        // only in the caller. This returns the FIRST parseable
                        // answer and stops. If the caller refused it
                        // afterwards, one hostile peer could answer every query
                        // with an out-of-scope narinfo and the honest peers
                        // further down this list would never be asked — a
                        // remotely triggerable denial of service against any
                        // path it chose. Refusing here keeps looking.
                        Ok(ni) if self.scope.check(&ni).is_err() => {
                            crate::scope::warn_refusal(&p.to_string(), hash_part, ni.store_path());
                        }
                        Ok(_) => return Some(text),
                        Err(e) => tracing::warn!(peer = %p, error = %e, "unparseable peer narinfo"),
                    }
                }
                Ok(None) => {}
                Err(e) => tracing::debug!(peer = %p, error = %e, "peer narinfo unreachable"),
            }
        }
        None
    }

    fn status(&self) -> TransportStatus {
        TransportStatus {
            name: "lan".into(),
            peers_known: self.peers.len(),
            peers_reachable: self
                .peers
                .iter()
                .filter(|p| {
                    self.client
                        .head_ok(&format!("http://{p}/peer/v1/info"), Duration::from_secs(2))
                        .unwrap_or(false)
                })
                .count(),
            detail: self
                .peers
                .iter()
                .map(|p| p.to_string())
                .collect::<Vec<_>>()
                .join(", "),
        }
    }
}

impl LanTransport {
    /// Download one artifact, verifying as it arrives, into a temp file.
    ///
    /// Fully verified before the caller commits, so a peer's bytes never reach
    /// Nix — or another peer — under a name unless they matched the signed
    /// hash. This is the stronger guarantee the upstream path cannot afford.
    fn fetch_one(
        &self,
        url: &str,
        art: &ArtifactRef,
        tmp: &std::path::Path,
        deadline: Duration,
    ) -> Result<()> {
        let mut body = self
            .client
            .get_stream(url, deadline)?
            .with_context(|| format!("{url}: not found"))?;
        let mut verifier = Verifier::new(art.nar_hash, art.nar_size, url.to_string());
        let mut f = std::fs::File::create(tmp)?;
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            let n = body.read(&mut buf)?;
            if n == 0 {
                break;
            }
            verifier.update(&buf[..n])?;
            f.write_all(&buf[..n])?;
        }
        f.flush()?;
        verifier.finish()?;
        Ok(())
    }
}

/// A blocking HTTP/1.1 client, hand-rolled.
///
/// `reqwest` is already in the tree, but it is async and this transport is
/// blocking by design (see `transport::mod`). Pulling in `reqwest/blocking`
/// means a second nested runtime; the peer protocol is four routes over plain
/// HTTP on a LAN, so a few dozen lines of `TcpStream` is the smaller thing to
/// own. No TLS, deliberately: peers are private-range only and the payload is
/// verified against a signed hash regardless.
pub(crate) mod ureq_like {
    use anyhow::{bail, Context, Result};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{SocketAddr, TcpStream};
    use std::time::Duration;

    pub struct Client {
        connect_timeout: Duration,
    }

    pub struct Body {
        inner: Box<dyn Read + Send>,
    }

    impl Read for Body {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            self.inner.read(buf)
        }
    }

    struct Parts {
        status: u16,
        content_length: Option<u64>,
        reader: BufReader<TcpStream>,
    }

    impl Client {
        pub fn new(connect_timeout: Duration) -> Self {
            Self { connect_timeout }
        }

        fn request(&self, url: &str, method: &str, deadline: Duration) -> Result<Parts> {
            let rest = url
                .strip_prefix("http://")
                .context("only http:// peers are supported")?;
            let (authority, path) = match rest.find('/') {
                Some(i) => (&rest[..i], &rest[i..]),
                None => (rest, "/"),
            };
            let addr: SocketAddr = authority
                .parse()
                .with_context(|| format!("peer authority {authority:?} is not an ip:port"))?;
            if !super::is_lan_address(&addr.ip()) {
                // Belt and braces: the peer list is filtered at construction,
                // but a URL can also arrive from discovery later.
                bail!("refusing to connect to {addr}: not a private address");
            }
            let stream = TcpStream::connect_timeout(&addr, self.connect_timeout)
                .with_context(|| format!("connecting to {addr}"))?;
            stream.set_read_timeout(Some(deadline))?;
            stream.set_write_timeout(Some(self.connect_timeout))?;
            let mut w = stream.try_clone()?;
            write!(
                w,
                "{method} {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\
                 User-Agent: oligarchy-p2pd/{}\r\n\r\n",
                env!("CARGO_PKG_VERSION")
            )?;
            w.flush()?;

            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line)?;
            let status: u16 = line
                .split_whitespace()
                .nth(1)
                .and_then(|s| s.parse().ok())
                .with_context(|| format!("bad status line {line:?}"))?;

            let mut content_length = None;
            loop {
                let mut h = String::new();
                if reader.read_line(&mut h)? == 0 {
                    break;
                }
                let t = h.trim_end();
                if t.is_empty() {
                    break;
                }
                if let Some((k, v)) = t.split_once(':') {
                    if k.eq_ignore_ascii_case("content-length") {
                        content_length = v.trim().parse().ok();
                    }
                }
            }
            Ok(Parts { status, content_length, reader })
        }

        pub fn head_ok(&self, url: &str, deadline: Duration) -> Result<bool> {
            Ok(self.request(url, "HEAD", deadline)?.status == 200)
        }

        pub fn get_text(&self, url: &str, deadline: Duration, cap: u64) -> Result<Option<String>> {
            let p = self.request(url, "GET", deadline)?;
            if p.status == 404 {
                return Ok(None);
            }
            if p.status != 200 {
                bail!("HTTP {}", p.status);
            }
            // A peer must not be able to make us buffer without bound just
            // because the thing it is sending is small in principle.
            let mut s = String::new();
            p.reader.take(cap).read_to_string(&mut s)?;
            Ok(Some(s))
        }

        pub fn get_bytes(&self, url: &str, deadline: Duration, cap: u64) -> Result<Option<Vec<u8>>> {
            let p = self.request(url, "GET", deadline)?;
            if p.status == 404 {
                return Ok(None);
            }
            if p.status != 200 {
                bail!("HTTP {}", p.status);
            }
            let mut v = Vec::new();
            p.reader.take(cap).read_to_end(&mut v)?;
            Ok(Some(v))
        }

        pub fn get_stream(&self, url: &str, deadline: Duration) -> Result<Option<Body>> {
            let p = self.request(url, "GET", deadline)?;
            if p.status == 404 {
                return Ok(None);
            }
            if p.status != 200 {
                bail!("HTTP {}", p.status);
            }
            // The verifier caps the length regardless; this just avoids reading
            // past the declared body on a connection we said we would close.
            let inner: Box<dyn Read + Send> = match p.content_length {
                Some(n) => Box::new(p.reader.take(n)),
                None => Box::new(p.reader),
            };
            Ok(Some(Body { inner }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_every_range_strict_egress_already_allows() {
        for ip in [
            "10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.20",
            "100.64.0.1", "100.127.255.255", // tailnet
            "169.254.1.1", "127.0.0.1",
        ] {
            assert!(is_lan_address(&ip.parse().unwrap()), "rejected {ip}");
        }
        for ip in ["fd00::1", "fe80::1", "::1"] {
            assert!(is_lan_address(&ip.parse().unwrap()), "rejected {ip}");
        }
    }

    #[test]
    fn refuses_public_addresses() {
        // The LAN transport does not leave the local network. This is the check
        // that makes "works under strictEgress with no firewall change" true
        // rather than merely typical — and the one a malicious index would try
        // to talk us past.
        for ip in [
            "8.8.8.8", "1.1.1.1", "203.0.113.7", "172.32.0.1", "100.128.0.1",
            "2606:4700:4700::1111", "2001:db8::1",
        ] {
            assert!(!is_lan_address(&ip.parse().unwrap()), "accepted {ip}");
        }
    }

    #[test]
    fn a_public_peer_is_dropped_not_fatal() {
        // Refusing to start would take the substituter down over an optional
        // transport; the entry is dropped and logged loudly instead.
        let t = LanTransport::new(
            &["192.168.1.2:5112".into(), "8.8.8.8:5112".into()],
            Duration::from_secs(1),
            Default::default(),
        )
        .unwrap();
        let st = t.status();
        assert_eq!(st.peers_known, 1);
        assert_eq!(st.detail, "192.168.1.2:5112");
    }

    #[test]
    fn a_malformed_peer_is_a_configuration_error() {
        assert!(
            LanTransport::new(&["not-an-address".into()], Duration::from_secs(1), Default::default())
                .is_err()
        );
    }
}
