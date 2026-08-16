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

**Superseded by a real option** — this used to be a hardcoded, copy-pasted
`extraEnv` block. It's now driven by `custom.platform.displayGpu` /
`dgpuPciId` (`modules/platform.nix`), a general dual-AMD-GPU option, not a
Steam-specific patch. Override `programs.steam.package` to inject
`DRI_PRIME` into Steam's FHS environment via the `extraEnv` parameter, only
when `displayGpu == "dgpu"` (the default) — so flipping that one option to
`"igpu"` (e.g. on battery) also stops force-routing Steam to the dGPU:

```nix
# configuration.nix — "Gaming" section
programs.steam = lib.mkIf config.custom.steam.enable {
  enable = true;
  extraCompatPackages = [ pkgs.proton-ge-bin ];
  package = lib.mkIf (config.custom.platform.displayGpu == "dgpu") (pkgs.steam.override {
    extraEnv = {
      DRI_PRIME = "pci-" + lib.replaceStrings [ ":" "." ] [ "_" "_" ] config.custom.platform.dgpuPciId;
    };
  });
};
```

`config.custom.platform.dgpuPciId` defaults to `"0000:03:00.0"` (this
machine's Navi 33) — see `modules/platform.nix`.

Every Steam-launched game (Proton or native) inherits this env var and
renders on the dGPU. The dGPU still powers down when no game is using it.

Since then, Steam is also launched through a hardened, swap-isolated
`systemd-run` wrapper rather than the raw binary (both from the IceWM menu in
`configuration.nix` and the `steam.desktop` override in
`home/apps/desktop-entries.nix`) — see `docs/security-hardening.md` Phase 7.
That wrapper is orthogonal to `DRI_PRIME`: it controls the cgroup/sandbox the
process runs in, not which GPU it renders on.

### Do NOT try to also force Hyprland's own backend device onto the dGPU

A follow-up attempt added `AQ_DRM_DEVICES` to `home/hyprland/default.nix` to
make Hyprland/Aquamarine itself prefer the dGPU, with the dGPU listed first
and the iGPU as a "fallback." **This crashed Hyprland outright** — confirmed
via coredump (`CCompositor::initServer` → `throwError` → `SIGABRT`) — and
took greetd down with it in a crash loop, locking out both Hyprland and
IceWM until a hard reboot. `AQ_DRM_DEVICES` does not gracefully fall back
here: per the hardware topology above, the dGPU has no display engine path
at all, so telling Aquamarine to open it as the primary backend/KMS device
is fatal, not just suboptimal, and there's nothing a "fallback" entry could
succeed at. The compositor's own backend has to stay on the iGPU regardless
of `displayGpu`; only client-app rendering (`DRI_PRIME`, above) can be
routed to the dGPU. Don't re-attempt this.

This is now also enforced by a Home Manager assertion in
`home/hyprland/default.nix` (checked at build time against
`wayland.windowManager.hyprland.settings.env`), not comments alone — a
regression that re-adds `AQ_DRM_DEVICES`/`WLR_DRM_DEVICES` will fail the
build instead of only failing at runtime.

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