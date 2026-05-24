from __future__ import annotations

import base64
import json
import os
import socket
import struct
import sys
import time
from pathlib import Path
from urllib.parse import quote


MOD_ROOT = Path(__file__).resolve().parents[1]
BHAPTICS_DIR = MOD_ROOT / "reframework" / "data" / "bhaptics"
EFFECTS_PATH = BHAPTICS_DIR / "re9vr_simple_haptics_effects.json"

PLAYER_HOST = "127.0.0.1"
PLAYER_PORT = 15881
PLAYER_PATH = "/v2/feedbacks"
APP_ID = "com.re9vr.simplehaptics.preview"
APP_NAME = "RE9VR Simple Haptics Preview"
QUIT_KEYS = {"q", "esc", "\x03"}
HELP_KEYS = {"?"}
REGISTER_SETTLE_SECONDS = 0.15


class PlayerWebSocket:
    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        self.registered_keys: set[str] = set()

    def connect(self) -> None:
        if self.sock is not None:
            return

        key = base64.b64encode(os.urandom(16)).decode("ascii")
        app_name = quote(APP_NAME, safe="")
        request = (
            f"GET {PLAYER_PATH}?app_id={APP_ID}&app_name={app_name} HTTP/1.1\r\n"
            f"Host: {PLAYER_HOST}:{PLAYER_PORT}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "User-Agent: RE9VR-Simple-Haptics-Preview/1.1\r\n"
            "\r\n"
        )

        sock = socket.create_connection((PLAYER_HOST, PLAYER_PORT), timeout=2.0)
        try:
            sock.sendall(request.encode("ascii"))
            response = self._read_http_response(sock)
            status_line = response.split(b"\r\n", 1)[0].decode("ascii", errors="replace")
            if " 101 " not in f" {status_line} ":
                raise RuntimeError(f"bHaptics Player rejected websocket handshake: {status_line}")
        except Exception:
            sock.close()
            raise

        sock.settimeout(0.25)
        self.sock = sock

    def close(self) -> None:
        sock = self.sock
        self.sock = None
        self.registered_keys.clear()
        if sock is None:
            return
        try:
            self._send_frame(sock, b"", opcode=0x8)
        except OSError:
            pass
        sock.close()

    def send_json(self, payload: dict) -> None:
        self.connect()
        assert self.sock is not None
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self._send_frame(self.sock, data, opcode=0x1)

    def is_registered(self, key: str) -> bool:
        return key in self.registered_keys

    def register_project(self, key: str, project: dict) -> None:
        if key in self.registered_keys:
            return
        self.send_json({"Register": [{"Key": key, "Project": project}], "Submit": []})
        self.registered_keys.add(key)

    def submit_registered(self, key: str) -> None:
        self.send_json({"Register": [], "Submit": [{"Type": "key", "Key": key}]})

    @staticmethod
    def _read_http_response(sock: socket.socket) -> bytes:
        chunks: list[bytes] = []
        total = b""
        sock.settimeout(2.0)
        while b"\r\n\r\n" not in total:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            total = b"".join(chunks)
            if len(total) > 32768:
                break
        return total

    @staticmethod
    def _send_frame(sock: socket.socket, payload: bytes, opcode: int) -> None:
        first = 0x80 | (opcode & 0x0F)
        length = len(payload)
        header = bytearray([first])
        if length < 126:
            header.append(0x80 | length)
        elif length <= 0xFFFF:
            header.extend([0x80 | 126])
            header.extend(struct.pack("!H", length))
        else:
            header.extend([0x80 | 127])
            header.extend(struct.pack("!Q", length))

        mask = os.urandom(4)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        sock.sendall(bytes(header) + mask + masked)


def load_effects() -> list[dict]:
    if not EFFECTS_PATH.exists():
        raise FileNotFoundError(
            f"{EFFECTS_PATH} is missing. Run tools/generate_effects.py from this mod folder first."
        )
    data = json.loads(EFFECTS_PATH.read_text(encoding="utf-8"))
    effects = data.get("effects")
    if not isinstance(effects, list):
        raise ValueError(f"{EFFECTS_PATH} does not contain an effects list.")
    return [effect for effect in effects if isinstance(effect, dict)]


def print_effect_table(effects: list[dict]) -> None:
    rows = [
        (
            str(effect.get("tact_file", "")),
            str(effect.get("description", "")),
            str(effect.get("trigger_description", "")),
            str(effect.get("preview_shortcut", "")),
        )
        for effect in effects
    ]
    headers = ("tact file name", "description", "trigger description", "preview shortcut")
    widths = [
        max(len(headers[index]), *(len(row[index]) for row in rows)) if rows else len(headers[index])
        for index in range(len(headers))
    ]

    print()
    print(" | ".join(headers[index].ljust(widths[index]) for index in range(len(headers))))
    print("-+-".join("-" * width for width in widths))
    for row in rows:
        print(" | ".join(row[index].ljust(widths[index]) for index in range(len(row))))
    print()
    print("Press a preview shortcut to play an effect. Press ? to reprint this table. Press q, Esc, or Ctrl-C to exit.")


def read_key() -> str:
    if os.name == "nt":
        import msvcrt

        key = msvcrt.getwch()
        if key in ("\x00", "\xe0"):
            msvcrt.getwch()
            return ""
        if key == "\x1b":
            return "esc"
        return key.lower()

    return sys.stdin.read(1).lower()


def read_tact_project(effect: dict) -> dict:
    tact_file = str(effect.get("tact_file", ""))
    tact_path = BHAPTICS_DIR / tact_file
    if not tact_path.exists():
        raise FileNotFoundError(f"Missing tact file: {tact_path}")

    data = json.loads(tact_path.read_text(encoding="utf-8"))
    project = data.get("project")
    if not isinstance(project, dict):
        raise ValueError(f"{tact_path} does not contain a tact project.")
    return project


def play_effect(client: PlayerWebSocket, effect: dict) -> None:
    key = str(effect.get("key", effect.get("tact_file", "effect")))
    if not key:
        raise ValueError(f"Missing effect key for {effect.get('tact_file')}.")
    if not client.is_registered(key):
        client.register_project(key, read_tact_project(effect))
        time.sleep(REGISTER_SETTLE_SECONDS)
    client.submit_registered(key)


def main() -> int:
    try:
        effects = load_effects()
    except Exception as exc:
        print(f"Could not load effects: {exc}", file=sys.stderr)
        return 1

    print_effect_table(effects)
    by_preview_shortcut = {
        str(effect.get("preview_shortcut", "")).lower(): effect
        for effect in effects
        if str(effect.get("preview_shortcut", ""))
    }

    client = PlayerWebSocket()
    try:
        while True:
            try:
                key = read_key()
            except KeyboardInterrupt:
                print()
                return 0

            if key in QUIT_KEYS:
                print()
                return 0
            if key in HELP_KEYS:
                print_effect_table(effects)
                continue
            effect = by_preview_shortcut.get(key)
            if effect is None:
                continue

            print(f"Playing {effect.get('tact_file')}...")
            try:
                play_effect(client, effect)
            except (OSError, RuntimeError, TimeoutError) as exc:
                client.close()
                print(f"bHaptics Player connection failed: {exc}")
                print("Start bHaptics Player, connect the gear, then press the preview shortcut again.")
            except Exception as exc:
                print(f"Preview failed for {effect.get('tact_file')}: {exc}")
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
