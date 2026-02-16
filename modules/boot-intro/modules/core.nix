{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-intro;

  # ════════════════════════════════════════════════════════════════════════════
  # Backward Compatibility Layer
  # Detect old config format and migrate to new structure
  # ════════════════════════════════════════════════════════════════════════════

  # Check for old format (theme + soundFile without source type)
  isOldConfig = cfg?theme && cfg?soundFile && !(cfg?source);

  # Derive source type from old config
  effectiveSource = if isOldConfig then "generate"
                     else if cfg?source then cfg.source
                     else "generate";

  # ════════════════════════════════════════════════════════════════════════════
  # DeMoD Color Palettes — Design ≠ Marketing
  # ════════════════════════════════════════════════════════════════════════════
  demodPalettes = {
    classic = {
      primary = "#00FF88";
      secondary = "#00CC6A";
      accent = "#88FFBB";
      background = "#000000";
      text = "#00FF88";
      waveform = "#00FF88";
    };

    steam = {
      primary = "#66c0f4";
      secondary = "#1b2838";
      accent = "#2a475e";
      background = "#171a21";
      text = "#c7d5e0";
      waveform = "#FB7E14";
    };

    amber = {
      primary = "#FFB000";
      secondary = "#CC8800";
      accent = "#FFCC44";
      background = "#0A0800";
      text = "#FFB000";
      waveform = "#FFB000";
    };

    cyan = {
      primary = "#00FFFF";
      secondary = "#00CCCC";
      accent = "#88FFFF";
      background = "#000808";
      text = "#00FFFF";
      waveform = "#00FFFF";
    };

    magenta = {
      primary = "#FF00FF";
      secondary = "#CC00CC";
      accent = "#FF88FF";
      background = "#080008";
      text = "#FF00FF";
      waveform = "#FF00FF";
    };

    red = {
      primary = "#FF3333";
      secondary = "#CC2222";
      accent = "#FF6666";
      background = "#080000";
      text = "#FF3333";
      waveform = "#FF3333";
    };

    white = {
      primary = "#FFFFFF";
      secondary = "#CCCCCC";
      accent = "#FFFFFF";
      background = "#000000";
      text = "#FFFFFF";
      waveform = "#FFFFFF";
    };

    oligarchy = {
      primary = "#7AA2F7";
      secondary = "#3D59A1";
      accent = "#BB9AF7";
      background = "#1A1B26";
      text = "#C0CAF5";
      waveform = "#7AA2F7";
    };

    archibald = {
      primary = "#A6E3A1";
      secondary = "#94E2D5";
      accent = "#F5C2E7";
      background = "#11111B";
      text = "#CDD6F4";
      waveform = "#A6E3A1";
    };
  };

  # Get effective theme (handle old config)
  effectiveTheme = if cfg?theme then cfg.theme else "classic";
  palette = demodPalettes.${effectiveTheme};

  # ════════════════════════════════════════════════════════════════════════════
  # Video Source Selection
  # ════════════════════════════════════════════════════════════════════════════

  # Parse resolution
  resParts = lib.splitString "x" (cfg.resolution or "1920x1080");
  resWidth = builtins.elemAt resParts 0;
  resHeight = builtins.elemAt resParts 1;

  # ════════════════════════════════════════════════════════════════════════════
  # FFmpeg Rendering Pipeline - Improved with GPU Support
  # ════════════════════════════════════════════════════════════════════════════

  # Quality presets for FFmpeg encoding
  renderQualityPresets = {
    fast = {
      preset = "ultrafast";
      crf = "23";
      audioBitrate = "128k";
      videoBitrate = "2";
      tune = "fastdecode";
    };
    balanced = {
      preset = "medium";
      crf = "20";
      audioBitrate = "192k";
      videoBitrate = "5";
      tune = "film";
    };
    high = {
      preset = "slow";
      crf = "18";
      audioBitrate = "256k";
      videoBitrate = "10";
      tune = "film";
    };
    ultra = {
      preset = "veryslow";
      crf = "16";
      audioBitrate = "320k";
      videoBitrate = "20";
      tune = "film";
    };
  };

  # Get effective quality preset
  effectiveQuality = if cfg?renderQuality then cfg.renderQuality else "balanced";
  qualityPreset = renderQualityPresets.${effectiveQuality};

  # GPU-accelerated encoding support
  # Detect available GPU and set appropriate encoder
  videoEncoder = if cfg?enableGpu && cfg.enableGpu
                 then "h264_nvenc"  # NVIDIA
                 else if cfg?enableAmdGpu && cfg.enableAmdGpu
                 then "h264_vaapi"   # AMD VAAPI
                 else "libx264";

  # Compute encoder options as a string for shell script
  videoBitrateStr = "${qualityPreset.videoBitrate}M";
  encoderOptions = if cfg?enableGpu && cfg.enableGpu
                   then "-c:v h264_nvenc -preset ${qualityPreset.preset} -cq ${qualityPreset.crf} -b:v ${videoBitrateStr}"
                   else if cfg?enableAmdGpu && cfg.enableAmdGpu
                   then "-c:v h264_vaapi -vaapi_device /dev/dri/renderD128 -vf 'format=nv12,hwupload' -cq ${qualityPreset.crf}"
                   else "-c:v libx264 -preset ${qualityPreset.preset} -crf ${qualityPreset.crf}";

  # Get effective settings
  escapeText = text: replaceStrings [ "'" ":" ] [ "\\'" "\\:" ] text;
  effectiveTitle = if cfg?titleText then cfg.titleText else "DeMoD";
  effectiveBottom = if cfg?bottomText then cfg.bottomText else "Design ≠ Marketing";
  escapedTitle = escapeText effectiveTitle;
  escapedBottom = escapeText effectiveBottom;

  # Logo handling
  logoPath = cfg.logoImage or null;
  logoExt = if logoPath != null
            then toLower (last (splitString "." (baseNameOf logoPath)))
            else null;
  isGif = logoExt == "gif";

  hasBackgroundVideo = cfg.backgroundVideo or null != null;
  hasLogo = logoPath != null;

  fadeDurationSecs = toString (cfg.fadeDuration or 1.5);

  # Generate video from audio source (existing + improved)
  generatedVideo = pkgs.runCommand "boot-intro-video-${effectiveTheme}.mp4" {
    nativeBuildInputs = [ pkgs.ffmpeg-full pkgs.fluidsynth pkgs.bc ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  } ''
    echo "═══════════════════════════════════════════════════════════════"
    echo "DeMoD Boot Intro Generator — Theme: ${effectiveTheme}"
    echo "Quality: ${effectiveQuality} | GPU: ${if (cfg.enableGpu or false) then "enabled" else "disabled"}"
    echo "═══════════════════════════════════════════════════════════════"

    # 1. Process Audio
    audioInput="${cfg.soundFile}"
    audioExt="''${audioInput##*.}"
    audioExt="$(echo "$audioExt" | tr '[:upper:]' '[:lower:]')"

    if [[ "$audioExt" == "mid" || "$audioExt" == "midi" ]]; then
      echo "Synthesizing MIDI..."
      fluidsynth -ni "${cfg.soundFont or "${pkgs.soundfont-fluid}/share/soundfonts/FluidR3_GM.sf2"}" "$audioInput" -F audio.wav -r 48000 -g ${toString (cfg.soundGain or 2.0)}
    else
      echo "Converting audio to normalized WAV..."
      ${pkgs.ffmpeg-full}/bin/ffmpeg -y -i "$audioInput" -ar 48000 -ac 2 audio.wav
    fi

    # 2. Calculate Timings
    TOTAL_DURATION=$(${pkgs.ffmpeg-full}/bin/ffprobe -v error -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 audio.wav)

    FADE_START=$(echo "$TOTAL_DURATION - ${fadeDurationSecs}" | ${pkgs.bc}/bin/bc -l)

    if (( $(echo "$FADE_START < 0.5" | ${pkgs.bc}/bin/bc -l) )); then
      FADE_START="0.5"
    fi

    echo "Duration: $TOTAL_DURATION s | Fade at: $FADE_START s"

    # 3. Build filter graph with effects
    SCANLINE_FILTER="geq=lum='lum(X,Y)*(0.92+0.08*sin(Y*3.14159/2))'"

    # GPU encoding options (computed in Nix)
    ENCODER_OPTS="${encoderOptions}"

    ${pkgs.ffmpeg-full}/bin/ffmpeg -y -i audio.wav \
      ${optionalString hasBackgroundVideo "-stream_loop -1 -i ${cfg.backgroundVideo}"} \
      ${optionalString (!hasBackgroundVideo) "-f lavfi -i color=c=${palette.background}:s=${resWidth}x${resHeight}"} \
      ${optionalString hasLogo "${if isGif then "-ignore_loop 0" else ""} -i ${logoPath}"} \
      -filter_complex "
        [1:v]scale=${resWidth}:${resHeight}:force_original_aspect_ratio=increase,crop=${resWidth}:${resHeight},setsar=1[bg];

        [0:a]asplit=2[a_viz][a_out_raw];
        [a_out_raw]afade=t=out:st=$FADE_START:d=${fadeDurationSecs}[a_out];

        [a_viz]showwaves=s=${resWidth}x${resHeight}:mode=cline:colors=${palette.waveform}:scale=cbrt:draw=full[waves];
        [waves]split=2[w1][w2];
        [w2]vflip[w2f];
        [w1][w2f]overlay=0:(main_h-overlay_h)/2[sym];

        [sym]hue=s=1.6[sat];
        [sat]split=2[base][bloom];
        [bloom]gblur=sigma=10[glow];
        [base][glow]blend=all_mode=screen:shortest=1[glowed];

        [glowed]lenscorrection=cx=0.5:cy=0.5:k1=0.1:k2=0.05[curved];
        [curved]$SCANLINE_FILTER[scanned];
        [scanned]vignette=PI/4.5,format=rgba,colorchannelmixer=aa=${toString (cfg.waveformOpacity or 0.75)}[viz];

        [bg][viz]overlay=0:0:shortest=1[composed];

        ${optionalString hasLogo ''
          [2:v]scale=-1:ih*${toString (cfg.logoScale or 0.35)}[logo];
          [composed][logo]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2[with_logo];
        ''}

        [${if hasLogo then "with_logo" else "composed"}]
          drawtext=text='${escapedTitle}':fontfile=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf:fontcolor=${palette.text}:fontsize=h/${toString (cfg.titleSize or 16)}:x=(w-text_w)/2:y=h/${toString (cfg.titleY or 8)}:shadowcolor=black@0.7:shadowx=3:shadowy=3,
          drawtext=text='${escapedBottom}':fontfile=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf:fontcolor=${palette.secondary}:fontsize=h/${toString (cfg.bottomSize or 28)}:x=(w-text_w)/2:y=h-text_h-h/${toString (cfg.bottomY or 10)}:shadowcolor=black@0.7:shadowx=2:shadowy=2
          [texted];

        [texted]fade=t=out:st=$FADE_START:d=${fadeDurationSecs}:color=${palette.background}[v_out]
      " \
      -map "[v_out]" -map "[a_out]" \
      $ENCODER_OPTS \
      -c:a aac -b:a ${qualityPreset.audioBitrate} \
      -shortest \
      $out

    echo "Generated: $out"
  '';

  # Video path based on source type
  finalVideoPath = if effectiveSource == "file" && cfg?videoFile then cfg.videoFile
                   else if effectiveSource == "database" then cfg.databaseVideoPath or "/var/lib/boot-intro/videos/intro.mp4"
                   else generatedVideo;

  # ════════════════════════════════════════════════════════════════════════════
  # Enhanced Audio Detection - Merged from production version
  # ════════════════════════════════════════════════════════════════════════════

  audioDetectionScript = pkgs.writeShellScript "detect-audio-enhanced" ''
    set -euo pipefail

    MAX_RETRIES=${toString (cfg.audioDetection.maxRetries or 5)}
    RETRY_DELAY=${toString (cfg.audioDetection.retryDelay or 0.2)}
    TIMEOUT=${toString (cfg.audioDetection.timeout or 2)}

    log() {
      ${optionalString (cfg.debugAudio or false) "echo \"[audio] $1\" >&2"}
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
    if [ -n "${cfg.audioDevice or ""}" ]; then
      log "Using manual device: ${cfg.audioDevice}"
      if test_device "${cfg.audioDevice}"; then
        echo "${cfg.audioDevice}"
        exit 0
      else
        log "WARNING: Manual device failed validation, falling back to auto-detect"
      fi
    fi

    # Priority-based detection with retry
    for attempt in $(seq 1 $MAX_RETRIES); do
      log "Detection attempt $attempt/$MAX_RETRIES"

      BEST_DEVICE=""
      BEST_PRIORITY=0

      for card in /proc/asound/card*; do
        [ -d "$card" ] || continue
        cardnum=$(basename "$card" | sed 's/card//')
        [ -f "$card/id" ] || continue
        id=$(cat "$card/id")

        priority=0
        DEVICE=""

        # Priority 100: Professional USB/DSP interfaces
        if echo "$id" | grep -qiE "USB|RME|Focusrite|Scarlett|Clarett|Universal|Apollo|MOTU|Behringer|PreSonus|Audient|Antelope|Apogee|SSL|Metric|UAD"; then
          priority=100
          DEVICE="hw:$cardnum,0"
          log "Found pro audio: $id"

        # Priority 75: Analog/PCH
        elif echo "$id" | grep -qiE "Analog|PCH|HDA|Generic"; then
          priority=75
          DEVICE="hw:$cardnum,0"
          log "Found analog: $id"

        # Priority 50: HDMI
        elif echo "$id" | grep -qiE "HDMI|DisplayPort|NVidia|AMD"; then
          for dev_num in 3 7 8 9 10 11; do
            if [ -e "/proc/asound/card$cardnum/pcm''${dev_num}p" ]; then
              test_dev="hw:$cardnum,''${dev_num}"
              if test_device "$test_dev"; then
                priority=50
                DEVICE="$test_dev"
                log "Found active HDMI: $id ($DEVICE)"
                break
              fi
            fi
          done

        # Priority 25: Other
        else
          priority=25
          DEVICE="hw:$cardnum,0"
        fi

        if [ -n "$DEVICE" ] && [ $priority -gt 0 ]; then
          if test_device "$DEVICE"; then
            if [ $priority -gt $BEST_PRIORITY ]; then
              BEST_PRIORITY=$priority
              BEST_DEVICE="$DEVICE"
              log "New best: $DEVICE (priority $priority)"
            fi
          fi
        fi
      done

      if [ -n "$BEST_DEVICE" ]; then
        log "Selected: $BEST_DEVICE"
        echo "$BEST_DEVICE"
        exit 0
      fi

      if [ $attempt -lt $MAX_RETRIES ]; then
        log "No device found, retrying in ''${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
      fi
    done

    # Try fallbacks
    log "WARNING: Detection failed, trying fallbacks"
    for fallback in default hw:0,0 plughw:0,0; do
      log "Trying fallback: $fallback"
      if test_device "$fallback"; then
        log "Fallback successful: $fallback"
        echo "$fallback"
        exit 0
      fi
    done

    log "ERROR: All methods failed, using 'default'"
    echo "default"
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # Main Playback Script
  # ════════════════════════════════════════════════════════════════════════════

  playScript = pkgs.writeShellApplication {
    name = "boot-intro-play";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.ncurses
      pkgs.mpv
      pkgs.alsa-utils
      pkgs.systemd
      pkgs.socat
    ];
    text = ''
      set -euo pipefail

      clear
      tput civis
      trap "tput cnorm" EXIT

      ${if (cfg.startupDelay or 0.1) > 0 then "sleep ${toString cfg.startupDelay}" else ""}

      AUDIO_DEVICE=$(${audioDetectionScript})

      ${optionalString (cfg.debugAudio or false) ''
        echo "Boot Intro Debug: Detected audio device: $AUDIO_DEVICE" >&2
        aplay -l >&2 || true
      ''}

      ${optionalString (cfg.initialVolume != null) ''
        amixer -q sset Master ${toString cfg.initialVolume}% unmute 2>/dev/null || true
      ''}

      MPV_CMD=(
        "mpv"
        "${finalVideoPath}"
        "--no-terminal"
        "--really-quiet"
        "--no-input-default-bindings"
        "--no-osc"
        "--no-osd-bar"
        "--osd-level=0"
        "--audio-device=alsa/$AUDIO_DEVICE"
        "--audio-channels=${cfg.audioChannels or "stereo"}"
        "--volume=${toString (cfg.volume or 100)}"
        "--video-sync=display-resample"
        "--hwdec=auto"
        "--vo=gpu"
        "--profile=fast"
      )

      ${if cfg.fadeOnSystemd or true then ''
        (
          ${if cfg.performanceMode or true then ''
            systemctl is-active multi-user.target --wait >/dev/null 2>&1 && \
            sleep 0.3 && \
            echo 'keypress q' | socat - UNIX-CONNECT:/tmp/mpv-socket 2>/dev/null || true
          '' else ''
            while ! systemctl is-active multi-user.target >/dev/null 2>&1; do
              sleep 0.5
            done
            sleep 0.3
            echo 'keypress q' | socat - UNIX-CONNECT:/tmp/mpv-socket 2>/dev/null || true
          ''}
        ) &

        MPV_CMD+=("--input-ipc-server=/tmp/mpv-socket")
      '' else ""}

      "''${MPV_CMD[@]}" || true

      clear
    '';
  };

in {
  options.services.boot-intro = {
    enable = mkEnableOption "DeMoD boot intro video player";

    # NEW: Source type selection
    source = mkOption {
      type = types.enum [ "generate" "database" "file" ];
      default = "generate";
      description = ''
        Video source type:
        - generate: FFmpeg generation from audio (default, backward compatible)
        - database: StreamDB video storage
        - file: Pre-rendered video file
      '';
    };

    # Backward compatible options
    theme = mkOption {
      type = types.enum (attrNames demodPalettes);
      default = "classic";
      description = "DeMoD color palette for the boot intro.";
    };

    videoFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Pre-rendered video. Use with source = \"file\"";
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
      description = "Background video (loops).";
    };

    waveformOpacity = mkOption {
      type = types.float;
      default = 0.75;
      description = "Audio visualization opacity (0.0-1.0).";
    };

    fadeDuration = mkOption {
      type = types.float;
      default = 1.5;
      description = "Fade-out duration in seconds.";
    };

    titleSize = mkOption {
      type = types.int;
      default = 16;
      description = "Title font divisor (height/N).";
    };

    titleY = mkOption {
      type = types.int;
      default = 8;
      description = "Title Y position divisor.";
    };

    bottomSize = mkOption {
      type = types.int;
      default = 28;
      description = "Bottom text font divisor.";
    };

    bottomY = mkOption {
      type = types.int;
      default = 10;
      description = "Bottom text Y offset divisor.";
    };

    soundFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Audio file (wav/mp3/flac/midi). Required if source = \"generate\".";
    };

    soundGain = mkOption {
      type = types.float;
      default = 2.0;
      description = "MIDI synthesis gain.";
    };

    soundFont = mkOption {
      type = types.path;
      default = "${pkgs.soundfont-fluid}/share/soundfonts/FluidR3_GM.sf2";
      description = "SF2 soundfont for MIDI.";
    };

    # NEW: GPU support
    enableGpu = mkOption {
      type = types.bool;
      default = false;
      description = "Enable NVIDIA GPU acceleration for video encoding.";
    };

    enableAmdGpu = mkOption {
      type = types.bool;
      default = false;
      description = "Enable AMD GPU acceleration (VAAPI) for video encoding.";
    };

    renderQuality = mkOption {
      type = types.enum [ "fast" "balanced" "high" "ultra" ];
      default = "balanced";
      description = "FFmpeg encoding quality preset.";
    };

    # Database options
    databaseVideoPath = mkOption {
      type = types.path;
      default = "/var/lib/boot-intro/videos/intro.mp4";
      description = "Path to video in StreamDB storage.";
    };

    # Service options
    timeout = mkOption {
      type = types.int;
      default = 30;
      description = "Max playback time before service exits.";
    };

    volume = mkOption {
      type = types.int;
      default = 100;
      description = "Playback volume (0-100).";
    };

    audioDevice = mkOption {
      type = types.str;
      default = "";
      description = "Specific ALSA device. Leave empty for auto-detection.";
    };

    audioChannels = mkOption {
      type = types.str;
      default = "stereo";
      description = "Audio channel configuration.";
    };

    initialVolume = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Set ALSA mixer volume before playback (0-100).";
    };

    debugAudio = mkOption {
      type = types.bool;
      default = false;
      description = "Enable audio device detection debugging.";
    };

    audioDetection = mkOption {
      type = types.submodule {
        options = {
          maxRetries = mkOption {
            type = types.int;
            default = 5;
            description = "Maximum detection retry attempts.";
          };
          retryDelay = mkOption {
            type = types.float;
            default = 0.2;
            description = "Delay between retries in seconds.";
          };
          timeout = mkOption {
            type = types.int;
            default = 2;
            description = "Device test timeout in seconds.";
          };
        };
      };
      default = {};
      description = "Audio detection configuration.";
    };

    startupDelay = mkOption {
      type = types.float;
      default = 0.1;
      description = "Delay before starting playback.";
    };

    fadeOnSystemd = mkOption {
      type = types.bool;
      default = true;
      description = "Fade out when multi-user.target is reached.";
    };

    performanceMode = mkOption {
      type = types.bool;
      default = true;
      description = "Use performance-optimized detection and playback.";
    };

    startEarly = mkOption {
      type = types.bool;
      default = false;
      description = "Start immediately after basic systemd initialization.";
    };

    # TUI and API integration
    enableTui = mkOption {
      type = types.bool;
      default = false;
      description = "Enable TUI video manager.";
    };

    enableApi = mkOption {
      type = types.bool;
      default = false;
      description = "Enable REST API server.";
    };

    apiPort = mkOption {
      type = types.port;
      default = 8080;
      description = "API server port.";
    };

    # Read-only outputs
    videoPath = mkOption {
      type = types.path;
      readOnly = true;
      default = finalVideoPath;
      description = "Path to the video in the Nix store.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = effectiveSource != "generate" || cfg.soundFile != null;
        message = "services.boot-intro: soundFile required when source = \"generate\"";
      }
      {
        assertion = effectiveSource != "file" || cfg.videoFile != null;
        message = "services.boot-intro: videoFile required when source = \"file\"";
      }
    ];

    environment.systemPackages = [
      pkgs.mpv
      pkgs.alsa-utils
    ];

    # Symlink video to predictable location
    environment.etc."demod/boot-intro.mp4".source = finalVideoPath;

    systemd.services.boot-intro-player = {
      description = "DeMoD Boot Intro${optionalString (!cfg.performanceMode) " [Compatibility Mode]"}";

      after = if cfg.startEarly
              then [ "systemd-udevd.service" "plymouth-quit-wait.service" ]
              else [ "systemd-user-sessions.service" "plymouth-quit-wait.service" "sound.target" ];

      wants = if cfg.startEarly then [] else [ "sound.target" ];
      before = [ "display-manager.service" ];
      wantedBy = [ "multi-user.target" ];

      conflicts = [ "getty@tty1.service" ];

      restartIfChanged = false;

      serviceConfig = {
        Type = "oneshot";

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

    # TUI service (if enabled)
    systemd.services.boot-intro-tui = mkIf cfg.enableTui {
      description = "DeMoD Boot Intro TUI Manager";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.mpv}/bin/mpv --help";  # Placeholder - TUI package would go here
        Restart = "on-failure";
      };
    };

    # API service (if enabled)
    systemd.services.boot-intro-api = mkIf cfg.enableApi {
      description = "DeMoD Boot Intro Video API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.mpv}/bin/mpv --help";  # Placeholder - API package would go here
        Environment = [
          "PORT=${toString cfg.apiPort}"
          "RUST_LOG=info"
        ];
        Restart = "on-failure";
      };
    };

    services.displayManager.sddm.settings = mkIf config.services.displayManager.sddm.enable {
      General.InputMethod = "";
    };
  };
}
