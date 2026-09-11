# Android USB phone-mirror

Low-latency [scrcpy](https://github.com/Genymobile/scrcpy) over USB, aimed at
playing phone games (Bedrock Minecraft) on the desktop. Not a Wi-Fi mirror.

| | |
|---|---|
| `packages.default` | `phone-mirror` + vanilla `scrcpy` + desktop entries |
| `nixosModules.default` | `custom.androidMirror.enable` — udev, `adbusers`, the package |

```bash
nix run .#phone-mirror                 # from this directory, or nix run .#phone-mirror from the OS flake
phone-mirror                           # once enabled on the host
phone-mirror minecraft                 # --start-app=com.mojang.minecraftpe
```

`configuration.nix` sets `custom.androidMirror.enable` from
`custom.desktopFeatures.enablePersonalApps` (mkDefault). Re-login after the
first switch so `adbusers` is live (`id` should list it). USB debugging on,
unlock the phone, accept the RSA prompt.

Use a USB 3 data cable on a USB 3 port. Charging-only cables fail as "no
device". If the xHCI controller wedges, `sudo xhci-recover`.

Do not add `DRI_PRIME` / `AQ_DRM_DEVICES` / `WLR_DRM_DEVICES`. Decode stays on
the iGPU next to Hyprland.

Env knobs: `PHONE_MIRROR_{MAX_SIZE,FPS,BITRATE,CODEC,APP}`, `ANDROID_SERIAL`.
Extra scrcpy flags after `--`. Virtual display (Android 15+):

```bash
phone-mirror -- --new-display=1920x1080 --start-app=com.mojang.minecraftpe
```
