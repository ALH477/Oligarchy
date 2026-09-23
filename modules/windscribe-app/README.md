# windscribe-app — the vendor Windscribe client

`custom.windscribeApp`. Opt-in, defaults off. The GUI, `windscribe-cli`, and
the root helper daemon from
[Windscribe/Desktop-App](https://github.com/Windscribe/Desktop-App), GPLv2.

**This is the alternative to `custom.vpn` (`modules/vpn.nix`), not a companion.**
Both take the default route, and an assertion refuses to have both enabled.

| | `custom.vpn` | `custom.windscribeApp` |
|---|---|---|
| what runs | kernel WireGuard via `wg-quick` | vendor client + root helper daemon |
| config | one sops-held `.conf`, declarative | the client's own GUI and account state |
| server choice | the one you generated a config for | the full picker, at runtime |
| extras | none | R.O.B.E.R.T., split tunnelling, port forwarding, protocol switching |
| code you run | nixpkgs WireGuard | a 48 MB vendor binary |
| on demand | yes, `autoStart = false` | helper always up, GUI launched by hand |

## Why this is not built from source

Upstream's Linux build wants the network at configure time in three separate
places, and a Nix build has none.

1. **vcpkg against a custom registry.** `tools/vcpkg/vcpkg-configuration.json`
   points at `github.com/Windscribe/ws-vcpkg-registry` for patched `qtbase`,
   `openssl`, `curl` with the `ech` feature, `openvpn`, `c-ares`, `spdlog` and
   about twenty more. The registry holds portfiles, not sources, so every
   port's upstream tarball would need pinning too.
2. **`FetchContent` at configure time.** `cmake/fetch_wsnet.cmake` clones
   `github.com/Windscribe/wsnet` at tag 1.5.34.1 while CMake is running.
3. **Qt built from `tools/deps`.** The documented Linux path builds Qt itself
   before the app.

A faithful source build means pinning vcpkg, the registry, wsnet and roughly
forty upstream tarballs as fixed-output derivations, then making vcpkg run
fully offline against them. That is a real project, not a module.

So this packages the release `.deb` instead, which is the same artifact Debian,
Fedora, openSUSE and Arch users install. Version and hash live at the top of
`pkgs/windscribe-desktop.nix`; bump both together and rebuild.

## Landmines

- **The helper hard-requires a group named `windscribe`, and fails silently
  without it.** `src/helper/linux/server.cpp` `getgrnam()`s it and, on failure,
  `unlink`s its own control socket and returns. The unit stays `active`, one
  line lands in the journal, and the client simply never connects. The module
  declares `users.groups.windscribe` for exactly this reason.
- **Upstream ships the GUI setgid (`chmod 2755` in the deb postinst); this
  module uses group membership instead.** A setgid bit does not survive into
  the Nix store, and reproducing it would mean a `security.wrappers` setgid
  wrapper. `custom.windscribeApp.users` adds accounts to the group, which is
  the same access without the setgid surface. It costs a re-login the first
  time.
- **`/opt/windscribe` is compiled in, not looked up.** `WS_LINUX_INSTALL_DIR`
  is a `-D` define (`CMakeLists.txt:240`), and the helper executes
  `/opt/windscribe/scripts/*` by absolute path. A tmpfiles `L+` rule points it
  at the store. `autoPatchelfHook` already rewrote the library RPATHs, so the
  symlink is for the scripts and the helper, not for the loader.
- **The helper's scripts are `#!/bin/bash` and assume an FHS `PATH`.** NixOS
  has no `/bin/bash`, and the shipped unit pins
  `PATH=/usr/sbin:/usr/bin:/sbin:/bin`, which holds none of `ip`, `nft`,
  `mount` or `resolvectl`. The package rewrites each shebang and prepends a
  store `PATH` **inside each script**, so they work regardless of what the
  helper hands down; the module's own unit sets a real `path` as well.
- **In-app update is replaced with a refusal, deliberately.** The shipped
  `install-update` dpkg-installs a downloaded package over `/opt/windscribe`,
  which here is a read-only store symlink. Leaving it in place would produce a
  permissions error; the replacement says what is actually going on.
- **`/etc/windscribe/platform` must hold a value the client recognises.** It
  picks the updater's artifact extension, and an unrecognised value leaves the
  download path empty and trips an assert
  (`engine/autoupdater/downloadhelper.cpp`). The module writes
  `linux_deb_x64` / `linux_deb_arm64` to match the artifact actually unpacked.
- **Qt is statically linked into the client**, so there is no Qt plugin path to
  wrap and no `wrapQtAppsHook`. The X, Wayland, GL and fontconfig stack is the
  whole of the dependency set. Three libraries are bundled: `libwsnet.so` and
  Windscribe's own `libcrypto`/`libssl` at soname 4, which is not a stock
  OpenSSL soname and is why they are not substituted.
- **The helper unit is deliberately unsandboxed.** Its job is to rewrite the
  routing table, the nftables ruleset, cgroups and `/etc/resolv.conf` as root.
  Every `ProtectSystem` or `RestrictAddressFamilies` line that looks like an
  improvement breaks one of those, and breaks it at connect time rather than at
  start time.
- **Its firewall and this repo's firewalls are separate rulesets.** The helper
  installs its own nftables tables for the kill switch and split tunnelling,
  alongside `strict-egress`'s `inet strict-egress` table and
  `ip-blocklists`/`demod-ip-blocker`'s iptables rules. They coexist the same
  way those already do, but nothing arbitrates between them.
- **`allowServerEgress` is a port-shaped hole, and that is the honest cost.**
  The client picks from a runtime-fetched pool of hundreds of server
  addresses, so unlike `custom.vpn` there is no endpoint to allowlist. Turn it
  off and the client cannot connect under an enforcing egress policy.
- **Two of the five bundled helpers are Go binaries, and `autoPatchelfHook`
  corrupts them into an immediate SIGSEGV on exec.** `windscribewstunnel` and
  `windscribeamneziawg` are Go; rewriting a Go binary's ELF layout to carry a
  store interpreter path makes its runtime crash at startup, on this machine
  reproducibly (rc 139). The client never surfaces a loader error — it only
  ever logs `"wstunnel failed to start"` and
  `ConnectionManager::onConnectionPrepareFailed(), error = 5`, which reads
  like a server-side or network problem, not a packaging one. It takes out
  WireGuard/AmneziaWG along with WStunnel/Stealth, and silently: nothing in
  the journal names a binary or a loader.
- **The fix applies `patchelf` to those two binaries TWICE, and the second
  call is load-bearing.** `auto-patchelf.py` rewrites each file in two
  separate subprocess calls (`--set-interpreter`, then `--set-rpath`); both
  that split and a single combined call leave a *fresh* copy of these two
  crashing. Only re-running the combined call on the already-rewritten file
  produces a working binary — measured over eight fresh-copy trials, four per
  binary. The working theory is that the first pass has to grow and relocate
  the ELF layout to fit a store-length interpreter plus an rpath, and the
  second rewrites a file already padded to fit. `--no-clobber-old-sections`
  would be the principled fix and is **not available**: nixpkgs 25.11 pins
  patchelf 0.15.2 and that flag arrived in 0.18. So the duplicated
  `patchelf` line in `preFixup` is not a copy-paste slip — deleting it
  restores the bug. Guarded by `.#test-windscribe-app`'s exec-smoke check
  (every bundled binary must run without dying on a signal) and by the
  package's own `installCheckPhase`.

## Commands

```bash
windscribe                 # the GUI
windscribe-cli login       # the CLI; `windscribe-cli --help` for the rest
systemctl status windscribe-helper
journalctl -u windscribe-helper -f
sudo tail -f /var/log/windscribe/helper_log.txt
```

Client logs live in `~/.local/share/Windscribe/Windscribe2`.

## Gates

```bash
nix build .#test-windscribe-app   # group, /opt tree, helper socket, CLI
nix build .#mcp-self-audit        # this is read-write and stays out of .mcp.json
```
