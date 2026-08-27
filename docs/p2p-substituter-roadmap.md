# P2P Substituter — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Stages 1-6 are landed and all nine gates pass.
> Stage 1's narinfo posture was WRONG and stage 2 corrects it — read Known gap 1
> and §3.2 before changing anything about the URL or the compression. The module
> is wired on the workstation host and **disabled by default**; §6 "Current
> wiring" says why, and the reason changed at stage 2. **§2 changed at stage 5**
> — a host that sets `servePackages` signs metadata, and one that sets
> `trustedPublicKeys` extends trust to a whole host for every path. Read §2
> before touching either. Update the
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
untrusted side of the boundary and is designed as if hostile: the daemon runs
unprivileged, cannot write the store, holds no keys, and nobody is in
`nix.settings.trusted-users`. Every path it serves is signature-checked and
hash-checked by `nix-daemon` afterwards.

Through stage 4, peers were **sources of bytes and nothing else** — no
metadata, no signatures, no policy — and removing every peer changed throughput
and nothing about correctness.

**Stage 5 amends that sentence, and the amendment is the whole cost of the
stage.** `servePackages` lets a host publish paths it *built*, which Nix refuses
unsigned, so the host signs them. Two things follow and both must be said
plainly:

- The daemon still holds no key. Signing happens in `oligarchy-p2p-seed.service`,
  a separate root oneshot, so the process exposed to hostile input is not the
  process holding the key. That separation is real — a compromised
  `oligarchy-p2pd` still cannot sign anything — but it mitigates daemon
  compromise, not the item below.
- **A consumer that sets `trustedPublicKeys` extends trust to a whole host, for
  every path.** Nix cannot scope a key to a set of store paths. Trusting a
  seeder's key trusts it for everything that consumer will ever substitute, and
  `Priority: 30` puts the adapter ahead of cache.nixos.org for all of it. For an
  input-addressed path the signature is the entire anchor (§3), so a compromised
  seeder can serve signed bytes for any path at all. `docs/plugins-roadmap.md`
  reaches the same conclusion from the other direction: *"signing is an
  authoring step, not a runtime one."*

**Stage 6 bounds the second bullet, which is the only part that was ever
fixable here.** Nix cannot scope a key — but every narinfo a peer supplies
passes through this adapter, so the adapter can. `acceptFromPeers` names the
packages a peer key may speak for; anything else it signs is refused before Nix
sees it, and the option is **mandatory** whenever a peer key is trusted. So the
accurate form of the rule after stage 6:

> **P2P still provides availability. Trust comes from keys, adding a key is an
> operator decision made in the flake, and what that key may speak for is
> bounded by name in the adapter — because Nix has no way to bound it.**

A peer cannot cause its key to be trusted; no module derives a key from a peer
address; and every option involved defaults to `[ ]`, where every sentence in
the paragraphs above still holds exactly as written.

**What stage 6 does not fix, stated plainly.** The scoping is a property of this
code path, not of the machine. The key remains in `trusted-public-keys`
globally, so an operator who adds a peer directly to `substituters`, or runs
`nix copy --from`, or uses a remote builder, is outside it.

The check also lives in `oligarchy-p2pd`, the process this document calls
hostile — but **that costs less than it appears, and an earlier draft of this
paragraph overstated it.** Nix verifies signatures cryptographically and does
not trust a key *name*: corrupting a `Sig:` line's base64 while leaving
`cache.nixos.org-1:` in front of it yields `error: signature is not valid`,
reproduced on real hardware. A compromised daemon holds no trusted private key,
so it can serve only what is genuinely signed — or be refused. Daemon RCE buys
denial of service and request visibility, not forgery. The scope's placement
matters only against an attacker holding **both** a trusted peer key and code
execution here: two compromises. See gap 38 for why the clean fix is recorded
rather than built.

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
| 4 | `BitTorrentTransport` (librqbit, `initial_peers`, `disable_trackers`) | `nix build .#p2p-swarm` and `.#p2p-no-peer-fallback` | **DONE** |
| 5 | `servePackages` — a host seeds what it **built**, signed by its own key | `nix build .#p2p-local-signing` — a consumer accepts it only because the key is trusted, and refuses it when it is not | **DONE** |
| 6 | `acceptFromPeers` — bound what a peer key may vouch for; `selftest`; MCP `net` wiring | `nix build .#p2p-peer-scope` and `.#p2p-selftest` — the second breaks each guarantee in turn and asserts it is noticed | **DONE** |
| 7 | BEP44-shaped signed index records + the OCI index container | tampered record refused; unsigned record refused | not started |
| 8 | Limits and eviction under pressure, bandwidth caps | cache stays inside its budget under sustained load | not started |

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

### Current wiring (stage 4)

The resolver is unchanged in shape; `transport = "bittorrent"` swaps what sits
at step 3.

```
1. local cache      verified IN FULL, then served
2. local Nix store  verified IN FULL, then served      → announced to the swarm
3. peers            LAN HTTP *or* BitTorrent           → verified IN FULL, then served
4. upstream HTTP    decompress + verify + tee          → announced to the swarm
```

- **Discovery is not BitTorrent's.** `disable_dht: true`, no trackers, no PEX.
  Peers *and* infohashes both come from the stage-3 peer surface, because every
  address dialled has to come from the private-range peer list for this to work
  under `strict-egress` unchanged. `AddTorrentOptions { initial_peers,
  disable_trackers }` is what makes a tracker-less, DHT-less swarm expressible.
- **BitTorrent adds nothing to the trust story.** Piece hashes come from a
  `.torrent` an untrusted peer handed us. What makes a fetch safe is what always
  did: the completed file is hashed against the **signed** `NarHash` before it
  is given a name.
- **`minArtifactSize` defaults to 4 MiB**, from the Stage 0 measurement (§4.1):
  the median NAR here is 355 KiB, and 4 MiB puts 16.4% of paths in swarms while
  covering 96.0% of the bytes. `discover` checks it *before* contacting any
  peer, so a small path costs no round trip.
- A host seeds at every point an artifact becomes a cache entry: upstream fetch,
  `nix-store --dump`, and peer fetch. It re-announces the whole cache at startup,
  because a restart otherwise silently stops seeding everything while the daemon
  still looks healthy.

### Current wiring (stage 5)

A host can now seed what it **built**, not only what it fetched. Two options,
both defaulting to empty, and they are deliberately on opposite sides:

```nix
# on the BUILDER
custom.p2pCache = {
  servePackages  = [ pkgs.my-thing ];
  signingKeyFile = "/var/lib/oligarchy/p2p/cache.sec";   # runtime path, 0400
  peer.enable    = true;
};

# on the CONSUMER — a separate, deliberate act
custom.p2pCache.trustedPublicKeys = [ "nixos-p2p-1:kBnLtBEr..." ];
```

- **The feature is "mint a narinfo and put it where `get_narinfo` looks".**
  Nothing else needed changing: `peer::have` was already store-aware, and
  `peer::narinfo`/`nar`/`torrent` all gate on that single lookup. NAR bytes come
  from `nix-store --dump` on demand via the existing `resolve::local`.
- **`declared/` is a non-evictable tier, checked before `narinfo/`.** A fetched
  narinfo that gets swept can be fetched again; a minted one cannot, because
  nothing upstream has ever heard of the path. Evicting it would silently
  unpublish a package while the daemon carried on looking healthy.
- **Nix does the crypto.** `nix store sign` produces the signature and
  `nix path-info --sigs` reads it back, so `ValidPathInfo::fingerprint` is never
  reimplemented and cannot drift from what Nix will verify. There is no ed25519
  in this crate.
- **The key never goes near the daemon.** `oligarchy-p2p-seed.service` is a
  separate root oneshot, and it has to be: minting needs the signing key *and*
  the Nix database, and the daemon's `RestrictAddressFamilies` excludes
  `AF_UNIX` precisely so it can never open the nix-daemon socket. The key path
  is not in `config.json` either — that file is what the daemon reads. The
  daemon's config carries one bool, `serve_declared`.
- **Only unsigned paths are signed and published.** Those are exactly the
  locally-built ones. Signing the rest of the closure would be permanent (it
  writes `/nix/var/nix/db`, and the signature then travels through `nix copy`,
  `nix path-info --sigs` and ssh-ng, not just this adapter) and would be the
  maximum possible blast radius for the key. It also avoids shadowing: a
  declared narinfo outranks the fetched tier forever, so minting one for a path
  upstream also has would freeze that path's signature set.
- **A pure seeder is now expressible** — `upstreams = [ ]` with
  `servePackages` set. The assertion and `Config::validate` were both relaxed,
  and they had to be: `seed` loads the same config, so refusing it would have
  made the unit that populates `declared/` unable to start on exactly the
  configuration it exists for.
- **The daemon skips upstream for a declared path.** It was built here, so
  cache.nixos.org cannot have it; asking anyway is a guaranteed miss that leaks
  the hash part of a locally-built path to a public cache once per request.
- Gate:

  ```console
  nix build .#p2p-local-signing   # the first gate where a peer MINTS metadata
  ```

### Current wiring (stage 6)

Two things, both about the same problem from opposite ends: stage 5 created a
trust that could not be bounded, and this subsystem's failures could not be
seen.

**`acceptFromPeers` bounds what a peer key may vouch for.**

```nix
custom.p2pCache = {
  trustedPublicKeys = [ "nixos-p2p-1:kBn..." ];
  acceptFromPeers   = [ "my-thing" ];      # mandatory; "*" is the opt-out
};
```

- **The rule is "does any `Sig:` name a peer key", not "does any `Sig:` name a
  key outside the peer set".** The second is the intuitive formulation and it
  fails open: signatures are attacker-supplied text, so appending a junk
  `Sig: cache.nixos.org-1:AAAA` makes the narinfo look upstream-vouched, while
  Nix — which *counts* verifying signatures rather than requiring all of them —
  still accepts the path on the strength of the real peer signature. Telling a
  forged signature from a real one means doing Ed25519, which this crate
  deliberately does not do. Asking whether a peer key is involved needs no
  verification and cannot be gamed by adding signatures.
  `appending_a_junk_upstream_signature_does_not_lift_the_scope` is the test.
- **A version suffix must start with a digit.** `starts_with(entry + "-")` is
  not a version test: it lets `glibc` reach `glibc-locales` and `linux` reach
  `linux-firmware`, both real nixpkgs paths in every system closure. Nix splits
  pname from version at the first `-` followed by a non-letter, and so does
  this. The cost is a deliberate false negative on an unversioned package's
  extra outputs, which errs closed.
- **The check is in the transport loop, not only in the caller.**
  `LanTransport::narinfo` returns the first parseable answer and stops. Refusing
  afterwards would let one hostile peer answer every query out-of-scope while
  the honest peers further down the list were never asked — a remotely
  triggerable denial of service against any path it chose.
- **Four enforcement points, because one is not enough.** The transport loop
  (above); `AppState::resolve`'s peer arm, before persisting or memoising; its
  disk arm, because an entry that reached `narinfo/` is durable and would
  otherwise be served forever without consulting the transport again; and
  `peer.rs`, so a lax or poisoned host does not relay onward and become a second
  hop into hosts that refused it directly. `declared/` is exempt everywhere —
  those are narinfos this host minted for its own operator's packages.
- Refusals are logged loudly for the first 16 and at `debug` after. A refusal is
  remotely triggerable and Nix mass-queries closures of thousands of paths, so
  one `warn` per path is journal amplification an attacker controls.

**`selftest` makes the invisible failures visible.**

```console
$ oligarchy-p2p-selftest
  PASS  bind_is_loopback                one is 127.0.0.1
  PASS  no_trusted_in_nix_conf          2 file(s) clean
  PASS  daemon_answers                  http://127.0.0.1:5111 serving /nix/store
  PASS  declared_refuses_a_write        refused as uid 992 (permission denied)
  PASS  declared_narinfos_are_coherent  1 published, all coherent
  PASS  round_trip                      xk1n…: 232 bytes, sha256:0k8c…
  PASS  peer_scope_is_bounded           1 peer key(s), scoped to: my-thing
  SKIP  peers_reachable                 no peers configured
```

- It runs as a **unit**, not a bare command, and shares `sandbox` verbatim with
  the daemon. `declared_refuses_a_write` attempts a real write and expects it to
  fail; that only means anything inside the daemon's confinement as the daemon's
  user, and from a root shell it would succeed and report a false PASS — so
  there it reports a loud SKIP instead.
- Two rules borrowed from `mcp_self_audit`: **a check that inspected nothing is
  a FAIL**, and **a skipped check is reported, never omitted**. "Zero declared
  narinfos, all valid" is the exact sentence that hid a real bug in stage 5.
- `round_trip` is the one that ties the parts together: it asks our own HTTP
  surface for a narinfo, fetches the NAR it names, and hashes it.

**`status` was lying.** It never contacted the daemon — every line was config
echo, so it printed a cheerful report on a host where the daemon was dead. It
now probes, reports the declared tier and the peer scope, and — a live bug —
uses `Cache::open` instead of `Cache::new`, which swept `tmp/` and could delete
a slot a concurrent fetch was writing.

**MCP:** `oligarchy-p2pd` was already on the `net` allowlist, so this is one
`p2p_status` tool. `selftest` is deliberately not exposed: it writes.

- Gates:

  ```console
  nix build .#p2p-peer-scope   # same peer, same key — only the name differs
  nix build .#p2p-selftest     # and it FAILS when each guarantee is broken
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
21. ~~**A peer can only serve metadata it has itself resolved, and that bounds
    what it can seed.**~~ **CLOSED by stage 5 — see below.** The peer surface never goes upstream on a peer's behalf
    (rule 1 in `peer.rs`), so `GET /peer/v1/narinfo/<hp>` answers only from the
    on-disk narinfo cache. A host that holds a store path but never resolved its
    narinfo cannot hand it to a peer, even with `serveFromStore` on — because
    without `NarHash` the *receiver* has nothing to verify against.

    The sharp edge: **a locally-BUILT path has no narinfo anywhere.** Nothing
    ever resolved one, so it can never be seeded. Substituting a closure warms
    everything it touches, so a machine that fetched a rebuild is a good seeder
    and a machine that compiled it is not — which is backwards from what the
    project eventually wants.

    **CLOSED in stage 5**, by doing exactly what this entry said it would take:
    the seeder generates and signs its own narinfo. `custom.p2pCache.servePackages`
    names the packages, `signingKeyFile` names the key, and
    `oligarchy-p2p-seed.service` — a **separate root oneshot**, because the
    daemon is deliberately denied both a key and the Nix database — mints the
    narinfo into a non-evictable `declared/` tier that `Cache::get_narinfo`
    checks first. Every peer route then works unmodified; they all gate on that
    one lookup, and `peer::have` was already store-aware.

    Two scoping decisions kept the blast radius from being what this entry
    feared. **Only paths with no signature at all are signed and published** —
    the ones this host actually built — so `servePackages = [ pkgs.foo ]` does
    not put this host's name on glibc, permanently, in the Nix database.
    And the trust half is a separate option on the *consumer*
    (`trustedPublicKeys`), so a seeder cannot make anyone trust it.

    What this does **not** answer is the larger question the entry named: it
    implements the mechanism and leaves the decision to whoever pastes the key.
    §2 records what that decision costs. See also `docs/plugins-roadmap.md`
    gap 1 — both subsystems were blocked on the same missing key, and a host
    running this now has one.
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

**Stage 4 leftovers**

26. **`provide` and `remove` are fire-and-forget, and `remove` therefore has no
    ordering guarantee.** Eviction may delete a file before `librqbit` has let
    go of it; librqbit errors on the missing file and drops the torrent, which
    is survivable. The alternative was worse — see gap 27 — but a synchronous
    `remove` would need the transport to own a runtime thread of its own. Worth
    doing if evicting a hot artifact ever shows up as peer-visible errors.
27. **`Handle::block_on` is wrong in a transport, in both directions.** From an
    async handler it panics outright (`Cannot start a runtime from within a
    runtime`); from a `spawn_blocking` thread it never returns at all —
    silently, with no panic, no error and a healthy-looking daemon. Both were
    shipped and both were caught by `.#p2p-swarm`. The trait now says **must not
    block** and records why.
28. **A swarm of two is slower than a direct HTTP copy.** BitTorrent's win is
    parallel multi-peer transfer; with one seeder it adds handshake and piece
    scheduling for nothing. `transport = "lan"` remains the right answer for a
    two-machine site and is not deprecated by this stage.
29. **The infohash still comes from a peer.** That is the stage-5 index's job.
    Until then a host can only join a swarm for an artifact some reachable peer
    already holds *and* has resolved metadata for — so the swarm cannot outlive
    the peer surface, and a fully offline swarm is not yet possible.
30. **Nothing limits how many torrents the session holds.** The cache is bounded
    and eviction calls `remove`, so it is bounded in practice, but there is no
    independent cap and no back-pressure if `provide` outruns `remove`.

**Deferred (stage 5+)**

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


**Stage 5 — seeding what this host built**

31. **A declared path joins a BitTorrent swarm only after it has been served
    once.** NAR bytes are materialised lazily: `resolve::local` dumps from the
    store on the first request and the startup re-announce walks `nar/`, not
    `declared/`. So over `transport = "bittorrent"` a freshly declared package
    is reachable by LAN HTTP immediately and by the swarm only after one fetch
    plus a restart. Deliberate — eager materialisation would duplicate every
    declared closure on disk at activation — but it means `minArtifactSize` and
    the swarm do not apply to a declared path on day one.
32. **Unpublishing does not call `transport.remove`.** Dropping a package from
    `servePackages` unlinks its narinfo, so `/peer/v1/have` starts answering 404
    — but if the artifact had been materialised and announced, the swarm still
    carries the infohash. Compare `resolve.rs`, where eviction *is* wired to
    `remove` for exactly this reason: a host that advertises an artifact it will
    not produce is worse than one that never advertised it.
33. **A materialised declared NAR is evictable.** It lands in `nar/` through the
    ordinary `dump_into_cache` path and is swept under `maxCacheSize` like any
    other entry, so a large declared package can be evicted and re-dumped
    repeatedly. The metadata is safe; only the bytes churn. Whether `sweep`
    should skip digests named by `declared/` is a real question and is not
    answered.
34. **Key rotation invalidates every consumer at once.** There is no key name
    option, no overlap window and no second-key support: replacing
    `signingKeyFile` means every peer's `trustedPublicKeys` is wrong until each
    is edited by hand. Fine for the handful of machines this is for; it is not a
    fleet story.
35. **`servePackages` takes the default output only.** `types.pathInStore`
    coerces a package to `$out`, so `foo.dev`/`foo.lib`/`foo.man` are not
    published unless listed explicitly. Documented in the option, not enforced —
    nothing warns that a multi-output package was half-seeded.
36. **The declared set is a stable, guessable list.** The existing peer-surface
    disclosure gap is about which paths a host happens to hold; this is
    sharper — it is a deliberate, enumerable statement of what this machine
    builds. Warned about at eval time, scoped to `peer.openFirewall`, and still
    unauthenticated.


**Stage 6 — bounding a peer key, and seeing failures**

37. **Name scoping cannot express "the closure this peer published".**
    **Narrowed, not closed.** `acceptFromPeers` now accepts a **package**,
    rendered to its exact store path — so `acceptFromPeers = [ pkgs.my-thing ]`
    is an exact grant needing no guess about names or versions, computed at
    evaluation time without building anything. Two machines on the same pinned
    flake derive the same path, which is the common case here and the one worth
    optimising for.

    What remains: a large local rebuild (a patched kernel, a toolchain bump)
    produces many locally-built paths, and each must be listed. There is still
    no way to say "everything in that closure" — the seeder computes
    `pkgs.closureInfo`, but letting it publish that list and having the consumer
    accept it is circular, since a peer would then define its own scope. A
    consumer that can *evaluate* the same flake can name the roots; one that
    cannot is left with `"*"`.
38. **The check lives in the process this document calls hostile — and the
    first version of this entry overstated what that costs.** It said "a daemon
    RCE *is* the scope bypass, and therefore remote root at the next rebuild".
    That is wrong, and the correction is worth having in writing.

    **Nix verifies a signature; it does not trust a key name.** Corrupting the
    base64 of a `Sig:` line while leaving `cache.nixos.org-1:` in front of it
    yields `error: signature is not valid` — reproduced on real hardware, and
    the reason the whole subsystem works. A compromised daemon holds no trusted
    private key, so everything it can serve is either genuinely signed, and
    therefore genuine, or refused by nix-daemon. Daemon RCE buys denial of
    service and visibility into which paths this host requests. It does not buy
    forgery.

    So the placement matters in exactly one case: an attacker holding **both**
    a trusted peer's private key **and** code execution in this daemon. With
    the key alone the scope check stops them; with the daemon alone Nix stops
    them; with both, neither does. Two compromises, not one.

    The clean fix — never put the peer key in `trusted-public-keys`, and have a
    privileged component re-sign in-scope paths with a key the consumer already
    trusts — would close even that. **Deliberately not built.** It needs Ed25519
    verification and Nix's fingerprint format reimplemented here (three traps:
    `References` must be full store paths where a narinfo carries basenames,
    sorted, and `NarHash` normalised to nix32), plus an IPC channel out of a
    daemon whose `RestrictAddressFamilies` excludes `AF_UNIX` precisely so it
    can never reach nix-daemon. Paying that — and reversing "Nix does the
    crypto" — to defend a two-compromise scenario is the wrong trade today. It
    becomes the right one if this ever faces peers the operator does not
    administer.
39. **A NAME entry is matched against a name the peer supplied.**
    **Narrowed by gap 37's fix**: a package or full-store-path entry is compared
    against the whole path, and the transport already binds the hash part to
    what was requested, so such an entry cannot be satisfied by a peer choosing
    a convenient label. The weakness below applies only to bare-name entries,
    which is now the documented reason to prefer a package.

    Original: `in_scope` reads
    `StorePath`, and the transport binds only its *hash part* to the request.
    So a peer answering a query for glibc's hash part can claim the name
    `my-thing` and pass the scope check. Nix catches the substitution itself —
    `goodStorePath` requires the name to match what was asked for — but the
    adapter will have cached and (before the `peer.rs` gate) relayed it, and the
    path is unavailable through this adapter until the entry is dropped. The
    scope is a bound on what a peer may *claim*, and only Nix binds the claim to
    reality.
40. **Nix's own 30-day positive narinfo cache outlives a tightening.**
    Documented in the `acceptFromPeers` option with the remediation
    (`rm -f /root/.cache/nix/binary-cache-v*.sqlite*`), which is all this side
    can do about it. A path
    accepted while the scope was `"*"` — or before stage 6 — is cached by Nix,
    outside this daemon, for `narinfo-cache-positive-ttl`. Narrowing
    `acceptFromPeers` does not evict it; only
    `rm -f /root/.cache/nix/binary-cache-v*.sqlite*` does, which is why the
    gates all do that by hand.
41. ~~**A refused peer can still consume cache budget.**~~ **CLOSED.**
    `Cache::remove_narinfo` reads the `NarHash` out before unlinking and drops
    the artifact too. A NAR is reachable only through a narinfo — the artifact
    tier is keyed by digest and carries no store path — so metadata and bytes
    now go together. `dropping_a_narinfo_takes_its_artifact_with_it` guards it.
42. **No revocation without a rebuild.** Removing a peer key or narrowing a
    scope requires `nixos-rebuild`. For a known-compromised seeder there is no
    faster lever than stopping the unit.
43. **`selftest` cannot check what it was told to publish.** **Narrowed.** It
    still has no Nix database access — that is the point of running it as the
    daemon user — so it cannot read `servePackages`. But the seed run now
    records the count it published to `declared/.expected`, and `selftest`
    compares, so a tier that has *lost* entries since is caught rather than
    reading as "coherent". What is still not caught is a seed run that published
    too few in the first place; that needs a check in the seed unit's context,
    where the intent is known.

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
- **Stage 4** — the BitTorrent transport, canonical torrent construction, real
  `provide`/`remove`, and the `minArtifactSize` threshold. 82 unit tests. Three
  bugs, all found by the gate rather than by local testing, and the local miss
  is the lesson: the local harness ran with `serveFromStore = false`, so the
  `nix-store` path — the one that panicked — was never exercised. Front-loading
  local tests only helps when the local config matches the gate's.
  * `Handle::block_on` from the async handler panicked on every store hit.
  * Moving it to `spawn_blocking` replaced the panic with a silent hang.
  * And the `provide` call site was never added at all: a `str.replace` anchor
    had gone stale when the line it keyed on was promoted from `debug!` to
    `info!` in stage 2, so the edit silently did nothing.
- **Stage 5** — `servePackages`: a host seeds what it **built**, closing gap 21.
  107 unit tests. The mechanism turned out to be far smaller than the entry
  feared — `peer::have` was already store-aware and every peer route gates on
  one lookup, so the work was "mint a narinfo and put it where `get_narinfo`
  looks" plus a non-evictable tier to keep it there. Nix does the crypto
  (`nix store sign` + `nix path-info --sigs`), so the crate gained no ed25519
  and cannot drift from `ValidPathInfo::fingerprint`.

  The cost is not in the code, it is in §2, and an adversarial review of the
  design is what made that legible. Three of its findings changed the design
  before a line of the module was written:
  * The first draft signed every path in the declared closure that lacked *our*
    signature — which is all of nixpkgs. That is permanent (it writes
    `/nix/var/nix/db` and travels through `nix copy` and ssh-ng, not just this
    adapter) and it is the maximum blast radius for the key. Now only paths with
    **no** signature are signed, which is exactly the set gap 21 was about, and
    it incidentally removes the shadowing problem a declared-first lookup would
    otherwise have created.
  * `signingKeyFile` was going to appear in `config.json`. That file is what the
    *daemon* reads, and the daemon must not know where the key lives. It carries
    one bool now; the key and the path list reach `seed` on its own unit's
    `ExecStart`.
  * `trustedPublicKeys` is not a convenience mirroring `plugins.nix`. Nix cannot
    scope a key to a path set, so it trusts a whole host for everything, ahead
    of cache.nixos.org. The option description says so at length, and §2 was
    amended rather than left standing — a locked contract the module contradicts
    is worse than no contract.

  Four bugs. The first two were found by re-reading the diff rather than by
  any test, and they share a shape — the gate could not distinguish the broken
  behaviour from the working one, so it passed:
  * **The second seed run unpublished everything the first one published.**
    `seed` computed one set — paths with no signature — and used it for both
    "sign this" and "publish this". On a re-run the path already carries our
    signature, so the set is empty, so nothing is published, so the prune step
    removes the entry. Every `nixos-rebuild` after the first would silently
    stop the host seeding, while the daemon, the unit and the journal all
    looked correct. The gate did not catch it because it seeded once. Now
    `plan_signing` and `plan_publishing` are separate pure functions with a
    doc comment saying why one is not the complement of the other, five unit
    tests over the four cases, and a gate leg that seeds twice and compares
    the published bytes.

  * **`ConditionPathExists` was in `[Service]`, where systemd ignores it.**
    `Condition*` is a `[Unit]` directive; an unknown key in `[Service]` costs
    only a log line, so the check silently did nothing — turning "wait quietly
    until sops decrypts the key" into "fail at every boot". Also missed by the
    gate, and for the same shape of reason as the one above: a *skipped* run and
    a *failed* run both leave `declared/` empty, so asserting emptiness could
    not tell them apart. The gate now asserts `ConditionResult=no` **and**
    `Result=success`.

  The other two were found by running it rather than reading it, and one is a
  real fault in the shipped module rather than in the gate:
  * `ReadOnlyPaths = "${stateDir}/declared"` without a `-` prefix makes systemd
    **refuse to start the daemon** when the directory is absent. An optional
    feature had acquired the power to take the substituter down — the exact
    thing the peer-list handling is careful about. Caught by the gate's
    remove-the-feature step, which is to say by the assertion that exists to
    prove the gate is not vacuous.
  * `nix path-info --json-format 1` is Determinate Nix 3.x only; on the Nix in
    nixpkgs it is `unrecognised flag`, a hard failure. Pinning it — which the
    review recommended, correctly, for the deprecation warning — would have made
    seeding fail on every stock NixOS host. The emitter now tries the pinned
    spelling and falls back. Found because the VM's Nix is the stable one; a
    host-only test would have shipped it.

  And the gate itself needed the vacuity lesson applied a fourth time, in a new
  form. `useNixStoreImage = true` severs the shared `/nix/store` that made three
  earlier gates vacuous — so this is the first gate here that can assert
  `consumer.fail("test -e <path>")` and mean it. But the test framework copies
  every derivation the **test script references** into each node's image
  (`nixos/lib/testing/testScript.nix:73`), so interpolating the probe's path
  into the script put the artifact on the consumer and undid the whole point.
  The probe is now discovered at runtime from the builder's minted narinfo,
  which is also how a real consumer learns it. The refusal leg additionally
  asserts the adapter *served* the bytes during the failed substitution: without
  that, "refused because untrusted" is indistinguishable from "refused because
  unavailable", which is precisely how a gate here went vacuous before.
- **Stage 6** — bounding what a peer key may vouch for, and giving the daemon a
  way to fail out loud. 133 unit tests, two new gates.

  Stage 5 shipped a trust it could not bound and documented the problem instead
  of fixing it. `trustedPublicKeys` put a key in `trusted-public-keys`, Nix
  cannot scope a key to a set of store paths, and the adapter sits at
  `Priority: 30` — so a compromised seeder could mint glibc and win the race.
  The fix is the observation that **every narinfo a peer supplies passes through
  this adapter**, so what Nix cannot bound, this can.

  The rule took two attempts and the first was wrong in the failing-open
  direction. "Scope it unless some signature names a key outside the peer set"
  treats a `cache.nixos.org-1` line as evidence upstream vouched for the path —
  but `Sig:` is attacker-supplied text and `checkSignatures` *counts* verifying
  signatures rather than requiring all of them, so one junk line disables the
  check while the real peer signature still gets the path registered. Telling
  forged from real means doing Ed25519, which this crate deliberately does not
  do. The shipped rule asks whether a peer key is involved at all: no
  verification needed, and adding signatures can only make a narinfo *more*
  scoped. The bypass is kept as a test.

  The name match took two attempts as well, and the second was caught by an
  assertion I had written before the code. `starts_with(entry + "-")` is not a
  version test: `glibc` reaches `glibc-locales`, `linux` reaches
  `linux-firmware`, and both are in every system closure. Nix splits pname from
  version at the first `-` followed by a non-letter; so does this now.

  An adversarial review of the design found three real gaps beyond those, all
  fixed here:
  * **One hostile peer could deny any path.** `LanTransport::narinfo` returns
    the first parseable answer and stops, so refusing in the caller meant the
    honest peers further down the list were never asked. The check moved into
    the loop.
  * **A lax host became a laundering relay.** All four `peer.rs` routes answer
    from `Cache::get_narinfo` with no scope check, so a host running `"*"` — or
    carrying an entry from before a tightening — would serve refused metadata
    onward to hosts that had refused it directly. One gate now covers all four.
  * **Refusals are remotely triggerable journal amplification.** Nix
    mass-queries closures; a hostile peer answering every request out-of-scope
    got one `warn` per path. Loud for the first 16, `debug` after.

  The observability half is the same lesson from the other side. Three stages
  running, the bug was something a passing gate could not distinguish from
  correct behaviour, and I had been treating that as a testing problem. It is
  not: `status` never contacted the daemon at all — every line was config echo,
  so it printed a cheerful report on a host where the daemon was dead. It also
  used `Cache::new`, which sweeps `tmp/`, so a routine status call could delete
  a slot a concurrent fetch was writing; `check` had been fixed for that and
  `status` was missed.

  `selftest` follows `plugind selftest` and does not report configuration — it
  exercises things. It runs as a **unit** sharing the daemon's sandbox verbatim,
  because `declared_refuses_a_write` proves `ReadOnlyPaths` by attempting a
  write, which only means anything inside the confinement it is testing. Two
  rules from `mcp_self_audit`: a check that inspected nothing is a FAIL, and a
  skipped check is reported rather than omitted — "zero declared narinfos, all
  valid" is the exact sentence that hid a stage-5 bug.

  The gate's real content is that it **breaks each guarantee in turn** and
  asserts the selftest notices: defeat the directory mode, defeat
  `ReadOnlyPaths`, corrupt a declared narinfo, empty the tier, stop the daemon,
  add `?trusted=1`. The first of those started as one leg and became two,
  because the first attempt did not fail: `declared/` is root-owned `0755`, so
  POSIX refuses the daemon user regardless of `ReadOnlyPaths`. Splitting it —
  defeat the mode alone, then both — proves the read-only mount does
  independent work, which is exactly the claim "configured" cannot support and
  only "attempted" can.
- **Stage 6a — closing the stage-6 gaps.** 135 unit tests. Four of the seven
  gaps stage 6 opened are now closed or narrowed, and one of them was closed by
  discovering it was smaller than I had written.

  **Gap 38 was overstated, and the correction is the most useful thing here.**
  The entry said a daemon RCE *is* the scope bypass, and therefore remote root
  at the next rebuild. That is wrong. Nix verifies a signature cryptographically
  and does not trust a key *name* — corrupting a `Sig:` line's base64 while
  leaving `cache.nixos.org-1:` in front of it yields `error: signature is not
  valid`, reproduced on real hardware rather than reasoned about. A compromised
  daemon holds no trusted private key, so it can serve only what is genuinely
  signed, or be refused. Daemon RCE buys denial of service and request
  visibility, not forgery. The scope's placement matters against an attacker
  holding **both** a trusted peer key and execution in the daemon: two
  compromises, not one. That materially changes the cost/benefit of the "clean
  fix" — re-signing in a privileged component — which needs Ed25519 and Nix's
  fingerprint format reimplemented here plus an IPC channel out of a daemon that
  has no `AF_UNIX` on purpose. Recorded as deliberately not built, with the
  condition under which it becomes right: peers the operator does not administer.

  **`acceptFromPeers` now takes packages** (gaps 37, 39). `[ pkgs.my-thing ]`
  renders to an exact store path at evaluation time — no build — so two machines
  on the same pinned flake agree exactly, and the grant cannot be satisfied by a
  peer choosing a convenient name, which a bare-name entry can. Names still work
  and still survive version bumps; the option now says which to prefer and why.

  That fix carried a trap worth recording: `toString` on a package produces a
  path string **with build context**, so writing it into the generated config
  would have made the package a dependency of the system closure — the consumer
  would build the very artifact it was configuring itself to fetch from a peer,
  silently voiding the option and, in the gate, putting the artifact on the
  node that was supposed not to have it. `unsafeDiscardStringContext` is
  load-bearing: naming a path you do not have is the entire idea.

  **Gap 41 closed**: `remove_narinfo` reads the digest out before unlinking and
  drops the artifact too, so a peer whose metadata was refused no longer leaves
  bytes consuming the cache budget until the size sweep notices.

  **Gap 43 narrowed**: `seed` records the count it published to
  `declared/.expected`, and `selftest` compares. It still cannot read
  `servePackages` — it runs as the daemon user with no Nix database access, by
  design — but a tier that has *lost* entries since the last seed run is now a
  FAIL rather than reading as "coherent". Publishing too few in the first place
  still needs a check where the intent is known.

  **Gap 40** is not fixable from this side; the remediation
  (`rm -f /root/.cache/nix/binary-cache-v*.sqlite*` after narrowing a scope) is
  documented in the option instead of left implicit.
