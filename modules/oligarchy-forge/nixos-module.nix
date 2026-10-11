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
  options.custom.oligarchyForge = {
    enable = mkEnableOption "oligarchy-forge sandboxed coding-agent runner";

    # The HOST-side posture. These are the defaults every forge project gets
    # when its oligarchy-forge.toml writes no [runtime.sandbox] table; the
    # per-project TOML can opt out per field (see forge-core's Sandbox).
    # The host-side defaults exist so a project that never heard of the
    # sandbox table still runs locked down — the alternative is a per-project
    # file being the only place the posture lives, which is exactly how a
    # "safe by default" flag ends up unsafe.
    sandbox = {
      readOnlyRootfs = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Host default for a forge project's container rootfs. `true` renders
          `--read-only` with tmpfs for /tmp and /var/tmp. A project overrides
          it with `read-only-rootfs = false` in its own [runtime.sandbox].
        '';
      };
      seccomp = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Host default for the seccomp profile. `true` applies the checked-in
          strict profile (forge-core's seccomp_strict.json, shipped in the
          image). A project overrides it with `seccomp = false`.
        '';
      };
      network = mkOption {
        type = types.enum [ "none" "host" ];
        default = "none";
        description = ''
          Host default for the container's network. `none` is `--network=none`:
          no egress at all, which is the correct default for a coding-agent
          sandbox. `host` restores the pre-sandbox behavior (full network
          namespace sharing). A project overrides it with
          `network = "host"` in its own [runtime.sandbox].
        '';
      };
      memoryMiB = mkOption {
        type = types.int;
        default = 4096;
        description = "Host default cgroup memory cap in MiB. 0 = unlimited.";
      };
      cpuPercent = mkOption {
        type = types.int;
        default = 400;
        description = "Host default CPU quota as percent of one core (400 = 4 cores). 0 = unlimited.";
      };
      pidsLimit = mkOption {
        type = types.int;
        default = 512;
        description = "Host default pids cgroup limit. 0 = unlimited.";
      };
    };
  };

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

    # The host-side sandbox defaults, exported into the user's environment so
    # the CLI's env layer (HostSandboxDefaults::from_env) picks them up.
    # These MATCH the forge-core built-in strict defaults, so the layer is a
    # no-op unless an admin deliberately changes one here. A per-project
    # oligarchy-forge.toml field always wins over these.
    environment.sessionVariables = {
      OLIGARCHY_FORGE_SANDBOX_READ_ONLY_ROOTFS = if cfg.sandbox.readOnlyRootfs then "true" else "false";
      OLIGARCHY_FORGE_SANDBOX_SECCOMP = if cfg.sandbox.seccomp then "true" else "false";
      OLIGARCHY_FORGE_SANDBOX_NETWORK_NONE = if cfg.sandbox.network == "none" then "true" else "false";
      OLIGARCHY_FORGE_SANDBOX_MEMORY_MIB = toString cfg.sandbox.memoryMiB;
      OLIGARCHY_FORGE_SANDBOX_CPU_PERCENT = toString cfg.sandbox.cpuPercent;
      OLIGARCHY_FORGE_SANDBOX_PIDS_LIMIT = toString cfg.sandbox.pidsLimit;
    };
  };
}
