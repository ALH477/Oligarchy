{ config, lib, pkgs, ... }:

with lib;

let
  oligarchyColors = {
    primary = "#00D4AA";
    alert = "#FF6B6B";
    warning = "#FFE66D";
    background = "#1A1A2E";
    surface = "#16213E";
    text = "#EAEAEA";
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
        # Falls back to a shipped DeMoD gif; modules/assets/blipply-avatar.gif
        # does not exist, which would break pure eval when enabled.
        default = ../assets/demod.gif;
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

  config = let
    cfg = config.oligarchy.blipply;
    blipplyHome = "/home/blipply";
  in mkIf cfg.enable (mkMerge [
    {
      # Blipply is a self-contained local voice assistant. Its agentic action
      # surface is the secure, read-only Oligarchy MCP (see [mcp] below), not the
      # removed OpenClaw gateway.
      services.blipply-assistant = {
        enable = true;
        user = "blipply";
        group = "blipply";
        homeDirectory = blipplyHome;
      };
      
      environment.etc."blipply/config.toml".text = lib.generators.toINI {} {
        general = {
          ollama_url = cfg.ai.ollamaUrl;
          hotkey = cfg.hotkeys.toggle;
          first_run_complete = false;
          active_profile = cfg.profiles.active;
        };

        # Secure local agent surface: Blipply launches the read-only Oligarchy
        # MCP over stdio and offers its tools to the local LLM. Read-only by
        # construction — voice can query/inspect/dry-build, never mutate.
        mcp = {
          enabled = true;
          command = "oligarchy-mcp";
          allowed_tools = "system_status,dcf_status,dsp_status,ai_status,service_status,journal_tail,list_modules,read_module,kernel_options,gpu_options,dry_build,flake_check";
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
            avatar_path = toString cfg.theme.avatar;
            avatar_size_px = cfg.theme.avatarSize;
            voice_model = cfg.voice.model;
            tts_speed = cfg.voice.ttsSpeed;
            tts_enabled = cfg.voice.ttsEnabled;
          };
        };
        
        theme = mkIf cfg.theme.inheritPalette {
          colors = oligarchyColors;
        };
      };
      
      users.users.blipply.extraGroups = [ "input" "audio" ];

      # Use the package the blipply-assistant flake module already builds
      # (there is no ./blipply-assistant/default.nix for callPackage).
      environment.systemPackages = [
        config.services.blipply-assistant.package
      ];

      systemd.tmpfiles.rules = [
        "d ${blipplyHome}/.config/blipply 0755 blipply blipply -"
      ];

      environment.etc."oligarchy/toggles/blipply.json".text = builtins.toJSON {
        name = "Blipply Assistant";
        description = "AI Voice Assistant";
        toggle = "blipply-assistant --toggle";
        check = "systemctl --user is-active blipply-assistant";
      };
    }
  ]);
}
