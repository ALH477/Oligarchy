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
   │   3. peers         LAN HTTP or BitTorrent —              │
   │                    fetched, verified IN FULL, served     │
   │   4. upstream      decompressed, streamed w/ lookahead,  │
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
hash-checked by `nix-daemon` afterwards. With `servePackages` and
`trustedPublicKeys` empty — the default — peers supply **bytes and nothing else**
(no metadata, no signatures, no policy) and removing every peer changes
throughput but not correctness.

Setting either one changes that, and the amended rule is:

> **P2P still provides availability. Trust comes from keys, and adding a key is
> an operator decision made in the flake — nothing the transport can do.**

See *Seeding what this host built*, below. A peer still cannot cause its own key
to be trusted.

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

## Seeding what this host built

Through stage 4 a host could only seed what it had **fetched**. The peer surface
answers `GET /peer/v1/narinfo/<hp>` from disk only, and a receiver cannot verify
a NAR without the signed `NarHash` that lives in a narinfo — so a locally-built
path, which has a narinfo nowhere, could never be handed to anyone. A machine
that *substituted* a rebuild was a good seeder and a machine that *compiled* it
was useless. For a distro whose point is custom kernels and plugin artifacts
that exist in no public cache, that is backwards.

```nix
# on the BUILDER
custom.p2pCache = {
  servePackages  = [ pkgs.my-thing ];
  signingKeyFile = "/var/lib/oligarchy/p2p/cache.sec";
  peer.enable    = true;
};

# on the CONSUMER — separate, and deliberate
custom.p2pCache.trustedPublicKeys = [ "nixos-p2p-1:kBnLtBEr..." ];
```

```console
nix key generate-secret --key-name "$(hostname)-p2p-1" > /var/lib/oligarchy/p2p/cache.sec
chmod 0400 /var/lib/oligarchy/p2p/cache.sec
nix key convert-secret-to-public < /var/lib/oligarchy/p2p/cache.sec   # paste into peers
```

Five things about this are deliberate.

**The key never goes near the daemon.** Minting a narinfo needs the signing key
*and* the Nix database, and `oligarchy-p2pd` is denied both on purpose — its
`RestrictAddressFamilies` has no `AF_UNIX`, so it cannot open the nix-daemon
socket at all. So minting runs in a separate root oneshot,
`oligarchy-p2p-seed.service`, and `signingKeyFile` is not even named in
`config.json`, which is the file the daemon reads. The process that parses
hostile input from the network is not the process that holds the key. Folding
the two units together would dissolve the only mitigation there is.

**Nix does the crypto.** `nix store sign` signs and `nix path-info --sigs` reads
the signature back, so `ValidPathInfo::fingerprint` is never reimplemented here
and cannot drift from what Nix will actually verify. There is no ed25519 in this
crate. (`--json-format 1` exists only on Determinate Nix 3.x — on nixpkgs' Nix
it is a hard `unrecognised flag` — so `declared.rs` tries it and falls back.)

**Only paths with no signature at all are signed.** Those are exactly the ones
this host built. Signing the rest of a declared closure would put this host's
name on glibc — permanently, in `/nix/var/nix/db`, where it travels through
`nix copy` and ssh-ng and not merely through this adapter — for no gain. It also
keeps the declared tier from shadowing anything, since a minted narinfo outranks
the fetched one forever.

**`declared/` is never evicted.** A fetched narinfo that gets swept can be
fetched again; a minted one cannot, because nothing upstream has heard of the
path. Evicting it would silently unpublish a package while the daemon carried on
looking healthy.

**`trustedPublicKeys` is the setting with teeth, and it is not scoped.** Nix has
no way to restrict a key to a set of store paths. Trusting a seeder's key trusts
that host for *every* path this machine will ever substitute, and `Priority: 30`
puts the adapter ahead of cache.nixos.org for all of them. For an
input-addressed path the signature is the entire trust anchor — the adapter's
own `NarHash` check does not help, because whoever controls the bytes controls
the narinfo too. Trust hosts you administer, on networks you control.

## Bounding what a peer key may vouch for

Trusting a peer's key is the one thing in this subsystem that extends trust, and
**Nix cannot scope a signing key to a set of store paths.** Once a key is in
`trusted-public-keys` it vouches for everything, and this adapter sits at
`Priority: 30` — ahead of cache.nixos.org for every path. A compromised seeder
could mint a narinfo for glibc, sign it, and be believed.

Nix cannot bound that. This adapter can, because every narinfo a peer supplies
passes through it:

```nix
custom.p2pCache = {
  trustedPublicKeys = [ "nixos-p2p-1:kBn..." ];
  acceptFromPeers   = [ "my-thing" ];    # mandatory; [ "*" ] is the opt-out
};
```

Three things about the implementation are load-bearing.

**The rule asks whether a peer key is involved, not whether a non-peer key is.**
The intuitive formulation — "it carries a `cache.nixos.org-1` signature, so
upstream vouched for it" — fails open. `Sig:` lines are attacker-supplied text,
and `ValidPathInfo::checkSignatures` *counts* signatures that verify rather than
requiring all of them to. So appending one junk `Sig: cache.nixos.org-1:AAAA`
makes a narinfo look upstream-vouched while the real peer signature still gets
the path registered. Distinguishing forged from real means implementing Ed25519,
which this crate deliberately does not do — Nix does the crypto. Asking "is a
peer key involved at all" needs no verification and cannot be gamed by *adding*
signatures.

**A version suffix has to start with a digit.** Matching `entry + "-"` is not a
version test: it lets `glibc` reach `glibc-locales` and `linux` reach
`linux-firmware`, both of which are in every system closure. Nix splits a name
into pname and version at the first `-` followed by a non-letter, and so does
`scope::in_scope`.

**Four enforcement points, each closing something the others cannot.**
`LanTransport::narinfo` returns the first parseable answer and stops, so the
check has to be *in the loop* — otherwise one hostile peer answering
out-of-scope denies a path while the honest peers below it are never asked.
`resolve`'s peer arm refuses before persisting. `resolve`'s disk arm re-checks,
because an entry that reached `narinfo/` is durable and would be served forever
without the transport being consulted again. And `peer.rs` gates all four peer
routes, so a host with a lax scope does not relay refused metadata onward and
become a second hop into hosts that refused it directly.

What this does **not** cover: the key stays in `trusted-public-keys` globally,
so anything bypassing the adapter — a peer added directly to `substituters`, a
`nix copy --from`, a remote builder — is unscoped. And the check now runs inside
`oligarchy-p2pd`, which this design treats as hostile, so a daemon compromise is
a scope bypass in a way it was not before. The clean version is the split
already used for signing; it is recorded as a gap, not built.

## Proving it, rather than reading it

Every failure this subsystem has shipped had one shape: the broken state was
indistinguishable from the working one. A declared tier that never populated, a
`provide` never wired, a seed run that unpublished what the last one published,
a `ConditionPathExists` in the wrong systemd section. Each time the daemon
answered, the unit was active, the journal read normally — and a passing gate
could not tell either.

```console
$ oligarchy-p2p-selftest
  PASS  bind_is_loopback                127.0.0.1
  PASS  no_trusted_in_nix_conf          2 file(s) clean
  PASS  daemon_answers                  http://127.0.0.1:5111 serving /nix/store
  PASS  declared_refuses_a_write        refused as uid 992 (permission denied)
  PASS  declared_narinfos_are_coherent  1 published, all coherent
  PASS  round_trip                      xk1n…: 232 bytes, sha256:0k8c…
  PASS  peer_scope_is_bounded           1 peer key(s), scoped to: my-thing
  SKIP  peers_reachable                 no peers configured
```

It runs as a **unit** sharing the daemon's sandbox verbatim, not as a bare
command. `declared_refuses_a_write` proves `ReadOnlyPaths` is in effect by
attempting a write — which only means anything inside the confinement it is
testing, and from a root shell would succeed and report a false PASS. There it
reports a loud SKIP instead.

Two rules, taken from the MCP workspace's `mcp_self_audit`: **a check that
inspected nothing is a FAIL**, and **a skipped check is reported, never
omitted**. "Zero declared narinfos, all valid" is the exact sentence that hid a
real bug.

`nix build .#p2p-selftest` asserts it passes — and then breaks each guarantee in
turn and asserts it *fails*. A selftest that cannot fail is the same mistake as
a gate that cannot fail.

## Two listeners, and why

The substituter surface is **loopback-only** and will proxy anything its
upstreams hold. Exposing it to a network would publish an open cache proxy for
the whole of cache.nixos.org.

So peers get a **separate listener** with a deliberately smaller route set
(`custom.p2pCache.peer`, default off, port 5112). It answers one question — *do
you already have this?* — never triggers an upstream fetch on a peer's behalf,
and serves nothing it has not verified. Reach is per-interface via
`peer.openFirewall`, which is empty by default, so enabling the surface does not
by itself expose anything.

Peer addresses are restricted to private ranges **in code**: RFC1918,
CGNAT/tailnet, link-local. That is the same set `strict-egress.nix` already
allows statically, which is why a LAN swarm needs no firewall change on the
egress side — and why accepting a routable peer would quietly step outside a
control the operator thinks they have.

Peers supply metadata as well as bytes, and must: a NAR cannot be verified
without the signed `NarHash`, and that lives in a narinfo. What comes back is
upstream's narinfo verbatim — signature intact — with a re-check that it names
the path that was asked for. Nix still verifies the signature. We are a courier.

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
| `host/src/cache.rs` | The artifact cache: temp+rename, LRU eviction, narinfo persistence, and the non-evictable `declared/` tier |
| `host/src/declared.rs` | Minting and signing narinfo for locally-built paths; runs only from the `seed` subcommand |
| `host/src/scope.rs` | What a peer key may vouch for — the only place in the crate that knows what a key is |
| `host/src/selftest.rs` | Assertions the daemon makes about itself, and why each one cannot be answered by reading config |
| `host/src/resolve.rs` | The ordered source chain and the upstream fetch pipeline |
| `host/src/decompress.rs` | xz / zstd, statically linked, no system libraries |
| `host/src/nixstore.rs` | `nix-store --dump`, and why it is the old CLI |
| `host/src/peer.rs` | The peer surface: the three rules that keep it from becoming a proxy |
| `host/src/transport/mod.rs` | The `ArtifactTransport` trait and `NullTransport` |
| `host/src/transport/lan.rs` | LAN peers over plain HTTP, and the private-range check |
| `host/src/transport/bittorrent.rs` | The swarm, and why discovery is not BitTorrent's |
| `host/src/torrent.rs` | Canonical torrent construction — all of it is wire contract |
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
nix build .#p2p-two-node
nix build .#p2p-swarm
nix build .#p2p-local-signing        # a host seeds what it BUILT; refused without the key
nix build .#p2p-peer-scope           # a peer key vouches only for the packages you named
nix build .#p2p-selftest             # the daemon's assertions, and that each fails when broken
nix build .#p2p-no-peer-fallback
```

By hand, against the real cache:

```console
oligarchy-p2pd --config ./config.json check
oligarchy-p2pd --config ./config.json daemon &
curl -s http://127.0.0.1:5111/nix-cache-info
diff <(curl -s https://cache.nixos.org/<hp>.narinfo) \
     <(curl -s http://127.0.0.1:5111/<hp>.narinfo)   # only URL should differ
```

## BitTorrent, and what it does not buy you

`transport = "bittorrent"` pulls pieces from every peer at once. That is the
only thing it buys, so it is worth having from roughly three peers upward and
buys nothing at two — `transport = "lan"` stays the right answer for a
two-machine site.

Discovery is **not** BitTorrent's: no DHT, no trackers, no PEX. Peers and
infohashes both come from the peer surface, because every address dialled has to
come from the private-range peer list for this to work under `strict-egress`
unchanged.

And it adds nothing to the trust story. Piece hashes come from a `.torrent` an
untrusted peer handed us, so they are exactly as trustworthy as that peer. What
makes a fetch safe is what always did: the completed file is hashed against the
signed `NarHash` before it is given a name.

Artifacts below `swarm.minArtifactSize` (4 MiB by default) never enter a swarm.
That number is measured, not guessed — the median NAR in this repo's own closure
is **355 KiB**, and 4 MiB puts 16.4% of paths in swarms while still covering
96.0% of the bytes.

## Three bugs worth knowing about

### A transport method that blocked

`Handle::block_on` inside a transport is wrong in two different ways, and both
shipped. From the async request handler it panics outright — *Cannot start a
runtime from within a runtime* — on every store hit. Moving it to
`spawn_blocking` traded that for something worse: the task simply never
returned. No panic, no error, no log line, and a daemon that looked entirely
healthy while seeding nothing.

`provide` and `remove` now spawn and return, and the trait says **must not
block**. The cost is that `remove` no longer beats eviction to the file, which
librqbit survives.


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
