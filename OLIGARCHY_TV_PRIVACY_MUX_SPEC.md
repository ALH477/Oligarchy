# Oligarchy Theater Face — TV Privacy Mux Specification

**Status:** Draft 0.1 — design spec, not implemented  
**Target tree:** `github:ALH477/Oligarchy`  
**Module path (proposed):** `modules/tv-privacy/`  
**Option namespace:** `custom.tvPrivacy`  
**Persona:** `theater`  
**Date:** 2026-09-08  
**This document is normative for the design.** Implementation may lag; where code and this file disagree, this file wins until a version bump.

Companion to `docs/architecture.md` and `docs/security-hardening.md`. It does not change the DCF 17-byte wire quantum. DCF identity (`custom.dcfIdentity`) is a billing service and is **out of scope**.

---

## 0. One-sentence claim

Oligarchy remains the only networked computer in the living room. The television is a dumb sink. A small muxer rewrites every identifier the sink, a capture card, or a downstream player can read — display, control-bus, container, and LAN — without touching pixels unless a live remux is requested.

---

## 1. Goals

1. Present a **generic, session-scoped face** on HDMI (CEC) and on any container that leaves the box so service IDs, PIDs, muxer tags, and timestamps do not identify the host or the source file. EDID firmware is used only for local hygiene (see §7.4).
2. Present a **generic, session-scoped face** on any container that leaves the box (MPEG-TS, MP4, MKV, fMP4) so service IDs, PIDs, muxer tags, and timestamps do not identify the host or the source file.
3. Keep the TV **off the trusted LAN**. The Hyprland box is the only stack that originates WAN traffic.
4. Fit Oligarchy's existing control plane: one persona, a handful of `oligarchy-ctl` actions, no new MCP write surface.
5. Be reproducible. Same flake + same policy + same session seed ⇒ same public identifiers. Different session seed ⇒ unlinkable identifiers.

## 2. Non-goals

The following are **forbidden** in this module. An implementation that does any of them is non-conformant.

- Circumventing HDCP, Widevine, PlayReady, FairPlay, or any DRM handshake.
- Forging another device's HDCP KSVs, CDM device certificates, or attested keys.
- Decrypting, re-encrypting, or stripping encryption from protected content.
- Attacking, probing, or reconfiguring a television that is not the operator's sink.
- Claiming to make a smart-TV OS "private" while that OS still has a WAN path. This spec assumes the panel's ethernet/Wi-Fi is dark.
- Changing Hyprland's DRM backend device (iGPU stays the compositor; see `docs/dgpu-steam-forcing.md`).

Privacy here is **identifier hygiene on hardware and streams you own**.

---

## 3. Threat model

### 3.1 Assets

| Asset | Why it matters |
|---|---|
| Host hostname, username, Machine-ID | Written into container tags, CEC OSD, mDNS |
| HDMI EDID serial / product / week | Logged by TVs, AVRs, capture cards, some GPUs |
| CEC vendor ID + OSD string | Shown in the TV input list; persisted across boots |
| MPEG-TS `service_id`, `transport_stream_id`, PIDs, SDT names | Fingerprint a library or a box across recordings |
| Encoder / muxer metadata (`handler_name`, `encoding_tool`, creation time) | Ties a file to a machine and a software build |
| WLAN / ethernet MAC, mDNS, Cast/WFD device ID | Stable LAN identity |
| ACR / automatic content recognition | Smart-TV OS screenshots or audio fingerprints — **mitigated by isolating the TV**, not by this muxer |

### 3.2 Adversaries

- The television firmware and its vendor cloud, if the panel is ever allowed on a network.
- An AVR, soundbar, or HDMI switch that caches EDID/CEC.
- A capture card or DVR that archives whatever identifiers ride in the container.
- A local network observer (mDNS, DHCP hostname, Cast beacon).
- A curious app on the Hyprland box that reads `/sys/class/drm/*/edid` or container tags. In-box attackers with root are out of scope; Nix store and root are already the TCB.

### 3.3 Out of scope adversaries

- TEMPEST / HDMI-cable emanation reconstruction.
- Someone with physical I²C access who reads the panel EEPROM itself (local EDID firmware changes what the *host* reads, not the sink's factory EEPROM).
- Supply-chain compromise of nixpkgs or the GPU blob.

### 3.4 Success criteria

A conformant deployment is successful if, after a session:

1. `edid-decode` on the host connector shows the scrubbed vendor/product/serial (local `/sys` + store hygiene), not the panel serial leftover, and not the operator's name. This does not prove what the TV stored.
2. `cec-ctl -s` reports the configured OSD string, not the hostname.
3. `ffprobe` on any file that passed the muxer shows empty or policy-generic metadata and the remapped TS identifiers.
4. The TV has no layer-3 path to the internet (operator-enforced; the module can only *remind*).
5. Two consecutive `ephemeral` sessions produce different public IDs. A `generic` session produces the same public IDs every time.

---

## 4. Vocabulary

| Term | Meaning |
|---|---|
| **Sink** | The television or projector. Treated as display-only. |
| **Face** | The set of identifiers this module emits toward the sink and toward files. |
| **Session** | One arming of the theater persona until disarm, reboot, or explicit `rekey`. |
| **Policy** | `generic` \| `ephemeral` \| `rotating`. |
| **Muxer** | The process that rewrites container and elementary-stream identifiers. Does not mean an HDMI switch ASIC. |
| **Link face** | CEC OSD / vendor / logical address. Lives on the cable. Local EDID hygiene is not a link face (see §7). |
| **Stream face** | PAT/PMT/SDT/NIT + container tags + stripped SEI. Lives in bytes. |
| **LAN face** | hostname, MAC, mDNS, Cast name. Lives on the network. |
| **Seed S** | 256-bit session secret. Never written into a container. |
| **Public ID** | Anything derived from S that is allowed to leave the box. |

---

## 5. System shape

```
                    custom.tvPrivacy.enable
                              │
              ┌───────────────┼────────────────┐
              │               │                │
        link face        stream face        LAN face
        (CEC)           (privacy-muxd)     (host/mdns)
              │               │                │
              └─────── theater persona ────────┘
                              │
                     oligarchy-ctl tv-*
                              │
                        Hyprland session
                     DRM connector → sink
```

Three faces, one seed, one control-plane category `tv`.

Default-off. The installer ISO must `mkForce` this module off, same convention as `dcfIdentity` / `strictEgress`.

---

## 6. Session seed

### 6.1 Inputs

```
host_secret     256-bit, age-sops, path custom.tvPrivacy.seedFile
                default /var/lib/oligarchy/tv-privacy/seed
date_bucket     YYYY-MM-DD in policy.rotating, else the string "static"
session_n       monotonic u64 in /var/lib/oligarchy/tv-privacy/session
connector       DRM name, e.g. "HDMI-A-1"
policy          "generic" | "ephemeral" | "rotating"
```

### 6.2 Derivation

```
S = HKDF-SHA256(
      ikm  = host_secret,
      salt = "oligarchy.tv-privacy.v1",
      info = policy || 0x00 || date_bucket || 0x00 || connector || 0x00 || le64(session_n)
    )   // 32 bytes
```

`generic` forces `date_bucket = "static"` and `session_n = 0`, so the face is stable across boots. That is intentional: a living-room TV that forgets its input name every night is worse UX than a bland stable name.

`ephemeral` increments `session_n` on every arm.

`rotating` increments `session_n` when `date_bucket` changes (midnight local, or `custom.tvPrivacy.rotateHours`).

### 6.3 What may be derived from S

Only through labeled HKDF expands:

```
edid_serial_u32     = expand(S, "edid-serial", 4)
cec_osd             = printable(expand(S, "cec-osd", 8))    // if policy != generic
ts_sid              = 1 + (expand(S, "ts-sid", 2) % 0xFFFE)
ts_tsid             = 1 + (expand(S, "ts-tsid", 2) % 0xFFFE)
ts_onid             = 0xFF00 | expand(S, "ts-onid", 1)
pid_perm_key        = expand(S, "pid-perm", 32)
lan_suffix          = hex(expand(S, "lan-suffix", 3))
```

No other public field may be a raw slice of S or of `host_secret`.

---

## 7. Local EDID hygiene (not a link face)

The module captures the panel EDID on first enable so that:
- The real TV serial is never copied into the world-readable Nix store.
- `/sys/class/drm/*/edid` never contains the panel serial for a curious local process.

It does **not** change what the TV sees. HDMI EDID is a sink-to-source protocol; `drm.edid_firmware` replaces the blob the kernel reads from the panel. The TV never receives it.

(See §7.4 for the capture/scrub pipeline. The resulting `theater.bin` is only used for stable mode timing on the host side.)

### 7.1 What we change (host-side blob only)

The kernel is told to use a **scrubbed EDID** as the local connector blob via `drm.edid_firmware=<connector>:edid/oligarchy-theater.bin`. This changes what the host and local processes observe, not what the sink stores.

Preserve (required, otherwise the mode set breaks):

- Established / standard / detailed timing descriptors needed for the target mode.
- Physical size if `custom.tvPrivacy.edid.keepMmSize = true` (default true — DPI and Hyprland scale depend on it).
- Colorimetry and bit-depth **only if** `edid.keepColor = true` (default true).
- Audio data block if the operator is sending audio over the same HDMI cable (default keep).

Scrub or replace (required):

| Field | `generic` | `ephemeral` / `rotating` |
|---|---|---|
| Vendor PNP ID | `custom.tvPrivacy.edid.vendor` default `OGA` | same (do not rotate vendor; AVRs cache it) |
| Product code | `0x0001` | `0x0001` |
| Serial | `0` | `edid_serial_u32` |
| Week / year | `0 / 2020` | `0 / 2020` |
| Monitor name (0xFC) | `THEATER` | `THEATER` |
| ASCII serial (0xFF) | omitted | omitted |

Checksums of every 128-byte block SHALL be rewritten. A blob that fails `edid-decode --check` SHALL NOT be installed.

### 7.2 What we do not invent

- Do not advertise HDR, VRR, ALLM, or HDMI 2.1 FRL if the captured panel EDID lacked them, unless `edid.allowCapabilityLift = true` (default false). Lifting capabilities is an interoperability hack, not a privacy feature, and it causes black screens.
- Do not advertise a larger timing set than the panel accepted. Capture first, then scrub.

### 7.3 Pipeline

```
1. On first enable: copy /sys/class/drm/card*-<connector>/edid → state/captured.bin
2. Run oligarchy-edid-scrub --policy … --in captured.bin --out theater.bin
3. Install to firmware tree used by initramfs (must be in initrd; nvidia-drm and amdgpu probe connectors before rootfs).
4. Kernel cmdline += drm.edid_firmware=<connector>:edid/oligarchy-theater.bin
5. Rebuild + reboot required for the link face. Live EDID rewrite is not promised.
```

Live rewrite via I²C from userspace is **optional and unsupported**. Too many GPUs ignore a mid-session EEPROM poke without an HPD pulse, and pulsing HPD drops the Hyprland output.

### 7.4 Capture hygiene

`captured.bin` stays on disk because timings come from it. It contains the real serial. Mode `0600`, directory `0700`, not copied into the world-readable Nix store. The store receives only the **scrubbed** blob.

---

## 8. Link face — CEC

### 8.1 Policy

| Field | `generic` | `ephemeral` / `rotating` |
|---|---|---|
| OSD string | `custom.tvPrivacy.cec.osd` default `Player` | `Player-` + 4 hex from `cec_osd` |
| Vendor ID | `0x000000` (unregistered) | same |
| Logical address | Playback device 1 (`0x4`) | same |
| Physical address | derived from EDID as usual | same |

### 8.2 Behaviour

A systemd user unit `oligarchy-cec-face.service` runs after the graphical session:

```
cec-ctl -d $DEV --playback --osd-name "$OSD" --phys-addr-from-edid $EDID_PATH
```

Required flags / policy bits:

- `cec.ignoreStandby = true` (default): do not let the TV power-off command suspend the PC.
- `cec.ignoreRouting = true` (default): ignore `<Active Source>` wars from a soundbar.
- `cec.offerSource = false` (default): do not broadcast Active Source on boot. The operator switches the input.

If no CEC adapter exists (some USB-C docks), the unit exits 0 and logs `cec.unavailable`. Missing CEC is not a build failure.

### 8.3 What we do not do

No CEC traffic injection toward other devices on the bus except the legal device-identity replies. No recording-device impersonation, no deck-control fuzzing.

---

## 9. Stream face — the muxer algorithm

This is the piece named in the original brief. It is a **deterministic identifier permutation plus a metadata knife**. It is not a video codec.

### 9.1 Process

`oligarchy-privacy-muxd` — a small Rust binary (C is acceptable; shell wrappers around ffmpeg are acceptable for v0 if they implement the same public-ID mapping).

Two modes:

- `file` — stdin/path → stdout/path, `-c copy` remux.
- `live` — MPEG-TS over Unix socket or UDP loopback, for a capture/record path.

Pixels are copied. If a decode is required (container the remuxer cannot bitstream-copy), the unit SHALL refuse unless `--allow-reencode` is set. Reencode is a quality/latency choice, not a privacy primitive.

### 9.2 MPEG-TS identifier law

Let `P` be the set of PIDs present in the input, excluding:

- `0x0000` PAT (kept)
- `0x0001` CAT (dropped — we emit no CA descriptors)
- `0x1FFF` stuffing (kept as stuffing)

Let `Q` be the destination PID space `{0x0100, 0x0101, …, 0x01FF}` ∪ `{0x1000, …, 0x10FF}`. 512 slots. Enough for any consumer TS.

Build a permutation `π: P → Q` as follows:

```
order = sort(P)
seed  = pid_perm_key
for i, pid in enumerate(order):
    π[pid] = Q[ (LE_u16(HKDF_expand(seed, "pid"||le16(pid), 2)) + i) % len(Q) ]
    # collision: linear probe Q
```

Then rewrite:

| Structure | Action |
|---|---|
| PAT | single program, `program_number = ts_sid`, PMT PID = `π[old_pmt]` |
| PMT | every elementary PID through `π`; PCR PID through `π`; drop CA descriptors; drop private descriptors whose tag is not in the allowlist `{0x0A language, 0x0E max bitrate, 0x11 STD, 0x1B AVC, 0x28 HEVC, 0x52 stream identifier}` |
| CAT | drop |
| SDT | rewrite to one service, name = `custom.tvPrivacy.stream.serviceName` default `TV`, provider = empty, `service_id = ts_sid` |
| NIT / BAT / EIT / TDT / TOT | drop |
| PES | rewrite PID only; continuity counter starts at 0 on the first packet of each new PID |
| adaptation PCR | rewrite so it still lives on `π[old_pcr]` |
| stuffing | optional CBR pad to `stream.cbrKbps` if set |

`transport_stream_id` in PAT and SDT = `ts_tsid`.  
`original_network_id` if an NIT is *not* dropped for some interoperability reason = `ts_onid`. Default is drop NIT.

### 9.3 MP4 / MKV / WebM knife

Bitstream copy, then:

Required deletions:

- `major_brand` / compatible brands left as the container requires; do not add a unique encoder brand.
- `handler_name`, `encoding_tool`, `encoder`, `comment`, `title` unless `stream.keepTitle = true` (default false).
- creation / modification timestamps → `1970-01-01T00:00:00Z` or omitted.
- UID / SegmentUID / TrackUID in MKV → fresh random from S (`expand(S, "mkv-uid-"+track, 16)`).
- attachments, tags, chapters that contain free text.
- `iTunes` / `©too` atoms.

Required keeps:

- codec config (AVCC/HVCC/AV1C, audio CSD).
- colour primaries / transfer / matrix if present. These are not identifiers.
- language tags if `stream.keepLanguage = true` (default true).

`+bitexact` or the equivalent flag is mandatory so muxer version strings do not reappear.

### 9.4 Elementary-stream knife

On bitstream copy we do not rewrite slice data. We drop access-unit-level SEI that is not required to decode:

Drop:

- user-data unregistered SEI (often encoder names, x264/x265 build strings).
- timing SEI that is redundant with the container (optional, `stream.dropTimingSei = true` default).

Keep:

- HDR10 / HLG metadata SEI and Dolby Vision RPU if present. Those are picture, not identity.
- prefix SEI required by the profile.

If the implementation cannot parse NAL/OBU boundaries safely, it SHALL leave the elementary stream untouched rather than risk a broken bitstream. Refusing is conformant. Guessing is not.

### 9.5 Live path

```
Hyprland output
    → wf-recorder or PipeWire portal (operator choice)
    → ffmpeg/pipe raw or annex-B
    → oligarchy-privacy-muxd --live
    → file, or UDP 127.0.0.1 only
```

Binding the live muxer to `0.0.0.0` is a spec violation. WAN streaming is the operator's separate stack (Jellyfin, etc.) and must consume the *already rewritten* face over localhost.

### 9.6 Idempotence

Muxing an already-muxed file with the same S and policy SHALL produce equivalent public IDs (PIDs may already sit in Q; the implementation SHALL detect a theater-face comment atom / TS private descriptor tag `0xE0` "OGA1" and pass through). This prevents PID ping-pong in a watch folder.

The private descriptor `0xE0` payload is exactly four bytes `OGA1`. It is a marker, not a tracking tag. Do not put S, hostname, or hashes of the source path in it.

---

## 10. LAN face

Applied only while the theater persona is active.

| Knob | Default | Behaviour |
|---|---|---|
| `lan.hostname` | `player` | transient hostname via `systemd-hostnamed`, restored on disarm |
| `lan.avahi` | off | already off in Oligarchy hardening; assert it stays off |
| `lan.randomMac` | true | random MAC on the interface used for optional WFD/Cast; address derived from `lan_suffix` so it is stable for one session |
| `lan.castName` | `Player` | if a Cast/WFD helper is installed, feed it this name |
| `lan.blockWellKnownAcr` | true | extra nft set of vendor ACR / smart-TV phone-home destinations, composed with `demod-ip-blocker` and optional `strictEgress` |

The module SHALL NOT enable Wi-Fi on the television. It MAY print a motd / control-center warning: `sink should be offline`.

Machine-ID (`/etc/machine-id`) is **not** rotated. Too much of systemd is keyed on it. The muxer and CEC/EDID faces are the public surface; machine-id stays a local secret.

---

## 11. Hyprland / persona integration

### 11.1 New persona `theater`

Add to `modules/personas.nix`:

```
theater = {
  description = "Theater — TV sink, DSP off, AI off, identity face armed.";
  kernel = "lts"; dsp = false; aiEnable = false; aiPreset = "cpu-fallback";
  quantum = 1024; minQuantum = 256; gamemode = false; power = "balanced";
  apps = [ "1|mpv" ];
};
```

Rationale: the DSP coprocessor and the agentic AI stack are load and attack surface the living room does not need. LTS kernel for the long-lived HDMI session.

### 11.2 Monitor rule

Home-manager fragment, keyed on `custom.tvPrivacy.connector`:

```
monitor = <connector>, <mode>, 0x0, 1
```

- scale is 1. Television pixels are large.
- `bitdepth` follows `edid.keepColor`.
- `cm` stays `srgb` unless the scrubbed EDID still advertises a wide gamut *and* `edid.keepColor = true`.
- VRR off unless the operator sets `hypr.vrr = true`. VRR + many panels = handshake flakes.

Window rules (theater persona only):

- `opacity 1.0 1.0` for `mpv`, `vlc`, `jellyfinmediaplayer`, and title matches for theater-mode browsers.
- `fullscreen` optional on the player workspace.

### 11.3 Idle

Use Oligarchy's existing idle ladder. Do not send CEC `<Standby>` when the PC idles. DPMS the connector is enough.

### 11.4 Control plane

New `oligarchy-ctl` category `tv`:

| Action id | Effect |
|---|---|
| `tv-status` | print policy, session_n, connector, CEC OSD, last mux timestamp |
| `tv-arm` | switch persona to theater (prompts rebuild if build-time pieces changed), start CEC unit, apply LAN face |
| `tv-disarm` | restore previous persona, restore hostname, stop CEC unit |
| `tv-rekey` | increment session_n, rewrite stream-face defaults; link face still needs reboot |
| `tv-mux <in> <out>` | one-shot file remux |
| `tv-watch <dir>` | watch folder → remux into `<dir>/faced/` |

Read-only MCP tool `tv_status` may exist later. No write MCP. Same rule as the rest of Oligarchy's agent surface.

Panic bind is unchanged: mute, clipboard wipe, optional radio cut, lock. Theater does not add a new panic.

---

## 12. Nix module sketch

```nix
# modules/tv-privacy/default.nix
{ config, lib, pkgs, ... }:
let cfg = config.custom.tvPrivacy;
in {
  options.custom.tvPrivacy = {
    enable = lib.mkEnableOption "Theater face: EDID/CEC/stream/LAN identifier hygiene";
    connector = lib.mkOption { type = lib.types.str; example = "HDMI-A-1"; };
    policy = lib.mkOption {
      type = lib.types.enum [ "generic" "ephemeral" "rotating" ];
      default = "generic";
    };
    seedFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/oligarchy/tv-privacy/seed";
    };
    rotateHours = lib.mkOption { type = lib.types.int; default = 24; };
    edid = {
      vendor = lib.mkOption { type = lib.types.str; default = "OGA"; };
      keepMmSize = lib.mkOption { type = lib.types.bool; default = true; };
      keepColor = lib.mkOption { type = lib.types.bool; default = true; };
      allowCapabilityLift = lib.mkOption { type = lib.types.bool; default = false; };
    };
    cec = {
      osd = lib.mkOption { type = lib.types.str; default = "Player"; };
      ignoreStandby = lib.mkOption { type = lib.types.bool; default = true; };
      ignoreRouting = lib.mkOption { type = lib.types.bool; default = true; };
    };
    stream = {
      serviceName = lib.mkOption { type = lib.types.str; default = "TV"; };
      keepTitle = lib.mkOption { type = lib.types.bool; default = false; };
      keepLanguage = lib.mkOption { type = lib.types.bool; default = true; };
      dropTimingSei = lib.mkOption { type = lib.types.bool; default = true; };
    };
    lan = {
      hostname = lib.mkOption { type = lib.types.str; default = "player"; };
      randomMac = lib.mkOption { type = lib.types.bool; default = true; };
    };
  };

  config = lib.mkIf cfg.enable {
    # firmware blob, cmdline, units, packages: oligarchy-edid-scrub,
    # oligarchy-privacy-muxd, cec-ctl wrapper.
    # assertions: cfg.connector != "", seedFile parent exists after activation,
    # edid vendor is three A-Z letters.
  };
}
```

Enable site:

```nix
# configuration.nix
custom.tvPrivacy = {
  enable = true;
  connector = "HDMI-A-1";
  policy = "generic";
};
custom.persona.active = "theater";   # or switch live via oligarchy-ctl
```

ISO builder SHALL `custom.tvPrivacy.enable = lib.mkForce false`.

---

## 13. Files on disk

```
/var/lib/oligarchy/tv-privacy/
    seed              0600   host_secret
    session           0600   u64 newline
    captured.bin      0600   raw EDID from the panel
    theater.bin       0644   scrubbed EDID copied into firmware as well
    last-status.json  0644   what tv-status reads
/usr-via-nix/
    oligarchy-edid-scrub
    oligarchy-privacy-muxd
    oligarchy-cec-face
```

Nothing from this directory is an MCP-readable secret except `last-status.json`.

---

## 14. Tests

A change is not mergeable without these.

1. **edid-roundtrip** — scrub(captured) passes `edid-decode --check`; vendor/serial/name match policy; detailed timing 0 still describes the same mode.
2. **cec-unit-dry** — wrapper prints the intended `cec-ctl` argv; does not require hardware.
3. **ts-golden** — a committed 2-program fixture remaps to one program; PAT/PMT/SDT fields equal the vectors for `S = 0x11..1f`, policy `generic`; no `x264`, hostname, or source filename survive `ffprobe` + `strings`.
4. **mp4-knife** — creation_time is epoch; handler_name empty; codec extra-data identical.
5. **idempotence** — mux(mux(f)) public IDs equal mux(f).
6. **bind-surface** — live mode refuses to listen on a non-loopback address (unit test on the CLI parser).
7. **iso-off** — `nix eval` of the installer configuration shows `custom.tvPrivacy.enable == false`.

Golden vectors live in `modules/tv-privacy/testdata/`. Same spirit as HydraMesh's certified adapters: the mapping is byte-deterministic.

---

## 15. Security notes

- `host_secret` is generated at first activation with `getrandom`. It is not derived from `/etc/machine-id` (that value sometimes leaks).
- The muxer runs as a dedicated user `tv-mux`, no home, no new privileges, memory deny write-execute, `RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ]` and then only loopback for `--live`.
- It must not be in the `docker` group, the `render` group, or any Hyprland socket group.
- Strict egress, if enabled, should allow the media domains the operator actually uses. This module adds an ACR block set; it does not open ports.
- Logs go to the journal at `info`. Do not log source file paths at info; `debug` may.

---

## 16. Operator cookbook (normative UX, not implementation)

```
# 1. plug the sink into HDMI-A-1, leave the TV off the network
# 2. enable the module, rebuild, reboot (link face needs KMS)
# 3. arm
oligarchy-ctl run tv-arm

# 4. play locally
mpv ./film.mkv

# 5. if a file will leave the box (USB, DVR, library sync)
oligarchy-ctl run tv-mux -- ./film.mkv ./faced/film.mkv

# 6. leave
oligarchy-ctl run tv-disarm
```

If the picture is black after step 2, the scrub dropped a timing the panel needs. Restore `captured.bin` as the firmware blob, file a bug, do not set `allowCapabilityLift`.

---

## 17. Versioning

| Rev | Date | Notes |
|---|---|---|
| 0.1 | 2026-09-08 | Initial design. No code in ALH477/Oligarchy yet. |

A 1.0 tag requires the Nix module, both binaries, the `theater` persona, golden tests, and an architecture.md paragraph.

---

## 18. Fit against the existing tree

| Existing Oligarchy piece | Relationship |
|---|---|
| `modules/personas.nix` | gains `theater` |
| `modules/platform.nix` | connector name may come from a platform probe; do not move Hyprland off the iGPU |
| `modules/security/` | LAN face asserts Avahi off; ACR set is additive to `demod-ip-blocker` |
| `home/hyprland` | monitor + window rules gated on persona |
| `oligarchy-ctl` | new category `tv` |
| `custom.dcfIdentity` | unrelated; leave disabled on a theater box |
| DSP coprocessor | off in `theater` |
| MCP | read-only `tv_status` only, later |

---

## 19. Summary law

1. The sink sees a bland display and a bland CEC name.
2. Any container that leaves the box has remapped IDs and no encoder/host tags.
3. The seed never leaves the box.
4. DRM identity is not in play.
5. The television's own OS is not the privacy boundary — pulling its WAN cable is.
