# ═══════════════════════════════════════════════════════════════════════════════
# custom.p2pCache — the Oligarchy P2P substituter.
#
# A local HTTP binary-cache adapter that Nix consults as an ordinary
# substituter. Stage 1 is a verifying pass-through proxy over the configured
# upstream caches; the peer-to-peer transport lands in later stages behind the
# same seam.
#
# THE INVARIANT THIS MODULE EXISTS TO HOLD: the adapter is never a trust
# authority. The DAEMON is unprivileged, holds no key, cannot write the store,
# nobody is in `nix.settings.trusted-users`, and the substituter URI it
# registers carries no `trusted=` parameter. Adding one would make Nix accept
# unsigned paths from it — silently, with exit 0 and no warning, verified on
# real hardware (see docs/p2p-substituter-roadmap.md §2.1 spike 11). The
# assertion below is the only thing standing between that and a future "just
# make it work" commit.
#
# TWO OPTIONS QUALIFY THAT, AND BOTH ARE OFF BY DEFAULT.
#
#   `servePackages` puts an Ed25519 signing key on this host so it can publish
#   paths it BUILT — which no cache has heard of, and which Nix therefore
#   refuses unsigned. The key is read by `oligarchy-p2p-seed.service`, a
#   separate root oneshot; it is not named in the daemon's config file and the
#   daemon never opens it. That split is deliberate: the process exposed to
#   hostile input is not the process holding the key. Note that signing does
#   write `/nix/var/nix/db` — the *daemon* still cannot, but the module can no
#   longer claim the subsystem as a whole touches nothing.
#
#   `trustedPublicKeys` is the other half, and it is the one with teeth. Nix
#   cannot scope a key to a set of paths: trusting a peer's key trusts it for
#   EVERY store path this host will ever substitute, and `priority = 30` puts
#   this adapter ahead of cache.nixos.org for all of them. A compromised
#   seeder can then serve signed bytes for any path at all. Extending that
#   trust is an operator decision made in the flake — nothing the transport
#   can do, and nothing this module does on its own.
#
# Design record + staging: docs/p2p-substituter-roadmap.md
# ═══════════════════════════════════════════════════════════════════════════════
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types optional literalExpression concatStringsSep;

  cfg = config.custom.p2pCache;

  substituterUrl = "http://${cfg.bindAddress}:${toString cfg.port}";

  configFile = pkgs.writeText "oligarchy-p2p-config.json" (builtins.toJSON {
    bind_address = cfg.bindAddress;
    port = cfg.port;
    store_dir = cfg.storeDir;
    priority = cfg.priority;
    upstreams = cfg.upstreams;
    upstream_timeout_secs = cfg.upstreamTimeout;
    state_dir = cfg.stateDir;
    max_cache_size = cfg.maxCacheSize;
    cache_downloaded = cfg.cacheDownloaded;
    serve_from_store = cfg.serveFromStore;
    transport = cfg.transport;
    peers = cfg.peers;
    peer_timeout_secs = cfg.peerTimeout;
    peer_listen = if cfg.peer.enable then cfg.peer.listenAddress else null;
    peer_port = cfg.peer.port;
    swarm_port = cfg.swarm.port;
    min_artifact_size = cfg.swarm.minArtifactSize;
    swarm_upload_bps = cfg.swarm.uploadBps;
    swarm_download_bps = cfg.swarm.downloadBps;

    # A bool, and deliberately nothing else. The declared path list and the
    # signing key reach `oligarchy-p2pd seed` on its own unit's ExecStart; this
    # file is what the DAEMON reads, and the daemon must not so much as know
    # where the key lives. (It is also world-readable, being in the store.)
    serve_declared = cfg.servePackages != [ ];

    # Not used to verify anything — Nix does that. Used to recognise which
    # signatures belong to a peer, so `accept_from_peers` can bound what they
    # are allowed to vouch for. Nix cannot scope a key to a set of paths; this
    # adapter can, because every peer narinfo passes through it.
    peer_public_keys = cfg.trustedPublicKeys;
    accept_from_peers = cfg.acceptFromPeers;
  });

  # The transitive closure of the declared packages, realised at build time.
  # `store-paths` is the list `oligarchy-p2pd seed` walks.
  declaredClosure = pkgs.closureInfo { rootPaths = cfg.servePackages; };

  # The daemon's confinement, shared verbatim with oligarchy-p2p-selftest.
  #
  # SHARED, not copied. The selftest's whole job is to prove these are really
  # in effect — `declared_refuses_a_write` attempts a write and expects EROFS —
  # and a check that ran under a near-copy of the sandbox would be testing
  # something the daemon does not run under. If these drift, the selftest starts
  # certifying a configuration nothing uses.
  sandbox = {
    # Modelled on modules/demod-talk/nixos-module.nix's stanza, which is the
    # maximal one in this repo, minus what an HTTP client genuinely needs.
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateUsers = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ cfg.stateDir ];
    # Nested read-only inside a read-write tree. `declared/` is generated by
    # root and only served by the daemon; without this the daemon could delete
    # what it is meant to publish, and the root-writes/daemon-reads split would
    # be a convention rather than an enforcement.
    #
    # The `-` prefix is load-bearing: without it systemd refuses to start the
    # unit at all when the path is absent, so a missing or removed declared/
    # would take the whole substituter down. An optional feature must never be
    # able to do that.
    ReadOnlyPaths = optional (cfg.servePackages != [ ]) "-${cfg.stateDir}/declared";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    # AF_INET/AF_INET6 for the loopback listener and the upstream client. No
    # AF_NETLINK, no AF_PACKET, no AF_UNIX — nothing here needs them, including
    # the store reads, which go through `nix-store --dump` rather than the
    # daemon socket precisely so this line can stay this short.
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    LockPersonality = true;
    # Nothing in this daemon generates code. Unlike the plugin runtime, where
    # this is decided per instance, here it is simply always true.
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
  };

  # Every substituter this host will consult, from wherever it was declared.
  # Scanned for `trusted=` below.
  allSubstituters =
    (config.nix.settings.substituters or [ ])
    ++ (config.nix.settings.trusted-substituters or [ ]);
in
{
  options.custom.p2pCache = {
    enable = mkEnableOption "the Oligarchy P2P substituter (local Nix binary-cache adapter)";

    package = mkOption {
      type = types.package;
      default = pkgs.oligarchy-p2pd;
      defaultText = literalExpression "pkgs.oligarchy-p2pd";
      description = "The adapter package. Comes from this sub-flake's overlay.";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address the adapter listens on. **Must be a loopback address.** The Nix
        binary cache protocol has no authentication, and this adapter will
        proxy any store path its upstreams hold; exposing it to a network turns
        it into an open cache proxy. Enforced by an assertion here, again by the
        daemon's config validation, and a third time immediately before the
        `bind()` syscall — the three can drift, and the consequence of drift is
        not recoverable by the time anyone notices.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5111;
      description = ''
        Loopback port. Deliberately outside the 7xxx range, which is DCF
        territory (see modules/mcp-servers/crates/ports-sec/src/known_endpoints.rs
        — register this port there too).
      '';
    };

    priority = mkOption {
      type = types.int;
      default = 30;
      description = ''
        Advertised in `nix-cache-info`. **Lower is consulted first**, and
        cache.nixos.org publishes 40 — so the default puts this adapter ahead of
        it, which is the point: a substituter Nix consults second only gets asked
        for paths the first one does not have.

        This is a deliberate trade, not an oversight. It means an adapter bug
        degrades all substitution rather than only P2P-eligible paths. The
        mitigations are that the daemon fails closed to a 404 on any internal
        error, `Restart=on-failure`, and the upstream caches staying configured
        behind it.
      '';
    };

    upstreams = mkOption {
      type = types.listOf types.str;
      default = [ "https://cache.nixos.org" ];
      description = ''
        Binary caches the adapter proxies, tried in order. These are HTTP
        endpoints for the adapter's own client, **not** Nix substituters — Nix
        never sees them. They must be `http://` or `https://`, and none may
        carry a `trusted=` parameter.
      '';
    };

    upstreamTimeout = mkOption {
      type = types.int;
      default = 20;
      description = ''
        Seconds to wait for an upstream narinfo. Kept well below Nix's own
        `stalled-download-timeout` (300s) so a slow upstream surfaces as a fast
        404 and a fall-through rather than a stalled build.
      '';
    };

    storeDir = mkOption {
      type = types.str;
      default = builtins.storeDir;
      defaultText = literalExpression "builtins.storeDir";
      description = ''
        Advertised as `StoreDir` in `nix-cache-info`. Nix refuses a cache whose
        StoreDir does not match its own, so this must track the real store.
      '';
    };

    transport = mkOption {
      type = types.enum [ "none" "lan" "bittorrent" ];
      default = "none";
      description = ''
        Where the adapter looks for artifacts before falling back to
        `upstreams`.

        - `none` — no peers. The adapter is a verifying cache in front of
          upstream and behaves exactly as it did before peers existed. This is
          the default, and it is what makes "P2P is an enhancement, never a
          requirement" structural rather than aspirational.
        - `lan` — other Oligarchy hosts named in `peers`, over plain HTTP. One
          peer at a time, serially. Simple, and for a two-machine site it is all
          you need.
        - `bittorrent` — the same peers, but pieces pulled from all of them at
          once. The win is parallel multi-peer transfer, so it is worth having
          from roughly three peers upward and buys nothing at two. Discovery is
          still the LAN peer surface: **no DHT, no trackers, no PEX**, because
          every address dialled has to come from the private-range peer list for
          this to work under `strict-egress` unchanged.

        There is no sniffing and no silent fallback between transports: an
        unrecognised value is a startup failure, not a machine that quietly has
        no peers.
      '';
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "192.168.1.20:5112" "100.64.0.3:5112" ];
      description = ''
        Peers as `ip:port`, pointing at their `peer.port`.

        **Private ranges only** — RFC1918, CGNAT/tailnet (100.64.0.0/10) and
        link-local. A routable address is dropped with a loud log line rather
        than being refused at startup, because an optional transport must not be
        able to take the substituter down.

        This is the same set `modules/security/strict-egress.nix` already puts
        in its *static* allow list, which is why a LAN swarm needs no firewall
        change on the egress side. Peers reached over Tailscale work for the
        same reason.
      '';
    };

    peerTimeout = mkOption {
      type = types.int;
      default = 10;
      description = ''
        Seconds a peer has to answer before the adapter gives up and goes
        upstream. Kept well under Nix's `stalled-download-timeout` (300s) so an
        unreachable peer costs a pause, not a failed build.
      '';
    };

    swarm = {
      port = mkOption {
        type = types.port;
        default = 6881;
        description = ''
          BitTorrent listen port, advertised to peers in `/peer/v1/info` so they
          know where to dial. Opened on the same interfaces as
          `peer.openFirewall` — a swarm needs inbound connections to be more
          than a leech.
        '';
      };

      minArtifactSize = mkOption {
        type = types.str;
        default = "4M";
        description = ''
          Artifacts smaller than this never enter a swarm; they come from a peer
          over plain HTTP or from upstream.

          The default is measured rather than guessed. Over this workstation's
          live closure (4096 paths, 48.6 GiB) the **median NAR is 355 KiB**, and
          a swarm per NAR would be pathological — announce and handshake
          overhead dominates and almost every swarm has one peer. At 4 MiB,
          16.4% of paths enter swarms and still cover **96.0% of the bytes**.
          The knee sits between 4 and 8 MiB. See
          `docs/p2p-substituter-roadmap.md` §4.1.

          The sample is a desktop- and dev-heavy closure, so a stage rig or a
          shipped instrument may want its own number.
        '';
      };

      uploadBps = mkOption {
        type = types.int;
        default = 0;
        example = 20 * 1024 * 1024;
        description = "Swarm upload limit in bytes per second. 0 is unlimited.";
      };

      downloadBps = mkOption {
        type = types.int;
        default = 0;
        example = 100 * 1024 * 1024;
        description = "Swarm download limit in bytes per second. 0 is unlimited.";
      };
    };

    peer = {
      enable = mkEnableOption ''
        the peer surface — a SECOND listener, on a real interface, that lets
        other hosts fetch artifacts this one already holds.

        Separate from the substituter listener on purpose. That one is
        loopback-only and will proxy anything its upstreams have; exposing it
        would publish an open cache proxy for the whole of cache.nixos.org. The
        peer surface answers a smaller question — *do you already have this?* —
        and never triggers an upstream fetch on a peer's behalf
      '';

      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = ''
          Address for the peer surface. A wildcard is fine and is the default:
          what makes it reachable is `peer.openFirewall`, which opens the port
          on named interfaces only. Following the same per-interface convention
          as `services.demod-talk` and `services.dcf-hypr-agent`, a routable
          unicast address is refused outright.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 5112;
        description = "Port for the peer surface. Register it in known_endpoints.rs.";
      };

      openFirewall = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "enp0s31f6" "tailscale0" ];
        description = ''
          Interfaces on which to open `peer.port`. **Empty by default**, so
          enabling the peer surface does not by itself expose anything — you
          name the interfaces, exactly as `services.demod-talk` does, rather
          than opening globally.

          Note that `tailscale0` is deliberately not a trusted interface on this
          host, so naming it here admits every peer in your tailnet.
        '';
      };
    };

    logLevel = mkOption {
      type = types.str;
      default = "info";
      example = "oligarchy_p2pd=debug";
      description = ''
        `RUST_LOG` filter for the daemon. At `info` the journal carries one line
        per served NAR naming which source answered — cache, nix-store or
        upstream — which is how you tell a working cache from an expensive
        proxy, plus every refusal. Raise it to `oligarchy_p2pd=debug` to also see
        narinfo resolution and cache writes; that also pulls in `hyper`'s
        connection chatter unless you scope it as in the example.
      '';
    };

    registerSubstituter = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add the adapter to `nix.settings.substituters`. Turn this off to run the
        daemon without Nix consulting it — useful when bringing a host up, or
        when testing the adapter by hand with `nix build --substituters`.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "oligarchy-p2p";
      description = ''
        Static system user the daemon runs as. Deliberately **not**
        `DynamicUser`: `strict-egress`'s `allow.uids` escape hatch matches on
        `meta skuid "<name>"`, which nft resolves against the passwd database at
        ruleset-load time, so a runtime-allocated uid cannot be named there. A
        later stage that needs peer egress will need this account to exist.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "oligarchy-p2p";
      description = "Group the daemon runs as.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/oligarchy/p2p";
      description = ''
        Where the local artifact cache lives: `nar/` holds verified NARs named
        by their `NarHash`, `tmp/` holds in-flight fetches. Both must be on the
        same filesystem — publishing a cache entry is a `rename(2)`, and its
        atomicity is what guarantees a name never refers to unverified bytes.
      '';
    };

    maxCacheSize = mkOption {
      type = types.str;
      default = "20G";
      example = "100G";
      description = ''
        Ceiling for the artifact cache. Bare bytes, or a `K`/`M`/`G`/`T` suffix
        in binary units. Eviction is least-recently-used and runs at startup and
        after each insert.

        LRU rather than insertion order matters here more than it usually does:
        the artifacts worth caching are large, built rarely and reused for
        months (a toolchain, a browser), while small paths churn constantly.
        Evicting by insertion order would throw away exactly the entries that
        pay for themselves.
      '';
    };

    cacheDownloaded = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep a verified copy of every NAR fetched from upstream. This is what
        upgrades later requests for the same path from "streamed and verified as
        it goes" to "verified in full before a byte is sent", and in a later
        stage it is what gives this host something to serve to peers.
      '';
    };

    servePackages = mkOption {
      type = types.listOf types.pathInStore;
      default = [ ];
      example = literalExpression ''[ pkgs.my-thing self.packages.x86_64-linux.thing ]'';
      description = ''
        Packages this host BUILDS and publishes to peers.

        Without this, a host can only seed what it *fetched*. A locally-built
        path has a narinfo nowhere — nothing ever resolved one — and a peer
        cannot verify a NAR without the signed `NarHash` that lives in one. So
        a machine that substituted a rebuild was a good seeder and a machine
        that compiled it was useless, which is backwards for a distro whose
        point is artifacts no public cache has.

        Listing a package here does four things: it is built by
        `nixos-rebuild`, it is added to {option}`system.extraDependencies` so
        the garbage collector keeps it, its closure is signed with
        {option}`custom.p2pCache.signingKeyFile`, and a narinfo is published
        under `declared/` in {option}`custom.p2pCache.stateDir`, where the peer
        surface serves it.

        **Only paths with no signature at all are signed and published** — the
        ones this host actually built. The rest of the closure already carries
        cache.nixos.org's signature and resolves the ordinary way; re-signing
        it would put this host's name on glibc, permanently, in the Nix
        database, for nothing.

        Note that a package coerces to its **default output** here, the same as
        in {option}`system.extraDependencies`. To publish `foo.dev` or
        `foo.lib`, list them.

        A consumer must add this host's public key to
        {option}`custom.p2pCache.trustedPublicKeys` before it will accept any
        of this. Read that option's description first — it is the one with
        teeth.
      '';
    };

    signingKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/oligarchy/p2p/cache.sec";
      description = ''
        Path to the Ed25519 secret key that signs {option}`servePackages`.

        A **runtime** path, deliberately typed `str` rather than `path`: a path
        literal would copy the private key into the world-readable Nix store.
        Point it outside the store, or at `config.sops.secrets."<name>".path`.

        Create one with:

        ```
        nix key generate-secret --key-name <host>-1 > /var/lib/oligarchy/p2p/cache.sec
        chmod 0400 /var/lib/oligarchy/p2p/cache.sec
        nix key convert-secret-to-public < /var/lib/oligarchy/p2p/cache.sec
        ```

        The last line prints the half to paste into peers'
        {option}`trustedPublicKeys`. The key is read only by
        `oligarchy-p2p-seed.service`, which runs as root; it is not named in
        the daemon's config file and the daemon never opens it. Seeding is
        refused if the file is readable by anyone but its owner.
      '';
    };

    acceptFromPeers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "my-thing" "my-lib" ]'';
      description = ''
        Which packages a trusted peer key is allowed to vouch for.

        **Nix cannot scope a signing key to a set of store paths.** Once a key
        is in {option}`nix.settings.trusted-public-keys` it is trusted for
        everything, and {option}`custom.p2pCache.priority` (30) puts this
        adapter ahead of cache.nixos.org for every path — so an unscoped
        compromised seeder can serve signed bytes for glibc and win the race.

        Nix cannot bound it. This adapter can, because every narinfo a peer
        supplies passes through it. Entries take three forms:

        - a bare package name, matched exactly or with a version suffix, so
          `my-thing` accepts `my-thing-1.2.3` and `my-thing-1.2.3-dev`. The
          suffix must begin with a digit, which is what stops `glibc` reaching
          `glibc-locales` and `linux` reaching `linux-firmware`;
        - a full `/nix/store/...` path, matched exactly — the tightest grant,
          and usable when a flake pins the version;
        - `"*"`, which accepts anything those keys sign. That is the
          unscoped behaviour, chosen deliberately and warned about.

        Two limits worth knowing. The scoping is enforced **by this adapter**,
        so it binds only paths obtained through it — an operator who adds a peer
        directly to {option}`nix.settings.substituters`, or runs
        `nix copy --from`, is outside it. And the name is supplied by the peer;
        Nix independently requires the substituted path's name to match the one
        it asked for, but this option is a bound on what a peer may *claim*.
      '';
    };

    trustedPublicKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "nixos-p2p-1:kBnLtBEr6M9v5Zk2..." ]'';
      description = ''
        Public keys this host will accept signatures from, added to
        {option}`nix.settings.trusted-public-keys`. Set this on a CONSUMER to
        accept packages a peer built.

        **Understand the blast radius before setting this.** Nix has no way to
        scope a key to a set of paths. Trusting a peer's key trusts it for
        *every* store path this host will ever substitute, from every
        substituter — not merely for the packages that peer meant to publish.
        Combined with {option}`custom.p2pCache.priority` (30, ahead of
        cache.nixos.org), a compromised or malicious holder of that key can
        serve signed bytes for any path at all and this host will register them
        as valid.

        For an input-addressed path the signature is the entire trust anchor;
        the adapter's own `NarHash` check does not help, because whoever
        controls the bytes controls the narinfo too. This is categorically
        different from leaving the list empty, where peers are sources of bytes
        and nothing else and removing every peer changes throughput but not
        correctness.

        Trust hosts you administer, on networks you control.
      '';
    };

    serveFromStore = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Answer from the local Nix store when this host already holds the path,
        via `nix-store --dump`, instead of fetching it from upstream.

        The output is hashed against the signed `NarHash` like every other
        source, so a path that is present-but-invalid — the debris a failed
        substitution leaves on disk — fails verification and falls through
        rather than being served. We never ask Nix whether the path is valid;
        verifying is cheaper than asking and answers the question that matters.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem cfg.bindAddress [ "127.0.0.1" "::1" "localhost" ];
        message = ''
          custom.p2pCache.bindAddress is "${cfg.bindAddress}", which is not
          loopback. The adapter speaks the Nix binary cache protocol with no
          authentication and will proxy any store path its upstreams hold —
          binding it to a routable address publishes an open cache proxy.

          If you want other hosts to fetch from this machine, that is what the
          peer transport is for. It is not this option.
        '';
      }
      {
        assertion = !(lib.any (u: lib.hasInfix "trusted=" u) cfg.upstreams);
        message = ''
          custom.p2pCache.upstreams contains an entry with a `trusted=`
          parameter. That flag has no meaning for this adapter's HTTP client, so
          its presence can only be a copy-paste from a substituter list — where
          it DOES have meaning, and disables signature checking entirely.
        '';
      }
      {
        # The one that must never regress. Verified on real hardware: with
        # `require-sigs true` and only the upstream key trusted, appending
        # `?trusted=1` to a substituter URI caused an UNSIGNED path to be
        # accepted and registered valid, exit 0, no warning of any kind.
        # See docs/p2p-substituter-roadmap.md §2.1 spike 11.
        assertion = !(lib.any (u: lib.hasInfix "trusted=" u) allSubstituters);
        message = ''
          A substituter on this host carries a `trusted=` parameter:

            ${concatStringsSep "\n  " (lib.filter (u: lib.hasInfix "trusted=" u) allSubstituters)}

          `trusted=1` makes Nix accept paths from that substituter even when
          they are signed by no key in `trusted-public-keys` — silently, with
          exit code 0 and no diagnostic. It defeats the entire trust model this
          subsystem is built on, and there is no runtime signal that it has
          happened.

          If a substituter is serving paths this host cannot verify, the fix is
          to add its public key to `trusted-public-keys`, not to stop checking.
        '';
      }
      {
        assertion = cfg.transport == "none" -> cfg.peers == [ ];
        message = ''
          custom.p2pCache.peers is set but transport is "none", so none of them
          will ever be contacted. Set transport = "lan" or clear the list —
          silently ignoring configuration is worse than refusing it.
        '';
      }
      {
        assertion = cfg.transport != "lan" || cfg.peers != [ ] || cfg.peer.enable;
        message = ''
          custom.p2pCache.transport = "lan" but there are no peers and the peer
          surface is off, so this host neither fetches from anyone nor serves
          anyone. Set custom.p2pCache.peers, or enable custom.p2pCache.peer, or
          leave transport at "none".
        '';
      }
      {
        assertion = cfg.transport != "bittorrent" || cfg.peer.enable;
        message = ''
          custom.p2pCache.transport = "bittorrent" needs custom.p2pCache.peer
          enabled. The swarm has no DHT and no trackers by design, so the peer
          surface is the ONLY way another host can learn this one's infohashes
          and swarm port — without it this host can leech and can never seed,
          and a swarm where nobody seeds does not form.
        '';
      }
      {
        assertion = cfg.transport != "bittorrent" || cfg.swarm.port != cfg.peer.port;
        message = ''
          custom.p2pCache.swarm.port and .peer.port are both
          ${toString cfg.swarm.port}. They are two different listeners and
          cannot share a port.
        '';
      }
      {
        assertion = cfg.upstreams != [ ] || cfg.servePackages != [ ];
        message = ''
          custom.p2pCache.upstreams is empty and nothing is declared in
          servePackages. The adapter would have nothing to serve, and every
          narinfo lookup would be a 404 that Nix caches for an hour
          (narinfo-cache-negative-ttl).

          A pure seeder — a build host that publishes only what it built and
          proxies nothing — is legitimate; set servePackages.
        '';
      }
      {
        assertion = cfg.trustedPublicKeys == [ ] || cfg.acceptFromPeers != [ ];
        message = ''
          custom.p2pCache.trustedPublicKeys is set but acceptFromPeers is empty.

          Nix cannot scope a signing key to a set of store paths. A trusted peer
          key vouches for EVERY path this host will ever substitute, and
          priority ${toString cfg.priority} puts this adapter ahead of
          cache.nixos.org for all of them — so a compromised holder of that key
          could serve signed bytes for glibc and be believed.

          Nix cannot bound that. This adapter can, but only if you say what the
          peer is allowed to speak for:

            custom.p2pCache.acceptFromPeers = [ "my-thing" ];

          Or, to accept anything those keys sign — the unscoped behaviour, and a
          real choice rather than an oversight:

            custom.p2pCache.acceptFromPeers = [ "*" ];
        '';
      }
      {
        assertion = cfg.servePackages == [ ] || cfg.signingKeyFile != null;
        message = ''
          custom.p2pCache.servePackages is set but signingKeyFile is not.

          A locally-built path has no signature anywhere, and Nix refuses an
          unsigned substitute outright ("lacks a signature by a trusted key").
          Without a key the declared packages are unusable to every peer, so
          this is a build-time error rather than a runtime surprise.

            nix key generate-secret --key-name ${config.networking.hostName}-p2p-1 \
              > /var/lib/oligarchy/p2p/cache.sec
            chmod 0400 /var/lib/oligarchy/p2p/cache.sec
            nix key convert-secret-to-public < /var/lib/oligarchy/p2p/cache.sec

          The last line prints the half to paste into peers' trustedPublicKeys.
        '';
      }
      {
        assertion = cfg.signingKeyFile == null
          || !(lib.hasPrefix builtins.storeDir cfg.signingKeyFile);
        message = ''
          custom.p2pCache.signingKeyFile points into ${builtins.storeDir},
          which is world-readable. A signing key there is a signing key every
          user on this machine holds.

          Use a runtime path, or config.sops.secrets."<name>".path.
        '';
      }
      {
        assertion = cfg.servePackages == [ ] || cfg.serveFromStore;
        message = ''
          custom.p2pCache.servePackages is set but serveFromStore is false.

          Declaring a package publishes its narinfo; the NAR bytes are produced
          on demand by `nix-store --dump`, which is exactly what serveFromStore
          gates. With it off the whole feature is inert: peers get metadata,
          `/peer/v1/have` answers 404, and nothing is ever materialised.
        '';
      }
      {
        assertion = cfg.servePackages == [ ] || cfg.peer.enable;
        message = ''
          custom.p2pCache.servePackages is set but peer.enable is false.

          The peer surface is the only way another host can reach a declared
          package. Signing paths nobody can ask for is a no-op that looks like
          a feature.
        '';
      }
    ];

    warnings =
      optional (cfg.priority >= 40) ''
        custom.p2pCache.priority is ${toString cfg.priority}, which is at or
        behind cache.nixos.org's 40. Nix consults substituters in ascending
        priority order and stops at the first that has the path, so the adapter
        will only ever be asked for paths upstream does not have — which, since
        it proxies that same upstream, is none of them. It will do nothing.
      ''
      ++ optional (cfg.cacheDownloaded && cfg.maxCacheSize == "0") ''
        custom.p2pCache.cacheDownloaded is true but maxCacheSize is "0", so
        every fetched artifact is evicted immediately after it is written. The
        adapter will work, but every request will go to upstream and the disk
        writes are pure waste. Set a real budget or turn cacheDownloaded off.
      ''
      ++ optional (cfg.peer.enable && cfg.peer.openFirewall == [ ]) ''
        custom.p2pCache.peer is enabled but peer.openFirewall names no
        interfaces, so the listener is up and the firewall drops everything that
        reaches it. That is a safe default rather than a broken one — name the
        interfaces your peers are on to make it useful.
      ''
      ++ optional (cfg.peer.enable && builtins.elem "tailscale0" cfg.peer.openFirewall) ''
        custom.p2pCache.peer is open on tailscale0, which means every peer in
        your tailnet can enumerate and fetch the store paths this host holds.
        This host's own policy treats tailscale0 as untrusted for exactly that
        reason (see networking.firewall in configuration.nix). Restrict it with
        a Tailscale ACL if the tailnet is not solely yours.
      ''
      ++ optional (cfg.peer.enable) ''
        custom.p2pCache.peer is enabled. Anyone who can reach peer.port can list
        which store paths this machine holds, which discloses roughly what it
        builds and runs. That is inherent to serving artifacts and is scoped to
        the interfaces named in peer.openFirewall; there is no authentication.
      ''
      ++ optional (cfg.servePackages != [ ]) ''
        custom.p2pCache.servePackages is set, so this host now holds an Ed25519
        signing key and publishes ${toString (builtins.length cfg.servePackages)}
        package(s) it built to its peers.

        Two consequences worth knowing. The declared set is a stable, guessable
        list rather than an incidental cache, so it discloses more about this
        machine than the peer surface alone. And signing writes /nix/var/nix/db,
        so this host's signature travels with those paths through `nix copy`,
        `nix path-info --sigs` and ssh-ng — not only through this adapter.

        The key is read by oligarchy-p2p-seed.service (root) and never by the
        daemon. Keep it that way: a key the daemon's user can read is a key
        reachable from the network-facing process.
      ''
      ++ optional (cfg.trustedPublicKeys != [ ]) ''
        custom.p2pCache.trustedPublicKeys is not empty, so this host will accept
        store paths signed by ${toString (builtins.length cfg.trustedPublicKeys)}
        key(s) beyond nixpkgs' own.

        Nix cannot scope a key to a set of paths. Each key here is trusted for
        EVERY store path this host will ever substitute, from every substituter
        — and priority ${toString cfg.priority} puts this adapter ahead of
        cache.nixos.org for all of them. Whoever holds one of these keys can
        serve signed bytes for any path at all and this host will register them
        as valid.

        This is the one setting in this module that extends trust. Set it only
        for hosts you administer.
      ''
      ++ optional (builtins.elem "*" cfg.acceptFromPeers) ''
        custom.p2pCache.acceptFromPeers contains "*", so a trusted peer key
        vouches for EVERY store path this host substitutes — the unscoped
        behaviour, which is what the option exists to avoid.

        That is a legitimate choice for hosts you administer on a network you
        control, and it is the only way to express "the whole closure this peer
        published" while scoping is name-based. Naming the packages is
        materially safer: it turns "this host is trusted for everything" into
        "this host is trusted for these", which is the difference between a
        compromised seeder replacing glibc and one replacing only what it was
        meant to publish.
      ''
      ++ optional (cfg.upstreams == [ ] && cfg.registerSubstituter) ''
        custom.p2pCache has no upstreams but is registered as a substituter, so
        Nix will ask this adapter first (priority ${toString cfg.priority}) for
        every path and get a 404 for everything except the declared packages.
        That costs a loopback round trip per path and nothing else, but if you
        did not mean to run a pure seeder, set upstreams.
      ''
      ++ optional (!cfg.registerSubstituter) ''
        custom.p2pCache.registerSubstituter is false, so the daemon will run but
        Nix will not consult it. Nothing will use the adapter until this is true
        or you pass --substituters by hand.
      '';

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      description = "Oligarchy P2P substituter";
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/nar 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/tmp 0750 ${cfg.user} ${cfg.group} -"
    ]
    # `declared/` is ROOT-owned and the daemon gets it read-only (see
    # ReadOnlyPaths below), because it is generated state: root mints and signs
    # it, the daemon only serves it. `narinfo/` is deliberately NOT here — the
    # daemon creates that one itself, since it owns it. Do not "tidy" the two
    # into the same shape; the asymmetry is the access control.
    ++ optional (cfg.servePackages != [ ])
      "d ${cfg.stateDir}/declared 0755 root root -";

    environment.etc."oligarchy/p2p/config.json".source = configFile;

    # Per-interface, never global, and never `trustedInterfaces` — the same
    # shape services.demod-talk and services.dcf-hypr-agent use.
    networking.firewall.interfaces = lib.genAttrs cfg.peer.openFirewall (_: {
      # The swarm port travels with the peer surface: a BitTorrent peer that
      # cannot accept inbound connections can only leech, and a swarm of pure
      # leeches transfers nothing.
      allowedTCPPorts = [ cfg.peer.port ]
        ++ optional (cfg.transport == "bittorrent") cfg.swarm.port;
    });

    # Definitions, not defaults, so they MERGE with nixpkgs' own
    # (cache.nixos.org and its key) rather than replacing them. Upstream stays
    # configured behind us on purpose: if this daemon is down or wrong, Nix
    # must still be able to build the system that fixes it.
    #
    # Note what is NOT here: no `trusted-users` and no `trusted=` on the URI.
    #
    # `trusted-public-keys` IS here, and only ever from `trustedPublicKeys`,
    # which defaults to empty. With it empty this adapter adds a source of
    # bytes and zero new trust, exactly as it always did. With it set, the
    # operator has extended trust to another host — deliberately, in the flake,
    # where it is reviewable. Nothing in the transport can do that on its own:
    # a peer cannot cause its key to be trusted, and this module never derives
    # a key from a peer address.
    nix.settings = lib.mkMerge [
      (mkIf cfg.registerSubstituter {
        substituters = [ substituterUrl ];
        trusted-substituters = [ substituterUrl ];
      })
      (mkIf (cfg.trustedPublicKeys != [ ]) {
        trusted-public-keys = cfg.trustedPublicKeys;
      })
    ];

    # Keep the declared packages out of the garbage collector's reach by making
    # them references of the system closure. Without this a `nix-collect-garbage`
    # deletes exactly what this host advertises, and the peer surface starts
    # 404ing paths whose narinfo it is still serving.
    system.extraDependencies = cfg.servePackages;

    environment.systemPackages = [
      cfg.package

      # Read-only, and the one the MCP `net` aspect is allowed to call.
      (pkgs.writeShellScriptBin "oligarchy-p2p-status" ''
        exec ${cfg.package}/bin/oligarchy-p2pd \
          --config /etc/oligarchy/p2p/config.json status "$@"
      '')

      # Runs the UNIT, not the binary, so the checks execute inside the
      # daemon's confinement as the daemon's user. Running the binary directly
      # from a root shell would report a false PASS on the one check that
      # matters most.
      (pkgs.writeShellScriptBin "oligarchy-p2p-selftest" ''
        set -u
        ${pkgs.systemd}/bin/systemctl start --wait oligarchy-p2p-selftest.service
        rc=$?
        # Scoped to THIS invocation, not a time window: two runs a minute apart
        # would otherwise interleave and the report would show checks from a
        # run the operator is not looking at — which is the failure mode this
        # whole command exists to end.
        id=$(${pkgs.systemd}/bin/systemctl show -p InvocationID --value \
               oligarchy-p2p-selftest.service)
        if [ -n "$id" ]; then
          ${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$id" --no-pager -o cat
        else
          ${pkgs.systemd}/bin/journalctl -u oligarchy-p2p-selftest.service \
            --no-pager -o cat -n 200
        fi
        exit "$rc"
      '')
    ];

    # ── The seeder ─────────────────────────────────────────────────────────
    #
    # A SEPARATE unit, and the separation is the whole mitigation. Minting a
    # narinfo needs two things the daemon is deliberately denied: the Ed25519
    # signing key, and the Nix database (`nix store sign` / `nix path-info`
    # reach nix-daemon over AF_UNIX, which the daemon's
    # RestrictAddressFamilies excludes on purpose). Folding this into
    # oligarchy-p2pd would hand a signing key to the process that parses
    # hostile input from the network.
    #
    # It runs as root, writes ${cfg.stateDir}/declared, and exits.
    systemd.services.oligarchy-p2p-seed =
      mkIf (cfg.servePackages != [ ] && cfg.signingKeyFile != null) {
        description = "Sign and publish the P2P substituter's declared packages";
        documentation = [ "https://github.com/ALH477/Oligarchy" ];
        wantedBy = [ "multi-user.target" ];

        # BEFORE the daemon, so a fresh boot has the declared narinfos in place
        # before anything can ask for one — `AppState::resolve` memoises negative
        # answers, and Nix caches a 404 for an hour on top of that.
        #
        # `before` and NOT `requiredBy`/`bindsTo`: a seeding failure must never
        # take the substituter down. The same reason a bad peer entry is a log
        # line rather than a fatal error.
        before = [ "oligarchy-p2pd.service" ];
        after = [ "systemd-tmpfiles-setup.service" "nix-daemon.socket" ];

        # Re-run when the declared set changes, not only at boot.
        restartTriggers = [ declaredClosure configFile ];

        path = [ config.nix.package ];

        # `[Unit]`, NOT `[Service]`. Condition* directives live in the unit
        # section; systemd ignores an unknown key in `[Service]` with only a
        # log line, so putting it in serviceConfig would silently disable the
        # check and make the unit FAIL at every boot where the key has not been
        # decrypted yet, instead of being skipped.
        #
        # The key may arrive from sops, which decrypts during activation. If it
        # is not there yet, do nothing rather than fail loudly every boot; the
        # daemon logs the empty declared tier either way.
        unitConfig.ConditionPathExists = cfg.signingKeyFile;

        serviceConfig = {
          Type = "oneshot";
          # Required, not cosmetic. switch-to-configuration only restarts units
          # that are ACTIVE; a oneshot without this is inactive the moment it
          # finishes, so restartTriggers would have nothing to restart and
          # declared/ would silently go stale across every rebuild.
          RemainAfterExit = true;
          User = "root";
          UMask = "0022";

          ExecStart = concatStringsSep " " [
            "${cfg.package}/bin/oligarchy-p2pd"
            "--config /etc/oligarchy/p2p/config.json"
            "seed"
            "--store-paths ${declaredClosure}/store-paths"
            "--key-file ${cfg.signingKeyFile}"
          ];

          Environment = [ "RUST_LOG=${cfg.logLevel}" ];

          # Modest, but this one legitimately writes the Nix database and reads a
          # secret, so it cannot inherit the daemon's posture.
          NoNewPrivileges = true;
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
        };
      };

    # ── The selftest ───────────────────────────────────────────────────────
    #
    # A unit rather than a bare CLI, and the reason is the whole point of the
    # command. `declared_refuses_a_write` proves `ReadOnlyPaths` is in effect by
    # attempting a write and expecting it to fail — which only means anything
    # inside the daemon's confinement, as the daemon's user. Run from a shell as
    # root it would write successfully and report a false PASS, so it reports a
    # loud SKIP there instead.
    #
    # Shares `sandbox` verbatim with oligarchy-p2pd. Not `wantedBy` anything:
    # this is asserted on demand and by the VM gate, following `plugind
    # selftest`, which is likewise a gate assertion rather than a boot step.
    systemd.services.oligarchy-p2p-selftest = {
      description = "Assert the P2P substituter's guarantees on this host";
      documentation = [ "https://github.com/ALH477/Oligarchy" ];
      after = [ "oligarchy-p2pd.service" ];

      serviceConfig = {
        Type = "oneshot";
        # Deliberately NOT RemainAfterExit: `systemctl start --wait` returns
        # when the unit stops, and the wrapper below relies on that to
        # propagate the exit status.
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "oligarchy/p2p";
        StateDirectoryMode = "0750";
        Environment = [ "RUST_LOG=${cfg.logLevel}" ];
        ExecStart =
          "${cfg.package}/bin/oligarchy-p2pd --config /etc/oligarchy/p2p/config.json selftest";
      } // sandbox // {
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
      };
    };

    systemd.services.oligarchy-p2pd = {
      description = "Oligarchy P2P substituter (Nix binary-cache adapter)";
      documentation = [ "https://github.com/ALH477/Oligarchy" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "nss-lookup.target" ];

      # Restart when the declared set changes. `AppState::resolve` memoises
      # NEGATIVE answers for 60s, and Nix caches the resulting 404 for an hour
      # per substituter — so a package added by a rebuild could otherwise be
      # unavailable through the adapter long after it was published.
      restartTriggers = optional (cfg.servePackages != [ ]) declaredClosure;

      # `nix-store --dump` for serveFromStore. Deliberately the OLD CLI: it
      # serialises a directory and consults nothing else, so the daemon needs no
      # access to the Nix database and never opens the nix-daemon socket. That
      # is what lets RestrictAddressFamilies below stay free of AF_UNIX.
      path = optional cfg.serveFromStore config.nix.package;

      # NOT `before = [ "nix-daemon.service" ]`. nix-daemon is socket-activated
      # and must be able to start without us; ordering it behind this unit would
      # make a broken adapter a broken Nix.
      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.package}/bin/oligarchy-p2pd --config /etc/oligarchy/p2p/config.json daemon";
        ExecStartPre = "${cfg.package}/bin/oligarchy-p2pd --config /etc/oligarchy/p2p/config.json check";

        Environment = [ "RUST_LOG=${cfg.logLevel}" ];

        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 2;

        StateDirectory = "oligarchy/p2p";
        StateDirectoryMode = "0750";

        MemoryMax = "1G";
        TasksMax = 64;
        UMask = "0077";

      } // sandbox // {
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
      };
    };
  };

  meta.maintainers = [ "ALH477" ];
}
