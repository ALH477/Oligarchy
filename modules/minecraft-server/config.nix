# Plugin configuration, shared by the NixOS module and the `nix run` dev runner.
#
# Extracted so those two cannot drift. A dev runner that rendered its own
# slightly-different Geyser config would test something the real service never
# runs, which is worse than not testing at all — the whole point of running it
# is to find out whether THESE settings bring Bedrock clients up.
#
# See modules/minecraft-server/README.md for what each of these does and why.
{ javaPort
, bedrockPort
, bindAddress ? null
, mtu
, geyserConfigVersion
, floodgateConfigVersion
}:

{
  geyser = {
    # Geyser rewrites its config whenever the file's config-version differs
    # from the jar's Constants.CONFIG_VERSION. Pinning it to the value that
    # pkgs/geyser-spigot.nix asserts against the jar is what keeps this
    # rendered file authoritative instead of regenerated on every start.
    config-version = geyserConfigVersion;

    bedrock = {
      address = if bindAddress != null then bindAddress else "0.0.0.0";
      port = bedrockPort;
      # Never track the Java port: both are pinned here.
      clone-remote-port = false;
    };

    # THE line. Anything else and Bedrock players are asked to log in with a
    # Java account. Deliberately no java.address / java.port: on a plugin
    # install those are populated from the server's own bind and ignored.
    java.auth-type = "floodgate";

    motd = {
      passthrough-motd = true;
      passthrough-player-counts = true;
    };

    # Reaches api.geysermc.org. Off: this host runs strict-egress and a version
    # notice is not worth an allowlist entry.
    notify-on-new-bedrock-update = false;

    advanced = {
      cache-images = 0;
      bedrock.mtu = mtu;
    };
  };

  floodgate = {
    config-version = floodgateConfigVersion;
    # Floodgate GENERATES this file on first start. Named, never rendered.
    key-file-name = "key.pem";
    # "." is outside Mojang's legal username charset ([A-Za-z0-9_]), so a
    # Bedrock player can never collide with a Java one. The cost is that any
    # plugin validating names against that charset rejects Bedrock players.
    username-prefix = ".";
    # Xbox gamertags contain spaces, which are illegal in Java usernames.
    replace-spaces = true;
    # Java<->Bedrock account linking, off entirely. Leaving `enabled = true`
    # with both linking modes off is not merely pointless — Floodgate then
    # tries to open its link database and logs
    #   [floodgate] Failed to find a database implementation
    # on every start, because the sqlite backend is a separate jar Floodgate
    # expects to download for itself. Observed on a real run; non-fatal, but it
    # is an error-level line that will be mistaken for the cause of the next
    # real problem.
    player-link = {
      enabled = false;
      require-link = false;
      enable-own-linking = false;
      # Would talk to wss://api.geysermc.org/ws.
      enable-global-linking = false;
    };
    metrics.enabled = false;
  };

  # One file, three plugins: switches off Paper's own bStats reporting AND
  # Geyser's AND Floodgate's. Geyser's own `enable-metrics` key is annotated
  # @ExcludePlatform(Spigot) and is not even written on this platform, so
  # setting it there would look like it worked and do nothing.
  bstats.enabled = false;

  # The server.properties entries crossplay depends on. Both are load-bearing
  # and both are silent when wrong — see the module header.
  serverProperties = {
    server-port = javaPort;
    online-mode = true;
    enforce-secure-profile = false;
  } // (if bindAddress != null then { server-ip = bindAddress; } else { });
}
