//! Differential certification: Exsecutor's `potestas` (the C unit in
//! `potestas/`) against plugind's own policy functions, on a generated,
//! deterministic corpus. Zero disagreements is the pass condition, and every
//! family has a floor so a run that compared nothing cannot pass.
//!
//! The Rust side is plugind's source itself: the two modules below are
//! path-included verbatim from `host/src/`, so `check_id`, `Policy::authorize`,
//! `Manifest::validate` and `Manifest::wx_enforced` are the functions plugind
//! runs, not copies. Their own `#[cfg(test)]` suites compile and run here
//! too, which is harmless and checks the inclusion is faithful.
//!
//! What each family compares:
//!
//! - ids: `manifest::check_id` against `titulus_iudica`, over every byte
//!   value, every Unicode scalar value, every length to 130, and a seeded
//!   fuzz. A byte string that is not UTF-8 cannot reach `check_id` (it takes
//!   a `&str`; manifests and control requests are parsed as UTF-8 first), so
//!   for those the unit is only required to refuse.
//! - paths: `Policy::authorize` with one forbidden prefix and one fs cap,
//!   against `tangit`. authorize reports HOW a cap overlaps; `overlaps`
//!   tries the unresolved pair before any canonicalised one, so its answer
//!   is "is under" / "contains" exactly when the lexical half fires. A
//!   "resolves to ..." answer means the lexical half said no and the
//!   filesystem said yes -- the half that stays in Rust -- and is counted,
//!   not compared. Inputs are limited to 4096 bytes, the unit's buffer; past
//!   it the unit refuses (verdict 3), which is asserted separately.
//! - anchors: `Manifest::validate` on a manifest whose only questionable
//!   field is one fs cap, against `ancora`.
//! - W^X: all 4 x 3 tier x jit rows of `wx_enforced`, `grants_wx_to_plugin`
//!   and `uses_bwrap`, against `wx_cogitur`, `wx_conceditur`, `involucrum`;
//!   and the same rows evaluated from the Nix mirror (`wxEnforced`,
//!   `grantsWx`, `usesBwrap` in modules/plugins.nix) with nix-instantiate.
#![allow(dead_code)]

#[path = "../../host/src/manifest.rs"]
mod manifest;
#[path = "../../host/src/policy.rs"]
mod policy;

use std::collections::BTreeSet;

use manifest::{Caps, Jit, Manifest, Tier, Trust, SUPPORTED_ABI};
use policy::Policy;
use potestas_cert as exs;

const TIERS: [(u64, Tier, &str); 4] = [
    (0, Tier::Wasm, "wasm"),
    (1, Tier::Native, "native"),
    (2, Tier::Lua, "lua"),
    (3, Tier::Microvm, "microvm"),
];
const JITS: [(u64, Jit, &str); 3] = [
    (0, Jit::None, "none"),
    (1, Jit::Host, "host"),
    (2, Jit::SelfJit, "self"),
];

/// xorshift64*, fixed seed: the corpus is the same on every run.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn manifest(fs_read: Vec<String>) -> Manifest {
    Manifest {
        id: "cert".into(),
        version: "1".into(),
        tier: Tier::Wasm,
        jit: Jit::None,
        trust: Trust::Untrusted,
        entry: "x".into(),
        abi: SUPPORTED_ABI.into(),
        caps: Caps {
            fs_read,
            ..Caps::default()
        },
        meta: Default::default(),
    }
}

// ------------------------------------------------------------------ ids

/// check_id's verdict in the unit's codes. Its two messages are told apart
/// by the grammar each names; "1..=64" covers empty and too long alike, and
/// the length (which check_id tested) splits them.
fn rust_id(id: &str) -> u64 {
    match manifest::check_id(id) {
        Ok(()) => 0,
        Err(e) => {
            let m = e.to_string();
            if m.contains("must be 1..=64 characters") {
                if id.is_empty() {
                    1
                } else {
                    2
                }
            } else if m.contains("must be [A-Za-z0-9_-]+") {
                3
            } else {
                panic!("check_id said something this harness does not know: {m}")
            }
        }
    }
}

#[test]
fn ids_agree_with_check_id() {
    let mut corpus: Vec<Vec<u8>> = Vec::new();
    // plugind's own vectors (manifest.rs and registry.rs tests).
    for s in [
        "",
        "evil",
        "confused",
        "plain",
        "np",
        "jp",
        "dev",
        "caps",
        "esc",
        "t",
        "cert",
        "X.service.d/../../../../etc/systemd/system/sshd",
        "../x",
        "a b",
        "a\nUser=root",
        "never-installed",
    ] {
        corpus.push(s.as_bytes().to_vec());
    }
    corpus.push(b"a".repeat(64));
    corpus.push(b"a".repeat(65));
    // Every byte value, alone, inside, and at both length edges.
    for b in 0u8..=255 {
        corpus.push(vec![b]);
        corpus.push(vec![b'a', b, b'z']);
        corpus.push(vec![b; 64]);
        corpus.push(vec![b; 65]);
    }
    // Every length to 130, clean and with one bad byte at each position.
    for n in 0..=130usize {
        corpus.push(b"aZ9_-".iter().cycle().take(n).copied().collect());
        for k in (0..n).step_by(7) {
            let mut v: Vec<u8> = b"Az0-_".iter().cycle().take(n).copied().collect();
            v[k] = b'.';
            corpus.push(v);
        }
    }
    // Seeded fuzz over a mixed alphabet, lengths 0..=70.
    let alpha: Vec<&[u8]> = vec![
        b"a",
        b"Z",
        b"0",
        b"9",
        b"_",
        b"-",
        b".",
        b"/",
        b" ",
        b"\n",
        b"@",
        b"[",
        b"`",
        b"{",
        b"\x00",
        b"\x7f",
        "é".as_bytes(),
        "ß".as_bytes(),
        "\u{2028}".as_bytes(),
        "😀".as_bytes(),
    ];
    let mut rng = Rng(0x706f_7465_7374_6173);
    for _ in 0..100_000 {
        let n = rng.below(71);
        let mut v = Vec::new();
        for _ in 0..n {
            // Mostly the grammar's own bytes, so long admitted ids occur.
            let t = if rng.below(4) == 0 {
                alpha[rng.below(alpha.len())]
            } else {
                alpha[rng.below(6)]
            };
            v.extend_from_slice(t);
        }
        corpus.push(v);
    }

    let mut compared = [0u64; 4];
    let mut non_utf8 = 0u64;
    let mut disagree = Vec::new();
    let mut judge = |v: &[u8]| {
        let e = exs::titulus_iudica(v);
        match std::str::from_utf8(v) {
            Ok(s) => {
                let r = rust_id(s);
                if r != e {
                    disagree.push(format!("{s:?}: rust {r}, exsecutor {e}"));
                }
                compared[r.min(3) as usize] += 1;
            }
            Err(_) => {
                // Unreachable for plugind; the unit must still refuse.
                if e == 0 {
                    disagree.push(format!("non-UTF-8 {v:?} admitted by exsecutor"));
                }
                non_utf8 += 1;
            }
        }
    };
    for v in &corpus {
        judge(v);
    }
    // Every Unicode scalar value, alone and after a valid prefix.
    let mut scalars = 0u64;
    for c in (0u32..=0x10ffff).filter_map(char::from_u32) {
        let mut buf = [0u8; 6];
        buf[0] = b'a';
        buf[1] = b'b';
        let l = c.encode_utf8(&mut buf[2..]).len();
        judge(&buf[2..2 + l]);
        judge(&buf[..2 + l]);
        scalars += 1;
    }

    let total: u64 = compared.iter().sum();
    println!(
        "ids: {total} compared (admitted {}, empty {}, too long {}, bad byte {}), \
         {scalars} scalar values x 2, {non_utf8} non-UTF-8 refused, {} disagreements",
        compared[0],
        compared[1],
        compared[2],
        compared[3],
        disagree.len()
    );
    assert!(
        disagree.is_empty(),
        "{} disagreements, first: {:#?}",
        disagree.len(),
        &disagree[..disagree.len().min(20)]
    );
    assert!(
        scalars == 1_112_064,
        "not every scalar value was tried: {scalars}"
    );
    assert!(total >= 2_000_000, "too few ids compared: {total}");
    assert!(
        compared[0] >= 5_000 && compared[2] >= 1_000 && compared[3] >= 100_000,
        "{compared:?}"
    );
    assert!(
        compared[1] >= 1 && non_utf8 >= 100,
        "{compared:?} {non_utf8}"
    );
}

// ---------------------------------------------------------------- paths

/// How `Policy::authorize` answered one (cap, forbidden) pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Rust {
    Admitted,
    Under,
    Contains,
    ResolvesUnder,
    ResolvesContaining,
}

const HOW: [(&str, Rust); 4] = [
    ("is under", Rust::Under),
    ("contains", Rust::Contains),
    ("resolves to a path under", Rust::ResolvesUnder),
    ("resolves to a path containing", Rust::ResolvesContaining),
];

fn rust_overlap(p: &str, f: &str) -> Rust {
    let mut pol = Policy::default();
    pol.forbidden_paths = vec![f.to_string()];
    let m = manifest(vec![p.to_string()]);
    let Err(e) = pol.authorize(&m) else {
        return Rust::Admitted;
    };
    let msg = e.to_string();
    // The message is rebuilt byte for byte for each possible `how`, so no
    // path spelling can make one answer look like another.
    for (how, r) in HOW {
        let want = format!(
            "plugin {} requests access to {p:?}, which {how} the forbidden prefix {f:?}",
            m.id
        );
        if msg == want {
            return r;
        }
    }
    panic!("authorize refused {p:?} / {f:?} for a reason this harness does not know: {msg}");
}

fn joins(comps: &[&str], depth: usize) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut layer = vec![Vec::<&str>::new()];
    for _ in 0..depth {
        let mut next = Vec::new();
        for t in &layer {
            for c in comps {
                let mut u = t.clone();
                u.push(c);
                next.push(u);
            }
        }
        out.extend(next.iter().map(|t| t.join("/")));
        layer = next;
    }
    out
}

fn spellings(leads: &[&str], tails: &[String]) -> BTreeSet<String> {
    let mut s = BTreeSet::new();
    for l in leads {
        for t in tails {
            s.insert(format!("{l}{t}"));
            s.insert(format!("{l}{t}/"));
        }
    }
    s
}

const PLUGIND_CAPS: [&str; 27] = [
    // policy.rs tests: is_under, proc, ancestors, relatives, siblings.
    "/home/asher/.ssh",
    "//home/asher/.ssh",
    "/./home/asher/.ssh",
    "/homework/notes",
    "/home",
    "/tmp/../home",
    "proc",
    "proc/self/mem",
    "etc/shadow",
    "home/asher/.ssh",
    "$STATE",
    "//proc/self/mem",
    "/opt/plugin/data",
    "/proc",
    "/proc/self/mem",
    "/proc/1/mem",
    "//proc/cpuinfo",
    "/",
    "/etc",
    "/run",
    "/var/lib",
    "//",
    "/./etc",
    "/srv/audio",
    "/etc-like",
    "$STATE/x",
    "/run/secrets/guitar-key",
];

#[test]
fn paths_agree_with_authorize() {
    let comps = [
        "",
        ".",
        "..",
        "proc",
        "etc",
        "secrets",
        "secrets.d",
        "home",
        "homework",
    ];
    let mut caps = spellings(&["/", "//", "/./", "", "./", "$STATE/"], &joins(&comps, 3));
    caps.extend(PLUGIND_CAPS.iter().map(|s| s.to_string()));
    let mut forbs = spellings(&["/", "", "./", "$STATE/"], &joins(&comps, 2));
    forbs.extend(Policy::default().forbidden_paths);
    forbs.extend(["/anything", "/does/not/matter", "/run/secrets", "/var/run"].map(String::from));

    let mut pairs = 0u64;
    let mut by = [0u64; 3];
    let mut resolved = 0u64;
    let mut disagree = Vec::new();
    let mut compare = |p: &str, f: &str| {
        let e = exs::tangit(p.as_bytes(), f.as_bytes());
        let r = rust_overlap(p, f);
        let ok = match (e, r) {
            (1, Rust::Under) | (2, Rust::Contains) => true,
            (0, Rust::Admitted) => true,
            (0, Rust::ResolvesUnder | Rust::ResolvesContaining) => {
                resolved += 1;
                true
            }
            _ => false,
        };
        if ok {
            by[e as usize] += 1;
        } else {
            disagree.push(format!("tangit({p:?}, {f:?}) = {e}, authorize: {r:?}"));
        }
        pairs += 1;
    };
    for p in &caps {
        for f in &forbs {
            compare(p, f);
        }
    }
    // Seeded fuzz over tokens, both sides.
    let toks = [
        "/", "/", "/", ".", "..", "$STATE", "$CONFIG", "$", "proc", "home", "homework", "a", "é",
        "\u{0}", "...", ".a",
    ];
    let mut rng = Rng(0x7061_7468_7320_2020);
    let tok = |rng: &mut Rng| {
        let n = rng.below(9);
        (0..n)
            .map(|_| toks[rng.below(toks.len())])
            .collect::<String>()
    };
    for _ in 0..300_000 {
        let (p, f) = (tok(&mut rng), tok(&mut rng));
        compare(&p, &f);
    }

    println!(
        "paths: {} pairs ({} caps x {} forbidden + 300000 fuzz): disjoint {}, under {}, \
         contains {}; {resolved} of the disjoint refused by Rust's symlink half; {} disagreements",
        pairs,
        caps.len(),
        forbs.len(),
        by[0],
        by[1],
        by[2],
        disagree.len()
    );
    assert!(
        disagree.is_empty(),
        "{} disagreements, first: {:#?}",
        disagree.len(),
        &disagree[..disagree.len().min(20)]
    );
    assert!(pairs >= 5_000_000, "too few pairs: {pairs}");
    for (i, n) in by.iter().enumerate() {
        assert!(*n >= 100_000, "verdict {i} occurred only {n} times");
    }
}

/// Past the unit's 4096-byte buffer the unit refuses whatever Rust says.
/// Not a disagreement in the compared domain: it is the unit's stated
/// narrowing, and Landlock cannot open such a path anyway (PATH_MAX).
#[test]
fn overlong_spellings_are_refused() {
    let long = format!("/srv/{}", "a".repeat(5000));
    assert_eq!(exs::tangit(long.as_bytes(), b"/proc"), 3);
    assert_eq!(exs::tangit(b"/srv", long.as_bytes()), 3);
    assert_eq!(
        rust_overlap(&long, "/proc"),
        Rust::Admitted,
        "Rust admits it lexically"
    );
    let edge = format!("/srv/{}", "a".repeat(4096 - 5));
    assert_eq!(edge.len(), 4096);
    assert_eq!(exs::tangit(edge.as_bytes(), b"/proc"), 0);
    assert_eq!(rust_overlap(&edge, "/proc"), Rust::Admitted);
}

// -------------------------------------------------------------- anchors

fn rust_anchor(cap: &str) -> u64 {
    match manifest(vec![cap.to_string()]).validate() {
        Ok(()) => 1,
        Err(e) => {
            let m = e.to_string();
            assert!(
                m.starts_with("fs capability"),
                "validate refused {cap:?} for another reason: {m}"
            );
            0
        }
    }
}

#[test]
fn anchors_agree_with_validate() {
    let comps = ["", ".", "..", "proc", "etc", "home"];
    let mut corpus = spellings(
        &[
            "/",
            "//",
            "",
            "./",
            "$",
            "$STATE",
            "$STATE/",
            "$CONFIG",
            "$STORE",
            "$STAT",
            "$CONFI",
            "$STOR",
            "$state",
            "%STATE",
            "$HOME",
            "$STATEX",
            "$STORE$CONFIG",
            "S",
            "é",
        ],
        &joins(&comps, 2),
    );
    let mut rng = Rng(0x616e_636f_7261_2020);
    let toks = [
        "$", "S", "T", "A", "E", "O", "R", "C", "N", "F", "I", "G", "/", ".", "x",
    ];
    for _ in 0..200_000 {
        let n = rng.below(10);
        corpus.insert((0..n).map(|_| toks[rng.below(toks.len())]).collect());
    }
    let mut by = [0u64; 2];
    let mut disagree = Vec::new();
    for cap in &corpus {
        let (e, r) = (exs::ancora(cap.as_bytes()), rust_anchor(cap));
        if e == r {
            by[e as usize] += 1;
        } else {
            disagree.push(format!("ancora({cap:?}) = {e}, validate: {r}"));
        }
    }
    println!(
        "anchors: {} caps: refused {}, anchored {}; {} disagreements",
        corpus.len(),
        by[0],
        by[1],
        disagree.len()
    );
    assert!(
        disagree.is_empty(),
        "{:#?}",
        &disagree[..disagree.len().min(20)]
    );
    assert!(by[0] >= 10_000 && by[1] >= 1_000, "{by:?}");
}

// ------------------------------------------------------------------ W^X

fn rust_row(tier: Tier, jit: Jit) -> (u64, u64, u64) {
    let mut m = manifest(vec![]);
    m.tier = tier;
    m.jit = jit;
    (
        m.wx_enforced() as u64,
        m.grants_wx_to_plugin() as u64,
        m.uses_bwrap() as u64,
    )
}

#[test]
fn wx_agrees_with_the_manifest() {
    let mut rows = 0;
    for (t, tier, tn) in TIERS {
        for (j, jit, jn) in JITS {
            let r = rust_row(tier, jit);
            let e = (
                exs::wx_cogitur(t, j),
                exs::wx_conceditur(t, j),
                exs::involucrum(t),
            );
            assert_eq!(e, r, "{tn}/{jn}: (wx_enforced, grants_wx, uses_bwrap)");
            rows += 1;
        }
    }
    // Codes outside the enums are the unit's "unknown", never a yes or no.
    for (t, j) in [(4, 0), (0, 3), (u64::MAX, 2), (1, u64::MAX)] {
        assert_eq!(exs::wx_cogitur(t, j), 2);
        assert_eq!(exs::wx_conceditur(t, j), 2);
    }
    assert_eq!(exs::involucrum(4), 2);
    println!("wx: {rows} tier x jit rows agree (wx_enforced, grants_wx_to_plugin, uses_bwrap)");
    assert_eq!(rows, 12);
}

/// One `name = ...;` binding from plugins.nix, from its first line to the
/// first line that ends the binding. The text is evaluated as written.
fn nix_binding(src: &str, name: &str) -> String {
    let head = format!("  {name} = ");
    let start = src
        .find(&head)
        .unwrap_or_else(|| panic!("plugins.nix no longer binds {name}"));
    let rest = &src[start..];
    let end = rest
        .find(";\n")
        .unwrap_or_else(|| panic!("{name}: no terminating ';'"));
    rest[..end + 1].to_string()
}

/// The Nix mirror, evaluated. Needs nix-instantiate; set
/// POTESTAS_SKIP_NIX=1 to skip it on purpose (the skip is printed). Absent
/// nix without that variable is a failure, not a pass.
#[test]
fn wx_agrees_with_the_nix_mirror() {
    if std::env::var_os("POTESTAS_SKIP_NIX").is_some() {
        println!("nix mirror: SKIPPED (POTESTAS_SKIP_NIX set) -- not compared");
        return;
    }
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../modules/plugins.nix");
    let src = std::fs::read_to_string(path).expect("read modules/plugins.nix");
    let bindings: String = ["bwrapTiers", "usesBwrap", "wxEnforced", "grantsWx"]
        .iter()
        .map(|n| nix_binding(&src, n) + "\n")
        .collect();
    let tiers = TIERS.map(|(_, _, n)| format!("\"{n}\"")).join(" ");
    let jits = JITS.map(|(_, _, n)| format!("\"{n}\"")).join(" ");
    let expr = format!(
        "let\n{bindings}in builtins.concatMap (t: map (j: let p = {{ tier = t; jit = j; }}; in \
         [ t j (wxEnforced p) (grantsWx p) (usesBwrap t) ]) [ {jits} ]) [ {tiers} ]"
    );
    let out = std::process::Command::new("nix-instantiate")
        .args(["--eval", "--strict", "--json", "-E", &expr])
        .output()
        .expect("nix-instantiate is not runnable; set POTESTAS_SKIP_NIX=1 to skip this check on purpose");
    assert!(
        out.status.success(),
        "nix-instantiate failed:\n{}\n{expr}",
        String::from_utf8_lossy(&out.stderr)
    );
    let rows: Vec<(String, String, bool, bool, bool)> =
        serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(rows.len(), 12, "{rows:?}");
    for (tn, jn, wx, grants, bwrap) in rows {
        let (t, tier, _) = TIERS.into_iter().find(|x| x.2 == tn).unwrap();
        let (j, jit, _) = JITS.into_iter().find(|x| x.2 == jn).unwrap();
        let nix = (wx as u64, grants as u64, bwrap as u64);
        assert_eq!(nix, rust_row(tier, jit), "{tn}/{jn}: Nix vs Rust");
        let e = (
            exs::wx_cogitur(t, j),
            exs::wx_conceditur(t, j),
            exs::involucrum(t),
        );
        assert_eq!(nix, e, "{tn}/{jn}: Nix vs Exsecutor");
    }
    println!("nix mirror: 12 rows of wxEnforced/grantsWx/usesBwrap agree with Rust and Exsecutor");
}
