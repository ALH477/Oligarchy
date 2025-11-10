# Oligarchy NixOS

Oligarchy NixOS is a custom NixOS distribution optimized for the Framework Laptop 16 (AMD Ryzen 7040 series), with robust support for other x86_64 hardware. It is designed for developers, researchers, creators, gamers, and Framework enthusiasts, offering a lightweight, Wayland-based Hyprland desktop (with optional X11 Cinnamon and DWM support), a graphical Calamares installer, and extensive customization options. The distribution integrates the HydraMesh service, powered by the DeMoD-LISP (D-LISP) SDK, for low-latency peer-to-peer (P2P) communication, suitable for Internet of Things (IoT), edge computing, and gaming applications. With a focus on utilitarian efficiency, educational value, stability, and accessibility, Oligarchy NixOS supports Snap packages, a comprehensive gaming suite, and hardware-specific optimizations to achieve low power consumption (5-7W idle on Framework 16) and high performance.

![Oligarchy](https://repository-images.githubusercontent.com/1072001868/8b510033-8549-4c89-995d-d40f79680900)

[ISO download](https://archive.org/details/oligarchy)

## Why Oligarchy NixOS is Optimized and Supreme

Oligarchy NixOS stands out due to its carefully crafted features, ensuring a robust, secure, and user-friendly experience tailored to modern hardware and advanced use cases:

- **Low Idle Power Consumption**: Optimized for the Framework Laptop 16 with power-efficient settings:
  - **Power Profiles Daemon**: Dynamically adjusts CPU performance to minimize idle power usage (`power-profiles-daemon` enables balanced and low-power modes).
  - **AMDGPU Configuration**: Kernel parameters (`amdgpu.abmlevel=0`, `amdgpu.sg_display=0`, `amdgpu.exp_hw_support=1`) optimize GPU power draw, achieving 5-7W idle consumption on Framework 16 (when using integrated AMD graphics).
  - **Fan Control**: The `fw-fanctrl` module ensures efficient cooling, reducing fan activity during low loads to further lower power usage.
  - **Lid Switch Handling**: Configurable scripts (`lid.sh`, `toggle_clamshell.sh`) disable the laptop screen in clamshell mode, saving power for external monitor setups.
- **Framework 16 Compatibility**: Leverages `nixos-hardware` and `fw-fanctrl` for AMD Ryzen 7040 support, including GPU drivers (`amdgpu`), firmware updates (`fwupd`), and fingerprint authentication (`fprintd`). A fallback option ensures compatibility with other hardware.
- **Modular Package Management**: Nix’s declarative configuration allows precise control over installed components. Features like gaming (`steam`, `lutris`, `dhewm3`), Snap support, and the HydraMesh service are optional, keeping the system lean and customizable.
- **Lightweight Desktop**: Hyprland, paired with Waybar (system status bar) and Wofi (application launcher), provides a fast, modern Wayland-based desktop environment, minimizing resource usage while supporting multi-monitor and clamshell configurations. Optional X11 support via Cinnamon and DWM.
- **Streamlined Installation**: The graphical Calamares installer simplifies disk setup (LUKS-encrypted ext4), user configuration, hardware options, and HydraMesh security settings (firewall and AppArmor), ensuring a quick, secure, and user-friendly deployment process.
- **Customization Scripts**: Tools for resolution cycling, Hyprland configuration, theme switching, web app integration, HydraMesh management, and a keybindings cheat sheet enhance user control, accessible via Wofi or keyboard shortcuts.
- **Snap Support**: Snap is optional, expanding software availability without compromising Nix’s reproducibility.
- **HydraMesh Service**: Integrates the DeMoD-LISP SDK for low-latency P2P communication, supporting transports like gRPC, WebSocket, and LoRaWAN. It includes a TUI configuration editor, Waybar status indicator, and robust security (systemd hardening, optional firewall, and AppArmor), making it ideal for IoT, gaming, and edge computing.
- **Virtual Camera Support**: Kernel module `v4l2loopback` enables virtual webcams for streaming and video conferencing.

## Security

Oligarchy NixOS prioritizes security, particularly for the HydraMesh service, which handles networked P2P communication for IoT, gaming, and edge computing. The HydraMesh service is secured through a multi-layered approach, adhering to industry best practices (e.g., NIST SP 800-53, CIS Controls) to mitigate risks from untrusted network inputs and potential exploits. Below is a detailed explanation of how HydraMesh is secured:

- **Systemd Hardening**:
  - **Dedicated User and Group**: HydraMesh runs as a dedicated `hydramesh` user and group, created dynamically with `DynamicUser = true`. This isolates the service from other system processes, preventing privilege escalation if compromised.
  - **Restricted Environment**: The systemd service (`systemd.services.hydramesh`) applies strict confinement:
    - `PrivateDevices = true`: Blocks access to hardware devices (e.g., `/dev/sda`, `/dev/input`).
    - `ProtectSystem = "strict"`: Mounts `/usr`, `/boot`, and `/etc` as read-only, preventing unauthorized modifications.
    - `ProtectHome = true`: Denies access to user home directories.
    - `PrivateTmp = true`: Provides a private `/tmp` directory, isolating temporary files.
    - `NoNewPrivileges = true`: Prevents the service from gaining new privileges (e.g., via setuid binaries).
    - `CapabilityBoundingSet = ""`: Removes all Linux capabilities, limiting kernel-level operations.
    - `RestrictNamespaces = true`: Restricts access to kernel namespaces (e.g., network, mount), reducing attack surface.
    - `SystemCallFilter = "@system-service ~@privileged"`: Whitelists only necessary system calls, blocking privileged operations (e.g., kernel module loading).
  - **Low-Level Mechanics**: These directives are enforced by systemd during service startup, creating a sandboxed environment. The service runs `/etc/hydramesh/` as its working directory, with `hydramesh` user permissions (UID/GID dynamically assigned at runtime).
  - **Value**: This aligns with containerization security principles (e.g., Docker’s default settings), ensuring robust isolation for networked applications.

- **Optional Firewall**:
  - **Dynamic Port Configuration**: If `services.hydramesh.firewallEnable` is set to `true` (configured post-installation), the firewall opens the TCP port specified in `/etc/hydramesh/config.json` (default 50051 for gRPC) and UDP 5683 for LoRaWAN if the `lorawan` plugin is enabled (`"plugins": {"lorawan": true}`).
  - **Implementation**: The `networking.firewall` section in `hydramesh.nix` uses `builtins.fromJSON` to parse `config.json` and dynamically set `allowedTCPPorts` and `allowedUDPPorts`. This ensures only necessary ports are exposed, reducing the attack surface.
  - **Low-Level Mechanics**: NixOS’s firewall, based on `iptables` or `nftables`, applies rules during system activation (`nixos-rebuild switch`). For example, if `port = 50051` and LoRaWAN is enabled, rules like `iptables -A INPUT -p tcp --dport 50051 -j ACCEPT` and `iptables -A INPUT -p udp --dport 5683 -j ACCEPT` are added.
  - **Value**: Follows network segmentation best practices (e.g., CIS Control 12), ensuring only required ports are open, critical for public-facing IoT or gaming nodes.

- **Optional AppArmor Profile**:
  - **Confinement**: If `services.hydramesh.apparmorEnable` is set to `true` (configured post-installation), an AppArmor profile confines the HydraMesh service (`/usr/bin/sbcl`) to:
    - Read access to `/etc/hydramesh/**` (configuration files).
    - Read/write access to `/var/lib/hydramesh/**` (StreamDB data).
    - TCP and UDP network access for communication (e.g., gRPC, LoRaWAN).
    - `capability dac_override` for file operations within allowed paths.
  - **Complain Mode**: The profile uses `flags=(complain)` to log violations without blocking, aiding debugging while maintaining security during production testing.
  - **Low-Level Mechanics**: The profile is generated in `hydramesh.nix` using `pkgs.writeText` and loaded into `/etc/apparmor.d/` during system activation. AppArmor’s kernel module enforces restrictions, logging violations to `/var/log/audit/audit.log` (if `auditd` is enabled).
  - **Value**: Provides mandatory access control, aligning with OWASP Top 10 mitigation strategies, protecting against file system exploits and unauthorized network access.

- **File System Permissions**:
  - **Dedicated Directories**: HydraMesh uses `/etc/hydramesh/` for configuration (read-only for `hydramesh` user) and `/var/lib/hydramesh/` for data (read/write). Permissions are set with:
    ```bash
    sudo chown hydramesh:hydramesh /var/lib/hydramesh /etc/hydramesh
    sudo chmod 755 /var/lib/hydramesh /etc/hydramesh
    sudo chmod 640 /etc/hydramesh/*
    ```
  - **Low-Level Mechanics**: The `hydramesh` user, created by `DynamicUser`, owns these directories, ensuring only the service can access them. The `640` mode restricts configuration files to read-only for non-owners, preventing unauthorized modifications.
  - **Value**: Enforces least privilege, a core security principle (e.g., NIST SP 800-53 AC-6), preventing tampering with sensitive files.

- **Secure Configuration Management**:
  - **TUI Editor**: The `hydramesh_config_editor.py` script validates `config.json` inputs against the D-LISP SDK schema, ensuring safe edits with JSON parsing and user confirmation prompts.
  - **Low-Level Mechanics**: The script uses Python’s `curses` for a TUI, `json` for parsing, and `re` for input validation (e.g., numbers, booleans, arrays). Changes are written to `/etc/hydramesh/config.json` only after user confirmation, reducing misconfiguration risks.
  - **Value**: Mitigates configuration errors, a common attack vector in networked services.

- **System-Wide Security Features**:
  - **AppArmor**: Enabled system-wide (`security.apparmor.enable = true`) for mandatory access control on all processes.
  - **Polkit and RTKit**: `security.polkit.enable = true` for authorization, and `security.rtkit.enable = true` for real-time kernel privileges in audio/pipewire.
  - **PAM for Fingerprint**: `security.pam.services.login.fprintAuth = true` and `sudo.fprintAuth = true` for secure authentication.
  - **Firewall**: Always enabled (`networking.firewall.enable = true`), with dynamic rules for HydraMesh.
  - **Value**: Provides layered defense, aligning with best practices for system integrity and access control.

## Building

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/ALH477/DeMoD-Framework16-NIXOS.git
   cd DeMoD-Framework16-NIXOS
   ```

2. **Prepare Assets**:
   - Place `wallpaper.jpg` and `hydramesh.svg` in the repository root.
   - Ensure `./HydraMesh/` contains `src/hydramesh.lisp`, `plugins/*.lisp`, and `streamdb/src/`.

3. **Update StreamDB Hash**:
   ```bash
   nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb
   ```
   Replace `cargoSha256` in `hydramesh/flake.nix` with the output. Note: The separate StreamDB flake uses Crane for building, with WASM and encryption features; integrate if needed via inputs.

4. **Customize Configuration (Optional)**:
   - Edit `./configuration.nix` to toggle options like `custom.steam.enable`, `custom.snap.enable`, `custom.nvidia.enable` before building the ISO. By default, Steam, Snap, and NVIDIA support are enabled; Framework-specific optimizations and fan control are included via modules.

5. **Build the ISO**:
   ```bash
   nix build .#nixosConfigurations.iso.config.system.build.isoImage
   ```

6. **Flash the ISO**:
   Use `dd` or a tool like Popsicle to flash `result/iso/nixos-*.iso` to a USB drive.

7. **Installation**:
   - Boot from the USB. The live environment uses LightDM and i3 for a minimal graphical session.
   - Calamares will autostart on login. Follow the graphical steps:
     - **Partitioning**: Select and partition the target disk (e.g., `/dev/sda`), enabling LUKS encryption on ext4 as needed.
     - **User and System**: Configure hostname, username, passwords, locale, and timezone.
     - The installer will generate `hardware-configuration.nix`, copy the preconfigured `./configuration.nix` (with enabled features like Steam, Snap, NVIDIA drivers, and Hyprland), and complete the installation.
   - Reboot into the new system, entering the LUKS password at boot if encrypted.

8. **Test in QEMU** (Optional):
   ```bash
   qemu-system-x86_64 -cdrom result/iso/nixos-*.iso -m 4G -enable-kvm -cpu host
   ```

## State Sanctioned Usage

Once installed, Oligarchy NixOS provides a powerful and customizable environment:

- **Desktop**:
  - Hyprland starts automatically via SDDM, with Waybar displaying CPU, memory, battery, network, and HydraMesh status (🕸️ ON/OFF).
  - Launch applications via Wofi (`SUPER+D`) or the terminal (`SUPER+Q` for Kitty).
  - Use `SUPER+1-0` to switch workspaces, `SUPER+SHIFT+1-0` to move windows to workspaces, and `SUPER+S` for a special `demod` workspace.
  - Optional: Switch to Cinnamon or DWM via SDDM.

- **Customization**:
  - **Resolution**: Cycle resolutions with `SUPER+SHIFT+W` or `SUPER+SHIFT+F1-F5`, or run `toggle_resolution` via Wofi/terminal.
  - **Hyprland Config**: Modify wallpaper/keybindings with `SUPER+SHIFT+P` or `hyprland_config_modifier` via Wofi.
  - **Themes**: Switch color schemes with `SUPER+SHIFT+T` or `theme_changer` via Wofi (options: green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom).
  - **Web Apps**: Add web apps to Wofi with `SUPER+SHIFT+A` or `webapp_to_wofi` via Wofi (supports Firefox, Brave, or default browser).
  - **HydraMesh**: Toggle the service with `SUPER+SHIFT+H` or `hydramesh_toggle` via Wofi. Edit `config.json` with `SUPER+SHIFT+E` or `hydramesh_config_editor` via Wofi. Monitor status in Waybar.
  - **Keybindings Cheat Sheet**: View keybindings with `SUPER+SHIFT+K` or `keybindings_cheatsheet` via Wofi.

- **Gaming**:
  - Steam, Lutris, and related tools are enabled by default. Run `steam`, `lutris`, `dhewm3` (requires Doom 3 data files), `r2modman` for modded games, or `darkradiant` for level editing via Wofi or terminal.
  - Use `proton-ge-bin` for enhanced game compatibility.

- **HydraMesh**:
  - Enable the service post-installation by adding to `configuration.nix` (then run `nixos-rebuild switch`):
    ```nix
    imports = [ ./hydramesh.nix ];
    services.hydramesh.enable = true;
    services.hydramesh.firewallEnable = true;  # Enables firewall for TCP/UDP ports
    services.hydramesh.apparmorEnable = true;  # Enables AppArmor confinement
    ```
  - Configure via `/etc/hydramesh/config.json` using the TUI editor (`SUPER+SHIFT+E` or Wofi). Supported fields:
    - `transport`: `gRPC`, `WebSocket`, or `native-lisp`.
    - `host` and `port`: e.g., `localhost:50051` for gRPC.
    - `mode`: `p2p`, `client`, `server`, `auto`, or `master`.
    - `node-id`: Unique identifier (e.g., `hydramesh-node-1`).
    - `peers`: Array of peer addresses (e.g., `["peer1:50051"]`).
    - `group-rtt-threshold`: RTT threshold in ms (default 50).
    - `plugins`: Object to enable transports (e.g., `{"lorawan": true}`).
    - `storage`: `streamdb` or `in-memory`.
    - `streamdb-path`: Path for StreamDB (e.g., `/var/lib/hydramesh/streamdb`).
    - `optimization-level`: 0-3 for performance tuning.
    - `retry-max`: 1-10 for transient error retries.
  - Test the service:
    ```bash
    /etc/hydramesh/test-hydramesh.sh
    ```
  - Update the codebase by replacing `./HydraMesh/` contents and running:
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
  - If enabled during customization, install:
    ```bash
    snap install <package>
    ```
    Example: `snap install core; snap install hello-world`
  - Run: `snap run hello-world`

- **Wallpaper**:
  - Place a custom wallpaper at `~/Pictures/wall.jpg` or use the default `/etc/nixos/hypr/wallpaper.jpg`.

## Troubleshooting

- **Build Failures**:
  - Ensure `cargoSha256` in `hydramesh/flake.nix` is updated with:
    ```bash
    nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb
    ```
  - Verify `./HydraMesh/` contains `src/hydramesh.lisp`, `plugins/*.lisp`, and `streamdb/src/`.
  - Check internet connectivity for fetching dependencies, or use a cached `/nix/store`.

- **HydraMesh Issues**:
  - If the service fails to start, check logs:
    ```bash
    journalctl -u hydramesh
    ```
  - Ensure `libstreamdb.so` is built and accessible in `/etc/hydramesh/streamdb/lib/`.
  - Validate `config.json` with the TUI editor (`SUPER+SHIFT+E`).
  - Check AppArmor logs if enabled:
    ```bash
    journalctl -t apparmor
    ```

- **Installer Errors**:
  - Ensure the USB device is correctly identified (`lsblk`) and not mounted.
  - If LUKS decryption fails, verify the password matches the one set during installation.
  - For Framework 16 issues, confirm `nixos-hardware` and `fw-fanctrl` inputs are accessible.

- **Hyprland Issues**:
  - If Waybar or Wofi fails, check configs in `~/.config/waybar/` or `~/.config/wofi/`.
  - For display issues, manually set resolutions:
    ```bash
    hyprctl keyword monitor eDP-2,2560x1600@165,auto,1
    ```

- **General Support**:
  - Consult the [NixOS Wiki](https://nixos.wiki) for configuration help.
  - Open issues at [GitHub](https://github.com/ALH477/DeMoD-Framework16-NIXOS).
  - Check Nix logs: `journalctl -u nix-daemon`.

## Contributing

Contributions are welcome! To contribute:
1. Fork the repository: `https://github.com/ALH477/DeMoD-Framework16-NIXOS`.
2. Make changes, ensuring compatibility with NixOS 25.05 (or upcoming 25.11) and Framework 16.
3. Submit pull requests or issues via GitHub.
4. Test changes with `nixos-rebuild dry-run` or QEMU before submitting.

## License

This project is licensed under the BSD 3-Clause License:
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

**Note**: The HydraMesh codebase in `./HydraMesh/` is licensed under LGPL-3.0. See `./HydraMesh/LICENSE` for details.

## Notes

- **Doom 3**: `dhewm3` requires separately owned Doom 3 data files (e.g., from Steam).
- **Assets**: Ensure `wallpaper.jpg`, `hydramesh.svg`, and `./HydraMesh/` (with `src/hydramesh.lisp`, `plugins/*.lisp`, `streamdb/src/`) are in the repository root before building.
- **StreamDB Build**: Replace `cargoSha256` in `hydramesh/flake.nix` with the output of `nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb`. For advanced builds, use the separate StreamDB flake with Crane for WASM/encryption support.
- **Validation**: Locale/timezone inputs are handled via Calamares; use standard formats (e.g., `en_US.UTF-8`, `America/Los_Angeles`).
- **Snap**: Enable via `custom.snap.enable` in `configuration.nix` before building. Use `snap` commands post-install.
- **HydraMesh Security**: The firewall (if enabled) opens the TCP port specified in `config.json` (default 50051) and UDP 5683 for LoRaWAN if enabled. AppArmor (if enabled) confines the service to `/etc/hydramesh/**` (read) and `/var/lib/hydramesh/**` (read/write) with TCP/UDP access.
- **Password Security**: User and root passwords are set during Calamares installation and hashed for security.
- **Memory Management**: To exclude prior conversation references, go to "Data Controls" in settings or click the book icon beneath relevant messages to forget specific chats.
- **NVIDIA Support**: Enabled by default for hybrid graphics setups; disable via `custom.nvidia.enable = false;` in `configuration.nix` for pure AMD power optimization.
