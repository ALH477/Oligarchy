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
  unifiedUiDir = "/home/asher/Downloads/unified-UI";

  # Pre-built binary (built once with `nix build .#demod-desktop-developer`)
  stackBin = "/home/asher/.local/bin/terminus-stack/bin/demod-desktop-developer";

  terminus-launcher = pkgs.writeShellScriptBin "terminus" ''
    export DEMOD_APP_DIR="${unifiedUiDir}"
    exec ${stackBin} "$@"
  '';

  terminus-dsp = pkgs.writeShellScriptBin "terminus-dsp" ''
    # DSP Studio standalone (no RT engine needed for GUI-only work)
    exec /home/asher/demod-ui/demod-ui "${unifiedUiDir}/dsp/dsp_studio.lua" "$@"
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
  terminus-dsp-connect = pkgs.writeShellScriptBin "terminus-dsp-connect" ''
    # Route Terminus Dev audio through ArchibaldOS DSP VM
    # Usage: terminus-dsp-connect [start|stop|status]
    set -e
    ACTION="''${1:-status}"
    BRIDGE="dsp-netjack-bridge"
    VM="archibaldos-dsp"

    case "$ACTION" in
      start)
        echo "Starting DSP VM..."
        sudo systemctl start "''${VM}.service"
        echo "Waiting for VM boot + NETJACK..."
        sleep 20
        echo "Starting NETJACK bridge..."
        sudo systemctl start "''${BRIDGE}.service"
        sleep 3
        echo "Connecting Terminus Dev to DSP bridge..."
        # Auto-connect demod-rt outputs to DSP bridge inputs via PipeWire
        pw-link "demod-rt:output_FL" "archibaldos-dsp:capture_1" 2>/dev/null || true
        pw-link "demod-rt:output_FR" "archibaldos-dsp:capture_2" 2>/dev/null || true
        # Auto-connect DSP bridge outputs to default speakers
        pw-link "archibaldos-dsp:playback_1" "$(pw-link -i | grep -m1 'alsa.*:playback_FL')" 2>/dev/null || true
        pw-link "archibaldos-dsp:playback_2" "$(pw-link -i | grep -m1 'alsa.*:playback_FR')" 2>/dev/null || true
        echo "Done. Terminus Dev → DSP VM → speakers"
        ;;
      stop)
        echo "Stopping NETJACK bridge..."
        sudo systemctl stop "''${BRIDGE}.service"
        echo "Stopping DSP VM..."
        sudo systemctl stop "''${VM}.service"
        ;;
      status)
        echo "=== DSP VM ==="
        systemctl is-active "''${VM}.service" 2>/dev/null || echo "inactive"
        echo "=== NETJACK Bridge ==="
        systemctl is-active "''${BRIDGE}.service" 2>/dev/null || echo "inactive"
        echo "=== JACK Ports ==="
        jack_lsp 2>/dev/null | grep -E "archibaldos|demod" || echo "no DSP ports visible"
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
  };
}
