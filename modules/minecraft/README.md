# Minecraft suite

Java (Prism) plus unofficial Bedrock (`mcpelauncher`) from the GitHub source trees the docs clone:

https://mcpelauncher.readthedocs.io/en/latest/source_build/

| Package | Upstream | Binary |
|---|---|---|
| `packages.prism` | Prism Launcher + JDKs | `prismlauncher` |
| `packages.mcpelauncher-client` | `github:minecraft-linux/mcpelauncher-manifest` | `mcpelauncher-client` |
| `packages.mcpelauncher-ui` | `github:minecraft-linux/mcpelauncher-ui-manifest` | `mcpelauncher-ui-qt` |
| `packages.default` | both | what `configuration.nix` installs |

Build recipe (clang, `GAMEWINDOW_SYSTEM=GLFW`, no FORTIFY) and GitHub
src pins live in nixpkgs (`mcpelauncher-client` / `mcpelauncher-ui-qt`).
Do not override `src` onto `ng` — the glfw.cmake patch is version-locked.
Xbox Live is curl-websockets in the client, not a separate MSA daemon.

```bash
nix build .#default          # from this directory
nix run .#bedrock            # Qt UI
```
