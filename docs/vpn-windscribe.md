# Windscribe over WireGuard (`custom.vpn`)

`modules/vpn.nix`. Opt-in, defaults off, and **on demand even when enabled** —
nothing routes through Windscribe until you ask for it.

> **There are two ways to run Windscribe on this system and they are mutually
> exclusive.** This document covers `custom.vpn`, the declarative wg-quick
> path. `custom.windscribeApp` (`modules/windscribe-app/`) runs the vendor
> client instead: a GUI, the server picker, R.O.B.E.R.T., split tunnelling and
> a root helper daemon. Both take the default route, so an assertion refuses to
> have both enabled. Pick `custom.vpn` for a declarative tunnel you turn on by
> hand with no vendor code in the path; pick `custom.windscribeApp` when you
> want to switch servers and protocols from a window.

There is no `windscribe` package in nixpkgs and the vendor client is a `.deb`
that wants a root helper daemon. None of that is needed. Windscribe's config
generator hands out a complete `wg-quick` config, so the whole subscription
reduces to one encrypted blob plus kernel WireGuard.

## Setup

### 1. An age key, once

`.sops.yaml` ships with a literal placeholder recipient. Nothing can be
encrypted until a real public key replaces it.

```bash
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt   # prints the PUBLIC key
sudo chmod 600 /var/lib/sops-nix/key.txt
```

Paste the printed public key over the `age1PLACEHOLDER...` line in `.sops.yaml`.

### 2. A config from Windscribe

<https://windscribe.com/getconfig/wireguard> — pick a location, pick **port
443** unless you have a reason not to, choose New Key Pair, download.

Selectable ports are 53, 80, 123, 443, 1194 and 65142. 443 is the one most
likely to survive a hostile network.

### 3. Import it

```bash
cd ~/Documents/oligarchy2/Oligarchy
oligarchy-vpn import ~/Downloads/Windscribe-*.conf
```

This encrypts the config to `modules/secrets/windscribe-wg.enc.conf` (safe to
commit; the plaintext is gitignored) and prints the `custom.vpn.endpoints` line
that goes with it.

### 4. Turn it on

In `~/.config/oligarchy/local.nix`:

```nix
custom.secrets.vpn.enable = true;
custom.vpn.enable = true;
custom.vpn.endpoints = [ "184.75.223.226:443" ];   # from step 3
```

```bash
sudo nixos-rebuild switch --flake .#nixos --impure
```

`--impure` is not optional. Without it `local.nix` is silently ignored — pure
evaluation answers `false` to the `pathExists` guard rather than erroring.

## Using it

| | |
|---|---|
| `oligarchy-vpn up` / `down` / `toggle` | the tunnel |
| `oligarchy-vpn status` | interface, peer, DNS, default route |
| `Super+Shift+V` | toggle, with a notification |
| `Super+Ctrl+V` | full status in a terminal |
| waybar | a glyph beside the network group; click toggles |
| control center | Network → Windscribe VPN |

All of them funnel through the same CLI, so they report state identically. No
password prompt: a polkit rule scoped to this one unit lets `wheel` start and
stop it.

## What it does and does not guarantee

**Full tunnel.** `AllowedIPs = 0.0.0.0/0` in the Windscribe config, so while
the tunnel is up everything goes through it. `wg-quick`'s policy routing keeps
LAN and link-local traffic on the local segment, so Steam Remote Play discovery
and any other LAN service keeps working.

**No kill switch.** If the tunnel drops, traffic falls back to the plain route.
This is deliberate: the failure mode of a kill switch on a laptop is a machine
that is offline for a reason nothing on screen explains.

**On demand.** `autoStart` is false and meant to stay false. A full tunnel on
every boot costs latency on every game and every voice call, and without a kill
switch that is not a trade worth paying continuously.

## Discord and Steam

Both work with the tunnel up and with it down, but for different reasons, and
both are worth understanding before changing anything here.

**With the tunnel down**, `strict-egress` is the boundary. Discord's web
endpoints are allowlisted by domain in `configuration.nix`; its **voice** is
not, and cannot be — a voice server is handed out per call from a pool spanning
unrelated networks. That is what the UDP 50000-65535 entry in
`strictEgress.allow.ports` is for. Steam is the same story and was already
handled: store and CDN by domain, game and Source traffic by the 27000-27100
port range.

**With the tunnel up**, `custom.vpn.trustTunnel` (default on) adds the tunnel
interface to `strictEgress.allow.interfaces`, so traffic leaving through it is
not filtered by destination at all.

Name the cost plainly: while the tunnel is up, `strict-egress` constrains
nothing that routes through it, and Windscribe is the egress boundary instead.
Set `trustTunnel = false` to keep the boundary local. Ordinary traffic is
unaffected either way — the filter keys on destination address and a tunnelled
packet still carries the real destination, so every `allow.domains` entry keeps
matching through the tunnel. It is specifically the IP-diverse UDP that starts
hitting the drop.

Two gaming caveats that are not this module's to fix. Windscribe throttles or
blocks peer-to-peer on some locations, which affects Steam downloads. And some
multiplayer services ban shared VPN addresses outright, which looks like a game
problem rather than a VPN one.

## DNS

The Windscribe config carries `DNS = 10.255.255.3`, its in-tunnel resolver and
the one that serves R.O.B.E.R.T. filtering. That line alone does not take
effect on this host: `services.resolved` is configured with
`domains = [ "~." ]` globally, which makes the global resolvers a candidate for
every name, and `wg-quick`'s resolvconf call sets link DNS without a routing
domain to outrank it.

`custom.vpn.dns.useTunnelDns` (default on) closes that by setting `~.` on the
link itself in `ExecStartPost`. This is about **which resolver sees your
queries**, not about a plaintext leak — queries go through the tunnel either
way.

Both `resolvectl` calls carry systemd's `-` ignore-failure prefix. Without it a
resolvectl that cannot reach resolved fails `ExecStartPost`, which fails the
unit, which tears the tunnel down. A DNS preference is not worth the tunnel.

## Troubleshooting

**The tunnel comes up but nothing reaches the internet.** Check
`custom.vpn.endpoints`. The outer encapsulated packet is an ordinary UDP
datagram to that address, and both `strict-egress` and the IP blocklists filter
it. There is a build-time assertion for the enforcing case, but under
`recovery.dryRun = true` (this host's current setting) a missing endpoint just
shows up as `STRICT-EGRESS-WOULDBLOCK` in the kernel log:

```bash
journalctl -kf | grep STRICT-EGRESS
```

**No handshake at all, no error anywhere.** Suspect
`services.demod-ip-blocker` first. It is enabled here, its feed is a
**VPN-provider egress list**, it inserts `INPUT ... src -j DROP` at position 1
of the INPUT chain, and — unlike `networking.firewall.blocklists` — it has **no
allowlist option**. If a Windscribe endpoint lands on that feed the return
traffic is dropped before conntrack sees it and nothing logs a reason. Test by
disabling `services.demod-ip-blocker` for one rebuild.

```bash
sudo iptables -L INPUT -n --line-numbers | head
sudo oligarchy-blocklist panic          # the other blocklist's escape hatch
```

**`sops` fails during `oligarchy-vpn import`.** Either `.sops.yaml` still holds
the placeholder (the CLI checks and says so) or the file does not match a
creation rule. The rule is `modules/secrets/.*\.enc\.(env|yaml|json|conf)$`.

**Eval fails with "path does not exist" for `windscribe-wg.enc.conf`.**
`custom.secrets.vpn.enable` is on but the secret has not been minted yet. Run
the import first. The existing `dcf-id.enc.env` consumer behaves the same way.

**Keys stop working after regenerating in the web UI.** Windscribe invalidates
the previous key pair when you generate a new one. Re-import.

## Gates

```bash
nix build .#test-vpn             # on-demand start, interface hatch, endpoint allow, MTU, DNS, CLI
nix build .#test-strict-egress   # the allow.interfaces addition did not move the existing chain
nix build .#mcp-self-audit       # oligarchy-vpn is read-write and stays out of the MCP surface
```
