# Tier 2 guest. Runs inside the microVM, where the plugin's writable-executable
# pages are somebody else's problem — specifically, this kernel's.
#
# The guest runs the SAME plugind binary that runs on the host, in `guest` mode,
# and loads the artifact through the same NativePlugin the host uses for tier 1.
# Nothing in here is a second implementation of the ABI.
{ config, lib, pkgs, ... }:

let cfg = config.custom.pluginGuest;
in
{
  options.custom.pluginGuest = {
    enable = lib.mkEnableOption "the Oligarchy plugin guest agent";

    pluginId = lib.mkOption {
      type = lib.types.str;
      description = "Plugin this guest hosts. Becomes the agent's argument.";
    };

    storePath = lib.mkOption {
      type = lib.types.either lib.types.package lib.types.path;
      description = ''
        The plugin artifact. Passed explicitly rather than discovered: the guest
        has no registry — the host's is root-owned and not shared in — so the
        manifest comes from this path, which the guest can see because the Nix
        store is shared read-only.
      '';
    };

    policy = lib.mkOption {
      type = lib.types.path;
      description = ''
        The guest's policy.json. NOT the host's.

        It has to permit `native`, because that is how the artifact is loaded in
        here: the manifest says tier = "microvm", and honouring that inside the
        guest would mean booting another microVM. Everything else it carries —
        minTrust, forbiddenPaths, the memory and CPU ceilings — comes from the
        host's policy, so a plugin the host would have refused for any reason
        other than its tier is refused in here too.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5005;
      description = ''
        vsock port the agent listens on. Must match GUEST_PORT in
        tiers/microvm.rs, which static-asserts against guest.rs — a mismatch is
        otherwise a fifteen-second timeout with no explanation.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # No users, no getty, no network. The guest exists to run one thing.
    services.getty.autologinUser = null;
    networking.firewall.enable = false;
    documentation.enable = false;
    system.stateVersion = lib.mkDefault "25.11";

    environment.etc."oligarchy/plugins/guest-policy.json".source = cfg.policy;

    # sandbox::prepare builds a Landlock ruleset naming these, and a rule on a
    # path that does not exist is an error rather than a silent omission — so
    # they have to be here before the agent starts, exactly as on the host.
    systemd.tmpfiles.rules = [
      "d /var/lib/oligarchy/plugins 0750 root root -"
      "d /var/lib/oligarchy/plugins/state 0750 root root -"
      "d /var/lib/oligarchy/plugins/state/${cfg.pluginId} 0750 root root -"
      "d /var/lib/oligarchy/plugins/config 0750 root root -"
      "d /var/lib/oligarchy/plugins/config/${cfg.pluginId} 0750 root root -"
    ];

    systemd.services.oligarchy-plugin-guest = {
      description = "Oligarchy plugin guest agent for ${cfg.pluginId}";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
      requires = [ "systemd-tmpfiles-setup.service" ];

      serviceConfig = {
        Type = "exec";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.oligarchy-plugind}/bin/plugind"
          "guest"
          "--store-path ${cfg.storePath}"
          "--guest-policy /etc/oligarchy/plugins/guest-policy.json"
          cfg.pluginId
        ];
        # If the plugin dies the VM is useless, and the host notices the vsock
        # closing. Restarting in here would hide that from the host.
        Restart = "no";

        # MemoryDenyWriteExecute stays OFF, deliberately and without apology:
        # this is the one place in the whole design a self-JIT plugin is
        # *supposed* to have writable-executable memory. The boundary here is the
        # guest kernel, not a seccomp filter. The rest of the hardening below is
        # about containing a buggy plugin, not a hostile one — a hostile one that
        # has not yet found a hypervisor bug is contained by it too, which is
        # worth having for free.
        MemoryDenyWriteExecute = false;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/oligarchy/plugins" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };

    # Fail loudly rather than idling if the agent exits: a guest sitting at a
    # login prompt with no plugin in it is a VM the host will wait on forever.
    systemd.services.oligarchy-plugin-guest.onFailure = [ "poweroff.target" ];
  };
}
