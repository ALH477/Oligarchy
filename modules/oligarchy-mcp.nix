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
    environment.systemPackages = [ oligarchy-mcp ];
    environment.sessionVariables.OLIGARCHY_FLAKE_DIR = cfg.flakeDir;
  };
}
