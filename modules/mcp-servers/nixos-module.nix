# ═══════════════════════════════════════════════════════════════════════════════
# Oligarchy MCP Servers — registration module
#
# Replaces the legacy modules/oligarchy-mcp.nix on a per-aspect basis. The
# umbrella binary is installed as `oligarchy-mcp` so .mcp.json continues to
# reference a single front door. Each `.mcp.json` entry invokes the umbrella
# with one argument (`<aspect>`); the umbrella exec-spawns the matching
# `oligarchy-<aspect>-mcp` binary.
#
# Each aspect's `enable` toggle defaults to `true`; flipping one off removes
# that binary (the umbrella then prints `exec failed` for that aspect).
#
# The top-level flake threads the `mcp-servers` sub-flake input through
# `specialArgs`. The module references `inputs.mcp-servers.packages.${pkgs.system}.<pkg>`.
# ═══════════════════════════════════════════════════════════════════════════════
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.custom.mcpServers;
  mcp = inputs.mcp-servers;
  packages = mcp.packages.${pkgs.system} or (throw
    "mcp-servers sub-flake has no packages for system ${pkgs.system}"
  );

  umbrellaPkg = packages.umbrella or packages.default;

  aspectNames = [ "system" "net" "dcf" "dsp" "ai" "secrets" "vm" "ports-sec" ];

  aspectPkg = name: packages."oligarchy-${name}-mcp" or null;
  # The `aspects` attrsOf submodule has per-name overrides; missing keys
  # default to `enable = true` to match the design's "all aspects on by
  # default" semantics.
  aspectEnabled = name:
    cfg.aspects.${name}.enable or true;
  enabledAspectPkgs =
    filter (p: p != null)
      (map (n: if aspectEnabled n then aspectPkg n else null) aspectNames);

  # Standalone read-only fingerprint helper (kept from the legacy
  # oligarchy-mcp.nix). Installed outside MCP so it can be called manually
  # too. The `system` aspect's fingerprint_status tool calls this the same
  # way the legacy Python server did.
  oligarchy-fingerprint = pkgs.writeShellScriptBin "oligarchy-fingerprint" ''
    set -u
    export PATH=${makeBinPath [ pkgs.fprintd pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}:$PATH
    user="''${2:-$(id -un)}"
    list_raw() { timeout 5 fprintd-list "$1" 2>&1 || true; }
    case "''${1:-status}" in
      status)
        raw="$(list_raw "$user")"
        echo "fprintd service : $(systemctl is-active fprintd.service 2>/dev/null || echo inactive)"
        if echo "$raw" | grep -qiE "found .*device"; then echo "Reader          : present"
        elif echo "$raw" | grep -qiE "no devices|impossible to"; then echo "Reader          : NOT FOUND"
        else echo "Reader          : unknown"; fi
        echo "Enrolled ($user):"
        if echo "$raw" | grep -qiE "has no fingers|no fingers enrolled"; then echo "  (none enrolled)"
        else echo "$raw" | grep -iE "finger" | sed 's/^/  /' || echo "  (none)"; fi
        echo "PAM (fprintAuth):"
        for svc in /etc/pam.d/*; do
          [ -f "$svc" ] || continue
          if grep -qs "pam_fprintd" "$svc"; then echo "  $(basename "$svc")"; fi
        done ;;
      list) list_raw "$user" ;;
      *) echo "usage: oligarchy-fingerprint {status|list} [user]" >&2; exit 2 ;;
    esac
  '';
in
{
  options.custom.mcpServers = {
    enable = mkEnableOption "the Oligarchy MCP umbrella and per-aspect servers";

    flakeDir = mkOption {
      type = types.str;
      default = "/etc/nixos";
      description = "Directory of the Oligarchy flake the MCP servers inspect (read-only).";
    };

    stateDir = mkOption {
      type = types.str;
      default = "~/.local/state/oligarchy-mcp";
      description = "Per-aspect audit log root. Expanded at runtime.";
    };

    systemdUnit.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the umbrella as a long-running systemd service. Off during
        development so Claude Code / Blipply spawn it directly over stdio.
        When on, the umbrella is hardened (NoNewPrivileges, ProtectSystem,
        SystemCallFilter=@system-service). Note: the umbrella execs into
        the per-aspect binary immediately, so a long-running service is
        only meaningful if Blipply/Claude Code keeps the spawned aspect
        child running on its own.
      '';
    };

    aspects = mkOption {
      type = types.attrsOf (types.submodule {
        options.enable = mkOption {
          type = types.bool;
          default = true;
          description = "Install the `oligarchy-<aspect>-mcp` binary so the umbrella can exec-spawn it.";
        };
      });
      default = { };
      description = "Per-aspect enable toggles.";
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      environment.systemPackages =
        [ umbrellaPkg ] ++ enabledAspectPkgs ++ [ oligarchy-fingerprint ];

      environment.sessionVariables = {
        OLIGARCHY_FLAKE_DIR = cfg.flakeDir;
        OLIGARCHY_MCP_STATE_DIR = cfg.stateDir;
      };
    })

    # Optional hardened systemd unit for long-running agent hosts. Off by
    # default; the umbrella is then spawned over stdio by Claude Code /
    # Blipply. Because the umbrella execs into the per-aspect binary on
    # startup, the service target is mostly a registration knob — once
    # systemd starts it, it sees the actual aspect binary running.
    (mkIf (cfg.enable && cfg.systemdUnit.enable) {
      systemd.services.oligarchy-mcp = {
        description = "Oligarchy MCP umbrella (long-running agent host)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${umbrellaPkg}/bin/oligarchy-mcp system";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        };
      };
    })
  ];
}