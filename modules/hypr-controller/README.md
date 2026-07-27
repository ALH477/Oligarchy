# HyprController — a dedicated Android remote for Oligarchy's Hyprland session

Two pieces, both live in this directory:

```
nixos-module.nix, hypr_bridge.py   → the host side (services.dcf-hypr-agent)
android/                            → the phone side, open in Android Studio
```

Wired into `configuration.nix` (`./modules/hypr-controller/nixos-module.nix`,
next to `./modules/dcf-mesh-agent.nix`) but **off by default** — see
"Enabling it" below.

## Why it's shaped this way

Full wire-protocol writeup: [`docs/DCF_HYPR_SPEC.md`](docs/DCF_HYPR_SPEC.md) — a
vendored reference copy; the canonical version lives in the HydraMesh repo
alongside `DCF_CONTROL_SPEC.md` / `DCF_REMOTE_ENGINE.md`. Short version —
Tailscale, plain LAN, and a USB-gadget link aren't three protocols, they're
three ways to get an IP to the same UDP socket. DCF/HydraMesh is already
handshakeless UDP bound to `0.0.0.0`, so none of that transport logic touches
the wire protocol at all:

```
 Android (HyprController)                    Oligarchy (Hyprland box)
 ┌─────────────────────┐                    ┌───────────────────────────────┐
 │ TransportManager     │   UDP, host:port   │ demod-hypr-bridge (Python)    │
 │  saved-IP → mDNS →   │◄──────────────────►│  .socket.sock  (hyprctl)      │
 │  broadcast-ping       │   DCF-Hypr-Ctrl    │  .socket2.sock (events)       │
 │ HyprController (dcf)  │   DCF-Hypr-Tele    │  oligarchy-ctl (cats/items/   │
 │  Frame/Text/DcfNode   │                    │              run — reused)    │
 └─────────────────────┘                    └───────────────────────────────┘
```

Two channels ride the same socket: `hypr <dispatch>` for live window-manager
control (workspace/focus/float/fullscreen/kill), and `ctl <args>` which is a
byte-for-byte passthrough to your **existing** `oligarchy-ctl` — so the phone
gets the whole control center (personas, DSP rig, power, DCF fabric, security)
for free, no new bridge logic.

## Host side: `services.dcf-hypr-agent`

- `nixos-module.nix` — mirrors `dcf-mesh-agent.nix`'s option shape
  (`nodeId`/`peerId`/`udpPort`/channel names), plus `openFirewallInterfaces`
  (reachability), `spaGated` (wires `networking.firewall.spaGate` from
  `modules/security/dcf-spa-gate.nix` — see below) and `advertiseMdns`
  (publishes `_dcfhypr._udp` via avahi so NSD discovery has something to find;
  a no-op if `services.avahi` isn't on).
- `hypr_bridge.py` — pure stdlib, imports the canonical `wirelab_core` /
  `textlab_core` reference codecs from `python/MCP/` in the pinned
  `hydramesh` flake input (same posture as `dcf-mesh-agent`'s "no extra
  runtime deps"). Auto-discovers the Hyprland instance socket by globbing
  rather than trusting `HYPRLAND_INSTANCE_SIGNATURE` to have propagated into
  the systemd `--user` unit's environment, since that's a common real-world
  gap.

Like `dcf-mesh-agent`, **this is NOT part of the read-only Oligarchy MCP
surface** — the `ctl <args>` passthrough is arbitrary command execution by
design (see "Quick Exec" below), and the bridge binds a UDP socket at
startup. `nix build .#mcp-self-audit` fails the build if `dcf-hypr-agent` or
`demod-hypr-bridge` ever end up in `.mcp.json`.

### Enabling it

```nix
services.dcf-hypr-agent = {
  enable = true;
  udpPort = 7100;
  spaGated = true;       # gate the port on an untrusted LAN; see below
};
```

A commented-out copy of this block already sits in `configuration.nix` next
to the `dcf-mesh-agent` one.

### Reachability

`enable = true` alone used to leave the bridge unreachable on every path: the
global firewall opens only `5353/udp`, and `tailscale0` is deliberately *not* a
trusted interface here (`configuration.nix` admits ssh on it and nothing else).
The module now opens `udpPort` on `openFirewallInterfaces`, default
`[ "tailscale0" ]`. Add `usb0`/`rndis0` for a USB-gadget link, or set it to
`[ ]` to manage the firewall yourself.

For an untrusted LAN don't add the interface here — use `spaGated`, which gates
the port instead of opening it.

### DCF-SPA gating (`spaGated`)

Implemented by `modules/security/dcf-spa-gate.nix`
(`networking.firewall.spaGate`), **not** by upstream's
`spa/modules/dcf-spa.nix`. Upstream's module sets
`networking.nftables.enable = true`, which switches the global firewall backend
and collides head-on with `services.demod-ip-blocker`'s ipset/iptables
`extraCommands` — importing it fails eval outright.

So the gate follows the pattern `modules/security/strict-egress.nix` already
established: a self-contained `table inet dcf_spa_gate` loaded by its own
oneshot service, **coexisting** with the iptables firewall rather than
replacing it. Only upstream's *binary* is reused — `dcf-spa-authorizer` never
creates the table, it just runs `nft add element`, and the package already
wraps `nft` onto its PATH.

The chain is `policy accept`, deliberately not upstream's `policy drop`: both
netfilter backends run independently, so a `drop` in either is final while an
`accept` in one does not bypass the other. Everything except the gated port is
therefore left entirely to the existing firewall.

It is **authentication only, no confidentiality, no key exchange** (EAR99, see
`DCF_SPA_SPEC.md` §3, §10-11): a knock signed with a per-device key opens the
port to that source IP for `grantTtl` seconds, then it closes again.

**Gating forces IPv4.** The knock channel is v4-only and the allow-set is
`ipv4_addr`, so a v6 peer can never be authorized — v6 to the gated port is
dropped outright, or the gate would be trivially bypassable (Tailscale hands
out v6). A gated controller must connect to this box's v4 address.

Provision `spaCredsDir` (default `/etc/dcf-spa/peers`) with one file per
controller device. The directory is created for you; if it is empty the
authorizer **refuses to start** rather than leaving the port dark forever:

```bash
# Ed25519 (recommended)
openssl genpkey -algorithm ed25519 -outform DER | tail -c 32 | xxd -p -c 32
# -> the device's DCF_SPA_KEY (goes on the phone); derive the matching
#    32-byte raw public key and drop it in spaCredsDir as 0001.pub (hex)

# or HMAC (simpler): a random 32-byte PSK shared with the device, as 0001.key
```

See `DCF_SPA_SPEC.md` §11 for the full provisioning walk-through. Leave
`spaGated` off when the only path in is Tailscale or a direct USB-gadget link
— both are already a trusted/tunnelled path.

**What SPA does not cover.** It authenticates the *port*, not the protocol
above it: the bridge still has no signed `hello` (see Known gaps), so whoever
holds a live grant can drive `ctl` and Quick Exec. And a grant is per **source
IP** for `grantTtl` seconds, so anything sharing that IP — NAT, another device
on the same LAN — rides in with it. SPA meaningfully raises the bar against a
LAN attacker; it does not make Quick Exec safe on a hostile network.

## Phone side: `android/`

Open `android/` in Android Studio directly — it'll offer to generate the
Gradle wrapper on first open (nobody hand-wrote `gradle-wrapper.jar`; that's
a binary Android Studio manages). Bump `compileSdk`/`targetSdk` in
`android/app/build.gradle.kts` to whatever it suggests as current.

- `dcf/Frame.kt`, `dcf/DcfNode.kt` — vendored verbatim from HydraMesh's
  Kotlin SDK.
- `dcf/Text.kt` — the DCF-Text L2 codec, verified against
  `docs/DCF_HYPR_SPEC.md`'s framing + reassembly test vectors before being
  vendored in.
- `net/TransportManager.kt` — saved-host probe → NSD → broadcast-ping, in
  that order.
- `control/HyprController.kt` — owns the socket, the ACK/retry reliability
  classes, and the convenience API (`workspace()`, `moveFocus()`,
  `ctlRun()`, etc.).
- `ui/` — the Compose screen + a theme applying the DeMoD tokens
  (turquoise/violet/deep-black, monospace) rather than default Material.

First connect: tap **IP** in the top bar, type the box's Tailscale address
(simplest — Tailscale needs zero special handling here, it's just another IP
once you're on the tailnet), hit Connect. It's saved after that; subsequent
launches try it first.

## Transport notes

- **Tailscale (recommended default):** nothing app-specific to build —
  WireGuard already covers confidentiality, DCF rides inside it unmodified.
- **LAN:** works via NSD if you set `advertiseMdns = true` and run avahi, or
  via broadcast either way. On a network you don't fully control, turn on
  `spaGated` — it keeps the port dark until a signed knock arrives. Note that
  gating forces IPv4 (see above).
- **USB-gadget:** enable USB tethering on the phone while cabled to the box;
  both ends end up on a private subnet and broadcast-ping finds it the same
  way it finds plain LAN.

## Media, volume, and running commands

All of it rides the `hypr exec <cmd>` passthrough that already existed —
Hyprland's `exec` dispatcher doesn't care whether the command opens a window
or just runs in the background, so this needed zero bridge changes, just new
one-liners on the app side:

- **Media:** `playerctl play-pause` / `next` / `previous` — the same
  commands the XF86 media keys already run, so anything MPRIS-aware
  (Spotify, MPV, a browser tab) responds the same way it would to a physical
  key.
- **Volume:** `wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%+/-` and
  `set-mute … toggle` — PipeWire/WirePlumber, same 2% step the physical keys
  use.
- **Lock / screenshot:** `hyprlock` and
  `~/.config/hypr/scripts/screenshot.sh screen`.
- **Quick Exec, behind an "ADV" toggle:** a free-text field that runs
  *anything* via the same passthrough. This is genuinely different from
  every button above — those are each one fixed command; this is arbitrary
  remote code execution on the box, from your phone. It's hidden behind a
  tap on purpose. Fine over Tailscale or a direct USB-gadget link. On a
  network you don't fully control, `spaGated` keeps the port shut to everyone
  who hasn't knocked — but it does not authenticate the messages of whoever
  has, so this field stays as dangerous as its warning says.

## Licensing

This subsystem is **mixed-license** — check the SPDX header before copying a
file out of it:

| Path | License |
| --- | --- |
| `nixos-module.nix`, `hypr_bridge.py` | BSD-3-Clause (repo default) |
| `android/**/ltd/demod/hyprcontroller/**` | BSD-3-Clause |
| `android/*.gradle.kts`, `android/app/*.gradle.kts` | BSD-3-Clause |
| `android/**/kotlin/dcf/{Frame,Text,DcfNode}.kt` | **LGPL-3.0-only** (vendored from HydraMesh) |
| `docs/DCF_HYPR_SPEC.md` | DeMoD LLC, vendored reference copy |

The three `dcf/*.kt` files are the upstream HydraMesh Kotlin SDK carried in
verbatim; their LGPL-3.0-only headers are deliberately left intact and must
not be relicensed. Note that LGPL-3.0 has well-known friction with the way
Android statically links and ships app code — if that matters for
distributing a built APK, the options are to talk to upstream about a
relicense/linking exception, or to reimplement `Frame`/`Text`/`DcfNode`
against the normative wire specs (`DCF_TEXT_SPEC.md` + `golden_vectors.json`)
rather than vendoring. Nothing here blocks personal/in-house use.

## Known gaps

- The Ed25519 pairing-auth the spec describes for the LAN path is
  **documented, not implemented at the bridge level** — `spaGated` gets you
  the DCF-SPA port gate (a real, separate mechanism, see above), but
  `hypr_bridge.py` itself doesn't yet verify a signed `hello` above the wire.
  Worth adding before trusting this on a hostile LAN.
- Telemetry is single-active-peer (the bridge pushes events to whichever
  controller most recently sent it a valid op). Fine for one phone; would
  need a small peer registry for more.
- The `movefocus` "one fast retransmit" the spec's L4 section describes
  isn't implemented — it's a single fire-and-forget send right now.
- No foreground service on the Android side — the app's socket lives with
  the Activity/ViewModel, so background telemetry (a persistent notification
  of the active window, say) isn't there yet.
- Neither side has been run against a live Hyprland session or compiled with
  a Kotlin toolchain yet. What *has* been verified: both modules evaluate
  (enabled and gated, via `extendModules`); the SPA table loads into a real
  kernel in a netns, with a grant admitting a peer and expiring on its TTL;
  and the bridge's wire-protocol usage matches HydraMesh's actual
  `python/MCP/textlab_core.py`. Still unproven end-to-end: the Android build,
  and a `nixos-rebuild switch` on real hardware.
- `tests/default.nix -A dcf-spa-gate` covers the gate but has not been run —
  it builds a VM, which is left to run on demand.
