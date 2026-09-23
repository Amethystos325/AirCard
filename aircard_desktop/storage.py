from __future__ import annotations

import hashlib
import json
import os
import secrets
import sys
import time
from pathlib import Path

from platform_io import sync_directory


def data_root() -> Path:
    if os.environ.get("AIRCARD_DATA_DIR"):
        return Path(os.environ["AIRCARD_DATA_DIR"]).resolve()
    if sys.platform == "win32":
        return Path(os.environ["LOCALAPPDATA"]) / "AirCardDesktop"
    return Path.home() / "Library" / "Application Support" / "AirCardDesktop"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def identity(value: str) -> str:
    return sha(value.encode())


def put(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + secrets.token_hex(8) + ".pending")
    try:
        with temporary.open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        for attempt in range(8):
            try:
                os.replace(temporary, path)
                break
            except PermissionError as error:
                # Windows readers/AV may briefly deny delete-sharing on the old
                # directory entry. Retain the flushed temp and retry atomically.
                if sys.platform != "win32" or getattr(error, "winerror", None) not in (5, 32, 33) or attempt == 7:
                    raise
                time.sleep(.02 * (2 ** attempt))
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def save(path: Path, value):
    put(path, json.dumps(value, ensure_ascii=False, indent=2).encode())


def read(path: Path, default=None):
    return json.loads(path.read_text("utf-8")) if path.exists() else default


class Store:
    def __init__(self, root: Path | None = None):
        self.root = root or data_root()
        self.root.mkdir(parents=True, exist_ok=True)

    def card(self, device: str, card: str) -> Path:
        return self.root / "devices" / identity(device)[:32] / "cards" / identity(card)[:32]

    def transactions(self):
        return [read(p) for p in (self.root / "transactions").glob("*/state.json")]

    def pending(self, device: str | None = None):
        return [s for s in self.transactions() if s["status"] not in ("complete", "rolled_back")
                and (device is None or s["deviceKey"] == identity(device))]

    def checkpoint(self, state):
        save(self.root / "transactions" / state["id"] / "state.json", state)

    def blob(self, directory: Path, name: str, data: bytes | None):
        entry = {"exists": data is not None}
        if data is not None:
            filename = identity(name)[:32] + ".bin"
            put(directory / filename, data)
            entry.update(file=filename, sha256=sha(data), size=len(data))
        return entry

    def load_blob(self, directory: Path, entry):
        if not entry["exists"]:
            return None
        filename = entry["file"]
        if Path(filename).name != filename or "/" in filename or "\\" in filename:
            raise ValueError("INVALID_BACKUP")
        data = (directory / filename).read_bytes()
        if sha(data) != entry["sha256"] or len(data) != entry["size"]:
            raise ValueError("INVALID_BACKUP")
        return data
