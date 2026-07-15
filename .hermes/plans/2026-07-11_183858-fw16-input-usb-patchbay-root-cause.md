# Framework 16 Keyboard / Peripherals / USB Patchbay Root-Cause Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.
> **CRITICAL: local commits only.** Do not push this repo unless the user explicitly says to push.
> Repo: `/home/asher/Documents/oligarchy2/Oligarchy` — rebuild: `sudo nixos-rebuild switch --flake .#nixos`

**Goal:** Find and remove the real cause of keyboard/peripheral flakiness and of "opening the patchbay on USB devices kills them", with evidence-backed NixOS fixes on the Framework 16 AMD.

**Architecture:** Inspection-first (no rebuild until RC confirmed). Fix in layers: (1) PCI XHCI runtime PM still allowed at parent controllers, (2) broken udev power rules matching USB *interfaces* not *devices*, (3) sticky bluetooth soft-block, (4) invalid BlueZ `Enable=` key, (5) user in `input` group + WirePlumber/qpwgraph reconfiguration races. Optionally add a small diagnostic script that proves each layer before/after.

**Tech Stack:** NixOS 25.11, linux-zen 7.0.10, Hyprland Wayland, PipeWire + WirePlumber + qpwgraph/helvum, Framework 16 keyboard 32ac:0012, MediaTek BT 0e8d:e616.

---

## Current context / live evidence (2026-07-11 ~18:33 boot)

| Observation | Value | Why it matters |
|---|---|---|
| Session | Hyprland / Wayland | not KDE XwaylandEavesdrops |
| Sunshine | inactive | **not** today's culprit |
| User groups | `... input audio ...` | raw evdev ACL still present |
| Framework kbd | `1-4.2` 32ac:0012, power `on`, hyprctl sees it | currently up |
| PCI XHCI parents | **all four** `control=auto` runtime enabled | parent bus can still sleep |
| USB autosuspend kludge | `usbcore.autosuspend=-1` on cmdline | only device-level; parent still auto |
| udev rules | match interfaces without `ENV{DEVTYPE}=="usb_device"` | boot storm of "Could not chase sysfs attribute ... power/*" |
| BT | Soft blocked; `PowerState: off-blocked` | sticky rfkill after USB parent events |
| rfkill file | `/var/lib/systemd/rfkill/pci-0000:c5:00.3-usb-0:5:1.0:bluetooth` == **1** | persists across boots |
| bluez conf | `Enable=Source,Sink,Media,Socket` | journal: **Unknown key Enable** |
| Audio nodes | only onboard Ryzen HDMI/analog; no USB audio present now | patchbay trigger needs USB device plugged |
| WirePlumber | multiple `wp_event_dispatcher_unregister_hook` asserts | SPA/WP restart thrash around login |
| upower critical | `criticalPowerAction = "Hibernate"` + `nohibernate` on cmdline | mismatched power policy (side issue) |

### Root-cause ranking (from evidence)

**RC-1 (primary, confirmed code gap): PCI XHCI runtime PM still `auto`**

- Controllers: `0000:c5:00.3`, `0000:c5:00.4`, `0000:c7:00.3`, `0000:c7:00.4` all `power/control=auto`.
- Keyboard and MediaTek BT hang under parent bus `0000:c5:00.3`.
- Device-level `power/control=on` is **not enough** — already proven on this machine in `nixos-input-debugging` reference (`pci-xhci-bt-resume-fix.md`).
- When parent suspends/resumes → USB reset cascade → HID dropouts → BT re-enumerates into soft-block → pipewire/wireplumber device graph thrash.

**RC-2 (confirmed false application of intended rules): udev power rules hit interfaces**

Current `services.udev.extraRules` in `configuration.nix:646-656` and live `/etc/udev/rules.d/99-local.rules`:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"
...
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ...
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="32ac", ATTR{power/control}="on"
```

No `ENV{DEVTYPE}=="usb_device"`. Journal proves interface match failures paths like:

```
1-4.2:1.0: .../power/control ... No such file or directory
1-5:1.0: .../power/autosuspend ... No such file or directory
```

Rules look like they apply to the keyboard but are fighting udev for every interface; noisy and brittle under re-enumeration (exactly what patchbay/USB probing triggers).

**RC-3 (confirmed live symptom): BT soft-block sticky**

- `rfkill list` → hci0 Soft blocked: yes
- Saved state `...bluetooth: 1` on the real path + older address variants left around
- bluez cannot power on (`Failed to set mode: Failed (0x03)`)
- Feed-through: any USB/BT headset or peripheral that uses bluez will look "dead" until hard unblock + delete saved state

**RC-4 (confirmed config bug): invalid BlueZ `Enable=` key**

`hardware.bluetooth.settings.General.Enable = "Source,Sink,Media,Socket"` is rejected by modern bluez. Soft degradation + log spam; fix when touching bluetooth stanza.

**RC-5 (probable amplifier for "patchbay on USB devices fails"): PipeWire/WirePlumber reconfigure + exclusive-open / profile flip on USB class audio (and any composite firmware device)**

Config loadouts:

- `modules/audio.nix` packages **qpwgraph + helvum** (the patchbays; hyphen binds in `home/hyprland/default.nix`)
- `custom.dsp` / `dsp-rigs` / JACK auto-patch can also poke the graph
- User in **`input` group** — any userspace tool (incl. plugins, carla, input-overlay package at `configuration.nix:468`) can open `/dev/input/event*` alongside compositor
- Opening patchbay against a USB sound device forces profile/route changes; if parent XHCI is still on runtime PM, or WP is already thrashing, the device drops and "everything fails"

**Ruled out for this boot (do not waste time here first):**

- Sunshine/`capSysAdmin` — not active
- KWin `XwaylandEavesdrops` — running Hyprland
- `iommu.passthrough=0` / vault IOMMU — cmdline shows no IOMMU force; preset is **hardened** not vault
- Flat Hyprland input block — config looks normal; devices show in `hyprctl devices`

---

## User-facing symptom model

```
idle / USB reconnect / open qpwgraph-helvum on USB audio node
        │
        ▼
PCI XHCI parent (c5:00.3) runtime suspend or heavy re-enum
        │
        ├─► Framework kbd (1-4.2) reset / drop HID
        ├─► MediaTek BT (1-5) re-enum → systemd-rfkill writes SoftBlock=1
        └─► WirePlumber SPA events thrash → patchbay "USB device fails altogether"
```

---

## Proposed approach

1. Prove PCIs sleepability and udev failures with a diagnostics-only script (no rebuild).
2. Instantly clear BT soft-block so user can recover peripherals **now**.
3. Patch NixOS rules: PCI XHCI + USB **devices only** + Framework keyboard DEVTYPE filter.
4. Drop `input` from login user groups.
5. Fix bluetooth settings key; clear sticky rfkill state file on activation.
6. Add WirePlumber USB soft-block / "don't babysit Interrupts on suspend" if still needed second pass.
7. Validate with repro matrix: idle, resume, open qpwgraph with USB audio, hotplug kbd.

No feature expansion. No sunshine. No IOMMU games. No new audio graph redesign unless RC-5 still reproduces after RC-1..4.

---

## Files likely to change

| File | Change |
|---|---|
| `Documents/oligarchy2/Oligarchy/configuration.nix` | udev.extraRules rewrite; remove `input` from `users.users.asher.extraGroups`; fix bluetooth `Enable` key (or anti-key) |
| Optional: `modules/platform.nix` | if you want Framework USB/XHCI quirks centralized next to existing `usbcore.autosuspend` params |
| Optional: `scripts/check-input-usb.sh` (new, local only) | diagnostic harness for before/after |
| **Do not** change | sunshine, KWin, cpu-security preset, kernel variant, Hyprland input layout |

---

## Step-by-step plan

### Task 0: Freeze a repro baseline (no code changes)

**Objective:** Confirm current failures and capture numbers so post-fix isn't cargo-cult.

**Step 1: Capture baseline artifact**

Run (as root where noted):

```bash
mkdir -p /tmp/oligarchy-input-rc
{
  date
  cat /proc/cmdline
  groups
  rfkill list
  bluetoothctl show | sed -n '1,30p'
  echo '--- xhci ---'
  for dev in /sys/bus/pci/devices/*/; do
    class=$(cat "$dev/class" 2>/dev/null) || continue
    [[ "$class" == 0x0c0330* ]] || continue
    echo "$(basename "$dev") control=$(cat "$dev/power/control") status=$(cat "$dev/power/runtime_status")"
  done
  echo '--- usb power ---'
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor ]] || continue
    printf '%s %s:%s ctrl=%s auto=%s status=%s %s\n' \
      "$(basename "$d")" "$(cat $d/idVendor)" "$(cat $d/idProduct)" \
      "$(cat $d/power/control 2>/dev/null)" "$(cat $d/power/autosuspend 2>/dev/null)" \
      "$(cat $d/power/runtime_status 2>/dev/null)" "$(cat $d/product 2>/dev/null)"
  done
  echo '--- udev errors this boot ---'
  journalctl -b -p warning --no-pager | grep -c 'Could not chase sysfs attribute' || true
  ls -la /var/lib/systemd/rfkill/
  cat /var/lib/systemd/rfkill/*bluetooth*
  hyprctl devices | head -40
} | tee /tmp/oligarchy-input-rc/baseline.txt
```

**Step 2: Immediate recovery (still no rebuild)**

```bash
sudo rfkill unblock bluetooth
sudo sh -c 'for f in /var/lib/systemd/rfkill/*bluetooth*; do echo 0 > "$f"; done'
# keep XHCI awake for this session only (proves RC-1 without reboot)
for d in /sys/bus/pci/devices/*/; do
  class=$(cat "$d/class" 2>/dev/null) || continue
  [[ "$class" == 0x0c0330* ]] || continue
  echo on | sudo tee "$d/power/control" >/dev/null
done
bluetoothctl power on
rfkill list
```

Expected:
- BT soft blocked = no
- PCI XHCI `control=on`
- keyboard keeps working

**Step 3: Manual repro note (user does this)**

With a USB audio interface (or phone DAC) plugged:

1. Open `qpwgraph` (Hyprland Super?, or menu) / `helvum`
2. Drag a link involving the USB device, or toggle its profile in side panel
3. Observe whether USB device disappears, keyboard hiccups, BT dies

If session survives after Step 2 hot-fix of XHCI → RC-1 is the smoking gun for "patchbay kills USB".

---

### Task 1: Rewrite udev power rules correctly

**Objective:** Keep USB **devices** and PCI XHCI controllers awake; stop applying power attrs on interfaces.

**Files:**
- Modify: `Documents/oligarchy2/Oligarchy/configuration.nix:646-656`

**Step 1: Replace `services.udev.extraRules` block with:**

```nix
      udev.extraRules = ''
        # PCI XHCI host controllers — must stay awake or entire USB trees reset
        # (class 0x0c0330). Device-level USB autosuspend alone is NOT enough.
        ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x0c0330", ATTR{power/control}="on"

        # USB devices only (never interfaces — interfaces have no power/* attrs)
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/autosuspend}="-1"
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/autosuspend_delay_ms}="-1"

        # USB hubs (bDeviceClass 09) — device level only
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{bDeviceClass}=="09", ATTR{power/control}="on"

        # Framework keyboard module (32ac:0012) + any Framework USB device
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="32ac", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="32ac", ATTR{power/autosuspend}="-1"

        # Thunderbolt authorize (Framework expansion bay)
        ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
      '';
```

**Notes:**
- Delete the bare `SUBSYSTEM=="usb"` rules without DEVTYPE.
- Delete interface-class matches (`bInterfaceClass=="03"`) — they hit interfaces without power attrs.
- Delete `SUBSYSTEM=="hid", ATTR{power/control}="on"` unless you verify those nodes *have* `power/control` (usually they don't on this tree; causes spam).
- Do **not** touch the Framework WebHID hidraw rule coming from nixos-hardware (already in 99-local for 32ac WebHID programming).

**Step 2: Dry-eval only (do not switch yet if other tasks unfinished)**

```bash
cd /home/asher/Documents/oligarchy2/Oligarchy
nix build .#nixosConfigurations.nixos.config.system.build.toplevel --no-link
```

Expected: eval/build succeeds.

**Step 3: Commit (local only)**

```bash
git add configuration.nix
git commit -m "fix(input): keep PCI XHCI awake; udev power rules USB devices only"
```

---

### Task 2: Remove login user from `input` group

**Objective:** Stop giving every process of `asher` raw evdev access; eliminates exclusive-open races with patchbay tools / input-overlay / plugins.

**Files:**
- Modify: `configuration.nix:752`

**Step 1: Change**

```nix
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" "video" "input" "audio" ];
```

to

```nix
      # No "input" — compositor routes HID for normal desktop use.
      # Raw-evdev daemons (blipply service user) keep their own group membership.
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" "video" "audio" ];
```

**Step 2:** Leave `modules/blipply-integration.nix` blipply **service** user in `input` if that assistant still needs hotkeys. Do not re-add to login user.

**Step 3: Commit**

```bash
git add configuration.nix
git commit -m "security(input): drop login user from input group"
```

Note: group change applies on next full login after switch.

---

### Task 3: Fix BlueZ settings + purge sticky soft-block

**Objective:** Valid bluez conf + bluetooth actually powers on after USB events.

**Files:**
- Modify: `configuration.nix` bluetooth block (~535-549)

**Step 1: Replace General block**

From:

```nix
        settings = {
          General = {
            Enable = "Source,Sink,Media,Socket";
            Experimental = true;
            FastConnectable = true;
            JustWorksRepairing = "always";
            MultiProfile = "multiple";
          };
```

To:

```nix
        settings = {
          General = {
            # Do NOT set "Enable=" — modern bluez rejects it ("Unknown key Enable")
            Experimental = true;
            FastConnectable = true;
            JustWorksRepairing = "always";
            MultiProfile = "multiple";
            KernelExperimental = true;
          };
```

**Step 2: Add a oneshot activation to clear sticky BT soft-block once** (NixOS activationScripts or systemd service). Preferred tiny activation snippet in `configuration.nix`:

```nix
    system.activationScripts.unblockBluetoothRfkill.text = ''
      # Install-time/switch-time purge of sticky soft-blocks from prior XHCI resumes.
      # Runtime soft-blocks still reappear if XHCI is left on runtime PM=auto — Task 1 fixes that root.
      if [ -d /var/lib/systemd/rfkill ]; then
        for f in /var/lib/systemd/rfkill/*bluetooth*; do
          [ -f "$f" ] || continue
          echo 0 > "$f" || true
        done
      fi
    '';
```

**Step 3: Commit**

```bash
git add configuration.nix
git commit -m "fix(bluetooth): drop invalid Enable key; clear sticky rfkill on activation"
```

---

### Task 4: Rebuild + verify (single switch)

**Objective:** Apply Tasks 1–3 atomically so there is one generation with all RC fixes.

**Step 1: Build then switch**

```bash
cd /home/asher/Documents/oligarchy2/Oligarchy
nixos-rebuild build --flake .#nixos
# if clean:
sudo nixos-rebuild switch --flake .#nixos
```

**Step 2: Verify udev + PCI without reboot first**

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=pci --subsystem-match=usb
sleep 1
for dev in /sys/bus/pci/devices/*/; do
  class=$(cat "$dev/class" 2>/dev/null) || continue
  [[ "$class" == 0x0c0330* ]] || continue
  echo "$(basename "$dev") control=$(cat "$dev/power/control") status=$(cat "$dev/power/runtime_status")"
done
# Expected: control=on for all four

# No new chase errors on rediscover
journalctl -b --since '2 min ago' | grep -c 'Could not chase sysfs attribute' || true
# Expected: 0 new hits

cat /sys/bus/usb/devices/1-4.2/power/control   # on
rfkill list                                      # BT soft blocked: no
bluetoothctl show | grep -E 'Powered|PowerState' # Powered: yes
```

**Step 3: Full session verification checklist**

- [ ] Keyboard works in TTY (Ctrl+Alt+F3)
- [ ] Keyboard works in Hyprland
- [ ] Touchpad works
- [ ] `hyprctl devices` still lists `framework-laptop-16-keyboard-module---ansi-keyboard` as main
- [ ] `rfkill list` → BT not soft-blocked after 10+ minutes idle
- [ ] With USB audio interface: open `qpwgraph` / `helvum`, create/break links — device stays online; keyboard stays online
- [ ] Hot-unplug/replug USB audio — reappears; no full input death
- [ ] After lid ignore idle period (or `systemctl suspend` if used): input still lives (or recovers cleanly)

**Step 4: Capture after artifact**

```bash
# same script as Task 0 → /tmp/oligarchy-input-rc/after.txt
diff -u /tmp/oligarchy-input-rc/baseline.txt /tmp/oligarchy-input-rc/after.txt | head -100
```

Expected deltas: XHCI `auto` → `on`; rfkill Bluetooth soft-block gone; udev chase-count down.

**Step 5: Commit switch receipt only if docs/notes added — no push.**

---

### Task 5 (only if patchbay still kills USB audio after Tasks 1–4): WirePlumber USB device policy

**Objective:** Stop WP from suspending ALSA USB nodes aggressively under patchbay edits.

**Files:**
- Modify: `modules/audio.nix` (extra WirePlumber config)

**Step 1: Add WirePlumber snippet under existing `extraConfig` merge:**

```nix
          "30-usb-no-suspend" = {
            "monitor.alsa.rules" = [
              {
                matches = [
                  { "device.name" = "~alsa_card.usb-.*"; }
                ];
                actions = {
                  update-props = {
                    "session.suspend-timeout-seconds" = 0;
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

**Step 2: Restart user audio only**

```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
```

**Step 3: Retest patchbay with USB interface.** If still fails, pull `journalctl --user -u wireplumber -f` while reproducing and **stop** — re-open RCA rather than piling more rules.

**Step 4: Commit if this landed**

```bash
git add modules/audio.nix
git commit -m "fix(audio): disable WirePlumber suspend on USB ALSA devices"
```

---

### Task 6: Optional diagnostic script (keep in repo scripts/)

**Objective:** One command for future "my keyboard died" pivots.

**Create:** `Documents/oligarchy2/Oligarchy/scripts/check-input-usb.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "== groups =="; groups
echo "== rfkill =="; rfkill list || true
echo "== xhci =="
for dev in /sys/bus/pci/devices/*/; do
  class=$(cat "$dev/class" 2>/dev/null) || continue
  [[ "$class" == 0x0c0330* ]] || continue
  printf '%s control=%s status=%s\n' "$(basename "$dev")" \
    "$(cat "$dev/power/control")" "$(cat "$dev/power/runtime_status")"
done
echo "== framework kbd =="
lsusb | grep -i 32ac || true
echo "== udev chase errors this boot =="
journalctl -b -p warning --no-pager 2>/dev/null | grep -c 'Could not chase sysfs attribute' || true
echo "== hypr keyboards =="
hyprctl devices 2>/dev/null | sed -n '/Keyboards:/,/Tablets:/p' | head -40 || true
```

Run: `bash scripts/check-input-usb.sh`

Commit if useful:

```bash
git add scripts/check-input-usb.sh
git commit -m "chore: add input/USB health check script"
```

---

## Tests / validation commands (summary)

```bash
# After switch
for d in /sys/bus/pci/devices/*/; do
  c=$(cat "$d/class" 2>/dev/null) || continue
  [[ $c == 0x0c0330* ]] && echo "$(basename $d) $(cat $d/power/control)"
done
# all "on"

journalctl -b | grep -c 'Could not chase sysfs attribute'   # expect ~0 new after reload

rfkill list                                                  # BT soft-blocked: no
bluetoothctl show | grep -E 'Powered|PowerState'

groups | tr ' ' '\n' | grep -x input || echo 'OK: no input group'
hyprctl devices | grep -i framework
```

No unit tests for udev beyond boot journal silence + device power attributes — treat the Task 0/4 artifacts as the regression suite.

---

## Risks, tradeoffs, open questions

| Risk | Mitigation |
|---|---|
| Forced XHCI `on` costs a few mW idle | Acceptable on plugged FW16 gaming/DSP box; optional later revert if battery becomes priority |
| Removing `input` group breaks custom hotkey tools | Only raw-evdev tools break; blipply systemd user keeps own group; document |
| ActivationScript writing rfkill files races with systemd-rfkill | Task 1 removes *why* soft-block reappears; script is one-shot cleanup of sticky state |
| Patchbay still fails for exclusive JACK apps | Task 5 WP policy; if still broken, check whether carla/jack opens USB ALSA exclusively |
| Dual active generations/tool thrash while debugging | one switch for Tasks 1–3 only |

**Open questions for implementer / user if Task 1–4 insufficient:**

1. Exactly which USB product is under the patchbay when it fails? (DAC VID:PID / model)
2. Does failure require **drawing a connection**, or does mere **opening** of qpwgraph/helvum kill the device?
3. Is the keyboard failure correlated with lid/idle, or only patchbay?

Record answers in the after-artifact; do not invent more kernel params until answered.

---

## Out of scope (do not do unless user asks)

- Sunshine re-enable
- cpuSecurity preset change
- IOMMU / vault parity
- Full pro-audio exclusive JACK redesign
- Pushing to origin (repo is currently `behind 9`; leave that alone)
- Touching `Documents/dsp` ITAR tree

---

## Implementation order (bite-sized)

1. Task 0 baseline + session hot-fix (5 min)
2. Task 1 udev/PCI rules + local commit
3. Task 2 remove `input` group + local commit
4. Task 3 bluetooth + rfkill purge + local commit
5. Task 4 single rebuild/switch + verification matrix
6. Task 5 only if patchbay still fails
7. Task 6 optional diagnostic script

**Done criteria:** XHCI all `on`, no udev chase spam on interfaces, BT unblocked and stays unblocked after idle, keyboard survives idle + USB audio patchbay edits, `asher` not in `input`.

---

## Handoff

Plan complete. Implementer should execute Tasks 0→4 strictly; Task 5 only on residual failure. Prefer one rebuild covering Tasks 1–3 so the user is not thrashing generations with a half-fixed keyboard.
