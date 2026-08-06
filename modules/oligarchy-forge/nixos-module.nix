# ═══════════════════════════════════════════════════════════════════════════════
# oligarchy-forge — registration module
#
# Installs the `oligarchy-forge` CLI and turns on rootless Podman as its
# default container backend. This is a normal, on-demand user dev tool (same
# category as dsp-ctl/oligarchy-ctl) — NOT an MCP server, so it carries none
# of the .mcp.json / allowlist / self-audit obligations that
# modules/mcp-servers/ has. See docs/oligarchy-forge-roadmap.md.
#
# The top-level flake threads the `oligarchy-forge` sub-flake input through
# `specialArgs`. This module references `inputs.oligarchy-forge.packages.${pkgs.stdenv.hostPlatform.system}`.
# ═══════════════════════════════════════════════════════════════════════════════
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.custom.oligarchyForge;
  forge = inputs.oligarchy-forge;
  system = pkgs.stdenv.hostPlatform.system;
  package = forge.packages.${system}.default or (throw
    "oligarchy-forge sub-flake has no package for system ${system}"
  );
in
{
  options.custom.oligarchyForge.enable = mkEnableOption "oligarchy-forge sandboxed coding-agent runner";

  config = mkIf cfg.enable {
    environment.systemPackages = [ package ];

    # Rootless Podman as the default sandbox runtime. Kept in a separate
    # namespace from the host's rootless Docker (configuration.nix) —
    # dockerCompat off so `docker` keeps meaning the existing daemon, not a
    # podman shim.
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
    };
  };
}
