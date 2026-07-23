{ config, lib, pkgs, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Oligarchy MCP — registration module
# Installs the local read-only MCP server (replacing the removed OpenClaw
# gateway) and points it at the system flake. stdio transport only: there is no
# network listener, no auth token, and no remote code fetch.
# ─────────────────────────────────────────────────────────────────────────────

let
  cfg = config.custom.oligarchyMcp;
  oligarchy-mcp = pkgs.callPackage ./oligarchy-mcp { };

  # Fingerprint integration for the MCP. READ-ONLY on purpose: it reports the
  # reader/enrollment state so the agent can answer "is fingerprint auth set
  # up?", but it never enrolls, verifies, or deletes — enrollment stays a
  # manual `fprintd-enroll` action outside the zero-trust MCP surface.
  oligarchy-fingerprint = pkgs.writeShellScriptBin "oligarchy-fingerprint" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.fprintd pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}:$PATH

    user="''${2:-$(id -un)}"

    # fprintd is D-Bus activated and can block if the reader is mid-scan, so
    # every call is timeout-bounded and failures degrade to a clear string.
    list_raw() { timeout 5 fprintd-list "$1" 2>&1 || true; }

    case "''${1:-status}" in
      status)
        raw="$(list_raw "$user")"
        echo "fprintd service : $(systemctl is-active fprintd.service 2>/dev/null || echo inactive)"
        if echo "$raw" | grep -qiE "found .*device"; then
          echo "Reader          : present"
        elif echo "$raw" | grep -qiE "no devices|impossible to"; then
          echo "Reader          : NOT FOUND"
        else
          echo "Reader          : unknown"
        fi
        echo "Enrolled ($user):"
        if echo "$raw" | grep -qiE "has no fingers|no fingers enrolled"; then
          echo "  (none enrolled)"
        else
          echo "$raw" | grep -iE "finger" | sed 's/^/  /' || echo "  (none)"
        fi
        # PAM services wired to fingerprint auth on this host (read-only view).
        echo "PAM (fprintAuth):"
        for svc in /etc/pam.d/*; do
          [ -f "$svc" ] || continue
          if grep -qs "pam_fprintd" "$svc"; then echo "  $(basename "$svc")"; fi
        done
        ;;
      list)
        list_raw "$user"
        ;;
      *)
        echo "usage: oligarchy-fingerprint {status|list} [user]" >&2
        exit 2
        ;;
    esac
  '';
in
{
  options.custom.oligarchyMcp = {
    enable = lib.mkEnableOption "the local read-only Oligarchy MCP server";

    flakeDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Directory of the Oligarchy flake the MCP inspects (read-only).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ oligarchy-mcp oligarchy-fingerprint ];
    environment.sessionVariables.OLIGARCHY_FLAKE_DIR = cfg.flakeDir;
  };
}
