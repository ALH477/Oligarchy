//! The tar-header judge that runs before root extracts a payload.
//!
//! `extract_payload` runs GNU tar as root on `payload.tar.zst`, a file that may
//! have come off a USB stick whose label anyone can forge. Tar creates whatever
//! the archive says. Measured as root with GNU tar 1.35 and this crate's own
//! extract flags, a hostile payload produced three things:
//!
//! - a world-readable block device `259,0` (an NVMe disk);
//! - a FIFO;
//! - a symlink to `/etc/shadow`.
//!
//! The name check that was here looked at names, never at member types.
//!
//! The decision is not made in Rust. It is Exsecutor's `examples/arca`,
//! emitted as C (`arca/arca.gen.c`, see `arca/PROVENANCE.md`) and linked here.
//! It admits only GNU tar's own output shape:
//!
//! - regular files, directories and GNU long names;
//! - checksum, size, mode, uid, gid and mtime in GNU's exact forms;
//! - relative names with no `..`, no control byte and no backslash.
//!
//! It refuses everything else. Narrow on purpose: a judge that parses tar
//! differently from tar can be shown one archive while tar extracts another.
//! Upstream it is held to GNU tar by a header fuzz with zero cases the judge
//! admits and tar reads differently.
//!
//! This module is the host half and only does I/O. It reads 512-byte blocks,
//! hands each to the judge, reads a long name when told to, skips file data by
//! the length the judge computed, and after the end block requires the rest of
//! the stream to be zeros. It never interprets a header itself.

use std::io::{self, Read};

use crate::error::{Error, Result};

extern "C" {
    // arca.exsc, as the C backend emits it (arca/arca.gen.c).
    fn exs_caput_iudica(h: *mut u8, l: *mut u8, nl: u64, habet: u64) -> u64;
    fn exs_magnitudo(h: *mut u8) -> u64;
    fn exs_saltus(m: u64) -> u64;
}

/// One member the judge admitted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    pub dir: bool,
    pub name: Vec<u8>,
}

fn why(v: u64) -> &'static str {
    match v {
        16 => "bad header checksum",
        17 => "not GNU tar format (POSIX ustar / pax are refused)",
        18 => "a member type other than file or directory (link, device, FIFO, ...)",
        19 => "a malformed size field",
        20 => "an absolute member name",
        21 => "a '..' component in a member name",
        22 => "a control byte, DEL or backslash in a member name",
        23 => "an empty member name",
        24 => "a malformed GNU long-name record",
        25 => "a long-name record not followed by a member",
        26 => "a directory with data, or a '/' that disagrees with the type",
        27 => "a mode, uid, gid or mtime field not in GNU's form",
        _ => "an undocumented verdict (refused: fail closed)",
    }
}

fn read_exact_or<R: Read>(r: &mut R, buf: &mut [u8], at: u64) -> Result<()> {
    r.read_exact(buf).map_err(|e| match e.kind() {
        io::ErrorKind::UnexpectedEof => {
            Error::store(format!("payload tar stream ends mid-member at byte {at}"))
        }
        _ => Error::Io(e),
    })
}

/// Judge a whole uncompressed tar stream. `Ok` lists the members, in order,
/// only if every header was admitted and the stream ends in zeros.
pub fn judge<R: Read>(mut r: R) -> Result<Vec<Member>> {
    let mut h = [0u8; 512];
    let mut l = [0u8; 4096];
    let mut nl: u64 = 0;
    let mut habet: u64 = 0;
    let mut at: u64 = 0;
    let mut members = Vec::new();
    loop {
        read_exact_or(&mut r, &mut h, at)?;
        // SAFETY: `h` is a local [u8; 512] and `l` a local [u8; 4096], exactly
        // the `acies<u8, 512>` / `acies<u8, 4096>` the functions are declared
        // over; the unit reads nothing past them and writes neither. It holds
        // no other state, so it is safe from any thread.
        let (v, m) = unsafe {
            (
                exs_caput_iudica(h.as_mut_ptr(), l.as_mut_ptr(), nl, habet),
                exs_magnitudo(h.as_mut_ptr()),
            )
        };
        let here = at;
        at += 512;
        match v {
            3 => {
                // The end, where GNU tar stops reading. Anything after it
                // must be zeros, or the judge admitted a stream it never saw.
                let mut buf = [0u8; 8192];
                loop {
                    let n = r.read(&mut buf)?;
                    if n == 0 {
                        return Ok(members);
                    }
                    if buf[..n].iter().any(|&b| b != 0) {
                        return Err(Error::store(format!(
                            "payload tar stream has data after its end block (byte {at})"
                        )));
                    }
                    at += n as u64;
                }
            }
            2 => {
                // A long-name record: the judge bounded m to 1..=4096.
                let pad = unsafe { exs_saltus(m) };
                let mut rec = vec![0u8; pad as usize];
                read_exact_or(&mut r, &mut rec, at)?;
                at += pad;
                l = [0u8; 4096];
                l[..m as usize].copy_from_slice(&rec[..m as usize]);
                nl = m;
                habet = 1;
            }
            0 | 1 => {
                let name = if habet == 1 {
                    l[..(nl - 1) as usize].to_vec()
                } else {
                    h[..100].iter().take_while(|&&b| b != 0).copied().collect()
                };
                members.push(Member { dir: v == 1, name });
                habet = 0;
                nl = 0;
                let pad = unsafe { exs_saltus(m) };
                let skipped = io::copy(&mut (&mut r).take(pad), &mut io::sink())?;
                if skipped != pad {
                    return Err(Error::store(format!(
                        "payload tar stream ends mid-member at byte {}",
                        at + skipped
                    )));
                }
                at += pad;
            }
            other => {
                return Err(Error::store(format!(
                    "refusing to extract: tar header at byte {here} has {} (arca verdict {other})",
                    why(other)
                )))
            }
        }
    }
}
