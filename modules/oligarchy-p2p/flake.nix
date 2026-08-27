{
  description = "Oligarchy P2P substituter — a local Nix binary-cache adapter over a peer transport";

  inputs = {
    # Pinned to the same stable release as the consuming Oligarchy flake so the
    # module, the package and the VM gates all evaluate against one nixpkgs
    # whether this flake is checked standalone or consumed with a `follows`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # System-independent half first, so `nixosModules.*` needs no per-system
      # dance and the module can reach its package through the overlay rather
      # than through `inputs.<flake>.packages.<system>`.
      overlay = final: prev: {
        oligarchy-p2pd = final.callPackage ./pkgs/oligarchy-p2pd { };
      };
    in
    {
      overlays.default = overlay;

      nixosModules.p2pCache = { ... }: {
        imports = [ ./modules/p2p-cache.nix ];
        nixpkgs.overlays = [ overlay ];
      };
      nixosModules.default = self.nixosModules.p2pCache;
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };

        # runNixOSTest pins each node's nixpkgs read-only, so a node can neither
        # import nixosModules.p2pCache (that module sets nixpkgs.overlays, which
        # collides) nor set node.pkgs itself. The way in is to call the runner
        # from a pkgs that already carries the overlay and import the bare
        # module in the node. Same dance as modules/oligarchy-plugins.
        nodePkgs = pkgs;

        # NixOS assigns test-node addresses in ALPHABETICAL order of the node
        # name, not declaration order — so `leecher` is .1 and `seeder` is .2,
        # which is the opposite of how the nodes read in the file below. Getting
        # this backwards points the leecher at itself and costs a 60-second
        # timeout with no hint as to why, so it is a named binding and the test
        # asserts it rather than trusting it.
        seederIp = "192.168.1.2";

        # A peer that never verifies anything, for the two-node gate.
        #
        # A derivation rather than a heredoc inside the test script: the script
        # is a Python f-string embedded in a Nix indented string, so a program
        # containing braces and its own heredoc has three levels of quoting to
        # get wrong, and did.
        hostilePeer = nodePkgs.writeText "hostile-peer.py" ''
          # Serves right-length, wrong bytes under the peer protocol. The point
          # is that only the digest can catch it: the length is correct, the
          # route is correct, and the HTTP is well-formed.
          import http.server, sys

          NARSIZE = int(sys.argv[1])


          class H(http.server.BaseHTTPRequestHandler):
              def _send(self, code, body=b"", ctype="application/octet-stream"):
                  self.send_response(code)
                  self.send_header("Content-Type", ctype)
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  if body and self.command != "HEAD":
                      self.wfile.write(body)

              def do_HEAD(self):
                  # Claim to have everything.
                  self._send(200 if "/have/" in self.path else 404)

              def do_GET(self):
                  if "/narinfo/" in self.path:
                      # Refuse metadata: the leecher already has the genuine,
                      # signed narinfo, so this gate is about the BYTES.
                      self._send(404)
                  elif "/nar/" in self.path:
                      self._send(200, b"X" * NARSIZE)
                  else:
                      self._send(200, b"{}", "application/json")

              def log_message(self, *a):
                  pass


          http.server.HTTPServer(("0.0.0.0", 5199), H).serve_forever()
        '';

        # ── Shared fixture ────────────────────────────────────────────────────
        # Both gates need the same thing: a real signed binary cache reachable
        # over HTTP from inside the VM, and a store to substitute into. The key
        # is generated *inside* the test rather than at build time, because a
        # committed signing key would be a lie about what is being proven.
        commonNode = { pkgs, ... }: {
          imports = [ ./modules/p2p-cache.nix ];

          custom.p2pCache = {
            enable = true;
            upstreams = [ "http://127.0.0.1:8000" ];
            # Not registered as a substituter: the tests drive it explicitly
            # with --substituters so that what is under test is unambiguous,
            # and so a failure cannot be masked by nixpkgs' default cache.
            registerSubstituter = false;
          };

          environment.systemPackages = [ pkgs.python3 pkgs.curl pkgs.hello ];
          virtualisation.memorySize = 2048;
          virtualisation.diskSize = 8192;

          # `nix copy` / `nix store sign` are nix-command verbs.
          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          # NOTE: nixpkgs' default substituter is deliberately NOT forced empty
          # here. Doing so would collide with the module's own
          # `nix.settings.substituters` definition in the signature-refusal node
          # — mkForce would win and erase the very line that test reads back out
          # of nix.conf. The VM has no network, and every command below passes
          # `--option substituters` explicitly, so the default is inert.
        };

        # Python helper shared by both testScripts: stand up a signed cache and
        # serve it over plain HTTP on 127.0.0.1:8000.
        setupUpstream = ''
          machine.wait_for_unit("multi-user.target")
          machine.succeed("mkdir -p /tmp/upstream /tmp/teststore")

          # A signing key that exists only for the life of this VM.
          machine.succeed(
              "nix-store --generate-binary-cache-key test-cache-1 "
              "/tmp/cache.sec /tmp/cache.pub"
          )
          pubkey = machine.succeed("cat /tmp/cache.pub").strip()
          hello = machine.succeed("readlink -f $(which hello) | xargs dirname | xargs dirname").strip()

          machine.succeed(f"nix store sign --key-file /tmp/cache.sec --recursive {hello}")
          machine.succeed(f"nix copy --to file:///tmp/upstream {hello}")

          machine.succeed(
              "systemd-run --unit=upstream-http -p WorkingDirectory=/tmp/upstream "
              "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1"
          )
          machine.wait_until_succeeds("curl -sf http://127.0.0.1:8000/nix-cache-info", timeout=30)
          machine.wait_for_unit("oligarchy-p2pd.service")
          machine.wait_until_succeeds("curl -sf http://127.0.0.1:5111/nix-cache-info", timeout=30)

          hp = hello.split("/")[-1].split("-")[0]

          # A store path this VM deliberately does NOT keep.
          #
          # `serveFromStore` is on, and the VM has `hello` in its own store, so
          # any test that corrupts the UPSTREAM copy of hello proves nothing —
          # the adapter answers correctly from `nix-store --dump` and never
          # looks upstream at all. Two gates passed vacuously that way before
          # this existed, and one of them then failed with "served the whole
          # correct thing", which is the adapter being right and the test being
          # wrong.
          #
          # So: add a path, sign it, publish it, then delete it locally. Now
          # upstream is genuinely the only source and corrupting it means
          # something.
          machine.succeed("seq 1 100000 > /tmp/blob")
          solo = machine.succeed("nix-store --add /tmp/blob").strip()
          machine.succeed(f"nix store sign --key-file /tmp/cache.sec {solo}")
          machine.succeed(f"nix copy --to file:///tmp/upstream {solo}")
          machine.succeed(f"nix-store --delete {solo}")
          machine.fail(f"test -e {solo}")
          solo_hp = solo.split("/")[-1].split("-")[0]
        '';
      in
      {
        packages = {
          default = pkgs.oligarchy-p2pd;
          oligarchy-p2pd = pkgs.oligarchy-p2pd;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ rustc cargo clippy rustfmt nixpkgs-fmt curl jq ];
        };

        formatter = pkgs.nixpkgs-fmt;

        checks = {
          fmt = pkgs.runCommand "check-fmt" { } ''
            ${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt --check ${./.} && touch $out
          '';

          # ── Gate 1: does Nix actually substitute through us? ────────────────
          # A unit test can prove we emit a well-formed narinfo. Only a real Nix
          # can prove Nix accepts it — StoreDir matching, Priority parsing, the
          # URL rewrite resolving, the body arriving intact, and the signature
          # surviving the round trip through our re-emission.
          substituter-protocol = nodePkgs.testers.runNixOSTest {
            name = "oligarchy-p2p-substituter-protocol";
            nodes.machine = commonNode;
            testScript = ''
              ${setupUpstream}

              # 1. nix-cache-info is well-formed and advertises us ahead of
              #    cache.nixos.org's 40.
              info = machine.succeed("curl -sf http://127.0.0.1:5111/nix-cache-info")
              assert "StoreDir: /nix/store" in info, info
              assert "WantMassQuery: 1" in info, info
              assert "Priority: 30" in info, info

              # 2. The narinfo we emit rewrites URL and nothing else. This is
              #    the invariant that keeps signatures valid; if it breaks, the
              #    symptom appears as an unexplained signature refusal.
              up = machine.succeed(f"curl -sf http://127.0.0.1:8000/{hp}.narinfo")
              ours = machine.succeed(f"curl -sf http://127.0.0.1:5111/{hp}.narinfo")

              def fields(t):
                  return dict(l.split(": ", 1) for l in t.strip().split("\n"))

              u, o = fields(up), fields(ours)
              for f in ["StorePath", "NarHash", "NarSize", "References", "Deriver"]:
                  if f in u:
                      assert u[f] == o.get(f), f"rewrote signed field {f}: {u[f]} -> {o.get(f)}"
              assert u["Sig"] == o["Sig"], "signature did not survive re-emission"
              assert o["URL"].startswith(f"nar/{hp}/"), o["URL"]
              assert o["URL"] != u["URL"], "URL was not rewritten"

              # Stage 2 canonicalisation: every transport field we emit is now a
              # function of NarHash/NarSize, both SIGNED and both immutable for
              # a given store path. This is what makes the narinfo stay true for
              # the thirty days Nix caches it, no matter what upstream does to
              # its compression — the failure stage 1 shipped with.
              assert o["Compression"] == "none", o["Compression"]
              assert o["FileHash"] == o["NarHash"], (o["FileHash"], o["NarHash"])
              assert o["FileSize"] == o["NarSize"], (o["FileSize"], o["NarSize"])
              assert o["URL"] == f"nar/{hp}/" + o["NarHash"].split(":")[1] + ".nar", o["URL"]
              assert not o["URL"].endswith((".xz", ".zst", ".bz2")), o["URL"]

              # 3. HEAD works — Nix uses it for existence checks.
              machine.succeed(f"curl -sfI http://127.0.0.1:5111/{hp}.narinfo")

              # 4. THE gate: a real substitution, end to end, with signature
              #    checking ON and only the test key trusted.
              machine.succeed(
                  f"nix-store --realise {hello} --store /tmp/teststore "
                  f"--option substituters http://127.0.0.1:5111 "
                  f"--option require-sigs true "
                  f"--option trusted-public-keys '{pubkey}'"
              )
              machine.succeed(
                  f"nix path-info --store /tmp/teststore {hello}"
              )
              machine.succeed(f"test -x /tmp/teststore{hello}/bin/hello")

              # 5. The adapter is loopback-only. Nothing outside may reach it.
              machine.fail("ss -ltn | grep -E '0\\.0\\.0\\.0:5111|\\[::\\]:5111'")
              machine.succeed("ss -ltn | grep -q '127.0.0.1:5111'")

              # 6. A path no upstream has is a clean 404, not a 500 — Nix reads
              #    404 as "ask the next substituter".
              missing = "0" * 32
              machine.succeed(
                  f"test $(curl -s -o /dev/null -w '%{{http_code}}' "
                  f"http://127.0.0.1:5111/{missing}.narinfo) = 404"
              )

              # 7. P2P must be an enhancement, never a dependency. With the
              #    daemon stopped Nix must still build from upstream. This is
              #    the "does not break booting or maintaining the system" claim;
              #    it was asserted only in prose until now.
              machine.succeed("systemctl stop oligarchy-p2pd")
              machine.succeed("rm -f /root/.cache/nix/binary-cache-v*.sqlite*")
              machine.succeed(
                  f"nix-store --realise {hello} --store /tmp/nodaemon "
                  f"--option substituters 'http://127.0.0.1:5111 http://127.0.0.1:8000' "
                  f"--option require-sigs true "
                  f"--option trusted-public-keys '{pubkey}'"
              )
              machine.succeed(f"test -x /tmp/nodaemon{hello}/bin/hello")
              machine.succeed("systemctl start oligarchy-p2pd")

              print("substituter-protocol: cache-info, canonical narinfo, HEAD, "
                    "real substitution, loopback bind, 404 fall-through and "
                    "daemon-down fallback verified")
            '';
          };

          # ── Gate 3: the artifact cache ─────────────────────────────────────
          # Stage 2's claim is that a NAR served from a local source is verified
          # IN FULL before Nix receives a byte of it. That is only worth
          # asserting against a real cache on a real disk, and it has three
          # legs: the cache gets populated, it is genuinely used (proved by
          # taking upstream away), and a tampered entry is refused rather than
          # served.
          artifact-cache = nodePkgs.testers.runNixOSTest {
            name = "oligarchy-p2p-artifact-cache";
            nodes.machine = commonNode;
            testScript = ''
              ${setupUpstream}

              # Legs 1-3 use `solo`, which this VM does not hold, so upstream is
              # the only source and the cache is the only thing that can make a
              # second request cheap.
              info = machine.succeed(f"curl -sf http://127.0.0.1:5111/{solo_hp}.narinfo")
              f = dict(l.split(": ", 1) for l in info.strip().split("\n"))
              narhash = f["NarHash"].split(":")[1]
              narsize = int(f["NarSize"])
              cached = f"/var/lib/oligarchy/p2p/nar/{narhash}.nar"
              assert f["Compression"] == "none", f["Compression"]
              assert f["URL"] == f"nar/{solo_hp}/{narhash}.nar", f["URL"]

              # Warm hello's METADATA now, while upstream is still up. Leg 4
              # runs after upstream has been stopped and needs the narinfo to
              # resolve; only the NAR has to be absent for that leg to mean
              # anything. Fetching the narinfo does not fetch the body, so the
              # artifact cache stays cold for hello either way.
              hf = dict(
                  l.split(": ", 1)
                  for l in machine.succeed(
                      f"curl -sf http://127.0.0.1:5111/{hp}.narinfo"
                  ).strip().split("\n")
              )
              hhash = hf["NarHash"].split(":")[1]

              # 1. A cold fetch decompresses upstream's xz and caches the
              #    canonical uncompressed NAR, named by the signed hash.
              machine.fail(f"test -e {cached}")
              machine.succeed(f"curl -sf -o /tmp/a.nar http://127.0.0.1:5111/nar/{solo_hp}/{narhash}.nar")
              machine.wait_until_succeeds(f"test -e {cached}", timeout=30)
              assert int(machine.succeed(f"stat -c%s {cached}").strip()) == narsize
              got = machine.succeed(f"nix hash file --type sha256 --base32 {cached}").strip()
              assert got == narhash, f"cache entry is not its own name: {got} != {narhash}"
              journal = machine.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert 'source="upstream"' in journal, journal

              # 2. THE leg that proves the cache is real: take upstream away
              #    entirely, then ask again. Anything that answers now came off
              #    the local disk, because `solo` is not in this store either.
              machine.succeed("systemctl stop upstream-http")
              machine.fail("curl -sf http://127.0.0.1:8000/nix-cache-info")
              machine.succeed(f"curl -sf -o /tmp/b.nar http://127.0.0.1:5111/nar/{solo_hp}/{narhash}.nar")
              machine.succeed("cmp /tmp/a.nar /tmp/b.nar")
              journal = machine.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert 'source="cache"' in journal, journal

              # 3. A tampered cache entry is refused, REMOVED, and not served.
              #    Length-preserving, so only the digest can catch it. With
              #    upstream down and the path absent locally, there is nothing
              #    left to fall through to, so this must be a clean 404.
              machine.succeed(f"printf 'X' | dd of={cached} bs=1 seek=200 count=1 conv=notrunc")
              code = machine.succeed(
                  f"curl -s -o /tmp/t.nar -w '%{{http_code}}' "
                  f"http://127.0.0.1:5111/nar/{solo_hp}/{narhash}.nar"
              ).strip()
              assert code == "404", f"served a tampered cache entry (HTTP {code})"
              machine.fail(f"test -e {cached}")
              journal = machine.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert "REFUSED a cache entry" in journal, journal

              # 4. serveFromStore, on a path this VM DOES hold. Upstream is
              #    still down and the cache is cold for it, so `nix-store --dump`
              #    is the only thing that can answer. This is the seeding
              #    primitive stage 3 builds on.
              machine.succeed(f"rm -f /var/lib/oligarchy/p2p/nar/{hhash}.nar")
              machine.succeed(f"curl -sf -o /tmp/d.nar http://127.0.0.1:5111/nar/{hp}/{hhash}.nar")
              assert machine.succeed(
                  "nix hash file --type sha256 --base32 /tmp/d.nar"
              ).strip() == hhash
              journal = machine.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert 'source="nix-store"' in journal, journal

              print("artifact-cache: cold fetch decompressed and cached as the "
                    "canonical NAR, served with upstream DOWN, tampered entry "
                    "refused and removed with nothing to fall back to, and "
                    "nix-store --dump answered for a path held locally")
            '';
          };

          # ── Gate 4: two nodes, one artifact ────────────────────────────────
          # The repo's first multi-node VM test, and the only way to prove the
          # claim the whole project rests on: that a machine which has never
          # seen a path can get it from a neighbour rather than from the
          # internet.
          #
          # The test is built so it CANNOT pass by accident. Node B has no
          # upstream that resolves, `hello` is not in its store, and its cache
          # starts empty — so if the path appears in B's store, the bytes came
          # from A over the peer surface. Nothing else could have supplied them.
          two-node = nodePkgs.testers.runNixOSTest {
            name = "oligarchy-p2p-two-node";

            nodes = {
              # A: holds the artifact and serves it. No peers of its own.
              seeder = { pkgs, ... }: {
                imports = [ ./modules/p2p-cache.nix ];
                custom.p2pCache = {
                  enable = true;
                  registerSubstituter = false;
                  upstreams = [ "http://127.0.0.1:8000" ];
                  serveFromStore = true;
                  peer.enable = true;
                  peer.openFirewall = [ "eth1" ];
                  logLevel = "oligarchy_p2pd=debug";
                };
                environment.systemPackages = [ pkgs.hello pkgs.curl ];
                nix.settings.experimental-features = [ "nix-command" "flakes" ];
                virtualisation.memorySize = 2048;
                virtualisation.diskSize = 8192;
              };

              # B: has nothing, and no working upstream. Its ONLY source is A.
              leecher = { pkgs, ... }: {
                imports = [ ./modules/p2p-cache.nix ];
                custom.p2pCache = {
                  enable = true;
                  registerSubstituter = false;
                  # Points at a port nothing listens on. If this test passes,
                  # upstream played no part in it.
                  upstreams = [ "http://127.0.0.1:9" ];
                  upstreamTimeout = 2;
                  # OFF, and this is load-bearing rather than tidy. NixOS test
                  # nodes share the HOST's /nix/store, so `hello` is visible on
                  # this node's filesystem even though it is not in its Nix
                  # database and not in its closure. With serveFromStore on, the
                  # daemon would `nix-store --dump` it locally and the peer
                  # transport — the entire subject of this gate — would never be
                  # exercised. "The leecher does not have it" has to mean
                  # something the shared store cannot undo.
                  serveFromStore = false;
                  transport = "lan";
                  peers = [ "${seederIp}:5112" ];
                  peerTimeout = 30;
                  logLevel = "oligarchy_p2pd=debug";
                };
                # Deliberately NOT pkgs.hello — B must not hold the artifact.
                environment.systemPackages = [ pkgs.curl ];
                nix.settings.experimental-features = [ "nix-command" "flakes" ];
                nix.settings.substituters = nixpkgs.lib.mkForce [ ];
                virtualisation.memorySize = 2048;
                virtualisation.diskSize = 8192;
              };
            };

            testScript = ''
              import json

              start_all()
              seeder.wait_for_unit("multi-user.target")
              leecher.wait_for_unit("multi-user.target")
              seeder.wait_for_unit("oligarchy-p2pd.service")
              leecher.wait_for_unit("oligarchy-p2pd.service")

              # ── Prepare the seeder: a signed cache it can resolve from ─────
              seeder.succeed("mkdir -p /tmp/upstream")
              seeder.succeed(
                  "nix-store --generate-binary-cache-key test-cache-1 "
                  "/tmp/cache.sec /tmp/cache.pub"
              )
              pubkey = seeder.succeed("cat /tmp/cache.pub").strip()
              hello = seeder.succeed(
                  "readlink -f $(which hello) | xargs dirname | xargs dirname"
              ).strip()
              hp = hello.split("/")[-1].split("-")[0]
              seeder.succeed(f"nix store sign --key-file /tmp/cache.sec --recursive {hello}")
              seeder.succeed(f"nix copy --to file:///tmp/upstream {hello}")
              seeder.succeed(
                  "systemd-run --unit=upstream-http -p WorkingDirectory=/tmp/upstream "
                  "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1"
              )
              seeder.wait_until_succeeds("curl -sf http://127.0.0.1:8000/nix-cache-info", timeout=30)

              # Warm the seeder over the WHOLE CLOSURE, by driving a real
              # substitution through its own adapter. This is what a machine
              # that just rebuilt actually looks like, and it matters: the peer
              # surface serves only metadata the host has itself resolved (it
              # never goes upstream on a peer's behalf), so a seeder warmed with
              # a single narinfo can hand over `hello` and none of the five
              # paths `hello` needs to run.
              seeder.succeed(
                  f"nix-store --realise {hello} --store /tmp/warm "
                  f"--option substituters http://127.0.0.1:5111 "
                  f"--option require-sigs true "
                  f"--option trusted-public-keys '{pubkey}'"
              )
              info = seeder.succeed(f"curl -sf http://127.0.0.1:5111/{hp}.narinfo")
              f = dict(l.split(": ", 1) for l in info.strip().split("\n"))
              narhash = f["NarHash"].split(":")[1]
              narsize = int(f["NarSize"])
              seeder.succeed(f"test -e /var/lib/oligarchy/p2p/nar/{narhash}.nar")
              # More than one path, or the substitution leg below proves only
              # that a single artifact moves.
              assert int(seeder.succeed(
                  "ls /var/lib/oligarchy/p2p/narinfo | wc -l"
              ).strip()) >= 5, "the seeder did not cache the whole closure"

              # ── The leecher really cannot supply this itself ───────────────
              # NOT `test -e {hello}` — the store DIRECTORY is shared from the
              # host in a NixOS test, so the files are there regardless. What
              # matters is that the path is not valid in this node's database,
              # its artifact cache is empty, its upstream does not answer, and
              # its daemon will not serve from the store.
              leecher.fail(f"nix path-info {hello}")
              leecher.fail(f"test -e /var/lib/oligarchy/p2p/nar/{narhash}.nar")
              leecher.fail(f"test -e /var/lib/oligarchy/p2p/narinfo/{hp}.narinfo")
              leecher.fail("curl -sf --max-time 3 http://127.0.0.1:9/nix-cache-info")
              assert '"serve_from_store":false' in leecher.succeed(
                  "cat /etc/oligarchy/p2p/config.json"
              )

              # ── Reachability: B can see A's peer surface, and only that ────
              # Assert the address assignment before depending on it. If NixOS
              # ever changes how node addresses are allocated, this fails with a
              # sentence instead of a timeout.
              assert "${seederIp}/24" in seeder.succeed("ip -4 addr show eth1"), \
                  "the seeder is not at ${seederIp}; node address assignment changed"

              leecher.wait_until_succeeds(
                  "curl -sf --max-time 5 http://${seederIp}:5112/peer/v1/info", timeout=60
              )
              # A's SUBSTITUTER surface must NOT be reachable from B. It is
              # loopback-only precisely so that exposing a peer does not expose
              # an open proxy for everything upstream holds.
              leecher.fail("curl -sf --max-time 5 http://${seederIp}:5111/nix-cache-info")

              # ── THE test: the metadata and the bytes both come from A ──────
              got = leecher.succeed(
                  f"curl -sf --max-time 30 http://127.0.0.1:5111/{hp}.narinfo"
              )
              assert "Sig: test-cache-1:" in got, got
              assert f"NarHash: sha256:{narhash}" in got, got

              leecher.succeed(
                  f"curl -sf --max-time 60 -o /tmp/got.nar "
                  f"http://127.0.0.1:5111/nar/{hp}/{narhash}.nar"
              )
              assert int(leecher.succeed("stat -c%s /tmp/got.nar").strip()) == narsize
              assert leecher.succeed(
                  "nix hash file --type sha256 --base32 /tmp/got.nar"
              ).strip() == narhash

              journal = leecher.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert "narinfo from a peer" in journal, journal
              assert "fetched from a peer" in journal, journal

              # ── And a real substitution, end to end, signatures required ───
              leecher.succeed(
                  f"nix-store --realise {hello} --store /tmp/teststore "
                  f"--option substituters http://127.0.0.1:5111 "
                  f"--option require-sigs true "
                  f"--option trusted-public-keys '{pubkey}'"
              )
              leecher.succeed(f"test -x /tmp/teststore{hello}/bin/hello")

              # ── A well-behaved peer does not hand out unverified bytes ────
              # Corrupt the seeder's cached artifact, length-preserving. A
              # verifies before serving a peer, so it must refuse rather than
              # pass the corruption on.
              seeder.succeed("systemctl stop upstream-http")
              seeder.succeed(
                  f"printf 'X' | dd of=/var/lib/oligarchy/p2p/nar/{narhash}.nar "
                  f"bs=1 seek=200 count=1 conv=notrunc"
              )
              code = seeder.succeed(
                  f"curl -s -o /dev/null -w '%{{http_code}}' "
                  f"http://127.0.0.1:5112/peer/v1/nar/{hp}/{narhash}"
              ).strip()
              # 404 either because the digest failed, or because A fell back to
              # its own store copy and re-published — both are A behaving. What
              # must NOT happen is corrupt bytes going out.
              if code == "200":
                  seeder.succeed(
                      f"curl -sf -o /tmp/served.nar http://127.0.0.1:5112/peer/v1/nar/{hp}/{narhash}"
                  )
                  assert seeder.succeed(
                      "nix hash file --type sha256 --base32 /tmp/served.nar"
                  ).strip() == narhash, "a peer served bytes that were not what it named"
              seeder_journal = seeder.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert "REFUSED a cache entry" in seeder_journal, seeder_journal

              # ── A HOSTILE peer is refused by the leecher ──────────────────
              # The leg above proves the SEEDER is honest, which is the seeder's
              # guarantee and not the one that matters. Peers are untrusted by
              # assumption, so the thing to prove is that B refuses bad bytes
              # from a peer that never verifies anything. A well-behaved peer
              # with a corrupt cache cannot demonstrate that — it refuses first.
              seeder.succeed(
                  f"systemd-run --unit=hostile ${pkgs.python3}/bin/python3 "
                  f"${hostilePeer} {narsize}"
              )
              seeder.succeed("systemctl start firewall.service || true")
              seeder.succeed("iptables -I nixos-fw -p tcp --dport 5199 -j nixos-fw-accept")
              leecher.wait_until_succeeds(
                  "curl -sf --max-time 5 http://${seederIp}:5199/peer/v1/info", timeout=60
              )

              # Point the leecher at the hostile peer only, and clear what it
              # already holds so it must actually fetch.
              # NOT /tmp: the unit sets PrivateTmp=true, so anything written to
              # the host's /tmp is invisible to the daemon — it restart-looped
              # on "No such file or directory" until this moved. /etc is
              # read-only to the unit under ProtectSystem=strict but perfectly
              # readable, which is all this needs.
              leecher.succeed(
                  "sed 's|${seederIp}:5112|${seederIp}:5199|' /etc/oligarchy/p2p/config.json "
                  "> /etc/oligarchy-p2p-hostile.json"
              )
              # Override ExecStart, NOT the environment. The unit passes
              # `--config /etc/oligarchy/p2p/config.json` explicitly, and an
              # explicit flag beats clap's env fallback — so an
              # `Environment=OLIGARCHY_P2P_CONFIG=...` drop-in silently does
              # nothing and the leecher keeps talking to the honest peer. It
              # did, and the gate then failed claiming forged bytes were
              # accepted when none had been served.
              leecher.succeed(
                  "mkdir -p /run/systemd/system/oligarchy-p2pd.service.d && "
                  "printf '[Service]\\nExecStartPre=\\nExecStart=\\n"
                  "ExecStart=${nodePkgs.oligarchy-p2pd}/bin/oligarchy-p2pd "
                  "--config /etc/oligarchy-p2p-hostile.json daemon\\n' "
                  "> /run/systemd/system/oligarchy-p2pd.service.d/hostile.conf"
              )
              leecher.succeed(f"rm -f /var/lib/oligarchy/p2p/nar/{narhash}.nar")
              leecher.succeed("systemctl daemon-reload && systemctl restart oligarchy-p2pd")
              leecher.wait_until_succeeds("curl -sf http://127.0.0.1:5111/nix-cache-info", timeout=30)

              # The override took, and the only peer really is the hostile one.
              assert "/etc/oligarchy-p2p-hostile.json" in leecher.succeed(
                  "systemctl show -p ExecStart oligarchy-p2pd"
              )
              # Check the PEERS list specifically. A blunt "5112 not in the
              # file" is wrong: peer_port is 5112 in every config whether the
              # peer surface is enabled or not, so that assertion fails on a
              # correctly-rewritten file.
              hostile_cfg = json.loads(
                  leecher.succeed("cat /etc/oligarchy-p2p-hostile.json")
              )
              assert hostile_cfg["peers"] == ["${seederIp}:5199"], hostile_cfg["peers"]

              code = leecher.succeed(
                  f"curl -s -o /tmp/bad.nar -w '%{{http_code}}' --max-time 60 "
                  f"http://127.0.0.1:5111/nar/{hp}/{narhash}.nar"
              ).strip()
              assert code == "404", f"accepted forged bytes from its only peer (HTTP {code})"
              leecher.fail(f"test -e /var/lib/oligarchy/p2p/nar/{narhash}.nar")
              assert leecher.succeed("ls /var/lib/oligarchy/p2p/tmp | wc -l").strip() == "0", \
                  "a rejected peer fetch left a temp file behind"
              journal = leecher.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert "peer fetch failed" in journal, journal
              assert "hash mismatch" in journal, journal

              print("two-node: leecher resolved metadata AND bytes from its only "
                    "peer with no upstream, substituted for real with signatures "
                    "required, could not reach the seeder's loopback surface, "
                    "and refused right-length forged bytes from a HOSTILE peer "
                    "without publishing or leaking a temp file")
            '';
          };

          # ── Gate 2: the trust boundary ─────────────────────────────────────
          # Two separate claims. First, that an unsigned or badly-signed path is
          # refused when it comes through us — we add availability, never trust.
          # Second, that the substituter URI we register carries no `trusted=`,
          # which is the one mistake that would silently make claim one false.
          signature-refusal = nodePkgs.testers.runNixOSTest {
            name = "oligarchy-p2p-signature-refusal";
            nodes.machine = { ... }: {
              imports = [ commonNode ];
              # This node DOES register, because half of what is under test is
              # the text of the generated nix.conf.
              custom.p2pCache.registerSubstituter = nixpkgs.lib.mkForce true;
              # And it does NOT serve from the store. This gate is about the
              # trust boundary, so every request must reach the (broken)
              # upstream copy; with the local store available the adapter
              # correctly answers from there and the gate proves nothing.
              # Source selection is the artifact-cache gate's subject, not this
              # one's.
              custom.p2pCache.serveFromStore = nixpkgs.lib.mkForce false;
            };
            testScript = ''
              ${setupUpstream}

              # ── Claim 2 first: the generated config ────────────────────────
              conf = machine.succeed("cat /etc/nix/nix.conf")
              assert "http://127.0.0.1:5111" in conf, conf

              # THE assertion. `?trusted=1` on a substituter URI makes Nix
              # accept paths signed by no trusted key — silently, exit 0, no
              # warning. Reproduced on real hardware; see the roadmap §2.1
              # spike 11. If this line ever fails, signature checking on this
              # host is decorative.
              for line in conf.splitlines():
                  if "127.0.0.1:5111" in line:
                      assert "trusted=" not in line, f"adapter registered as trusted: {line}"

              # Nobody is root-equivalent. Same invariant the plugin runtime
              # asserts; restated here because this module adds a substituter,
              # which is the other half of that trust anchor.
              assert "trusted-users = root\n" in conf or "trusted-users" not in conf, conf

              # ── Claim 1: an unsigned path is refused THROUGH us ────────────
              # Strip the signature from the upstream narinfo. The bytes are
              # genuine; only the signature is gone.
              # `hello`, and the node has serveFromStore off so the local
              # store cannot answer instead. Deliberately NOT the `solo` path
              # from the fixture: that one is content-addressed
              # (`nix-store --add`), and Nix does not require a signature for a
              # CA path — it re-derives the hash from the content. Stripping its
              # Sig proves nothing, and a version of this test that did so
              # passed while asserting nothing.
              machine.succeed(
                  f"grep -v '^Sig:' /tmp/upstream/{hp}.narinfo > /tmp/nosig && "
                  f"mv /tmp/nosig /tmp/upstream/{hp}.narinfo"
              )
              # Restarting clears the in-memory narinfo cache but NOT the
              # on-disk one, which survives a restart by design — that is what
              # lets the artifact cache work with upstream down. A test that
              # only restarted would be served the previously-cached SIGNED
              # narinfo and would pass while proving nothing.
              machine.succeed("rm -rf /var/lib/oligarchy/p2p/narinfo")
              machine.succeed("systemctl restart oligarchy-p2pd")
              machine.wait_until_succeeds("curl -sf http://127.0.0.1:5111/nix-cache-info", timeout=30)

              ours = machine.succeed(f"curl -sf http://127.0.0.1:5111/{hp}.narinfo")
              assert "Sig:" not in ours, "we invented a signature"

              machine.succeed("rm -f /root/.cache/nix/binary-cache-v*.sqlite*")
              out = machine.fail(
                  f"nix-store --realise {hello} --store /tmp/teststore2 "
                  f"--option substituters http://127.0.0.1:5111 "
                  f"--option require-sigs true "
                  f"--option trusted-public-keys '{pubkey}' 2>&1"
              )
              assert "not signed by any of the keys" in out or "lacks a signature" in out, out
              machine.fail(f"nix path-info --store /tmp/teststore2 {hello}")

              # ── And a corrupted body is refused BY US ─────────────────────
              # Rebuild the upstream with `compression=none`, so a flipped byte
              # produces a clean HASH MISMATCH rather than a decompressor error.
              # Both are refusals, but only one proves the digest check fired,
              # and this test exists to prove exactly that. The xz path is
              # covered by the artifact-cache gate and zstd by cache.nixos.org.
              machine.succeed("rm -rf /tmp/upstream && mkdir -p /tmp/upstream")
              machine.succeed(
                  f"nix copy --to 'file:///tmp/upstream?compression=none' {hello}"
              )
              machine.succeed("rm -rf /var/lib/oligarchy/p2p/narinfo /var/lib/oligarchy/p2p/nar")
              machine.succeed("rm -f /root/.cache/nix/binary-cache-v*.sqlite*")
              machine.succeed("systemctl restart oligarchy-p2pd")
              machine.wait_until_succeeds("curl -sf http://127.0.0.1:5111/nix-cache-info", timeout=30)

              # The URL we serve is derived from NarHash, not from upstream's
              # URL field — stage 2 made it a function of signed data only.
              ours = machine.succeed(f"curl -sf http://127.0.0.1:5111/{hp}.narinfo")
              f = dict(l.split(": ", 1) for l in ours.strip().split("\n"))
              narhash = f["NarHash"].split(":")[1]
              narsize = int(f["NarSize"])
              assert f["URL"] == f"nar/{hp}/{narhash}.nar", f["URL"]

              upstream_nar = machine.succeed(
                  f"awk '/^URL: /{{print $2}}' /tmp/upstream/{hp}.narinfo"
              ).strip()
              machine.succeed(
                  f"printf 'X' | dd of=/tmp/upstream/{upstream_nar} "
                  f"bs=1 seek={narsize - 40} count=1 conv=notrunc"
              )

              # Pull it directly: one thing under test, no decompressor and no
              # Nix in the way to fail first.
              got = machine.succeed(
                  f"curl -s -o /tmp/body -w '%{{size_download}}' "
                  f"http://127.0.0.1:5111/nar/{hp}/{narhash}.nar || true"
              ).strip()
              assert int(got) < narsize, f"served {got} of {narsize} bytes — the body completed"

              journal = machine.succeed("journalctl -u oligarchy-p2pd --no-pager")
              assert "REFUSED" in journal, journal
              assert "hash mismatch" in journal, journal

              # A refused fetch must leave NOTHING named in the cache, or every
              # later request would serve the bad bytes off disk.
              machine.fail(f"test -e /var/lib/oligarchy/p2p/nar/{narhash}.nar")

              machine.succeed("rm -f /root/.cache/nix/binary-cache-v*.sqlite*")
              machine.fail(
                  f"nix-store --realise {hello} --store /tmp/teststore3 "
                  f"--option substituters http://127.0.0.1:5111 "
                  f"--option require-sigs true "
                  f"--option trusted-public-keys '{pubkey}' 2>&1"
              )
              machine.fail(f"nix path-info --store /tmp/teststore3 {hello}")

              print("signature-refusal: no trusted= on the URI, unsigned path "
                    "refused, corrupted body refused BY THE ADAPTER with a named "
                    "hash mismatch, nothing published to the cache, and Nix "
                    "left without the path")
            '';
          };
        };
      });
}
