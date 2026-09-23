"""Durable per-card copies of artwork already recovered from the device."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path

from card_export import CARD_HASH, ExportResult, _durable_write, artwork_order, supported_artwork_name


CACHE_ROOT = Path.home() / "Library" / "Application Support" / "AirCard" / "ArtworkCache"
GENERATION = re.compile(r"generation-[0-9a-f]{16}\Z")


def _card_directory(card_hash: str, cache_root: Path) -> Path:
    if not CARD_HASH.fullmatch(card_hash):
        raise ValueError("Invalid card hash")
    return cache_root / hashlib.sha256(card_hash.encode("ascii")).hexdigest()


def _publish_json(path: Path, payload: dict) -> None:
    pending = path.with_name(path.name + f".{secrets.token_hex(6)}.pending")
    try:
        _durable_write(pending, json.dumps(payload, indent=2).encode())
        os.replace(pending, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        pending.unlink(missing_ok=True)


def save_cached_card(card_hash: str, result: ExportResult,
                     cache_root: Path = CACHE_ROOT) -> dict:
    if not result.exported:
        raise ValueError("No artwork to cache")
    recovery_state = json.loads((result.recovery / "state.json").read_text())
    if recovery_state.get("cardHash") != card_hash:
        raise ValueError("Recovery does not belong to this card")
    cache_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(cache_root, 0o700)
    card_dir = _card_directory(card_hash, cache_root)
    card_dir.mkdir(mode=0o700, exist_ok=True)
    generation = f"generation-{secrets.token_hex(8)}"
    version_dir = card_dir / generation
    version_dir.mkdir(mode=0o700)
    checksums = {}
    for name in result.exported:
        if not supported_artwork_name(name):
            raise ValueError(f"Unexpected artwork name: {name}")
        data = (result.recovery / name).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        expected = recovery_state.get("assets", {}).get(name, {}).get("sha256")
        if not data or digest != expected:
            raise ValueError(f"Recovery checksum did not match for {name}")
        destination = version_dir / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _durable_write(destination, data)
        if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise OSError(f"Cached copy did not verify for {name}")
        checksums[name] = digest
    manifest = {
        "cardHash": card_hash,
        "generation": generation,
        "cachedAt": datetime.now(timezone.utc).isoformat(),
        "assets": checksums,
    }
    _publish_json(version_dir / "manifest.json", manifest)
    _publish_json(card_dir / "current.json", manifest)
    cached = get_cached_card(card_hash, cache_root)
    if cached is None:
        raise OSError("Published card artwork cache failed verification")
    return cached


def get_cached_card(card_hash: str, cache_root: Path = CACHE_ROOT) -> dict | None:
    card_dir = _card_directory(card_hash, cache_root)
    try:
        manifest = json.loads((card_dir / "current.json").read_text())
        generation = manifest["generation"]
        if manifest.get("cardHash") != card_hash or not GENERATION.fullmatch(generation):
            return None
        assets = manifest["assets"]
        if not isinstance(assets, dict) or not assets:
            return None
        files = {}
        for name, digest in assets.items():
            if not supported_artwork_name(name) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                return None
            path = card_dir / generation / name
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                return None
            files[name] = str(path)
        ordered = sorted(files, key=artwork_order)
        preview_name = ordered[0] if ordered else None
        if preview_name is None:
            return None
        return {"preview": files[preview_name], "previewName": preview_name,
                "assets": ordered,
                "cachedAt": manifest.get("cachedAt"), "files": files}
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return None
