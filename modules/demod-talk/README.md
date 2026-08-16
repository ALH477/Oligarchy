# `modules/demod-talk` — DCF-Talk on Oligarchy

Decentralized voice and text over the 17-byte `DeModFrame`, packaged as a
sub-flake in the same shape as `demod-voice/` and `mcp-servers/`.

**LGPL-3.0-only**, dual-licensed — same terms as the HydraMesh Lua it packages.
Commercial terms on request; see `LICENSING.md` in HydraMesh.

## Read this before enabling

DCF carries **no encryption**, deliberately, to keep the framework clear of
EAR/ITAR classification. Confidentiality is a property of the tunnel you run it
inside, not of the payload.

So `services.demod-talk.interface` is **mandatory and has no default**. The
module refuses to bind a wildcard address, opens the firewall on that interface
only, and asserts at build time that the interface is a WireGuard interface
declared on this host — unless you have picked an over-the-air transport, where
plaintext is expected and, on US amateur bands, legally required
(FCC Part 97.113(a)(4) prohibits obscuring meaning).

What the model defends against: external attackers, transit observation, and
malformed traffic — a fixed-offset 17-byte frame has no parser to exploit, so
the vulnerability class that defines this product category does not exist here.

What it does not: a compromised peer inside the tunnel, a malicious insider, or
the operator, who can read everything by design. Correct for a
trusted-membership deployment; wrong for a public network of strangers.

## Usage

`flake.nix`:

```nix
inputs.demod-talk.url = "path:./modules/demod-talk";
```

`configuration.nix` (off by default, per the repo convention):

```nix
services.demod-talk = {
  enable    = true;
  interface = "wg0";          # mandatory — the security boundary
  channel   = "basement-jam";
  transport = "wan";          # lan | wan | rf | acoustic | debug
  hub.enable = false;
};
```

## Transports

| tier | grouping | link cost, Opus 16 kbps | use |
|---|---|---|---|
| `lan` | SuperPack batched | 82 kbps | switched LAN |
| `wan` | SuperPack batched | 82 kbps | internet / VPN |
| `rf` | batched + RS(16) | 96.8 kbps | SDR |
| `acoustic` | batched + RS(32) | heavier | HydraModem |
| `debug` | one datagram per frame | **198 kbps** | packet captures only |

Batching is the largest win available and the numbers above are measured by
`dcf-talk`, not modelled. FEC *repairs* damage; packet-loss concealment only
*hides* it — at 30% corruption on `rf` every block plays with none concealed,
while the same damage without FEC conceals 18 of 60.

## Commands

- `dcf-talk` — the end-to-end demo and smoke tool (`--help` for flags)
- `dcf-jam` — the rendezvous demo from `lua/`
- `dcf-certify` — re-run every golden-vector certification against the installed
  store path, proving the copy you are running still reproduces the vectors

The package's `checkPhase` runs all six certifications plus four smoke modes, so
a module that fails certification **fails the build** rather than surprising you
at runtime. `nix flake check` surfaces the same as named checks.

## Not yet wired

This runs the in-process demo. Real sockets and real audio devices need the
`dm.net`, `dm.audio` and `dm.streamdb` bindings in demod-ui; until those land,
`services.demod-talk` exercises the stack rather than carrying a live call.
