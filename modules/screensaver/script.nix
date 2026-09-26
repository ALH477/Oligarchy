# The oligarchy-screensaver command: somnium's frames into a fullscreen mpv.
#
# A function, not a module, so that `.#screensaver-tests` builds the SAME
# builder the module uses with the module's defaults, without evaluating a
# whole nixosConfiguration to reach it. See ./README.md.
#
#   somnium -- the Exsecutor engine (github:ALH477/exsecutor, packages.somnium)
#   somnia  -- the effects to cycle through, in order
#   fps     -- the rate mpv plays at, which is also the rate somnium renders
#              at: the pipe's backpressure paces the producer
#   period  -- seconds per effect when there is more than one
#   pixelated -- nearest-neighbour upscaling of the 160x100 frame
{ lib
, writeShellApplication
, mpv
, somnium
, somnia ? [ "plasma" "ignis" "vita" ]
, fps ? 20
, period ? 60
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
        *) echo "oligarchy-screensaver: unknown somnium '$1'" >&2; return 1 ;;
      esac
    }

    # Frames rendered before the first one is shown: the fire starts from a
    # cold hearth and takes about sixty frames to reach its height.
    warmup() {
      case "$1" in
        ignis) echo 60 ;;
        *) echo 0 ;;
      esac
    }

    # One effect alone runs "forever" (0xFFFFFFFF frames, somnium's own
    # spelling of it); several take `period` seconds each, in turn.
    frames=$(( fps * period ))
    if [ "''${#somnia[@]}" -eq 1 ]; then
      frames=4294967295
    fi

    # Every somnium run gets a fresh seed. The engine has no entropy of its
    # own by design -- the seed is the one door, and this is the host
    # choosing to open it.
    #
    # `|| return 0` is load-bearing: when the viewer exits, somnium dies of
    # SIGPIPE at its next write, and without the return this loop would
    # respawn it as fast as fork allows, forever, into a closed pipe.
    # `.#screensaver-tests` would hang on exactly that, which is the point.
    produce() {
      local s
      while :; do
        for s in "''${somnia[@]}"; do
          request "$(somnium_id "$s")" "$(warmup "$s")" "$frames" "$SRANDOM" | somnium || return 0
        done
      done
    }

    viewer=(
      mpv --no-config --no-terminal
      --demuxer=rawvideo
      --demuxer-rawvideo-w=160 --demuxer-rawvideo-h=100
      --demuxer-rawvideo-mp-format=rgb24
      "--demuxer-rawvideo-fps=$fps"
      # mpv inhibits idle while it plays video, by default. hypridle honours
      # inhibitors, so without this the lock and DPMS-off listeners never
      # fire while the screensaver runs -- the screensaver would keep the
      # screen on and the session unlocked indefinitely.
      --stop-screensaver=no
      --fs --no-border --osc=no --osd-level=0 --cursor-autohide=always
      --no-input-default-bindings
      --wayland-app-id=oligarchy-screensaver --title=oligarchy-screensaver
      --cache=no
      ${lib.optionalString pixelated "--scale=nearest"}
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
