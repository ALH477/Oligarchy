#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025-2026, Asher LeRoy
"""
demod-hypr-bridge — DCF-Hypr control/telemetry bridge for a Hyprland session.

Relays DCF-Text messages (see docs/DCF_HYPR_SPEC.md, a reference copy of the spec
in the HydraMesh repo) between a remote controller (e.g. the HyprController
Android app) and:

  * Hyprland's own IPC sockets ($XDG_RUNTIME_DIR/hypr/<HIS>/.socket.sock for dispatch,
    .socket2.sock for the live event stream) — never modified, spoken exactly as
    `hyprctl` itself speaks it: open, write, read, close per command (Hyprland freezes
    a connection it considers "open" for 5s, so we never hold .socket.sock open).
  * oligarchy-ctl (the existing control-center action dispatcher already used by the
    Wofi menu and the TUI) — `cats` / `items <cat>` / `run <action-id>`, passed through
    byte-for-byte so this bridge never re-implements that registry.

Config is env-driven, matching the existing dcf-mesh-agent convention:
  DCF_HYPR_NODE_ID       hex node id for this bridge          (default 0x0001)
  DCF_HYPR_PEER_ID       expected controller node id           (default 0x0002)
  DCF_HYPR_UDP_PORT      UDP port to bind                       (default 7100)
  DCF_HYPR_CTRL_CHANNEL  control-channel passphrase              (default "demod-hypr-ctrl")
  DCF_HYPR_TELE_CHANNEL  telemetry-channel passphrase            (default "demod-hypr-tele")
  DCF_HYPR_CTL_BIN       path to oligarchy-ctl                   (default "oligarchy-ctl")
  DCF_HYPR_PYTHON_MCP    path to HydraMesh's python/MCP (added to sys.path)

Pure stdlib except for the two vendored reference codecs (wirelab_core, textlab_core),
imported from python/MCP/ in the pinned `hydramesh` flake input — no extra runtime
deps, same posture as the rest of the DCF stack ("DCF protocol is pure stdlib in
HydraMesh").
"""
from __future__ import annotations

import glob
import os
import socket
import subprocess
import sys
import threading
import time

# ── pairing-auth (Ed25519 signed hello) ──────────────────────────────────
# PyNaCl wraps libsodium (already on NixOS); if unavailable, the bridge
# runs in open mode — backward compatible with no pairing key configured.
try:
    from nacl.signing import VerifyKey
    from nacl.exceptions import BadSignatureError
    _HAS_NACL = True
except ImportError:
    _HAS_NACL = False

# ── vendor the canonical reference codecs from the pinned hydramesh input ──────────
_MCP_DIR = os.environ.get("DCF_HYPR_PYTHON_MCP")
if _MCP_DIR and _MCP_DIR not in sys.path:
    sys.path.insert(0, _MCP_DIR)
import wirelab_core as wire      # encode/decode/crc16_ccitt/syndrome
import textlab_core as text      # channel_id/packetize/TextReassembler

# ── config ──────────────────────────────────────────────────────────────────────────
NODE_ID = int(os.environ.get("DCF_HYPR_NODE_ID", "0x0001"), 16)
PEER_ID = int(os.environ.get("DCF_HYPR_PEER_ID", "0x0002"), 16)
UDP_PORT = int(os.environ.get("DCF_HYPR_UDP_PORT", "7100"))
CTRL_CHANNEL = text.channel_id(os.environ.get("DCF_HYPR_CTRL_CHANNEL", "demod-hypr-ctrl"))
TELE_CHANNEL = text.channel_id(os.environ.get("DCF_HYPR_TELE_CHANNEL", "demod-hypr-tele"))
CTL_BIN = os.environ.get("DCF_HYPR_CTL_BIN", "oligarchy-ctl")

ACK_OK, ACK_ERR = "ok", "err"

# ── pairing-auth config ───────────────────────────────────────────────────
# If a raw Ed25519 public key file exists at the DCF-SPA peers path, the
# bridge requires a signed hello before accepting ops. If the file is absent
# or PyNaCl is missing, open mode (no auth required) is used.
PAIRING_PUB_PATH = os.environ.get("DCF_HYPR_PAIRING_PUB", "/etc/dcf-spa/peers/0001.pub")
PAIRING_VERIFY_KEY: VerifyKey | None = None
PAIRING_AUTH_ENABLED = False

if _HAS_NACL:
    try:
        with open(PAIRING_PUB_PATH, "r") as _f:
            _pub_hex = _f.read().strip()
        if _pub_hex:
            PAIRING_VERIFY_KEY = VerifyKey(bytes.fromhex(_pub_hex))
            PAIRING_AUTH_ENABLED = True
            print(f"demod-hypr-bridge: pairing-auth ENABLED (key from {PAIRING_PUB_PATH})", file=sys.stderr)
    except FileNotFoundError:
        print("demod-hypr-bridge: pairing-auth disabled (no peer key file)", file=sys.stderr)
    except Exception as e:
        print(f"demod-hypr-bridge: pairing-auth disabled (key load error: {e})", file=sys.stderr)
else:
    print("demod-hypr-bridge: pairing-auth disabled (PyNaCl not available)", file=sys.stderr)


def now_us() -> int:
    return int(time.time() * 1_000_000) & 0xFFFFFF  # ts field is 24-bit, wraps ~16.7s


def find_hypr_socket(name: str) -> str | None:
    """Locate the Hyprland instance's IPC socket without depending on this service
    inheriting HYPRLAND_INSTANCE_SIGNATURE from the graphical session's env — glob for
    it instead, and pick the most recently touched instance if several exist."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    candidates = glob.glob(os.path.join(runtime_dir, "hypr", "*", name))
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def hypr_dispatch(args: str, timeout: float = 2.0) -> tuple[bool, str]:
    """Relay one command to Hyprland's command socket: connect, write, read, close.
    `args` is the exact hyprctl-style command line (e.g. 'dispatch workspace 3',
    'dispatch movefocus l', 'getoption animations:enabled -j')."""
    sock_path = find_hypr_socket(".socket.sock")
    if sock_path is None:
        return False, "no Hyprland instance found ($XDG_RUNTIME_DIR/hypr/*/.socket.sock)"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(sock_path)
            s.sendall(args.encode("utf-8"))
            s.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                buf = s.recv(65536)
                if not buf:
                    break
                chunks.append(buf)
            return True, b"".join(chunks).decode("utf-8", "replace").strip()
    except OSError as e:
        return False, f"hypr socket error: {e}"


def ctl_run(args: list[str], timeout: float = 15.0) -> tuple[bool, str]:
    """Relay to the existing oligarchy-ctl dispatcher (cats / items <cat> / run <id>)."""
    try:
        p = subprocess.run([CTL_BIN, *args], capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "").strip()
        if p.returncode != 0:
            return False, (p.stderr or out or f"exit {p.returncode}").strip()
        return True, out
    except FileNotFoundError:
        return False, f"{CTL_BIN} not found on PATH"
    except subprocess.TimeoutExpired:
        return False, "oligarchy-ctl timed out"


class Bridge:
    def __init__(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", UDP_PORT))
        self.ctrl_reassembler = text.TextReassembler(accept_dst=CTRL_CHANNEL)
        self.last_peer_addr: tuple[str, int] | None = None  # last address that sent us a valid op
        self.start_time = time.time()
        self._packet_id = 0
        self._lock = threading.Lock()
        self._authenticated_peers: set[str] = set()  # source IPs that completed hello

    def _next_packet_id(self) -> int:
        with self._lock:
            pid = self._packet_id
            self._packet_id = (pid + 1) % (text.MAX_PACKET_ID + 1) if hasattr(text, "MAX_PACKET_ID") else (pid + 1) % 64
            return pid

    def _send_text(self, message: str, dst_channel: int, addr: tuple[str, int], flags: int = 0) -> None:
        frames = text.packetize(message, self._next_packet_id(), now_us(), NODE_ID, dst_channel, flags)
        for f in frames:
            self.sock.sendto(f, addr)

    def _reply(self, req_id: str, ok: bool, body: str, addr: tuple[str, int]) -> None:
        status = ACK_OK if ok else ACK_ERR
        self._send_text(f"{req_id} {status} {body}", CTRL_CHANNEL, addr)

    def handle_op(self, line: str, addr: tuple[str, int]) -> None:
        self.last_peer_addr = addr
        parts = line.strip().split(maxsplit=2)
        if not parts:
            return
        if parts[0] == "ping":
            self._send_text(f"pong hypr-bridge {int(time.time() - self.start_time)}", CTRL_CHANNEL, addr)
            return
        if len(parts) < 2:
            return
        req_id, op = parts[0], parts[1]
        rest = parts[2] if len(parts) > 2 else ""
        # ── pairing-auth hello ──────────────────────────────────────────
        # Format: "<req_id> auth hello <timestamp_ms> <signature_hex>"
        # The signature covers the UTF-8 bytes of "hello <timestamp_ms>".
        # Timestamp must be within 30s of the bridge's clock (replay protection).
        if op == "auth":
            hello_parts = rest.split()
            if len(hello_parts) < 3 or hello_parts[0] != "hello":
                self._reply(req_id, False, "auth malformed", addr)
                return
            if not PAIRING_AUTH_ENABLED:
                # No key configured — open mode, accept immediately
                self._authenticated_peers.add(addr[0])
                self._reply(req_id, True, "auth ok (open mode)", addr)
                return
            ts_ms = hello_parts[1]
            sig_hex_val = hello_parts[2]
            try:
                ts = int(ts_ms)
            except ValueError:
                self._reply(req_id, False, "auth bad-timestamp", addr)
                return
            # Replay protection: timestamp must be within 30 seconds
            now_ms = int(time.time() * 1000)
            if abs(now_ms - ts) > 30_000:
                self._reply(req_id, False, "auth timestamp-expired", addr)
                return
            try:
                sig_bytes = bytes.fromhex(sig_hex_val)
            except ValueError:
                self._reply(req_id, False, "auth bad-signature-hex", addr)
                return
            message = f"hello {ts_ms}".encode("utf-8")
            try:
                assert PAIRING_VERIFY_KEY is not None
                PAIRING_VERIFY_KEY.verify(message, sig_bytes)
            except (BadSignatureError, Exception):
                self._reply(req_id, False, "auth invalid-signature", addr)
                return
            self._authenticated_peers.add(addr[0])
            self._reply(req_id, True, "auth ok", addr)
            return
        # ── auth gate ───────────────────────────────────────────────────
        if PAIRING_AUTH_ENABLED and addr[0] not in self._authenticated_peers:
            self._send_text(f"{req_id} err auth required", CTRL_CHANNEL, addr)
            return
        if op == "hypr":
            ok, body = hypr_dispatch(f"dispatch {rest}" if not rest.startswith("j/") else rest)
        elif op == "ctl":
            ok, body = ctl_run(rest.split())
        else:
            ok, body = False, f"unknown op '{op}'"
        self._reply(req_id, ok, body, addr)

    def control_loop(self) -> None:
        while True:
            data, addr = self.sock.recvfrom(65536)
            for ev in self.ctrl_reassembler.push(data):
                if ev[0] == "message":
                    _, _pid, _ts, _src, _dst, line, _flags = ev
                    self.handle_op(line, addr)

    def telemetry_loop(self) -> None:
        """Tail Hyprland's event socket and relay each line verbatim to whichever
        controller last spoke to us. Fire-and-forget, latest-wins — a dropped event
        is superseded by the next one, and the controller can always force a resync
        with a `hypr <query> -j` op."""
        while True:
            sock_path = find_hypr_socket(".socket2.sock")
            if sock_path is None:
                time.sleep(2.0)
                continue
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.connect(sock_path)
                    buf = b""
                    while True:
                        chunk = s.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            if self.last_peer_addr is not None:
                                self._send_text(
                                    line.decode("utf-8", "replace"), TELE_CHANNEL, self.last_peer_addr
                                )
            except OSError:
                pass
            time.sleep(1.0)  # instance restarted / not up yet — retry

    def run(self) -> None:
        print(
            f"demod-hypr-bridge: node=0x{NODE_ID:04X} peer=0x{PEER_ID:04X} "
            f"udp=:{UDP_PORT} ctrl_ch=0x{CTRL_CHANNEL:04X} tele_ch=0x{TELE_CHANNEL:04X}",
            file=sys.stderr,
        )
        threading.Thread(target=self.telemetry_loop, daemon=True).start()
        self.control_loop()


if __name__ == "__main__":
    Bridge().run()
