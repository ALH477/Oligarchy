{ config, lib, pkgs, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Hermes MCP — registration module
# Installs the local read-only Hermes MCP server and points it at the system
# flake. stdio transport only: there is no network listener, no auth token,
# and no remote code fetch.
# ─────────────────────────────────────────────────────────────────────────────

let
  cfg = config.custom.hermesMcp;
  hermes-mcp = pkgs.callPackage ./hermes-mcp { };
in
{
  options.custom.hermesMcp = {
    enable = lib.mkEnableOption "the local read-only Hermes MCP server";

    flakeDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Directory of the Oligarchy flake the MCP inspects (read-only).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ hermes-mcp ];
    environment.sessionVariables.HERMES_MCP_FLAKE_DIR = cfg.flakeDir;
  };
}
