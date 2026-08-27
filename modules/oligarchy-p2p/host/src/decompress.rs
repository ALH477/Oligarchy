//! Decompressing upstream bodies to the canonical uncompressed NAR.
//!
//! Stage 1 re-served upstream's bytes verbatim, which meant the narinfo we
//! handed Nix described bytes we did not control. Nix caches a narinfo for
//! `narinfo-cache-positive-ttl` — **thirty days** — so when upstream
//! re-compressed (cache.nixos.org moved `hello` from xz to zstd mid-development)
//! every cached narinfo named a NAR we would no longer serve, and the adapter
//! 404'd until the TTL expired.
//!
//! Serving `Compression: none` fixes that at the root: every transport field we
//! emit becomes a pure function of `NarHash` and `NarSize`, both of which are
//! **signed** and therefore immutable for a given store path. Upstream can
//! re-compress as often as it likes.
//!
//! It is also the security improvement §3.2 of the roadmap argues for: the
//! bytes on our wire are the bytes the signature covers, so no unsigned field
//! sits anywhere in the trust path.

use std::io::Read;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("unsupported compression {0:?}")]
pub struct Unsupported(pub String);

/// Compression algorithms we can decode.
///
/// `bzip2` and `br` are deliberately absent. Nix's *default* when a narinfo
/// omits `Compression` is bzip2, so a very old cache could serve it — but
/// nothing in this project's upstream set does, and refusing loudly (the
/// adapter 404s and Nix fetches from upstream directly) is better than adding a
/// third vendored C decoder for a case that does not arise. If one ever does,
/// the fix is one arm of this match, not a redesign.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    None,
    Xz,
    Zstd,
}

impl Codec {
    pub fn parse(compression: &str) -> Result<Self, Unsupported> {
        match compression {
            "none" | "" => Ok(Codec::None),
            "xz" => Ok(Codec::Xz),
            "zstd" => Ok(Codec::Zstd),
            other => Err(Unsupported(other.to_string())),
        }
    }

    /// Wrap a blocking reader so it yields the decompressed NAR.
    pub fn reader<'a, R: Read + 'a>(self, inner: R) -> Box<dyn Read + 'a> {
        match self {
            Codec::None => Box::new(inner),
            Codec::Xz => Box::new(xz2::read::XzDecoder::new(inner)),
            Codec::Zstd => Box::new(
                zstd::stream::read::Decoder::new(inner)
                    .expect("zstd decoder init cannot fail on a reader"),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn parses_what_caches_actually_serve() {
        assert_eq!(Codec::parse("xz").unwrap(), Codec::Xz);
        assert_eq!(Codec::parse("zstd").unwrap(), Codec::Zstd);
        assert_eq!(Codec::parse("none").unwrap(), Codec::None);
    }

    #[test]
    fn an_empty_compression_field_is_none_not_bzip2() {
        // Careful: Nix's *narinfo default* for an ABSENT Compression field is
        // bzip2 (nar-info.cc), and `NarInfo::compression()` implements that.
        // By the time a string reaches here it has already been through that
        // defaulting, so an empty string means the field said "none"-ish, not
        // "field was missing". The two live in different places on purpose.
        assert_eq!(Codec::parse("").unwrap(), Codec::None);
    }

    #[test]
    fn refuses_what_it_cannot_decode_rather_than_guessing() {
        // Guessing would corrupt the stream and surface as a hash mismatch far
        // from the cause.
        for c in ["bzip2", "br", "lzip", "gzip"] {
            assert_eq!(Codec::parse(c), Err(Unsupported(c.to_string())));
        }
    }

    #[test]
    fn xz_round_trips() {
        let data: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let mut e = xz2::write::XzEncoder::new(Vec::new(), 6);
        e.write_all(&data).unwrap();
        let packed = e.finish().unwrap();
        assert!(packed.len() < data.len());
        let mut out = Vec::new();
        Codec::Xz.reader(&packed[..]).read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn zstd_round_trips() {
        let data: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let packed = zstd::stream::encode_all(&data[..], 3).unwrap();
        assert!(packed.len() < data.len());
        let mut out = Vec::new();
        Codec::Zstd.reader(&packed[..]).read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn a_truncated_stream_errors_rather_than_returning_short() {
        // If a truncated body decoded to a short-but-clean NAR we would hand
        // Nix a valid-looking prefix. It must be an io error.
        let data: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let mut e = xz2::write::XzEncoder::new(Vec::new(), 6);
        e.write_all(&data).unwrap();
        let packed = e.finish().unwrap();
        let truncated = &packed[..packed.len() / 2];
        let mut out = Vec::new();
        assert!(Codec::Xz.reader(truncated).read_to_end(&mut out).is_err());
    }
}
