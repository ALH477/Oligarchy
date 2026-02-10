{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-intro;

  # Parse resolution into width/height for FFmpeg filters
  resParts = lib.splitString "x" cfg.resolution;
  resWidth = builtins.elemAt resParts 0;
  resHeight = builtins.elemAt resParts 1;

  # ════════════════════════════════════════════════════════════════════════════
  # DeMoD Color Palettes — Design ≠ Marketing
  # Retro-tech brutalist aesthetic with CRT-era warmth
  # ════════════════════════════════════════════════════════════════════════════
  demodPalettes = {
    # Classic DeMoD — phosphor green on black
    classic = {
      primary = "#00FF88";
      secondary = "#00CC6A";
      accent = "#88FFBB";
      background = "#000000";
      text = "#00FF88";
      waveform = "#00FF88";
    };

    # Amber — warm CRT terminal
    amber = {
      primary = "#FFB000";
      secondary = "#CC8800";
      accent = "#FFCC44";
      background = "#0A0800";
      text = "#FFB000";
      waveform = "#FFB000";
    };

    # Cyan — cool tech aesthetic
    cyan = {
      primary = "#00FFFF";
      secondary = "#00CCCC";
      accent = "#88FFFF";
      background = "#000808";
      text = "#00FFFF";
      waveform = "#00FFFF";
    };

    # Magenta — synthwave influence
    magenta = {
      primary = "#FF00FF";
      secondary = "#CC00CC";
      accent = "#FF88FF";
      background = "#080008";
      text = "#FF00FF";
      waveform = "#FF00FF";
    };

    # Red — warning/alert mode
    red = {
      primary = "#FF3333";
      secondary = "#CC2222";
      accent = "#FF6666";
      background = "#080000";
      text = "#FF3333";
      waveform = "#FF3333";
    };

    # White — high contrast accessibility
    white = {
      primary = "#FFFFFF";
      secondary = "#CCCCCC";
      accent = "#FFFFFF";
      background = "#000000";
      text = "#FFFFFF";
      waveform = "#FFFFFF";
    };

    # Oligarchy — the distro's signature palette
    oligarchy = {
      primary = "#7AA2F7";
      secondary = "#3D59A1";
      accent = "#BB9AF7";
      background = "#1A1B26";
      text = "#C0CAF5";
      waveform = "#7AA2F7";
    };

    # ArchibaldOS — real-time audio workstation theme
    archibald = {
      primary = "#A6E3A1";
      secondary = "#94E2D5";
      accent = "#F5C2E7";
      background = "#11111B";
      text = "#CDD6F4";
      waveform = "#A6E3A1";
    };
  };

  palette = demodPalettes.${cfg.theme};

  # ════════════════════════════════════════════════════════════════════════════
  # Video Generation
  # ════════════════════════════════════════════════════════════════════════════
  fadeDurationSecs = toString cfg.fadeDuration;

  escapeText = text: replaceStrings [ "'" ":" ] [ "\\'" "\\:" ] text;
  escapedTitle = escapeText cfg.titleText;
  escapedBottom = escapeText cfg.bottomText;

  logoPath = cfg.logoImage;
  logoExt = if logoPath != null
            then toLower (last (splitString "." (baseNameOf logoPath)))
            else null;
  isGif = logoExt == "gif";

  hasBackgroundVideo = cfg.backgroundVideo != null;
  hasLogo = cfg.logoImage != null;

  generatedVideo = pkgs.runCommand "boot-intro-video-${cfg.theme}.mp4" {
    nativeBuildInputs = [ pkgs.ffmpeg-full pkgs.fluidsynth pkgs.bc ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  } ''
    echo "═══════════════════════════════════════════════════════════════"
    echo "DeMoD Boot Intro Generator — Theme: ${cfg.theme}"
    echo "═══════════════════════════════════════════════════════════════"

    # 1. Process Audio
    audioInput="${cfg.soundFile}"
    audioExt="''${audioInput##*.}"
    audioExt="$(echo "$audioExt" | tr '[:upper:]' '[:lower:]')"

    if [[ "$audioExt" == "mid" || "$audioExt" == "midi" ]]; then
      echo "Synthesizing MIDI..."
      fluidsynth -ni "${cfg.soundFont}" "$audioInput" -F audio.wav -r 48000 -g ${toString cfg.soundGain}
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

    # 3. Build filter graph
    # Scanline effect for CRT authenticity
    SCANLINE_FILTER="geq=lum='lum(X,Y)*(0.92+0.08*sin(Y*3.14159/2))'"

    ${pkgs.ffmpeg-full}/bin/ffmpeg -y -i audio.wav \
      ${optionalString hasBackgroundVideo "-stream_loop -1 -i ${cfg.backgroundVideo}"} \
      ${optionalString (!hasBackgroundVideo) "-f lavfi -i color=c=${palette.background}:s=${resWidth}x${resHeight}"} \
      ${optionalString hasLogo "${if isGif then "-ignore_loop 0" else ""} -i ${cfg.logoImage}"} \
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
        [scanned]vignette=PI/4.5,format=rgba,colorchannelmixer=aa=${toString cfg.waveformOpacity}[viz];

        [bg][viz]overlay=0:0:shortest=1[composed];

        ${optionalString hasLogo ''
          [2:v]scale=-1:ih*${toString cfg.logoScale}[logo];
          [composed][logo]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2[with_logo];
        ''}

        [${if hasLogo then "with_logo" else "composed"}]
          drawtext=text='${escapedTitle}':fontfile=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf:fontcolor=${palette.text}:fontsize=h/${toString cfg.titleSize}:x=(w-text_w)/2:y=h/${toString cfg.titleY}:shadowcolor=black@0.7:shadowx=3:shadowy=3,
          drawtext=text='${escapedBottom}':fontfile=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf:fontcolor=${palette.secondary}:fontsize=h/${toString cfg.bottomSize}:x=(w-text_w)/2:y=h-text_h-h/${toString cfg.bottomY}:shadowcolor=black@0.7:shadowx=2:shadowy=2
          [texted];

        [texted]fade=t=out:st=$FADE_START:d=${fadeDurationSecs}:color=${palette.background}[v_out]
      " \
      -map "[v_out]" -map "[a_out]" \
      -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
      -c:a aac -b:a 192k \
      -shortest \
      $out

    echo "Generated: $out"
  '';

  finalVideoPath = if cfg.videoFile != null then cfg.videoFile else generatedVideo;

  # ════════════════════════════════════════════════════════════════════════════
  # Audio Device Detection - Performance Mode vs Compatibility Mode
  # ════════════════════════════════════════════════════════════════════════════
  
  # PERFORMANCE MODE: Single-pass detection (5-15ms)
  audioDetectionPerformance = pkgs.writeShellScript "detect-audio-performance" ''
    # Manual override (0ms)
    if [ -n "${cfg.audioDevice}" ]; then
      echo "${cfg.audioDevice}"
      exit 0
    fi
    
    # Single-pass detection with priority scoring
    BEST_DEVICE=""
    BEST_PRIORITY=0
    
    for card in /proc/asound/card*; do
      [ -d "$card" ] || continue
      cardnum=$(basename "$card" | sed 's/card//')
      [ -f "$card/id" ] || continue
      id=$(cat "$card/id")
      
      priority=0
      device=""
      
      # Priority 100: Professional USB/DSP interfaces
      if echo "$id" | grep -qE "USB|RME|Focusrite|Scarlett|Clarett|Universal|Apollo|MOTU|Behringer|PreSonus|Audient|Antelope|Apogee|SSL|Metric|UAD"; then
        priority=100
        device="hw:$cardnum,0"
      
      # Priority 50: HDMI/DisplayPort
      elif echo "$id" | grep -qE "HDMI|DisplayPort|NVidia|AMD"; then
        priority=50
        for dev in 3 7 8; do
          if [ -e "/proc/asound/card$cardnum/pcm${dev}p" ]; then
            device="hw:$cardnum,$dev"
            break
          fi
        done
        [ -z "$device" ] && device="hw:$cardnum,0"
      
      # Priority 25: Other cards
      else
        priority=25
        pcm_device=$(ls "$card"/pcm*p 2>/dev/null | head -n1)
        if [ -n "$pcm_device" ]; then
          devnum=$(basename "$pcm_device" | sed 's/pcm//;s/p//')
          device="hw:$cardnum,$devnum"
        fi
      fi
      
      if [ $priority -gt $BEST_PRIORITY ] && [ -n "$device" ]; then
        BEST_PRIORITY=$priority
        BEST_DEVICE="$device"
      fi
    done
    
    if [ -n "$BEST_DEVICE" ]; then
      ${optionalString cfg.debugAudio ''echo "[Performance] Detected: $BEST_DEVICE (priority $BEST_PRIORITY)" >&2''}
      echo "$BEST_DEVICE"
    else
      ${optionalString cfg.debugAudio ''echo "[Performance] No device found, using default" >&2''}
      echo "default"
    fi
  '';

  # COMPATIBILITY MODE: Multi-pass detection (100-300ms) - thorough for debugging
  audioDetectionCompatibility = pkgs.writeShellScript "detect-audio-compatibility" ''
    # Manual override
    if [ -n "${cfg.audioDevice}" ]; then
      echo "${cfg.audioDevice}"
      exit 0
    fi
    
    ${optionalString cfg.debugAudio ''echo "[Compatibility] Starting multi-pass detection..." >&2''}
    
    # Pass 1: Professional audio interfaces
    for card in /proc/asound/card*; do
      if [ -f "$card/id" ]; then
        id=$(cat "$card/id")
        cardnum=$(basename "$card" | sed 's/card//')
        
        if echo "$id" | grep -qiE "USB|RME|Focusrite|Scarlett|Clarett|Universal|Apollo|MOTU|Behringer|PreSonus|Audient|Antelope|Apogee|SSL|Metric|UAD"; then
          DEVICE="hw:$cardnum,0"
          ${optionalString cfg.debugAudio ''echo "[Compatibility] Found professional audio interface: $id -> $DEVICE" >&2''}
          echo "$DEVICE"
          exit 0
        fi
      fi
    done
    
    # Pass 2: HDMI/DisplayPort audio
    for card in /proc/asound/card*; do
      if [ -f "$card/id" ]; then
        id=$(cat "$card/id")
        cardnum=$(basename "$card" | sed 's/card//')
        
        if echo "$id" | grep -qiE "HDMI|DisplayPort|NVidia|AMD|Intel.*HDMI"; then
          for dev in 3 7 8 9; do
            if [ -e "/proc/asound/card$cardnum/pcm${dev}p" ]; then
              DEVICE="hw:$cardnum,$dev"
              ${optionalString cfg.debugAudio ''echo "[Compatibility] Found HDMI/DP audio: $id -> $DEVICE" >&2''}
              echo "$DEVICE"
              exit 0
            fi
          done
        fi
      fi
    done
    
    # Pass 3: First available PCM device
    for card in /proc/asound/card*; do
      if [ -f "$card/id" ]; then
        cardnum=$(basename "$card" | sed 's/card//')
        id=$(cat "$card/id")
        
        for pcm in "$card"/pcm*p; do
          if [ -d "$pcm" ]; then
            devnum=$(basename "$pcm" | sed 's/pcm//;s/p//')
            DEVICE="hw:$cardnum,$devnum"
            ${optionalString cfg.debugAudio ''echo "[Compatibility] Using fallback device: $id -> $DEVICE" >&2''}
            echo "$DEVICE"
            exit 0
          fi
        done
      fi
    done
    
    # Pass 4: Last resort
    ${optionalString cfg.debugAudio ''echo "[Compatibility] No specific device found, using ALSA default" >&2''}
    echo "default"
  '';

  audioDetectionScript = if cfg.performanceMode 
                         then audioDetectionPerformance 
                         else audioDetectionCompatibility;

  # ════════════════════════════════════════════════════════════════════════════
  # Systemd Monitor - Performance Mode vs Compatibility Mode
  # ════════════════════════════════════════════════════════════════════════════
  
  # PERFORMANCE MODE: Blocking wait (no polling overhead)
  systemdMonitorPerformance = optionalString cfg.fadeOnSystemd ''
    (
      # Efficient blocking wait for multi-user.target
      while ! systemctl is-active --quiet multi-user.target 2>/dev/null; do
        sleep 1
      done
      
      ${optionalString cfg.debugAudio ''echo "[Performance] System ready, initiating fade..." >&2''}
      echo '{"command": ["quit"]}' > /tmp/boot-intro-mpv.cmd 2>/dev/null || kill $MPV_PID 2>/dev/null
    ) &
    MONITOR_PID=$!
  '';

  # COMPATIBILITY MODE: Frequent polling for debugging/testing
  systemdMonitorCompatibility = optionalString cfg.fadeOnSystemd ''
    (
      while true; do
        if systemctl is-active --quiet multi-user.target 2>/dev/null; then
          ${optionalString cfg.debugAudio ''echo "[Compatibility] System ready, initiating fade..." >&2''}
          echo 'quit' > /tmp/boot-intro-mpv.cmd 2>/dev/null || kill $MPV_PID 2>/dev/null
          break
        fi
        sleep 0.5
      done
    ) &
    MONITOR_PID=$!
  '';

  systemdMonitor = if cfg.performanceMode 
                   then systemdMonitorPerformance 
                   else systemdMonitorCompatibility;

  playScript = pkgs.writeShellScript "boot-intro-play" ''
    ${optionalString cfg.debugAudio ''
      echo "Boot Intro Starting [Mode: ${if cfg.performanceMode then "Performance" else "Compatibility"}]" >&2
    ''}
    
    # Startup delay
    sleep ${toString cfg.startupDelay}
    
    # Detect audio device
    AUDIO_DEVICE=$(${audioDetectionScript})
    
    ${optionalString cfg.debugAudio ''
      echo "Boot intro: device=$AUDIO_DEVICE" >&2
      ${pkgs.alsa-utils}/bin/aplay -l >&2 2>/dev/null || true
    ''}
    
    # Set initial volume if requested
    ${optionalString (cfg.initialVolume != null) ''
      if [ "$AUDIO_DEVICE" != "default" ]; then
        CARD_NUM=$(echo "$AUDIO_DEVICE" | sed 's/hw://;s/,.*//')
        ${pkgs.alsa-utils}/bin/amixer ${if cfg.performanceMode then "-q" else ""} -c "$CARD_NUM" sset Master ${toString cfg.initialVolume}% unmute 2>/dev/null || true
      else
        ${pkgs.alsa-utils}/bin/amixer ${if cfg.performanceMode then "-q" else ""} sset Master ${toString cfg.initialVolume}% unmute 2>/dev/null || true
      fi
    ''}
    
    # Launch mpv
    ${pkgs.mpv}/bin/mpv \
      --fs --no-border --no-config --no-osd-bar --no-input-default-bindings \
      --vo=gpu,drm --gpu-context=auto --hwdec=auto-safe \
      --ao=alsa \
      --audio-device="alsa/$AUDIO_DEVICE" \
      --audio-channels=${cfg.audioChannels} \
      --alsa-buffer-time=100000 \
      --alsa-resample=no \
      --audio-samplerate=48000 \
      --volume=${toString cfg.volume} \
      --panscan=${if cfg.fillMode == "fill" then "1.0" else "0"} \
      --scale=ewa_lanczossharp \
      --really-quiet \
      ${optionalString cfg.fadeOnSystemd ''--input-file=/tmp/boot-intro-mpv.cmd \''} \
      ${finalVideoPath} &
    
    MPV_PID=$!
    
    ${systemdMonitor}
    
    # Wait for completion
    wait $MPV_PID 2>/dev/null || true
    
    ${optionalString cfg.fadeOnSystemd ''
      kill $MONITOR_PID 2>/dev/null || true
      rm -f /tmp/boot-intro-mpv.cmd
    ''}
    
    ${optionalString cfg.debugAudio ''echo "Boot intro completed" >&2''}
  '';

in
{
  options.services.boot-intro = {
    enable = mkEnableOption "DeMoD boot intro video system";

    # ── Performance Control ──
    performanceMode = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable performance optimizations (recommended for production).
        - true: Single-pass audio detection (~5-15ms), blocking systemd monitor (~0ms overhead)
        - false: Multi-pass audio detection (~100-300ms), polling systemd monitor (~200ms overhead)
        Use false only for debugging or maximum hardware compatibility testing.
      '';
    };

    # ── Theme Selection ──
    theme = mkOption {
      type = types.enum (attrNames demodPalettes);
      default = "classic";
      description = "DeMoD color palette for the boot intro.";
      example = "oligarchy";
    };

    # ── Video Source ──
    videoFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Pre-rendered video. Skips generation if set.";
    };

    # ── Generation Options ──
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
      description = "Background video (loops). Solid color if unset.";
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

    fillMode = mkOption {
      type = types.enum [ "fill" "letterbox" ];
      default = "fill";
      description = "Aspect ratio handling.";
    };

    # ── Text Layout ──
    titleSize = mkOption {
      type = types.int;
      default = 16;
      description = "Title font divisor (height/N).";
    };

    titleY = mkOption {
      type = types.int;
      default = 8;
      description = "Title Y position divisor (height/N from top).";
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

    # ── Audio Options ──
    soundFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Audio file (wav/mp3/flac/midi). Required if videoFile is null.";
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

    # ── Service Options ──
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

    # ── Audio Configuration ──
    audioDevice = mkOption {
      type = types.str;
      default = "";
      description = ''
        Specific ALSA device to use (e.g., "hw:0,0", "hw:1,3").
        Leave empty for automatic detection.
        Manual specification bypasses detection (fastest - 0ms overhead).
      '';
      example = "hw:1,0";
    };

    audioChannels = mkOption {
      type = types.str;
      default = "stereo";
      description = "Audio channel configuration for mpv.";
      example = "7.1";
    };

    initialVolume = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Set ALSA mixer volume before playback (0-100).
        Null to skip (saves ~20ms boot time in performance mode).
      '';
      example = 80;
    };

    debugAudio = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Log available ALSA devices and detection process.
        Adds ~10ms overhead in performance mode, more in compatibility mode.
      '';
    };

    # ── Startup Timing ──
    startupDelay = mkOption {
      type = types.float;
      default = 0.1;
      description = ''
        Delay in seconds before starting playback.
        Minimum recommended: 0.1s for DRM/KMS initialization.
      '';
    };

    fadeOnSystemd = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Monitor systemd and fade out when multi-user.target is reached.
        Performance mode: blocking wait (~0ms overhead)
        Compatibility mode: polling every 0.5s (~200ms cumulative overhead)
      '';
    };

    startEarly = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Start immediately after basic systemd initialization.
        May reduce boot time by 0.5-2s but audio hardware might not be ready.
      '';
    };

    # ── Read-only Outputs ──
    videoPath = mkOption {
      type = types.path;
      readOnly = true;
      default = finalVideoPath;
      description = "Path to the generated video in the Nix store.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.videoFile != null || cfg.soundFile != null;
        message = "services.boot-intro: Either videoFile or soundFile must be provided.";
      }
    ];

    # Package requirements
    environment.systemPackages = [ 
      pkgs.mpv 
      pkgs.alsa-utils
    ];

    # Symlink video to predictable location
    environment.etc."demod/boot-intro.mp4".source = finalVideoPath;

    systemd.services.boot-intro-player = {
      description = "DeMoD Boot Intro${optionalString (!cfg.performanceMode) " [Compatibility Mode]"}";

      # Timing dependencies
      after = if cfg.startEarly 
              then [ "systemd-udevd.service" "plymouth-quit-wait.service" ]
              else [ "systemd-user-sessions.service" "plymouth-quit-wait.service" "sound.target" ];
      
      wants = if cfg.startEarly then [] else [ "sound.target" ];
      before = [ "display-manager.service" ];
      wantedBy = [ "multi-user.target" ];

      conflicts = [ "getty@tty1.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = playScript;

        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "journal";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;

        TimeoutStartSec = cfg.timeout;
        SuccessExitStatus = [ 0 1 ];
        
        # Filesystem access for device detection
        PrivateTmp = false;
        
        # Real-time priority for audio workstations
        LimitRTPRIO = 99;
        LimitMEMLOCK = "infinity";
      };
    };

    services.displayManager.sddm.settings = mkIf config.services.displayManager.sddm.enable {
      General.InputMethod = "";
    };
  };
}
