# Tier 2 guest. Runs inside the microVM, where the plugin's writable-executable
# pages are somebody else's problem — specifically, this kernel's.
#
# The guest runs the SAME plugind binary in `shim` mode with the tier rewritten
# to native, so the code path inside the VM is one we already test on the host.
# Nothing here is a second implementation.
{ config, lib, pkgs, ... }:

let cfg = config.custom.pluginGuest;
in {
  options.custom.pluginGuest = {
    enable = lib.mkEnableOption "the Oligarchy plugin guest agent";
    pluginId = lib.mkOption {
      type = lib.types.str;
      description = "Plugin this guest hosts. Becomes the shim's argument.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 5005;
      description = "vsock port. Must match GUEST_PORT in tiers/microvm.rs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # No users, no getty, no network. The guest exists to run one thing.
    services.getty.autologinUser = null;
    networking.firewall.enable = false;
    documentation.enable = false;
    system.stateVersion = lib.mkDefault "24.11";

    systemd.services.oligarchy-plugin-guest = {
      description = "Oligarchy plugin guest agent for ${cfg.pluginId}";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.oligarchy-plugind}/bin/plugind shim ${cfg.pluginId}";
        Restart = "no"; # if the plugin dies, the VM dies; the host reboots it
        # The guest kernel is the boundary, so the in-guest hardening is about
        # containing a buggy plugin rather than a hostile one. MDWE stays OFF
        # here: this is exactly where a self-JIT plugin is *supposed* to run.
        MemoryDenyWriteExecute = false;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        StateDirectory = "oligarchy/plugins";
      };
      environment.OLIGARCHY_VSOCK_PORT = toString cfg.port;
    };

    # Fail loudly rather than idling if the agent exits.
    systemd.services.oligarchy-plugin-guest.onFailure = [ "poweroff.target" ];
  };
}
