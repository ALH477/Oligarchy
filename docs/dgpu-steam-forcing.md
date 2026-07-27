# Force Steam Games to Use the dGPU (Radeon RX 7600)

## Problem

Steam games were rendering on the iGPU (AMD Phoenix1, `c5:00.0`) instead of
the dGPU (AMD Navi 33 / RX 7600, `03:00.0`).

A stray `DRI_PRIME=1` was found in the Steam process environment. On this
dual-AMD system, Mesa PRIME index `1` maps to the **iGPU** (`renderD129`), not
the dGPU — the kernel enumeration order doesn't match the assumption that
"index 1 = discrete." The game (`PioneerGame.exe` / Arc Raiders) held
file descriptors to `/dev/dri/renderD129` (iGPU), and `card1` (dGPU) sat idle.

## Hardware Topology

| GPU            | PCI address  | DRM device     | Role                |
|----------------|--------------|----------------|---------------------|
| Navi 33 RX 7600| `0000:03:00.0`| `renderD128` (card1) | dGPU (render offload) |
| Phoenix1       | `0000:c5:00.0`| `renderD129` (card2) | iGPU (drives eDP panel)|

The laptop panel (`eDP-2`) is physically wired to the iGPU only. The dGPU is
render-offload only — it has no display engine path to the panel. This is not
a muxed-switching laptop; a "switch the whole display to dGPU" keybind is not
physically possible.

## Fix

Override `programs.steam.package` to inject `DRI_PRIME` into Steam's FHS
environment via the `extraEnv` parameter. Every Steam-launched game (Proton or
native) inherits this env var and renders on the dGPU. The dGPU still powers
down when no game is using it.

### Change to apply (both repositories)

**`/etc/nixos/configuration.nix`** — lines ~175–178:

```nix
programs.steam = lib.mkIf config.custom.steam.enable {
  enable = true;
  extraCompatPackages = [ pkgs.proton-ge-bin ];
  package = pkgs.steam.override {
    extraEnv = {
      DRI_PRIME = "pci-0000_03_00_0";  # Navi 33 dGPU (renderD128)
    };
  };
};
```

**`~/Documents/oligarchy2/Oligarchy/configuration.nix`** — lines ~356–359:

```nix
programs.steam = lib.mkIf config.custom.steam.enable {
  enable = true;
  extraCompatPackages = [ pkgs.proton-ge-bin ];
  package = pkgs.steam.override {
    extraEnv = {
      DRI_PRIME = "pci-0000_03_00_0";  # Navi 33 dGPU (renderD128)
    };
  };
};
```

### Why `pci-0000_03_00_0`

The explicit-PCI form (`pci-` + bus address with underscores) is unambiguous
and survives kernel enumeration reordering. The bare index form (`DRI_PRIME=1`)
is fragile because index assignment follows whatever order the kernel registers
the DRM devices, which doesn't necessarily match "discrete = 1."

Conversion: PCI slot `0000:03:00.0` → `pci-0000_03_00_0`.

### Why `extraEnv` works

The NixOS `programs.steam` module's `apply` hook calls `steam.override` and
merges `extraEnv` into the FHS wrapper. The exported variables propagate:
Steam → pressure-vessel → Proton → game process. They take precedence over
any ambient session value, so even the stray `DRI_PRIME=1` in the environment
is overridden cleanly.

The module's own documentation example uses this exact pattern:

```nix
pkgs.steam.override {
  extraEnv = {
    MANGOHUD = true;
    RADV_TEX_ANISO = 16;
  };
}
```

## After Rebuild

### Rebuild

```sh
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

### Verify

1. Relaunch the game from Steam.
2. Check which render node the game process holds:
   ```sh
   ls -l /proc/$(pgrep -f PioneerGame)/fd | grep render
   ```
   Should show `renderD128` (dGPU), not `renderD129` (iGPU).

3. Check GPU busy percentages:
   ```sh
   cat /sys/class/drm/card1/device/gpu_busy_percent  # dGPU — should climb
   cat /sys/class/drm/card2/device/gpu_busy_percent  # iGPU — should settle
   ```

## Stray `DRI_PRIME=1` Origin

The `DRI_PRIME=1` was found in the live Steam process environment but was not
located in any NixOS config, shell rc, `environment.d`, or Hyprland config. It
likely originates from a `nixos-hardware` Framework module or a leftover
session variable. The `extraEnv` override makes it harmless (the explicit PCI
form wins), but if you want a clean session it can be hunted down separately.