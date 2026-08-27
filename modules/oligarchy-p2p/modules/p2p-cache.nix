# ═══════════════════════════════════════════════════════════════════════════════
# custom.p2pCache — the Oligarchy P2P substituter.
#
# A local HTTP binary-cache adapter that Nix consults as an ordinary
# substituter. Stage 1 is a verifying pass-through proxy over the configured
# upstream caches; the peer-to-peer transport lands in later stages behind the
# same seam.
#
# THE INVARIANT THIS MODULE EXISTS TO HOLD: the adapter is never a trust
# authority. It is unprivileged, it cannot write the store, nobody is in
# `nix.settings.trusted-users`, and the substituter URI it registers carries no
# `trusted=` parameter. Adding one would make Nix accept unsigned paths from it
# — silently, with exit 0 and no warning, verified on real hardware (see
# docs/p2p-substituter-roadmap.md §2.1 spike 11). The assertion below is the
# only thing standing between that and a future "just make it work" commit.
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
  });

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
        assertion = cfg.upstreams != [ ];
        message = ''
          custom.p2pCache.upstreams is empty. Stage 1 is a proxy — with no
          upstream it can serve nothing, and every narinfo lookup would be a
          404 that Nix caches for an hour (narinfo-cache-negative-ttl).
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
    ];

    environment.etc."oligarchy/p2p/config.json".source = configFile;

    # Definitions, not defaults, so they MERGE with nixpkgs' own
    # (cache.nixos.org and its key) rather than replacing them. Upstream stays
    # configured behind us on purpose: if this daemon is down or wrong, Nix
    # must still be able to build the system that fixes it.
    #
    # Note what is NOT here: no `trusted-public-keys`, no `trusted-users`, and
    # no `trusted=` on the URI. This adapter adds a source of bytes and zero
    # new trust.
    nix.settings = mkIf cfg.registerSubstituter {
      substituters = [ substituterUrl ];
      trusted-substituters = [ substituterUrl ];
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.oligarchy-p2pd = {
      description = "Oligarchy P2P substituter (Nix binary-cache adapter)";
      documentation = [ "https://github.com/ALH477/Oligarchy" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "nss-lookup.target" ];

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

        # Hardening. Modelled on modules/demod-talk/nixos-module.nix's stanza,
        # which is the maximal one in this repo, minus what an HTTP client
        # genuinely needs.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
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
        # AF_INET/AF_INET6 for the loopback listener and the upstream client.
        # No AF_NETLINK, no AF_PACKET, no AF_UNIX — nothing here needs them,
        # including the store reads, which go through `nix-store --dump` rather
        # than the daemon socket precisely so this line can stay this short.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        LockPersonality = true;
        # Nothing in this daemon generates code. Unlike the plugin runtime,
        # where this is decided per instance, here it is simply always true.
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
      };
    };
  };

  meta.maintainers = [ "ALH477" ];
}
