{ config, lib, pkgs, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# System Personas / "Modes"
# One switch retunes the whole machine — kernel, the ArchibaldOS DSP coprocessor,
# the local-AI tier, audio quantum, gamemode and power policy. Build-time knobs
# are owned here (mkDefault, so a host or oligarchy-local.nix can still override);
# the control center (`oligarchy-ctl persona <name>`) flips the runtime bits live
# and writes `custom.persona.active` into oligarchy-local.nix for the rest.
# ─────────────────────────────────────────────────────────────────────────────

with lib;

let
  cfg = config.custom.persona;

  personas = {
    # Lowest-latency audio: arm the DSP coprocessor, get the CPU out of its way.
    studio = {
      description = "Studio — DSP coprocessor armed, AI idle, lowest audio latency.";
      kernel = "zen"; dsp = true;  aiEnable = false; aiPreset = "cpu-fallback";
      quantum = 64;   minQuantum = 32;  gamemode = false; power = "performance";
      apps = [ "1|guitarix" "2|qpwgraph" ];
    };
    # Maximum FPS.
    gaming = {
      description = "Gaming — gamemode + performance governor, full AI.";
      kernel = "zen"; dsp = false; aiEnable = true;  aiPreset = "pewdiepie";
      quantum = 256;  minQuantum = 64;  gamemode = true;  power = "performance";
      apps = [ ];
    };
    # Daily driver — reproduces the prior hardcoded defaults.
    dev = {
      description = "Dev — capable AI, balanced power (the everyday baseline).";
      kernel = "zen"; dsp = false; aiEnable = true;  aiPreset = "pewdiepie";
      quantum = 256;  minQuantum = 64;  gamemode = false; power = "balanced";
      apps = [ "1|kitty" "2|code" ];
    };
    # Maximum endurance.
    battery = {
      description = "Battery — AI and DSP off, power-saver, high quantum.";
      kernel = "zen"; dsp = false; aiEnable = false; aiPreset = "cpu-fallback";
      quantum = 512;  minQuantum = 256; gamemode = false; power = "power-saver";
      apps = [ ];
    };
  };

  p = personas.${cfg.active};
in
{
  options.custom.persona.active = mkOption {
    type = types.enum (attrNames personas);
    default = "dev";
    description = ''
      Active system persona. One switch retunes kernel, the DSP coprocessor,
      the AI tier, audio quantum, gamemode and power policy. Change it live with
      `oligarchy-ctl persona <name>` (control center), which also writes
      custom.persona.active into oligarchy-local.nix and prompts the rebuild for
      the build-time pieces.
    '';
  };

  config = {
    # Build-time knobs (mkDefault → a host or oligarchy-local.nix can override).
    custom.kernel.variant = mkDefault p.kernel;
    services.dsp-vm.enable = mkDefault p.dsp;
    services.ollamaAgentic.enable = mkDefault p.aiEnable;
    services.ollamaAgentic.preset = mkDefault p.aiPreset;
    programs.gamemode.enable = mkDefault p.gamemode;

    # Persona fully owns the low-latency clock block (configuration.nix no longer
    # sets it), so there is no cross-module merge of the same JSON path.
    services.pipewire.extraConfig.pipewire."20-low-latency"."context.properties" = {
      "default.clock.rate" = 48000;
      "default.clock.quantum" = p.quantum;
      "default.clock.min-quantum" = p.minQuantum;
      "default.clock.max-quantum" = 512;
    };

    # power-profiles-daemon has no declarative "default profile", so apply it once
    # the daemon is up.
    systemd.services.persona-power-profile = {
      description = "Apply the ${cfg.active} persona power profile";
      wantedBy = [ "multi-user.target" ];
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${p.power}";
      };
    };

    # Surface the active persona + each persona's app set for the control center.
    environment.etc = {
      "oligarchy/persona".text = cfg.active;
    } // (mapAttrs'
      (n: pdef: nameValuePair "oligarchy/persona-apps/${n}" {
        text = concatStringsSep "\n" pdef.apps;
      })
      personas);
  };
}
