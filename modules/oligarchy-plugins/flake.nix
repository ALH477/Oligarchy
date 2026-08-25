{
  description = "Oligarchy tiered plugin system: one WIT ABI, three sandbox tiers, imperative install";

  inputs = {
    # Pinned to the same stable release as the consuming Oligarchy flake so the
    # module, the package and the VM tests all evaluate against one nixpkgs
    # whether this flake is checked standalone or consumed with a `follows`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Tier 2. A normal input rather than an optional one, because a conditional
    # flake input is a lie you tell yourself at 3am.
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, microvm, ... }:
    let
      # The module itself is system-independent; only packages need the
      # per-system dance.
      overlay = final: prev: {
        oligarchy-plugind = final.callPackage ./pkgs/plugind { };
      };
    in
    {
      overlays.default = overlay;

      # ── what a consumer imports ────────────────────────────────────────
      #
      #   inputs.oligarchy-plugins.url = "github:ALH477/oligarchy-plugins";
      #   ...
      #   imports = [ inputs.oligarchy-plugins.nixosModules.plugins ];
      #   custom.plugins.enable = true;
      #
      nixosModules.plugins = { pkgs, ... }: {
        imports = [ ./modules/plugins.nix ];
        nixpkgs.overlays = [ overlay ];
      };

      # Same, plus microvm.nix's host module, so tier 2 works without the
      # consumer having to know it exists.
      #
      # `plugins` remains the module to name when you do not want tier 2: the
      # host module brings a `microvm@` template, a state directory under
      # /var/lib/microvms and a set of `microvm.*` options, none of which a
      # wasm-only or tier-1 host has any use for. custom.plugins asserts on the
      # difference rather than silently doing nothing.
      nixosModules.default = {
        imports = [
          self.nixosModules.plugins
          microvm.nixosModules.host
        ];
      };

      # The guest side of tier 2. Consumed by modules/plugins.nix through
      # microvm.vms.<name>.config, not imported directly by a consumer.
      nixosModules.microvmGuest = {
        imports = [ microvm.nixosModules.microvm ./modules/guest.nix ];
      };
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) overlay ];
        };
        # checks/ uses lib.mapAttrs' and lib.nameValuePair; neither is in
        # scope from `pkgs` alone at this point.
        lib = nixpkgs.lib;
        rust = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" "clippy" ];
          targets = [ "wasm32-wasip2" ];
        };
      in
      {
        packages = {
          default = pkgs.oligarchy-plugind;
          oligarchy-plugind = pkgs.oligarchy-plugind;

          # The WIT package, exported so plugin authors can pin the exact ABI
          # they built against instead of vendoring a copy that drifts.
          wit = pkgs.runCommand "oligarchy-plugin-wit" { } ''
            mkdir -p $out/share/wit $out/include
            cp ${./wit}/*.wit $out/share/wit/
            cp ${./host/include}/*.h $out/include/
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            rust
            pkgs.cargo-component
            pkgs.wasm-tools
            pkgs.wit-bindgen
            pkgs.pkg-config
            pkgs.bubblewrap
            pkgs.libseccomp
            pkgs.luajit
            pkgs.nixpkgs-fmt
            pkgs.statix
          ];
          # wasmtime needs cmake for some backends; mlua links nixpkgs' LuaJIT
          # through pkg-config, so pkg-config and luajit are both required.
          nativeBuildInputs = [ pkgs.cmake pkgs.stdenv.cc ];
          shellHook = ''
            echo "oligarchy-plugins dev shell"
            echo "  cargo test -p oligarchy-plugind    # manifest + policy + seccomp shape"
            echo "  cargo run -- doctor                # what this kernel can enforce"
            echo "  nix flake check                    # includes the VM test"
          '';
        };

        checks =
          let
            # Fixtures the VM tests install. These have to actually exist:
            # the first version asserted against /etc/oligarchy/test/... and
            # nothing ever put anything there, so both tests would have failed
            # on the very first command.
            fixture = { id, tier, jit, trust ? "first-party", entry ? "module.wasm" }:
              nodePkgs.runCommand "fixture-${id}" { } ''
                mkdir -p $out
                cat > $out/plugin.toml <<'TOML'
                id      = "${id}"
                version = "0.0.1"
                tier    = "${tier}"
                jit     = "${jit}"
                trust   = "${trust}"
                entry   = "${entry}"
                abi     = "oligarchy:plugin@0.1.0"

                [caps]
                fs_read_write = ["$STATE"]
                network       = false
                TOML
                # A stub artifact so the path check passes; these tests are
                # about unit generation and policy, not about DSP.
                mkdir -p $out/lib
                : > $out/${entry} 2>/dev/null || : > $out/lib/stub.so
              '';

            fixtures = {
              plain = fixture { id = "plain"; tier = "wasm"; jit = "host"; };
              jitty = fixture {
                id = "jitty";
                tier = "native";
                jit = "self";
                trust = "trusted";
                entry = "lib/libjitty.so";
              };
              nativeplain = fixture {
                id = "nativeplain";
                tier = "native";
                jit = "none";
                entry = "lib/libplain.so";
              };
              # Identical to `plain` in everything policy looks at, so in the
              # signed-install test the signature is the only variable.
              unsigned = fixture { id = "unsigned"; tier = "wasm"; jit = "host"; };
            };

            # Fixtures reach a node as /etc/oligarchy/test/<name>.
            etcOf = lib.mapAttrs'
              (n: drv: lib.nameValuePair "oligarchy/test/${n}" { source = drv; });

            fixtureEtc = etcOf fixtures;

            # ── Tier 1 fixtures: a REAL native plugin ─────────────────────
            #
            # Everything else that touches W^X is indirect. The unit tests prove
            # the right BPF was assembled; wx-enforcement proves the right
            # MemoryDenyWriteExecute reached systemd; `plugind selftest` proves
            # the kernel honours the filter in a forked child of plugind. None
            # of them prove that a plugin's own machine code, dlopen'd inside
            # bwrap after Landlock and seccomp are applied, gets the answer its
            # manifest declared. This fixture asks the kernel from there.
            wxProbe = { id, jit }:
              let
                manifest = nodePkgs.writeText "plugin.toml" ''
                  id      = "${id}"
                  version = "0.0.1"
                  tier    = "native"
                  jit     = "${jit}"
                  trust   = "first-party"
                  entry   = "lib/libwxprobe.so"
                  abi     = "oligarchy:plugin@0.1.0"

                  [caps]
                  fs_read_write = ["$STATE"]
                  network       = false
                '';
              in
              nodePkgs.runCommand "plugin-${id}"
                {
                  nativeBuildInputs = [ nodePkgs.stdenv.cc ];
                } ''
                mkdir -p $out/lib
                cc -shared -fPIC -O1 -Wall -Wextra -Werror \
                   -I${./host/include} -DPLUGIN_ID='"${id}"' \
                   -o $out/lib/libwxprobe.so ${./tests/wx-probe.c}
                cp ${manifest} $out/plugin.toml
              '';

            tier1Fixtures = {
              # jit=none: the filter is installed, so both probes must be denied.
              wxnone = wxProbe { id = "wxnone"; jit = "none"; };
              # jit=self: the concession. Both must be allowed, or the tier is
              # useless for the LuaJIT/Faust case it exists to serve.
              wxself = wxProbe { id = "wxself"; jit = "self"; };
            };

            tier1Etc = etcOf tier1Fixtures;

            # ── Tier 2 fixture: the same probe, declared into a microVM ─────
            #
            # tier=microvm + jit=self + trust=untrusted is the exact case tier 2
            # exists for, and the one manifest validation refuses anywhere else:
            # a plugin that ships its own code generator and has no provenance.
            # The guest kernel is the only honest place to run it.
            wxVmPlugin =
              let
                manifest = nodePkgs.writeText "plugin.toml" ''
                  id      = "wxvm"
                  version = "0.0.1"
                  tier    = "microvm"
                  jit     = "self"
                  trust   = "untrusted"
                  entry   = "lib/libwxprobe.so"
                  abi     = "oligarchy:plugin@0.1.0"

                  [caps]
                  fs_read_write = ["$STATE"]
                  network       = false
                '';
              in
              nodePkgs.runCommand "plugin-wxvm"
                {
                  nativeBuildInputs = [ nodePkgs.stdenv.cc ];
                } ''
                mkdir -p $out/lib
                cc -shared -fPIC -O1 -Wall -Wextra -Werror \
                   -I${./host/include} -DPLUGIN_ID='"wxvm"' \
                   -o $out/lib/libwxprobe.so ${./tests/wx-probe.c}
                cp ${manifest} $out/plugin.toml
              '';



            # A throwaway signing keypair, generated once with
            #   nix-store --generate-binary-cache-key oligarchy-plugins-test-1 …
            # and committed on purpose. It is PUBLICLY KNOWN and exists only so
            # a VM can produce a genuinely-signed store path without reaching a
            # real cache. Never put this public key on a real host, and never
            # sign anything you care about with the secret half.
            testPublicKey = "oligarchy-plugins-test-1:kyd+Rn9HlxiVTU7UqIVXhUdGYITdgPjdOTHjrvz6w3w=";
            testSecretKey = "oligarchy-plugins-test-1:LrnxTIW3tSa8PvzTWhOy7duAFPXC/7YPuRb4J1Vt32WTJ35Gf0eXGJVNTtSohVeFR0ZghN2A+N05MeOu/PrDfA==";

            # runNixOSTest pins each node's nixpkgs read-only — it derives
            # node.pkgs from the pkgs the runner was taken from — so a node can
            # neither import nixosModules.plugins (that module sets
            # nixpkgs.overlays, which collides) nor set node.pkgs itself. The
            # way in is to call the runner from a pkgs that already carries the
            # overlay, and to import the bare module in the node. Deliberately
            # not the `pkgs` above: that one carries rust-overlay for the dev
            # shell, which has no business in a test node's package set.
            nodePkgs = import nixpkgs {
              inherit system;
              overlays = [ overlay ];
            };
          in
          {
            # The test that matters. A unit test can only prove we BUILT the
            # right BPF; only a kernel can prove it is enforced.
            wx-enforcement = nodePkgs.testers.runNixOSTest {
              name = "oligarchy-plugins-wx";
              nodes.machine = { ... }: {
                imports = [ ./modules/plugins.nix ];
                environment.etc = fixtureEtc;
                custom.plugins = {
                  enable = true;
                  allowedTiers = [ "wasm" "native" "lua" ];
                  allowSelfJit = true;
                  requireSignature = false;
                  trustedPublicKeys = [ "test-1:AAAA" ];
                  minTrust = "untrusted";
                };
                virtualisation.memorySize = 2048;
              };
              testScript = ''
                machine.wait_for_unit("oligarchy-plugind.service")

                # These tests are about unit generation and policy, not about
                # DSP, so the fixtures carry a stub artifact that cannot
                # instantiate. `--no-start` is the seam for exactly that: it
                # does the durable half (write the drop-in, reload, persist
                # enabled=true) and stops before the start that would fail. It
                # matters that these stay `succeed` — a helper that swallowed
                # the exit status would also swallow a broken drop-in
                # generator, a failed daemon-reload, or a policy regression.
                out = machine.succeed("plugind doctor")
                assert "landlock: " in out, out
                assert "UNSUPPORTED" not in out, out

                # tier=wasm must NOT get MDWE, because this process runs
                # Cranelift. Getting this backwards breaks Tier 0 silently,
                # which is the bug this test exists to catch.
                machine.succeed("plugind install /etc/oligarchy/test/plain --allow-unsigned")
                machine.succeed("plugind enable --no-start plain")
                cat = machine.succeed("systemctl cat oligarchy-plugin@plain.service")
                assert "MemoryDenyWriteExecute=no" in cat, cat
                assert "Cranelift" in cat, cat

                # tier=native jit=none is where W^X actually means something.
                machine.succeed("plugind install /etc/oligarchy/test/nativeplain --allow-unsigned")
                machine.succeed("plugind enable --no-start nativeplain")
                cat = machine.succeed("systemctl cat oligarchy-plugin@nativeplain.service")
                assert "MemoryDenyWriteExecute=yes" in cat, cat

                # tier=native jit=self is the concession, and the reason must be
                # recorded in the unit where an auditor will see it.
                machine.succeed("plugind install /etc/oligarchy/test/jitty --allow-unsigned")
                machine.succeed("plugind enable --no-start jitty")
                cat = machine.succeed("systemctl cat oligarchy-plugin@jitty.service")
                assert "MemoryDenyWriteExecute=no" in cat, cat
                assert "jit=self" in cat, cat

                # /run is tmpfs, so the grant must not outlive the decision.
                # The registry, not /run, is the authority.
                machine.shutdown()
                machine.start()
                machine.wait_for_unit("oligarchy-plugind.service")
                cat = machine.succeed("systemctl cat oligarchy-plugin@jitty.service")
                assert "MemoryDenyWriteExecute=no" in cat, cat
              '';
            };

            # Policy must be able to refuse what a manifest requests, at
            # install time rather than at load time.
            policy-refusal = nodePkgs.testers.runNixOSTest {
              name = "oligarchy-plugins-policy";
              nodes.machine = { ... }: {
                imports = [ ./modules/plugins.nix ];
                environment.etc = fixtureEtc;
                custom.plugins = {
                  enable = true;
                  allowedTiers = [ "wasm" ];
                  allowSelfJit = false;
                  requireSignature = false;
                  trustedPublicKeys = [ "test-1:AAAA" ];
                };
              };
              testScript = ''
                machine.wait_for_unit("oligarchy-plugind.service")
                machine.succeed("plugind install /etc/oligarchy/test/plain --allow-unsigned")
                # native on a wasm-only host: refused by tier.
                machine.fail("plugind install /etc/oligarchy/test/nativeplain --allow-unsigned")
                # self-JIT with allowSelfJit=false: refused by policy.
                machine.fail("plugind install /etc/oligarchy/test/jitty --allow-unsigned")
              '';
            };

            # Tier 1, end to end, on a booted kernel: bwrap namespaces, the
            # Landlock ruleset, the seccomp filter, dlopen of a real .so, the C
            # vtable, the host log callback — and then the only question that
            # matters, asked from inside the sandbox by the plugin's own code.
            tier1-runtime = nodePkgs.testers.runNixOSTest {
              name = "oligarchy-plugins-tier1";
              nodes.machine = { ... }: {
                imports = [ ./modules/plugins.nix ];
                environment.etc = tier1Etc;
                custom.plugins = {
                  enable = true;
                  allowedTiers = [ "wasm" "native" "lua" ];
                  # Required to load a jit=self plugin at all, which is half of
                  # what this test is for.
                  allowSelfJit = true;
                  requireSignature = false;
                  minTrust = "untrusted";
                };
                virtualisation.memorySize = 2048;
              };
              testScript = ''
                machine.wait_for_unit("oligarchy-plugind.service")

                # Tier 1 needs unprivileged user namespaces: bubblewrap dropped
                # its setuid mode, so there is nothing else to get them from.
                #
                # Assert the knob that actually governs, which is kernel-
                # dependent. `security.unprivilegedUsernsClone` writes
                # kernel.unprivileged_userns_clone, and that sysctl exists only
                # on kernels carrying the Debian patch — zen and xanmod do, the
                # vanilla kernel this VM boots does not, so the option is a
                # no-op here and userns comes from user.max_user_namespaces
                # instead. Asserting the option's sysctl would have tested the
                # wrong thing on half the kernels this distro offers.
                doctor = machine.succeed("plugind doctor")
                assert "max_user_namespaces: 0\n" not in doctor, doctor
                assert int(machine.succeed("cat /proc/sys/user/max_user_namespaces")) > 0

                # The same claim plugind makes about W^X, on this kernel, before
                # any plugin is involved.
                machine.succeed("plugind selftest")

                def probe(plugin):
                    machine.succeed(f"plugind install /etc/oligarchy/test/{plugin} --allow-unsigned")
                    machine.succeed(f"plugind enable {plugin}")
                    machine.wait_for_unit(f"oligarchy-plugin@{plugin}.service")
                    return machine.succeed(
                        f"journalctl -u oligarchy-plugin@{plugin}.service --no-pager"
                    )

                # ── jit=none: the filter is installed, so the plugin's own
                #    mprotect(PROT_EXEC) must fail — and so must memfd_create,
                #    which is the half MemoryDenyWriteExecute leaves open.
                # All six routes, named individually. The first version of this
                # assertion checked only the two the filter happened to cover,
                # and passed while three others were wide open — an anonymous
                # PROT_EXEC mapping, a plain-file dual mapping, and the two
                # syscalls that write a page regardless of its protection.
                j = probe("wxnone")
                assert (
                    "WXPROBE exec=denied memfd=denied anon=denied "
                    "dualmap=denied ptrace=denied uffd=denied"
                ) in j, j
                # ...and the unit says so where an auditor would look.
                cat = machine.succeed("systemctl cat oligarchy-plugin@wxnone.service")
                assert "MemoryDenyWriteExecute=yes" in cat, cat

                # ── jit=self: the concession. Both must be allowed, or tier 1
                #    cannot serve the LuaJIT/Faust case it exists for.
                # jit=self: no filter, so everything is allowed. dualmap is the
                # exception — NoExecPaths is keyed off wx_enforced, so it is
                # absent here too and the file mapping succeeds.
                j = probe("wxself")
                assert (
                    "WXPROBE exec=allowed memfd=allowed anon=allowed "
                    "dualmap=allowed ptrace=allowed uffd=allowed"
                ) in j, j
                cat = machine.succeed("systemctl cat oligarchy-plugin@wxself.service")
                assert "MemoryDenyWriteExecute=no" in cat, cat
                assert "jit=self" in cat, cat

                # The sandbox is real: Landlock reported enforcement, and the
                # plugin ran confined rather than falling back to unconfined.
                assert "landlock fully enforced" in j or "landlock partially" in j, j
                assert "ready (confined)" in j, j

                # And the grant is per-instance, not per-machine: the jit=none
                # unit is still hardened after the jit=self one was granted.
                cat = machine.succeed("systemctl cat oligarchy-plugin@wxnone.service")
                assert "MemoryDenyWriteExecute=yes" in cat, cat
              '';
            };

            # Tier 2 end to end, on a booted kernel, with a second kernel inside
            # it. Needs nested virtualisation on the builder.
            #
            # The claim under test is the one that justifies the tier existing at
            # all: an untrusted, self-JIT plugin — which manifest validation
            # refuses to load anywhere else — runs, gets the writable-executable
            # memory it needs, and gets it inside a guest kernel rather than on
            # the host.
            tier2-runtime = nodePkgs.testers.runNixOSTest {
              name = "oligarchy-plugins-tier2";
              nodes.machine = { ... }: {
                imports = [
                  ./modules/plugins.nix
                  microvm.nixosModules.host
                ];
                custom.plugins = {
                  enable = true;
                  allowedTiers = [ "wasm" "native" "lua" "microvm" ];
                  allowSelfJit = true;
                  requireSignature = false;
                  minTrust = "untrusted";
                  microvm.enable = true;
                  # qemu rather than cloud-hypervisor: this guest is itself
                  # inside a VM, and qemu's vsock and virtiofs paths are the
                  # best-tested under nesting. The workstation ships
                  # cloud-hypervisor; that difference is the one thing this test
                  # does not cover.
                  microvm.hypervisor = "qemu";
                  microvm.mem = 512;
                  declaredPlugins.wxvm = {
                    artifact = wxVmPlugin;
                    tier = "microvm";
                    jit = "self";
                    trust = "untrusted";
                    # The host-side unit is started by `plugind enable`, not at
                    # boot, so the test controls the ordering.
                    autoStart = false;
                  };
                };
                virtualisation = {
                  memorySize = 4096;
                  cores = 2;
                  # Expose the host's KVM to this VM so the guest inside it can
                  # use hardware virtualisation rather than TCG.
                  qemu.options = [ "-cpu host" ];
                };
              };
              testScript = ''
                machine.wait_for_unit("oligarchy-plugind.service")

                # Nested KVM has to be there, or the guest falls back to
                # emulation and the fifteen-second boot budget is fiction.
                machine.succeed("test -e /dev/kvm")

                # The declarative half: microvm.nix materialised a guest for the
                # declared plugin, and the drop-in generated by the NIX mirror
                # (not the Rust one — this is the first test to exercise that
                # path at all) says what it should.
                machine.succeed("test -e /var/lib/microvms/wxvm/current/bin/microvm-run")
                cat = machine.succeed("systemctl cat oligarchy-plugin@wxvm.service")
                # tier=microvm is W^X-enforced on the HOST side: the host half is
                # a vsock proxy that never JITs. The concession is inside.
                assert "MemoryDenyWriteExecute=yes" in cat, cat

                # Bring it up. This starts microvm@wxvm.service, waits for the
                # guest to bind vsock, does the CONNECT handshake and the ABI
                # Hello, then calls init() over the wire.
                # No `plugind install`: a declared plugin is not in the
                # registry and never will be. It is resolved through the
                # declared index in /etc, which is the whole point of that file.
                machine.succeed("systemctl start oligarchy-plugin@wxvm.service")
                machine.wait_for_unit("microvm@wxvm.service")
                machine.wait_for_unit("oligarchy-plugin@wxvm.service")

                host = machine.succeed(
                    "journalctl -u oligarchy-plugin@wxvm.service --no-pager"
                )
                assert "microvm up" in host, host

                # And the payoff, from inside the guest: a self-JIT plugin gets
                # the executable memory it asked for, because the boundary here
                # is a kernel and not a filter.
                #
                # Polled rather than read once: the guest's console travels
                # guest journald -> guest console -> qemu stdout -> host
                # journald, and that pipeline is not synchronous with the host
                # having called init() over the vsock.
                machine.wait_until_succeeds(
                    "journalctl -u microvm@wxvm.service --no-pager | grep -q WXPROBE",
                    timeout=60,
                )
                guest = machine.succeed("journalctl -u microvm@wxvm.service --no-pager")
                assert "WXPROBE exec=allowed memfd=allowed anon=allowed" in guest, guest
              '';
            };

            # Stage 2's acceptance criterion, stated as a test: an unprivileged
            # user can install a SIGNED plugin and cannot install an unsigned
            # one, and nobody is in nix.settings.trusted-users.
            #
            # Worth saying why this needs a VM. Every interesting claim here is
            # about something no unit test can see: a unix socket's mode, a real
            # `nix store verify` against the keys in the running nix.conf, a real
            # uid failing to write a 0750 directory, and a GC root that Nix
            # itself agrees is a root.
            signed-install = nodePkgs.testers.runNixOSTest {
              name = "oligarchy-plugins-signed-install";
              nodes.machine = { ... }: {
                imports = [ ./modules/plugins.nix ];
                environment.etc = fixtureEtc // {
                  "oligarchy/test-key.sec" = {
                    text = testSecretKey;
                    mode = "0400";
                  };
                };
                users.users.alice = { isNormalUser = true; };
                # Deliberately not an installer: proves the socket is a closed
                # door rather than a formality.
                users.users.bob = { isNormalUser = true; };
                custom.plugins = {
                  enable = true;
                  allowedTiers = [ "wasm" ];
                  allowSelfJit = false;
                  requireSignature = true;
                  trustedPublicKeys = [ testPublicKey ];
                  installers = [ "alice" ];
                };
                virtualisation.memorySize = 2048;
              };
              testScript = ''
                machine.wait_for_unit("oligarchy-plugind.service")

                # `su` without -l keeps root's environment but resets PATH from
                # login.defs, so set it explicitly rather than depend on that.
                def as_user(user, cmd):
                    return f"su {user} -s /bin/sh -c 'PATH=/run/current-system/sw/bin {cmd}'"

                # ── the trust model, in one assertion ───────────────────────
                # If this ever fails, nothing below it means anything: a user
                # trusted to Nix can add their own keys and substituters.
                #
                # Read the generated nix.conf rather than `nix config show`:
                # that is the declarative surface this module writes to, and it
                # does not require the node to have opted into the new CLI.
                cfg = machine.succeed("cat /etc/nix/nix.conf")
                assert "trusted-users = root\n" in cfg, cfg
                # The plugin cache key did reach it...
                assert "oligarchy-plugins-test-1:kyd+Rn9HlxiVTU7UqIVXhUdGYITdgPjdOTHjrvz6w3w=" in cfg, cfg
                # ...merged with, not in place of, what nixpkgs already trusted.
                assert "cache.nixos.org-1:" in cfg, cfg

                # ── the socket is the only mutation path, and it is a door ──
                machine.succeed("test -S /run/oligarchy/plugind/control.sock")
                perms = machine.succeed(
                    "stat -c '%A %U:%G' /run/oligarchy/plugind/control.sock"
                ).strip()
                assert perms == "srw-rw---- root:oligarchy-plugins", perms
                # An installer cannot write the registry directly.
                machine.fail(as_user("alice", "test -w /var/lib/oligarchy/plugins/registry"))

                signed = machine.succeed("readlink -f /etc/oligarchy/test/plain").strip()
                unsigned = machine.succeed("readlink -f /etc/oligarchy/test/unsigned").strip()

                # A CONTENT-ADDRESSED unsigned path, which is the case that made
                # the first version of this test worthless. `nix store verify
                # --sigs-needed 1` short-circuits for content-addressed paths —
                # it sets the signature count to max before consulting a key —
                # and `nix store add-path` needs no privilege whatsoever. So an
                # installer could author arbitrary content, add it to the store,
                # and have it register as signature_verified. The two fixtures
                # above are runCommand outputs, i.e. INPUT-addressed, so they
                # failed verification for the wrong reason and the hole was
                # invisible. This one closes that.
                machine.succeed(
                    "mkdir -p /tmp/ca && printf '%s\n' "
                    "'id = \"cabypass\"' 'version = \"1.0.0\"' 'tier = \"wasm\"' "
                    "'jit = \"host\"' 'entry = \"module.wasm\"' "
                    "'abi = \"oligarchy:plugin@0.1.0\"' > /tmp/ca/plugin.toml "
                    "&& : > /tmp/ca/module.wasm"
                )
                ca = machine.succeed(
                    as_user(
                        "alice",
                        "nix --extra-experimental-features nix-command "
                        "store add-path /tmp/ca --name cabypass",
                    )
                ).strip()
                # It really is content-addressed with no signatures — if this
                # ever stops being true the test below stops testing anything.
                info = machine.succeed(
                    "nix --extra-experimental-features nix-command path-info "
                    f"--json {ca}"
                )
                assert '"signatures":[]' in info.replace(" ", ""), info
                assert '"ca":"fixed' in info.replace(" ", ""), info
                # plugind passes --extra-experimental-features itself (see
                # registry.rs); this test node has not enabled the new CLI, so
                # signing has to ask for it too.
                machine.succeed(
                    "nix --extra-experimental-features nix-command store sign "
                    f"--key-file /etc/oligarchy/test-key.sec {signed}"
                )

                # ── 1. an unprivileged user installs a SIGNED plugin ────────
                out = machine.succeed(as_user("alice", f"plugind install {signed}"))
                assert "installed plain" in out, out
                # The sandbox explanation comes back too, so an install done for
                # you reads like one you did yourself.
                assert "tier" in out.lower(), out

                # ── 2. ...and cannot install an unsigned one ────────────────
                err = machine.fail(as_user("alice", f"plugind install {unsigned}") + " 2>&1")
                assert "no valid signature" in err, err

                # ── 3. ...and cannot ask for the check to be skipped. The wire
                #       format has no field for it, so this is refused before
                #       anything is even fetched.
                err = machine.fail(
                    as_user("alice", f"plugind install --allow-unsigned {unsigned}") + " 2>&1"
                )
                assert "no field for it" in err, err

                # ── 4. neither can root: requireSignature is declarative, and a
                #       CLI flag does not get to overrule it.
                err = machine.fail(f"plugind install --allow-unsigned {unsigned} 2>&1")
                assert "requireSignature is true" in err, err

                # ── 5. a content-addressed unsigned path is refused ─────────
                err = machine.fail(as_user("alice", f"plugind install {ca}") + " 2>&1")
                assert "no valid signature" in err, err
                # ...and root cannot force it either.
                err = machine.fail(f"plugind install --allow-unsigned {ca} 2>&1")
                assert "requireSignature is true" in err, err

                # ── 6. a non-installer gets neither path ────────────────────
                err = machine.fail(as_user("bob", f"plugind install {signed}") + " 2>&1")
                assert "install group" in err or "Permission denied" in err, err

                # ── 7. the GC root is one Nix agrees with ───────────────────
                # A bare symlink into the store is not a root; only a path
                # registered under /nix/var/nix/gcroots is. Ask Nix, not ls.
                roots = machine.succeed(f"nix-store -q --roots {signed}")
                assert "gcroots/plain" in roots, roots

                # ── 8. reads work over the socket as well as writes ─────────
                out = machine.succeed(as_user("alice", "plugind list"))
                assert "plain" in out, out
                assert "ok" in out, out   # the signature column

                # ── 9. and the privileged action left an audit trail ────────
                alice_uid = machine.succeed("id -u alice").strip()
                # Not `log`: the test driver already binds that name.
                journal = machine.succeed("journalctl -u oligarchy-plugind --no-pager")
                assert "control request" in journal, journal
                assert alice_uid in journal, journal
              '';
            };

            fmt = pkgs.runCommand "check-fmt" { } ''
              ${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt --check ${./.} && touch $out
            '';
          };

        formatter = pkgs.nixpkgs-fmt;
      });
}
