# modules/companions — commanding ArchibaldOS companions

A **companion** is an older machine running ArchibaldOS's `companion` profile:
a headless music computer with JACK on its audio interface. It is sized for
4 GB and 2 cores (ArchibaldOS `docs/companion.md`). This module makes an
Oligarchy host its commander:

```nix truth:ignore
custom.companions.enable = true;   # hub wg-companions 10.77.0.1/24, UDP 51877
```

```bash truth:ignore
oligarchy-companion enroll surface asher@192.168.1.42   # once; uses its password once
# add the printed custom.companions.members.surface entry, rebuild this host
oligarchy-companion status surface                       # dsp-ctl over SSH, through the tunnel
oligarchy-companion deploy surface                       # build HERE, switch it, sync /etc/nixos back
```

## Design

- **Plaintext rule.** The DSP control protocol and DCF carry no encryption
  (export posture), so the link beneath them is WireGuard. The companion
  dials; the hub only listens. Each peer's `allowedIPs` is its own /32. The
  companion's control bridge admits the hub's address only, on its tunnel
  interface only (ArchibaldOS `modules/companion.nix`).
- **Built here.** `deploy` runs `nixos-rebuild --target-host root@<tunnel>`
  against a local copy of the companion's flake. A 4 GB machine never
  compiles, and the linux-surface kernel compiles in minutes here instead of
  hours there.
- **One flake, two copies, kept identical.** After each deploy, the copy is
  synced to the companion's `/etc/nixos`, and the previous one is kept as
  `/etc/nixos.prev`. If someone edited the companion's `hosts/installed`
  since the last sync, `deploy` refuses: `pull` takes their version, and
  `--force` overwrites it.
- **Enrolment uses the password once.** A fresh companion takes password SSH
  (ArchibaldOS warns about it at build time). `enroll` copies its flake,
  writes `hosts/installed/commander.nix` (hub address, hub key, your SSH key,
  its tunnel address), installs it, and has the companion switch once. After
  that the companion takes keys only, and root takes only your key.
- **No keys in the store, none in the CLI.** The hub's private key is
  generated at first start (0600, root). The CLI reads the public half from
  `/run/oligarchy-companions/hub.pub`, and member data from
  `/etc/oligarchy/companions.json`, which holds no keys.

Read-write, and it reaches other machines, so like `dsp-ctl` it stays **off
the MCP surface**. Opt-in and default off; when disabled it emits nothing, so
the ISO needs no `mkForce`.

## Gate

`nix build .#companion-cli-tests` runs the real script against a fake
companion. Stubs replace ssh, the remote side, `nixos-rebuild`, `dsp-ctl`,
`ip` and `getent`; the fake ssh runs remote commands on a scratch tree. Eight
checks:
- `enroll` produces a `commander.nix` that **evaluates** to the attrset
  ArchibaldOS's module reads, installs it, switches the companion, and reads
  the key back as root;
- `enroll` refuses a non-companion;
- `deploy` builds here, syncs back, and refuses to clobber a remote edit;
- `status` drives `dsp-ctl` correctly.

The gate found a real bug while it was being written. With no companion
enrolled yet, the address allocator's last `[ -f ]` failed inside a pipeline,
and `set -e` + `pipefail` ended `enroll` with no message.

Not measured: a real SSH session, a real switch, a real tunnel.
ArchibaldOS's `checks.installed-contract` evaluates the same `commander.nix`
shape against the module itself.
