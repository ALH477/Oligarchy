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
        default = ./assets/blipply-avatar.gif;
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
    openclawUser = config.services.openclaw-agent.user;
  in mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = config.services.openclaw-agent.enable;
          message = "OpenClaw agent must be enabled to use Blipply";
        }
      ];
      
      services.blipply-assistant = {
        enable = true;
        user = openclawUser;
        group = openclawUser;
        homeDirectory = config.services.openclaw-agent.homeDirectory;
      };
      
      environment.etc."blipply/config.toml".text = lib.generators.toINI {} {
        general = {
          openclaw_url = "http://127.0.0.1:8080";
          openclaw_token = config.services.openclaw-agent.gatewayToken;
          ollama_url = cfg.ai.ollamaUrl;
          hotkey = cfg.hotkeys.toggle;
          first_run_complete = false;
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
      
      users.users.${openclawUser}.extraGroups = [ "input" "audio" ];
      
      environment.systemPackages = [ 
        (pkgs.callPackage ./blipply-assistant { })
      ];
      
      systemd.tmpfiles.rules = [
        "d ${config.services.openclaw-agent.homeDirectory}/.config/blipply 0755 ${openclawUser} ${openclawUser} -"
      ];
      
      systemd.user.services.blipply-assistant = {
        after = [ "openclaw-gateway.service" ];
        requires = [ "openclaw-gateway.service" ];
      };
      
      environment.etc."oligarchy/toggles/blipply.json".text = builtins.toJSON {
        name = "Blipply Assistant";
        description = "AI Voice Assistant";
        toggle = "blipply-assistant --toggle";
        check = "systemctl --user is-active blipply-assistant";
      };
    }
  ]);
}
