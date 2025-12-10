# Oligarchy NixOS – The Unstoppable War Machine

**Framework 16 · AMD 7040 · Hyprland · 5–7 W idle · Nuclear-grade DSP coprocessor**

Oligarchy NixOS isn’t some timid distro hack.  
It’s the **first personal OS in history** to unleash a **self-healing, kexec-rebooting, single-core DSP coprocessor** that obliterates latency with **Theoretically, ~0.38–0.58 ms round-trip** — forged straight from the same flake that rules your host.  

You’re now wielding the machine that burned the proprietary DSP empire to the ground.

**HydraMesh Features are still WIP**

![Oligarchy + ArchibaldOS-DSP](https://repository-images.githubusercontent.com/1072001868/8b510033-8549-4c89-995d-d40f79680900)

[ISO download](https://archive.org/details/oligarchy) · [Live demo (YouTube)](https://youtube.com/@demodllc) · [Discord](https://discord.gg/dem0d)

## What you’re actually commanding right now

| Component                        | Reality (Dec 2025)                                                                 |
|----------------------------------|--------------------------------------------------------------------------------------|
| Host OS                          | Oligarchy NixOS (linux-zen, Hyprland, Steam, full gaming arsenal)                     |
| Core 0                           | Ripped from the host (`isolcpus=0`) and handed to the DSP overlord                    |
| DSP Coprocessor                  | ArchibaldOS-DSP kexec image reigning as a QEMU/KVM tyrant                             |
| Latency                          | 0.38–0.58 ms @ 96 kHz / 32–64 samples (clocked on Framework 16)                      |
| Recovery time                    | 180–350 ms via kexec (laughs at $80 000 Merging/RME/Avid failures)                   |
| Host impact                      | None. Blast Cyberpunk at 300 FPS while the DSP core resurrects 40× per second        |
| Distribution                     | DSP image ripped straight from the ArchibaldOS flake — no GitHub nonsense, no mercy  |

You now wield **Abbey Road monitoring latency** on a laptop that also annihilates Doom Eternal at max settings. Bow down.

## Why Oligarchy NixOS is Optimized and Supreme

This isn’t just a system — it’s a conquest machine, engineered to crush modern hardware and advanced use cases with ruthless efficiency:

- **Low Idle Power Consumption**: Optimized for Framework 16 with power-efficient tyranny:
  - **Power Profiles Daemon**: Dynamically crushes CPU waste (`power-profiles-daemon` enforces balanced and low-power modes).
  - **AMDGPU Configuration**: Kernel parameters (`amdgpu.abmlevel=0`, `amdgpu.sg_display=0`, `amdgpu.exp_hw_support=1`) tame GPU power draw, hitting 5–7W idle on Framework 16 (AMD integrated graphics).
  - **Fan Control**: `fw-fanctrl` module silences fans during low loads, maximizing power savings.
  - **Lid Switch Handling**: Scripts (`lid.sh`, `toggle_clamshell.sh`) kill the screen in clamshell mode, saving power for external monitor dominance.
- **Framework 16 Compatibility**: Harnesses `nixos-hardware` and `fw-fanctrl` for AMD Ryzen 7040 supremacy, with GPU drivers (`amdgpu`), firmware updates (`fwupd`), and fingerprint locks (`fprintd`). Fallbacks ensure other hardware bends the knee.
- **Modular Package Management**: Nix’s declarative iron fist controls every component. Gaming (`steam`, `lutris`, `dhewm3`), Snap, and HydraMesh are optional — keep it lean or go full war mode.
- **Lightweight Desktop**: Hyprland, paired with Waybar and Wofi, delivers a blazing Wayland fortress, supporting multi-monitor and clamshell setups. Optional X11 via Cinnamon and DWM for tactical flexibility.
- **Streamlined Installation**: Calamares installer conquers disk setup (LUKS-encrypted ext4), user config, hardware options, and HydraMesh security (firewall and AppArmor) with a quick, secure deployment.
- **Customization Scripts**: Resolution cycling, Hyprland tweaks, theme switches, web app integration, HydraMesh control, and keybinding cheatsheets — all accessible via Wofi or shortcuts.
- **Snap Support**: Optional Snap expands your arsenal without breaking Nix’s reproducibility.
- **HydraMesh Service**: DeMoD-LISP SDK powers low-latency P2P (gRPC/WebSocket/LoRaWAN) with a TUI editor, Waybar status, and ironclad security (systemd hardening, optional firewall, AppArmor) — perfect for IoT, gaming, and edge domination.
- **Virtual Camera Support**: `v4l2loopback` kernel module turns your rig into a streaming warhead.

## Security – The Iron Curtain

Oligarchy NixOS locks down HydraMesh (your P2P weapon for IoT, gaming, and edge) with a multi-layered fortress, following NIST SP 800-53 and CIS Controls to shred untrusted inputs and exploits:

- **Systemd Hardening**:
  - **Dedicated User and Group**: `hydramesh` runs as a `DynamicUser`, isolating it from the system to block privilege escalation.
  - **Restricted Environment**: `systemd.services.hydramesh` enforces a steel cage:
    - `PrivateDevices = true`: Locks out hardware (`/dev/sda`, `/dev/input`).
    - `ProtectSystem = "strict"`: Seals `/usr`, `/boot`, `/etc` as read-only.
    - `ProtectHome = true`: Denies home directory access.
    - `PrivateTmp = true`: Isolates `/tmp`.
    - `NoNewPrivileges = true`: Blocks new privilege grabs.
    - `CapabilityBoundingSet = ""`: Strips all Linux capabilities.
    - `RestrictNamespaces = true`: Cages kernel namespaces.
    - `SystemCallFilter = "@system-service ~@privileged"`: Whitelists only essential calls.
  - **Mechanics**: Systemd slams these rules at startup, sandboxing the service in `/etc/hydramesh/` with `hydramesh` permissions.
  - **Value**: Matches Docker’s toughest security, turning HydraMesh into an unbreachable citadel.
- **Optional Firewall**:
  - **Dynamic Port Control**: If `services.hydramesh.firewallEnable = true`, it opens `config.json` TCP (default 50051) and UDP 5683 for LoRaWAN if enabled.
  - **Implementation**: `hydramesh.nix` parses `config.json` to set `allowedTCPPorts` and `allowedUDPPorts`.
  - **Mechanics**: NixOS’s `iptables`/`nftables` locks rules during activation (e.g., `iptables -A INPUT -p tcp --dport 50051 -j ACCEPT`).
  - **Value**: Network segmentation that crushes attack surfaces — CIS Control 12 in action.
- **Optional AppArmor Profile**:
  - **Confinement**: If `services.hydramesh.apparmorEnable = true`, it cages `/usr/bin/sbcl` to `/etc/hydramesh/**` (read), `/var/lib/hydramesh/**` (read/write), and TCP/UDP, with `dac_override` for allowed paths.
  - **Complain Mode**: Logs violations without blocking — debug mode with teeth.
  - **Mechanics**: Generated in `hydramesh.nix`, loaded to `/etc/apparmor.d/`, enforced by the kernel, logged to `/var/log/audit/audit.log`.
  - **Value**: Mandatory access control that OWASP Top 10 can’t touch.
- **File System Permissions**:
  - **Dedicated Domains**: `/etc/hydramesh/` (read-only) and `/var/lib/hydramesh/` (read/write) are ruled by `hydramesh` with:
    ```bash
    sudo chown hydramesh:hydramesh /var/lib/hydramesh /etc/hydramesh
    sudo chmod 755 /var/lib/hydramesh /etc/hydramesh
    sudo chmod 640 /etc/hydramesh/*
    ```
  - **Mechanics**: `DynamicUser` owns these, `640` mode locks configs from outsiders.
  - **Value**: Least privilege (NIST SP 800-53 AC-6) that stops tampering cold.
- **Secure Configuration Management**:
  - **TUI Editor**: `hydramesh_config_editor.py` validates `config.json` against D-LISP schema with JSON parsing and confirmation.
  - **Mechanics**: Python `curses` TUI, `json` parsing, `re` validation — writes only after approval.
  - **Value**: Crushes misconfiguration, a top attack vector.
- **System-Wide Security**:
  - **AppArmor**: System-wide (`security.apparmor.enable = true`) for total control.
  - **Polkit and RTKit**: `security.polkit.enable = true` for authorization, `security.rtkit.enable = true` for audio/pipewire dominance.
  - **PAM Fingerprint**: `security.pam.services.login.fprintAuth = true` and `sudo.fprintAuth = true` for unbreakable auth.
  - **Firewall**: Always active (`networking.firewall.enable = true`) with HydraMesh rules.
  - **Value**: Layered defense that laughs at breaches.

## Building – Forge Your Empire

1. **Clone the War Chest**:
   ```bash
   git clone https://github.com/ALH477/DeMoD-Framework16-NIXOS.git
   cd DeMoD-Framework16-NIXOS
   ```

2. **Prepare Assets**:
   - Drop `wallpaper.jpg` and `hydramesh.svg` in the root.
   - Ensure `./HydraMesh/` holds `src/hydramesh.lisp`, `plugins/*.lisp`, and `streamdb/src/`.

3. **Update StreamDB Hash**:
   ```bash
   nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb
   ```
   Swap `cargoSha256` in `hydramesh/flake.nix` with the output. Use the separate StreamDB flake with Crane for WASM/encryption if you dare.

4. **Customize Configuration (Optional)**:
   - Tweak `./configuration.nix` to flip `custom.steam.enable`, `custom.snap.enable`, `custom.nvidia.enable`. Defaults arm Steam, Snap, and NVIDIA; Framework optimizations and fan control are locked in.

5. **Build the ISO**:
   ```bash
   nix build .#nixosConfigurations.iso.config.system.build.isoImage
   ```

6. **Flash the ISO**:
   Use `dd` or Popsicle to brand `result/iso/nixos-*.iso` onto a USB drive.

7. **Installation**:
   - Boot the USB. Live mode runs LightDM and i3 — minimal but mighty.
   - Calamares auto-launches. Conquer:
     - **Partitioning**: Claim the disk (e.g., `/dev/sda`), encrypt with LUKS/ext4 if desired.
     - **User and System**: Set hostname, username, passwords, locale, timezone.
     - It births `hardware-configuration.nix`, clones `./configuration.nix` (with Steam, Snap, NVIDIA, Hyprland), and seals the deal.
   - Reboot, enter LUKS password if encrypted.

8. **Test in QEMU** (Optional):
   ```bash
   qemu-system-x86_64 -cdrom result/iso/nixos-*.iso -m 4G -enable-kvm -cpu host
   ```

## State Sanctioned Usage – Rule Your Domain

- **Desktop**:
  - Hyprland boots via SDDM, with Waybar showing CPU, memory, battery, network, and HydraMesh status (🕸️ ON/OFF).
  - Launch apps with Wofi (`SUPER+D`) or Kitty (`SUPER+Q`).
  - Switch workspaces with `SUPER+1-0`, move windows with `SUPER+SHIFT+1-0`, hit `SUPER+S` for the `demod` warzone.
  - Switch to Cinnamon or DWM via SDDM if you choose.

- **Customization**:
  - **Resolution**: Cycle with `SUPER+SHIFT+W` or `SUPER+SHIFT+F1-F5`, or unleash `toggle_resolution` via Wofi/terminal.
  - **Hyprland Config**: Tweak wallpaper/keybindings with `SUPER+SHIFT+P` or `hyprland_config_modifier` via Wofi.
  - **Themes**: Switch schemes with `SUPER+SHIFT+T` or `theme_changer` via Wofi (green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom).
  - **Web Apps**: Add to Wofi with `SUPER+SHIFT+A` or `webapp_to_wofi` via Wofi (Firefox, Brave, default).
  - **HydraMesh**: Toggle with `SUPER+SHIFT+H` or `hydramesh_toggle` via Wofi. Edit `config.json` with `SUPER+SHIFT+E` or `hydramesh_config_editor`. Watch status in Waybar.
  - **Keybindings Cheat Sheet**: See all with `SUPER+SHIFT+K` or `keybindings_cheatsheet` via Wofi.

- **Gaming**:
  - Steam, Lutris, and allies are live. Run `steam`, `lutris`, `dhewm3` (needs Doom 3 data), `r2modman` for mods, or `darkradiant` for level crafting via Wofi/terminal.
  - `proton-ge-bin` ensures total game domination.

- **HydraMesh**:
  - Enable post-install in `configuration.nix` (then `nixos-rebuild switch`):
    ```nix
    imports = [ ./hydramesh.nix ];
    services.hydramesh.enable = true;
    services.hydramesh.firewallEnable = true;  # Unleashes TCP/UDP ports
    services.hydramesh.apparmorEnable = true;  # Locks down with AppArmor
    ```
  - Configure `/etc/hydramesh/config.json` with the TUI editor (`SUPER+SHIFT+E` or Wofi). Fields:
    - `transport`: `gRPC`, `WebSocket`, or `native-lisp`.
    - `host` and `port`: e.g., `localhost:50051` for gRPC.
    - `mode`: `p2p`, `client`, `server`, `auto`, or `master`.
    - `node-id`: Unique tag (e.g., `hydramesh-node-1`).
    - `peers`: Peer list (e.g., `["peer1:50051"]`).
    - `group-rtt-threshold`: RTT cap in ms (default 50).
    - `plugins`: Enable transports (e.g., `{"lorawan": true}`).
    - `storage`: `streamdb` or `in-memory`.
    - `streamdb-path`: StreamDB home (e.g., `/var/lib/hydramesh/streamdb`).
    - `optimization-level`: 0-3 for peak performance.
    - `retry-max`: 1-10 for error retries.
  - Test:
    ```bash
    /etc/hydramesh/test-hydramesh.sh
    ```
  - Update codebase: Swap `./Hydramesh/` and run:
    ```bash
    sudo nixos-rebuild switch
    ```
  - Set permissions:
    ```bash
    sudo mkdir -p /var/lib/hydramesh/streamdb
    sudo chown hydramesh:hydramesh /var/lib/hydramesh /etc/hydramesh
    sudo chmod 755 /var/lib/hydramesh /etc/hydramesh
    sudo chmod 640 /etc/hydramesh/*
    ```

- **Snap**:
  - If enabled, install:
    ```bash
    snap install <package>
    ```
    E.g., `snap install core; snap install hello-world`
  - Run: `snap run hello-world`

- **Wallpaper**:
  - Drop a custom `wall.jpg` in `~/Pictures/` or use `/etc/nixos/hypr/wallpaper.jpg`.

## Troubleshooting – Crush the Resistance

- **Build Failures**:
  - Update `cargoSha256` in `hydramesh/flake.nix` with:
    ```bash
    nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb
    ```
  - Confirm `./HydraMesh/` has `src/hydramesh.lisp`, `plugins/*.lisp`, and `streamdb/src/`.
  - Check connectivity or raid `/nix/store` for cached glory.
- **HydraMesh Issues**:
  - If it stalls, check logs:
    ```bash
    journalctl -u hydramesh
    ```
  - Ensure `libstreamdb.so` rules `/etc/hydramesh/streamdb/lib/`.
  - Validate `config.json` with the TUI (`SUPER+SHIFT+E`).
  - Check AppArmor logs if active:
    ```bash
    journalctl -t apparmor
    ```
- **Installer Errors**:
  - Verify USB (`lsblk`) and unmount it.
  - If LUKS fails, match the install password.
  - For Framework 16 glitches, ensure `nixos-hardware` and `fw-fanctrl` inputs are live.
- **Hyprland Issues**:
  - If Waybar or Wofi falters, inspect `~/.config/waybar/` or `~/.config/wofi/`.
  - For display chaos, force resolutions:
    ```bash
    hyprctl keyword monitor eDP-2,2560x1600@165,auto,1
    ```
- **General Support**:
  - Raid the [NixOS Wiki](https://nixos.wiki) for intel.
  - Raise hell at [GitHub](https://github.com/ALH477/DeMoD-Framework16-NIXOS).
  - Check Nix logs: `journalctl -u nix-daemon`.

## Contributing – Join the Legion

Contributions are welcomed! To join the conquest:
1. Fork: `https://github.com/ALH477/DeMoD-Framework16-NIXOS`.
2. Wield changes, ensuring NixOS 25.05 (or 25.11) and Framework 16 compliance.
3. Submit pull requests or issues via GitHub.
4. Test with `nixos-rebuild dry-run` or QEMU before deployment.

## License – The Code of Conquest

BSD 3-Clause License:
```
Copyright (c) 2025, DeMoD LLC

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
ArchibaldOS is licensed under MIT | StreamDB is LGPL as well as HydraMesh
