# DCF-Minecraft on Oligarchy

`services.oligarchyMinecraft.dcf` bridges the Paper server's world to the DCF mesh: command
blocks and redstone exchange ordinary 17-byte `DeModFrame`s with any Punctim peer, through a
**conforming register** in the world (34 nibbles as barrel item counts / redstone-wire power).
The protocol, the datapack and the plugin live in the HydraMesh (Punctim) repo —
`Documentation/DCF_MINECRAFT_SPEC.md` there is normative; this page is the Oligarchy wiring.

## What `dcf.enable = true` does

| piece | where it comes from | what it is on this host |
|---|---|---|
| `dcf-minecraft-paper.jar` | `hydramesh.packages.<system>.dcf-minecraft-paper` (the already-locked `hydramesh` flake input) | a store symlink under `/var/lib/minecraft/plugins/`, managed like Geyser's |
| `plugins/DcfMinecraft/config.yml` | rendered from the `dcf.*` options | a COPY (plugins rewrite their config) |
| the datapack | `hydramesh.packages.<system>.dcf-minecraft-datapack` | a store symlink at `/var/lib/minecraft/<level-name>/datapacks/dcf` (read-only is fine: a server never writes into a datapack) |
| `minecraft-dcf-sidecar.service` | `hm.dcf-python`'s `punctim mc` | only with `bridge = "sidecar"` or `bedrockWs.enable`; runs as `minecraft`, drives the console FIFO (upstream's `ListenFIFO`, `/run/minecraft-server.stdin`) and follows `logs/latest.log` |

`bridge = "plugin"` (default) needs no sidecar and no console: the plugin polls the datapack's
`tx_pending` in-process every tick and writes inbound frames through `function dcf:rx_commit`.

## Peers and channels

`dcf.peers` is a list of `{ host; port; dialect; }`. `dialect = "bare"` reaches the Hermes agent
(`services.dcf-mesh-agent`, UDP 7801, SuperPack pairs) and the JS/web nodes; `"proto"` reaches
`dcf_node.py`, the Go/Rust/C nodes and `punctim io`. Loopback peers need no firewall change.
Minecraft events ride DCF-Game EVENT on channel `mc-world` (0xD952); chat rides DCF-Text on
`mc-chat` (0xE624). Hermes listens on `duet` by default, so to talk to it from the world start it
with `DCF_CHANNEL=mc-chat` (or a second agent on that channel).

## Bedrock

Bedrock players on this server need nothing: Geyser/Floodgate already put them in the same world
(their names are `.Gamertag`). `dcf.bedrockWs.enable` additionally listens for a **vanilla Bedrock
client's own** `/connect ws://<host>:19134` on `interface` only — the client's protocol crossing
the host boundary, the same category as Geyser's RakNet listener, not inter-process HTTP. Nothing
here goes into `.mcp.json`: every endpoint is read-write.

## Why no RCON

RCON would put a password in `server.properties`, which this module renders from Nix into the
store. The console FIFO already exists and needs no secret; `punctim mc --fifo … --log …` pairs
each command with its feedback line in `latest.log`.

## Testing

* `nix build .#test-minecraft-server` — the VM gate: with `dcf.enable` the plugin symlink, the
  datapack, the rendered config, the sidecar unit and the tunnel-scoped WS port are asserted
  (Paper is stubbed; the VM is offline).
* `nix run .#minecraft-server-dev` + HydraMesh's `minecraft/tools/devserver_test.py` — the real
  Paper 26.2 + Geyser + Floodgate stack as your own user, the plugin and datapack installed,
  the golden frame `d31312340001ffffdeadbeefab12cd24c0` round-tripped over the stdin console and
  UDP; `--join <prism-instance>` lets you watch from your client.
