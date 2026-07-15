# XHCI Host Death under Dual USB Audio / Patchbay Thrash — Fix Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.
> **CRITICAL: local commits only.** Do not push. Repo: `/home/asher/Documents/oligarchy2/Oligarchy`. Rebuild: `sudo nixos-rebuild switch --flake .#nixos`.
> **Do not thrash** both NI Komplete + Yamaha MG-XU wild on bus until A/B tests say so — last thrash killed the whole `c5:00.3` USB tree (kbd + SSD journal abort).

**Goal:** Stop AMD XHCI controller `0000:c5:00.3` from hard-dying (`HC died; cleaning up`) when PipeWire patchbay / multi-USB-audio graph stress runs, so Framework keyboard, BT, NIC, expansion SSD, and USB audio stay alive.

**Architecture:** The failure is **not** residual autosuspend now that PCI XHCI is forced `power/control=on`. It is a **controller-level fault** under concurrent isochronous USB-audio URB/link thrash on shared AMD XHCI (Framework 16, chip `1022:15b9`). Externalize mitigations in layers: (1) stop bad quirk/scheme params that increase recovery fragility, (2) reduce concurrent high-bandwidth ALSA open pressure via WirePlumber, (3) biparish recovery service for HC death, (4) optional kernel A/B (zen → mainline) only if 1–3 fail. Keep TDD via scripted repro + watcher, one variable per generation.

**Tech Stack:** NixOS 25.11, linux-zen 7.0.10, AMD FW16 7040 XHCI, PipeWire 1.4 + WirePlumber, qpwgraph/helvum, NI Komplete Audio 2 (`17cc:1840`), Yamaha MG-XU (`0499:1703`), Framework kbd (`32ac:0012`).

---

## Current context / assumptions

### Post-reboot live state (2026-07-11 ~18:52, gen `4jv1i7q4…`)

| Check | Value |
|---|---|
| Uptime | ~1 min after reboot |
| Bus | Devices back on `c5:00.3` bus1/bus2 |
| XHCI power | all 4 controllers `control=on` (fixer from gen 244–245 still applied) |
| Keyboard | present |
| USB audio | K2 + MG-XU both enumerated |
| BT | Soft blocked: **yes** (sticky file still `…bluetooth: 1`; unblock service raced/ran early) |
| Kernel | `7.0.10-zen1` |
| Params of interest | `threadirqs`, `usbcore.use_both_schemes=y`, `xhci_hcd.quirks=0x40` (= **XHCI_TRUST_TX_LENGTH**), `usbcore.autosuspend=-1`, `pcie_aspm=off` |

### Proven fault sequence (pre-reboot thrash log)

1. qpwgraph + helvum open
2. 12 rounds of `pw-link` create/destroy across **both** USB audio devices + default-sink flips
3. ~18:48:28: `pw-dump` **timeouts** (graph stuck)
4. ~18:48:34 kernel:
   ```
   xhci_hcd 0000:c5:00.3: xHCI host not responding to stop endpoint command
   xhci_hcd 0000:c5:00.3: xHCI host controller not responding, assume dead
   xhci_hcd 0000:c5:00.3: HC died; cleaning up
   ```
5. Full USB tree disconnect: kbd, K2, MG-XU, BT, hubs, expansion UAS SSD (`sda` journal abort), r8152 eth
6. Controller stayed PCI-bound as `on/active` but dead; only reboot recovered (unbind needed root password not available)

### Topology (same dead controller hosts everything critical)

```
0000:c5:00.3  AMD XHCI 1022:15b9 (Framework)
  bus1 (HS)
    1-1.1  Yamaha MG-XU          ← isochronous audio
    1-2.2  NI Komplete Audio 2   ← isochronous audio
    1-4.2  Framework keyboard    ← HID (collateral)
    1-5    MediaTek Bluetooth    ← collateral
  bus2 (SS)
    2-2.1  Framework 250GB SSD   ← UAS (collateral, journal kill)
    2-2.3  Realtek 2.5G eth      ← collateral
```

**Why "patchbay kills peripherals" felt true:** patchbay ops stress multi-device isoc endpoints on this single XHCI; when the host controller dies, keyboard dies with it because Framework kbd is on the same silicon.

### Already applied (keep)

- `services.udev.extraRules` PCI XHCI `power/control=on` + `ENV{DEVTYPE}=="usb_device"` filters
- login user **not** in `input` group (re-login to take effect)
- BlueZ invalid `Enable=` removed
- `unblock-bluetooth.service` present but **insufficient** against sticky softblock file content `1` at boot

### Out of scope this plan

- Sunshine
- cpuSecurity preset changes
- full DSP rig redesign
- ITAR trees
- push to origin

---

## Root cause statement

**Primary:** Concurrent heavy PipeWire graph mutation with **two class-compliant USB audio interfaces** on AMD XHCI `0000:c5:00.3` (zen 7.0.10) drives the host into "stop endpoint" hang → controller marked dead. Not userspace alone (kernel claims HC death). Keyboard death is **shared-bus collateral**.

**Contributing config factors (ordered hypotheses to A/B):**

| Rank | Factor | Why suspect |
|---|---|---|
| H1 high | Global `xhci_hcd.quirks=0x40` (XHCI_TRUST_TX_LENGTH) forced in both cmdline (`modules/platform.nix`) and `extraModprobeConfig` | Relaxes TX-length checks; can change recovery path when URB storms hit AMD hosts |
| H2 high | `usbcore.use_both_schemes=y` | Dual bandwidth schemes increase scheduling complexity under multi-device isoc |
| H3 med | Simultaneous open of K2 **and** MG-XU as active sink/source + rapid `pw-link` storms | Trigger that reproduced HC death hard |
| H4 med | linux-zen 7.0.10 (`PREEMPT_DYNAMIC` + zen scheduling) vs mainline for USB isoc | Zen aggressiveness may worse-case xhci completion |
| H5 low | `threadirqs` | Threading IRQ handlers under rtkit—possible interaction, less likely sole cause |
| H6 residual | BT sticky rfkill file remains 1 after reboot | Separate; service exists but softblock reappears (user-visible peripheral death even without HC death) |

**Ruled out as primary HC death cause:** PCI runtime auto (now `on`); udev interface power spam (fixed, no chase spam after trigger pre-thrash).

---

## Proposed approach

1. **Scripted safe repro** that fails closed: stop at first missing kbd / single audio dropout; never force dual-device 12-round thrash again without user OK.
2. **One-variable A/B generations** against H1 then H2 (remove conflicting double-setting of quirks).
3. **WirePlumber policy**: do not keep both pro interfaces fully active-routed by default; disable session suspend thrash; optional exclusive profile.
4. **HC-death recovery unit** so HCI death does not require full reboot.
5. **Fix BT softblock for real** (delete sticky files + re-unblock after `bluez` + short delay; optionally `After=` graphical).
6. If H1+H2+H3 still die → try stock `boot.kernelPackages = pkgs.linuxPackages_latest` (or non-zen currently selected by persona) as H4 last.

Success criteria (must all hold after switch + cyclic mkdir-log test):

- [ ] `lsusb` retains Framework kbd after gentle multi-device routing
- [ ] HC death string **absent** from `journalctl -b -k | grep 'HC died'` after 5-minute controlled stress
- [ ] `pw-link` K2↔onboard loop 30 cycles without bus wipe
- [ ] BT Soft blocked: no within 30s of login
- [ ] Expansion SSD stays mounted under mild audio edit (no planned stress of UAS + dual isoc)

---

## Files likely to change

| Path | Purpose |
|---|---|
| `modules/platform.nix` | Framework USB kernel params: drop/adjust `xhci_hcd.quirks=0x40`, `use_both_schemes` |
| `configuration.nix` | Dedup `extraModprobeConfig` conficting quirk; BT service timing; optional recovery unit |
| `modules/audio.nix` | WirePlumber rules for USB audio suspend / multi-device policy |
| `scripts/usb-xhci-watch.sh` | Non-destructive watcher (new) |
| `scripts/usb-audio-stress.sh` | Bounded, kill-safe stress (new) |
| `scripts/xhci-recover.sh` | bind/unbind recovery helper (new, needs root) |

---

## Step-by-step plan

### Task 0: Post-reboot baseline artifact (read-only)

**Objective:** Capture healthy topology before any cod change.

```bash
mkdir -p /tmp/oligarchy-xhci-rc
{
  date; cat /proc/cmdline
  lsusb; lsusb -t
  cat /proc/asound/cards
  for d in /sys/bus/pci/devices/*/; do
    c=$(cat "$d/class" 2>/dev/null) || continue
    [[ $c == 0x0c0330* ]] || continue
    echo "$(basename $d) $(cat $d/power/control) $(cat $d/power/runtime_status)"
  done
  cat /sys/module/xhci_hcd/parameters/quirks
  rfkill list
  journalctl -b -k --no-pager | grep -c 'HC died' || true
} | tee /tmp/oligarchy-xhci-rc/baseline-post-reboot.txt
```

Expected from live probe: 0× `HC died` this boot, devices present, quirks=`64`.

---

### Task 1: Add non-destructive watcher + kill-safe stress scripts

**Objective:** Repro tooling that **aborts** if kbd disappears (no infinite thrash).

**Files:**
- Create: `Documents/oligarchy2/Oligarchy/scripts/usb-xhci-watch.sh`
- Create: `Documents/oligarchy2/Oligarchy/scripts/usb-audio-stress.sh`

**Step 1: watch script**

```bash
#!/usr/bin/env bash
# scripts/usb-xhci-watch.sh — poll xhci + collateral devices
set -euo pipefail
LOG=${1:-/tmp/oligarchy-xhci-rc/watch.log}
mkdir -p "$(dirname "$LOG")"
KBD_GLOB='/dev/input/by-id/usb-Framework_Laptop_16_Keyboard_Module*'
end=$((SECONDS + ${WATCH_SECS:-120}))
prev=""
while (( SECONDS < end )); do
  s=""
  for d in /sys/bus/pci/devices/*/; do
    c=$(cat "$d/class" 2>/dev/null) || continue
    [[ $c == 0x0c0330* ]] || continue
    s+="$(basename "$d")=$(cat "$d/power/control")/$(cat "$d/power/runtime_status"); "
  done
  kbd=0; compgen -G "$KBD_GLOB" >/dev/null && kbd=1
  cards=$(grep -E 'K2|MGXU|usb' /proc/asound/cards 2>/dev/null | tr '\n' ' ' || true)
  bt=$(rfkill list 2>/dev/null | awk '/Bluetooth/{f=1} f&&/Soft blocked/{print $3; exit}')
  line="$(date +%H:%M:%S) kbd=$kbd bt_soft=${bt:-?} cards=[$cards] $s"
  if [[ $line != "$prev" ]]; then
    echo "$line" | tee -a "$LOG"
    prev=$line
  fi
  if [[ $kbd -eq 0 ]]; then
    echo "FATAL: keyboard gone — abort watch" | tee -a "$LOG"
    journalctl -b -k --since '30 sec ago' --no-pager | tee -a "$LOG" || true
    exit 2
  fi
  sleep 1
done
```

**Step 2: mild stress (single device first)**

```bash
#!/usr/bin/env bash
# scripts/usb-audio-stress.sh — bounded pw-link thrash; aborts if kbd dies
set -euo pipefail
MODE=${1:-single}   # single | dual | defaults
ROUNDS=${ROUNDS:-20}
LOG=/tmp/oligarchy-xhci-rc/stress-${MODE}.log
mkdir -p /tmp/oligarchy-xhci-rc
: >"$LOG"

KBD() { compgen -G '/dev/input/by-id/usb-Framework*' >/dev/null; }
die_if_dead() {
  if ! KBD; then
    echo "ABORT: keyboard lost" | tee -a "$LOG"
    journalctl -b -k --since '20 sec ago' --no-pager | tee -a "$LOG" || true
    exit 3
  fi
  if journalctl -b -k --since '20 sec ago' --no-pager 2>/dev/null | grep -q 'HC died'; then
    echo "ABORT: HC died in kernel log" | tee -a "$LOG"
    exit 4
  fi
}

K2_IN=alsa_input.usb-Native_Instruments_Komplete_Audio_2_0000A748-00.analog-stereo:capture_FL
K2_OUT=alsa_output.usb-Native_Instruments_Komplete_Audio_2_0000A748-00.analog-stereo:playback_FL
MG_IN=alsa_input.usb-Yamaha_Corporation_MG-XU-00.analog-stereo:capture_FL
MG_OUT=alsa_output.usb-Yamaha_Corporation_MG-XU-00.analog-stereo:playback_FL
ON_OUT=alsa_output.pci-0000_c5_00.6.analog-stereo:playback_FL

for i in $(seq 1 "$ROUNDS"); do
  echo "round $i $(date +%T) mode=$MODE" | tee -a "$LOG"
  case "$MODE" in
    single)
      pw-link "$K2_IN" "$ON_OUT" || true
      sleep 0.3
      pw-link -d "$K2_IN" "$ON_OUT" || true
      ;;
    dual)
      pw-link "$K2_IN" "$K2_OUT" || true
      pw-link "$MG_IN" "$MG_OUT" || true
      sleep 0.3
      pw-link -d "$K2_IN" "$K2_OUT" || true
      pw-link -d "$MG_IN" "$MG_OUT" || true
      ;;
    defaults)
      # flip default sinks by name if ids unstable: use wpctl status parsing carefully
      wpctl status | tee -a "$LOG" | head -5
      ;;
  esac
  die_if_dead
  sleep 0.5
done
echo "PASS mode=$MODE rounds=$ROUNDS" | tee -a "$LOG"
```

**Step 3: chmod + chronic git**

```bash
chmod +x scripts/usb-xhci-watch.sh scripts/usb-audio-stress.sh
git add scripts/usb-xhci-watch.sh scripts/usb-audio-stress.sh
git commit -m "chore: add kill-safe XHCI/USB audio watch and stress scripts"
```

**Step 4: sanity run after login (watch only)**

```bash
./scripts/usb-xhci-watch.sh &
# leave 30s idle — expect no FATAL
```

---

### Task 2: Remove forced `XHCI_TRUST_TX_LENGTH` (H1)

**Objective:** Drop global `xhci_hcd.quirks=0x40` experiment introduced for Framework; let AMD host use stock quirk discovery only.

**Files:**
- Modify: `modules/platform.nix:134-141`
- Modify: `configuration.nix:268-272` (remove mirrored `options xhci_hcd quirks=0x40`)

**Step 1: platform.nix change**

From:

```nix
    (mkIf cfg.framework {
      boot.kernelParams = [
        "usbcore.autosuspend=-1"
        "usbcore.use_both_schemes=y"
        "xhci_hcd.quirks=0x40"
        "usb-storage.quirks=:u"
      ];
    })
```

To:

```nix
    (mkIf cfg.framework {
      boot.kernelParams = [
        "usbcore.autosuspend=-1"
        # use_both_schemes left intentional in Task 3 A/B
        "usbcore.use_both_schemes=y"
        # DO NOT force xhci_hcd.quirks=0x40 (XHCI_TRUST_TX_LENGTH).
        # Global TRUST_TX_LENGTH was a Framework hearsay fix; it can change
        # stop-endpoint recovery under multi-isoc USB audio and co-occurred
        # with HC death on 1022:15b9 (c5:00.3) in 2026-07-11 thrash.
        "usb-storage.quirks=:u"
      ];
    })
```

**Step 2: configuration.nix extraModprobeConfig**

From:

```nix
      extraModprobeConfig = ''
        options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
        options usbcore autosuspend=-1
        options xhci_hcd quirks=0x40
      '';
```

To:

```nix
      extraModprobeConfig = ''
        options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
        options usbcore autosuspend=-1
        # xhci_hcd.quirks intentionally unset — see modules/platform.nix note
      '';
```

**Step 3: build/switch (requires reboot for module param)**

```bash
cd /home/asher/Documents/oligarchy2/Oligarchy
git add modules/platform.nix configuration.nix
git commit -m "fix(usb): stop forcing xhci TRUST_TX_LENGTH quirk (0x40)

Correlated with AMD XHCI HC death under dual USB-audio patchbay thrash
on Framework 16 controller 0000:c5:00.3 (1022:15b9)."
sudo nixos-rebuild switch --flake .#nixos
sudo systemctl reboot
```

**Step 4: verify quirk gone & mild stress**

```bash
cat /sys/module/xhci_hcd/parameters/quirks   # expect 0 or hardware-default WITHOUT forced 0x40
./scripts/usb-audio-stress.sh single
# if PASS only, lightly try:
ROUNDS=10 ./scripts/usb-audio-stress.sh dual
```

**Pass criterion:** single mode 20/20; dual 10/10 if user allows. **No** `HC died`.

If single fails already → stop and reopen H4 (kernel) earlier; do not stack further.

---

### Task 3: Flip `usbcore.use_both_schemes` to `n` (H2) — only if Task 2 dual still dies

**Objective:** One-parameter A/B for bandwidth scheduling complexity.

**Files:**
- Modify: `modules/platform.nix` Framework kernelParams

Change:

```nix
        "usbcore.use_both_schemes=n"
```

Commit, switch, **reboot**, re-run `./scripts/usb-audio-stress.sh dual` ROUNDS=10.

If dual passes after H1+H2 both applied, leave both mitigations. If dual still dies, revert H2 only when H1 clearly carried the bug (bisect mentally by logs).

---

### Task 4: WirePlumber USB audio policy (H3 reduction)

**Objective:** Reduce default simultaneous open / suspend thrash on USB ALSA devices without forbidding both cards in lsusb.

**Files:**
- Modify: `modules/audio.nix` wireplumber `extraConfig` merge

Add:

```nix
          "30-usb-audio-stability" = {
            "monitor.alsa.rules" = [
              {
                matches = [
                  { "device.name" = "~alsa_card.usb-.*"; }
                ];
                actions = {
                  update-props = {
                    # Don't power-manage USB isoc nodes into stop-ep storms
                    "session.suspend-timeout-seconds" = 0;
                    # Avoid random auto profile flips while patchbay open
                    "api.alsa.auto-profile" = false;
                    "api.alsa.auto-port" = false;
                  };
                };
              }
              {
                matches = [
                  { "node.name" = "~alsa_input.usb-.*"; }
                  { "node.name" = "~alsa_output.usb-.*"; }
                ];
                actions = {
                  update-props = {
                    "session.suspend-timeout-seconds" = 0;
                    "node.pause-on-idle" = false;
                  };
                };
              }
            ];
          };
```

Also document for user in comment: **route one interface at a time** for today’s hero rig; second card can stay enumerated but unused until confirmed stable.

**Step: user service bounce (no full reboot)**

```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
ROUNDS=15 ./scripts/usb-audio-stress.sh dual
```

Commit:

```bash
git add modules/audio.nix
git commit -m "fix(audio): disable WirePlumber suspend/auto-profile on USB ALSA"
```

---

### Task 5: Fix Bluetooth softblock for real + HC recover helper

**Objective:** BT actually on after boot; optional XHCI recover path without reboot.

**Files:**
- Modify: `configuration.nix` `systemd.services.unblock-bluetooth` (and activation)

**Step 1: harden unblock service**

```nix
    systemd.services.unblock-bluetooth = {
      description = "Unblock Bluetooth rfkill after sticky soft-blocks";
      after = [ "bluetooth.service" "systemd-rfkill.service" "multi-user.target" ];
      wants = [ "bluetooth.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Delay so systemd-rfkill finishes restoring /var/lib state first.
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
        ExecStart = pkgs.writeShellScript "unblock-bt" ''
          set -e
          for f in /var/lib/systemd/rfkill/*bluetooth*; do
            [ -f "$f" ] || continue
            echo 0 > "$f" || true
          done
          ${pkgs.util-linux}/bin/rfkill unblock bluetooth || true
        '';
      };
    };
```

**Step 2: recovery script (root)**

Create `scripts/xhci-recover.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DEV=${1:-0000:c5:00.3}
echo "Unbinding $DEV"
echo "$DEV" > /sys/bus/pci/drivers/xhci_hcd/unbind
sleep 2
echo "Binding $DEV"
echo "$DEV" > /sys/bus/pci/drivers/xhci_hcd/bind
sleep 2
lsusb
rfkill unblock bluetooth || true
```

Optional companion oneshot triggered by udev on controller remove is YAGNI; keep manual first.

**Verify BT after switch (no reboot needed):**

```bash
sudo systemctl restart unblock-bluetooth
rfkill list   # Soft blocked: no
bluetoothctl power on
```

---

### Task 6: Controlled dual-device validation matrix (human + scripts)

**Objective:** Prove fix without nuclear thrash of previous session.

| # | Action | Expected |
|---|---|---|
| 1 | Idle 5 min after login | kbd sticky alive; no HC died |
| 2 | `./scripts/usb-audio-stress.sh single` | PASS |
| 3 | Open **qpwgraph only** (one GUI); link K2→onboard 10 times by hand or pw-link | LIVE |
| 4 | Enable MG-XU in patchbay **without** link storms; one connection | LIVE |
| 5 | ROUNDS=10 `dual` script | PASS or ABORT with clean logs (not infinite thrash) |
| 6 | If dual fails after H1–H4 | see Task 7 |

Gather logs to `/tmp/oligarchy-xhci-rc/`.

---

### Task 7 (last resort): Kernel package A/B (H4)

**Objective:** Only if dual stress still produces `HC died` after H1–H3.

Identify current kernel selector (`modules/kernel.nix` / persona). Prefer temporary:

```nix
# in configuration.nix or active persona — one generation only
boot.kernelPackages = pkgs.linuxPackages_latest; # or linuxPackages (nixos default non-zen)
```

Do **not** flip defaults forever on first try. Rebuild, reboot, re-run Task 6 matrix. Compare:

```bash
uname -r
journalctl -b -k | grep -E 'HC died|stop endpoint'
```

If mainline is clean and zen is dirty → file result in plan notes; decide whether Oligarchy stays on zen with audio caveats or switches.

---

## Tests / validation commands (summary)

```bash
# always before claiming win
cat /sys/module/xhci_hcd/parameters/quirks
journalctl -b -k | grep -c 'HC died'     # must be 0 after new stress
lsusb | grep -E '32ac:0012|17cc:1840|0499:1703'
# kill-safe stress
./scripts/usb-audio-stress.sh single
ROUNDS=10 ./scripts/usb-audio-stress.sh dual
# BT
rfkill list | sed -n '/Bluetooth/,/Wireless/p'
```

---

## Risks, tradeoffs, open questions

| Risk | Notes |
|---|---|
| Removing TRUST_TX_LENGTH regresses some Framework USB case | Keep autosuspend=-1 + PCI power on; re-add quirk **only** if specific device class regresses |
| Dual NI+Yamaha on one XHCI may always be fragile on AMD | Operational policy: one primary interface; second on separate dock/controller if possible |
| Expansion SSD on same dead controller → journal corruption risk | Prefer not mounting critical workspaces on FW expansion when dual isoc thrash hitting |
| zen vs mainline DSP/latency | H4 last; measure xruns separately |
| Aggressive thrash watched by Hermes earlier **did** kill bus deliberately — user must re-login/reboot if any future test ABORTs |

**Open questions:**

1. Do you need **simultaneous** K2 + MG-XU streaming, or is one active UV enough?
2. Prefer staying on linux-zen at all costs?

---

## Implementation order

0. Baseline  
1. Scripts  
2. Drop `xhci_hcd.quirks=0x40` (+ reboot) + single/dual light stress  
3. `use_both_schemes=n` only if needed (+ reboot)  
4. WirePlumber USB stability  
5. BT softblock + recover helper  
6. Human + script validation matrix  
7. Kernel A/B only if still dead  

**Done when:** no `HC died` after Task 6 matrix; kbd and USB audio survive dual light stress; BT unblocked after boot.

---

## Handoff

This plan supersedes residual notions that "just" more power udev rules fix patchbay kills. Power path is already fixed; remaining is **XHCI controller death under isoc concurrent load**.

Offer: execute Tasks 0–2 immediately after user confirms; never re-run the uncontrolled 12× dual thrash.
