# Minecraft server (`services.oligarchyMinecraft`)

Paper + Geyser + Floodgate, so Java **and** Bedrock clients join one world, with
the ports opened on a tunnel interface only. A thin wrapper over nixpkgs'
`services.minecraft-server`, which already owns the `minecraft` user, the EULA
file, declarative `server.properties` and the console FIFO.

Companion to `modules/minecraft/`, which is the *client* suite (Prism +
`mcpelauncher`). That README's "a dedicated Bedrock server by IP is the reliable
path" is what this module exists to provide.

```nix
services.oligarchyMinecraft = {
  enable = true;
  eula = true;                                    # https://aka.ms/MinecraftEULA
  interface = "tailscale0";
  # package defaults to the in-tree pin (pkgs/papermc.nix: Paper 26.2 build 121)
};
```

## The four settings that make crossplay work

Each is silent when wrong, and three of the four are enforced by assertions.

| where | setting | why |
|---|---|---|
| `server.properties` | `online-mode = true` | **Required.** Floodgate authenticates Bedrock players itself and injects them past Mojang auth; Java players still authenticate normally. Turning this off does not help Bedrock, it makes the server cracked |
| `server.properties` | `enforce-secure-profile = false` | **Required (1.19+).** The server otherwise demands a Mojang-signed chat profile key at login. Floodgate players have none, so every Bedrock player is kicked at join while Java players are fine |
| Geyser | `java.auth-type = floodgate` | Anything else and Bedrock players are asked to link a Java account |
| Floodgate | `key.pem` | Generated on first start. Geyser, in the same JVM, picks it up automatically. Never render it from Nix — it is the credential that bypasses Java auth |

## Version coupling — the part that bites

**Geyser-Spigot requires the server's protocol to equal the protocol Geyser
speaks.** From `GeyserSpigotVersionChecker.checkForSupportedProtocol`:

```java
if (viaversion) { checkViaVersionSupportedVersions(logger); return; }
if (Bukkit.getUnsafe().getProtocolVersion() != GameProtocol.getJavaProtocolVersion())
    sendOutdatedMessage(logger);
```

Geyser's wiki line about "Spigot/Paper 1.20.5 or above" is the **NMS-adapter
floor**, not protocol compatibility — the two read alike and are not the same
claim. Latest Geyser emulates a much newer Java client than nixpkgs' newest
Paper, so the obvious pairing (`papermcServers.papermc` + latest Geyser) fails
*every* Bedrock login with nothing useful in either log.

Current pins, chosen to match natively so no ViaVersion is needed:

| | version | protocol |
|---|---|---|
| Paper | `26.2` build 121 (`pkgs/papermc.nix`) | 776 |
| Geyser-Spigot | 2.11.2 build 1234 (emulates Java 26.2; Bedrock 26.0–26.45) | 776 |
| Floodgate | 2.2.5 build 140 | — |

The `.nix` files under `pkgs/` are the truth for these numbers (each derivation checks the
jar's Java version / config version in `installCheckPhase`); update this table with them.

Pin `package` to an explicit version attribute. The bare `papermc` attribute
follows nixpkgs' newest Paper, so a routine flake update would move the server
out from under a Geyser pin that was correct when written. There is an assertion
for the mismatch, so this fails at eval, not at 2am.

Pick Geyser and Floodgate builds from the same fortnight. A skewed pair produces
Floodgate's own `Expected {} arguments, got {}. Is Geyser up-to-date?`
disconnect, which blames the wrong half.

### Re-pinning

```bash
curl -s https://download.geysermc.org/v2/projects/geyser/versions/2.9.1 | jq .builds
# The API publishes the artifact hash, so no prefetch round trip is needed:
curl -s .../builds/1003 | jq -r .downloads.spigot.sha256 \
  | xargs nix hash convert --hash-algo sha256 --to sri
```

Then update `javaMinecraftVersion` / `javaProtocolVersion` /
`nativePaperVersions` / `configVersion` in `pkgs/geyser-spigot.nix`. All of them
are **checked against the jar at build time**, so a re-pin that forgets one
fails `nix build` rather than a player's login.

Take `nativePaperVersions` from <https://minecraft.wiki/w/Protocol_version> —
every Minecraft version sharing that protocol number. **Not** from Modrinth's
`game_versions`, which reports the ViaVersion-assisted range and would make the
assertion pass on a configuration that cannot work.

Use build-numbered `download.geysermc.org` URLs, never `versions/latest` or
`builds/latest`. Modrinth is not an alternative for Floodgate: its project
publishes only Fabric and NeoForge jars, no Spigot artifact.

## What is managed, and what is not

Managed (rewritten on every start, like upstream's `server.properties`):
`plugins/*.jar` as store symlinks under fixed, version-less names;
`plugins/Geyser-Spigot/config.yml`; `plugins/floodgate/config.yml`;
`plugins/bStats/config.yml`.

Not managed, deliberately: `plugins/floodgate/key.pem` (a generated credential),
the world, `usercache.json`, and `config/paper-global.yml` — rendering the last
means hand-writing its `_version`, and a wrong value runs the wrong migration.

Jars are **symlinks** (nothing is written next to a jar, and the link keeps the
store path GC-rooted). Configs are **copies** — Geyser's `ConfigLoader` calls
`loader.save()`, and a `/nix/store` symlink turns that into an `EROFS`
`IOException` that Geyser treats as fatal.

The rendered Geyser config pins `config-version` to the value asserted against
the jar, which is what stops Geyser regenerating the file on every start.

Geyser's schema is `bedrock:` / `java:` / `motd:` / `gameplay:` / `advanced:`.
There is **no top-level `remote:`** any more, and Configurate drops unrecognised
keys in silence — a config copied from an older tutorial leaves `auth-type` at
its default with no error anywhere.

## Traps worth knowing

- **`advanced.bedrock.mtu`.** Geyser's default is 1400; `tailscale0`'s MTU is
  1280. The module defaults to 1200. Too large presents as Bedrock clients
  connecting and then timing out during world load — nothing like an MTU error.
- **First start needs `piston-data.mojang.com`.** `papermcServers` ships
  Paperclip, which downloads Mojang's vanilla jar before it can run. Without it
  the unit crash-loops; `startLimitBurst` makes it give up loudly.
- **`sessionserver.mojang.com` is not optional** — without it no Java player can
  authenticate, because `online-mode` stays true.
- **`TimeoutStopSec = 600`.** `ExecStop` waits for the world to save; systemd's
  90s default SIGKILLs a large world mid-save and corrupts a region file.
- **Floodgate's `username-prefix` is `.`** — outside Mojang's legal username
  charset, so Bedrock players can never collide with Java ones. Java's limit is
  16 and gamertags run to 15, so one character fits with zero headroom; longer
  makes Floodgate truncate and silently merge distinct players. Any plugin that
  validates names against `[A-Za-z0-9_]` will reject Bedrock players.
- **Tailnet-only excludes consoles.** Xbox/PlayStation/Switch cannot run
  Tailscale and cannot add a server by IP. Android, iOS and Windows can.

## Testing

Three layers, each covering what the others cannot.

### 1. Build time — the version pairing

`pkgs/geyser-spigot.nix` reads the Java version and `CONFIG_VERSION` straight
out of the jar in `installCheckPhase`, so a re-pin that forgets to update them
fails `nix build` rather than a player's login. This cannot be a runtime test:
proving 776 == 776 needs a real handshake.

### 2. `nix build .#test-minecraft-server` — the module wiring

A NixOS VM test. Stubs Paper, because a test VM is offline and Paperclip needs
Mojang, but uses the **real** jars. Asserts the unit reaches `active` (which
proves `preStart` works as `minecraft` inside upstream's sandbox), jar
materialisation and stale-symlink pruning, the rendered crossplay config,
`online-mode`/`enforce-secure-profile`, the console FIFO, and that the ports are
admitted on the tunnel interface and **nowhere else**.

It cannot tell you whether a Bedrock client connects, because it never runs a
real server.

### 3. `nix run .#minecraft-server-dev` — the server itself

```bash
nix run .#minecraft-server-dev -- --accept-eula
```

Runs the real Paper + Geyser + Floodgate in a scratch directory as your own
user — no root, no systemd, no rebuild, nothing touched on the system. Binds
loopback, so it does not appear on the LAN because you were testing.

```
--accept-eula   agree to Mojang's EULA (required; a script should not agree for you)
--dir PATH      state dir (default $XDG_CACHE_HOME/oligarchy-minecraft-dev)
--heap SIZE     JVM heap (default 2G)
--reset         delete the state dir first, world included
```

Java clients connect to `localhost:25565`, Bedrock clients to `127.0.0.1` port
`19132`. First start takes ~25s: Paperclip downloads Mojang's jar, Paper
generates a world, and Geyser fetches the Minecraft JAR once to extract locale
files. Type `stop` to shut down.

It shares `config.nix` with the module **verbatim**, so what you are exercising
is the configuration the real service runs. A runner with its own subtly
different config would be worse than no runner at all.

What it does **not** cover: the reachability boundary. There is no tunnel and no
firewall here — that is the module's job and layer 2's assertion.

A healthy start looks like:

```
[floodgate] Took 762ms to boot Floodgate
[Geyser-Spigot] Started Geyser on 127.0.0.1:19132
Done (23.427s)! For help, type "help"
```

with **no** `ERROR` lines and no "outdated server" warning from Geyser — that
warning is exactly what a broken Paper/Geyser protocol pairing produces.
