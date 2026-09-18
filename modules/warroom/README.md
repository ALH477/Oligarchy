# warroom — the Oligarchy War Room

A Rust/Ratatui **unified command center** for the machine: one screen carrying
system, DSP, mesh, perimeter, network, AI and forge state, plus a runner for the
`oligarchy-ctl` action registry. Binary name: `warroom`.

Opt-in, **defaults off** (`custom.warroom.enable`). It is a normal read-write
user tool — same category as `dsp-ctl` and `oligarchy-forge` — so it is **not
part of the read-only MCP surface** and must never appear in `.mcp.json`
(`nix build .#mcp-self-audit` fails the build if it does).

## Why it exists

The bash `oligarchy-warroom.sh` cockpit collects everything on the draw thread:
one slow subprocess and the whole screen — keypresses included — stops. This
design fixes exactly that. `collect::spawn` gives **one thread per collector**,
each on its own interval, all writing into a single channel; the UI thread only
ever drains that channel, so a hung `dsp-ctl` or an unreachable mesh peer costs
its own pane a timeout and never a frame.

Two rules fall out of that and are load-bearing:

- **Staleness is rendered, not hidden.** `Freshness` is `Fresh` / `Stale(dur)` /
  `Failed(err)` / `Unavailable(why)`, and the widget layer must show them
  differently. A dashboard showing a stale green dot is worse than no dashboard.
- **Color is never the signal.** Every health dot carries its text label
  (`OK`/`WARN`/`FAIL`/`--`) from `Health::label()`, in the TUI and in the CLI.

## It does not replace the bash control center

`warroom` **coexists with** the existing control-center trio
(`home/apps/control-center/`) rather than replacing it, and deleting any of them
is not part of this work:

| tool | shape | still the right tool for |
|---|---|---|
| `oligarchy-control` | fzf menu | quick keyboard-driven toggles from any shell |
| `oligarchy-update` | fzf wizard | the guided rebuild/update flow |
| `oligarchy-ctl` | **the dispatcher** | scripts, the Wofi hub, the Android bridge |
| `oligarchy.sh` | fzf menu | redundant third front-end; superseded by this TUI |
| `warroom` | Ratatui | live, non-blocking, whole-machine situational awareness |

**`oligarchy-ctl` remains the shared action registry.** The War Room drives it —
it does not fork it. That dispatcher already has a **non-terminal consumer**:
`modules/hypr-controller/hypr_bridge.py` forwards to it over UDP for the Android
companion app. Reimplementing its PATH-probing and action list in Rust would
split that single source of truth the day it was written, so `warroom` shells
out to `oligarchy-ctl cats` / `items <cat>` / `run <id>` instead.

For the same reason the TUI **hands off** rather than absorbs: `D` suspends the
screen and runs `dsp-ctl`, `F` runs `oligarchy-forge`. Those tools already do
their jobs; the War Room is a hub, not a monolith.

## The six tabs

| # | tab | what it carries |
|---|---|---|
| 1 | `SITREP` | rollup card per subsystem: load, memory, temps, uptime, persona, power, kernel |
| 2 | `DSP` | DSP VM state, JACK/PipeWire quantum, NETJACK latency; `D` hands off to `dsp-ctl` |
| 3 | `MESH` | HydraMesh / DCF node status and peer table |
| 4 | `PERIMETER` | strict-egress, blocklists, malware shield, listening ports |
| 5 | `ORDNANCE` | the `oligarchy-ctl` catalog, fuzzy-filterable and runnable |
| 6 | `TRAFFIC` | the output log of everything this session ran |

## Keys

```
1-6 / Tab / Shift-Tab   select pane
r                       refresh every collector now
t                       cycle theme
D                       hand off to dsp-ctl
F                       hand off to oligarchy-forge
?                       help overlay
q / Esc                 stand down
```

In `ORDNANCE`: `j`/`k` or arrows navigate, `/` fuzzy-filters, `Enter` runs,
`Esc` clears the filter.

Destructive actions go through a confirm modal. The gated set is a **literal
list** (`actions::DESTRUCTIVE` plus the `kernel-` / `gpu-` / `persona-`
prefixes), not a heuristic on the id string: a heuristic that quietly stops
matching after someone renames an action fails *open*, and failing open here
means restarting the mesh without asking.

## CLI surface

Bare `warroom` (or `warroom tui`) launches the TUI, matching `forge-cli`'s
k9s/lazydocker convention. The non-TUI subcommands all run **one collection pass
and exit** — they never enter the interval loop.

```bash
warroom                 # the TUI
warroom status          # one-shot colored sitrep
warroom status --json   # the same pass as machine-readable JSON
warroom doctor          # per-collector availability + probe latency
warroom actions         # dump the oligarchy-ctl catalog
warroom actions --json
```

Global flags: `--theme <id>`, `--no-theme-sync`, `--no-splash`.

### `warroom doctor`

Exists because of a lesson this repo already paid for: *a tool that returns
nothing looks like a healthy tool with nothing to say.* `doctor` separates "this
subsystem is off" from "this subsystem is broken" from "I am being run without
the privilege to see it", by printing each collector's probe result, the reason
when it is `MISSING`, its interval, and how long the probe took.

### `warroom status --json` — the forward hook

This is the integration point, and it is the reason the JSON shape matters more
than the human one. A waybar module, the greeter, or a future
`/run/oligarchy-warroom/status.json` cache can all consume it without linking
the TUI. The payload is `warroom_core::model::Snapshot` serialized verbatim —
the contract lives in the data layer next to the collectors that fill it, not in
an ad-hoc struct in the CLI:

```json
{
  "ts": "2026-09-18T06:31:13Z",
  "host": "nixos",
  "panels": [
    {
      "id": "system",
      "title": "SITREP",
      "state": "fresh",
      "health": "good",
      "summary": "load 2.95 · mem 17% · dev · balanced",
      "rows": [
        { "label": "load", "value": "2.95 2.18 2.00 / 16 cpu", "health": "good" }
      ],
      "table": { "headers": ["peer", "rtt"], "rows": [["fw13", "2ms"]] }
    }
  ]
}
```

- `ts` — RFC3339 UTC. Hand-rolled from `SystemTime`; no `chrono`/`time`
  dependency is pulled in for one string.
- `state` — `"fresh"`, `"failed"` or `"unavailable"`. These mirror the TUI's
  `Freshness` variants minus `stale`: a one-shot pass has nothing older than
  itself. **A consumer must branch on this**, or it will render an
  `unavailable` pane as a healthy one with an empty body.
- `health` — `"good" | "warn" | "bad" | "unknown"`, lowercase.
- `rows` — always present, possibly empty (`failed` and `unavailable` panels
  carry the reason in `summary` and no rows).
- `table` — **omitted entirely** when absent (`skip_serializing_if`), so consume
  it as optional, not as `null`.

Panels appear in SITREP display order, the same order every run, which is what
makes the human form diffable and the JSON form stable.

Human output drops all ANSI escapes when stdout is not a terminal or `NO_COLOR`
is set, so piping it into a log or a parser is safe.

`warroom actions` depends on `warroom_core::actions::catalog()`. While that is
still a stub it returns an error, and the CLI **propagates it unchanged** — a
hand-rolled fallback would fork the dispatcher this tool exists to drive.

## Theming

Two sources, in this order:

1. **Built-in DeMoD palette** (`warroom_core::theme::DEMOD`), transcribed from
   `home/themes/default.nix` (`palettes.demod`), which is ground truth. The
   palette table in `docs/architecture.md` is a stale snapshot and is not used.
2. **Opportunistic sync**: the active theme id is read from
   `~/.config/demod/theme.json` (what `theme-switch.sh` writes) or
   `~/.config/oligarchy/themes/manifest.json`, then its palette from
   `~/.config/oligarchy/themes/<id>/palette.json`.

Every step of (2) **fails silently back to (1)**. A missing directory, a
malformed JSON file, a theme id with no palette — none of them are errors, and
none of them change what the tool does. Theming is decoration; a decoration
failure must never take down a status display.

`warroom-core` carries no ratatui dependency, so colors are plain RGB triples;
`warroom-tui`'s `Skin` converts them and degrades to the nearest of the 16 ANSI
colors on terminals without truecolor.

`--theme <id>` forces a specific theme; `--no-theme-sync` (or
`WARROOM_THEME_SYNC=0`) ignores `~/.config` entirely and uses the built-in
palette.

## NixOS options

```nix
custom.warroom = {
  enable     = true;   # default false
  package    = ...;    # defaults to this sub-flake's package
  splash     = true;   # -> WARROOM_SPLASH;     "0" disables
  themeSync  = true;   # -> WARROOM_THEME_SYNC; "0" disables
  defaultTui = false;  # point the greeter's TUI launch at `warroom`
};
```

Both booleans are exported through `environment.sessionVariables`; the
command-line flags (`--no-splash`, `--no-theme-sync`) win over them.

`defaultTui = true` sets `services.oligarchyGreeting.tui.launchCommand` to this
package's `warroom` binary. `configuration.nix` sets that option to
`oligarchy-control` with `mkDefault`, so the assignment here (normal priority)
wins with no explicit override. It is safe to reference that option because the
top-level flake imports `greeting.nixosModules.greeting` unconditionally in
`commonModules`; a standalone consumer of this module that does *not* import the
greeting module should leave `defaultTui` at `false`.

With `enable = false` the module adds **nothing at all** — no package, no unit,
no session variable — so, like `modules/android-mirror`, the ISO needs no
`lib.mkForce` for it.

## Layout

```
modules/warroom/
├── flake.nix                     # packages.default = warroom, nixosModules.default
├── nixos-module.nix              # custom.warroom.*
└── crates/
    ├── warroom-core/             # data layer, NO tui dependency
    │   └── src/
    │       ├── model.rs          # Health / Freshness / Panel / Snapshot — the contract
    │       ├── collect/          # one file per subsystem + the thread scheduler
    │       ├── actions.rs        # the oligarchy-ctl catalog
    │       ├── exec.rs           # subprocess with a hard timeout, never a shell
    │       └── theme.rs          # DeMoD palette + opportunistic palette.json
    └── warroom-tui/
        └── src/
            ├── main.rs           # clap surface; bare invocation = TUI
            ├── cli.rs            # status / doctor / actions
            ├── app.rs            # state, keys, the confirm gate
            ├── handoff.rs        # suspend the TUI, run dsp-ctl/forge, restore
            └── ui/               # one module per tab + shared widgets
```

`warroom-core` is deliberately free of any TUI dependency: everything in it is
equally usable by the Ratatui front-end, by `warroom status --json`, and by
whatever reads that JSON later.

`exec::run` never uses a shell (`Command::new(prog).args(args)`) and always
carries a timeout. A collector that hangs must cost its own thread a timeout,
never the UI a frame.

## Building

```bash
nix build ./modules/warroom     # the sub-flake alone
cd modules/warroom && cargo test --workspace
```

New files are invisible to `nix build` until `git add`ed — a flake only sees
git-tracked content.
