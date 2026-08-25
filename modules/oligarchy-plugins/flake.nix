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

    # ── Tier 2 (microvm.nix) is NOT an input yet ──────────────────────────
    #
    # It is staged in deliberately, after tiers 0 and 1 are known good on real
    # hardware. An input that is locked but never imported is not free: it
    # enters flake.lock, gets fetched on every `nix flake check`, and reads to
    # the next person like tier 2 is wired when it is not.
    #
    # To land tier 2, restore:
    #
    #   microvm = {
    #     url = "github:microvm-nix/microvm.nix";
    #     inputs.nixpkgs.follows = "nixpkgs";
    #   };
    #
    # add `microvm` to the outputs argument list, and restore
    # nixosModules.default / nixosModules.microvmGuest below. Nothing in
    # modules/plugins.nix needs changing — see the two-condition gate there for
    # why its microvm section already costs a host without this input nothing.
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, ... }:
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
      # There is deliberately no `nixosModules.default` while tier 2 is
      # unstaged: `default` used to mean "plugins + the microvm.nix host
      # module", and quietly redefining it to mean "plugins alone" would give a
      # consumer who sets custom.plugins.microvm.enable a silently missing host
      # module instead of an error. Name the module you want. See the microvm
      # note in `inputs` above.
      nixosModules.plugins = { pkgs, ... }: {
        imports = [ ./modules/plugins.nix ];
        nixpkgs.overlays = [ overlay ];
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
          # mlua's vendored LuaJIT needs a C toolchain; wasmtime needs cmake
          # for some backends.
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
            };

            fixtureEtc = lib.mapAttrs'
              (n: drv:
                lib.nameValuePair "oligarchy/test/${n}" { source = drv; })
              fixtures;

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

            fmt = pkgs.runCommand "check-fmt" { } ''
              ${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt --check ${./.} && touch $out
            '';
          };

        formatter = pkgs.nixpkgs-fmt;
      });
}
