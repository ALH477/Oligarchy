{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.oligarchy.blipply;
  
  # Get OpenClaw configuration
  openclawCfg = config.services.openclaw-agent;
  openclawUser = openclawCfg.user;
  openclawHome = openclawCfg.homeDirectory;
  
  # Oligarchy DeMoD color palette
  oligarchyColors = {
    primary = "#00D4AA";      # DeMoD Cyan (online/active)
    alert = "#FF6B6B";        # Alert Red (offline/error)
    warning = "#FFE66D";      # Warning Yellow
    background = "#1A1A2E";   # Dark background
    surface = "#16213E";      # Surface color
    text = "#EAEAEA";         # Text color
  };
  
  # Generate blipply config from Oligarchy settings
  # Uses OpenClaw gateway for AI with plugin context
  blipplyConfig = {
    general = {
      # Use OpenClaw gateway instead of direct Ollama
      # This gives Blipply access to plugins (summarize, oracle, peekaboo, etc.)
      openclaw_url = "http://127.0.0.1:8080";  # OpenClaw gateway endpoint
      openclaw_token = openclawCfg.gatewayToken;
      ollama_url = cfg.ai.ollamaUrl;  # Fallback if OpenClaw unavailable
      hotkey = cfg.hotkeys.toggle;
      first_run_complete = false;  # Will run setup on first launch
      active_profile = cfg.profiles.active;
    };
    
    audio = {
      stt_model = cfg.voice.sttModel;
      vad_enabled = cfg.voice.vadEnabled;
      vad_aggressiveness = cfg.voice.vadAggressiveness;
      sample_rate = cfg.voice.sampleRate;
      push_to_talk = cfg.hotkeys.pushToTalk != null;
      silence_duration_ms = cfg.voice.silenceDurationMs;
    };
    
    pipewire = {
      input_device = "auto";
      output_device = "auto";
      buffer_size = 480;
    };
    
    profiles = {
      default = {
        name = cfg.profiles.default.name;
        model = cfg.ai.model;
        personality = cfg.profiles.default.personality;
        avatar_path = cfg.theme.avatar;
        avatar_size_px = cfg.theme.avatarSize;
        voice_model = cfg.voice.model;
        tts_speed = cfg.voice.ttsSpeed;
        tts_enabled = cfg.voice.ttsEnabled;
      };
    } ++ cfg.profiles.extra;
    
    theme = mkIf cfg.theme.inheritPalette {
      colors = oligarchyColors;
    };
  };
  
in {
  options.oligarchy.blipply = {
    enable = mkEnableOption "Blipply AI Voice Assistant";
    
    ai = {
      model = mkOption {
        type = types.str;
        default = "llama3.2:3b";
        description = "Ollama model to use (can reference ai-stack presets)";
      };
      
      ollamaUrl = mkOption {
        type = types.str;
        default = "http://127.0.0.1:11434";
        description = "Ollama API endpoint (auto-set from ai-stack if enabled)";
      };
    };
    
    theme = {
      inheritPalette = mkOption {
        type = types.bool;
        default = true;
        description = "Use Oligarchy's DeMoD color palette";
      };
      
      avatar = mkOption {
        type = types.path;
        default = "./assets/blipply-avatar.gif";
        description = "Path to Blipply avatar (GIF, PNG, or SVG)";
      };
      
      avatarSize = mkOption {
        type = types.int;
        default = 96;
        description = "Avatar size in pixels";
      };
    };
    
    voice = {
      sttModel = mkOption {
        type = types.str;
        default = "base.en";
        description = "Whisper speech-to-text model";
      };
      
      model = mkOption {
        type = types.str;
        default = "en_US-lessac-medium";
        description = "Piper text-to-speech voice model";
      };
      
      ttsSpeed = mkOption {
        type = types.float;
        default = 1.0;
        description = "TTS speech speed multiplier";
      };
      
      ttsEnabled = mkOption {
        type = types.bool;
        default = true;
        description = "Enable text-to-speech output";
      };
      
      vadEnabled = mkOption {
        type = types.bool;
        default = true;
        description = "Enable voice activity detection";
      };
      
      vadAggressiveness = mkOption {
        type = types.int;
        default = 2;
        description = "VAD aggressiveness (0-3, higher = more sensitive)";
      };
      
      sampleRate = mkOption {
        type = types.int;
        default = 16000;
        description = "Audio sample rate in Hz";
      };
      
      silenceDurationMs = mkOption {
        type = types.int;
        default = 1000;
        description = "Silence duration to end speech (ms)";
      };
    };
    
    hotkeys = {
      toggle = mkOption {
        type = types.str;
        default = "Super+Shift+A";
        description = ''
          Hotkey to toggle Blipply visibility.
          Format: "Modifier+Key" (e.g., "Super+Shift+A")
          Will be integrated with Oligarchy's keybinding system.
        '';
      };
      
      pushToTalk = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Optional push-to-talk hotkey.
          When held, Blipply listens continuously.
        '';
      };
    };
    
    profiles = {
      active = mkOption {
        type = types.str;
        default = "default";
        description = "Default profile to use";
      };
      
      default = {
        name = mkOption {
          type = types.str;
          default = "Blipply";
          description = "Display name for default profile";
        };
        
        personality = mkOption {
          type = types.str;
          default = "helpful";
          description = ''
            Personality preset: helpful, sassy, technical, concise
          '';
        };
      };
      
      extra = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = ''
          Additional custom profiles.
          Each profile is an attrset with same structure as default.
        '';
      };
    };
    
    context = {
      awareness = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable context awareness (active window, clipboard, etc).
          Warning: May impact privacy.
        '';
      };
      
      audioDucking = mkOption {
        type = types.bool;
        default = true;
        description = "Duck (lower volume of) other audio when Blipply speaks";
      };
    };
  };
  
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.openclaw-agent.enable;
        message = "OpenClaw agent must be enabled to use Blipply (config.services.openclaw-agent.enable = true)";
      }
    ];
    
    # Import the actual blipply module
    imports = [ ./blipply-assistant/flake.nix ];
    
    # Enable blipply service with Oligarchy-configured settings
    # Runs as OpenClaw user for tight integration
    services.blipply-assistant = {
      enable = true;
      user = openclawUser;
      group = openclawUser;
      homeDirectory = openclawHome;
    };
    
    # Generate blipply configuration
    environment.etc."blipply/config.toml".text = lib.generators.toINI {} blipplyConfig;
    
    # Blipply runs as the OpenClaw user for tight integration
    # This allows sharing config, workspace, and plugins
    users.users.${openclawUser}.extraGroups = [ "input" "audio" ];
    
    # Install blipply binary system-wide
    environment.systemPackages = [ 
      (pkgs.callPackage ./blipply-assistant { })
    ];
    
    # Create blipply config in OpenClaw user's home
    systemd.tmpfiles.rules = [
      "d ${openclawHome}/.config/blipply 0755 ${openclawUser} ${openclawUser} -"
      "C ${openclawHome}/.config/blipply/config.toml 0644 ${openclawUser} ${openclawUser} - ${configFile}"
    ];
    
    # Blipply depends on OpenClaw gateway for AI with plugins
    systemd.user.services.blipply-assistant = {
      after = [ "openclaw-gateway.service" ];
      requires = [ "openclaw-gateway.service" ];
    };
    
    # Waybar integration: add Blipply status indicator
    # Shows status for OpenClaw user services
    programs.waybar.settings.mainBar = mkIf config.programs.waybar.enable {
      "custom/blipply" = {
        format = "{}";
        tooltip = true;
        interval = 5;
        exec = pkgs.writeShellScript "waybar-blipply" ''
          export XDG_RUNTIME_DIR=/run/user/$(${pkgs.coreutils}/bin/id -u ${openclawUser})
          # Check if blipply is running for OpenClaw user
          if ${pkgs.systemd}/bin/systemctl --user -M ${openclawUser}@ is-active blipply-assistant >/dev/null 2>&1; then
            echo '{"text": "🎤", "tooltip": "Blipply: Online\nClick to toggle", "class": "online"}'
          else
            echo '{"text": "🎤", "tooltip": "Blipply: Offline\nClick to start", "class": "offline"}'
          fi
        '';
        on-click = "blipply-assistant --toggle";
        on-click-right = "${pkgs.systemd}/bin/systemctl --user -M ${openclawUser}@ restart blipply-assistant";
      };
    };
    
    # Hyprland keybinding integration
    wayland.windowManager.hyprland.settings = mkIf config.wayland.windowManager.hyprland.enable {
      bind = [
        # Main toggle hotkey
        "SUPER SHIFT, A, exec, blipply-assistant --toggle"
      ] ++ optionals (cfg.hotkeys.pushToTalk != null) [
        # Push-to-talk (hold to listen)
        "SUPER SHIFT, M, exec, blipply-assistant --push-to-talk"
      ];
    };
    
    # Runtime toggle integration: add to Oligarchy's toggle menu
    environment.etc."oligarchy/toggles/blipply.json".text = builtins.toJSON {
      name = "Blipply Assistant";
      description = "AI Voice Assistant";
      toggle = "blipply-assistant --toggle";
      check = "systemctl --user is-active blipply-assistant";
    };
  };
}
