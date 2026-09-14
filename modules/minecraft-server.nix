# services.oligarchyMinecraft — a Paper Minecraft server that Java AND Bedrock
# clients can both join, reachable only over a tunnel.
#
# Per CLAUDE.md this defaults to OFF and is flipped on in configuration.nix.
#
# ─────────────────────────────────────────────────────────────────────────────
# THIS IS A WRAPPER, NOT A REIMPLEMENTATION.
#
# `services.minecraft-server` (nixpkgs) already owns the static `minecraft`
# user, the EULA file, declarative server.properties, the ListenFIFO console
# socket and a hardening stanza. This module sets that up with Paper as the
# package, turns its GLOBAL firewall opening off, and adds the three things it
# has no concept of: the crossplay plugins, their configuration, and a
# reachability boundary.
#
# WHAT MAKES CROSSPLAY WORK, in one place, because each half fails silently
# without the other:
#
#   server.properties  online-mode            = true    <- REQUIRED
#   server.properties  enforce-secure-profile = false   <- REQUIRED (1.19+)
#   Geyser             java.auth-type         = floodgate
#   Floodgate          plugin on the SAME server, generating its own key.pem
#
# online-mode stays TRUE. Floodgate authenticates Bedrock players itself against
# the Xbox chain and its key.pem, then injects them past Mojang auth; Java
# players still go through Mojang normally. Turning online-mode off does not
# "make Bedrock work" — it makes the server cracked, where anyone may join as
# anyone. There is an assertion for this because it is the single most common
# way people break this setup.
#
# enforce-secure-profile is the one that must be relaxed. Since 1.19 the server
# demands a Mojang-signed chat profile key at login and Floodgate players have
# none, so with the 1.19+ default of true EVERY Bedrock player is kicked at join
# while Java players are unaffected — which reads like a Geyser bug and is not.
#
# ─────────────────────────────────────────────────────────────────────────────
# REACHABILITY IS THE TUNNEL.
#
# A Minecraft server hands world-write access to anyone who completes a
# handshake. There is no per-player authorisation below the whitelist, and the
# whitelist is a name list, not a credential. So `interface` is mandatory and
# the ports are opened on THAT INTERFACE ONLY, never globally — the same shape
# services.demod-talk uses, for a comparable reason.
#
# The JVM still binds the wildcard address unless `bindAddress` is set. That is
# deliberate and matches this host's own sshd, which binds 0.0.0.0 while
# configuration.nix admits :22 on tailscale0 alone. The global firewall permits
# only TCP 22/443 and UDP 5353, so the per-interface rule is the whole boundary.
# Do not "fix" this by trusting the interface: configuration.nix is explicit
# that tailscale0 is NOT a trusted interface, because that would admit every
# tailnet peer to every port.
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.oligarchyMinecraft;

  # ── Tunnel detection ───────────────────────────────────────────────────────
  # Lifted from modules/demod-talk/nixos-module.nix, which already handles the
  # case that trips up a naive check: Tailscale IS WireGuard, but it is not
  # declared under networking.wireguard.interfaces — tailscaled brings up its
  # own tailscale0 — so an option-tree-only check would reject a good tailnet.
  wgIfaces = config.networking.wireguard.interfaces or { };
  wgQuickIfaces = config.networking.wg-quick.interfaces or { };
  isWg = wgIfaces ? ${cfg.interface};
  isWgQuick = wgQuickIfaces ? ${cfg.interface};

  tsIface = config.services.tailscale.interfaceName or "tailscale0";
  isTailscale = (config.services.tailscale.enable or false) && cfg.interface == tsIface;

  tunnelUnit =
    if isWg then "wireguard-${cfg.interface}.service"
    else if isWgQuick then "wg-quick-${cfg.interface}.service"
    else if isTailscale then "tailscaled.service"
    else null;

  # ── Version coupling ───────────────────────────────────────────────────────
  # Geyser-Spigot requires the server's protocol to EQUAL the protocol Geyser
  # speaks (GeyserSpigotVersionChecker.checkForSupportedProtocol), unless
  # ViaVersion is present to translate. Geyser's wiki line about "1.20.5 or
  # above" is the NMS-adapter floor and does NOT mean protocol compatibility.
  # The jar's own facts are read out at build time in pkgs/geyser-spigot.nix.
  gy = cfg.crossplay.geyser;
  mcVersion = if cfg.mcVersion != null then cfg.mcVersion else derivedMcVersion;
  derivedMcVersion =
    # Our own Paper package states it outright; nixpkgs' encodes it as the part
    # of `version` before the first dash ("1.21.10-91" -> "1.21.10").
    if cfg.package ? mcVersion then cfg.package.mcVersion
    else
      let v = cfg.package.version or ""; in
      if v == "" then "" else head (splitString "-" v);
  nativeMatch = elem mcVersion (gy.nativePaperVersions or [ ]);

  yaml = pkgs.formats.yaml { };

  # ── Rendered plugin configuration ──────────────────────────────────────────
  # Merged with recursiveUpdate rather than declared as mkDefault inside a
  # freeform option: pkgs.formats.yaml's type is an `oneOf`, and an oneOf takes
  # the highest-priority definition wholesale instead of merging leaves. Doing
  # it here is what makes "override one key" actually mean that.
  # Defaults live in ./minecraft-server/config.nix, shared verbatim with the
  # `nix run .#minecraft-server-dev` runner so the two cannot drift.
  sharedConfig = import ./minecraft-server/config.nix {
    inherit javaPort;
    inherit (cfg) bindAddress;
    inherit (cfg.crossplay) bedrockPort mtu;
    geyserConfigVersion = gy.configVersion or 5;
    floodgateConfigVersion = cfg.crossplay.floodgate.configVersion or 3;
  };

  geyserSettings = recursiveUpdate sharedConfig.geyser cfg.crossplay.geyserSettings;
  floodgateSettings = recursiveUpdate sharedConfig.floodgate cfg.crossplay.floodgateSettings;

  geyserConfigFile = yaml.generate "geyser-config.yml" geyserSettings;
  floodgateConfigFile = yaml.generate "floodgate-config.yml" floodgateSettings;

  # ── Egress reporting ───────────────────────────────────────────────────────
  # Reported, never written: strict-egress.nix PULLS (autoDetect.*), and one
  # auditable allowlist in configuration.nix is the point.
  requiredEgressHosts = [
    # Paperclip downloads Mojang's vanilla jar on FIRST START.
    "piston-data.mojang.com"
    # online-mode login verification. Without it, no Java player can join.
    "sessionserver.mojang.com"
    # Mojang public key set, fetched at startup for profile verification.
    "api.minecraftservices.com"
    # Geyser fetches the Minecraft JAR on first start for locale files.
    "launchermeta.mojang.com"
  ];
  allowedEgressDomains = config.networking.firewall.strictEgress.allow.domains or [ ];
  missingEgressHosts = subtractLists allowedEgressDomains requiredEgressHosts;

  # One file, three plugins — see config.nix for why Geyser's own
  # enable-metrics key is not the right lever on Spigot.
  bstatsConfigFile = yaml.generate "bstats-config.yml" sharedConfig.bstats;

  # NOT managed: config/paper-global.yml. Rendering it means hand-writing its
  # `_version`, and a wrong value makes Paper run the wrong config migration.
  # The only thing worth setting there is the update checker, whose cost is one
  # log line and a request to api.papermc.io — a host the build already needs.

  # Jar names this module owns. Deliberately version-LESS: a build number in the
  # filename would leave the old jar beside the new one on a bump, and Paper
  # would load the same plugin twice then refuse to enable one.
  managedJars = [ "Geyser-Spigot.jar" "floodgate-spigot.jar" ];
  activeJars = optionals cfg.crossplay.enable managedJars;
  retiredJars = subtractLists activeJars managedJars;

  # ── preStart ───────────────────────────────────────────────────────────────
  # Runs as `minecraft`, in WorkingDirectory=dataDir, inside upstream's sandbox
  # (PrivateUsers/ProtectHome/PrivateTmp, UMask 0077) and under `set -e` — every
  # job script nixos/lib/systemd-lib.nix generates is prefixed with it. There is
  # NO ProtectSystem in that unit, so /nix/store reads work; there is also no
  # root, so nothing here may chown.
  pluginPreStart = ''
    umask 0027
    mkdir -p plugins config

    # Jars are SYMLINKS, not copies. Bukkit opens plugins/*.jar through
    # java.io.File (which follows them) and nothing is ever written next to a
    # jar — a plugin's state lives in plugins/<plugin.yml name>/. The symlink
    # also keeps the store path inside this unit's closure, so it stays
    # GC-rooted for the life of the generation.
    install_jar() {   # $1 = store path, $2 = name under plugins/
      if [ -e "plugins/$2" ] && [ ! -L "plugins/$2" ]; then
        echo "oligarchy-minecraft: plugins/$2 is a real file; moving it to $2.stateful" >&2
        mv -f "plugins/$2" "plugins/$2.stateful"   # not *.jar, so Paper ignores it
      fi
      ln -sfn "$1" "plugins/$2"
    }

    ${optionalString cfg.crossplay.enable ''
      install_jar ${cfg.crossplay.geyser}/share/geyser/Geyser-Spigot.jar Geyser-Spigot.jar
      install_jar ${cfg.crossplay.floodgate}/share/floodgate/floodgate-spigot.jar floodgate-spigot.jar
    ''}

    # Retire jars this module used to own. Two cases: crossplay was switched
    # off (the link still resolves, so name it explicitly), and the pin moved
    # and the old store path was collected (the link dangles). A REGULAR file
    # is an operator's own plugin and is never touched.
    ${concatMapStringsSep "\n    " (j: ''
      if [ -L "plugins/${j}" ]; then
        case "$(readlink "plugins/${j}")" in /nix/store/*) rm -f "plugins/${j}" ;; esac
      fi
    '') retiredJars}
    for link in plugins/*.jar; do
      [ -L "$link" ] || continue
      case "$(readlink "$link")" in
        /nix/store/*) [ -e "$link" ] || rm -f "$link" ;;
      esac
    done

    # Configs are COPIES, never store symlinks. Geyser's ConfigLoader#load0
    # calls loader.save() whenever the file was empty or its config-version
    # moved, Floodgate substitutes its metrics UUID into its own file, bStats
    # writes a serverUuid, and Paper rewrites paper-global.yml. A /nix/store
    # symlink turns each of those into an EROFS IOException, and Geyser treats
    # a failed config load as fatal — it exits, with one line in the journal.
    #
    # Unconditional copy, matching what upstream already does with
    # server.properties under `declarative = true`: hand edits do not survive a
    # restart. Because the rendered config pins config-version to the value
    # asserted against the jar at build time, Geyser reads this file, fills
    # absent keys from its code defaults, and never rewrites it.
    install_config() {   # $1 = store file, $2 = destination
      mkdir -p "$(dirname "$2")"
      cp -f "$1" "$2"
      chmod u+w "$2"
    }

    ${optionalString cfg.crossplay.enable ''
      install_config ${geyserConfigFile} plugins/Geyser-Spigot/config.yml
      install_config ${floodgateConfigFile} plugins/floodgate/config.yml
    ''}
    install_config ${bstatsConfigFile} plugins/bStats/config.yml

    # NOT managed, deliberately: plugins/floodgate/key.pem. Floodgate generates
    # that keypair on first start and Geyser, in the same JVM, picks it up on
    # its own. It is the credential that lets a client bypass Java auth — it
    # must never be rendered from Nix and must never reach /nix/store.
  '';

  javaPort = cfg.javaPort;
in
{
  options.services.oligarchyMinecraft = {
    enable = mkEnableOption ''
      a Paper Minecraft server with Geyser + Floodgate crossplay, reachable only
      over a tunnel interface. Wraps services.minecraft-server
    '';

    eula = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Agreement to Mojang's EULA (https://aka.ms/MinecraftEULA). Forwarded to
        services.minecraft-server.eula, whose assertion refuses to build without
        it. Stated here so the agreement is visible in configuration.nix.
      '';
    };

    interface = mkOption {
      type = types.str;
      example = "tailscale0";
      description = ''
        Interface to open the Java and Bedrock ports on. MANDATORY and
        deliberately not defaulted: a Minecraft server grants world-write access
        to anyone who connects, so the tunnel is the membership boundary. Point
        this at tailscale0 or at a WireGuard interface declared on this host.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./minecraft-server/pkgs/papermc.nix { };
      defaultText = literalExpression "pkgs.callPackage ./minecraft-server/pkgs/papermc.nix { }";
      description = ''
        Paper. Pinned in-tree rather than taken from `pkgs.papermcServers` for
        two reasons: nixpkgs stops at Minecraft 1.21.10, which no current
        Bedrock client can be bridged to without a translation layer; and
        nixpkgs' derivation fetches from PaperMC's sunset v2 API, which returns
        HTTP 410 and only appears to work because the artifact is in
        cache.nixos.org. See minecraft-server/pkgs/papermc.nix.

        If you override this, its version must appear in the pinned Geyser's
        `nativePaperVersions` or the crossplay assertion refuses the pair.
      '';
    };

    mcVersion = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1.21.10";
      description = ''
        Minecraft version this server speaks, for the crossplay compatibility
        assertion. Defaults to the part of `package.version` before the first
        dash ("1.21.10-91" -> "1.21.10"). Set it explicitly when `package` is
        something without a parseable version, such as a test stub.
      '';
    };

    javaPort = mkOption {
      type = types.port;
      default = 25565;
      description = "TCP port for Java Edition clients, on `interface` only.";
    };

    bindAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "100.64.0.5";
      description = ''
        Address to bind (server.properties `server-ip`, and Geyser's Bedrock
        listener). `null` binds the wildcard and relies on the per-interface
        firewall rule as the boundary — the same arrangement this host already
        uses for sshd. Set it only if you want belt-and-braces; note the tunnel
        address must exist before the unit starts.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the Java and Bedrock ports on `interface` ONLY. Never opens them
        globally, and never marks the interface trusted. Set false if you manage
        the firewall yourself.
      '';
    };

    jvmOpts = mkOption {
      type = types.separatedString " ";
      default = "-Xmx4G -Xms4G";
      description = "JVM options. Paper wants Xmx and Xms equal.";
    };

    serverProperties = mkOption {
      type = with types; attrsOf (oneOf [ bool int str ]);
      default = { };
      example = { motd = "Oligarchy"; difficulty = "normal"; max-players = 10; };
      description = ''
        Extra server.properties entries, merged OVER this module's defaults.
        online-mode and enforce-secure-profile are constrained by assertions —
        see the header comment for why.
      '';
    };

    whitelist = mkOption {
      type = with types; attrsOf str;
      default = { };
      example = { someone = "uuid-here"; };
      description = ''
        Forwarded to services.minecraft-server.whitelist. Note this covers Java
        players only; Bedrock players arrive with the Floodgate prefix applied,
        so their names here must include it.
      '';
    };

    acknowledgeTailnetReach = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Silence the warning that every peer on the tunnel can reach the server.
        Set this once a Tailscale ACL (or WireGuard peer list) actually narrows
        who can, not before.
      '';
    };

    tailscaleTag = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "tag:minecraft";
      description = ''
        Informational: the Tailscale ACL tag intended to gate this server.
        Tailscale ACLs are tailnet-wide policy and are not managed from NixOS,
        so this documents the intent and is surfaced in the unit description —
        it enforces nothing by itself.
      '';
    };

    crossplay = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Install Geyser + Floodgate so Bedrock Edition clients can join. With
          this off the server is Java-only and this module is just a
          tunnel-scoped services.minecraft-server.
        '';
      };

      bedrockPort = mkOption {
        type = types.port;
        default = 19132;
        description = ''
          UDP port for Bedrock Edition clients (RakNet), on `interface` only.
          19132 is the port Bedrock's "Add Server" dialog defaults to.
        '';
      };

      mtu = mkOption {
        type = types.ints.between 576 1500;
        default = 1200;
        description = ''
          Geyser's RakNet MTU. Geyser's own default is 1400, which does NOT fit
          a tunnel: tailscale0's MTU is 1280, and WireGuard is typically 1420.
          An oversized MTU here presents as Bedrock clients connecting and then
          timing out during world load, which looks nothing like an MTU problem.
          1200 leaves headroom under 1280 minus headers.
        '';
      };

      geyser = mkOption {
        type = types.package;
        default = pkgs.callPackage ./minecraft-server/pkgs/geyser-spigot.nix { };
        defaultText = literalExpression "pkgs.callPackage ./minecraft-server/pkgs/geyser-spigot.nix { }";
        description = ''
          Geyser-Spigot. Its passthru carries the Java version and protocol the
          jar natively speaks, both verified against the jar at build time, and
          the module asserts that they match `mcVersion`.
        '';
      };

      floodgate = mkOption {
        type = types.package;
        default = pkgs.callPackage ./minecraft-server/pkgs/floodgate-spigot.nix { };
        defaultText = literalExpression "pkgs.callPackage ./minecraft-server/pkgs/floodgate-spigot.nix { }";
        description = ''
          Floodgate. Pin it from the same fortnight as Geyser: a skewed pair
          produces Floodgate's own "Expected {} arguments, got {}. Is Geyser
          up-to-date?" disconnect, which blames the wrong half.
        '';
      };

      geyserSettings = mkOption {
        type = yaml.type;
        default = { };
        description = ''
          Merged over this module's defaults with recursiveUpdate and rendered
          to plugins/Geyser-Spigot/config.yml, so setting one leaf here
          overrides only that leaf.

          Note the schema: current Geyser has no top-level `remote:` section —
          it is `java:`, `motd:`, `gameplay:` and `advanced:`. Configurate
          silently drops keys it does not recognise, so a config copied from an
          older tutorial leaves auth-type at its default and Bedrock players get
          asked to link a Java account, with no error anywhere.
        '';
      };

      floodgateSettings = mkOption {
        type = yaml.type;
        default = { };
        description = "Merged over this module's defaults, rendered to plugins/floodgate/config.yml.";
      };

      acknowledgeUsernameTruncation = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Permit a Floodgate username-prefix longer than one character. See the
          assertion: Java's username limit is 16 and Xbox gamertags run to 15,
          so a 1-character prefix fits with zero headroom and anything longer
          makes Floodgate truncate, silently collapsing distinct players onto
          one name.
        '';
      };
    };
  };

  config = mkIf cfg.enable {

    services.minecraft-server = {
      enable = true;
      declarative = true;
      inherit (cfg) eula whitelist jvmOpts package;

      # Never globally. configuration.nix is explicit that tailscale0 is not a
      # trusted interface; upstream's openFirewall would open the Java port on
      # every interface at once. We scope it below instead.
      openFirewall = false;

      # From ./minecraft-server/config.nix. online-mode and
      # enforce-secure-profile are load-bearing for crossplay and both have
      # assertions behind them — see the header.
      serverProperties =
        (removeAttrs sharedConfig.serverProperties
          (optional (!cfg.crossplay.enable) "enforce-secure-profile"))
        // cfg.serverProperties;
    };

    # Per-interface, never global, never trustedInterfaces — the same shape
    # services.demod-talk and custom.p2pCache.peer use.
    networking.firewall = mkIf cfg.openFirewall {
      interfaces.${cfg.interface} = {
        allowedTCPPorts = [ javaPort ];
        allowedUDPPorts = optional cfg.crossplay.enable cfg.crossplay.bedrockPort;
      };
    };

    systemd.services.minecraft-server = {
      # mkForce: upstream sets its own "Minecraft Server Service".
      description = mkForce ("Minecraft (Paper${optionalString cfg.crossplay.enable " + Geyser/Floodgate"})"
        + " on ${cfg.interface}"
        + optionalString (cfg.tailscaleTag != null) " (ACL ${cfg.tailscaleTag})");

      # Do not start before the boundary exists, and do not outlive it. Without
      # this the server can come up bound and firewalled against an interface
      # that is not there yet.
      after = optional (tunnelUnit != null) tunnelUnit;
      bindsTo = optional (tunnelUnit != null) tunnelUnit;

      # `preStart` is types.lines, where mkAfter ordering is specified. A second
      # ExecStartPre would merge too, but only in module-import order.
      preStart = mkAfter pluginPreStart;

      # Upstream's default Restart=always plus a first start that must reach
      # piston-data.mojang.com (Paper ships Paperclip, which downloads Mojang's
      # vanilla jar) is a tight crash-loop when egress is blocked. Give up
      # loudly instead of hammering.
      startLimitBurst = 5;
      startLimitIntervalSec = 600;

      serviceConfig = {
        RestartSec = 20;
        # ExecStop writes "stop" to the FIFO and waits for the world to save.
        # systemd's 90s default SIGKILLs a large world mid-save, which corrupts
        # a region file.
        TimeoutStopSec = 600;
      };

      # No restartTriggers: the plugin store paths are interpolated into
      # preStart above, so the unit text already changes when a pin moves.
    };

    assertions = [
      {
        assertion = cfg.interface != "";
        message = "services.oligarchyMinecraft.interface must name a real interface.";
      }
      {
        assertion = isWg || isWgQuick || isTailscale;
        message = ''
          services.oligarchyMinecraft.interface = "${cfg.interface}" is not a
          tunnel interface on this host. A Minecraft server grants world-write
          access to anyone who completes a handshake, so the tunnel is the
          membership boundary and this module will not open the ports anywhere
          else. Declare the interface under networking.wireguard.interfaces or
          networking.wg-quick.interfaces, or enable services.tailscale and point
          this at "${tsIface}".
        '';
      }
      {
        assertion = mcVersion != "";
        message = ''
          services.oligarchyMinecraft.mcVersion could not be derived from
          `package` (version = "${cfg.package.version or ""}"). Set it
          explicitly — every version check below depends on it, and a blank
          value would turn them all into no-ops.
        '';
      }
      {
        assertion = !cfg.crossplay.enable || nativeMatch;
        message = ''
          Paper ${mcVersion} and Geyser ${gy.version or "?"} do not speak the
          same Java protocol. Geyser emulates a
          ${gy.javaMinecraftVersion or "?"} client (protocol
          ${toString (gy.javaProtocolVersion or 0)}); without ViaVersion,
          GeyserSpigotVersionChecker requires the server's protocol to match
          exactly. The symptom is every Bedrock login failing with nothing
          useful in either log.

          Fix it by pinning one side to the other: this Geyser natively serves
          ${concatStringsSep ", " (gy.nativePaperVersions or [ ])}. Edit
          modules/minecraft-server/pkgs/geyser-spigot.nix, or move `package` to
          a matching Paper.

          Do NOT decide this from Modrinth's game_versions list — that is the
          ViaVersion-assisted range, and it would make this assertion pass on a
          configuration that cannot work.
        '';
      }
      {
        assertion = !cfg.crossplay.enable || (cfg.serverProperties.online-mode or true);
        message = ''
          services.oligarchyMinecraft: online-mode must stay true with
          Floodgate. Floodgate authenticates Bedrock players itself and injects
          them past Mojang auth; Java players still authenticate normally.
          Turning online-mode off does not make Bedrock work — it makes the
          server cracked, where anyone can join as anyone.
        '';
      }
      {
        assertion = !cfg.crossplay.enable
          || (cfg.serverProperties.enforce-secure-profile or false) == false;
        message = ''
          services.oligarchyMinecraft: enforce-secure-profile must be false with
          Floodgate. Since 1.19 the server demands a Mojang-signed chat profile
          key at login, and Floodgate players have none — so with this true
          EVERY Bedrock player is kicked at join while Java players are fine.
          Relax only this; keep online-mode = true.
        '';
      }
      {
        assertion = !cfg.crossplay.enable || cfg.crossplay.bedrockPort != javaPort;
        message = ''
          services.oligarchyMinecraft: bedrockPort (UDP ${toString cfg.crossplay.bedrockPort})
          and javaPort (TCP ${toString javaPort}) must differ.
        '';
      }
      {
        assertion = !cfg.crossplay.enable
          || cfg.crossplay.acknowledgeUsernameTruncation
          || stringLength (floodgateSettings.username-prefix or ".") <= 1;
        message = ''
          services.oligarchyMinecraft: Floodgate's username-prefix is longer
          than one character. Xbox gamertags run to 15 characters and Java's
          username limit is 16, so a one-character prefix fits with zero
          headroom; anything longer makes Floodgate TRUNCATE, silently
          collapsing distinct players onto the same name. Set
          crossplay.acknowledgeUsernameTruncation if you accept that.
        '';
      }
    ];

    warnings =
      optional (cfg.crossplay.enable && (gy.bedrockVersions or null) != null) ''
        services.oligarchyMinecraft: this Geyser (${gy.version or "?"}) serves
        Bedrock clients ${gy.bedrockVersions} and no others. Bedrock auto-updates
        from the app stores and generally cannot be held back, so when your
        players' clients move past that range they stop being able to connect —
        with a generic "Unable to connect to world", not a version message.
        Re-pin Geyser (and Paper with it) in modules/minecraft-server/pkgs/ when
        that happens; the build-time jar checks will keep the pair honest.
      ''
      ++ optional (cfg.openFirewall && !cfg.acknowledgeTailnetReach) ''
        services.oligarchyMinecraft is opening ${toString javaPort}/tcp${
          optionalString cfg.crossplay.enable " and ${toString cfg.crossplay.bedrockPort}/udp"
        } on ${cfg.interface}, which every peer on that tunnel can reach. This
        host's own policy treats ${tsIface} as untrusted for exactly that
        reason. Narrow it with a Tailscale ACL (see tailscaleTag) or a WireGuard
        peer list, then set acknowledgeTailnetReach = true to silence this.
      ''
      ++ optional
        (config.networking.firewall.strictEgress.enable or false
        && missingEgressHosts != [ ])
        ''
          networking.firewall.strictEgress is enabled and these hosts are not in
          its allowlist: ${concatStringsSep " " missingEgressHosts}.

          This module reports rather than writes, because strict-egress.nix
          PULLS (autoDetect.*) and keeping one auditable allowlist in
          configuration.nix is the point. Two of these are not optional:
          piston-data.mojang.com, because the Paper jar is a Paperclip launcher
          which downloads Mojang's vanilla jar on FIRST START and crash-loops
          without it; and sessionserver.mojang.com, because without it no Java
          player can authenticate at all.
        '';
  };

  meta.maintainers = [ ];
}
