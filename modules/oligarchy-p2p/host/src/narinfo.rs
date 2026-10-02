//! `.narinfo` parsing and re-emission.
//!
//! The invariant this module exists to hold: **everything we did not
//! deliberately rewrite comes back out byte-identical, in the original order.**
//! That includes fields Nix does not know about, and it includes every `Sig:`
//! line — a narinfo may carry several, and dropping one silently narrows the
//! set of hosts that can verify the path.
//!
//! Only four fields are ours to change, and they are exactly the four that the
//! signature does not cover. `ValidPathInfo::fingerprint` (libstore/path-info.cc)
//! is
//!
//! ```text
//! "1;" + storePath + ";" + narHash + ";" + narSize + ";" + join(",", references)
//! ```
//!
//! so `URL`, `Compression`, `FileHash` and `FileSize` are unsigned and may be
//! rewritten by anyone — us included — without invalidating `Sig`. Touching
//! anything else would invalidate every signature on the path, and the failure
//! would show up as an unexplained "lacks a signature by a trusted key" much
//! further downstream. `rewrite_transport` is the only mutator for that reason.

use crate::nixhash::Sha256Digest;

/// Fields the signature covers. Rewriting any of these breaks `Sig`.
pub const SIGNED_FIELDS: &[&str] = &["StorePath", "NarHash", "NarSize", "References"];

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum NarInfoError {
    #[error("line {0} has no `: ` separator")]
    Separator(usize),
    #[error("line {0}: field name is empty or not [A-Za-z0-9-]")]
    BadKey(usize),
    #[error("line {0} is empty")]
    EmptyLine(usize),
    #[error("line {0} contains a carriage return")]
    CarriageReturn(usize),
    #[error("the last line has no terminating newline")]
    Unterminated,
    #[error("field {0} appears more than once")]
    Duplicate(String),
    #[error("missing required field {0}")]
    Missing(&'static str),
    #[error("{0} is not a number")]
    NotANumber(&'static str),
    #[error("NarSize is zero")]
    ZeroNarSize,
    #[error("bad hash in {field}: {source}")]
    Hash {
        field: &'static str,
        #[source]
        source: crate::nixhash::HashError,
    },
}

/// An ordered, loss-free view of a narinfo.
///
/// Deliberately a `Vec` of pairs rather than a map: a map would lose field
/// order and collapse repeated `Sig:` lines, and both of those are observable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NarInfo {
    fields: Vec<(String, String)>,
}

impl NarInfo {
    /// Parse a narinfo, accepting ONLY the grammar on which this parser and
    /// Nix's (`NarInfo::NarInfo` in libstore/nar-info.cc) provably read the
    /// same fields. A narinfo outside it is refused, not interpreted.
    ///
    /// This matters because the adapter judges a narinfo (hash part, peer
    /// scope, NarHash) and then hands the same bytes to nix-daemon, which
    /// judges them again with its own parser. Any input the two parse
    /// differently is a way to show the adapter one store path and Nix
    /// another — exactly the bypass of `acceptFromPeers` that §2 forbids. Two
    /// such inputs were real before this grammar:
    ///
    /// - a repeated `StorePath:`. `get` returns the first; Nix assigns on
    ///   every occurrence, so the LAST wins. The same holds for NarHash,
    ///   NarSize and URL. Hence: no field may repeat, except `Sig`, which Nix
    ///   accumulates and so do we.
    /// - a blank line. `str::lines` skipped it; Nix does not split on lines at
    ///   all — it searches for the next ':' from the current position, so a
    ///   blank line glues itself onto the next key (`"\nStorePath"`), which
    ///   Nix then ignores as unknown. A `StorePath:` after a blank line was
    ///   read by the adapter and invisible to Nix. Hence: no empty lines.
    ///
    /// The rest closes the same class at its edges. `lines()` also strips a
    /// `\r` that Nix keeps in the value, so no `\r` anywhere. Nix requires
    /// every line to end in `\n` ("expecting '\n'"), so must we. A field name
    /// containing ':' or a newline is what lets Nix's colon search drift from
    /// line boundaries, so names are `[A-Za-z0-9-]` (every real field, and the
    /// `X-Oligarchy-*` transport hints, fit). `split_once(": ")` agrees with
    /// Nix's `colon + 2` only because the name has no ':' of its own.
    pub fn parse(s: &str) -> Result<Self, NarInfoError> {
        let body = s.strip_suffix('\n').ok_or(NarInfoError::Unterminated)?;
        let mut fields: Vec<(String, String)> = Vec::new();
        for (n, line) in body.split('\n').enumerate() {
            let n = n + 1;
            if line.is_empty() {
                return Err(NarInfoError::EmptyLine(n));
            }
            if line.contains('\r') {
                return Err(NarInfoError::CarriageReturn(n));
            }
            // A value may itself contain colons — `Sig:` and `URL:` both do —
            // so split_once is required and splitn on ':' would be wrong.
            let (k, v) = line.split_once(": ").ok_or(NarInfoError::Separator(n))?;
            if k.is_empty() || !k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
                return Err(NarInfoError::BadKey(n));
            }
            if k != "Sig" && fields.iter().any(|(seen, _)| seen == k) {
                return Err(NarInfoError::Duplicate(k.to_string()));
            }
            fields.push((k.to_string(), v.to_string()));
        }
        let me = Self { fields };
        me.validate()?;
        Ok(me)
    }

    /// The same four requirements Nix enforces at the end of its parser:
    /// StorePath, NarHash, a non-empty URL and a non-zero NarSize.
    fn validate(&self) -> Result<(), NarInfoError> {
        self.get("StorePath").ok_or(NarInfoError::Missing("StorePath"))?;
        let nh = self.get("NarHash").ok_or(NarInfoError::Missing("NarHash"))?;
        Sha256Digest::parse_prefixed(nh).map_err(|source| NarInfoError::Hash {
            field: "NarHash",
            source,
        })?;
        let url = self.get("URL").ok_or(NarInfoError::Missing("URL"))?;
        if url.is_empty() {
            return Err(NarInfoError::Missing("URL"));
        }
        if self.nar_size()? == 0 {
            return Err(NarInfoError::ZeroNarSize);
        }
        Ok(())
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.fields.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    pub fn get_all(&self, key: &str) -> Vec<&str> {
        self.fields
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    pub fn store_path(&self) -> &str {
        self.get("StorePath").expect("validated at parse")
    }

    pub fn nar_hash(&self) -> Sha256Digest {
        Sha256Digest::parse_prefixed(self.get("NarHash").expect("validated at parse"))
            .expect("validated at parse")
    }

    pub fn nar_size(&self) -> Result<u64, NarInfoError> {
        self.get("NarSize")
            .ok_or(NarInfoError::Missing("NarSize"))?
            .parse()
            .map_err(|_| NarInfoError::NotANumber("NarSize"))
    }

    /// `Compression` defaults to bzip2 when absent — a Nix quirk (nar-info.cc
    /// sets it after parsing), not something to guess differently.
    pub fn compression(&self) -> &str {
        match self.get("Compression") {
            None | Some("") => "bzip2",
            Some(c) => c,
        }
    }

    pub fn file_size(&self) -> Option<u64> {
        self.get("FileSize").and_then(|s| s.parse().ok())
    }

    pub fn url(&self) -> &str {
        self.get("URL").expect("validated at parse")
    }

    /// The store path's hash part — the 32-character name a narinfo is looked
    /// up by (`GET /<hashpart>.narinfo`).
    pub fn hash_part(&self) -> &str {
        let p = self.store_path();
        let base = p.rsplit('/').next().unwrap_or(p);
        base.split_once('-').map(|(h, _)| h).unwrap_or(base)
    }

    fn set(&mut self, key: &str, value: String) {
        // Not documentation. `rewrite_transport` is the only caller and it
        // passes four fixed keys, so this can only fire if someone adds a
        // fifth — which is exactly the change that would silently invalidate
        // every signature on every path we serve.
        assert!(
            !SIGNED_FIELDS.contains(&key),
            "refusing to rewrite {key}: it is covered by the signature fingerprint"
        );
        if let Some(slot) = self.fields.iter_mut().find(|(k, _)| k == key) {
            slot.1 = value;
        } else {
            self.fields.push((key.to_string(), value));
        }
    }

    /// Rewrite the transport fields to point at us. The **only** mutator.
    ///
    /// `compression`/`file_hash`/`file_size` are passed through unchanged when
    /// `None`, which is the stage-1 pass-through posture: we re-serve upstream's
    /// bytes verbatim, so upstream's description of them stays true. Stage 2
    /// serves the uncompressed NAR and will supply all three.
    pub fn rewrite_transport(
        &mut self,
        url: String,
        compression: Option<&str>,
        file_hash: Option<Sha256Digest>,
        file_size: Option<u64>,
    ) {
        self.set("URL", url);
        if let Some(c) = compression {
            self.set("Compression", c.to_string());
        }
        if let Some(h) = file_hash {
            self.set("FileHash", h.to_prefixed());
        }
        if let Some(s) = file_size {
            self.set("FileSize", s.to_string());
        }
    }

    pub fn to_text(&self) -> String {
        let mut s = String::new();
        for (k, v) in &self.fields {
            s.push_str(k);
            s.push_str(": ");
            s.push_str(v);
            s.push('\n');
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A real cache.nixos.org narinfo, captured in the Stage 0 spikes.
    const HELLO: &str = "\
StorePath: /nix/store/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-hello-2.12.3
URL: nar/174fba8vinrah6iyhp92kmz7r5kx6habnc4qb1rs0657sx224zvn.nar.xz
Compression: xz
FileHash: sha256:174fba8vinrah6iyhp92kmz7r5kx6habnc4qb1rs0657sx224zvn
FileSize: 58484
NarHash: sha256:1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2
NarSize: 279624
References: 0d8g8n0a11v6f5m2h416ajyxmnkwc3md-glibc-2.42-67 lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-hello-2.12.3
Deriver: a41gq8gxdhd2haqk5ij6ak4ybwmignrp-hello-2.12.3.drv
Sig: cache.nixos.org-1:TqYPBscpSVaO5LQnJYnNe2tvRnibuig5TV+kjyOIr+UUzmK+CLy7czpeNjRpdOclUvedDSqHb4xRS0vm3zggAw==
";

    #[test]
    fn round_trips_byte_for_byte() {
        assert_eq!(NarInfo::parse(HELLO).unwrap().to_text(), HELLO);
    }

    #[test]
    fn unknown_fields_survive_round_trip() {
        // Nix ignores fields it does not know (verified against a real store in
        // Stage 0, spike 1). We must not be the component that drops them, or a
        // future transport hint carried this way would vanish on re-emission.
        let with_extra = format!(
            "{HELLO}X-Oligarchy-Torrent: magnet:?xt=urn:btih:0123456789abcdef\nX-Oligarchy-PieceLength: 262144\n"
        );
        let ni = NarInfo::parse(&with_extra).unwrap();
        assert_eq!(ni.to_text(), with_extra);
        assert_eq!(ni.get("X-Oligarchy-PieceLength"), Some("262144"));
    }

    #[test]
    fn every_sig_line_is_preserved() {
        // A path signed by two keys must stay verifiable by hosts trusting
        // either one. Collapsing to a single Sig silently narrows that set.
        let two = HELLO.replace(
            "Sig: cache.nixos.org-1:",
            "Sig: extra.example.org-1:AAAA\nSig: cache.nixos.org-1:",
        );
        let ni = NarInfo::parse(&two).unwrap();
        assert_eq!(ni.get_all("Sig").len(), 2);
        assert_eq!(ni.to_text(), two);
    }

    #[test]
    fn rewrite_touches_only_unsigned_fields() {
        // The guarantee: after a rewrite, every field the fingerprint covers is
        // bit-identical. If this breaks, signatures stop verifying and the
        // symptom appears nowhere near this function.
        let before = NarInfo::parse(HELLO).unwrap();
        let mut after = before.clone();
        after.rewrite_transport(
            "nar/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx/whatever.nar".into(),
            Some("none"),
            Some(before.nar_hash()),
            Some(before.nar_size().unwrap()),
        );
        for f in SIGNED_FIELDS {
            assert_eq!(before.get(f), after.get(f), "rewrote signed field {f}");
        }
        assert_eq!(before.get_all("Sig"), after.get_all("Sig"));
        assert_eq!(after.url(), "nar/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx/whatever.nar");
        assert_eq!(after.compression(), "none");
    }

    #[test]
    fn pass_through_rewrite_leaves_compression_alone() {
        // Stage 1 posture: only URL moves. Upstream still describes its own
        // bytes, because they are the bytes we re-serve.
        let mut ni = NarInfo::parse(HELLO).unwrap();
        ni.rewrite_transport("nar/x/y.nar.xz".into(), None, None, None);
        assert_eq!(ni.compression(), "xz");
        assert_eq!(ni.get("FileSize"), Some("58484"));
    }

    #[test]
    #[should_panic(expected = "covered by the signature fingerprint")]
    fn writing_a_signed_field_is_a_hard_error() {
        // The guard in `set`. If a future field rewrite needs NarHash, the
        // right answer is to re-sign, not to relax this.
        let mut ni = NarInfo::parse(HELLO).unwrap();
        ni.set("NarHash", "sha256:whatever".into());
    }

    #[test]
    fn hash_part_is_the_lookup_key() {
        assert_eq!(
            NarInfo::parse(HELLO).unwrap().hash_part(),
            "lcxc2z1h2g8wq8dxfpizy1di85kyxnqx"
        );
    }

    #[test]
    fn refuses_a_narinfo_nix_would_also_refuse() {
        for (bad, why) in [
            (HELLO.replace("NarSize: 279624", "NarSize: 0"), "zero NarSize"),
            (
                HELLO.lines().filter(|l| !l.starts_with("NarHash")).collect::<Vec<_>>().join("\n"),
                "no NarHash",
            ),
            (
                HELLO.lines().filter(|l| !l.starts_with("URL")).collect::<Vec<_>>().join("\n"),
                "no URL",
            ),
        ] {
            assert!(NarInfo::parse(&bad).is_err(), "accepted a narinfo with {why}");
        }
    }

    /// The peer-scope bypass this grammar closes: the adapter must never read
    /// a different StorePath than Nix does. Each case was accepted before.
    #[test]
    fn refuses_every_input_nix_would_read_differently() {
        let allowed = "StorePath: /nix/store/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-hello-2.12.3\n";
        let evil = "StorePath: /nix/store/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-glibc-2.42-67\n";
        let rest = HELLO.strip_prefix(allowed).unwrap();
        let cases: Vec<(String, NarInfoError)> = vec![
            // Nix: last StorePath wins.
            (format!("{allowed}{evil}{rest}"), NarInfoError::Duplicate("StorePath".into())),
            // Nix: the blank line glues onto the next key, which it then ignores.
            (
                format!("URL: x\n\n{allowed}{evil}{}", rest.replacen("URL: ", "X-Old-URL: ", 1)),
                NarInfoError::EmptyLine(2),
            ),
            (format!("{allowed}{}", rest.replacen("NarHash", "NarHash: sha256:1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2\nNarHash", 1)),
                NarInfoError::Duplicate("NarHash".into())),
            (format!("{allowed}{rest}NarSize: 1\n"), NarInfoError::Duplicate("NarSize".into())),
            (format!("{allowed}{rest}URL: nar/elsewhere.nar\n"), NarInfoError::Duplicate("URL".into())),
            (HELLO.replacen("\n", "\r\n", 1), NarInfoError::CarriageReturn(1)),
            (HELLO.trim_end_matches('\n').to_string(), NarInfoError::Unterminated),
            (format!("{HELLO}Store:Path: x\n"), NarInfoError::BadKey(11)),
            (format!("{HELLO}: x\n"), NarInfoError::BadKey(11)),
            (format!("{HELLO}StorePath:/nix/store/x\n"), NarInfoError::Separator(11)),
        ];
        for (bad, want) in cases {
            assert_eq!(NarInfo::parse(&bad), Err(want), "{bad:?}");
        }
    }

    #[test]
    fn compression_absent_means_bzip2_not_none() {
        // Nix's own default. Guessing "none" here would make us mis-describe a
        // legacy cache's bytes and corrupt the fetch in a way that looks like a
        // hash mismatch.
        let no_comp: String = HELLO
            .lines()
            .filter(|l| !l.starts_with("Compression"))
            .map(|l| format!("{l}\n"))
            .collect();
        assert_eq!(NarInfo::parse(&no_comp).unwrap().compression(), "bzip2");
    }
}
