"""Export known Wallet card face assets with durable Mac recovery copies."""

from __future__ import annotations

import hashlib
import json
import os
import posixpath
import re
import secrets
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

import apply_card_skin as airlift
from card_assets import PDF_ASSET_NAME, PNG_ASSET_NAMES


ASSETS = (*PNG_ASSET_NAMES, PDF_ASSET_NAME)
MAX_ASSET_SIZE = 32 * 1024 * 1024
CARD_HASH = re.compile(r"[-A-Za-z0-9_+=]{20,64}\Z")
RECOVERY_ROOT = Path.home() / "Library" / "Application Support" / "AirCard" / "Recovery"


class ExportError(RuntimeError):
    pass


class AssetUnavailable(ExportError):
    """The named asset was not moved; its Books staging was restored."""


@dataclass(frozen=True)
class ExportResult:
    recovery: Path
    exported: tuple[str, ...]
    unavailable: tuple[str, ...]
    unrecognized: tuple[str, ...]


def _durable_write(path: Path, data: bytes) -> None:
    with path.open("wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(path, 0o600)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _save_state(directory: Path, state: dict) -> None:
    path = directory / "state.json"
    pending = directory / "state.json.pending"
    _durable_write(pending, json.dumps(state, indent=2).encode())
    os.replace(pending, path)
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _sync_snapshot(directory: Path) -> None:
    for path in directory.rglob("*"):
        if path.is_file():
            os.chmod(path, 0o600)
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _valid_asset(name: str, data: bytes) -> bool:
    if not data or len(data) > MAX_ASSET_SIZE:
        return False
    if name.endswith(".png"):
        return data.startswith(b"\x89PNG\r\n\x1a\n") and data[12:16] == b"IHDR" and b"IEND" in data[-24:]
    return data.startswith(b"%PDF-") and b"%%EOF" in data[-1024:]


def _stat_recovered(udid: str, recovered: str) -> int | None:
    result = airlift.native("afc-stat", udid, recovered)
    if not airlift.operation_ok(result):
        return None
    op = result["operation"]
    if op.get("kind") != "S_IFREG":
        raise ExportError(f"Recovery path is not a regular file: {recovered}")
    size = op.get("size")
    if not isinstance(size, int) or size <= 0 or size > MAX_ASSET_SIZE:
        raise ExportError(f"Invalid asset size at {recovered}: {size}")
    return size


def _export_one(udid: str, target: str, name: str, directory: Path,
                state: dict) -> bytes:
    token = secrets.token_hex(10)
    source = f"{airlift.SOURCE_PREFIX}{token}"
    link = f"{airlift.LINK_PREFIX}{token}"
    recovered = f"{airlift.RECOVERED_PREFIX}{token}"
    snapshot_root = directory / f"{name}.books-snapshot"
    snapshot_root.mkdir(mode=0o700)
    archive_path = directory / f"{name}.stage.zip"
    books_path = directory / f"{name}.Books.plist"
    local_path = directory / name
    identifiers = [
        f"../../{source}/p0/p1/p2/link",
        posixpath.relpath(posixpath.join(target, name), airlift.AIRLOCK_ROOT),
    ]
    destinations = [link, recovered]
    entry = state["assets"][name] = {
        "recoveredMediaPath": recovered,
        "target": posixpath.join(target, name),
        "status": "preparing",
    }
    _save_state(directory, state)
    _durable_write(archive_path, airlift.build_archive(target, b"aircard-export-staging"))
    _durable_write(books_path, airlift.build_books(identifiers))

    snapshot = airlift.native("snapshot-books", udid, os.fspath(snapshot_root))
    if not airlift.operation_ok(snapshot):
        raise ExportError(f"Cannot snapshot device Books state for {name}")
    _sync_snapshot(snapshot_root)
    entry["status"] = "books-snapshotted"
    _save_state(directory, state)
    stage_attempted = False
    primary_error: Exception | None = None
    data: bytes | None = None
    try:
        stage_attempted = True
        staged = airlift.native("stage", udid, source, link, recovered,
                                os.fspath(archive_path), os.fspath(books_path),
                                os.fspath(snapshot_root))
        if not airlift.operation_ok(staged):
            raise ExportError(f"Cannot stage {name}")
        entry["status"] = "staged"
        _save_state(directory, state)
        command = [os.fspath(airlift.AIRTRAFFIC_HOST), udid]
        for identifier, destination in zip(identifiers, destinations):
            command.extend((identifier, destination))
        moved = airlift.run_json(command, timeout=120)
        # AirTraffic can report success without moving a file: AFC is decisive.
        size = _stat_recovered(udid, recovered)
        if size is None:
            raise AssetUnavailable(f"{name} is absent or could not be moved")
        entry["status"] = "original-in-device-recovery"
        entry["size"] = size
        _save_state(directory, state)
        read = airlift.native("afc-read", udid, recovered, os.fspath(local_path))
        if not airlift.operation_ok(read) or not local_path.is_file():
            raise ExportError(f"Cannot copy {name} to Mac recovery storage")
        data = local_path.read_bytes()
        if len(data) != size or read["operation"].get("size") != size:
            raise ExportError(f"{name} failed size verification")
        if data == b"aircard-export-staging":
            raise ExportError(f"{name} contains staging data, not a card asset")
        with local_path.open("rb") as stream:
            os.fsync(stream.fileno())
        os.chmod(local_path, 0o600)
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        entry["formatRecognized"] = _valid_asset(name, data)
        entry["status"] = "mac-backup-verified"
        _save_state(directory, state)
        if moved.get("exitCode") != 0 or not moved.get("ok"):
            raise ExportError(f"AirTraffic reported a transfer error for {name}")
        if not airlift.write_file(udid, target, name, data):
            raise ExportError(f"Cannot restore the card copy of {name}")
        entry["status"] = "card-copy-written"
        _save_state(directory, state)
        # This read checks the new copy; its own restoration is best effort.
        copied = airlift.read_file(udid, target, name)
        if copied != data:
            raise ExportError(f"The restored card copy of {name} did not verify")
        entry["status"] = "card-copy-verified"
        _save_state(directory, state)
    except Exception as error:
        primary_error = error
    finally:
        if stage_attempted:
            try:
                probe = airlift.native("afc-stat", udid, recovered)
                is_present = airlift.operation_ok(probe)
                if not is_present:
                    finish = airlift.native("finish-export", udid, source, link,
                                             recovered, os.fspath(snapshot_root))
                else:
                    finish = airlift.native("finish-export-preserve", udid, source,
                                             link, recovered, os.fspath(snapshot_root))
                if not airlift.operation_ok(finish):
                    raise ExportError(f"Could not restore Books staging for {name}")
                entry["booksRestored"] = True
                entry["deviceOriginalRetained"] = is_present
                if is_present and data is not None:
                    check_path = directory / f"{name}.device-check"
                    checked = airlift.native("afc-read", udid, recovered,
                                              os.fspath(check_path))
                    if not airlift.operation_ok(checked) or not check_path.is_file() or \
                            check_path.read_bytes() != data:
                        raise ExportError(f"Device recovery copy changed for {name}")
                    check_path.unlink()
                    entry["deviceOriginalVerified"] = True
            except Exception as error:
                entry.setdefault("booksRestored", False)
                if primary_error is None:
                    primary_error = error
            _save_state(directory, state)
    if primary_error is not None:
        safely_unavailable = (isinstance(primary_error, AssetUnavailable)
                              and entry.get("booksRestored") is True)
        entry["status"] = "unavailable" if safely_unavailable else "needs-recovery"
        _save_state(directory, state)
        if safely_unavailable:
            raise primary_error
        raise ExportError(str(primary_error)) from primary_error
    if data is None:
        raise ExportError(f"No verified data for {name}")
    entry["status"] = ("exported-with-device-recovery" if
                       entry.get("deviceOriginalRetained") else
                       "exported-with-mac-recovery")
    _save_state(directory, state)
    return data


def export_card(udid: str, card_hash: str, output: Path | None,
                recovery_root: Path = RECOVERY_ROOT) -> ExportResult:
    if not CARD_HASH.fullmatch(card_hash):
        raise ValueError("Invalid card hash")
    if output is not None and (not output.name or output.suffix.lower() != ".zip"):
        raise ValueError("Output must be a .zip file")
    recovery_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(recovery_root, 0o700)
    directory = Path(tempfile.mkdtemp(prefix="card-", dir=recovery_root))
    state = {"cardHash": card_hash, "deviceUDID": udid,
             "output": os.fspath(output) if output is not None else None,
             "assets": {}}
    _save_state(directory, state)
    target = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    assets = {}
    unavailable = []
    try:
        for name in ASSETS:
            try:
                assets[name] = _export_one(udid, target, name, directory, state)
            except AssetUnavailable:
                unavailable.append(name)
        if not assets:
            raise ExportError("None of the three card face assets could be read")
        if output is not None:
            output.parent.mkdir(parents=True, exist_ok=True)
            pending = output.with_name(output.name + f".{secrets.token_hex(6)}.pending")
            try:
                with zipfile.ZipFile(pending, "w", compression=zipfile.ZIP_STORED) as archive:
                    for name, data in assets.items():
                        archive.writestr(name, data)
                with zipfile.ZipFile(pending) as archive:
                    if archive.namelist() != list(assets):
                        raise ExportError("Export archive contents did not verify")
                    for name in assets:
                        if archive.read(name) != assets[name]:
                            raise ExportError(f"Export archive failed verification: {name}")
                with pending.open("rb") as stream:
                    os.fsync(stream.fileno())
                os.replace(pending, output)
                fd = os.open(output.parent, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            finally:
                pending.unlink(missing_ok=True)
        state["status"] = "complete-partial" if unavailable else "complete"
        state["unavailable"] = unavailable
        _save_state(directory, state)
        return ExportResult(
            recovery=directory,
            exported=tuple(assets),
            unavailable=tuple(unavailable),
            unrecognized=tuple(name for name in assets
                               if not state["assets"].get(name, {}).get("formatRecognized", True)),
        )
    except Exception as error:
        state["status"] = "incomplete"
        _save_state(directory, state)
        raise ExportError(f"{error}; recovery files: {directory}") from error
