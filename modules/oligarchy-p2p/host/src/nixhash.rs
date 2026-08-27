//! Nix hash encoding.
//!
//! `.narinfo` carries hashes as `<algo>:<digest>`, and Nix accepts three
//! encodings for the digest (`Hash::parseAnyPrefixed`): base16, its own base32,
//! and base64. cache.nixos.org emits base32, but a narinfo we did not write may
//! use any of them, so all three are parsed. We only ever *emit* base32,
//! because that is what `NarInfo::to_string` emits upstream and matching it
//! keeps our output diff-able against a real cache.
//!
//! Nix's base32 is not RFC 4648. It has its own alphabet and it walks the
//! digest from the most-significant end backwards, so a naive base32 crate
//! produces a plausible-looking string that is simply wrong.

use std::fmt;

/// Nix's base32 alphabet: 0-9 a-z with `e`, `o`, `t` and `u` omitted.
const NIX32: &[u8] = b"0123456789abcdfghijklmnpqrsvwxyz";

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum HashError {
    #[error("hash is missing its `algo:` prefix")]
    NoPrefix,
    #[error("unsupported hash algorithm {0:?}; only sha256 is used by the binary cache protocol")]
    Algo(String),
    #[error("digest is not valid base16, nix-base32 or base64 for sha256")]
    Digest,
}

/// A sha256 digest, the only algorithm the binary cache protocol uses for
/// `NarHash` and `FileHash`.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Sha256Digest(pub [u8; 32]);

impl fmt::Debug for Sha256Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "sha256:{}", self.to_nix32())
    }
}

impl Sha256Digest {
    /// Parse a `sha256:<digest>` field as it appears in a narinfo.
    pub fn parse_prefixed(s: &str) -> Result<Self, HashError> {
        let (algo, digest) = s.split_once(':').ok_or(HashError::NoPrefix)?;
        if algo != "sha256" {
            return Err(HashError::Algo(algo.to_string()));
        }
        Self::parse_digest(digest)
    }

    /// Parse a bare digest, guessing the encoding from its length. The three
    /// lengths are distinct for sha256 (64 / 52 / 44), so this is unambiguous.
    pub fn parse_digest(d: &str) -> Result<Self, HashError> {
        match d.len() {
            64 => Self::from_base16(d),
            52 => Self::from_nix32(d),
            44 => Self::from_base64(d),
            _ => Err(HashError::Digest),
        }
    }

    fn from_base16(d: &str) -> Result<Self, HashError> {
        let b = d.as_bytes();
        let mut out = [0u8; 32];
        for (i, chunk) in b.chunks_exact(2).enumerate() {
            let hi = (chunk[0] as char).to_digit(16).ok_or(HashError::Digest)?;
            let lo = (chunk[1] as char).to_digit(16).ok_or(HashError::Digest)?;
            out[i] = ((hi << 4) | lo) as u8;
        }
        Ok(Self(out))
    }

    fn from_base64(d: &str) -> Result<Self, HashError> {
        const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut acc: u32 = 0;
        let mut bits = 0u32;
        let mut out = Vec::with_capacity(32);
        for c in d.bytes() {
            if c == b'=' {
                break;
            }
            let v = A.iter().position(|&a| a == c).ok_or(HashError::Digest)? as u32;
            acc = (acc << 6) | v;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((acc >> bits) as u8);
            }
        }
        if out.len() != 32 {
            return Err(HashError::Digest);
        }
        let mut a = [0u8; 32];
        a.copy_from_slice(&out);
        Ok(Self(a))
    }

    /// Decode Nix's base32. Mirrors `nix32Decode` in libutil/hash.cc: symbol
    /// `n` of the output contributes bits starting at offset `n * 5`, and the
    /// string is written most-significant-symbol first.
    pub fn from_nix32(d: &str) -> Result<Self, HashError> {
        let b = d.as_bytes();
        if b.len() != 52 {
            return Err(HashError::Digest);
        }
        let mut out = [0u8; 32];
        for (n, &c) in b.iter().rev().enumerate() {
            let digit = NIX32.iter().position(|&a| a == c).ok_or(HashError::Digest)? as u32;
            let b_off = n * 5;
            let i = b_off / 8;
            let j = (b_off % 8) as u32;
            out[i] |= (digit << j) as u8;
            let carry = digit >> (8 - j);
            if i + 1 < 32 {
                out[i + 1] |= carry as u8;
            } else if carry != 0 {
                // Bits that would fall off the end must be zero, or this string
                // does not encode a 32-byte digest.
                return Err(HashError::Digest);
            }
        }
        Ok(Self(out))
    }

    /// Encode as Nix base32 — 52 symbols for sha256.
    pub fn to_nix32(&self) -> String {
        let len = (32 * 8 - 1) / 5 + 1; // 52
        let mut s = String::with_capacity(len);
        for n in (0..len).rev() {
            let b_off = n * 5;
            let i = b_off / 8;
            let j = (b_off % 8) as u32;
            let mut c = (self.0[i] as u32) >> j;
            if i + 1 < 32 {
                c |= (self.0[i + 1] as u32) << (8 - j);
            }
            s.push(NIX32[(c & 0x1f) as usize] as char);
        }
        s
    }

    /// The form a narinfo field takes.
    pub fn to_prefixed(&self) -> String {
        format!("sha256:{}", self.to_nix32())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Taken from a real cache.nixos.org narinfo for hello-2.12.3, captured
    // during the Stage 0 spikes. Both encodings name the same NAR.
    const HELLO_NIX32: &str = "1n71v0lypd23hmqq1zbhzcd9v49r8g6n2f0hsyfv99pkgmajraw2";
    const HELLO_B64: &str = "gqssVX3zprSd1xA4Yc1DOZGdGvtw/YBxhUO06ynY4dg=";

    #[test]
    fn nix32_round_trips() {
        let h = Sha256Digest::from_nix32(HELLO_NIX32).unwrap();
        assert_eq!(h.to_nix32(), HELLO_NIX32);
    }

    #[test]
    fn the_three_encodings_name_the_same_digest() {
        // If this fails, one of the decoders is subtly wrong and the adapter
        // would reject perfectly good NARs from a cache that happened to emit
        // a different encoding.
        let a = Sha256Digest::parse_prefixed(&format!("sha256:{HELLO_NIX32}")).unwrap();
        let b = Sha256Digest::parse_prefixed(&format!("sha256:{HELLO_B64}")).unwrap();
        let hex: String = a.0.iter().map(|x| format!("{x:02x}")).collect();
        let c = Sha256Digest::parse_prefixed(&format!("sha256:{hex}")).unwrap();
        assert_eq!(a, b);
        assert_eq!(a, c);
    }

    #[test]
    fn nix32_is_not_rfc4648() {
        // Guards against someone "simplifying" this to a base32 crate. The
        // alphabet omits e/o/t/u and the walk is reversed; an RFC 4648 decoder
        // returns a different digest for the same string, silently.
        assert!(!NIX32.contains(&b'e'));
        assert!(!NIX32.contains(&b'o'));
        assert!(!NIX32.contains(&b't'));
        assert!(!NIX32.contains(&b'u'));
        let h = Sha256Digest::from_nix32(HELLO_NIX32).unwrap();
        assert_ne!(h.0[0], 0);
    }

    #[test]
    fn rejects_wrong_algo_and_missing_prefix() {
        assert_eq!(Sha256Digest::parse_prefixed("deadbeef"), Err(HashError::NoPrefix));
        assert!(matches!(
            Sha256Digest::parse_prefixed("sha512:deadbeef"),
            Err(HashError::Algo(_))
        ));
    }
}
