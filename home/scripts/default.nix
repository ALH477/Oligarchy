{ config, pkgs, lib, theme ? {}, features ? {}, ... }:

let
  p = theme;  # Shorthand for palette
  
  # Helper scripts directory
  scriptsDir = ".config/hypr/scripts";
  
in {
  # ════════════════════════════════════════════════════════════════════════════
  # Screenshot Script
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/screenshot.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      OUTPUT="$HOME/Pictures/Screenshots/$(date +%Y%m%d_%H%M%S).png"
      
      case "''${1:-screen}" in
        screen)
          grim "$OUTPUT" && notify-send "Screenshot" "Saved to $OUTPUT"
          ;;
        region)
          grim -g "$(slurp)" "$OUTPUT" && notify-send "Screenshot" "Saved to $OUTPUT"
          ;;
        window)
          grim -g "$(hyprctl -j activewindow | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" "$OUTPUT" && \
            notify-send "Screenshot" "Saved to $OUTPUT"
          ;;
        region-edit)
          grim -g "$(slurp)" - | swappy -f - -o "$OUTPUT"
          ;;
        *)
          echo "Usage: $0 {screen|region|window|region-edit}"
          exit 1
          ;;
      esac
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Volume Control Script
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/volume.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      case "''${1:-}" in
        up)
          wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
          ;;
        down)
          wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
          ;;
        mute)
          wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
          ;;
        *)
          echo "Usage: $0 {up|down|mute}"
          exit 1
          ;;
      esac
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Brightness Control Script
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/brightness.sh" = lib.mkIf (features.hasBacklight or false) {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      case "''${1:-}" in
        up)
          brightnessctl set 5%+
          ;;
        down)
          brightnessctl set 5%-
          ;;
        *)
          echo "Usage: $0 {up|down}"
          exit 1
          ;;
      esac
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Lid Event Handler
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/lid.sh" = lib.mkIf (features.hasBattery or false) {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -u
      
      # Only disable internal display if external monitor is connected
      case "''${1:-}" in
        close)
          # Check if we have more than one monitor before disabling
          if hyprctl monitors -j 2>/dev/null | jq -e 'length > 1' >/dev/null 2>&1; then
            hyprctl keyword monitor "eDP-1,disable" 2>/dev/null || true
          fi
          ;;
        open)
          hyprctl keyword monitor "eDP-1,preferred,auto,1" 2>/dev/null || true
          ;;
        *)
          echo "Usage: $0 {close|open}"
          exit 1
          ;;
      esac
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # System Monitor Script
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/sysinfo.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -u
      
      # Colors (theme-aware)
      CYAN=$'\033[38;2;0;245;212m'
      GREEN=$'\033[38;2;57;255;20m'
      YELLOW=$'\033[38;2;255;232;20m'
      WHITE=$'\033[38;2;255;255;255m'
      DIM=$'\033[38;2;128;128;128m'
      RESET=$'\033[0m'
      
      echo "''${CYAN}╔════════════════════════════════════╗''${RESET}"
      echo "''${CYAN}║''${RESET}  ''${WHITE}System Information''${RESET}                ''${CYAN}║''${RESET}"
      echo "''${CYAN}╚════════════════════════════════════╝''${RESET}"
      echo ""
      
      # CPU
      echo "''${CYAN}┌─ CPU ──────────────────────────────┐''${RESET}"
      echo "  ''${WHITE}$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)''${RESET}"
      echo "  ''${GREEN}$(nproc) cores''${RESET}"
      echo "''${CYAN}└────────────────────────────────────┘''${RESET}"
      echo ""
      
      # Memory
      echo "''${CYAN}┌─ MEMORY ───────────────────────────┐''${RESET}"
      free -h | awk 'NR==2{printf "  ''${WHITE}Total: %s  Used: %s  Free: %s''${RESET}\n", $2,$3,$4}'
      echo "''${CYAN}└────────────────────────────────────┘''${RESET}"
      echo ""
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Theme Switcher Script (runtime theme switching)
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/theme-switch.sh" = {
    executable = true;
    source = ./theme-switch.sh;
  };

  home.file."${scriptsDir}/theme-switcher.sh" = {
    executable = true;
    source = ./theme-switcher.sh;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Keybind Help Script
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/keybind-help.sh" = {
    executable = true;
    source = ./keybind-help.sh;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Caffeine — idle-inhibit toggle (on PATH for the Super+F10 bind + waybar)
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".local/bin/caffeine" = {
    executable = true;
    source = ./caffeine.sh;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Screen Recording Script — gpu-screen-recorder, hardware accelerated
  # (Replaces the broken draft: `-w "$extra_args"` passed an EMPTY QUOTED
  # string as the window argument so recording never started, and save-replay
  # only sent a notification. This is the proven implementation from the
  # monolith: PID+mode tracking, SIGINT graceful stop, real SIGUSR1 replay.)
  # ════════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/record.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail

      DIR="$HOME/Videos/Recordings"
      REPLAY_DIR="$HOME/Videos/Replays"
      PIDFILE="/tmp/gpu-recorder.pid"
      MODEFILE="/tmp/gpu-recorder.mode"
      REPLAY_DURATION=60  # seconds

      mkdir -p "$DIR" "$REPLAY_DIR"

      notify() {
        notify-send -t 3000 -i camera-video "󰑋  Recording" "$1" 2>/dev/null || true
      }

      error_notify() {
        notify-send -t 3000 -u critical "󰑋  Recording" "Failed: $1" 2>/dev/null || true
      }

      is_recording() {
        [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
      }

      get_mode() {
        [[ -f "$MODEFILE" ]] && cat "$MODEFILE" || echo "none"
      }

      stop_recording() {
        if is_recording; then
          local pid=$(cat "$PIDFILE")
          local mode=$(get_mode)

          # SIGINT = graceful stop (gpu-screen-recorder finalizes on SIGINT)
          kill -INT "$pid" 2>/dev/null || true

          for i in {1..30}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
          done

          rm -f "$PIDFILE" "$MODEFILE"

          if [[ "$mode" == "record" ]]; then
            notify "Recording saved to Videos/Recordings"
          fi
          return 0
        fi
        return 1
      }

      start_recording() {
        local output="$DIR/$(date +'%Y-%m-%d_%H%M%S').mp4"

        gpu-screen-recorder \
          -w screen \
          -f 60 \
          -a default_output \
          -c mp4 \
          -q very_high \
          -o "$output" &

        local pid=$!
        echo "$pid" > "$PIDFILE"
        echo "record" > "$MODEFILE"
        notify "Recording started (Super+R to stop)"
      }

      start_region_recording() {
        local selection
        selection=$(slurp -d 2>/dev/null) || { error_notify "Selection cancelled"; exit 0; }

        local output="$DIR/region_$(date +'%Y-%m-%d_%H%M%S').mp4"

        gpu-screen-recorder \
          -w screen \
          -s "$selection" \
          -f 60 \
          -a default_output \
          -c mp4 \
          -q very_high \
          -o "$output" &

        local pid=$!
        echo "$pid" > "$PIDFILE"
        echo "record" > "$MODEFILE"
        notify "Region recording started"
      }

      start_replay_buffer() {
        # Continuously records the last N seconds; SIGUSR1 dumps the buffer.
        gpu-screen-recorder \
          -w screen \
          -f 60 \
          -a default_output \
          -c mp4 \
          -q very_high \
          -r "$REPLAY_DURATION" \
          -o "$REPLAY_DIR" &

        local pid=$!
        echo "$pid" > "$PIDFILE"
        echo "replay" > "$MODEFILE"
        notify "Replay buffer active (''${REPLAY_DURATION}s)"
      }

      save_replay() {
        if is_recording && [[ "$(get_mode)" == "replay" ]]; then
          local pid=$(cat "$PIDFILE")
          kill -USR1 "$pid" 2>/dev/null
          notify "Replay saved to Videos/Replays"
        else
          error_notify "No replay buffer active"
        fi
      }

      # Waybar status output (JSON)
      output_status() {
        if is_recording; then
          local mode=$(get_mode)
          if [[ "$mode" == "record" ]]; then
            echo '{"text": "󰑋 REC", "class": "recording", "tooltip": "Recording active\nClick: Stop | Right: Save Replay"}'
          else
            echo '{"text": "󰃽 REPLAY", "class": "replay", "tooltip": "Replay buffer active ('"$REPLAY_DURATION"'s)\nClick: Stop | Right: Save Replay"}'
          fi
        else
          echo '{"text": "", "class": "idle", "tooltip": "Screen Recording\nClick: Start | Middle: Replay Mode"}'
        fi
      }

      case "''${1:-status}" in
        toggle)
          if is_recording; then
            stop_recording
          else
            start_recording
          fi
          ;;
        region)
          stop_recording 2>/dev/null || true
          start_region_recording
          ;;
        replay-toggle)
          if is_recording; then
            stop_recording
          else
            start_replay_buffer
          fi
          ;;
        save-replay)
          save_replay
          ;;
        stop)
          stop_recording || error_notify "Not recording"
          ;;
        status)
          output_status
          ;;
        *)
          echo "Usage: $0 {toggle|region|replay-toggle|save-replay|stop|status}"
          exit 1
          ;;
      esac
    '';
  };

  # ══════════════════════════════════════════════════════════════════════════
# Gamemode Toggle Script (for gaming performance optimization)
  # ══════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/gamemode.sh" = lib.mkIf (features.enableGaming or false) {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # DeMoD Gamemode Toggle - Optimizes system for gaming
      
      STATEFILE="/tmp/demod-gamemode-active"
      
      notify() {
        notify-send -t 3000 -i applications-games "$1" "$2" 2>/dev/null || true
      }
      
      gamemode_on() {
        if command -v gamemoded &>/dev/null; then
          gamemoded -r 2>/dev/null || true
          gamemoded -d 2>/dev/null &
        fi
        
        hyprctl --batch "\
          keyword animations:enabled 0; \
          keyword decoration:blur:enabled 0; \
          keyword decoration:shadow:enabled 0; \
          keyword decoration:dim_inactive 0; \
          keyword misc:vfr 0; \
          keyword misc:vrr 2; \
          keyword general:gaps_in 0; \
          keyword general:gaps_out 0; \
          keyword general:border_size 1"
        
        touch "$STATEFILE"
        notify "Game Mode ON" "Animations disabled, VRR forced, gaps removed"
      }
      
      gamemode_off() {
        if command -v gamemoded &>/dev/null; then
          gamemoded -r 2>/dev/null || true
        fi
        
        hyprctl --batch "\
          keyword animations:enabled 1; \
          keyword decoration:blur:enabled 1; \
          keyword decoration:shadow:enabled 1; \
          keyword decoration:dim_inactive 1; \
          keyword misc:vfr 1; \
          keyword misc:vrr 1; \
          keyword general:gaps_in 5; \
          keyword general:gaps_out 10; \
          keyword general:border_size 2"
        
        rm -f "$STATEFILE"
        notify "Game Mode OFF" "Desktop effects restored"
      }
      
      gamemode_status() {
        if [[ -f "$STATEFILE" ]]; then
          echo '{"text": "ON", "class": "active", "tooltip": "Game Mode Active\nClick to disable"}'
        else
          echo '{"text": "", "class": "inactive", "tooltip": "Game Mode\nClick to enable"}'
        fi
      }
      
      case "''${1:-toggle}" in
        on)     gamemode_on ;;
        off)    gamemode_off ;;
        toggle)
          if [[ -f "$STATEFILE" ]]; then
            gamemode_off
          else
            gamemode_on
          fi
          ;;
        status) gamemode_status ;;
        *)
          echo "Usage: $0 {on|off|toggle|status}"
          exit 1
          ;;
      esac
    '';
  };

  # ══════════════════════════════════════════════════════════════════════════
  # Toggle Clamshell Mode Script
  # ══════════════════════════════════════════════════════════════════════════
  home.file."${scriptsDir}/toggle_clamshell.sh" = lib.mkIf (features.hasBattery or false) {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -u
      
      if ! hyprctl monitors -j 2>/dev/null | jq -e '.[] | select(.name | test("^(DP|HDMI)"))' >/dev/null 2>&1; then
        notify-send -u warning -i dialog-warning "Clamshell" "No external monitor detected" 2>/dev/null || true
        exit 1
      fi
      
      if hyprctl monitors -j 2>/dev/null | jq -e '.[] | select(.name | test("^eDP"))' >/dev/null 2>&1; then
        hyprctl keyword monitor "eDP-1,disable" 2>/dev/null && \
          notify-send "Clamshell" "Laptop screen disabled" 2>/dev/null || true
      else
        hyprctl keyword monitor "eDP-1,preferred,auto,1" 2>/dev/null && \
          notify-send "Clamshell" "Laptop screen enabled" 2>/dev/null || true
      fi
    '';
  };

  # ══════════════════════════════════════════════════════════════════════════
  # Thermal Status Script
  # ══════════════════════════════════════════════════════════════════════════
  home.file.".local/bin/thermal-status" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      CYAN=$'\033[38;2;0;245;212m'
      VIOLET=$'\033[38;2;139;92;246m'
      GREEN=$'\033[38;2;57;255;20m'
      YELLOW=$'\033[38;2;255;232;20m'
      RED=$'\033[38;2;255;59;92m'
      WHITE=$'\033[38;2;255;255;255m'
      DIM=$'\033[38;2;128;128;128m'
      RESET=$'\033[0m'
      
      echo ""
      echo "''${CYAN}  ╔══════════════════════════════════════╗''${RESET}"
      echo "''${CYAN}  ║''${RESET}  ''${VIOLET}󱃂''${RESET}  ''${WHITE}THERMAL STATUS''${RESET}                  ''${CYAN}║''${RESET}"
      echo "''${CYAN}  ╚══════════════════════════════════════╝''${RESET}"
      echo ""
      
      echo "  ''${CYAN}┌─ TEMPERATURES ─────────────────────┐''${RESET}"
      if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -E "(Tctl|Tdie|Core|edge|junction)" | head -8 | while read line; do
          temp=$(echo "$line" | grep -oP '\+\d+' | head -1 | tr -d '+')
          if [[ -n "$temp" ]]; then
            if [[ $temp -ge 80 ]]; then
              echo "  ''${RED}󰈸''${RESET}  ''${WHITE}$line''${RESET}"
            elif [[ $temp -ge 60 ]]; then
              echo "  ''${YELLOW}󰔏''${RESET}  ''${WHITE}$line''${RESET}"
            else
              echo "  ''${GREEN}󱃃''${RESET}  ''${WHITE}$line''${RESET}"
            fi
          else
            echo "  ''${CYAN}󰔏''${RESET}  ''${WHITE}$line''${RESET}"
          fi
        done
      else
        echo "  ''${DIM}  sensors not found''${RESET}"
      fi
      echo "  ''${CYAN}└────────────────────────────────────┘''${RESET}"
      
      echo ""
      echo "  ''${CYAN}┌─ FANS ─────────────────────────────┐''${RESET}"
      fan_found=false
      for hwmon in /sys/class/hwmon/hwmon*; do
        for fan in "$hwmon"/fan*_input; do
          [[ -f "$fan" ]] || continue
          fan_found=true
          rpm=$(cat "$fan" 2>/dev/null || echo 0)
          name=$(cat "$hwmon/name" 2>/dev/null || echo "Fan")
          if [[ $rpm -gt 0 ]]; then
            echo "  ''${GREEN}󰈐''${RESET}  ''${WHITE}$name:''${RESET} ''${GREEN}$rpm RPM''${RESET}"
          else
            echo "  ''${DIM}󰈐  $name: OFF''${RESET}"
          fi
        done
      done
      [[ "$fan_found" == "false" ]] && echo "  ''${DIM}  No fans detected''${RESET}"
      echo "  ''${CYAN}└────────────────────────────────────┘''${RESET}"
      
      echo ""
      echo "  ''${CYAN}┌─ POWER ────────────────────────────┐''${RESET}"
      if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        echo "  ''${YELLOW}󰓅''${RESET}  ''${WHITE}CPU Governor:''${RESET} ''${GREEN}$gov''${RESET}"
      fi
      if [[ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]]; then
        level=$(cat /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null)
        echo "  ''${YELLOW}󰾆''${RESET}  ''${WHITE}GPU Power:''${RESET} ''${GREEN}$level''${RESET}"
      fi
      echo "  ''${CYAN}└────────────────────────────────────┘''${RESET}"
      echo ""
    '';
  };

  # Create demod config directory and theme.json (runtime theme switching support)
  # (The theme.json entry below creates the parent dir; a bare
  # home.file.".config/demod".recursive without a source is invalid.)
  home.file.".config/demod/theme.json".text = ''
    {
      "name": "${p.name}",
      "bg": "${p.bg}",
      "surface": "${p.surface}",
      "border": "${p.border}",
      "borderFocus": "${p.borderFocus}",
      "accent": "${p.accent}",
      "text": "${p.text}",
      "textDim": "${p.textDim}",
      "success": "${p.success}",
      "warning": "${p.warning}",
      "error": "${p.error}",
      "info": "${p.info}",
      "purple": "${p.purple}",
      "pink": "${p.pink}"
    }
  '';
}
