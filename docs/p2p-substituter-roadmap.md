# P2P Substituter — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Stages 1-3 are landed and all four gates pass.
> Stage 1's narinfo posture was WRONG and stage 2 corrects it — read Known gap 1
> and §3.2 before changing anything about the URL or the compression. The module
> is wired on the workstation host and **disabled by default**; §6 "Current
> wiring" says why, and the reason changed at stage 2. Update the
> stage table and the changelog at the bottom as work proceeds. The design
> section above the line is the locked contract; the roadmap below the line is
> the work tracker.
>
> **Source:** `modules/oligarchy-p2p/` (self-contained sub-flake, consumed as
> `path:./modules/oligarchy-p2p`). Its own `README.md` is the design writeup;
> this file is Oligarchy's integration record.

## 1. Purpose

Let Nix obtain binary artifacts from peers instead of only from
`cache.nixos.org`, **without patching Nix and without weakening its trust
model.** The adapter presents a standard binary cache on loopback; Nix believes
it is talking to an ordinary HTTP substituter.

The value proposition committed to for v1 is narrow on purpose:

> On a multi-machine Oligarchy site, rebuilding one host should let the others
> fetch the new closure from it at LAN speed instead of re-downloading from
> upstream.

Not censorship resistance, not a public swarm. That framing is what makes the
security story tractable and the MVP shippable.

## 2. Trust

**P2P provides availability. Nix provides trust.** The adapter is on the
untrusted side of the boundary and is designed as if hostile: it runs
unprivileged, cannot write the store, holds no keys, and nobody is in
`nix.settings.trusted-users`. Every path it serves is signature-checked and
hash-checked by `nix-daemon` afterwards.

Peers are **sources of bytes and nothing else.** They supply no metadata, no
signatures and no policy. Removing every peer changes throughput and nothing
about correctness.

## 3. Verified facts about the binary cache protocol

Read from the Nix source in the store *and* reproduced against the Nix actually
installed here (Determinate Nix 3.16.0 / 2.33.3). These are load-bearing; the
design rests on them.

**Unknown `.narinfo` fields are ignored.** `NarInfo::NarInfo`
(`libstore/nar-info.cc`) is an if/else-if chain with no terminal `else`. But
`NarInfo::to_string` re-serialises only known fields, so a custom field does
**not** survive a round-trip through a Nix-managed cache. Extended metadata is
*compatible*, not *durable*.

**The signature covers five things.** `ValidPathInfo::fingerprint`
(`libstore/path-info.cc:44`):

```
"1;" + storePath + ";" + narHash + ";" + narSize + ";" + join(",", references)
```

`URL`, `Compression`, `FileHash`, `FileSize`, `Deriver` and `CA` are **unsigned**
and may be rewritten freely. This is the entire basis of the adapter: it
rewrites transport fields and nothing else.

**`FileHash` is never verified on the substitution path.**
`BinaryCacheStore::narFromPath` pipes the body straight through the
decompressor. The only integrity check is in `LocalStore::addToStore`
(`local-store.cc:1096`), which hashes the NAR during `restorePath`.

**`?trusted=1` on a substituter URI defeats everything.**
`StoreConfig::isTrusted` (`store-api.hh:182`) short-circuits the signature check
in both `substitution-goal.cc:155` and `local-store.cc:1062`.

**Content-addressed paths need no signature at all.**
`ValidPathInfo::checkSignatures` (`libstore/path-info.cc:120`) returns `maxSigs`
immediately when `isContentAddressed()` holds, without looking at a single
signature:

```cpp
size_t ValidPathInfo::checkSignatures(const StoreDirConfig & store, const PublicKeys & publicKeys) const
{
    if (isContentAddressed(store))
        return maxSigs;
    ...
```

This is sound rather than a hole: `isContentAddressed` recomputes the store path
from the declared `CA:` field and requires it to equal the actual path, so a
forged `CA:` line yields a different path and fails (loudly —
`"claims to be content-addressed but isn't"`). For such a path the trust anchor
is **the store path name itself**, not a signature.

Two consequences for this adapter. First, our `NarHash` check adds nothing
independent for a CA path — `NarHash` is unsigned there in effect, so an
attacker controlling both the narinfo and the bytes could serve a consistent
pair and we would pass it; what catches that is Nix re-deriving the CA hash in
`LocalStore::addToStore` and comparing it to the path name. The layering still
holds, we are simply not the layer doing the work. Second, and more practically:
**a test that strips a `Sig:` line from a CA path proves nothing.** `nix-store
--add` produces exactly such a path, and a version of `p2p-signature-refusal`
built on one passed while asserting nothing at all.

**Negative narinfo lookups are cached per-substituter for one hour**
(`narinfo-cache-negative-ttl`), and positive ones for **thirty days**
(`narinfo-cache-positive-ttl`). Both matter; see §5 and Known gap 1.

**Nix issues only `HEAD` and `GET`.** No `Range`, no conditional requests. The
`URL` field may be relative or absolute (`parseURLRelative`).

### 3.1 Stage 0 spikes — measured, not assumed

| # | Experiment | Result |
|---|---|---|
| 1 | `X-Oligarchy-*` fields added to a narinfo | **Accepted**, ignored |
| 2 | Rewrite `URL`/`Compression: none`/`FileHash`/`FileSize`, `Sig` untouched | **Accepted and registered valid** |
| 3 | `nix store dump-path` byte count vs `NarSize` | **279624 == 279624** |
| 4 | Flip one byte in NAR framing | Refused: `bad archive: unknown file type` |
| 5 | Flip one byte in file content | Refused: `hash mismatch importing path` |
| 6 | Path validity after 4 and 5 | **`is not valid`** — though partial dirs are left on disk |
| 7 | Strip the `Sig:` line | Refused: `lacks a signature by a trusted key` |
| 8 | `FileSize: 100` with a 279624-byte body | **Succeeded.** `FileSize` is advisory |
| 9 | 64 MiB of zeros appended to the NAR | **Succeeded, path valid.** Trailing bytes never read, never complained about |
| 10 | Unsigned narinfo, substituter **without** `?trusted=1` | Refused: `ignoring substitute … not signed by any of the keys` |
| 11 | Unsigned narinfo, substituter **with** `?trusted=1` | **ACCEPTED AND REGISTERED VALID.** Exit 0, no warning, no diagnostic |

**Spikes 8 and 9 together mean Nix imposes no upper bound on what a substituter
delivers.** There is no decompression bomb (`Compression: none` removes the
amplification) but there *is* an unbounded bandwidth sink, and nothing
downstream stops it. The adapter's byte cap at the declared length is the only
thing that does — load-bearing, not belt-and-braces. `verify.rs` enforces it on
every chunk, and `one_byte_over_narsize_aborts` names that guarantee.

**Spike 11 is why `custom.p2pCache` carries a hard assertion** scanning every
substituter on the host for `trusted=`. It is silent, it is total, and there is
no runtime signal that it has happened.

### 3.2 The canonical swarm artifact is the uncompressed NAR

Upstream serves `nar/<filehash>.nar.xz`. Torrenting *that* would key the swarm
on bytes whose exact form depends on the compressor version and settings, so a
locally-built path re-compressed here produces different bytes, a different
infohash, and a swarm of one. Worse, `FileHash` is unsigned, so the artifact's
identity would sit outside the signature.

Instead: **the swarm artifact is the raw NAR.** `nix store dump-path` is
canonical and byte-identical everywhere (spike 3). So the adapter serves
`Compression: none`, `FileHash = NarHash`, `FileSize = NarSize`, and **the
artifact's hash is the signed `NarHash`.** No unsigned field enters the trust
path at any point.

On a LAN this is usually a throughput *win* — single-threaded xz decompression
runs at a few MB/s, well under gigabit. Over WAN it costs bytes; `zstd` under
pinned parameters is the documented future refinement.

### 3.3 Torrent construction (librqbit 8.1.1)

`compute_info_hash` bencodes only `TorrentMetaV1Info`, and `create_torrent`
hardcodes `created_by: None` / `creation_date: None`. No timestamp or host
identity reaches the infohash. Demonstrated as well as argued:

```
run1  same file, 256KiB pieces : d464a6004be76c1ed5e2b1ee40f1f459548cc2be
run2  same file, 256KiB pieces : d464a6004be76c1ed5e2b1ee40f1f459548cc2be
run3  COPY at another path     : d464a6004be76c1ed5e2b1ee40f1f459548cc2be
run4  same file, 1MiB pieces   : b087fc0e7fe3e46d41b19906368e372c9f38b7c9
```

Run 3 is the one that matters: the second copy sat at a different directory
under a different filename and still produced the same infohash, because `name`
is passed explicitly rather than derived from `basename`. **Two peers storing
the same NAR at different paths join the same swarm.** Left to default, the
on-disk filename would leak into the infohash and every peer would be alone —
silently.

Three consequences: `piece_length` must **always** be passed explicitly
(`choose_piece_length` is a flat 2 MiB carrying `// TODO: make this smarter or
smth`); `CreateTorrentOptions` exposes exactly the two knobs needed; and
`private` is hardcoded `false` while sitting *inside* the info dict, so a
private (BEP27) swarm is a code change, not a flag.

## 4. Protocol decision

**BitTorrent v1 via `librqbit` as a Rust library crate.** The v2-vs-v1 security
delta here is nil: the index record is signed independently of BitTorrent, SHA-1
second-preimage resistance is intact, and the terminal check is `NarHash`
verified twice. A forged piece costs a retry, not a bad store path. Paying a C++
FFI boundary plus boost plus a second crash domain to buy nothing is the wrong
trade.

Verified: `librqbit` with `default-features = false, features = ["rust-tls"]`
locks to 307 crates with **no openssl**, and `buildInputs = [ ]` holds. The
`initial_peers` + `disable_trackers` options mean a LAN swarm needs **no tracker
and no DHT**, which is what makes "works under `strictEgress` unmodified"
literally true.

Rejected: IPFS/Bitswap (provider-record latency in minutes is fatal for a build
workflow); a libp2p custom protocol (means writing piece scheduling from
scratch — recorded as transport #3); DCF/HydraMesh (a 17-byte-frame RF protocol,
wrong by three orders of magnitude).

### 4.1 The honest objection, and the mitigation

A swarm per NAR is pathological — most NARs are tiny and every swarm would have
one peer. Measured over this workstation's live closure (4096 paths, 48.6 GiB):
median NAR **355 KiB**, p90 9.7 MiB, p99 245 MiB, largest 3.2 GiB.

| `minArtifactSize` | paths in swarms | % of paths | % of **bytes** |
|---|---|---|---|
| none | 4096 | 100.0% | 100.0% |
| 1 MiB | 1340 | 32.7% | 98.8% |
| **4 MiB** | **671** | **16.4%** | **96.0%** |
| 8 MiB | 460 | 11.2% | 93.5% |
| 64 MiB | 120 | 2.9% | 77.8% |

**4 MiB eliminates 83.6% of the swarms for a 4.0% bandwidth give-up.** The knee
sits between 4 and 8 MiB. Caveat: this sample is a desktop/dev-heavy closure, so
the default is justified but a per-host override should stay available.

## 5. Adapter posture

**Always-proxy.** The adapter is substituter #1 (`Priority: 30` against
cache.nixos.org's 40) and proxies narinfo from upstream, rewriting only unsigned
transport fields. It never 404s on a path upstream has, so it never triggers
Nix's hour-long negative cache.

The cost is stated rather than hidden: it sits in the path of all substitution.
Mitigations are that it fails closed to a 404 on any internal error,
`Restart=on-failure`, and upstream staying configured *behind* it — if this
daemon is down or wrong, Nix must still be able to build the system that fixes
it. A `p2p-daemon-down` gate is listed under Known gaps.

---

## 6. Staging

One stage per commit. Each stage's gate must be green before the next starts.

| Stage | Scope | Gate | Status |
|---|---|---|---|
| 0 | Validation spikes; no repo changes | all five answered, four risks retired | **DONE** |
| 1 | Sub-flake + loopback adapter, pass-through proxy, no transport | `nix build .#p2p-substituter-protocol` and `.#p2p-signature-refusal` | **DONE** |
| 2 | Local artifact cache + `nix-store --dump` serving + the uncompressed-NAR canonicalisation | `nix build .#p2p-artifact-cache` — a corrupt body is refused *before* Nix sees a byte | **DONE** |
| 3 | `ArtifactTransport` + `LanTransport` over the peer surface, static peers | `nix build .#p2p-two-node` — the repo's first multi-node test | **DONE** (mDNS deferred, gap 20) |
| 4 | `BitTorrentTransport` (librqbit, `initial_peers`, `disable_trackers`) | two-node swarm + `p2p-no-peer-fallback` | not started |
| 5 | BEP44-shaped signed index records + the OCI index container | tampered record refused; unsigned record refused | not started |
| 6 | Limits, eviction, `oligarchy-p2p-status`/`-test`, MCP `net` wiring | `.#mcp-self-audit` still green, daemon absent from `.mcp.json` | not started |

### Current wiring (stage 3)

- Input: `oligarchy-p2p.url = "path:./modules/oligarchy-p2p"`, with
  `inputs.nixpkgs.follows = "nixpkgs"`.
- Module: `oligarchy-p2p.nixosModules.default`, imported **only** by
  `nixosConfigurations.nixos`. `custom.p2pCache.enable` is still false, and
  `transport` still defaults to `"none"` — a host that enables the adapter does
  not thereby join a swarm.
- The resolver chain, in order:

  ```
  1. local cache      <stateDir>/nar/<narhash>.nar   verified IN FULL, then served
  2. local Nix store  nix-store --dump               verified IN FULL, then served
  3. peers            LanTransport                   fetched, verified IN FULL, then served
  4. upstream HTTP    decompress + verify + tee      streamed with one-chunk lookahead
  ```

  Narinfo resolution has the same shape: memory → disk → **peers** → upstream.
  Without the peer leg the transport is useless offline, because a NAR cannot be
  verified without the signed `NarHash` and that lives in a narinfo.

- **Two listeners, and the separation is the design.** The substituter surface
  is loopback-only and will proxy anything upstream holds. The peer surface
  (`custom.p2pCache.peer`, default off, port 5112) binds a real interface and
  answers a deliberately smaller question — *do you already have this?* It never
  triggers an upstream fetch on a peer's behalf and serves nothing it has not
  verified. Reach is per-interface via `peer.openFirewall`, empty by default.
- **Peers are private-range only** — RFC1918, CGNAT/tailnet, link-local —
  checked in code, not left to the firewall. This is the same set
  `strict-egress.nix` already allows statically, which is why a LAN swarm needs
  no firewall change on the egress side.
- Gates:

  ```console
  nix build .#p2p-substituter-protocol   # a real substitution, end to end
  nix build .#p2p-signature-refusal      # the one that matters
  nix build .#p2p-artifact-cache         # the cache is real, and is verified
  nix build .#p2p-two-node               # a leecher whose ONLY source is a peer
  ```

### Known gaps, by the stage that will hit them

**Stage 1 leftovers — all three closed by stage 2**

1. ~~**A pass-through narinfo describes bytes we do not control, and Nix caches
   it for 30 days.**~~ **CLOSED.** The adapter now serves the canonical
   uncompressed NAR: `Compression: none`, `FileHash = NarHash`,
   `FileSize = NarSize`, and `URL = nar/<hashpart>/<narhash>.nar`. Every field
   emitted is a function of signed, immutable data, so upstream may re-compress
   freely. `the_nar_url_does_not_move_when_upstream_recompresses` is the
   regression test and `.#p2p-substituter-protocol` asserts the canonical form
   against a real Nix.
2. ~~**A corrupt body is caught, but not before some of it has been
   forwarded.**~~ **CLOSED for local sources, which is where it matters.**
   Sources 1 and 2 hash the artifact in full and only then open the response, so
   Nix receives nothing at all from a bad one. See the remaining gap 10 for the
   upstream first-fetch case, which cannot have this property for a reason.
3. ~~**No `p2p-daemon-down` gate.**~~ **CLOSED.** `.#p2p-substituter-protocol`
   now stops the unit and asserts a real build still succeeds from upstream.
4. ~~**The narinfo cache is a `HashMap` that clears wholesale at 4096
   entries.**~~ **Superseded.** It is still that, but it is now a front for a
   persistent on-disk narinfo cache, so a wholesale clear costs a disk read
   rather than a network round trip.
5. **Only `sha256` is accepted.** Unchanged, and still correct: the binary cache
   protocol uses nothing else, and `nixhash.rs` refuses other algorithms loudly
   rather than guessing.

**Stage 2 leftovers**

10. **The first fetch of a path still streams, so a corrupt upstream body has
    all-but-its-last-chunk forwarded before the digest fires.** This is not an
    oversight and buffering is not the fix: Nix aborts a transfer that delivers
    nothing for `stalled-download-timeout` (300s), so verifying a multi-gigabyte
    download in full before emitting anything would turn large paths from slow
    into impossible. The lookahead still guarantees the body cannot *complete*
    unless the digest matched, Nix re-checks `NarHash` regardless, and every
    subsequent serve of that path comes from the cache with the full guarantee.
    When the peer transport lands it should use fetch-then-serve, because LAN
    peers are fast enough to afford it — that is where untrusted bytes actually
    come from.
11. **`bzip2` and `br` cannot be decoded, so those paths are declined.** The
    adapter 404s at the narinfo — deliberately early, before Nix commits to it —
    and Nix fetches from upstream directly. Nix's default for an *absent*
    `Compression` field is bzip2, so a very old cache would hit this. Adding it
    is one arm of `Codec::parse` plus a vendored decoder; nothing in this
    project's upstream set needs it yet.
12. **The on-disk narinfo cache has no TTL.** A store path's narinfo is
    immutable, so this is sound, with one wrinkle: a path can *gain* a `Sig`
    line upstream and we would keep serving the older one. That can only ever
    cause a refusal, never a false acceptance, so it is a availability nit
    rather than a correctness bug. `rm -rf <stateDir>/narinfo` is the fix.
13. **Nothing re-verifies the cache in the background.** Entries are verified on
    every serve, so a rotted entry is caught the next time it is asked for and
    removed — but a cache full of rot looks healthy until something reads it.
    A periodic scrub belongs with the seeding work in stage 4, since seeding
    hands those bytes to other machines.
14. **The daemon's log level is a knob, and the default matters.**
    `custom.p2pCache.logLevel` defaults to `info`, at which the journal carries
    one line per served NAR naming the source (`cache` / `nix-store` /
    `upstream`) plus every refusal. That is the difference between a working
    cache and an expensive proxy, and it was invisible until stage 2 — the
    telemetry existed but sat at `debug` while the unit ran at `info`, so
    neither an operator nor the VM gates could see it. If you add a fact worth
    acting on, put it at `info`.
15. **`serveFromStore` spawns `nix-store --dump` per request with no
    concurrency limit.** A mass-query burst could fork a lot of processes.
    `TasksMax=64` in the unit is the current backstop; a real semaphore belongs
    with the peer transport, which will make concurrent serving normal rather
    than incidental.

**Stage 3 leftovers**

20. **mDNS discovery is not implemented; peers are a static list.** The stage
    was specified with Avahi `_oligarchy-p2p._tcp` browsing. It is deferred
    rather than done because the load-bearing half — the transport, the peer
    surface and the verification — is what the two-node gate proves, and adding
    a multicast dependency to that gate would have made a flaky discovery
    mechanism able to fail a test about byte transfer. Static peers are also
    what a fixed set of household machines actually wants. When it lands it
    should be `mdns-sd` (pure Rust, no D-Bus, so no `AF_UNIX` in
    `RestrictAddressFamilies`) rather than shelling out to `avahi-browse`.
21. **A peer can only serve metadata it has itself resolved, and that bounds
    what it can seed.** The peer surface never goes upstream on a peer's behalf
    (rule 1 in `peer.rs`), so `GET /peer/v1/narinfo/<hp>` answers only from the
    on-disk narinfo cache. A host that holds a store path but never resolved its
    narinfo cannot hand it to a peer, even with `serveFromStore` on — because
    without `NarHash` the *receiver* has nothing to verify against.

    The sharp edge: **a locally-BUILT path has no narinfo anywhere.** Nothing
    ever resolved one, so it can never be seeded. Substituting a closure warms
    everything it touches, so a machine that fetched a rebuild is a good seeder
    and a machine that compiled it is not — which is backwards from what the
    project eventually wants.

    Fixing it means the seeder generating and signing its own narinfo, which
    makes it a signing authority for those paths — a much larger question than a
    transport, and the same one `docs/plugins-roadmap.md` is waiting on a cache
    key for. Recorded, not designed. Until then, `custom.p2pCache` seeds what it
    *fetched*, which is exactly the stated v1 value proposition (one host
    rebuilds, the others fetch from it) and no more.
22. **`discover` asks every peer in series.** Fine for the handful of machines
    this is for; it is O(peers) round trips on the latency path of every
    substitution. Parallelise when the peer list can be long — which is to say,
    when there is a real transport.
23. **A peer that accepts a connection and stalls costs `peerTimeout` per
    request.** The socket read timeout bounds each read, not the whole
    transfer, so a peer trickling one byte per timeout window can hold a fetch
    open. It cannot corrupt anything — the verifier still decides — but it can
    make the adapter slower than going upstream. A total-transfer deadline
    belongs with stage 4.
24. **No peer is ever marked bad.** A peer that fails verification is retried on
    the next request. With a static, hand-written peer list that is the right
    behaviour; with discovery it is not.
25. **`provide`/`remove` are absent from `ArtifactTransport` on purpose.** For
    the LAN transport, being reachable is the announcement, so both would be
    no-ops — and a trait method whose only implementation does nothing teaches
    the wrong thing about what a transport owes. Stage 4 adds them, where
    announcing to a swarm and dropping a torrent on eviction are real.

**Before BitTorrent lands (stage 4+)**

16. `strict-egress` puts RFC1918 / 100.64.0.0/10 / link-local in its *static*
   allow set, so a LAN or tailnet swarm needs no firewall change. A **public**
   swarm would need `allow.uids`, which is a total egress bypass for that uid.
   If that is ever added it must emit a build warning in the `allowSelfJit`
   style and refuse to co-exist silently with `strictEgress`.
17. `users.users.<user>` is a static system user rather than `DynamicUser`
   specifically because `strict-egress`'s `allow.uids` matches on
   `meta skuid "<name>"`, which nft resolves against passwd at ruleset-load
   time. A dynamic uid cannot be named there. Do not "tidy" this into
   `DynamicUser`.
18. **Swarm membership discloses build history to the LAN/tailnet.** Unmitigated,
   and scoped to LAN/tailnet by design. Must reach the module's option
   description and `warnings` before stage 3, following `demod-talk`'s
   tailnet-reach warning.
19. `librqbit` is at 8.1.1 here while crates.io already carries **9.0.1** — a
   major version has landed since the pin. `transport/bittorrent.rs` must be the
   only file in the crate that names a `librqbit` type.

### Writing the repo's first multi-node VM test

Three things cost a cycle each, and all three are properties of the test
harness rather than of the code under test. Recorded because
`docs/plugins-roadmap.md` gap #8 proposes a second multi-node test and will hit
the same ones.

**Node addresses are assigned in alphabetical order of the node name**, not
declaration order. With `nodes = { seeder = …; leecher = …; }` the *leecher*
gets `192.168.1.1` and the seeder `192.168.1.2` — the opposite of how the file
reads. Pointing a peer at the wrong one costs a sixty-second
`wait_until_succeeds` timeout with nothing to say why. The gate now binds the
address to a name and *asserts* it (`ip -4 addr show eth1`) before depending on
it, so a change in allocation fails with a sentence.

**All nodes share the host's `/nix/store`.** A node's own closure is what its
Nix *database* knows, but the store directory contains everything every node
needs. So `test -e /nix/store/…-hello` succeeds on a node that has never heard
of hello, and any feature that reads the store directly — `serveFromStore`
here — will answer from it. "This node does not have it" has to be expressed as
`nix path-info` failing, plus turning off whatever reads the raw directory.

**The test driver lints and type-checks the script before booting anything.** An
f-string with no placeholders is a hard error; shadowing an injected global
(`log`) is a type error. Both fail at *driver build* time, which is fast, but
the message points at a generated file rather than at the flake. A program with
its own braces and heredoc (the hostile peer) belongs in `writeText`, not inline
in a Python f-string inside a Nix indented string — three levels of quoting is
one too many.

### A test fixture that made two gates vacuous

Worth recording because the symptom was two *passing* gates, and then a
confusing failure that turned out to be the adapter being right.

`serveFromStore` is on by default, and a NixOS test VM has whatever is in
`environment.systemPackages` in its own Nix store. So a gate that published
`hello` to a fake upstream, corrupted the upstream copy, and asserted a refusal
was asserting nothing: the adapter looked in the local store first, found a
genuine `hello`, verified it against the signed `NarHash`, and served it. The
corruption was never read. One gate passed for that reason; the other failed
with `served the whole correct thing`, which is exactly what a correct adapter
does and exactly what a wrong test asks about.

The fix is in `setupUpstream`: build a store path, sign it, publish it, then
`nix-store --delete` it locally. Upstream is then genuinely the only source and
corrupting it means something. Gates that need a locally-held path (the
`nix-store --dump` leg) still use `hello`; gates about upstream bytes use the
deleted one.

The general rule this is an instance of: **a test whose subject can be satisfied
by a fallback is not testing its subject.** The resolver has three sources by
design, so any gate aimed at one of them has to remove the other two.

## 7. Changelog

- **Stage 0** — five validation spikes against the real Nix and the real
  `librqbit`. Confirmed unknown-field tolerance, the unsigned-field rewrite,
  both hash-mismatch paths, the signature refusal and the `?trusted=1` bypass;
  measured the closure size distribution (4 MiB threshold justified: 96.0% of
  bytes for 16.4% of swarms); built `librqbit` with `buildInputs = [ ]` and no
  openssl; demonstrated infohash determinism *including path-independence*.
  Retired four risks, added two facts (spikes 8-9) that made the byte cap
  load-bearing.
- **Stage 1** — the sub-flake, the loopback adapter and both gates. 32 unit
  tests run in `checkPhase`. Two real bugs found by testing rather than by
  reading: the digest check was never running because `Body::from_stream` with
  `Content-Length` drops the generator before the post-loop check (fixed with
  one-chunk lookahead in `verifying_stream`, regression test
  `a_corrupt_body_never_completes`), and the pass-through posture turns out to
  interact badly with Nix's 30-day positive narinfo cache when upstream
  re-compresses (Known gap 1 — the reason the module ships disabled).
- **Stage 2** — the artifact cache, `nix-store --dump` serving, and the
  uncompressed-NAR canonicalisation that retires stage 1's narinfo bug. 60 unit
  tests. Two things were found by running it rather than by reading it: eviction
  had been documented as running after each insert and only ran at startup, and
  — the real one — **a populated cache returned 404 the moment upstream was
  unreachable**, because every NAR request resolves its narinfo first and that
  resolution went to the network. A cache that only works when you do not need
  it is not a cache; metadata is now persisted to disk alongside the artifacts,
  under its own eviction budget so the two never compete. A third, smaller
  one: every useful log line sat at `debug` while the unit ran at `info`, so
  the one fact an operator most needs — which source answered — was
  unobservable. Promoted, with `logLevel` to tune it. The gates themselves also
  needed fixing twice: once for the stage-2 URL scheme, once because
  `serveFromStore` was quietly satisfying the very requests they meant to fail,
  and once more because the replacement fixture used a content-addressed path,
  for which Nix requires no signature (see §3 and the section above).
- **Stage 3** — the `ArtifactTransport` trait, the `LanTransport`, and the peer
  surface, plus the repo's first multi-node VM gate. 71 unit tests. No product
  bugs this stage; the design held. The gate, however, was vacuous twice and
  both reasons are environmental rather than logical: **NixOS test nodes share
  the host's `/nix/store`**, so the leecher could see `hello` on disk and
  `serveFromStore` would have answered locally without the peer ever being
  consulted; and the adversarial leg originally corrupted the *seeder's* cache,
  which proves the seeder is honest — the seeder verifies before serving a peer,
  so it refuses first and the leecher never sees bad bytes. Testing that a
  leecher refuses a lying peer needs an actually hostile peer, so the gate now
  ships one. That is the third instance in this subsystem of the same rule: a
  test whose subject can be satisfied by something else is not testing its
  subject.
