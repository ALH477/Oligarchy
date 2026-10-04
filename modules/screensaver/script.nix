# The oligarchy-screensaver command: somnium's frames into a fullscreen mpv.
#
# A function, not a module, so that `.#screensaver-tests` builds the SAME
# builder the module uses with the module's defaults, without evaluating a
# whole nixosConfiguration to reach it. See ./README.md.
#
#   somnium -- the Exsecutor engine (github:ALH477/exsecutor): packages.somnium
#              (the freestanding reference build) or lib.buildExsecutorCProgram
#              (the C backend, buffered; see ./default.nix `backend`). Either
#              ships the 3D model at share/somnium/signaculum_mesh.bin.
#   somnia  -- the effects to cycle through, in order
#   fps     -- the rate mpv plays at, which is also the rate somnium renders
#              at: the pipe's backpressure paces the producer
#   period  -- seconds per effect when there is more than one
#   pixelated -- nearest-neighbour upscaling of the 160x100 frame
{ lib
, writeShellApplication
, mpv
, somnium
, somnia ? [ "pluvia" "titulus" "stellae" "signum" "cuniculus" "abyssus" "plasma" "ignis" "vita" ]
, fps ? 20
, period ? 45
, pixelated ? true
}:

writeShellApplication {
  name = "oligarchy-screensaver";
  runtimeInputs = [ somnium mpv ];
  text = ''
    somnia=(${lib.escapeShellArgs somnia})
    fps=${toString fps}
    period=${toString period}

    usage() {
      cat <<'EOF'
    usage: oligarchy-screensaver                 run fullscreen until the viewer closes
           oligarchy-screensaver --request ID SKIP WRITE SEED
                                                 print somnium's 17-byte request
           oligarchy-screensaver --headless N LOG
                                                 the real pipeline, vo=null, N frames,
                                                 mpv's log to LOG (what the gate runs)
    EOF
    }

    # u32 little-endian. Two printfs because the escape text is built first
    # and expanded by %b, which keeps the variable out of the format string.
    le32() {
      local v=$(( $1 & 0xFFFFFFFF ))
      printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $(( v & 255 )) $(( (v >> 8) & 255 )) $(( (v >> 16) & 255 )) $(( (v >> 24) & 255 )))"
    }

    # The request somnium reads on stdin -- docs/design/somnium.md section 3
    # in the exsecutor repo: "SOM1", the effect id, frames to skip, frames to
    # write, the seed.
    request() {
      printf 'SOM1'
      printf '%b' "\\x$(printf '%02x' $(( $1 & 255 )))"
      le32 "$2"
      le32 "$3"
      le32 "$4"
    }

    somnium_id() {
      case "$1" in
        plasma) echo 0 ;;
        ignis) echo 1 ;;
        vita) echo 2 ;;
        pluvia) echo 3 ;;
        stellae) echo 4 ;;
        cuniculus) echo 5 ;;
        abyssus) echo 6 ;;
        titulus) echo 7 ;;
        signum) echo 8 ;;
        fulmen) echo 9 ;;
        cruor) echo 10 ;;
        *) echo "oligarchy-screensaver: unknown somnium '$1'" >&2; return 1 ;;
      esac
    }

    # Frames rendered before the first one is shown: the fire starts from a
    # cold hearth and takes about sixty frames to reach its height; the
    # starfield and the logo's sky need about thirty to fill.
    warmup() {
      case "$1" in
        ignis) echo 60 ;;
        stellae | signum) echo 30 ;;
        *) echo 0 ;;
      esac
    }

    # The 3D engine's model, shipped beside the engine; somnium 8 reads it
    # straight after its request.
    model=${somnium}/share/somnium/signaculum_mesh.bin

    # One effect alone runs "forever" (0xFFFFFFFF frames, somnium's own
    # spelling of it); several take `period` seconds each, in turn -- except
    # the title card, which always plays its one 400-frame cycle (rain into
    # OLIGARCHY, the two inscriptions, the scatter), and the logo, which
    # always makes two full turns (256 frames each).
    frames=$(( fps * period ))
    frames_for() {
      if [ "''${#somnia[@]}" -eq 1 ]; then
        echo 4294967295
        return
      fi
      case "$1" in
        titulus) echo 400 ;;
        signum) echo 512 ;;
        *) echo "$frames" ;;
      esac
    }

    # Every somnium run gets a fresh seed. The engine has no entropy of its
    # own by design -- the seed is the one door, and this is the host
    # choosing to open it.
    #
    # `|| return 0` is load-bearing: when the viewer exits, somnium dies of
    # SIGPIPE at its next write, and without the return this loop would
    # respawn it as fast as fork allows, forever, into a closed pipe.
    # `.#screensaver-tests` would hang on exactly that, which is the point.
    run_one() {
      local s=$1 id
      id=$(somnium_id "$s")
      if [ "$id" -eq 8 ]; then
        { request "$id" "$(warmup "$s")" "$(frames_for "$s")" "$SRANDOM"; cat "$model"; } | somnium
      else
        request "$id" "$(warmup "$s")" "$(frames_for "$s")" "$SRANDOM" | somnium
      fi
    }

    produce() {
      local s
      while :; do
        for s in "''${somnia[@]}"; do
          run_one "$s" || return 0
        done
      done
    }

    viewer=(
      mpv --no-config --no-terminal
      --demuxer=rawvideo
      --demuxer-rawvideo-w=160 --demuxer-rawvideo-h=100
      --demuxer-rawvideo-mp-format=rgb24
      --demuxer-rawvideo-size=48000
      "--demuxer-rawvideo-fps=$fps"
      # mpv inhibits idle while it plays video, by default. hypridle honours
      # inhibitors, so without this the lock and DPMS-off listeners never
      # fire while the screensaver runs -- the screensaver would keep the
      # screen on and the session unlocked indefinitely.
      --stop-screensaver=no
      # Presentation: do not use mpv's default gpu-next. That VO speaks
      # Vulkan and can pick the dGPU even when DRI_PRIME is unset, which on
      # this machine is a cross-device dmabuf import (flicker). --vo=gpu +
      # --gpu-api=opengl is the path boot-intro already pins, honours the
      # unit's UnsetEnvironment=DRI_PRIME, and scales in the client so
      # Hyprland is not asked to scan out a 160x100 buffer. display-resample
      # duplicates 20 fps onto the 165 Hz BOE panel; without it VFR-class
      # flicker (stale wallpaper through the window) is the reported glitch.
      # --hwdec=no: this is raw rgb24, not a codec.
      --vo=gpu --gpu-api=opengl --gpu-context=wayland --hwdec=no
      --video-sync=display-resample
      --ao=null
      --fs --no-border --osc=no --osd-level=0 --cursor-autohide=always
      --no-input-default-bindings
      --wayland-app-id=oligarchy-screensaver --title=oligarchy-screensaver
      --cache=no
      --keepaspect=no
      ${lib.optionalString pixelated "--scale=nearest --cscale=nearest --dscale=nearest"}
    )

    case "''${1:-}" in
      "")
        produce | "''${viewer[@]}" -
        ;;
      --request)
        [ "$#" -eq 5 ] || { usage >&2; exit 2; }
        request "$2" "$3" "$4" "$5"
        ;;
      --headless)
        [ "$#" -eq 3 ] || { usage >&2; exit 2; }
        produce | "''${viewer[@]}" --vo=null --ao=null "--frames=$2" "--log-file=$3" -
        ;;
      -h | --help)
        usage
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  '';
}
