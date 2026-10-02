# Terminus Developer Edition — local-only app wrapper
# Wraps the unified-UI flake's `demod-desktop-developer` package which runs
# the full device stack: orchestrator + demod-rt + Faust DSP + device bridge
# + TERMINUS home. No source code or private repo URLs are committed — the
# wrapper invokes a pre-built binary and points at the local working tree
# for live Lua iteration. Safe to commit to the public Oligarchy repo.
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.terminus-dev;

  # Path to the local unified-UI working tree (developer machine only)
  unifiedUiDir = "/home/${config.custom.user.name}/Downloads/unified-UI";

  # Pre-built binary (built once with `nix build .#demod-desktop-developer`)
  stackBin = "/home/${config.custom.user.name}/.local/bin/terminus-stack/bin/demod-desktop-developer";

  terminus-launcher = pkgs.writeShellScriptBin "terminus" ''
    export DEMOD_APP_DIR="${unifiedUiDir}"
    exec ${stackBin} "$@"
  '';

  terminus-dsp = pkgs.writeShellScriptBin "terminus-dsp" ''
    # DSP Studio standalone (no RT engine needed for GUI-only work)
    exec /home/${config.custom.user.name}/demod-ui/demod-ui "${unifiedUiDir}/dsp/dsp_studio.lua" "$@"
  '';

  terminus-desktop = pkgs.makeDesktopItem {
    name = "terminus";
    desktopName = "Terminus Dev";
    comment = "DeMoD Terminus — full RT stack + TERMINUS home";
    exec = "terminus";
    icon = "applications-system";
    categories = [ "Development" "AudioVideo" ];
    startupNotify = false;
  };

  terminus-dsp-desktop = pkgs.makeDesktopItem {
    name = "terminus-dsp";
    desktopName = "Terminus DSP Studio";
    comment = "DeMoD DSP Studio — GUI only (no RT engine)";
    exec = "terminus-dsp";
    icon = "applications-system";
    categories = [ "Development" "AudioVideo" ];
    startupNotify = false;
  };
  # ── demod-rt auto-link ─────────────────────────────────────────────────────
  # PipeWire does not connect demod-rt's outputs to anything, so a freshly
  # launched Terminus is silent until someone runs pw-link by hand, and the links
  # die with the process.
  #
  # This is deliberately NOT a WirePlumber policy rule. WP only builds an audio
  # linkable out of nodes that expose SPA_PARAM_PortConfig (si-audio-adapter), and
  # demod-rt is a pipewire-jack client node, which does not. Stamping
  # `media.class = "Stream/Output/Audio"` + `node.autoconnect = true` onto it via
  # jack.rules was verified to apply cleanly and still produce zero links — the
  # node never becomes a linkable, so the policy never sees it. Hence an explicit
  # linker.
  #
  # It only acts when demod-rt:out_L has NO outgoing link, so manual routing —
  # notably terminus-dsp-connect sending demod-rt through the ArchibaldOS DSP VM
  # — is never overridden.
  demod-rt-autolink = pkgs.writeShellScript "demod-rt-autolink" ''
    default_sink() {
      wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null |
        sed -n 's/.*node\.name = "\([^"]*\)".*/\1/p' | head -1
    }

    already_linked() {
      pw-link -l 2>/dev/null | grep -A1 '^demod-rt:out_L$' | grep -q '|->'
    }

    sync_links() {
      pw-link -o 2>/dev/null | grep -qx 'demod-rt:out_L' || return 0
      already_linked && return 0

      sink=$(default_sink)
      [ -n "$sink" ] || return 0

      pw-link "demod-rt:out_L" "$sink:playback_FL" 2>/dev/null || return 0
      pw-link "demod-rt:out_R" "$sink:playback_FR" 2>/dev/null || true
      echo "autolink: demod-rt -> $sink"
    }

    # Reconcile once (covers demod-rt already running), then on every graph change.
    sync_links
    pw-link -m -o 2>/dev/null | while IFS= read -r _; do sync_links; done
  '';

  terminus-dsp-connect = pkgs.writeShellScriptBin "terminus-dsp-connect" ''
    # Route Terminus Dev audio through the ArchibaldOS DSP VM's engine.
    # Usage: terminus-dsp-connect [start|stop|status]
    #
    # This host joins the guest's NetJack2 manager with the dsp-netjack user
    # unit (PipeWire's netjack2 driver); the guest shows up here as
    # dsp-vm.sink (into its engine) and dsp-vm.source (out of it). It used to
    # start dsp-netjack-bridge and link `demod-rt:output_FL` to
    # `archibaldos-dsp:capture_1`: the bridge could not form a link, and
    # demod-rt's ports are out_L/out_R, so neither link ever existed.
    set -e
    ACTION="''${1:-status}"
    LINK="dsp-netjack"
    VM="${config.custom.vm.dsp.name}"

    case "$ACTION" in
      start)
        echo "Starting DSP VM..."
        sudo systemctl start "''${VM}.service"
        systemctl --user start "''${LINK}.service"
        echo "Waiting for the guest's NetJack2 manager..."
        for _ in $(seq 1 90); do
          pw-link -i 2>/dev/null | grep -qx 'dsp-vm.sink:playback_1' && break
          sleep 1
        done
        pw-link -i 2>/dev/null | grep -qx 'dsp-vm.sink:playback_1' \
          || { echo "dsp-vm.sink never appeared: is the guest up? (dsp-status)" >&2; exit 1; }
        echo "Connecting Terminus Dev to the DSP VM..."
        pw-link "demod-rt:out_L" "dsp-vm.sink:playback_1" 2>/dev/null || true
        pw-link "demod-rt:out_R" "dsp-vm.sink:playback_2" 2>/dev/null || true
        # The engine's return to the default speakers.
        pw-link "dsp-vm.source:capture_1" "$(pw-link -i | grep -m1 'alsa.*:playback_FL')" 2>/dev/null || true
        pw-link "dsp-vm.source:capture_2" "$(pw-link -i | grep -m1 'alsa.*:playback_FR')" 2>/dev/null || true
        echo "Done. Terminus Dev -> DSP VM engine -> speakers"
        ;;
      stop)
        echo "Stopping NetJack2 to the DSP VM..."
        systemctl --user stop "''${LINK}.service"
        echo "Stopping DSP VM..."
        sudo systemctl stop "''${VM}.service"
        ;;
      status)
        echo "=== DSP VM ==="
        systemctl is-active "''${VM}.service" 2>/dev/null || echo "inactive"
        echo "=== NetJack2 (dsp-netjack) ==="
        systemctl --user is-active "''${LINK}.service" 2>/dev/null || echo "inactive"
        echo "=== Ports ==="
        { pw-link -o; pw-link -i; } 2>/dev/null | grep -E "dsp-vm|demod-rt" || echo "no DSP ports visible"
        ;;
      *)
        echo "Usage: terminus-dsp-connect [start|stop|status]"
        exit 1
        ;;
    esac
  '';

in
{
  options.custom.terminus-dev = {
    enable = lib.mkEnableOption "Terminus developer edition (local-only app)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      terminus-launcher
      terminus-dsp
      terminus-dsp-connect
      terminus-desktop
      terminus-dsp-desktop
    ];

    systemd.user.services.demod-rt-autolink = {
      description = "Link demod-rt outputs to the default PipeWire sink";
      wantedBy = [ "pipewire.service" ];
      after = [ "pipewire.service" "wireplumber.service" ];
      partOf = [ "pipewire.service" ];
      path = with pkgs; [ pipewire wireplumber gnugrep gnused coreutils ];
      serviceConfig = {
        ExecStart = demod-rt-autolink;
        Restart = "always";
        RestartSec = 2;
      };
    };
  };
}
