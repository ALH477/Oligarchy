# `custom.gc` — the Oligarchy garbage collector

Reclaims Nix profile generations, stale build links and build-artefact
directories. Opt-in, defaults off, and defaults to planning rather than
deleting.

## Why it exists

`configuration.nix` used to carry an unconditional weekly `nix-gc-generations`
oneshot: prune `/nix/var/nix/profiles/system` to the last 5 generations, then
run `nix-collect-garbage`. It ran for months on a machine that still reached
94% disk. It could not have helped, and the reason is worth keeping written
down, because the timer looked correct:

| | measured when this module was written |
|---|---|
| `/nix/store` | 219 GB |
| system generations | 8 — the only thing the timer pruned |
| **user / home-manager generations** | **11, never pruned** — the timer named the system profile only |
| **Nix auto-gcroots** | **122**, never pruned |
| of those, `result*` links in project dirs | 49, pinning ~9.9 GB of overlapping closures |
| Cargo `target/` + `node_modules` | 35 GB over 20 dirs, 0 tracked files |

**A gcroot prevents `nix-collect-garbage` from reclaiming its closure.** So the
garbage was pinned, not unnoticed, and running the old timer more often would
have changed nothing. That is the gap this module closes.

## Using it

```nix
custom.gc = {
  enable = true;
  roots  = [ "/home/asher/Documents/oligarchy2" ];
  workspace.enable = true;          # walks your source tree, so off by default
};
```

Then, in order:

```bash
oligarchy-gc status          # confirm Mode : DRY-RUN
oligarchy-gc plan | jq       # read what it WOULD do; deletes nothing, ever
# only once you believe the plan:
#   custom.gc.dryRun = false;  and rebuild
oligarchy-gc run
```

`plan` puts JSON on stdout and everything else on stderr, so
`oligarchy-gc plan | jq '.by_kind'` works. `run` refuses outright while
`dryRun = true`, and needs root only when the collectors that write Nix
profiles are enabled — retiring a `result` link or a `target/` dir in a tree
you own does not, and demanding `sudo` to `rm` your own files trains the wrong
reflex.

The timer (`custom.gc.timer.enable`, off by default) runs `oligarchy-gc gate`,
which collects only once free space on `/nix` has fallen to
`timer.minFreeGB`. Scheduled reclaim should answer pressure, not arrive on a
calendar — and in `dryRun` the gate resolves to `plan`, so the timer is safe
to enable before you have soaked it.

## The denylist cannot be emptied

`extraDeny` **appends** to a built-in list. There is deliberately no option
that replaces it:

| path | why |
|---|---|
| `/var/lib/oligarchy/plugins` | `oligarchy-plugins` registers a gcroot per installed plugin here; removing one unpins a live plugin's closure |
| `/var/lib/oligarchy/p2p` | the P2P artifact cache runs its **own** eviction budget, and publishing an entry is a `rename(2)` needing `nar/` and `tmp/` on one filesystem |
| `/var/lib/reliquary` | the preservation store. A collector that eats the archive is not a collector |
| `/home/asher/Documents/dsp`, `…/dsp-rust` | **DeMoD Secure Protocol** — private, and local-only *by choice*. A sweep that reads "no remote" as "unbacked, needs pushing" or "stale, needs reclaiming" has misread the intent in both directions |

A root **may** contain a denied path — `roots = [ "/srv/work" ]` with
`extraDeny = [ "/srv/work/keep" ]` is exactly what the denylist is for, and
pointing a root at `~/Documents`, which contains the two private trees, is
reasonable. Denied trees are **pruned at the traversal layer**: `find` never
descends into them, rather than descending and filtering the results. The
difference between skipping a match and never reading the tree matters for a
private repository. The verdict is then re-checked before a path enters the
plan, and a third time before anything is unlinked.

## Refusals

Eval-time, each naming the attribute path and what went wrong:

- a `roots` entry that is not absolute
- a whole-system root (`/`, `/nix`, `/home`, `/etc`, `/var`, `/usr`, `/boot`, `/run`)
- a root *inside* the denylist
- `workspace.enable = true` with `roots = [ ]` — that combination collects
  nothing while looking exactly like a clean disk
- a non-empty `preserve` (see below)

At runtime, every "couldn't determine" case is a refusal, never a
pass-through: a non-absolute path, anything containing `..`, an unresolvable
link, a root that vanished mid-run. This is the rule
`modules/reliquary/src/usb.rs` states as *"is refused, never waved through"* —
its earlier device check was unsafe precisely because a no-match silently
skipped the guard instead of stopping.

## `preserve` is reserved, and asserted empty

The seam for archive-before-delete: pack with `oligarchy-archive`, gate on
`reliquary verify` (which exits 2 on a bad block), delete the source only on
success. It is **not wired**, for two reasons.

Everything this module deletes today is regenerable — build artefacts, store
paths, surplus generations — so archiving it would be pointless. And
`modules/reliquary/docs/ADVERSARY_REVIEW.md` records two gaps that make
archive-then-delete unsafe regardless: reliquary does not `fsync` after write,
and `reliquary push` does not verify the destination copy. Until both are
closed, a successful archive is not proof the original is safe to delete, and
an assertion says so rather than letting the option quietly exist.

## No MCP surface

`oligarchy-gc` must never appear in `.mcp.json`. This is structural, not
stylistic: `modules/mcp-servers/crates/core/src/allowlist.rs` keeps the
`storage` aspect free of any binary capable of deleting, and a
`nix-collect-garbage --dry-run` tool was written for that aspect and then
*removed on purpose*, to keep the read-only property a fact about the
allowlist rather than a convention someone could erode. `.#mcp-self-audit`
fails the build if this lands there, and `.#gc-contract` asserts it too.

## Gates

```bash
nix build .#gc-contract   # eval-only: inert when off, and every refusal refuses
nix build .#test-gc       # the VM test: it actually deletes, and actually spares
```

The split is deliberate. An eval-only gate over a deleter is the
`windscribe-app` failure mode this repo records — eight green structural
assertions over a subsystem that did not work. So `.#test-gc` plants real
files and asserts **both** directions: the aged, in-root, non-denied paths are
gone afterwards, and the ones that are merely too new, inside `extraDeny`, or
outside every root are all still there.

`.#test-gc` leaves the Nix-side collectors off, and that gap is honest rather
than hidden: a test VM's store is the host's, so exercising generations or
`nix-collect-garbage` there would prove nothing about this module and could
only do harm. What the VM measures is the part this module actually decides —
which paths are in scope.
