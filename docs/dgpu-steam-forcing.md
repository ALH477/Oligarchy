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

The laptop panel (`eDP-2`) is physically wired to the iGPU only. The dGPU does
have its own outputs — `card1-DP-1`, the Framework Graphics Module's rear USB-C
ports — but no path whatsoever to the internal panel. This is not a
muxed-switching laptop; a "switch the whole display to dGPU" keybind is not
physically possible.

That asymmetry is the thing to keep in mind throughout: anything rendered on
the dGPU and shown on the internal panel has to be copied across devices.

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

## Session-wide `DRI_PRIME` is a bug — the rule, and how it was found

The original `DRI_PRIME=1` documented above was never traced to a source, and
this section does **not** claim to have found it: the value differs (`1`, not
the `pci-` form), so it may still have come from somewhere else, and it is no
longer present in the live session either way.

What was found is a separate and considerably larger problem in this repo.
`home/hyprland/default.nix` carried a `gpuEnv` binding emitting
`env=DRI_PRIME,pci-0000_03_00_0` into `hyprland.conf`.

That is a far bigger hammer than it looks. A Hyprland `env=` is *session-global*
— it is exported to every client **and** pushed into the systemd user manager's
environment — so a single line put the entire desktop on the dGPU, not just
games. Since the panel hangs off the iGPU, every client's every frame became a
cross-device dmabuf import. Symptoms, all of which were live on this machine:

- visible artifacts and flicker in Brave and other GPU-compositing clients;
- `hyprlock` wedging uninterruptibly in TTM buffer migration
  (`ttm_bo_move_memcpy` -> `amdgpu_bo_move`), which got its own per-unit
  `UnsetEnvironment = "DRI_PRIME"` band-aid before the real cause was found;
- the dGPU stuck at `runtime_status: active` with `gpu_busy_percent: 0` —
  clients held `renderD128` continuously, so amdgpu runtime PM never suspended
  it, and the battery paid for a GPU that was doing nothing.

It has been removed. The standing rule:

> **dGPU routing is per-app and opt-in. A session-wide `DRI_PRIME` is a bug.**

Three sanctioned routes, and no others:

| what | how | where |
|---|---|---|
| Steam and everything it launches | `extraEnv` on `programs.steam.package` | `configuration.nix` |
| any other command | `dgpu-run <cmd>` | `home/scripts/default.nix` |
| a systemd unit | `Environment=DRI_PRIME=…` on that unit | the unit |

`custom.platform.displayGpu` selects *which* device those opted-in routes point
at. It does not, and must not, put anything in the ambient environment.

### Checking for a regression

```sh
env | grep DRI_PRIME                            # expect: nothing
grep -c DRI_PRIME ~/.config/hypr/hyprland.conf  # expect: 0

# a browser should be on the iGPU (renderD129), never renderD128
ls -l /proc/$(pgrep -f brave | head -1)/fd | grep -o 'renderD12[89]' | sort -u

# with no game running, the dGPU should be asleep
cat /sys/bus/pci/devices/0000:03:00.0/power/runtime_status   # expect: suspended
```