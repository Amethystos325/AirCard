from __future__ import annotations

import asyncio
import base64
import json
import secrets
import zipfile
from pathlib import Path

from card_assets import build_card_assets, PNG_ASSET_NAMES
from card_export import classify_pass_data
from .storage import Store, save, read, identity, put
from .transport import Session, device_info
from .worker import ART, CACHE, CARD
from .images import prepare, artwork_preview


class Engine:
    def __init__(self, store=None, session_type=Session, emit=lambda event: None):
        self.store = store or Store()
        self.session_type, self.emit = session_type, emit
        self.lock = asyncio.Lock()
        self.active = None
        self.cancel_requested = False

    def progress(self, stage):
        if self.active:
            self.emit({"event": "progress", "operationId": self.active["id"], "stage": stage})

    def overview(self):
        cards = []
        for path in (self.store.root / "devices").glob("*/cards/*/card.json"):
            card = read(path)
            card["backup"] = (path.parent / "original" / "manifest.json").is_file()
            card["preview"] = self.preview(path.parent / "preview.png")
            cards.append(card)
        return {"cards": cards, "pending": [{k: s[k] for k in ("id", "deviceKey", "card", "status")} for s in self.store.pending()],
                "active": {k: self.active[k] for k in ("id", "deviceKey", "card", "mode")} if self.active else None}

    @staticmethod
    def preview(path):
        return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode() if path.is_file() else None

    def prepare_image(self, source, crop=None):
        token = secrets.token_hex(16)
        destination = self.store.root / "prepared" / (token + ".png")
        prepare(Path(source), destination, crop)
        return {"imageId": token, "preview": self.preview(destination)}

    def load_manifest(self, directory, device, card):
        manifest = read(directory / "manifest.json")
        if not manifest or manifest["deviceKey"] != identity(device) or manifest["card"] != card:
            raise ValueError("INVALID_BACKUP")
        if set(manifest["assets"]) != ART:
            raise ValueError("INVALID_BACKUP")
        return {name: self.store.load_blob(directory, row) for name, row in manifest["assets"].items()}

    async def operate(self, device, card, mode, image_id=None):
        if not CARD.fullmatch(card) or mode not in ("classify", "read", "apply", "restore"):
            raise ValueError("INVALID_REQUEST")
        if self.lock.locked():
            raise RuntimeError("BUSY")
        async with self.lock:
            if self.store.pending(device):
                raise RuntimeError("RECOVERY_REQUIRED")
            if self.store.quarantined_card(device, card):
                raise RuntimeError("CARD_QUARANTINED")
            card_dir = self.store.card(device, card)
            known = read(card_dir / "card.json", {})
            if mode in ("apply", "restore") and known.get("kind") != "secure-element":
                raise RuntimeError("CARD_NOT_CLASSIFIED")
            desired = None
            if mode == "apply":
                if not isinstance(image_id, str) or len(image_id) != 32 or any(c not in "0123456789abcdef" for c in image_id):
                    raise ValueError("INVALID_IMAGE")
                desired = dict(build_card_assets((self.store.root / "prepared" / (image_id + ".png")).read_bytes()))
            elif mode == "restore":
                desired = self.load_manifest(card_dir / "original", device, card)
            state = {"id": secrets.token_hex(16), "device": device, "deviceKey": identity(device),
                     "card": card, "mode": mode, "status": "running", "originals": {}, "writeStarted": False}
            self.active, self.cancel_requested = state, False
            self.store.checkpoint(state)
            transaction = self.store.root / "transactions" / state["id"]
            result = {}
            preview = None
            try:
                async with self.session_type(self.store, state) as session:
                    try:
                        self.progress("classifying")
                        pass_data = await session.read("pkpass", "pass.json")
                        kind = classify_pass_data(pass_data) if pass_data else "unknown"
                        if kind != "secure-element" and mode != "classify":
                            raise RuntimeError("CARD_NOT_CLASSIFIED")
                        meta = {"card": card, "deviceKey": state["deviceKey"], "kind": kind,
                                "label": self.card_label(pass_data)}
                        if mode != "classify":
                            self.progress("backingUp")
                            names = [("pkpass", name) for name in sorted(ART)]
                            if desired is not None:
                                names += [(area, leaf) for area in ("cache", "pkcache") for leaf in sorted(CACHE)]
                            for area, name in names:
                                if self.cancel_requested:
                                    raise RuntimeError("CANCELLED")
                                data = await session.read(area, name)
                                state["originals"][area + "/" + name] = self.store.blob(transaction / "before", area + "/" + name, data)
                                self.store.checkpoint(state)
                            originals = {name: self.store.load_blob(transaction / "before", state["originals"]["pkpass/" + name]) for name in ART}
                            if not any(originals.values()):
                                raise RuntimeError("ARTWORK_UNAVAILABLE")
                            original_dir = card_dir / "original"
                            if not (original_dir / "manifest.json").exists():
                                manifest = {"deviceKey": state["deviceKey"], "card": card,
                                            "assets": {name: self.store.blob(original_dir, name, data) for name, data in originals.items()}}
                                save(original_dir / "manifest.json", manifest)
                            # Revalidate the immutable backup before any new artwork write.
                            self.load_manifest(original_dir, device, card)
                            if desired is not None:
                                if self.cancel_requested:
                                    raise RuntimeError("CANCELLED")
                                state["writeStarted"] = True
                                self.store.checkpoint(state)
                                self.progress("writing")
                                for name in sorted(ART):
                                    await session.write("pkpass", name, desired[name])
                                self.progress("invalidating")
                                for area in ("cache", "pkcache"):
                                    for name in sorted(CACHE):
                                        await session.write(area, name, None)
                            selected = desired if desired is not None else originals
                            preview = artwork_preview(selected)
                        self.progress("cleaning")
                        await session.finish()
                        if preview:
                            put(card_dir / "preview.png", preview)
                        save(card_dir / "card.json", meta)
                        state["status"] = "complete"
                        result = {"card": meta, "operationId": state["id"]}
                    except BaseException:
                        self.progress("recovering")
                        try:
                            await session.recover_pending()
                            if state["writeStarted"]:
                                await self.rollback(session, state)
                            await session.finish()
                            state["status"] = "rolled_back"
                        except BaseException:
                            state["status"] = "needs_recovery"
                        raise
            except BaseException:
                if state["status"] == "running":
                    state["status"] = "needs_recovery"
                raise
            finally:
                self.store.checkpoint(state)
                self.active = None
                self.emit({"event": "changed"})
            return result

    @staticmethod
    def card_label(data):
        try:
            value = json.loads(data or b"{}")
            return str(value.get("organizationName") or value.get("description") or "")[:80]
        except (ValueError, TypeError):
            return ""

    async def rollback(self, session, state):
        directory = self.store.root / "transactions" / state["id"] / "before"
        # Check all backup files before the first rollback write.
        values = {key: self.store.load_blob(directory, row) for key, row in state["originals"].items()}
        completed = state.setdefault("rollbackCompleted", [])
        for key, data in values.items():
            if key in completed:
                continue
            area, leaf = key.split("/", 1)
            await session.write(area, leaf, data)
            completed.append(key)
            self.store.checkpoint(state)

    async def recover(self, operation_id):
        if self.lock.locked():
            raise RuntimeError("BUSY")
        if len(operation_id) != 32 or any(c not in "0123456789abcdef" for c in operation_id):
            raise ValueError("INVALID_REQUEST")
        async with self.lock:
            state = read(self.store.root / "transactions" / operation_id / "state.json")
            if not state or state["status"] in ("complete", "rolled_back"):
                raise ValueError("INVALID_REQUEST")
            self.active = state
            try:
                self.progress("recovering")
                async with self.session_type(self.store, state) as session:
                    await session.recover_pending()
                    if state["writeStarted"]:
                        await self.rollback(session, state)
                    await session.finish()
                state["status"] = "rolled_back"
                self.store.checkpoint(state)
                return {"recovered": True}
            finally:
                self.active = None
                self.emit({"event": "changed"})

    def export(self, device_key, card, destination):
        if not isinstance(device_key, str) or len(device_key) != 64 or any(c not in "0123456789abcdef" for c in device_key):
            raise ValueError("INVALID_REQUEST")
        directory = self.store.root / "devices" / device_key[:32] / "cards" / identity(card)[:32] / "original"
        manifest = read(directory / "manifest.json")
        if not manifest or manifest["deviceKey"] != device_key or manifest["card"] != card:
            raise ValueError("INVALID_BACKUP")
        files = {name: self.store.load_blob(directory, row) for name, row in manifest["assets"].items()}
        if set(files) != ART:
            raise ValueError("INVALID_BACKUP")
        destination = Path(destination)
        if destination.suffix.lower() != ".zip":
            raise ValueError("INVALID_REQUEST")
        import io
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            for name, data in files.items():
                if data is not None:
                    archive.writestr(name, data)
        put(destination, output.getvalue())
        return {"exported": True}
