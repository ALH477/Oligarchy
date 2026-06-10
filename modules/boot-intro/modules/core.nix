{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-intro;

  # ════════════════════════════════════════════════════════════════════════════
  # DeMoD Color Palettes — Design ≠ Marketing
  # ════════════════════════════════════════════════════════════════════════════
  demodPalettes = {
    classic = {
      primary = "#00FF88"; secondary = "#00CC6A"; accent = "#88FFBB";
      background = "#000000"; text = "#00FF88"; waveform = "#00FF88";
    };
    steam = {
      primary = "#66c0f4"; secondary = "#1b2838"; accent = "#2a475e";
      background = "#171a21"; text = "#c7d5e0"; waveform = "#FB7E14";
    };
    amber = {
      primary = "#FFB000"; secondary = "#CC8800"; accent = "#FFCC44";
      background = "#0A0800"; text = "#FFB000"; waveform = "#FFB000";
    };
    cyan = {
      primary = "#00FFFF"; secondary = "#00CCCC"; accent = "#88FFFF";
      background = "#000808"; text = "#00FFFF"; waveform = "#00FFFF";
    };
    magenta = {
      primary = "#FF00FF"; secondary = "#CC00CC"; accent = "#FF88FF";
      background = "#080008"; text = "#FF00FF"; waveform = "#FF00FF";
    };
    red = {
      primary = "#FF3333"; secondary = "#CC2222"; accent = "#FF6666";
      background = "#080000"; text = "#FF3333"; waveform = "#FF3333";
    };
    white = {
      primary = "#FFFFFF"; secondary = "#CCCCCC"; accent = "#FFFFFF";
      background = "#000000"; text = "#FFFFFF"; waveform = "#FFFFFF";
    };
    oligarchy = {
      primary = "#7AA2F7"; secondary = "#3D59A1"; accent = "#BB9AF7";
      background = "#1A1B26"; text = "#C0CAF5"; waveform = "#7AA2F7";
    };
    archibald = {
      primary = "#A6E3A1"; secondary = "#94E2D5"; accent = "#F5C2E7";
      background = "#11111B"; text = "#CDD6F4"; waveform = "#A6E3A1";
    };
  };

  palette = demodPalettes.${cfg.theme};

  # ffmpeg colour fields are reliable as 0xRRGGBB; "#RRGGBB" is not.
  toFF = c: "0x" + removePrefix "#" c;

  # ════════════════════════════════════════════════════════════════════════════
  # Geometry / quality
  # ════════════════════════════════════════════════════════════════════════════
  resParts = splitString "x" cfg.resolution;
  resWidth = elemAt resParts 0;
  resHeight = elemAt resParts 1;
  resHeightInt = toInt resHeight;

  # Software x264 only. Build-time generation runs in the Nix sandbox, which has
  # no GPU device, so hardware encoders cannot apply here.
  renderQualityPresets = {
    fast     = { preset = "ultrafast"; crf = "23"; audioBitrate = "128k"; };
    balanced = { preset = "medium";    crf = "20"; audioBitrate = "192k"; };
    high     = { preset = "slow";      crf = "18"; audioBitrate = "256k"; };
    ultra    = { preset = "veryslow";  crf = "16"; audioBitrate = "320k"; };
  };
  qualityPreset = renderQualityPresets.${cfg.renderQuality};
  encoderOptions =
    "-c:v libx264 -preset ${qualityPreset.preset} -crf ${qualityPreset.crf} -pix_fmt yuv420p";

  # ════════════════════════════════════════════════════════════════════════════
  # Text / logo / effect parameters (all derived in Nix, no shell escaping needed)
  # ════════════════════════════════════════════════════════════════════════════
  # Pass title/subtitle via textfile= so arbitrary characters can't break the
  # filtergraph (the old single-quote/colon escaping was incomplete).
  titleFile  = pkgs.writeText "boot-intro-title.txt"  cfg.titleText;
  bottomFile = pkgs.writeText "boot-intro-bottom.txt" cfg.bottomText;

  dejavuBold    = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";
  dejavuRegular = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";

  logoPath = cfg.logoImage;
  logoExt  = if logoPath != null then toLower (last (splitString "." (baseNameOf logoPath))) else null;
  isGif    = logoExt == "gif";

  hasBackgroundVideo = cfg.backgroundVideo != null;
  hasLogo            = logoPath != null;
  hasScan            = cfg.scanlines;

  fadeDurationSecs = toString cfg.fadeDuration;

  # CRT effect tuning
  bloomSigma = toString (resHeightInt / 160);                                # ~px, scales with height
  caShift    = toString cfg.chromaticAberration;                             # px
  grainAmt   = toString (builtins.floor (cfg.grain * 40.0));                 # noise strength
  scanDark   = toString (builtins.floor (255.0 * (1.0 - cfg.scanlineIntensity)));  # dark-line luma

  # Fixed input order so filtergraph indices are deterministic:
  #   0 audio, 1 background, [2 scanlines], [logo]
  scanIdx = "2";
  logoIdx = toString (if hasScan then 3 else 2);

  # Post-overlay label plumbing (logo + scanlines are optional stages)
  logoStage = optionalString hasLogo ''
    [${logoIdx}:v]scale=-1:ih*${toString cfg.logoScale}[logo];
    [composed][logo]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2[scene];
  '';
  sceneLabel = if hasLogo then "scene" else "composed";

  scanStage = optionalString hasScan ''
    [${scanIdx}:v]scale=${resWidth}:${resHeight}:flags=neighbor,format=rgba[scan];
    [grained][scan]blend=all_mode=multiply:shortest=1[scanned];
  '';
  scannedLabel = if hasScan then "scanned" else "grained";

  textAlpha = "alpha='if(lt(t,1),t,1)'";  # ease text in over the first second

  # ════════════════════════════════════════════════════════════════════════════
  # Video generation (FFmpeg, at build time)
  # ════════════════════════════════════════════════════════════════════════════
  generatedVideo = pkgs.runCommand "boot-intro-video-${cfg.theme}.mp4" {
    nativeBuildInputs = [ pkgs.ffmpeg-full pkgs.fluidsynth pkgs.bc ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  } ''
    echo "═══════════════════════════════════════════════════════════════"
    echo "DeMoD Boot Intro Generator — Theme: ${cfg.theme} | Quality: ${cfg.renderQuality}"
    echo "═══════════════════════════════════════════════════════════════"

    # 1. Process audio
    audioInput="${cfg.soundFile}"
    audioExt="$(echo "''${audioInput##*.}" | tr '[:upper:]' '[:lower:]')"

    if [[ "$audioExt" == "mid" || "$audioExt" == "midi" ]]; then
      echo "Synthesizing MIDI..."
      fluidsynth -ni "${cfg.soundFont}" "$audioInput" -F audio.wav -r 48000 -g ${toString cfg.soundGain}
    else
      echo "Normalizing audio to WAV..."
      ffmpeg -y -i "$audioInput" -ar 48000 -ac 2 audio.wav
    fi

    # 2. Timings
    TOTAL_DURATION=$(ffprobe -v error -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 audio.wav)
    FADE_START=$(echo "$TOTAL_DURATION - ${fadeDurationSecs}" | bc -l)
    if (( $(echo "$FADE_START < 0.5" | bc -l) )); then FADE_START="0.5"; fi
    echo "Duration: $TOTAL_DURATION s | Fade at: $FADE_START s"

    ${optionalString hasScan ''
      # 3. Pre-render a cheap 1px-wide horizontal scanline column, stretched to
      #    full width later with nearest-neighbour (far faster than per-pixel geq
      #    on the whole clip, and crisper).
      ffmpeg -y -f lavfi -i "color=c=white:s=1x${resHeight}" \
        -vf "format=gray,geq=lum='if(eq(mod(Y,2),0),255,${scanDark})'" \
        -frames:v 1 scanlines.png
    ''}

    # 4. Compose
    ffmpeg -y -i audio.wav \
      ${if hasBackgroundVideo
        then "-stream_loop -1 -i ${cfg.backgroundVideo}"
        else "-f lavfi -i color=c=${toFF palette.background}:s=${resWidth}x${resHeight}"} \
      ${optionalString hasScan "-i scanlines.png"} \
      ${optionalString hasLogo "${optionalString isGif "-ignore_loop 0 "}-i ${logoPath}"} \
      -filter_complex "
        [1:v]scale=${resWidth}:${resHeight}:force_original_aspect_ratio=increase,crop=${resWidth}:${resHeight},setsar=1,format=rgba[bg];

        [0:a]asplit=2[a_viz][a_out_raw];
        [a_out_raw]afade=t=out:st=$FADE_START:d=${fadeDurationSecs}[a_out];

        [a_viz]showwaves=s=${resWidth}x${resHeight}:mode=cline:colors=${toFF palette.waveform}:scale=cbrt:draw=full[waves];
        [waves]split=2[w1][w2];
        [w2]vflip[w2f];
        [w1][w2f]overlay=0:(main_h-overlay_h)/2[sym];

        [sym]hue=s=1.6[sat];
        [sat]split=2[base][bloom];
        [bloom]gblur=sigma=${bloomSigma}[glow];
        [base][glow]blend=all_mode=screen:shortest=1[glowed];

        [glowed]rgbashift=rh=-${caShift}:bh=${caShift}[aberr];
        [aberr]format=rgba,colorchannelmixer=aa=${toString cfg.waveformOpacity}[viz];

        [bg][viz]overlay=0:0:shortest=1[composed];
        ${logoStage}
        [${sceneLabel}]noise=alls=${grainAmt}:allf=t[grained];
        ${scanStage}

        [${scannedLabel}]
          drawtext=textfile=${titleFile}:expansion=none:fontfile=${dejavuBold}:fontcolor=${toFF palette.text}:fontsize=h/${toString cfg.titleSize}:x=(w-text_w)/2:y=h/${toString cfg.titleY}:shadowcolor=black@0.7:shadowx=3:shadowy=3:${textAlpha},
          drawtext=textfile=${bottomFile}:expansion=none:fontfile=${dejavuRegular}:fontcolor=${toFF palette.secondary}:fontsize=h/${toString cfg.bottomSize}:x=(w-text_w)/2:y=h-text_h-h/${toString cfg.bottomY}:shadowcolor=black@0.7:shadowx=2:shadowy=2:${textAlpha}
          [texted];

        [texted]lenscorrection=cx=0.5:cy=0.5:k1=0.08:k2=0.025[curved];
        [curved]vignette=PI/4.5[vig];
        [vig]fade=t=out:st=$FADE_START:d=${fadeDurationSecs}:color=${toFF palette.background}[v_out]
      " \
      -map "[v_out]" -map "[a_out]" \
      ${encoderOptions} \
      -c:a aac -b:a ${qualityPreset.audioBitrate} \
      -shortest \
      $out

    echo "Generated: $out"
  '';

  finalVideoPath =
    if cfg.source == "file" then cfg.videoFile
    else generatedVideo;

  # ════════════════════════════════════════════════════════════════════════════
  # Audio device detection (runtime)
  # ════════════════════════════════════════════════════════════════════════════
  audioDetectionScript = pkgs.writeShellScript "detect-audio-enhanced" ''
    set -euo pipefail

    MAX_RETRIES=${toString cfg.audioDetection.maxRetries}
    RETRY_DELAY=${toString cfg.audioDetection.retryDelay}
    TIMEOUT=${toString cfg.audioDetection.timeout}

    log() {
      ${optionalString cfg.debugAudio "echo \"[audio] $1\" >&2"}
    }

    test_device() {
      local device=$1
      if timeout $TIMEOUT ${pkgs.alsa-utils}/bin/aplay -D "$device" \
         --dump-hw-params /dev/zero 2>&1 | grep -q "Hardware PCM"; then
        return 0
      fi
      return 1
    }

    # Manual override (0ms overhead)
    if [ -n "${cfg.audioDevice}" ]; then
      log "Using manual device: ${cfg.audioDevice}"
      if test_device "${cfg.audioDevice}"; then
        echo "${cfg.audioDevice}"; exit 0
      else
        log "WARNING: Manual device failed validation, falling back to auto-detect"
      fi
    fi

    for attempt in $(seq 1 $MAX_RETRIES); do
      log "Detection attempt $attempt/$MAX_RETRIES"
      BEST_DEVICE=""; BEST_PRIORITY=0

      for card in /proc/asound/card*; do
        [ -d "$card" ] || continue
        cardnum=$(basename "$card" | sed 's/card//')
        [ -f "$card/id" ] || continue
        id=$(cat "$card/id")
        priority=0; DEVICE=""

        if echo "$id" | grep -qiE "USB|RME|Focusrite|Scarlett|Clarett|Universal|Apollo|MOTU|Behringer|PreSonus|Audient|Antelope|Apogee|SSL|Metric|UAD"; then
          priority=100; DEVICE="hw:$cardnum,0"; log "Found pro audio: $id"
        elif echo "$id" | grep -qiE "Analog|PCH|HDA|Generic"; then
          priority=75; DEVICE="hw:$cardnum,0"; log "Found analog: $id"
        elif echo "$id" | grep -qiE "HDMI|DisplayPort|NVidia|AMD"; then
          for dev_num in 3 7 8 9 10 11; do
            if [ -e "/proc/asound/card$cardnum/pcm''${dev_num}p" ]; then
              test_dev="hw:$cardnum,''${dev_num}"
              if test_device "$test_dev"; then
                priority=50; DEVICE="$test_dev"; log "Found active HDMI: $id ($DEVICE)"; break
              fi
            fi
          done
        else
          priority=25; DEVICE="hw:$cardnum,0"
        fi

        if [ -n "$DEVICE" ] && [ $priority -gt 0 ]; then
          if test_device "$DEVICE" && [ $priority -gt $BEST_PRIORITY ]; then
            BEST_PRIORITY=$priority; BEST_DEVICE="$DEVICE"; log "New best: $DEVICE ($priority)"
          fi
        fi
      done

      if [ -n "$BEST_DEVICE" ]; then
        log "Selected: $BEST_DEVICE"; echo "$BEST_DEVICE"; exit 0
      fi
      if [ $attempt -lt $MAX_RETRIES ]; then
        log "No device found, retrying in ''${RETRY_DELAY}s..."; sleep $RETRY_DELAY
      fi
    done

    log "WARNING: Detection failed, trying fallbacks"
    for fallback in default hw:0,0 plughw:0,0; do
      if test_device "$fallback"; then log "Fallback: $fallback"; echo "$fallback"; exit 0; fi
    done
    log "ERROR: All methods failed, using 'default'"
    echo "default"
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # Playback (runtime)
  # ════════════════════════════════════════════════════════════════════════════
  playScript = pkgs.writeShellApplication {
    name = "boot-intro-play";
    runtimeInputs = [
      pkgs.coreutils pkgs.ncurses pkgs.mpv pkgs.alsa-utils pkgs.systemd pkgs.socat
    ];
    text = ''
      set -euo pipefail

      SOCK="/run/boot-intro/mpv.sock"
      rm -f "$SOCK"

      clear
      tput civis
      trap 'tput cnorm; rm -f "$SOCK"' EXIT

      ${optionalString (cfg.startupDelay > 0) "sleep ${toString cfg.startupDelay}"}

      AUDIO_DEVICE=$(${audioDetectionScript})

      ${optionalString cfg.debugAudio ''
        echo "Boot Intro Debug: Detected audio device: $AUDIO_DEVICE" >&2
        aplay -l >&2 || true
      ''}

      ${optionalString (cfg.initialVolume != null) ''
        amixer -q sset Master ${toString cfg.initialVolume}% unmute 2>/dev/null || true
      ''}

      MPV_CMD=(
        "mpv"
        "${finalVideoPath}"
        "--no-terminal" "--really-quiet"
        "--no-input-default-bindings" "--no-osc" "--no-osd-bar" "--osd-level=0"
        "--audio-device=alsa/$AUDIO_DEVICE"
        "--audio-channels=${cfg.audioChannels}"
        "--volume=${toString cfg.volume}"
        "--video-sync=display-resample" "--hwdec=auto" "--vo=gpu" "--profile=fast"
      )

      ${optionalString cfg.fadeOnSystemd ''
        (
          # Wait until the graphical stack is up, then ask mpv (via its JSON IPC
          # socket) to quit so the splash hands off cleanly to the DM.
          ${if cfg.performanceMode
            then ''systemctl is-active multi-user.target --wait >/dev/null 2>&1 || true''
            else ''while ! systemctl is-active multi-user.target >/dev/null 2>&1; do sleep 0.5; done''}
          sleep 0.3
          for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
          echo '{ "command": ["quit"] }' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true
        ) &
        MPV_CMD+=("--input-ipc-server=$SOCK")
      ''}

      "''${MPV_CMD[@]}" || true
      clear
    '';
  };

in {
  options.services.boot-intro = {
    enable = mkEnableOption "DeMoD boot intro video player";

    source = mkOption {
      type = types.enum [ "generate" "file" ];
      default = "generate";
      description = ''
        Video source:
        - generate: render with FFmpeg from `soundFile` (default)
        - file: play a pre-rendered `videoFile`
      '';
    };

    theme = mkOption {
      type = types.enum (attrNames demodPalettes);
      default = "classic";
      description = "DeMoD colour palette for the boot intro.";
    };

    videoFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Pre-rendered video. Use with source = \"file\".";
    };

    resolution = mkOption {
      type = types.str;
      default = "1920x1080";
      description = "Output resolution (WxH).";
    };

    titleText = mkOption {
      type = types.str;
      default = "DeMoD";
      description = "Title text at top of screen.";
    };

    bottomText = mkOption {
      type = types.str;
      default = "Design ≠ Marketing";
      description = "Subtitle text at bottom.";
    };

    logoImage = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Center logo (PNG/GIF).";
    };

    logoScale = mkOption {
      type = types.float;
      default = 0.35;
      description = "Logo scale relative to screen height.";
    };

    backgroundVideo = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Background video (loops behind the visualizer).";
    };

    waveformOpacity = mkOption {
      type = types.float;
      default = 0.75;
      description = "Audio-visualizer opacity (0.0-1.0).";
    };

    fadeDuration = mkOption {
      type = types.float;
      default = 1.5;
      description = "Fade-out duration in seconds.";
    };

    titleSize = mkOption { type = types.int; default = 16; description = "Title font divisor (height/N)."; };
    titleY    = mkOption { type = types.int; default = 8;  description = "Title Y position divisor."; };
    bottomSize = mkOption { type = types.int; default = 28; description = "Bottom text font divisor."; };
    bottomY    = mkOption { type = types.int; default = 10; description = "Bottom text Y offset divisor."; };

    soundFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Audio file (wav/mp3/flac/midi). Required when source = \"generate\".";
    };

    soundGain = mkOption { type = types.float; default = 2.0; description = "MIDI synthesis gain."; };

    soundFont = mkOption {
      type = types.path;
      default = "${pkgs.soundfont-fluid}/share/soundfonts/FluidR3_GM.sf2";
      description = "SF2 soundfont for MIDI.";
    };

    renderQuality = mkOption {
      type = types.enum [ "fast" "balanced" "high" "ultra" ];
      default = "balanced";
      description = ''
        x264 encoding quality preset. Higher presets build slower; "fast" is
        recommended while iterating on the look.
      '';
    };

    # ── CRT effect tuning ──────────────────────────────────────────────────────
    scanlines = mkOption {
      type = types.bool;
      default = true;
      description = "Overlay CRT scanlines.";
    };

    scanlineIntensity = mkOption {
      type = types.float;
      default = 0.45;
      description = "Scanline darkness, 0.0 (off) - 1.0 (black lines).";
    };

    chromaticAberration = mkOption {
      type = types.int;
      default = 2;
      description = "CRT colour-fringe shift in pixels (0 disables).";
    };

    grain = mkOption {
      type = types.float;
      default = 0.12;
      description = "Analog film grain amount, 0.0 (off) - 1.0.";
    };

    # ── Service / playback ─────────────────────────────────────────────────────
    timeout       = mkOption { type = types.int; default = 30;  description = "Max playback time before the service exits."; };
    volume        = mkOption { type = types.int; default = 100; description = "Playback volume (0-100)."; };
    audioDevice   = mkOption { type = types.str; default = ""; description = "Specific ALSA device. Empty = auto-detect."; };
    audioChannels = mkOption { type = types.str; default = "stereo"; description = "Audio channel configuration."; };

    initialVolume = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Set ALSA Master volume before playback (0-100).";
    };

    debugAudio = mkOption { type = types.bool; default = false; description = "Enable audio detection debugging."; };

    audioDetection = mkOption {
      type = types.submodule {
        options = {
          maxRetries = mkOption { type = types.int;   default = 5;   description = "Maximum detection retry attempts."; };
          retryDelay = mkOption { type = types.float; default = 0.2; description = "Delay between retries (seconds)."; };
          timeout    = mkOption { type = types.int;   default = 2;   description = "Device test timeout (seconds)."; };
        };
      };
      default = {};
      description = "Audio detection configuration.";
    };

    startupDelay    = mkOption { type = types.float; default = 0.1;  description = "Delay before starting playback."; };
    fadeOnSystemd   = mkOption { type = types.bool;  default = true; description = "Quit when multi-user.target is reached."; };
    performanceMode = mkOption { type = types.bool;  default = true; description = "Use the fast wait/detection path."; };
    startEarly      = mkOption { type = types.bool;  default = false; description = "Start right after basic systemd init."; };

    videoPath = mkOption {
      type = types.path;
      readOnly = true;
      default = finalVideoPath;
      description = "Resolved path to the boot-intro video in the Nix store.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.source != "generate" || cfg.soundFile != null;
        message = "services.boot-intro: soundFile required when source = \"generate\".";
      }
      {
        assertion = cfg.source != "file" || cfg.videoFile != null;
        message = "services.boot-intro: videoFile required when source = \"file\".";
      }
      {
        assertion = builtins.match "[0-9]+x[0-9]+" cfg.resolution != null;
        message = "services.boot-intro: resolution must be WIDTHxHEIGHT (e.g. \"1920x1080\"), got \"${cfg.resolution}\".";
      }
    ];

    environment.systemPackages = [ pkgs.mpv pkgs.alsa-utils ];

    # Predictable path to the rendered video.
    environment.etc."demod/boot-intro.mp4".source = finalVideoPath;

    systemd.services.boot-intro-player = {
      description = "DeMoD Boot Intro${optionalString (!cfg.performanceMode) " [Compatibility Mode]"}";

      after = if cfg.startEarly
              then [ "systemd-udevd.service" "plymouth-quit-wait.service" ]
              else [ "systemd-user-sessions.service" "plymouth-quit-wait.service" "sound.target" ];
      wants = if cfg.startEarly then [ ] else [ "sound.target" ];
      before = [ "display-manager.service" ];
      wantedBy = [ "multi-user.target" ];
      conflicts = [ "getty@tty1.service" ];
      restartIfChanged = false;

      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "boot-intro";  # creates/cleans /run/boot-intro (mpv IPC socket)

        ExecCondition = pkgs.writeShellScript "boot-intro-condition" ''
          if ${pkgs.systemd}/bin/systemctl is-active display-manager.service >/dev/null 2>&1; then
            exit 1
          fi
          exit 0
        '';

        ExecStart = "${playScript}/bin/boot-intro-play";

        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "journal";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;

        TimeoutStartSec = cfg.timeout;
        SuccessExitStatus = [ 0 1 ];
        PrivateTmp = false;
        LimitRTPRIO = 99;
        LimitMEMLOCK = "infinity";
      };
    };

    services.displayManager.sddm.settings = mkIf config.services.displayManager.sddm.enable {
      General.InputMethod = "";
    };
  };
}
