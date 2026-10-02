//! Safe wrappers over the Exsecutor unit `potestas/potestas.gen.c`.
//!
//! The unit is pure (Exsecutor spec §4.1 rule 6): it reads the buffers it is
//! given and nothing else. Its C face is `examples/potestas/potestas.h`
//! upstream. An id buffer is 64 bytes and a path buffer 4096; the wrappers
//! copy into zeroed buffers of exactly that size and pass the true length,
//! which the unit judges before it reads a byte, so a longer input never
//! reaches past the buffer.

use std::os::raw::c_uchar;

extern "C" {
    fn exs_titulus_iudica(b: *mut c_uchar, n: u64) -> u64;
    fn exs_subest(p: *mut c_uchar, np: u64, f: *mut c_uchar, nf: u64) -> u64;
    fn exs_tangit(p: *mut c_uchar, np: u64, f: *mut c_uchar, nf: u64) -> u64;
    fn exs_ancora(p: *mut c_uchar, n: u64) -> u64;
    fn exs_involucrum(tier: u64) -> u64;
    fn exs_wx_cogitur(tier: u64, jit: u64) -> u64;
    fn exs_wx_conceditur(tier: u64, jit: u64) -> u64;
}

pub const ID_BUF: usize = 64;
pub const PATH_BUF: usize = 4096;

fn fill<const N: usize>(s: &[u8]) -> Box<[u8; N]> {
    let mut b = Box::new([0u8; N]);
    let k = s.len().min(N);
    b[..k].copy_from_slice(&s[..k]);
    b
}

/// `manifest::check_id`: 0 admitted, 1 empty, 2 over 64 bytes, 3 a byte
/// outside `[A-Za-z0-9_-]`.
pub fn titulus_iudica(id: &[u8]) -> u64 {
    let mut b = fill::<ID_BUF>(id);
    unsafe { exs_titulus_iudica(b.as_mut_ptr(), id.len() as u64) }
}

/// `policy::is_under(p, f)`: 1 or 0.
pub fn subest(p: &[u8], f: &[u8]) -> u64 {
    let (mut bp, mut bf) = (fill::<PATH_BUF>(p), fill::<PATH_BUF>(f));
    unsafe {
        exs_subest(
            bp.as_mut_ptr(),
            p.len() as u64,
            bf.as_mut_ptr(),
            f.len() as u64,
        )
    }
}

/// The lexical half of `policy::overlaps(p, f)`: 0 disjoint, 1 under,
/// 2 contains, 3 a side longer than 4096 bytes (refuse).
pub fn tangit(p: &[u8], f: &[u8]) -> u64 {
    let (mut bp, mut bf) = (fill::<PATH_BUF>(p), fill::<PATH_BUF>(f));
    unsafe {
        exs_tangit(
            bp.as_mut_ptr(),
            p.len() as u64,
            bf.as_mut_ptr(),
            f.len() as u64,
        )
    }
}

/// `Manifest::validate`'s fs-capability anchor rule: 1 anchored, 0 refused.
pub fn ancora(p: &[u8]) -> u64 {
    let mut b = fill::<PATH_BUF>(p);
    unsafe { exs_ancora(b.as_mut_ptr(), p.len() as u64) }
}

/// Tier codes: 0 wasm, 1 native, 2 lua, 3 microvm. Jit: 0 none, 1 host,
/// 2 self. Each answers 1 yes, 0 no, 2 an unknown code.
pub fn involucrum(tier: u64) -> u64 {
    unsafe { exs_involucrum(tier) }
}
pub fn wx_cogitur(tier: u64, jit: u64) -> u64 {
    unsafe { exs_wx_cogitur(tier, jit) }
}
pub fn wx_conceditur(tier: u64, jit: u64) -> u64 {
    unsafe { exs_wx_conceditur(tier, jit) }
}
