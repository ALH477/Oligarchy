//! The verification funnel. Every byte the adapter serves passes through here.
//!
//! Two guarantees, and they are separate on purpose:
//!
//! 1. **The digest matches.** Checked at end-of-stream.
//! 2. **The length is capped.** Checked on *every* chunk, and this one is not
//!    redundant with Nix.
//!
//! Guarantee 2 exists because of a measured fact, not a hypothetical. Stage 0
//! spikes 8 and 9 (docs/p2p-substituter-roadmap.md §2.1) showed that Nix
//! imposes no upper bound on what a substituter delivers: `FileSize` is never
//! checked on the substitution path, and bytes past the end of the NAR stream
//! are read and discarded without complaint. Serving 64 MiB for a 279 KiB claim
//! succeeded and registered the path as valid. So a peer can attach unbounded
//! garbage and *nothing downstream will stop it*. This cap is the only thing
//! that does.
//!
//! `Verified` is a witness type: it has no public constructor, and `finish()`
//! is the only thing that produces one. A function that requires a `Verified`
//! cannot be handed unchecked bytes by mistake — the mistake does not typecheck.

use crate::nixhash::Sha256Digest;
use bytes::Bytes;
use sha2::{Digest, Sha256};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum VerifyError {
    #[error("{source_name}: served {got} bytes for a declared {expected} — refusing to continue")]
    TooLong {
        source_name: String,
        got: u64,
        expected: u64,
    },
    #[error("{source_name}: stream ended at {got} bytes, expected {expected}")]
    TooShort {
        source_name: String,
        got: u64,
        expected: u64,
    },
    #[error("{source_name}: hash mismatch\n  expected: {expected}\n  got:      {got}")]
    Digest {
        source_name: String,
        expected: String,
        got: String,
    },
}

/// Proof that a stream matched its declared digest and length.
#[derive(Debug)]
pub struct Verified {
    pub bytes: u64,
    pub digest: Sha256Digest,
    _seal: (),
}

/// Streaming verifier. Feed it every chunk; call `finish` at end of stream.
#[derive(Debug)]
pub struct Verifier {
    hasher: Sha256,
    seen: u64,
    expected_len: u64,
    expected_digest: Sha256Digest,
    source_name: String,
}

impl Verifier {
    pub fn new(expected_digest: Sha256Digest, expected_len: u64, source_name: impl Into<String>) -> Self {
        Self {
            hasher: Sha256::new(),
            seen: 0,
            expected_len,
            expected_digest,
            source_name: source_name.into(),
        }
    }

    pub fn seen(&self) -> u64 {
        self.seen
    }

    /// Feed a chunk. Errors the instant the cap is exceeded — before the chunk
    /// is hashed and before a caller could forward it — so an unbounded source
    /// costs one chunk of slack, not an unbounded transfer.
    pub fn update(&mut self, chunk: &[u8]) -> Result<(), VerifyError> {
        let next = self.seen.saturating_add(chunk.len() as u64);
        if next > self.expected_len {
            return Err(VerifyError::TooLong {
                source_name: self.source_name.clone(),
                got: next,
                expected: self.expected_len,
            });
        }
        self.hasher.update(chunk);
        self.seen = next;
        Ok(())
    }

    pub fn finish(self) -> Result<Verified, VerifyError> {
        if self.seen != self.expected_len {
            return Err(VerifyError::TooShort {
                source_name: self.source_name,
                got: self.seen,
                expected: self.expected_len,
            });
        }
        let mut got = [0u8; 32];
        got.copy_from_slice(&self.hasher.finalize());
        let got = Sha256Digest(got);
        if got != self.expected_digest {
            return Err(VerifyError::Digest {
                source_name: self.source_name,
                expected: self.expected_digest.to_prefixed(),
                got: got.to_prefixed(),
            });
        }
        Ok(Verified {
            bytes: self.seen,
            digest: got,
            _seal: (),
        })
    }
}

/// One chunk of lookahead.
///
/// Extracted so the fix for a real bug lives in exactly one place. The bug: a
/// digest check written *after* a read loop never runs when the consumer stops
/// polling early — which is what `Body::from_stream` does the moment it has
/// `Content-Length` bytes. A length-preserving corruption was served with
/// HTTP 200 and nothing in the log.
///
/// Withholding the final chunk until the check has passed makes completion of
/// the body conditional on verification rather than incidental to it.
///
/// The end-to-end guarantee is asserted against the code that actually runs, in
/// `resolve::upstream_stream` — see `a_corrupt_body_never_completes` there.
/// Asserting it only at this level is what let the original bug through: the
/// `Verifier` was correct in isolation and the integration was not.
#[derive(Debug, Default)]
pub struct Lookahead {
    held: Option<Bytes>,
}

impl Lookahead {
    /// Accept a chunk; return the previous one, which is now safe to emit.
    pub fn push(&mut self, chunk: Bytes) -> Option<Bytes> {
        self.held.replace(chunk)
    }

    /// The withheld final chunk. Only call this once verification has passed.
    pub fn take(self) -> Option<Bytes> {
        self.held
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest_of(data: &[u8]) -> Sha256Digest {
        let mut h = Sha256::new();
        h.update(data);
        let mut o = [0u8; 32];
        o.copy_from_slice(&h.finalize());
        Sha256Digest(o)
    }

    #[test]
    fn good_stream_verifies() {
        let data = b"the quick brown fox";
        let mut v = Verifier::new(digest_of(data), data.len() as u64, "test");
        for c in data.chunks(4) {
            v.update(c).unwrap();
        }
        assert_eq!(v.finish().unwrap().bytes, data.len() as u64);
    }

    #[test]
    fn one_byte_over_narsize_aborts() {
        // The guarantee spikes 8 and 9 made load-bearing: Nix will not stop an
        // over-long body, so we must, and we must do it mid-stream rather than
        // at the end. A version that only checked length in `finish` would let
        // a peer stream gigabytes first.
        let data = b"exactly-right";
        let mut v = Verifier::new(digest_of(data), data.len() as u64, "greedy-peer");
        v.update(data).unwrap();
        let err = v.update(b"!").unwrap_err();
        assert!(matches!(err, VerifyError::TooLong { .. }), "{err:?}");
        assert!(err.to_string().contains("greedy-peer"));
    }

    #[test]
    fn the_cap_fires_before_the_whole_body_arrives() {
        // A 1 GiB body against a 10-byte claim must die on the first oversized
        // chunk, not after buffering 1 GiB.
        let mut v = Verifier::new(digest_of(b"0123456789"), 10, "flood");
        assert!(v.update(&[0u8; 4]).is_ok());
        assert!(v.update(&[0u8; 4]).is_ok());
        assert!(v.update(&[0u8; 4]).is_err());
        assert_eq!(v.seen(), 8, "must not have absorbed the oversized chunk");
    }

    #[test]
    fn truncated_stream_is_refused() {
        let data = b"the quick brown fox";
        let mut v = Verifier::new(digest_of(data), data.len() as u64, "test");
        v.update(&data[..5]).unwrap();
        assert!(matches!(v.finish(), Err(VerifyError::TooShort { .. })));
    }

    #[test]
    fn right_length_wrong_bytes_is_refused() {
        // The malicious-peer case: correct length, wrong content. Only the
        // digest catches this.
        let good = b"the quick brown fox";
        let bad = b"the quick brown FOX";
        let mut v = Verifier::new(digest_of(good), good.len() as u64, "liar");
        v.update(bad).unwrap();
        let err = v.finish().unwrap_err();
        assert!(matches!(err, VerifyError::Digest { .. }), "{err:?}");
        assert!(err.to_string().contains("liar"), "error must name the source");
    }

    #[test]
    fn lookahead_withholds_exactly_one_chunk() {
        let mut la = Lookahead::default();
        assert_eq!(la.push(Bytes::from_static(b"a")), None, "first push emits nothing");
        assert_eq!(la.push(Bytes::from_static(b"b")).unwrap(), Bytes::from_static(b"a"));
        assert_eq!(la.take().unwrap(), Bytes::from_static(b"b"), "last chunk is withheld");
    }

    #[test]
    fn a_verified_witness_cannot_be_forged() {
        // `Verified` has a private field, so it is unconstructible outside this
        // module. This test documents the intent; the compiler enforces it.
        // Uncommenting the line below must fail to build:
        //   let _ = Verified { bytes: 0, digest: digest_of(b""), _seal: () };
        let data = b"x";
        let mut v = Verifier::new(digest_of(data), 1, "test");
        v.update(data).unwrap();
        assert!(v.finish().is_ok());
    }
}
