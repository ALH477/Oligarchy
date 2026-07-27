# DCF-Hypr — Remote Compositor Control over the DeModFrame Wire

**Version 1 (draft)** · DeMoD LLC · Normative. Companion to
[`WIRE_QUANTUM_SPEC.md`](WIRE_QUANTUM_SPEC.md), [`DCF_TEXT_SPEC.md`](DCF_TEXT_SPEC.md),
[`DCF_CONTROL_SPEC.md`](DCF_CONTROL_SPEC.md), and [`DCF_REMOTE_ENGINE.md`](DCF_REMOTE_ENGINE.md).

DCF-Hypr carries **compositor control operations** — the dispatches a controller sends a
running Hyprland session (switch workspace, move focus, float/kill/exec a window) — and the
**control-center action registry** (`oligarchy-ctl`'s `cats`/`items`/`run` verbs) over
HydraMesh. It introduces **no new wire format**: like DCF-Control, an op is an adapter over
the 17-byte `DeModFrame` quantum, serialised as DCF-Text messages. It exists so a **dedicated
handheld controller** (phone, tablet) can drive Oligarchy's Hyprland runtime over whichever
IP path currently connects the two devices — Tailscale, plain LAN, or a direct USB-gadget
link — without the transport ever touching the control vocabulary.

## Why this is small

Same shape as `DCF_REMOTE_ENGINE.md`: one bridge process on the compositor side, one client
on the controller side, and HydraMesh in between. Neither Hyprland nor `oligarchy-ctl` is
modified — both already speak a local, textual, unix-socket protocol; the bridge just relays
it.

```
   CONTROLLER (Android)                         COMPOSITOR HOST (Oligarchy)
 ┌────────────────────────┐             ┌──────────────────────────────────────────┐
 │ HyprController (app)   │             │  demod-hypr-bridge  (Python, stdlib)      │
 │  ├ dcf.DcfNode (UDP)    │             │   ├ dcf.DcfNode (UDP)                     │
 │  ├ dcf.Text (L2)        │◄──DCF-Hypr──┤   ├ dcf.text  (L2, textlab_core-equiv)     │
 │  └ TransportManager     │  ctrl+tele  │   ├─► hyprctl / .socket.sock  (dispatch)   │
 │     (Tailscale/LAN/USB) │    UDP      │   ├─► oligarchy-ctl  (cats/items/run)      │
 └────────────────────────┘             │   └◄─ .socket2.sock  (live events)         │
                                          └──────────────────────────────────────────┘
     DCF-Hypr-Control  (DATA frames, ACK-where-needed, dst = channel_id("demod-hypr-ctrl"))
     DCF-Hypr-Telemetry(DATA frames, lossy latest-wins, dst = channel_id("demod-hypr-tele"))
```

## Layered model

| Layer | What | Reuses |
|-------|------|--------|
| **L1** frame | 17-byte `DeModFrame`, `DATA` (type 0). | `codec/demod_frame.h` / `kotlin/…/Frame.kt` |
| **L2** framing | DCF-Text `packetize`/reassemble: op bytes ⇄ `DATA` frames. | `codec/demod_text.h`, `python/MCP/textlab_core.py` (certified) |
| **L3** op payload | v1 = two verbatim op families, byte-transparent relay (below). | none |
| **L4** reliability | ACK+retransmit for state-changing ops; fire-and-forget for focus-move/telemetry. | this doc |
| **L5** transport | one frame → one UDP datagram, `INADDR_ANY`; transport-agnostic. | `C_SDK/node/dcfnode.c` equivalent |

The op payload is opaque to L1–L2, so the vocabulary can grow (new dispatchers, new
`oligarchy-ctl` categories) without touching the wire certificate.

## L3 op payload (v1 = two verbatim families)

One DCF-Text message = one line of UTF-8. Two families, chosen by the bridge, both shipping
the **existing local protocol byte-for-byte** — same philosophy as DCF-Control §L3:

| Prefix | Relayed to | Example | Class |
|--------|-----------|---------|-------|
| `hypr <args>` | `hyprctl dispatch <args>` via `.socket.sock` (opened, written, read, **closed** per call — Hyprland freezes on an unclosed connection) | `hypr workspace 3`, `hypr movefocus l`, `hypr movetoworkspace 5`, `hypr togglefloating`, `hypr fullscreen`, `hypr killactive`, `hypr exec kitty` | see L4 |
| `ctl <args>` | `oligarchy-ctl <args>` (the existing `cats` / `items <cat>` / `run <action-id>` dispatcher already used by the Wofi menu and TUI) | `ctl cats`, `ctl items dcf`, `ctl run persona-studio` | request/response, always ACK'd (the reply *is* the ack) |
| `ping` | liveness only, no compositor call | `ping` → `pong <bridge_id> <uptime_s>` | heartbeat |

`ctl` is what makes the controller a front end for the **whole existing control center**
(personas, DSP rig, power profiles, DCF fabric status, security scans) for free — the bridge
never re-implements that registry, it shells out to the same script the Wofi menu calls.
`hypr` is the low-level, low-latency lane for live window-manager navigation — the part that
actually needs to feel like a game controller.

Telemetry (bridge → controller) needs **no translation at all**: each line read off
`.socket2.sock` (`EVENT>>DATA\n`, e.g. `workspace>>3`, `activewindow>>class,title`) is
relayed as its own DCF-Text message, verbatim, on the telemetry channel. The controller
parses the same event grammar any Hyprland IPC consumer would.

## L4 reliability (normative)

Mirrors DCF-Control's op classes, mapped onto compositor semantics:

- **state-changing** (`workspace`, `movetoworkspace`, `togglefloating`, `fullscreen`,
  `killactive`, `exec`, every `ctl run …`): sender MUST get an **ACK** (for `hypr`, a
  synthesized `{id, ok}` line from the bridge; for `ctl`, the relayed stdout itself) and
  retransmits on timeout — exponential backoff, cap 5 tries, ~250 ms window, identical to
  DCF-Control. Idempotent where the underlying dispatcher already is (re-`workspace 3` is a
  no-op).
- **event / latest-wins** (`movefocus`, rapid D-pad repeats): sent once, no ACK, one fast
  retransmit inside a short window. A dropped focus-move is corrected by the next tap; this
  keeps the D-pad feeling instant instead of RTT-gated.
- **telemetry** (`.socket2.sock` relay): fire-and-forget, latest-wins, deduped by
  `packet_id`. A dropped event is superseded by the next one; the controller can always
  force a resync with a `hypr <query> -j` state pull (see Certification/Phases below —
  state-pull queries are informative in v1, not yet specified as a distinct op).

Ordering: `packet_id` (6-bit, DCF-Text's own field) gives per-channel order; duplicates and
out-of-order fragments are handled exactly as `DCF_TEXT_SPEC.md` §Reassembly already
specifies — no new reassembly logic, just two independent `TextReassembler` instances (one
per channel/dst).

## Channel / addressing

Handshakeless, same idiom as DCF-Control. Two rendezvous channels via `dst_id =
channel_id(name)` (the existing `crc16(name)` hash):

- `channel_id("demod-hypr-ctrl")` — controller → bridge ops.
- `channel_id("demod-hypr-tele")` — bridge → controller telemetry.

Default node ids: controller = `0x0002`, bridge = `0x0001` (mirrors DCF-Control's
GUI=2/engine=1). Peers wire as `id@host:port`; each binds `INADDR_ANY` and `sendto`s the
peer. Liveness is the `ping`/`pong` pair above, on the control channel.

## Transport (informative — this is the point of the exercise)

`host:port` in the L5 UDP send is **just whatever IP currently reaches the compositor box**.
DCF-Hypr does not know or care which of these got the datagram there:

| Transport | What it is | Security posture (§Security) |
|-----------|-----------|-------------------------------|
| **Tailscale** | Controller and compositor both on the same tailnet; send to the box's `100.x.y.z` address. | WireGuard already covers confidentiality — the recommended default. |
| **LAN** | Same broadcast domain, mDNS/avahi-advertised or a saved IP. | Untrusted by default — gate the UDP port with DCF-SPA (below). |
| **USB-gadget** | Phone USB-tethered to the box; Android's RNDIS/NCM gadget puts both ends on a private point-to-point subnet. | Physically trusted link (matches DCF-Control's "trusted link: plaintext intended mode"). |

A controller-side transport manager's job is discovery/liveness (find which of these paths
is currently up), never protocol translation — one `DcfNode`, one UDP socket, three possible
routes to the same peer.

## Security

The wire is **encryption-free by design** (`DCF_SECURITY_EXPOSURE.md`); `hypr`/`ctl` ops are
forgeable by any on-path node, same as DCF-Control. Per transport:

- **USB-gadget (trusted, physical link):** plaintext is the intended mode. Optional
  Ed25519 pairing-auth (below) is cheap insurance against a lost/stolen phone but not
  required to function.
- **Tailscale (untrusted network, trusted tunnel):** the WireGuard tunnel is the
  confidentiality layer; DCF rides inside it unmodified, exactly as `DCF_CONTROL_SPEC.md`
  prescribes for "untrusted link: run the UDP inside a WireGuard tunnel."
- **LAN (untrusted network, no tunnel):** this is the mode that needs hardening.
  1. Gate the bridge's UDP port with **DCF-SPA** (`DCF_SPA_SPEC.md`, already implemented as
     `services.dcf-spa` / `dcf-spa-authorizer`): the port reads DROP to a scan; the
     controller sends one Ed25519-signed knock token before its first `hypr`/`ctl` frame.
  2. Layer the **optional Ed25519 pairing-auth ABOVE the wire** that `DCF_CONTROL_SPEC.md`
     already describes for its own GUI↔engine link: the bridge requires a signed `hello`
     from the controller's key before accepting ops from a new source address. This lives
     in L3/L4, never in the L1 codec, identically to DCF-Control.
  Neither mechanism adds confidentiality to the data plane — per `DCF_SPA_SPEC.md` §3, that
  boundary is what keeps both features authentication-only and EAR99. If the LAN is
  genuinely hostile, prefer Tailscale over hardening plaintext LAN further.

## Reference implementation targets

| Language | Role | Files |
|----------|------|-------|
| Python (bridge, stdlib only) | compositor-side relay: DCF ⇄ `.socket.sock`/`.socket2.sock` ⇄ `oligarchy-ctl` | `matrix-bridge`-style module, ships as `demod-hypr-bridge` |
| Kotlin (controller) | phone-side client | `dcf/Frame.kt`, `dcf/DcfNode.kt` (existing), `dcf/Text.kt` (new — DCF-Text L2 port, absent from the Kotlin SDK until now) |

## Certification

`Text.kt` must diff byte-for-byte against `Documentation/text_vectors.json`'s 9 framing + 4
reassembly cases, same as every other language port (see `DCF_TEXT_SPEC.md` §Certification).
No new vectors are needed for DCF-Hypr itself — L3 is opaque text, same as DCF-Control's JSON
relay — only the (already-certified) L2 framing matters.

## Phases

0. **Link** — `DcfNode` + `Text.kt` in the app; bridge binds, PING/PONG round-trips.
1. **Control** — `hypr <dispatch>` relay to `.socket.sock`; a workspace button on the phone
   changes the focused workspace on the box.
2. **Control-center passthrough** — `ctl <args>` relay to `oligarchy-ctl`; the phone can list
   and run every existing action (personas, DSP rig, power, security) with zero new
   compositor-side logic.
3. **Telemetry** — `.socket2.sock` relay; the phone UI reflects live workspace/window state
   instead of only sending blind commands.
4. **Hardening** — DCF-SPA gating for the LAN path, Ed25519 pairing-auth, a NixOS module
   (`services.dcf-hypr-agent`) mirroring `services.dcf-mesh-agent`'s option shape.

## Where it lives

- **HydraMesh**: this doc + `kotlin/…/dcf/Text.kt` + (later) `control_vectors.json` if a
  binary v2 op-codec is ever added, mirroring DCF-Control's optional v2 note.
- **Oligarchy**: `modules/dcf-hypr-agent.nix` (systemd user service) + the bridge script.
  Consumes HydraMesh as a pinned `hydra-mesh` flake input, exactly like `dcf-mesh-agent.nix`
  already does.
