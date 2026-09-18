# Adversary audit — oligarchy-scrollmapper 1.0.1

Reviewer stance: treat the module as an untrusted drop-in on a hardened
NixOS host (Oligarchy). Goal is boot integrity, supply-chain honesty,
least privilege, and “does the option actually do what it says.”

Scope: this directory only. Not the Godot Scrollmapper app. Not
Oligarchy’s other modules except the interfaces we touch
(`services.boot-intro`, `services.oligarchyGreeting`, Plymouth, getty).

---

## Verdict

Shipable as an optional path module after the 1.0.1 fixes. Do not
enable `bootDialogue.console` on headless or serial-console appliances
until you have watched one boot. Do not treat KJVA as “the Orthodox
Study Bible.”

Residual risk is documented under Accepted.

---

## Findings

### F1 — Translation option was a no-op (High, fixed)

`custom.scrollmapper.translation` wrote an environment variable but the
NixOS module always installed `flake.packages.<system>.default` (KJVA).
Selecting `BSB` still shipped KJVA and then failed at runtime if the
CLI honored the env var.

Fix: `pkgs.callPackage ./package.nix { translation = cfg.translation; }`.

### F2 — Wrapper `--set` pinned canon (High, fixed)

`makeWrapper --set SCROLLMAPPER_CANON orthodox` overrides the process
environment. The module’s `environment.variables` could not win. Users
could not actually switch canon or translation without rebuilding the
wrapper.

Fix: `--set-default`.

### F3 — IFD + 10 MiB fetch at module eval (High, fixed)

`builtins.readFile (pkg + "/share/scrollmapper/sample.tsv")` forced a
package build (and the GitHub fetch) during NixOS evaluation just to
fill getty issue text.

Fix: read `./sample.tsv` from the module source tree.

### F4 — Early-boot unit could stall sysinit (High, fixed)

`DefaultDependencies = false`, `wantedBy = sysinit.target`, no
timeout, `set -euo pipefail`, and a hard `exec`. A missing tool or a
closed `/run` would either abort the unit noisily or, worse, hang
Plymouth quit.

Fix: unit never fails the boot (`exit 0` on every fault),
`TimeoutStartSec = 5`, `Conflicts = shutdown.target`,
`SuccessExitStatus = 0 1`, no `set -e`.

### F5 — Login path loaded the full JSON (Medium, fixed)

`dailyVerse.onLogin` ran `scrollmapper daily`, which parsed ~10 MiB of
JSON in every interactive bash. That is the opposite of low-footprint
and adds avoidable latency on the war-room shell.

Fix: curated `boot-pool.tsv` (143 verses, ~19 KiB). `daily` defaults
to `--pool`. `--full` remains for people who want the whole canon.

### F6 — `notify-send` from a system unit (Medium, fixed)

The timer ran as root with no session bus. Notifications either died
or, on a misconfigured host, popped up as root.

Fix: `systemd.user.services` + `systemd.user.timers`, after
`graphical-session.target`, `libnotify` from the store.

### F7 — Global `environment.variables` (Medium, fixed)

`SCROLLMAPPER_*` was exported into every service via
`environment.variables`. Useless clutter and a footgun for units that
forward the whole environ into a container.

Fix: `environment.sessionVariables` only.

### F8 — Alias collisions (Low, fixed)

`verse` and `sm` are common names. Off by default (`aliases = false`).

### F9 — Source closure leaked the module tree (Low, fixed)

`src = ./.` would copy `__pycache__`, README, audit notes, and
anything else that later lands in the folder.

Fix: `lib.fileset.toSource` allowlist.

### F10 — agetty issue `%` expansion (Low, fixed)

`/etc/issue.d` is processed by agetty. A `%s` / `%b` in verse text
becomes hostname / baud. Current KJVA pool has none; still escape `%`
→ `%%`.

### F11 — Unsanitized Plymouth / console payload (Low, fixed)

A corrupted pool line with `ESC` or CR could scribble the splash or
the console. Boot script now strips C0 controls.

### F12 — Unicode box drawing on early console (Low, fixed)

vt fonts often lack `┌│└`. Console banner is ASCII.

### F13 — Dead flake app and typo output (Low, fixed)

`apps.daily` pointed at the CLI with no args. Package output `cpvd`
was a typo for `cpdv`.

### F14 — Greeting / boot-intro option writes when disabled (Low, fixed)

Tips and `bottomText` were written whenever the *option* existed, not
when the service was enabled.

### F15 — Unpinned `master` branch URLs (Accepted, mitigated)

`fetchurl` uses `.../bible_databases/master/formats/json/<T>.json`.
The SRI hash is the real pin. If upstream rewrites history, the build
fails closed. An adversary who can match the hash already has those
bytes.

Not accepted: swapping the hash without a human diff of the JSON.

### F16 — “Orthodox canon” overclaim (Accepted)

KJVA is Protestant KJV plus the KJV Apocrypha. It is the best
permissive English dump Scrollmapper publishes. It is **not** the
Orthodox Study Bible, not Brenton’s LXX, not the Church of Greece
order, and it lacks standalone 3 Maccabees and Psalm 151.

The book *filter* is Orthodox. The *text* is KJVA. README says so.

### F17 — `/dev/console` write is dual-use (Accepted)

An early `printf` to `/dev/console` is the boot dialogue the user
asked for. It can also interleave with kernel oops text and confuse
serial consoles. Default is on; switch off with
`bootDialogue.console = false`.

### F18 — World-readable `/run/scrollmapper` (Accepted)

Verses are not secrets. 0644 lets a user session reuse the boot pick
without a second parse. Do not put secrets in this directory later.

### F19 — Plymouth in the unit PATH (Accepted, conditional)

`pkgs.plymouth` is only added when `bootDialogue.plymouth = true`.
Calling `plymouth` when the daemon is down is ignored.

### F20 — No `flake.lock` in the tarball (Accepted)

This is a path submodule. Oligarchy’s root flake must lock it. A
nested lock that pins a second nixpkgs 25.11 is how you get two
python3s. Documented in the README.

### F21 — `lib.fileset` requires nixpkgs ≥ 23.11 (Accepted)

Oligarchy is on 25.11.

### F22 — No automated Nix eval in this environment (Accepted)

The authoring host has Python but not `nix`. Review is static plus a
stdlib CLI dry-run. A consumer must `nix build .#kjva` before merge.

---

## Attack sketches that do not land

| Sketch | Why it dies |
|---|---|
| Swap KJVA.json on GitHub raw | SRI mismatch, build fails |
| Embed ANSI in pool to hijack Plymouth | stripped |
| `%s` in issue.d to leak hostname stylistically | escaped; also not a secret |
| Make the oneshot block graphical.target | 5 s cap, never `set -e` |
| Use daily notify as root priv-esc via notify-send | now a user unit |
| Override canon via env to read off-canon books the package did not install | only installed JSON exists; missing file is a hard error |
| `sm` alias shadows a user binary | aliases off by default |

---

## Residual test plan for the integrator

1. `nix build path:./modules/scrollmapper#kjva` then
   `./result/bin/scrollmapper info`.
2. `nixos-rebuild dry-activate` with only `custom.scrollmapper.enable`.
3. Boot a VM with Plymouth on and off; confirm sysinit time delta < 1 s.
4. Flip `translation = "KJV"` and confirm store path changes and
   `scrollmapper books` drops Tobit.
5. `dailyVerse.notify = true` as a desktop user; confirm the unit is
   `user`, not `system`.
6. Do not merge if `boot-intro.bottomText` overrides a host that already
   set it — we use `mkDefault`.
