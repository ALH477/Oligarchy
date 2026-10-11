# services.oligarchyHaven — Haven on Oligarchy

A self-hosted Discord alternative ([Haven](https://github.com/ancsemi/Haven)) as
a sandboxed, opt-in NixOS service.

- **Defaults OFF.** Flip `services.oligarchyHaven.enable = true` in `configuration.nix`
  (or a host layer); never edit `nixos-module.nix` to turn it on.
- **Tailnet-only.** The server binds loopback and the port is admitted on
  `services.oligarchyHaven.interface` (default `tailscale0`) only. The tailnet is the
  membership boundary: anyone who can reach the server can register.

## Quick start

```nix
services.oligarchyHaven = {
  enable = true;
  serverName = "The War Machine";
  # interface = "tailscale0";   # default
  # port = 3000;                # default
};
```

Rebuild, then open `https://<host>.<tailnet>.ts.net:3000` and register
`admin` (the first registration becomes admin). Haven generates a self-signed
certificate on first boot; accept the warning once.

## Licence posture (AGPL-3.0)

Haven is AGPL-3.0. This repo does **not** vendor it:

- `packages/haven.nix` fetches an immutable release tag
  (`v4.21.0`, commit `b69bea7`) at build time and builds it **unmodified** —
  no patches, no vendored source. The AGPL §13 obligation to publish modified
  source applies only when you run a *modified* network service, so a stock
  deployment of this package carries no such obligation.
- The upstream `LICENSE` ships inside the derivation; `meta.license` declares
  `agpl3Only` so the closure records it.
- The module glue (`nixos-module.nix`, `flake.nix`, this README) is DeMoD
  BSD-3-Clause, covered by the `modules/haven/**` block in the repo root
  `REUSE.toml`.

**If you fork and patch the package**, add the AGPL §13 offer-of-source note
here and keep the patched source available to the server's users. Do not remove
the `meta.license` declaration.

## Updates

Haven's in-app one-click updater cannot work against an immutable `/nix/store`
install. Updates are pin bumps: edit `version`/`rev` in `packages/haven.nix`,
refresh the two hashes (`nix-prefetch-url --unpack` for the tarball,
`prefetch-npm-deps` for `package-lock.json`), and rebuild.

## Secrets

`JWT_SECRET` is provisioned via sops:

```nix
custom.secrets.enable = true;
custom.secrets.haven.enable = true;
services.oligarchyHaven.sops.enable = true;
```

Mint the encrypted file as `modules/secrets/haven.enc.env` containing
`JWT_SECRET=<long random string>`, then `git add` it (the module's assertion
tells you the exact steps). With sops off, Haven auto-generates a secret into
its data dir — acceptable for a single-host tailnet only.

## Optional outbound features and strict-egress

Voice is peer-to-peer (client-side WebRTC + STUN), so this module opens **no
UDP ports** and no relay. If you enable features that make outbound calls
(STUN NAT-punching, push notifications, GIF search, the built-in tunnel), and
you run `networking.firewall.strictEgress`, the module emits a warning listing
the hosts to add to your `configuration.nix` allowlist. It never writes them
itself — strict-egress pulls, and one auditable allowlist is the point.

## Sandbox notes

The service runs as a dynamic `haven` user under a near-total systemd hardening
stanza (`ProtectSystem=strict`, `NoNewPrivileges`, `RestrictNamespaces`,
`SystemCallFilter=@system-service`, empty capability set, …). The one
deliberate exemption is `MemoryDenyWriteExecute = false`, required by Node's V8
JIT — see the module header for the reasoning and how it relates to the plugin
W^X policy (AGENTS.md rule 3).
