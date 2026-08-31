{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.custom.ciBuilder;
  platform = config.custom.platform;
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # modules/ci-builder.nix — the self-hosted CI build server.
  #
  # WHY THIS EXISTS. Every verification asset in this tree is opt-in: sixteen
  # `nix build .#<gate>` outputs and five `runNixOSTest` suites, none of which
  # any flake output or CI system references. They protect against the author
  # forgetting, which is exactly the moment they do not fire. This module makes
  # a machine that runs them on a schedule.
  #
  # THE PUBLIC-REPO PROBLEM, WHICH IS THE WHOLE DESIGN. ALH477/Oligarchy is a
  # public repository, and GitHub documents that self-hosted runners should not
  # be used with public repos: a pull request from a fork can execute arbitrary
  # code as the runner user. Three mitigations, and they are layered because no
  # single one is sufficient:
  #
  #   1. TRIGGERS. The workflows that target this machine never fire on
  #      `pull_request`. That lives in .github/workflows/, not here, but it is
  #      the load-bearing half — a runner cannot be reached by a job that never
  #      starts. See .github/workflows/gates.yml.
  #   2. EPHEMERAL. `ephemeral = true` below makes the runner deregister after
  #      a single job, so a job cannot leave state for the next one to find.
  #   3. ISOLATION. The `sandbox` runner exists for the one lane that DOES read
  #      untrusted pull-request content (the agent-review lane, which also holds
  #      API credentials). See the `sandbox` option's own note for why that lane
  #      and only that lane gets a VM.
  #
  # WHY THE GATE LANE IS NOT ALSO IN A VM. It is tempting to put every runner
  # inside a guest. Doing so breaks `plugins-tier2-runtime`: that gate already
  # boots a microVM inside a NixOS test VM, so a runner in a VM puts its inner
  # guest at L3. Its own test script asserts `test -e /dev/kvm` against a
  # fifteen-second boot budget whose comment says the budget "stops meaning
  # anything" under emulation (modules/oligarchy-plugins/flake.nix:530-540).
  # The gate lane only ever runs code already pushed to this repo, so the
  # trigger restriction is the appropriate control there and the VM is not.
  # ═══════════════════════════════════════════════════════════════════════════

  options.custom.ciBuilder = {
    enable = mkEnableOption ''
      the self-hosted GitHub Actions build server. Registers one or two
      ephemeral runners, enables nested virtualisation for the tier-2 plugin
      gate, and strips the desktop closure this host has no use for
    '';

    repoUrl = mkOption {
      type = types.str;
      default = "https://github.com/ALH477/Oligarchy";
      description = "Repository the runners register against.";
    };

    tokenFile = mkOption {
      # types.str, NOT types.path: a path literal copies the token into the
      # world-readable /nix/store. Same reasoning as custom.secrets.ageKeyFile.
      type = types.str;
      default = "/var/lib/secrets/github-runner-token";
      description = ''
        Absolute path to a file containing a GitHub runner registration token
        or a PAT. Provision it with sops-nix (custom.secrets) or by hand; it
        must never be a path literal, or it lands in the store.
      '';
    };

    nestedVirtualisation = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable nested KVM. Required by `nix build .#plugins-tier2-runtime`,
        which is the only gate that boots a guest inside a guest — every other
        VM gate needs plain KVM. The modprobe parameter is selected from
        custom.platform.cpu rather than hardcoded, so this follows the host.

        Note this is necessary but not sufficient: the CPU must also have
        nested virtualisation enabled in firmware.
      '';
    };

    maxJobs = mkOption {
      type = types.int;
      default = 4;
      description = ''
        Nix `max-jobs`. Kept modest by default because the VM gates are the
        memory spike, not the compile: the two-node p2p gates run two 2048 MiB
        guests each, and plugins-tier2-runtime runs 4096 MiB plus a 512 MiB
        inner guest. Four concurrent gate builds can ask for ~16 GiB of guest
        RAM before counting the build itself.
      '';
    };

    gc = {
      automatic = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Garbage-collect on a timer. On by default because this host realizes
          the entire system closure on every `nix build .#malwareScan` —
          measured at 4096 paths / 48.6 GiB in
          docs/p2p-substituter-roadmap.md §3.1 — and a build server that fills
          its disk fails every lane at once, in a way that reads like a broken
          test rather than a full disk.
        '';
      };

      olderThan = mkOption {
        type = types.str;
        default = "14d";
        description = "Passed to nix-collect-garbage --delete-older-than.";
      };
    };

    hostRunner = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          The gate runner: runs on the host, with real /dev/kvm. Serves the
          lanes that only ever execute code already in this repo.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "oligarchy-gates";
        description = "Runner name as it appears in the repository settings.";
      };

      labels = mkOption {
        type = types.listOf types.str;
        default = [ "nixos" "x86_64" "kvm" "nested-kvm" ];
        description = ''
          Labels the gate workflows select on. `self-hosted` is added by the
          runner itself and must not be listed here.
        '';
      };
    };

    sandbox = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          A SECOND runner for the agent-review lane, which is the only lane
          that reads pull-request content from forks and the only one holding
          model API credentials. Off by default because it needs the microVM
          host module (available through the oligarchy-plugins input) and a
          guest closure, so it is a deliberate opt-in rather than something a
          fresh clone silently builds.

          Kept separate from hostRunner rather than sharing one runner with
          more labels: a single runner would let a job that asked for the
          sandbox land on the host instead if the labels ever drifted, and
          that failure is silent.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "oligarchy-agents";
        description = "Runner name for the sandboxed lane.";
      };

      labels = mkOption {
        type = types.listOf types.str;
        default = [ "nixos" "sandboxed" ];
        description = ''
          Deliberately does NOT include `kvm`: nothing in the agent lane boots
          a VM, and advertising the capability would let a gate job schedule
          itself here.
        '';
      };

      memoryMiB = mkOption {
        type = types.int;
        default = 4096;
        description = "RAM for the sandbox guest.";
      };

      vcpu = mkOption {
        type = types.int;
        default = 2;
        description = "vCPUs for the sandbox guest.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.hostRunner.enable || cfg.sandbox.enable;
          message = ''
            custom.ciBuilder.enable is on but both runners are disabled, so
            this host registers nothing and no lane can be scheduled.
          '';
        }
        {
          # A gate that silently degrades to emulation is worse than one that
          # does not run: tier2's boot budget stops being a measurement.
          assertion = cfg.nestedVirtualisation || !cfg.hostRunner.enable;
          message = ''
            custom.ciBuilder.hostRunner is enabled with
            nestedVirtualisation = false. `nix build .#plugins-tier2-runtime`
            boots a microVM inside a NixOS test VM and asserts /dev/kvm exists
            in the inner guest; without nested KVM it falls back to emulation
            and its fifteen-second boot budget stops meaning anything.

            Either set custom.ciBuilder.nestedVirtualisation = true, or accept
            that this builder cannot run the tier-2 gate and exclude it from
            the nightly lane in .github/workflows/gates.yml.
          '';
        }
      ];

      # ── Nested virtualisation, vendor-selected ────────────────────────────
      # Driven by custom.platform.cpu so this file never learns the host's CPU
      # vendor; modules/platform.nix already carries that fact for four other
      # hosts and this is exactly the abstraction it exists for.
      boot.extraModprobeConfig = mkIf cfg.nestedVirtualisation (
        if platform.cpu == "amd"
        then "options kvm_amd nested=1"
        else "options kvm_intel nested=1"
      );

      # ── Headless ──────────────────────────────────────────────────────────
      # configuration.nix turns these on unconditionally for a workstation.
      # A build server has no display, and the desktop closure is a large
      # fraction of build time on a cold store.
      #
      # systemd.defaultUnit needs mkOverride 40, not mkForce: configuration.nix
      # already sets it with mkForce (priority 50), and two mkForce definitions
      # of the same option collide rather than one winning.
      programs.hyprland.enable = mkForce false;
      services.greetd.enable = mkForce false;
      services.boot-intro.enable = mkForce false;
      services.oligarchyGreeting.enable = mkForce false;
      systemd.defaultUnit = mkOverride 40 "multi-user.target";

      # Runtime services a builder does not want. Note what is NOT here:
      #   custom.oligarchyForge  — the agent lane runs through it
      #   custom.secrets         — provisions the runner token
      #   networking.firewall.strictEgress — already mkDefault false, and its
      #     autoDetect.nixSubstituters would otherwise need to learn about
      #     api.github.com before a runner could register
      services.ollamaAgentic.enable = mkForce false;
      custom.dcfCommunityNode.enable = mkForce false;
      custom.dcfIdentity.enable = mkForce false;
      services.dcf-tray.enable = mkForce false;
      custom.malwareShield.enable = mkForce false;
      custom.mcpServers.enable = mkForce false;
      custom.hydramesh.enable = mkForce false;

      # ── Nix daemon ────────────────────────────────────────────────────────
      # mkForce, not a plain value: configuration.nix pins max-jobs = 3 and
      # cores = 4 outright (not mkDefault), because on the Framework 16 the
      # defaults fanned out to sixteen cores and the OOM killer took the
      # machine. That reasoning is a laptop's, and this host is not one — a
      # build server is allowed to use itself. Two unprioritised definitions
      # of the same option are an eval error, so overriding has to be explicit.
      nix.settings = {
        max-jobs = mkForce cfg.maxJobs;
        # 0 = one job per available core. A VM gate is mostly a single long
        # QEMU run that will not use them, but the Rust and kernel builds
        # underneath the gates will.
        cores = mkForce 0;
        # The gates are this machine's entire product. Keeping the failed build
        # tree is the difference between a red nightly you can diagnose in the
        # morning and one you have to reproduce first.
        keep-failed = true;
        keep-going = true;
      };

      nix.gc = mkIf cfg.gc.automatic {
        automatic = true;
        dates = "daily";
        options = "--delete-older-than ${cfg.gc.olderThan}";
      };

      # The runner needs git, and the workflows shell out to jq for the job
      # summary. Both are cheap; leaving them implicit produces a failure that
      # looks like a workflow bug rather than a missing package.
      environment.systemPackages = with pkgs; [ git jq ];
    }

    # ── The gate runner ─────────────────────────────────────────────────────
    (mkIf cfg.hostRunner.enable {
      services.github-runners.${cfg.hostRunner.name} = {
        enable = true;
        url = cfg.repoUrl;
        tokenFile = cfg.tokenFile;
        # Deregister after one job. A gate lane leaves large build artifacts
        # and a populated working tree; ephemeral means the next job cannot
        # observe either.
        ephemeral = true;
        replace = true;
        extraLabels = cfg.hostRunner.labels;
        extraPackages = with pkgs; [ git jq nix ];

        # The runner must reach /dev/kvm, or every VM gate fails complaining
        # about missing hardware acceleration instead of about the thing under
        # test — a whole nightly of misleading red.
        #
        # Granted through SupplementaryGroups rather than by putting a user in
        # users.users: with `user`/`group` both left null this service runs
        # under a DYNAMICALLY allocated user, so there is no static account to
        # add to a group. Declaring one anyway does not extend the runner's
        # identity — it creates a second, unrelated user, and NixOS then fails
        # the build asking which of isSystemUser/isNormalUser it should be.
        serviceOverrides.SupplementaryGroups = [ "kvm" ];
      };
    })

    # ── The sandboxed agent runner ──────────────────────────────────────────
    (mkIf cfg.sandbox.enable {
      microvm.vms.${cfg.sandbox.name} = {
        config = {
          microvm = {
            hypervisor = "qemu";
            mem = cfg.sandbox.memoryMiB;
            vcpu = cfg.sandbox.vcpu;
          };

          system.stateVersion = config.system.stateVersion;

          services.github-runners.${cfg.sandbox.name} = {
            enable = true;
            url = cfg.repoUrl;
            tokenFile = cfg.tokenFile;
            ephemeral = true;
            replace = true;
            extraLabels = cfg.sandbox.labels;
            extraPackages = with pkgs; [ git jq nix ];
          };
        };
      };
    })
  ]);
}
