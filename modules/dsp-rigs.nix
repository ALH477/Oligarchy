{ config, lib, pkgs, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# DSP rigs — "pedalboard as code"
# A rig is a switchable effect chain that runs as a JACK client and is patched
# capture → rig → (DSP coprocessor via NETJACK if armed, else playback). Two
# rig types are supported:
#   lv2   — a declarative list of LV2 plugin URIs, hosted by mod-host
#   faust — a .dsp program compiled to a JACK client at build time
# plus the always-safe `bypass` (direct passthrough).
#
# OPT-IN (custom.dsp.enable, default false) so it adds no service/packages
# unless you want it. Switching the active rig is runtime (control center) once
# enabled; declared Faust rigs are compiled at build time.
#
# NOTE: the JACK auto-patching (port names) is best-effort and may need tuning
# to your actual interface — verify in qpwgraph. `bypass` is the safe baseline.
# ─────────────────────────────────────────────────────────────────────────────

with lib;

let
  cfg = config.custom.dsp;

  # Compile a Faust .dsp to a headless JACK client.
  faustRig = name: src: pkgs.stdenvNoCC.mkDerivation {
    name = "dsp-rig-${name}";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.faust pkgs.gcc pkgs.pkg-config pkgs.jack2 ];
    buildPhase = ''
      faust2jackconsole -o "dsp-rig-${name}" "${src}"
    '';
    installPhase = ''
      install -Dm755 "dsp-rig-${name}" "$out/bin/dsp-rig-${name}"
    '';
  };

  rigModule = types.submodule ({ name, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "bypass" "lv2" "faust" ];
        default = "bypass";
        description = "Rig engine.";
      };
      description = mkOption { type = types.str; default = name; };
      plugins = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Ordered LV2 plugin URIs (type = \"lv2\").";
        example = [ "http://lsp-plug.in/plugins/lv2/comp_stereo" ];
      };
      faustSrc = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Faust .dsp source (type = \"faust\").";
      };
    };
  });

  # Resolve each rig to a small metadata file the runner reads at runtime.
  rigMetaFor = name: r:
    let
      bin = if r.type == "faust" && r.faustSrc != null
            then "${faustRig name r.faustSrc}/bin/dsp-rig-${name}"
            else "";
    in ''
      type=${r.type}
      description=${r.description}
      plugins=${concatStringsSep " " r.plugins}
      command=${bin}
    '';

  runner = pkgs.writeShellScriptBin "dsp-rig" ''
    set -uo pipefail
    RIGDIR=/etc/oligarchy/dsp-rigs
    STATE="$HOME/.config/oligarchy/rig"
    PIDFILE="''${XDG_RUNTIME_DIR:-/tmp}/oligarchy-rig.pid"
    # Run JACK tools inside PipeWire's JACK environment.
    PWJACK="${pkgs.pipewire}/bin/pw-jack"
    JLSP="$PWJACK ${pkgs.jack2}/bin/jack_lsp"
    jc() { $PWJACK ${pkgs.jack2}/bin/jack_connect "$@" 2>/dev/null || true; }
    note() { command -v notify-send >/dev/null 2>&1 && notify-send "🎛 Rig" "$1" || echo "$1"; }

    stop_current() {
      [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      pkill -f "mod-host -p 5555" 2>/dev/null || true
    }

    case "''${1:-}" in
      list)   ls "$RIGDIR" 2>/dev/null; exit 0 ;;
      status) cat "$STATE" 2>/dev/null || echo bypass; exit 0 ;;
      switch) ;;
      *) echo "usage: dsp-rig {switch <name>|list|status}" >&2; exit 2 ;;
    esac

    name="''${2:-bypass}"
    meta="$RIGDIR/$name"
    [ -f "$meta" ] || { echo "no such rig: $name" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$meta"

    stop_current
    mkdir -p "$(dirname "$STATE")"; echo "$name" > "$STATE"

    # Source/sink anchors (best-effort; tune in qpwgraph if your ports differ).
    CAP_L="$($JLSP 2>/dev/null | grep -iE 'capture_(FL|1)$' | head -1)"
    CAP_R="$($JLSP 2>/dev/null | grep -iE 'capture_(FR|2)$' | head -1)"
    OUT_L="$($JLSP 2>/dev/null | grep -iE 'playback_(FL|1)$' | head -1)"
    OUT_R="$($JLSP 2>/dev/null | grep -iE 'playback_(FR|2)$' | head -1)"

    if [ "$type" = "bypass" ]; then
      [ -n "$CAP_L" ] && [ -n "$OUT_L" ] && jc "$CAP_L" "$OUT_L"
      [ -n "$CAP_R" ] && [ -n "$OUT_R" ] && jc "$CAP_R" "$OUT_R"
      note "bypass"
      exit 0
    fi

    if [ "$type" = "lv2" ]; then
      ${pkgs.mod-host}/bin/mod-host -p 5555 >/dev/null 2>&1 &
      echo $! > "$PIDFILE"; sleep 1
      i=0
      for uri in $plugins; do
        printf 'add %s %d\n' "$uri" "$i" | ${pkgs.netcat-gnu}/bin/nc -q1 127.0.0.1 5555 >/dev/null 2>&1 || true
        i=$((i+1))
      done
      note "lv2: $description ($i plugins) — verify routing in qpwgraph"
      exit 0
    fi

    if [ "$type" = "faust" ] && [ -n "$command" ]; then
      setsid -f "$command" >/dev/null 2>&1 &
      echo $! > "$PIDFILE"; sleep 1
      note "faust: $description — verify routing in qpwgraph"
      exit 0
    fi
  '';
in
{
  options.custom.dsp = {
    enable = mkEnableOption "DSP rigs (pedalboard-as-code) — adds mod-host + a runner";

    rig.active = mkOption {
      type = types.str;
      default = "bypass";
      description = "Rig selected at boot. Switch live with the control center.";
    };

    rigs = mkOption {
      type = types.attrsOf rigModule;
      default = {
        bypass = { type = "bypass"; description = "Bypass — direct passthrough"; };
        comp   = { type = "lv2"; description = "LSP compressor"; plugins = [ "http://lsp-plug.in/plugins/lv2/comp_stereo" ]; };
        # Faust example (opt-in: uncomment to compile at build time):
        # drive = { type = "faust"; description = "Soft-clip overdrive"; faustSrc = ./dsp-rigs/drive.dsp; };
      };
      description = "Named rigs. Faust rigs compile at build; LV2 need their plugins installed.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ runner pkgs.mod-host pkgs.lsp-plugins pkgs.qpwgraph pkgs.jack2 ];

    # One metadata file per rig for the runtime runner / control center.
    environment.etc = mapAttrs' (n: r: nameValuePair "oligarchy/dsp-rigs/${n}" { text = rigMetaFor n r; }) cfg.rigs;

    # Apply the boot-default rig once the graphical session's audio is up.
    systemd.user.services.dsp-rig-runner = {
      description = "Apply the active Oligarchy DSP rig";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" "pipewire.service" ];
      path = [ pkgs.pipewire pkgs.jack2 pkgs.mod-host pkgs.netcat-gnu pkgs.libnotify ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runner}/bin/dsp-rig switch ${cfg.rig.active}";
      };
    };
  };
}
