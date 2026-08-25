{ config, options, lib, pkgs, ... }:

let
  cfg = config.custom.plugins;

  inherit (lib) mkOption mkEnableOption mkIf mkMerge types optional optionals
    optionalString concatStringsSep mapAttrsToList filterAttrs
    literalExpression;

  # ── the shape of a declaratively-pinned plugin ──────────────────────────
  #
  # Note what this submodule is NOT: it is not how most plugins get installed.
  # It is the escape hatch for the first-party set you want reproducible and
  # rollback-able with the rest of the system. Everything else arrives through
  # `plugind install` at runtime and lives in the mutable registry.
  pluginModule = { name, config, ... }: {
    options = {
      artifact = mkOption {
        type = types.either types.package types.path;
        description = ''
          Derivation or store path containing plugin.toml and the entry
          artifact. Content-addressed, GC-rooted by plugind on activation.
        '';
      };

      tier = mkOption {
        type = types.enum [ "wasm" "native" "lua" "microvm" ];
        default = "wasm";
        description = ''
          Execution tier.

          wasm    - wasmtime component. Host JITs via Cranelift; the guest
                    never requests executable pages. Default and correct
                    answer for anything you did not write.
          native  - dlopen'd .so behind the C vtable, under
                    bwrap + landlock + seccomp. For DSP that cannot afford
                    the Wasm boundary.
          lua     - mlua/LuaJIT, same sandbox as native. Control and glue,
                    not the audio hot path.
          microvm - separate guest kernel via microvm.nix. The only honest
                    place for untrusted code that ships its own JIT.
        '';
      };

      jit = mkOption {
        type = types.enum [ "none" "host" "self" ];
        default = "none";
        description = ''
          Where code generation happens.

          none - no runtime codegen. MemoryDenyWriteExecute=yes, and
                 memfd_create is denied so the dual-mapping bypass is closed.
          host - Cranelift compiles the plugin in the host address space.
                 The guest is still fully W^X-confined.
          self - the plugin carries its own code generator and needs
                 writable-then-executable memory. MemoryDenyWriteExecute=no
                 for this instance only. Requires allowSelfJit.
        '';
      };

      trust = mkOption {
        type = types.enum [ "first-party" "trusted" "untrusted" ];
        default = "untrusted";
        description = ''
          Provenance. Defaults to untrusted because an omitted trust level is
          the most suspicious possible input.
        '';
      };

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Start on boot via the generated wants= entry.";
      };

      settings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Rendered to /var/lib/oligarchy/plugins/config/''${name}/config.toml
          and reachable from the plugin through host.read-config. Never put
          secrets here; use sops-nix and a device capability instead.
        '';
      };

      caps = {
        fsRead = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = literalExpression ''[ "/etc/demod/presets" "$STORE" ]'';
          description = ''
            Read-only paths. `$STATE`, `$CONFIG` and `$STORE` expand at load
            time. Checked against policy.forbiddenPaths before Landlock sees
            them.
          '';
        };
        fsReadWrite = mkOption {
          type = types.listOf types.str;
          default = [ "$STATE" ];
        };
        network = mkOption { type = types.bool; default = false; };
        tcpConnect = mkOption {
          type = types.listOf types.port;
          default = [ ];
          description = ''
            TCP ports the plugin may connect to. Requires Landlock ABI >= 4
            (kernel 6.7); below that the netns is the only enforcement and
            an empty list means all-or-nothing.
          '';
        };
        devices = mkOption {
          # Mirrors the device check in Manifest::validate(). Constrained at the
          # type level because these strings are interpolated into a systemd
          # drop-in (`DeviceAllow=<dev> rw`) that root writes and systemd
          # parses: a newline followed by `User=root` would override the
          # template's unprivileged User= and start the plugin as root.
          type = types.listOf (types.strMatching "^/dev/[A-Za-z0-9._/-]+$");
          default = [ ];
          example = literalExpression ''[ "/dev/snd/seq" ]'';
          description = ''
            Device nodes the plugin may open, as absolute paths under /dev.
            Each becomes a DeviceAllow= line in the instance's sandbox drop-in
            and a --dev-bind-try in its bwrap namespace.
          '';
        };
        hostServices = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Names visible to the plugin through host.has-capability.";
        };
        memoryMax = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Bytes. Enforced by cgroup v2 and, for wasm, StoreLimits.";
        };
        cpuQuota = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Percent of one core. 100 = one full core.";
        };
      };
    };
  };

  enabledPlugins = filterAttrs (_: p: p.autoStart) cfg.declaredPlugins;

  # "The bwrap tiers" governs which systemd directives a drop-in needs, whether
  # bubblewrap belongs on a unit's PATH, and which tiers get compiled into
  # plugind at all. Named because spelling it out inline in six places is how
  # this module and its Rust mirror drifted apart. Mirrors Manifest::uses_bwrap.
  bwrapTiers = [ "native" "lua" ];
  usesBwrap = tier: builtins.elem tier bwrapTiers;
  anyBwrapTier = lib.any (t: builtins.elem t cfg.allowedTiers) bwrapTiers;

  # Must stay in lockstep with Manifest::wx_enforced() in host/src/manifest.rs.
  # It is NOT `jit != "self"`: the unit hosts plugind, and for tier=wasm
  # plugind is running Cranelift, which needs mprotect(PROT_EXEC) to publish
  # compiled code. MDWE on a Tier 0 unit hardens nothing (a wasm guest cannot
  # syscall) and breaks compilation.
  wxEnforced = p:
    if p.tier == "wasm" then false
    else if p.tier == "microvm" then true
    else p.jit != "self";

  # True only when W^X is off *because the plugin asked*, which is the case
  # that needs auditing.
  grantsWx = p: p.jit == "self" && usesBwrap p.tier;

  # ── policy.json: the machine owner's answer to the manifest's request ────
  policyFile = pkgs.writeText "oligarchy-plugin-policy.json" (builtins.toJSON {
    allow_self_jit = cfg.allowSelfJit;
    allow_microvm = cfg.microvm.enable;
    min_trust = cfg.minTrust;
    allowed_tiers = cfg.allowedTiers;
    require_signature = cfg.requireSignature;
    # The ONLY keys plugind will accept a signature from. Not the same list as
    # nix.settings.trusted-public-keys, which legitimately also carries
    # cache.nixos.org: a plugin signed by cache.nixos.org is not a plugin this
    # host approved.
    trusted_public_keys = cfg.trustedPublicKeys;
    max_memory = cfg.limits.memoryMax;
    max_cpu_quota = cfg.limits.cpuQuota;
    forbidden_paths = cfg.forbiddenPaths;
    allow_network = cfg.allowNetwork;
  });

  # The manifest a declared plugin gets, so declarative and imperative
  # plugins are described by exactly the same schema and go through exactly
  # the same authorize() path. No second code path, no second set of bugs.
  mkManifest = name: p: pkgs.writeText "plugin-${name}.toml" ''
    id = "${name}"
    version = "${p.artifact.version or "0"}"
    tier = "${p.tier}"
    jit = "${p.jit}"
    trust = "${p.trust}"
    entry = "${p.artifact.pluginEntry or "module.wasm"}"
    abi = "oligarchy:plugin@0.1.0"

    [caps]
    fs_read = ${builtins.toJSON p.caps.fsRead}
    fs_read_write = ${builtins.toJSON p.caps.fsReadWrite}
    network = ${lib.boolToString p.caps.network}
    tcp_connect = ${builtins.toJSON p.caps.tcpConnect}
    devices = ${builtins.toJSON p.caps.devices}
    host_services = ${builtins.toJSON p.caps.hostServices}
    ${optionalString (p.caps.memoryMax != null) "memory_max = ${toString p.caps.memoryMax}"}
    ${optionalString (p.caps.cpuQuota != null) "cpu_quota = ${toString p.caps.cpuQuota}"}
  '';

  # ── the per-instance sandbox drop-in, at BUILD time for declared plugins ─
  #
  # For imperative plugins plugind writes the equivalent into
  # /run/systemd/system/... at enable time. Same content, same generator
  # logic, different lifetime: /run is tmpfs, so an imperative grant of W^X
  # cannot survive a reboot without the registry re-authorising it.
  #
  # Declared plugins go through `systemd.units.<unit>.overrideStrategy =
  # "asDropin"`, which lands the file at
  # /etc/systemd/system/<unit>.d/overrides.conf. NOT environment.etc: on NixOS
  # /etc/systemd/system is a symlink into the store, so nothing can be placed
  # underneath it. (/run beats /etc in systemd's drop-in precedence anyway, so
  # the imperative path still wins for a plugin that is both declared and
  # installed — which is the right way round.)
  mkDropin = name: p:
    let
      # The three tiers do not want the same directives, and "the bwrap tiers"
      # is the distinction that keeps coming up.
      bwrapTier = usesBwrap p.tier;
    in
    {
      "oligarchy-plugin@${name}.service" = {
        overrideStrategy = "asDropin";
        text = ''
          # Generated by custom.plugins.declaredPlugins.${name}
          #
          # MIRROR of registry::write_dropin() in host/src/registry.rs. That one
          # serves imperative plugins into /run; this one serves declared
          # plugins into /etc. Every directive below has to appear in both, and
          # they have drifted before: NotifyAccess and the AF_NETLINK branch
          # each reached the Rust side alone, which nothing would have caught
          # because checks.wx-enforcement only asserts the MDWE line and no
          # declared plugin exists anywhere in this repo to exercise the rest.
          [Service]
          MemoryDenyWriteExecute=${if wxEnforced p then "yes" else "no"}
          ${optionalString (p.tier == "wasm") ''
            # tier=wasm: MDWE is off because THIS process runs Cranelift. The
            # guest is confined by wasmtime, not by seccomp; setting MDWE here
            # would break compilation without hardening anything.
          ''}
          ${optionalString (grantsWx p) ''
            # jit=self: W^X deliberately off for this instance. Executable-memory
            # confinement is delegated to landlock + cgroups + namespaces.
          ''}
          ${
          # ProtectKernelTunables: bwrap mounts its own /proc, and the kernel
          #   refuses mount("proc") in a userns when a submount of the outer
          #   /proc is locked read-only — which is what this directive does. Off,
          #   the plugin still has a fresh procfs, no capabilities, and a
          #   Landlock ruleset that does not name /proc.
          # NotifyAccess: MainPID is bwrap, but the plugind shim it forks is what
          #   becomes ready, and `main` (the default) discards a notification
          #   from anything else. `exec` does not help — it still means MainPID
          #   plus ExecStart* processes, not a grandchild.
          # Both are explained at length in docs/plugins-roadmap.md. Kept OUT of
          # the emitted text: `systemctl cat` should show directives, not essays.
          optionalString bwrapTier ''
            # tier 1: bwrap supplies /proc, and forks the process that reports ready
            ProtectKernelTunables=no
            NotifyAccess=all
          ''}
          ${optionalString (p.caps.memoryMax != null) ''
            MemoryMax=${toString p.caps.memoryMax}
            MemorySwapMax=0
          ''}
          ${optionalString (p.caps.cpuQuota != null) "CPUQuota=${toString p.caps.cpuQuota}%"}
          DevicePolicy=closed
          ${concatStringsSep "\n" (map (d: "DeviceAllow=${d} rw") p.caps.devices)}
          ${optionalString (!p.caps.network) ''
            PrivateNetwork=yes
            ${
              # AF_NETLINK for the bwrap tiers and only for them: bwrap brings
              # up loopback inside the netns it creates and needs a
              # NETLINK_ROUTE socket to do it, so denying it fails the sandbox
              # before the plugin loads, with an error that reads like a kernel
              # problem. The namespace is empty and the process holds no
              # capabilities, so there is nothing in there to configure but lo.
              "RestrictAddressFamilies=AF_UNIX"
              + optionalString bwrapTier " AF_NETLINK"
            }
          ''}
        '';
      };
    };

in
{
  options.custom.plugins = {
    enable = mkEnableOption "the Oligarchy tiered plugin runtime";

    package = mkOption {
      type = types.package;
      # Per tier, not per "bwrap tier": allowing lua but not native should drop
      # libloading, and allowing native but not lua should drop mlua and LuaJIT.
      # This is the one place the finer distinction is the point.
      default = pkgs.oligarchy-plugind.override {
        withNativeTier = builtins.elem "native" cfg.allowedTiers;
        withLuaTier = builtins.elem "lua" cfg.allowedTiers;
      };
      defaultText = literalExpression ''
        pkgs.oligarchy-plugind.override {
          withNativeTier = builtins.elem "native" config.custom.plugins.allowedTiers;
          withLuaTier    = builtins.elem "lua"    config.custom.plugins.allowedTiers;
        }
      '';
      description = ''
        The supervisor. By default the tiers this host does not allow are
        compiled out rather than merely refused at runtime — which is the point
        of the crate's tier features: on a wasm-only host, libloading, mlua and
        the vendored LuaJIT are not in the closure at all, so there is nothing
        for a policy bug to reach.
      '';
    };

    user = mkOption { type = types.str; default = "oligarchy"; };
    group = mkOption { type = types.str; default = "oligarchy"; };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/oligarchy/plugins";
      description = ''
        The mutable half of the system: the registry, per-plugin state,
        per-plugin config, and the GC roots that stop `nix store gc` from
        deleting an installed plugin out from under a running rig.
      '';
    };

    # ── the security dials ────────────────────────────────────────────────

    allowedTiers = mkOption {
      type = types.listOf (types.enum [ "wasm" "native" "lua" "microvm" ]);
      default = [ "wasm" ];
      description = ''
        Tiers permitted on this host. The default is wasm-only, which is the
        posture a stage rig or a shipped guitar should have: every plugin is
        memory-safe by construction and no plugin can obtain executable pages.
        Add "native" when you need CLAP/LV2/Faust-native DSP on the hot path.
      '';
    };

    allowSelfJit = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Master switch for plugin-supplied JITs.

        When false, no plugin on this machine gets writable-executable memory
        at any trust level, and MemoryDenyWriteExecute is unconditional.

        When true, plugins whose manifest declares jit = "self" run without
        the W^X seccomp filter. Understand what that means before enabling it:
        systemd's MemoryDenyWriteExecute is bypassable by construction through
        memfd_create plus two mappings of the same fd (one PROT_WRITE, one
        PROT_EXEC), which is precisely the mechanism a JIT uses. So enabling
        this does not merely relax a check, it concedes the category. The
        compensating controls are Landlock, the namespaces, the cgroup caps,
        and — for anything untrusted — forced routing to tier=microvm.
      '';
    };

    minTrust = mkOption {
      type = types.enum [ "first-party" "trusted" "untrusted" ];
      default = "untrusted";
      description = ''
        Least-trusted provenance this host will load. Set to "trusted" to
        refuse anything unsigned by a known author, or "first-party" to
        refuse everything not built in your own flake.

        Read this as a filter on a *claim*, not a boundary: `trust` is a field
        in the plugin's own plugin.toml, so an author who wants past
        minTrust = "first-party" writes trust = "first-party". What makes the
        claim mean anything is that the manifest sits inside a store path
        somebody signed — so the real statement is "the key that signed this
        asserted first-party". Deriving trust from the signing key's identity
        rather than from the payload is the correct fix and is not done yet; see
        docs/plugins-roadmap.md.
      '';
    };

    requireSignature = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Refuse to register a store path without a valid signature from
        trustedPublicKeys.

        With this true and trustedPublicKeys empty, nothing can be registered
        at all. That is not a misconfiguration — it is the most locked-down
        state this module has, and the correct posture for a host that runs the
        plugin runtime but has not yet been given a plugin source. The build
        only refuses the genuinely incoherent case: a configured substituter
        whose signatures no key on this host can check.
      '';
    };

    allowNetwork = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether `network = true` in a manifest is a request or an error.
      '';
    };

    forbiddenPaths = mkOption {
      type = types.listOf types.str;
      default = [
        "/etc/ssh"
        "/etc/shadow"
        "/var/lib/sops"
        "/run/secrets"
        "/root"
        "/home"
      ];
      description = ''
        Prefixes no plugin may name in its capabilities, even read-only.
        Checked before Landlock, so a manifest naming one of these fails to
        load rather than loading with a ruleset that quietly omits it.
      '';
    };

    limits = {
      memoryMax = mkOption { type = types.int; default = 256 * 1024 * 1024; };
      cpuQuota = mkOption { type = types.int; default = 100; };
    };

    # ── the imperative half's trust anchors ───────────────────────────────

    substituters = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "https://cache.demod.ltd" ]'';
      description = ''
        Binary caches plugins may be fetched from. These go into
        nix.settings.substituters and .trusted-substituters, NOT trusted-users.

        This distinction is the whole trust model. Per the Nix manual, adding
        a user to trusted-users is equivalent to giving that user root. So an
        unprivileged user must never need to be trusted in order to install a
        plugin. Instead the cache is trusted, its key is pinned below, and
        every path is verified before it is registered.
      '';
    };

    trustedPublicKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "cache.demod.ltd-1:AAAA..." ]'';
      description = ''
        Keys whose signatures make a store path installable. They go into
        nix.settings.trusted-public-keys, merging with — rather than replacing —
        whatever else the system already trusts.

        This is the trust anchor for the entire imperative half: plugind
        `nix store verify`s every path against these before registering it, and
        with requireSignature set no CLI flag can talk it out of that.
      '';
    };

    installGroup = mkOption {
      type = types.str;
      default = "oligarchy-plugins";
      description = ''
        Group owning the control socket, and therefore the set of accounts that
        may ask the supervisor to install a signed plugin.

        Deliberately NOT custom.plugins.group: that is the group the runtime
        runs as, and its members can read every plugin's state directory.
        Membership conveys the install-time verbs and nothing else: install,
        remove, enable, disable, list. The request format has no way to ask for
        signature checking to be skipped, so it is not a route to running
        arbitrary code — but it is not scoped per-account either. A member can
        remove or disable another member's plugin, and installing a same-id
        artifact replaces the existing entry. That is consistent with a
        single-operator machine and worth knowing before handing it out on one
        that is not. `purge`, which deletes a plugin's presets, is deliberately
        not reachable over the socket at all.
      '';
    };

    installers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ config.custom.user.name ]'';
      description = ''
        Accounts added to installGroup, i.e. accounts that can run
        `plugind install` without being root.

        This is the option that exists so that nix.settings.trusted-users does
        not have to be — see the `substituters` description for why that
        distinction is the whole trust model. If you find yourself reaching for
        trusted-users to make a plugin install work, this is the option you
        actually wanted.
      '';
    };

    microvm = {
      enable = mkEnableOption ''
        tier=microvm. Requires KVM and the microvm.nix host module. This is
        where untrusted plugins that ship their own JIT go: roughly 125 ms of
        Firecracker boot and a few MiB of VMM overhead buys a separate guest
        kernel, which is the only honest answer for W+X memory you did not
        write
      '';
      hypervisor = mkOption {
        type = types.enum [ "firecracker" "cloud-hypervisor" "qemu" "crosvm" ];
        default = "cloud-hypervisor";
        description = ''
          firecracker is the fastest boot and smallest attack surface;
          cloud-hypervisor trades a little of both for device breadth.
        '';
      };
      vcpu = mkOption { type = types.int; default = 1; };
      mem = mkOption { type = types.int; default = 128; };
    };

    declaredPlugins = mkOption {
      type = types.attrsOf (types.submodule pluginModule);
      default = { };
      description = ''
        Plugins pinned in the system closure. Use for the first-party set you
        want to roll back with everything else. The FX Bazaar case is the
        other one: `plugind install` at runtime, no rebuild.
      '';
    };
  };

  # The tier 2 block at the end of this list is gated twice, and the two are not
  # interchangeable. `optional (options ? microvm)` gates its *presence*: the
  # module system resolves definition paths against declared options before it
  # evaluates any mkIf, so even an mkIf-false block naming `microvm.*` fails
  # with "The option `microvm' does not exist" on a host without microvm.nix.
  # It has to test `options` and not `config`, because deciding the shape of
  # `config` from a value inside `config` is an infinite recursion.
  # `mkIf cfg.microvm.enable` then gates whether this host wants tier 2.
  config = mkIf cfg.enable
    (mkMerge ([
      {
        # ── assertions: catch at build time what would be a runtime refusal ──
        assertions = [
          {
            assertion = cfg.allowSelfJit -> (cfg.microvm.enable
              || !(lib.any (p: p.jit == "self" && p.trust == "untrusted")
              (lib.attrValues cfg.declaredPlugins)));
            message = ''
              custom.plugins: an untrusted plugin declares jit = "self" but
              microvm is not enabled. Granting writable-executable memory to
              unreviewed code on the host is the one thing this design refuses
              to do. Either set custom.plugins.microvm.enable = true, or raise
              the plugin's trust level after actually reviewing it.
            '';
          }
          {
            assertion = lib.all (p: builtins.elem p.tier cfg.allowedTiers)
              (lib.attrValues cfg.declaredPlugins);
            message = ''
              custom.plugins: a declared plugin uses a tier not in
              allowedTiers (${concatStringsSep ", " cfg.allowedTiers}).
            '';
          }
          {
            assertion = lib.all (p: p.tier != "microvm" || cfg.microvm.enable)
              (lib.attrValues cfg.declaredPlugins);
            message = ''
              custom.plugins: a declared plugin uses tier = "microvm" but
              custom.plugins.microvm.enable is false, so no guest would be
              generated and the plugin would fail to load at runtime.
            '';
          }
          {
            assertion = !(lib.any (p: p.tier == "wasm" && p.jit == "self")
              (lib.attrValues cfg.declaredPlugins));
            message = ''
              custom.plugins: tier = "wasm" with jit = "self" is incoherent.
              A Wasm guest has no way to obtain executable pages; Cranelift in
              the host does the compiling. Use jit = "host", or move the plugin
              to tier = "native".
            '';
          }
          {
            assertion = anyBwrapTier
              -> (config.security.unprivilegedUsernsClone or true);
            message = ''
              custom.plugins: tiers native/lua need bubblewrap, which needs
              unprivileged user namespaces since its setuid mode was removed.
              Set security.unprivilegedUsernsClone = true, or restrict
              allowedTiers to [ "wasm" ].

              Note that option only writes kernel.unprivileged_userns_clone,
              which exists solely on kernels carrying the Debian patch (zen and
              xanmod do). Elsewhere the governing knob is
              user.max_user_namespaces; `plugind doctor` reports both.
            '';
          }
          {
            assertion = cfg.microvm.enable -> options ? microvm;
            message = ''
              custom.plugins.microvm.enable is true but the microvm.nix host
              module is not imported, so no guest could ever be built. Add
              microvm.nix as a flake input and import its nixosModules.host
              alongside oligarchy-plugins.nixosModules.plugins — see the tier 2
              note in modules/oligarchy-plugins/flake.nix.
            '';
          }
          {
            assertion = cfg.requireSignature
              -> (cfg.substituters == [ ] || cfg.trustedPublicKeys != [ ]);
            message = ''
              custom.plugins: substituters are configured and requireSignature is
              true, but trustedPublicKeys is empty — so the cache can serve paths
              that nothing on this host can verify. Add the cache's public key.
            '';
          }
        ];

        warnings =
          optional (cfg.allowSelfJit) ''
            custom.plugins.allowSelfJit is enabled, so a plugin declaring
            jit = "self" will run without MemoryDenyWriteExecute. Note that this
            concedes the category rather than merely relaxing a check: MDWE is
            bypassable via memfd_create plus two mappings of the same fd, which
            is exactly what a JIT does. Audit with `plugind lint`.
          ''
          ++ optional
            (lib.any (u: u != "root" && u != "@wheel")
              (config.nix.settings.trusted-users or [ ]))
            ''
              custom.plugins: nix.settings.trusted-users lists someone other than
              root. Per the Nix manual that is equivalent to giving those
              accounts root, so signature checking here is decorative for them —
              they can add their own substituters and keys and rebuild nothing.
              Use custom.plugins.installers instead: it grants only the ability
              to ask the supervisor for a signature-checked install.
            ''
          ++ optional (cfg.minTrust == "untrusted" && cfg.allowedTiers != [ "wasm" ])
            ''
              custom.plugins: minTrust = "untrusted" together with a non-wasm
              tier means unreviewed native code can load. That is a defensible
              choice on a workstation and a bad one on a stage rig.
            '';

        environment.systemPackages = [ cfg.package ];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = cfg.stateDir;
          description = "Oligarchy plugin runtime";
        };

        users.groups.${cfg.group} = { };
        # The install group exists whether or not anyone is in it: plugind
        # chowns the control socket to it at startup, so it has to resolve.
        #
        # `members` rather than writing extraGroups into each installer's
        # users.users entry: this module has no business defining accounts it
        # does not own, and a partial submodule per installer is a merge-conflict
        # surface with wherever those accounts are really declared.
        users.groups.${cfg.installGroup}.members = cfg.installers;

        environment.etc."oligarchy/plugins/policy.json".source = policyFile;

        # One sandbox drop-in per declared plugin. See mkDropin.
        systemd.units = lib.foldl' (acc: x: acc // x) { }
          (mapAttrsToList mkDropin cfg.declaredPlugins);

        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir}            0750 ${cfg.user} ${cfg.group} -"
          # root-owned, group-readable. The registry is the INPUT to
          # write_dropin(), which root interpolates into a systemd drop-in — so
          # a plugin user who could write it could inject `User=root` into its
          # own unit and have the next reconcile apply it. Instances still need
          # to read it (`plugind run %i`), hence 0750 root:${cfg.group}.
          "d ${cfg.stateDir}/registry   0750 root ${cfg.group} -"
          "d ${cfg.stateDir}/state      0750 ${cfg.user} ${cfg.group} -"
          "d ${cfg.stateDir}/config     0750 ${cfg.user} ${cfg.group} -"
          "d ${cfg.stateDir}/gcroots    0750 ${cfg.user} ${cfg.group} -"
        ] ++ lib.concatLists (mapAttrsToList
          (name: p: [
            # The directory has to exist before the symlink rule runs; tmpfiles
            # applies rules in order within a file but will not create parents.
            "d ${cfg.stateDir}/state/${name}   0750 ${cfg.user} ${cfg.group} -"
            "d ${cfg.stateDir}/config/${name}  0750 ${cfg.user} ${cfg.group} -"
            "L+ ${cfg.stateDir}/config/${name}/manifest.toml - - - - ${mkManifest name p}"
          ])
          cfg.declaredPlugins);

        # Trusted caches, NOT trusted users. See the substituters option docs.
        #
        # Both substituter lists, and they are not redundant. `substituters` is
        # what Nix consults by default, so without it `plugind install` would
        # never fetch from the plugin cache at all. `trusted-substituters` is
        # the separate list an *untrusted* user is permitted to select
        # explicitly, which keeps a hand-run `nix build --substituters ...`
        # working for an installer. Neither grants anything by itself: a path is
        # accepted only if signed by a key in trusted-public-keys.
        #
        # These are definitions, not defaults, so they merge with nixpkgs' own
        # (cache.nixos.org and its key) rather than replacing them.
        nix.settings = {
          substituters = cfg.substituters;
          trusted-substituters = cfg.substituters;
          trusted-public-keys = cfg.trustedPublicKeys;
        };

        # ── the supervisor ──────────────────────────────────────────────────
        systemd.services.oligarchy-plugind = {
          description = "Oligarchy plugin supervisor";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "nix-daemon.service" ];
          path = [ pkgs.nix pkgs.systemd ]
            ++ optional
            anyBwrapTier
            pkgs.bubblewrap;

          serviceConfig = {
            Type = "notify";
            ExecStart = "${cfg.package}/bin/plugind --control-group ${cfg.installGroup} daemon";
            ExecReload = "${cfg.package}/bin/plugind reconcile";

            # Deliberately root, and deliberately narrow about why. The
            # supervisor's privileged job is precisely two things: write the
            # per-instance sandbox drop-in into /run/systemd/system and reload
            # the manager. Neither is available to an unprivileged user, and
            # reconcile() does both on every boot — regenerating the drop-ins
            # from the registry is what makes a W^X grant unable to outlive the
            # decision to make it. Group is ${cfg.group} so the plugin instances,
            # which are NOT root, can reach the runtime directory.
            #
            # Two things follow from that being the *whole* list. The plugins
            # themselves run as ${cfg.user} under the oligarchy-plugin@ template
            # below, so nothing plugin-supplied executes in this unit. And the
            # install path — `nix build` of a caller-supplied installable, plus
            # `nix store verify` and the registry write — deliberately does NOT
            # run with this unit's privilege: plugind drops those subprocesses
            # to the state directory's owner, because evaluating an
            # attacker-chosen flake as root would be root code execution however
            # narrow the request format is. See nix_cmd() in
            # host/src/registry.rs.
            Group = cfg.group;
            Restart = "on-failure";
            RestartSec = 2;

            # The supervisor's OWN runtime directory, not the one the plugin
            # instances share. systemd chowns a RuntimeDirectory to the unit's
            # User and deletes it when the unit stops, so a socket living in the
            # instances' directory would (a) be unlinked whenever any plugin was
            # disabled — letting any installer break the install path with one
            # legitimate request — and (b) end up owned by the unprivileged
            # plugin user, who could then replace it with their own listener.
            #
            # 0755 so a member of installGroup, deliberately not in
            # ${cfg.group}, can traverse to the socket. The directory mode is
            # not the boundary; the socket's own 0660 and its group are, and
            # plugind sets both at bind time.
            RuntimeDirectory = "oligarchy/plugind";
            RuntimeDirectoryMode = "0755";

            # The supervisor is reachable from an unprivileged socket, so it
            # gets the bounds a network-facing service would. Without them a
            # group member can spend the machine on concurrent `nix build`s.
            MemoryMax = "2G";
            TasksMax = 128;
            # Files land 0640 — registry.json stays readable by ${cfg.group},
            # which the instances need — and the control socket's mode before
            # plugind chmods it is 0750, so there is no window in which anyone
            # else could connect.
            UMask = "0027";

            NoNewPrivileges = true;
            ProtectSystem = "strict";
            # ProtectSystem=strict makes the whole hierarchy read-only, /run
            # included, so the two writable paths have to be named. This list is
            # the supervisor's entire write authority over the system; keep it
            # that short. StateDirectory is deliberately not used here: tmpfiles
            # owns the state layout below and creates it as ${cfg.user}, which
            # systemd would chown back to root.
            ReadWritePaths = [ cfg.stateDir "/run/systemd/system" ];
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = false; # the audio graph needs SCHED_FIFO
            LockPersonality = true;
            # The supervisor itself never JITs. Its children may; that is
            # decided per-instance in the drop-ins.
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
          };
        };

        # ── the per-plugin template ─────────────────────────────────────────
        #
        # Everything common lives here so there is one place to audit. The only
        # things that vary per instance are in the drop-in: MemoryDenyWriteExecute,
        # the cgroup caps, the device allowlist, and PrivateNetwork.
        systemd.services."oligarchy-plugin@" = {
          description = "Oligarchy plugin %i";
          after = [ "oligarchy-plugind.service" ];
          bindsTo = [ "oligarchy-plugind.service" ];

          # A plugin that crashloops is a plugin that gets to stop.
          #
          # These live in [Unit], not [Service]. In serviceConfig they produced
          # "Unknown key 'StartLimitIntervalSec' in section [Service], ignoring"
          # on every start — systemd said so out loud and the rate limit simply
          # did not exist.
          startLimitBurst = 3;
          startLimitIntervalSec = 60;

          # Same gate as the supervisor's path above: an unconditional
          # bubblewrap here would put it and its closure on a wasm-only host,
          # which is exactly what deriving `package` from allowedTiers exists
          # to avoid.
          path = optionals
            anyBwrapTier [ pkgs.bubblewrap ];

          serviceConfig = {
            Type = "notify";
            # Explicit because the bwrap tiers need NotifyAccess=all (see the
            # drop-in generator), which lets any process in the unit's cgroup —
            # i.e. the plugin — speak the notify protocol. Most of that protocol
            # is self-harm at worst: READY and STATUS are cosmetic, MAINPID is
            # validated against the unit's own cgroup, and there is no watchdog.
            # FDSTORE is the exception worth pinning, because "systemd holds
            # file descriptors this plugin handed it across a restart" is a
            # different shape of thing entirely. The default is already 0;
            # saying so keeps it 0 when someone later adds a fd store for an
            # unrelated reason.
            FileDescriptorStoreMax = 0;
            ExecStart = "${cfg.package}/bin/plugind run %i";
            User = cfg.user;
            Group = cfg.group;
            Restart = "on-failure";
            RestartSec = 5;

            StateDirectory = "oligarchy/plugins";
            # Match the tmpfiles rules below; systemd's default is 0755, which
            # would widen the state directory on first start of any instance.
            StateDirectoryMode = "0750";
            RuntimeDirectory = "oligarchy/plugins";

            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectClock = true;
            RestrictSUIDSGID = true;
            # bwrap does NOT need "userns and nothing else", which is what this
            # used to say and what broke tier 1 outright: it creates the user
            # namespace and the mount, pid, ipc, uts, cgroup and net namespaces
            # in ONE clone() call, so denying any of them fails the whole call —
            # and bwrap then reports the badly misleading "no permissions to
            # creating new namespace ... enable kernel.unprivileged_userns_clone",
            # which sends you after a sysctl that was never the problem.
            #
            # Listing them is still better than dropping the directive: `time`
            # stays denied, and the list documents exactly what the sandbox asks
            # the kernel for. The plugin gains nothing from it either way — it
            # runs inside those namespaces with every capability dropped.
            RestrictNamespaces = "user mnt pid ipc uts cgroup net";
            LockPersonality = true;
            SystemCallArchitectures = "native";
            UMask = "0077";
            TasksMax = 64;
            IOWeight = 50;

            # NOTE: MemoryDenyWriteExecute is deliberately absent here. Setting
            # it in the template would apply it to every instance including
            # jit=self ones, and a template cannot express the exception. It is
            # set per-instance by the drop-in — at build time for declared
            # plugins, and by plugind into /run for imperative ones.
          };
        };

        systemd.targets.oligarchy-plugins = {
          description = "Oligarchy plugins";
          wantedBy = [ "multi-user.target" ];
          wants = mapAttrsToList (name: _: "oligarchy-plugin@${name}.service")
            enabledPlugins;
        };
      }

      (mkIf anyBwrapTier
        {
          # bubblewrap dropped setuid mode, so the namespaces have to come from
          # somewhere. This is the price of tier 1.
          security.unprivilegedUsernsClone = lib.mkDefault true;
          environment.systemPackages = [ pkgs.bubblewrap ];
        })

    ] ++ optional (options ? microvm) (mkIf cfg.microvm.enable {
      # Tier 2 hosts. Guests are generated from declaredPlugins with
      # tier = "microvm". Unlike the other tiers, microvm plugins cannot be
      # installed purely imperatively: the guest needs a closure, and building
      # one is a rebuild. That is a real limitation of this tier, not an
      # oversight — imperative install works for wasm/native/lua.
      microvm.host.enable = true;
      microvm.vms = lib.mapAttrs
        (name: p: {
          config = {
            imports = [ ./guest.nix ];
            nixpkgs.overlays = [ (_: _: { inherit (pkgs) oligarchy-plugind; }) ];

            custom.pluginGuest = {
              enable = true;
              pluginId = name;
              port = 5005; # must match GUEST_PORT in tiers/microvm.rs
            };

            microvm = {
              inherit (cfg.microvm) hypervisor vcpu mem;
              interfaces = [ ]; # no network unless the manifest asked
              shares = [{
                source = "/nix/store";
                mountPoint = "/nix/.ro-store";
                tag = "ro-store";
                proto = "virtiofs";
              }];
              # cid is assigned per-VM by microvm.nix; the host reaches the guest
              # through the unix socket it exposes, not by picking a cid here.
              vsock.cid = 3;
            };
            system.stateVersion = config.system.stateVersion;
          };
        })
        (filterAttrs (_: p: p.tier == "microvm") cfg.declaredPlugins);
    })));

  meta.maintainers = [ "ALH477" ];
}
