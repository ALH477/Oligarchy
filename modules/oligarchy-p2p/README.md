# oligarchy-p2p — the P2P substituter

A local HTTP binary-cache adapter. Nix talks to it as an ordinary substituter;
it obtains NARs from a peer transport, an upstream cache, or a local artifact
cache, and hands them back through the standard protocol.

**Nix is not patched, and its trust model is not weakened.**

```
        nix build                     [root, via nix-daemon]
            │  substituters = [ "http://127.0.0.1:5111" "https://cache.nixos.org" ]
            ▼  ── no ?trusted=1, asserted at eval AND in a VM gate ──
   ┌──────────────────────────────────────────────────────────┐
   │ oligarchy-p2pd        user oligarchy-p2p, unprivileged   │
   │   GET /nix-cache-info    StoreDir / WantMassQuery / Prio │
   │   GET /<hash>.narinfo    proxied, only URL rewritten     │
   │   GET /nar/<hp>/<name>   the body                        │
   │            │                                             │
   │            ▼  ordered, first success wins                │
   │   1. local cache   verified IN FULL, then served         │
   │   2. local store   verified IN FULL, then served         │
   │   3. upstream      decompressed, streamed w/ lookahead,  │
   │                    teed into the cache                   │
   │            │                                             │
   │            ▼  EVERY path converges here, no bypass       │
   │   verify: SHA-256 against the SIGNED NarHash + byte cap  │
   └──────────────────────────────────────────────────────────┘
```

## The problem this solves

Rebuilding one host on a multi-machine site makes every other host re-download
the same closure from `cache.nixos.org`. The bytes are already on the LAN. They
are also already content-addressed and signed, so fetching them from a peer
costs nothing in trust — provided the peer is never allowed to *become* trust.

## The design in one rule

> **P2P provides availability. Nix provides trust.**

The adapter is on the untrusted side of the boundary and is built as if hostile.
It runs unprivileged, cannot write the store, holds no keys, and nobody is in
`nix.settings.trusted-users`. Every path it serves is signature-checked and
hash-checked by `nix-daemon` afterwards. Peers supply **bytes and nothing else**
— no metadata, no signatures, no policy.

Three facts make this work, all read from the Nix source and reproduced against
a real store (see `docs/p2p-substituter-roadmap.md` §3):

- **The signature covers `StorePath`, `NarHash`, `NarSize` and `References`.**
  `URL`, `Compression`, `FileHash` and `FileSize` are unsigned, so rewriting the
  transport fields is legal and rewriting anything else is not. That rule is
  enforced, not documented: `NarInfo::set` asserts against `SIGNED_FIELDS`.
- **Nix re-verifies `NarHash` while restoring the NAR.** A bad body cannot
  become a valid store path no matter what we do.
- **Nix imposes no upper bound on what a substituter delivers.** `FileSize` is
  never checked and trailing bytes are silently discarded — serving 64 MiB for a
  279 KiB claim succeeds. Our byte cap is the only thing that stops it.

## The one mistake that would undo all of it

`?trusted=1` on a substituter URI makes Nix accept paths signed by no trusted
key. Silently: exit 0, no warning, no diagnostic, no runtime signal of any kind.
Reproduced on real hardware with `require-sigs true` set.

So the module carries a hard assertion scanning *every* substituter on the host
for `trusted=`, the daemon refuses an upstream carrying it, and
`p2p-signature-refusal` greps the generated `nix.conf`. Three places, because
the thing they prevent is invisible.

## The canonical artifact is the uncompressed NAR

The adapter serves `Compression: none`, with `FileHash = NarHash` and
`FileSize = NarSize`, at `nar/<hashpart>/<narhash>.nar`.

That looks like a pessimisation and is actually the thing that makes the whole
design hold. Two reasons:

- **Every field it emits becomes a function of signed, immutable data.** Nix
  caches a narinfo for thirty days. Stage 1 keyed the URL on `FileHash` plus a
  compression suffix — both describing bytes *upstream* controls — and when
  cache.nixos.org moved `hello` from xz to zstd, every cached narinfo named a
  NAR the adapter refused to serve. It 404'd until the TTL expired.
- **No unsigned field is left anywhere in the trust path.** The bytes on the
  wire are exactly the bytes the upstream signature covers.

It is also what makes a peer swarm possible at all: `nix-store --dump` is
byte-canonical on every machine, so a locally-built path and a downloaded one
produce the identical artifact. A compressed one would not.

## Use it

```nix
custom.p2pCache = {
  enable = true;
  upstreams = [ "https://cache.nixos.org" ];
};
```

`enable` defaults to **false**, and at stage 1 it should stay that way — see the
roadmap's Known gap 1.

## Layout

| Path | Purpose |
|---|---|
| `host/src/main.rs` | CLI (`daemon`, `check`, `status`) and startup preflight |
| `host/src/config.rs` | `/etc/oligarchy/p2p/config.json`, `deny_unknown_fields` |
| `host/src/http.rs` | The binary cache protocol surface; hand-rolled routing |
| `host/src/narinfo.rs` | Loss-free narinfo round-trip; the only mutator is `rewrite_transport` |
| `host/src/nixhash.rs` | Nix base32 — **not** RFC 4648; own alphabet, reversed walk |
| `host/src/route.rs` | The URL space, and why a NAR request can re-find its narinfo |
| `host/src/verify.rs` | The verification funnel and `verifying_stream` |
| `host/src/upstream.rs` | Upstream caches, rustls only |
| `host/src/cache.rs` | The artifact cache: temp+rename, LRU eviction, narinfo persistence |
| `host/src/resolve.rs` | The ordered source chain and the upstream fetch pipeline |
| `host/src/decompress.rs` | xz / zstd, statically linked, no system libraries |
| `host/src/nixstore.rs` | `nix-store --dump`, and why it is the old CLI |
| `modules/p2p-cache.nix` | `custom.p2pCache.*`, the unit, the assertions |
| `pkgs/oligarchy-p2pd/default.nix` | `buildInputs = [ ]`, and that is load-bearing |

## Verify it actually works

```console
nix build .#oligarchy-p2pd          # 32 unit tests run in checkPhase
nix flake check                     # + nixpkgs-fmt

# From the repo root — real VMs, slow, run on demand:
nix build .#p2p-substituter-protocol
nix build .#p2p-signature-refusal
nix build .#p2p-artifact-cache
```

By hand, against the real cache:

```console
oligarchy-p2pd --config ./config.json check
oligarchy-p2pd --config ./config.json daemon &
curl -s http://127.0.0.1:5111/nix-cache-info
diff <(curl -s https://cache.nixos.org/<hp>.narinfo) \
     <(curl -s http://127.0.0.1:5111/<hp>.narinfo)   # only URL should differ
```

## Two bugs worth knowing about

### A cache that only worked when you did not need it

A NAR request resolves its narinfo before it can do anything else, and that
resolution went to the network. So with the artifact cache fully populated and
upstream unreachable, every request returned 404 — the exact situation the cache
exists for. Metadata is now persisted to disk alongside the artifacts, under its
own eviction budget so the two can never compete for space.

Found by pulling the network out and asking for a path that was definitely
cached. It would not have shown up in any unit test, because every unit test had
a working upstream.

### A verification that never ran

The digest check did not run for the first version of this daemon, and every
unit test passed anyway.

`Body::from_stream` with `Content-Length` set means the HTTP layer stops polling
the body once it has that many bytes and drops the generator — so a check
written *after* the read loop never executes. A length-preserving corruption was
served with HTTP 200 and nothing in the log. The `Verifier` was correct in
isolation; the integration was not.

`verifying_stream` fixes it by withholding the final chunk until `finish()` has
passed, so the response cannot *complete* unless the digest matched.
`a_corrupt_body_never_completes` is the regression test, and
`p2p-signature-refusal` asserts the refusal appears in the journal — because a
test that only checked "the build failed" would have passed against the broken
version too.
