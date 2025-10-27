# Oligarchy NixOS

Oligarchy NixOS is a custom NixOS distribution optimized for the Framework Laptop 16 (AMD Ryzen 7040 series), with robust support for other x86_64 hardware. It is designed for developers, researchers, creators, gamers, and Framework enthusiasts, offering a lightweight, Wayland-based Hyprland desktop, a guided Text User Interface (TUI) installer, and extensive customization options. The distribution integrates the HydraMesh service, powered by the DeMoD-LISP (D-LISP) SDK, for low-latency peer-to-peer (P2P) communication, suitable for Internet of Things (IoT), edge computing, and gaming applications. With a focus on utilitarian efficiency, educational value, stability, and accessibility, Oligarchy NixOS supports Flatpak and Snap packages, a comprehensive gaming suite, and hardware-specific optimizations to achieve low power consumption (5-7W idle on Framework 16) and high performance.

![Oligarchy](https://repository-images.githubusercontent.com/1072001868/8b510033-8549-4c89-995d-d40f79680900)

## Why Oligarchy NixOS is Optimized and Supreme

Oligarchy NixOS stands out due to its carefully crafted features, ensuring a robust, secure, and user-friendly experience tailored to modern hardware and advanced use cases:

- **Low Idle Power Consumption**: Optimized for the Framework Laptop 16 with power-efficient settings:
  - **Power Profiles Daemon**: Dynamically adjusts CPU performance to minimize idle power usage (`power-profiles-daemon` enables balanced and low-power modes).
  - **AMDGPU Configuration**: Kernel parameters (`amdgpu.abmlevel=0`, `amdgpu.sg_display=0`, `amdgpu.exp_hw_support=1`) optimize GPU power draw, achieving 5-7W idle consumption on Framework 16.
  - **Fan Control**: The `fw-fanctrl` module ensures efficient cooling, reducing fan activity during low loads to further lower power usage.
  - **Lid Switch Handling**: Configurable scripts (`lid.sh`, `toggle_clamshell.sh`) disable the laptop screen in clamshell mode, saving power for external monitor setups.
- **Framework 16 Compatibility**: Leverages `nixos-hardware` and `fw-fanctrl` for AMD Ryzen 7040 support, including GPU drivers (`amdgpu`), firmware updates (`fwupd`), and fingerprint authentication (`fprintd`). A fallback option in the installer ensures compatibility with other hardware.
- **Modular Package Management**: Nix’s declarative configuration allows precise control over installed components. Features like gaming (`steam`, `lutris`, `dhewm3`), Snap support, and the HydraMesh service are optional, keeping the system lean and customizable.
- **Lightweight Desktop**: Hyprland, paired with Waybar (system status bar) and Wofi (application launcher), provides a fast, modern Wayland-based desktop environment, minimizing resource usage while supporting multi-monitor and clamshell configurations.
- **Streamlined Installation**: A TUI installer simplifies disk setup (LUKS-encrypted ext4), user configuration, hardware options, and HydraMesh security settings (firewall and AppArmor), ensuring a quick, secure, and user-friendly deployment process.
- **Customization Scripts**: Tools for resolution cycling, Hyprland configuration, theme switching, web app integration, HydraMesh management, and a keybindings cheat sheet enhance user control, accessible via Wofi or keyboard shortcuts.
- **Flatpak and Snap Support**: Flatpak is enabled by default for broad application access, while Snap is optional, expanding software availability without compromising Nix’s reproducibility.
- **HydraMesh Service**: Integrates the DeMoD-LISP SDK for low-latency P2P communication, supporting transports like gRPC, WebSocket, and LoRaWAN. It includes a TUI configuration editor, Waybar status indicator, and robust security (systemd hardening, optional firewall, and AppArmor), making it ideal for IoT, gaming, and edge computing.

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
  - **Dynamic Port Configuration**: If `services.hydramesh.firewallEnable` is set to `true` (prompted during installation), the firewall opens the TCP port specified in `/etc/hydramesh/config.json` (default 50051 for gRPC) and UDP 5683 for LoRaWAN if the `lorawan` plugin is enabled (`"plugins": {"lorawan": true}`).
  - **Implementation**: The `networking.firewall` section in `hydramesh.nix` uses `builtins.fromJSON` to parse `config.json` and dynamically set `allowedTCPPorts` and `allowedUDPPorts`. This ensures only necessary ports are exposed, reducing the attack surface.
  - **Low-Level Mechanics**: NixOS’s firewall, based on `iptables` or `nftables`, applies rules during system activation (`nixos-rebuild switch`). For example, if `port = 50051` and LoRaWAN is enabled, rules like `iptables -A INPUT -p tcp --dport 50051 -j ACCEPT` and `iptables -A INPUT -p udp --dport 5683 -j ACCEPT` are added.
  - **Value**: Follows network segmentation best practices (e.g., CIS Control 12), ensuring only required ports are open, critical for public-facing IoT or gaming nodes.

- **Optional AppArmor Profile**:
  - **Confinement**: If `services.hydramesh.apparmorEnable` is set to `true` (prompted during installation), an AppArmor profile confines the HydraMesh service (`/usr/bin/sbcl`) to:
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

- **System-Wide Security**:
  - **LUKS Encryption**: The installer configures LUKS-encrypted ext4 for the root filesystem, protecting data at rest.
  - **Hashed Passwords**: User and root passwords are hashed with `mkpasswd -m sha-512` during installation, ensuring secure authentication.
  - **System-Wide Firewall**: Enabled by default (`networking.firewall.enable = true` in `configuration.nix`), providing a baseline defense for all services.
  - **Low-Level Mechanics**: LUKS uses `dm-crypt` for encryption, with the key stored in memory during boot. The firewall applies `iptables`/`nftables` rules globally, complementing HydraMesh’s specific rules.
  - **Value**: Aligns with defense-in-depth principles, protecting both the service and the broader system.

These measures ensure HydraMesh is secure for production use, protecting against unauthorized access, data breaches, and exploits in networked environments like IoT and gaming.

## Who and What It’s Good For

Oligarchy NixOS is ideal for users seeking a Linux distribution that balances practical functionality, educational value, stability, and accessibility. Its target audiences and use cases include:

- **Developers and Learners**:
  - **Use Cases**: Programming in multiple languages (C, Rust, Go, Python, Lisp), developing distributed systems with HydraMesh, and learning NixOS’s declarative configuration. The distro supports tools like `gcc`, `rustc`, `sbcl` with Lisp packages, and `docker`, alongside networking utilities (`wireshark`, `nmap`, `mininet`).
  - **Value**: The TUI installer, customization scripts (e.g., `hydramesh_config_editor`, `theme_changer`), and HydraMesh’s Lisp-based SDK provide hands-on learning opportunities. The `keybindings_cheatsheet` simplifies navigation, while Nix’s reproducibility encourages experimentation without risking system stability.
- **Creators and Content Producers**:
  - **Use Cases**: Video editing (Kdenlive), 3D modeling (Blender), graphic design (GIMP, Inkscape), and audio production (Ardour, Audacity). The distro supports hardware-accelerated graphics (Mesa, AMD Vulkan) for efficient workflows.
  - **Value**: Stable, reproducible environments prevent disruptions, and accessibility features like Wofi (`SUPER+D`) and web app integration (`webapp_to_wofi`) streamline creative tasks. Tools like `natron` (VFX) and `sweethome3d` (3D home planning) add versatility.
- **Gamers and Modders**:
  - **Use Cases**: Running Steam, Lutris, and Wine for gaming, modding with `r2modman`, and level editing with `darkradiant`. HydraMesh enhances P2P multiplayer with low-latency communication.
  - **Value**: Optional gaming toggle minimizes bloat, while `proton-ge-bin` ensures compatibility. Framework 16’s GPU is optimized for performance, and Nix’s stability prevents conflicts in gaming setups.
- **Framework Enthusiasts and Mobile Users**:
  - **Use Cases**: Deploying IoT nodes, experimenting with hardware configurations (via `framework-tool`), and using software-defined radio (`sdrpp`) or antenna simulation (`xnec2c`). The `eliza` chatbot adds an educational AI component.
  - **Value**: Power-efficient settings (5-7W idle) and hardware support (fingerprint, firmware) make it ideal for mobile use. The TUI installer and keybindings ensure accessibility for hardware tinkerers.
- **Scientific Researchers and Engineers**:
  - **Use Cases**: Molecular dynamics (`lammps`, `gromacs`), bioinformatics (`blast`, `emboss`), and reproducible workflows (`snakemake`, `nextflow`). HydraMesh supports IoT and edge computing research.
  - **Value**: Nix’s reproducibility ensures consistent results, while the TUI editor and Waybar status simplify HydraMesh configuration. Specialized tools and Lisp-based SDK cater to advanced research needs.

## Features for the Masses

Oligarchy NixOS offers a rich set of features, designed to be both powerful and user-friendly:
- **Guided TUI Installer**: Prompts for keyboard layout, disk selection (LUKS-encrypted ext4), Framework hardware support, locale, timezone, hostname, user accounts, gaming support, Snap support, and HydraMesh security (firewall, AppArmor), ensuring a customized and secure setup.
- **Hyprland Desktop**: A fast Wayland compositor with Waybar (displays CPU, memory, battery, network, and HydraMesh status) and Wofi (application launcher), configured for multi-monitor and clamshell mode.
- **Customization Scripts**:
  - `toggle_resolution`: Cycles monitor resolutions (`SUPER+SHIFT+W` or Wofi).
  - `hyprland_config_modifier`: Edits Hyprland wallpaper/keybindings (`SUPER+SHIFT+P` or Wofi).
  - `theme_changer`: Switches color schemes (green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom) (`SUPER+SHIFT+T` or Wofi).
  - `webapp_to_wofi`: Adds web apps to Wofi (`SUPER+SHIFT+A` or Wofi), supporting Firefox, Brave, or default browser.
  - `hydramesh_toggle`: Toggles the HydraMesh service (`SUPER+SHIFT+H` or Wofi), with status (🕸️ ON/OFF) shown in Waybar using `hydramesh.svg`.
  - `hydramesh_config_editor`: Edits HydraMesh’s `config.json` in a TUI (`SUPER+SHIFT+E` or Wofi).
  - `keybindings_cheatsheet`: Displays Hyprland keybindings in a `zenity` popup (`SUPER+SHIFT+K` or Wofi).
- **Gaming Support**: Optional toggle enables `steam`, `lutris`, `wineWowPackages.stable`, `dhewm3` (Doom 3 port), `r2modman` (mod manager), `darkradiant` (level editor), and `proton-ge-bin` for compatibility.
- **HydraMesh Service**: Runs the DeMoD-LISP SDK for low-latency P2P communication, sourced from `./HydraMesh/` (with `src/hydramesh.lisp`, `plugins/*.lisp`, `streamdb/src/`). Configurable via `config.json` with fields:
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
  Secured with systemd hardening, optional firewall (dynamic TCP port from `config.json`, UDP 5683 for LoRaWAN), and AppArmor (complain mode).
- **Flatpak and Snap**: Flatpak is enabled by default (`flatpak install flathub <app-id>`). Snap is optional (`snap install <package>`).
- **Framework 16 Optimization**: Hardware-specific modules for AMD Ryzen 7040, with fallback for other systems.
- **Comprehensive Packages**: A broad set of tools for development, multimedia, networking, and utilities.

## Packages

### Main Packages
Always installed, covering development, multimedia, networking, utilities, and desktop environment:
- **Development Tools**:
  - `vim`: Text editor for coding and configuration.
  - `docker`: Containerization for development and deployment.
  - `git`, `git-lfs`, `gh`: Version control and GitHub CLI for project management.
  - `cmake`, `gcc`, `gnumake`, `ninja`: Build systems for compiling software.
  - `rustc`, `cargo`: Rust development for systems programming and StreamDB.
  - `go`: Go programming for networked applications.
  - `openssl`, `gnutls`, `pkgconf`, `snappy`: Cryptography and build tools.
  - `python3Full` with `pip`, `virtualenv`, `cryptography`, `pycryptodome`, `grpcio`, `grpcio-tools`, `protobuf`, `numpy`, `matplotlib`, `python-snappy`: Python with scientific and networking libraries.
  - `perl` with `JSON`, `GetoptLong`, `CursesUI`, `ModulePluggable`, `Appcpanminus`: Perl scripting with JSON and TUI support.
  - `sbcl` with `cffi`, `cl-ppcre`, `cl-json`, `cl-csv`, `usocket`, `bordeaux-threads`, `log4cl`, `trivial-backtrace`, `cl-store`, `hunchensocket`, `fiveam`, `cl-dot`, `cserial-port`, `cl-lorawan`, `cl-lsquic`, `cl-can`, `cl-sctp`, `cl-zigbee`: Steel Bank Common Lisp with packages for HydraMesh and networking.
  - `libserialport`, `can-utils`, `lksctp-tools`, `cjson`, `ncurses`, `libuuid`: Hardware and networking libraries for IoT and serial communication.
  - `kicad`, `graphviz`, `mako`, `openscad`, `freecad`: PCB design and CAD for hardware development.
  - `nextflow`, `emboss`, `blast`, `lammps`, `gromacs`, `snakemake`: Bioinformatics and scientific computing tools for research.
  - `librecad`, `qcad`, `sweethome3d`: CAD and 3D home design for architecture and prototyping.
  - `sdrpp`: Software-defined radio for RF engineering.
  - `natron`: Video effects for post-production.
  - `xnec2c`: Antenna modeling for radio enthusiasts.
  - `eliza`: AI chatbot for educational exploration.
  - `systemctl-tui`: Systemd TUI manager for service management.
- **Multimedia**:
  - `ardour`, `audacity`, `ffmpeg-full`, `jack2`, `qjackctl`, `libpulseaudio`, `pkgsi686Linux.libpulseaudio`, `pavucontrol`, `guitarix`: Audio production and processing.
  - `vlc`, `pandoc`, `kdePackages.okular`, `obs-studio`: Media playback, document conversion, and streaming.
  - `gimp`, `kdePackages.kdenlive`, `inkscape`, `blender`, `libreoffice`, `krita`: Graphics, video editing, and office productivity.
- **Networking**:
  - `wireshark`, `tcpdump`, `nmap`, `netcat`, `mininet`: Network analysis and emulation for debugging and research.
  - `blueberry`: Bluetooth management for peripherals.
  - `networkmanager`: Network configuration for seamless connectivity.
- **Utilities**:
  - `htop`, `nvme-cli`, `lm_sensors`, `s-tui`, `stress`, `dmidecode`, `util-linux`, `gparted`, `usbutils`: System monitoring and disk management.
  - `zip`, `unzip`, `fastfetch`, `gnugrep`: File and system utilities.
  - `unetbootin`, `popsicle`, `gnome-disk-utility`, `framework-tool`: USB and Framework-specific utilities.
  - `zenity`: GUI dialog for keybindings cheat sheet.
- **Desktop Environment**:
  - `kitty`, `wofi`, `waybar`, `hyprpaper`, `brightnessctl`, `wl-clipboard`, `grim`, `slurp`, `v4l-utils`: Hyprland tools for terminal, launcher, status bar, and screenshots.
  - `xfce.thunar`, `xfce.thunar-volman`, `gvfs`, `udiskie`, `polkit_gnome`, `font-awesome`: File management and desktop utilities.
  - `xorg.xinit`: X server fallback support.
- **Virtualization**:
  - `qemu`, `virt-manager`, `docker-compose`, `docker-buildx`: Virtualization and container tools for development and testing.
- **Graphics**:
  - `vulkan-tools`, `vulkan-loader`, `vulkan-validation-layers`, `libva-utils`: Vulkan and VAAPI for graphics acceleration.
  - `mesa`, `amdvlk`, `vaapiVdpau`, `libvdpau-va-gl`, `rocmPackages.clr.icd`: Graphics drivers optimized for AMD hardware.
- **Browsers/Productivity**:
  - `brave`, `firefox`, `thunderbird`: Web browsing and email.
  - `vesktop`: Discord client for communication.
  - `unstable.openvscode-server`: VS Code server for development (from nixpkgs-unstable).

### Optional Gaming Packages
Enabled with `custom.steam.enable` (prompted during installation):
- `steam`, `steam-run`, `linuxConsoleTools`, `lutris`, `wineWowPackages.stable`, `dhewm3`, `r2modman`, `darkradiant`, `proton-ge-bin`

### Installer Dependencies
Included in the live ISO for installation:
- `disko`: Disk partitioning and formatting.
- `dialog`: TUI framework for installer prompts.
- `python3`: Runtime for customization scripts and TUI editor.

## Prerequisites

To build and install Oligarchy NixOS, ensure the following:
- A system with Nix installed (or a NixOS environment) for building the ISO.
- A Framework Laptop 16 (AMD Ryzen 7040 series) for optimal hardware support, though compatible with other x86_64 systems.
- A USB drive (at least 8GB) for flashing the ISO.
- The following files in the repository root:
  - `flake.nix`: Defines NixOS configurations and installer.
  - `configuration.nix`: System-wide settings and packages.
  - `hardware-configuration.nix`: Hardware-specific settings (generate during installation).
  - `hydramesh.nix`: HydraMesh service configuration.
  - `hydramesh_config_editor.py`: TUI editor for HydraMesh configuration.
  - `README.md`: This documentation.
  - `wallpaper.jpg`: Default wallpaper for Hyprland and SDDM (provide a valid image file).
  - `hydramesh.svg`: Waybar icon for HydraMesh status (provide a valid SVG file).
  - `./HydraMesh/` directory, containing:
    - `src/hydramesh.lisp`: Main D-LISP SDK code.
    - `plugins/*.lisp`: Plugin files (e.g., `lorawan.lisp` for LoRaWAN transport).
    - `streamdb/src/`: StreamDB Rust source code, building `libstreamdb.so`.
- Internet access for fetching dependencies during the build (optional for offline installs; ensure cached packages if offline).
- Root privileges for flashing the ISO and setting permissions.

## Installation

Follow these steps to build, flash, and install Oligarchy NixOS:

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/ALH477/DeMoD-Framework16-NIXOS
   cd DeMoD-Framework16-NIXOS
   ```

2. **Ensure Assets**:
   - Place `wallpaper.jpg` and `hydramesh.svg` in the repository root for Hyprland/SDDM and Waybar, respectively.
   - Ensure the `./HydraMesh/` directory exists in the repository root, containing `src/hydramesh.lisp`, `plugins/*.lisp`, and `streamdb/src/`.

3. **Compute StreamDB Hash**:
   - Run the following command to compute the `cargoSha256` for the StreamDB derivation in `hydramesh.nix`:
     ```bash
     nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb
     ```
   - Replace `sha256-placeholder-compute-with-nix-prefetch` in `hydramesh.nix` with the output hash.

4. **Build the ISO**:
   - Build the live ISO using Nix Flakes:
     ```bash
     nix build .#nixosConfigurations.iso.config.system.build.isoImage
     ```
   - The resulting ISO will be in `result/iso/nixos-*.iso`.

5. **Flash to USB**:
   - Identify your USB device (e.g., `/dev/sdX`) using `lsblk`. Ensure it’s unmounted and not in use.
   - Flash the ISO to the USB drive:
     ```bash
     sudo dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress
     sync
     ```
   - Replace `/dev/sdX` with your USB device path.

6. **Boot and Install**:
   - Boot from the USB drive (configure BIOS/UEFI to prioritize USB boot).
   - Log in with username `nixos` and password `nixos`.
   - The TUI installer starts automatically in a Kitty terminal, displaying the Oligarchy ASCII logo.
   - Follow the TUI prompts:
     - **Keyboard Layout**: Select from a menu (e.g., `us`, `gb`, `de`, etc.).
     - **Disk**: Choose a disk to wipe and install (LUKS-encrypted ext4). Warning: This erases all data on the selected disk.
     - **LUKS Password**: Enter and confirm a password for disk encryption.
     - **HydraMesh Service**: Enable/disable the HydraMesh service.
     - **HydraMesh Security**: Enable/disable firewall (opens TCP port from `config.json`, UDP 5683 for LoRaWAN if enabled) and AppArmor (complain mode).
     - **Framework Hardware**: Enable/disable Framework 16 optimizations (disabling supports other hardware).
     - **Locale/Timezone**: Set language (e.g., `en_US.UTF-8`) and timezone (e.g., `America/Los_Angeles`).
     - **Hostname/Username**: Configure system hostname and user identity (e.g., `nixos`, `asher`).
     - **Passwords**: Set user password and optional root password (hashed for security).
     - **Gaming**: Enable/disable Steam and gaming packages.
     - **Snap**: Enable/disable Snap package support.
   - The installer partitions the disk, generates `hardware-configuration.nix`, copies configuration files, and installs the system.
   - Reboot into the new system, entering the LUKS password at boot.

7. **Test in QEMU** (Optional):
   - Test the ISO in a virtual machine before flashing:
     ```bash
     qemu-system-x86_64 -cdrom result/iso/nixos-*.iso -m 4G -enable-kvm -cpu host
     ```

## State Sanctioned Usage

Once installed, Oligarchy NixOS provides a powerful and customizable environment:

- **Desktop**:
  - Hyprland starts automatically, with Waybar displaying CPU, memory, battery, network, and HydraMesh status (🕸️ ON/OFF).
  - Launch applications via Wofi (`SUPER+D`) or the terminal (`SUPER+Q` for Kitty).
  - Use `SUPER+1-0` to switch workspaces, `SUPER+SHIFT+1-0` to move windows to workspaces, and `SUPER+S` for a special `demod` workspace.

- **Customization**:
  - **Resolution**: Cycle resolutions with `SUPER+SHIFT+W` or `SUPER+SHIFT+F1-F5`, or run `toggle_resolution` via Wofi/terminal.
  - **Hyprland Config**: Modify wallpaper/keybindings with `SUPER+SHIFT+P` or `hyprland_config_modifier` via Wofi.
  - **Themes**: Switch color schemes with `SUPER+SHIFT+T` or `theme_changer` via Wofi (options: green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom).
  - **Web Apps**: Add web apps to Wofi with `SUPER+SHIFT+A` or `webapp_to_wofi` via Wofi (supports Firefox, Brave, or default browser).
  - **HydraMesh**: Toggle the service with `SUPER+SHIFT+H` or `hydramesh_toggle` via Wofi. Edit `config.json` with `SUPER+SHIFT+E` or `hydramesh_config_editor` via Wofi. Monitor status in Waybar.
  - **Keybindings Cheat Sheet**: View keybindings with `SUPER+SHIFT+K` or `keybindings_cheatsheet` via Wofi.

- **Gaming**:
  - If enabled, run `steam`, `lutris`, `dhewm3` (requires Doom 3 data files), `r2modman` for modded games, or `darkradiant` for level editing via Wofi or terminal.
  - Use `proton-ge-bin` for enhanced game compatibility.

- **HydraMesh**:
  - Enable the service by adding to `configuration.nix`:
    ```nix
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

- **Flatpak**:
  - Install applications:
    ```bash
    flatpak install flathub <app-id>
    ```
    Example: `flatpak install flathub com.spotify.Client`
  - Run: `flatpak run com.spotify.Client`

- **Snap**:
  - If enabled, install:
    ```bash
    snap install <package>
    ```
    Example: `snap install core; snap install hello-world`
  - Run: `snap run hello-world`

- **Wallpaper**:
  - Place a custom wallpaper at `~/Pictures/wall.jpg` or use the default `/etc/nixos/hypr/wallpaper.jpg`.

## Troubleshooting

- **Build Failures**:
  - Ensure `cargoSha256` in `hydramesh.nix` is updated with:
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
2. Make changes, ensuring compatibility with NixOS 25.05 and Framework 16.
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
- **StreamDB Build**: Replace `cargoSha256` in `hydramesh.nix` with the output of `nix-prefetch-url --unpack file://$(pwd)/HydraMesh/streamdb`.
- **Validation**: Locale/timezone inputs are not validated in the installer; use standard formats (e.g., `en_US.UTF-8`, `America/Los_Angeles`).
- **Flatpak/Snap**: Flatpak is enabled by default; Snap requires enabling during installation. Use `flatpak` or `snap` commands post-install.
- **HydraMesh Security**: The firewall (if enabled) opens the TCP port specified in `config.json` (default 50051) and UDP 5683 for LoRaWAN if enabled. AppArmor (if enabled) confines the service to `/etc/hydramesh/**` (read) and `/var/lib/hydramesh/**` (read/write) with TCP/UDP access.
- **Password Security**: User and root passwords are hashed using `mkpasswd -m sha-512` during installation for enhanced security.
- **Memory Management**: To exclude prior conversation references, go to "Data Controls" in settings or click the book icon beneath relevant messages to forget specific chats.