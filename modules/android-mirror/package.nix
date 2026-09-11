# phone-mirror — scrcpy with the flags that actually matter for USB game play.
#
# H264 not H265: encode latency on the phone beats extra compression. Video
# buffer stays 0 (scrcpy's default; setting it is how people add 50–100ms
# without noticing). Audio buffer is 30ms rather than 0 so Minecraft's SFX
# don't underrun. UHID keyboard/mouse/gamepad so the phone sees real HID, not
# injected SDK events.
#
# No DRI_PRIME. Hyprland is on the iGPU (see home/hyprland/default.nix);
# presenting decoded frames from the dGPU is a PCIe copy. Decode next to the
# compositor.
#
# No --tcpip, no --turn-screen-off. Wi-Fi is a different latency class; turning
# the panel off has been measured to *raise* capture delay (Genymobile/scrcpy
# #4587). Pass those to raw `scrcpy` if you want them.
{
  lib,
  writeShellApplication,
  makeDesktopItem,
  symlinkJoin,
  scrcpy,
  android-tools,
}:

let
  phone-mirror = writeShellApplication {
    name = "phone-mirror";
    runtimeInputs = [
      scrcpy
      android-tools
    ];
    text = ''
      usage() {
        cat <<'EOF'
      phone-mirror — low-latency USB scrcpy for Android games on the desktop

        phone-mirror                 USB mirror, game defaults
        phone-mirror minecraft       start Bedrock (com.mojang.minecraftpe)
        phone-mirror devices         adb devices -l
        phone-mirror encoders        scrcpy --list-encoders
        phone-mirror -- [scrcpy…]    extra flags after the defaults
        phone-mirror -h

      Env (all optional):
        ANDROID_SERIAL / PHONE_SERIAL   pick a device
        PHONE_MIRROR_MAX_SIZE           default 1920
        PHONE_MIRROR_FPS                default 120
        PHONE_MIRROR_BITRATE            default 12M
        PHONE_MIRROR_CODEC              default h264
        PHONE_MIRROR_APP                extra --start-app=

      USB only. `scrcpy --tcpip` if you really want Wi-Fi.
      EOF
      }

      if [ -n "''${PHONE_SERIAL:-}" ] && [ -z "''${ANDROID_SERIAL:-}" ]; then
        export ANDROID_SERIAL="$PHONE_SERIAL"
      fi

      extra_app=""
      extras=()
      case "''${1:-}" in
        -h|--help|help)
          usage
          exit 0
          ;;
        devices)
          exec adb devices -l
          ;;
        encoders)
          exec scrcpy --select-usb --list-encoders
          ;;
        minecraft|mc|bedrock)
          extra_app="com.mojang.minecraftpe"
          shift
          ;;
        --)
          shift
          extras+=("$@")
          set --
          ;;
        -*)
          extras+=("$@")
          set --
          ;;
        "")
          ;;
        *)
          echo "unknown command: $1 (try --help)" >&2
          exit 2
          ;;
      esac

      if [ "$#" -gt 0 ]; then
        if [ "$1" = "--" ]; then
          shift
        fi
        extras+=("$@")
      fi

      export SDL_VIDEODRIVER="''${SDL_VIDEODRIVER:-wayland,x11}"

      args=(
        scrcpy
        --select-usb
        --video-codec="''${PHONE_MIRROR_CODEC:-h264}"
        --video-bit-rate="''${PHONE_MIRROR_BITRATE:-12M}"
        --max-size="''${PHONE_MIRROR_MAX_SIZE:-1920}"
        --max-fps="''${PHONE_MIRROR_FPS:-120}"
        --video-buffer=0
        --audio-buffer=30
        --no-mipmaps
        --stay-awake
        --disable-screensaver
        --keyboard=uhid
        --mouse=uhid
        --gamepad=uhid
        --shortcut-mod=lalt
        --window-title=phone-mirror
      )

      app="''${extra_app:-''${PHONE_MIRROR_APP:-}}"
      if [ -n "$app" ]; then
        args+=(--start-app="$app")
      fi

      exec "''${args[@]}" "''${extras[@]}"
    '';
  };

  desktopMirror = makeDesktopItem {
    name = "phone-mirror";
    desktopName = "Phone Mirror";
    genericName = "Android USB game display";
    comment = "Low-latency scrcpy over USB";
    exec = "${phone-mirror}/bin/phone-mirror";
    icon = "phone";
    categories = [
      "Game"
      "Utility"
    ];
    terminal = false;
  };

  desktopMinecraft = makeDesktopItem {
    name = "phone-mirror-minecraft";
    desktopName = "Minecraft Bedrock (phone)";
    comment = "Start Bedrock on the phone and mirror it over USB";
    exec = "${phone-mirror}/bin/phone-mirror minecraft";
    icon = "minecraft";
    categories = [ "Game" ];
    terminal = false;
  };
in
symlinkJoin {
  name = "android-mirror";
  paths = [
    phone-mirror
    scrcpy
    desktopMirror
    desktopMinecraft
  ];
  meta = {
    description = "Low-latency USB scrcpy wrapper for playing Android games on the desktop";
    homepage = "https://github.com/Genymobile/scrcpy";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "phone-mirror";
  };
}
