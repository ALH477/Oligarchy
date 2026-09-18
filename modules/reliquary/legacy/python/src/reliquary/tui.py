"""Textual TUI for ingest / verify / push / extract / ISO."""

from __future__ import annotations

from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import DirectoryTree, Footer, Header, Input, Log, Static

from reliquary.config import Config
from reliquary.store import Store
from reliquary import optical, usb


BANNER = "RELIQUARY  ·  tarball + checksum + PAR2  ·  USB-A / USB-B / CD-R"


class ReliquaryApp(App):
    CSS = """
    Screen { background: #0b0d10; }
    Header { background: #1b2a22; color: #d7f7d0; }
    Footer { background: #111; }
    #sidebar { width: 42; border: tall #2d4a38; }
    #main { border: tall #2d4a38; }
    #status { height: 7; border: tall #3a3320; color: #e6d9a2; padding: 0 1; }
    #log { border: tall #2d4a38; }
    #cmd { dock: bottom; height: 3; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("v", "verify", "Verify"),
        Binding("p", "push", "Push USBs"),
        Binding("i", "iso", "Make ISO"),
        Binding("e", "extract", "Extract"),
        Binding("colon", "focus_cmd", "Command"),
    ]

    def __init__(self, cfg: Config):
        super().__init__()
        self.cfg = cfg
        self.store = Store(cfg)
        self.selected: str | None = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            with Vertical(id="sidebar"):
                yield Static("BLOCKS", id="blabel")
                yield DirectoryTree(str(self.cfg.blocks), id="tree")
            with Vertical(id="main"):
                yield Static(id="status")
                yield Log(id="log", highlight=True)
        yield Input(placeholder=":ingest /path  |  :verify ID  |  :push ID  |  :iso ID  |  :extract ID /dest", id="cmd")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "Reliquary"
        self.sub_title = BANNER
        self._refresh_status()
        self.query_one("#log", Log).write_line("Mounted local store at " + str(self.cfg.store_root))
        self.query_one("#log", Log).write_line("Type a colon-command or use the key bindings.")

    def _refresh_status(self) -> None:
        vols = usb.volume_status(self.cfg)
        blocks = self.store.list_blocks()
        lines = [
            f"store  {self.cfg.store_root}   blocks={len(blocks)}   par2={self.cfg.par2_redundancy}%",
        ]
        for role, info in vols.items():
            data = info["data"]
            meta = info["meta"]
            flag = "READY" if info["ready"] else ("SEEN" if info["present"] else "ABSENT")
            mp = data.get("mountpoint") or "—"
            lines.append(
                f"USB-{role}  {flag:6}  data={data['label']} @ {mp}   meta={'yes' if meta.get('present') else 'no'}"
            )
        self.query_one("#status", Static).update("\n".join(lines))

    def on_directory_tree_file_selected(self, event: DirectoryTree.FileSelected) -> None:
        path = Path(str(event.path))
        block = path.parent.name if path.name != path.parent.name else path.name
        # DirectoryTree gives files; climb to the block directory.
        for candidate in (path, *path.parents):
            if (candidate / "manifest.json").exists() and candidate.parent == self.cfg.blocks:
                self.selected = candidate.name
                self.query_one("#log", Log).write_line(f"selected {self.selected}")
                return

    def action_refresh(self) -> None:
        self._refresh_status()
        tree = self.query_one("#tree", DirectoryTree)
        tree.path = str(self.cfg.blocks)
        tree.reload()
        self.query_one("#log", Log).write_line("refreshed")

    def action_focus_cmd(self) -> None:
        self.query_one("#cmd", Input).focus()

    def action_verify(self) -> None:
        if self.selected:
            self._run(f"verify {self.selected}")

    def action_push(self) -> None:
        if self.selected:
            self._run(f"push {self.selected}")

    def action_iso(self) -> None:
        if self.selected:
            self._run(f"iso {self.selected}")

    def action_extract(self) -> None:
        self.query_one("#log", Log).write_line("use :extract BLOCK /destination")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        raw = event.value.strip()
        event.input.value = ""
        if raw.startswith(":"):
            raw = raw[1:]
        if raw:
            self._run(raw)

    def _run(self, command: str) -> None:
        log = self.query_one("#log", Log)
        log.write_line(f"» {command}")
        parts = command.split()
        try:
            verb = parts[0]
            if verb in {"ingest", "pack"}:
                man = self.store.ingest(Path(parts[1]), profile=parts[2] if len(parts) > 2 else "cd")
                log.write_line(f"ingested {man['id']}  {man['payload']['bytes']} B")
                self.selected = man["id"]
            elif verb == "verify":
                result = self.store.verify(parts[1], repair="--repair" in parts)
                log.write_line("OK" if result["ok"] else "FAILED " + str(result["checksum_problems"]))
            elif verb == "push":
                result = usb.push_block(self.cfg, self.store, parts[1])
                log.write_line(str(result))
            elif verb == "iso":
                iso = optical.make_iso(self.cfg, self.store, parts[1])
                log.write_line(f"ISO {iso} ({iso.stat().st_size} B)")
            elif verb == "extract":
                dest = self.store.extract(parts[1], Path(parts[2]))
                log.write_line(f"extracted to {dest}")
            elif verb == "status":
                self._refresh_status()
            elif verb == "help":
                log.write_line("ingest PATH [cd|usb] | verify ID | push ID | iso ID | extract ID DEST | status")
            else:
                log.write_line(f"unknown command {verb!r}")
        except Exception as exc:  # noqa: BLE001 — TUI must not crash on tool errors
            log.write_line(f"error: {exc}")
        self._refresh_status()


def run_tui(cfg: Config) -> int:
    ReliquaryApp(cfg).run()
    return 0
