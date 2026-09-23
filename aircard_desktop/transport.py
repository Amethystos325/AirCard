"""Recoverable, restricted file transfers; never accepts a caller-supplied device path."""
from __future__ import annotations

import asyncio
import json
import plistlib
import re
import secrets
import sys
from pathlib import Path

from apply_card_skin import build_archive
from windows_canary import snapshot_books, restore_books, books_match, canary_books, bounded_file, remove_probe_tree
from windows_probe import select_device, prepare_apple_runtime, trace_frame, trace_text
from .storage import save, put, read, sha, identity
from .worker import target

BUILDS = {("27.0", "24A435"), ("27.0", "24A437"), ("27.0", "24A5390f")}


async def device_info():
    async with await select_device(None) as client:
        values = client.all_values
        version, build = str(values.get("ProductVersion", "")), str(values.get("BuildVersion", ""))
        return {"id": client.udid, "key": identity(client.udid), "name": values.get("DeviceName", "iPhone"),
                "product": client.product_type, "version": version, "build": build,
                "compatible": (version, build) in BUILDS, "connected": True}


async def native(job, directory):
    path = directory / ("native-" + secrets.token_hex(8) + ".json")
    save(path, job)
    command = [sys.executable]
    if not getattr(sys, "frozen", False):
        command.append(str(Path(__file__).resolve().parents[1] / "desktop_backend.py"))
    command += ["--native-worker", str(path)]
    # Never inherit the protocol pipe: the server has a blocking reader on it.
    # Windows child-runtime initialization can wait on that same pipe handle.
    process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                                                  stderr=asyncio.subprocess.PIPE,
                                                  **({"creationflags": 0x08000000} if sys.platform == "win32" else {}))
    communication = asyncio.create_task(process.communicate())
    try:
        output, diagnostic = await asyncio.wait_for(asyncio.shield(communication), 45)
    except BaseException:
        if process.returncode is None:
            process.kill()
        await process.wait()
        try:
            output, diagnostic = await communication
            put(path.with_suffix('.diagnostic.txt'), output[-65536:] + b'\n' + diagnostic[-65536:])
        except BaseException:
            pass
        raise
    finally:
        path.unlink(missing_ok=True)
    result = {}
    for line in output.splitlines():
        try:
            row = json.loads(line)
            if "ok" in row:
                result = row
        except ValueError:
            continue
    if process.returncode or not result.get("ok"):
        put(path.with_suffix('.diagnostic.txt'), output[-65536:] + b'\n' + diagnostic[-65536:])
        raise RuntimeError("SYNC_FAILED")
    return result


class Session:
    def __init__(self, store, state):
        self.store, self.state = store, state
        self.directory = store.root / "transactions" / state["id"] / "transport"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.journal = read(self.directory / "journal.json", {"roots": [], "identifiers": [], "pending": None})

    def checkpoint(self):
        save(self.directory / "journal.json", self.journal)

    async def __aenter__(self):
        from pymobiledevice3.services.afc import AfcService
        self.client = await select_device(self.state["device"])
        try:
            values = self.client.all_values
            if (str(values.get("ProductVersion")), str(values.get("BuildVersion"))) not in BUILDS:
                raise RuntimeError("UNSUPPORTED_DEVICE")
            self.state["deviceInfo"] = {"product": self.client.product_type,
                                        "version": str(values.get("ProductVersion")),
                                        "build": str(values.get("BuildVersion"))}
            self.store.checkpoint(self.state)
            self.afc = await AfcService(self.client).__aenter__()
            self.runtime = await asyncio.to_thread(prepare_apple_runtime, self.store.root / "runtime") if sys.platform == "win32" else None
            snapshot_path = self.directory / "books-snapshot.json"
            if snapshot_path.exists():
                self.snapshot = read(snapshot_path)
            else:
                if self.journal.get("roots") or self.journal.get("pending"):
                    raise RuntimeError("INVALID_BACKUP")
                # A crash while taking the initial snapshot cannot have moved a
                # card file yet. Restart only that incomplete, unpublished copy.
                for index in range(6):
                    (self.directory / f"books-{index}.bin").unlink(missing_ok=True)
                self.snapshot = await snapshot_books(self.afc, self.directory)
            await native(self.job(checkSync=True), self.directory)
            return self
        except BaseException:
            await self.client.close()
            raise

    async def __aexit__(self, *args):
        await self.afc.__aexit__(*args)
        await self.client.close()

    def job(self, **extra):
        return {"udid": self.state["device"], "runtime": str(self.runtime) if self.runtime else None, **extra}

    async def transfer(self, area, leaf, direction, data=b""):
        directory, leaf = target(self.state["card"], area, leaf)
        token = secrets.token_hex(16)
        source, link, recovered = (f"aircard-probe-{token}-{kind}-0" for kind in ("source", "link", "recovered"))
        for path in (source, link, recovered):
            if await self.afc.exists(path):
                raise RuntimeError("STAGING_COLLISION")
        pairs = [[f"../../{source}/p0/p1/p2/link", link]]
        pairs.append([f"../../{source}/payload", link + "/" + leaf] if direction == "push" else
                     [f"../../{link}/{leaf}", recovered])
        self.journal["roots"].extend([source, link, recovered])
        self.journal["identifiers"].extend(pair[0] for pair in pairs)
        self.checkpoint()
        async with await self.client.start_lockdown_service("com.apple.streaming_zip_conduit") as service:
            await service.send_plist({"MediaSubdir": source}, fmt=plistlib.FMT_BINARY)
            await service.sendall(build_archive(directory, data if direction == "push" else b"aircard-desktop-staging"))
            try:
                await asyncio.wait_for(service.recv_plist(), 10)
            except TimeoutError:
                pass
        if (await self.afc.stat(source + "/p0/p1/p2/link")).get("st_ifmt") != "S_IFLNK":
            raise RuntimeError("STAGING_FAILED")
        if await bounded_file(self.afc, source + "/payload") != (data if direction == "push" else b"aircard-desktop-staging"):
            raise RuntimeError("STAGING_FAILED")
        await self.afc.makedirs("Books/Sync")
        await self.afc.set_file_contents("Books/Sync/Books.plist", canary_books(self.directory, self.snapshot, self.journal["identifiers"]))
        # Persist before moving: a disconnected phone may hold the only copy here.
        if direction == "pull":
            self.journal["pending"] = {"area": area, "leaf": leaf, "recovered": recovered}
            self.checkpoint()
        missing = False
        async with await self.client.start_lockdown_service("com.apple.os_trace_relay") as log:
            await log.send_plist({"Request": "StartActivity", "Pid": 0xffffffff, "MessageFilter": 0xffff,
                                  "StreamFlags": 0x3c}, fmt=plistlib.FMT_BINARY)
            kind, initial = await asyncio.wait_for(trace_frame(log), 10)
            if kind != 1 or plistlib.loads(initial).get("Status") != "RequestSuccessful":
                raise RuntimeError("TRACE_FAILED")

            async def watch():
                nonlocal missing
                while True:
                    kind, packet = await trace_frame(log)
                    message = trace_text(packet) if kind == 2 else None
                    if message and message.startswith("/usr/libexec/atc ") and "asset not found in airlock" in message and pairs[1][0] in message:
                        missing = True

            listener = asyncio.create_task(watch())
            try:
                await native(self.job(card=self.state["card"], area=area, leaf=leaf, token=token,
                                      direction=direction, assets=pairs), self.directory)
                await asyncio.sleep(.25)
            finally:
                listener.cancel()
                try:
                    await listener
                except asyncio.CancelledError:
                    pass
        if direction == "push":
            if await self.afc.exists(source + "/payload"):
                raise RuntimeError("WRITE_NOT_VERIFIED")
            return None
        if await self.afc.exists(recovered):
            return await bounded_file(self.afc, recovered, 32 * 1024 * 1024)
        if missing:
            self.journal["pending"] = None
            self.checkpoint()
            return None
        raise RuntimeError("READ_INDETERMINATE")

    async def read(self, area, leaf):
        data = await self.transfer(area, leaf, "pull")
        if data is not None:
            # Local durable copy precedes every writeback, including classification.
            put(self.directory / "pending.bin", data)
            self.journal["pending"]["sha256"] = sha(data)
            self.checkpoint()
            await self.transfer(area, leaf, "push", data)
            self.journal["pending"] = None
            self.checkpoint()
        return data

    async def write(self, area, leaf, data):
        if data is None:
            # Move to retained recovery rather than relying on AFC symlink unlink.
            moved = await self.transfer(area, leaf, "pull")
            if moved is not None:
                put(self.directory / ("removed-" + secrets.token_hex(8) + ".bin"), moved)
            self.journal["pending"] = None
            self.checkpoint()
            if moved is not None:
                observed = await self.transfer(area, leaf, "pull")
                if observed is not None:
                    put(self.directory / "pending.bin", observed)
                    self.journal["pending"]["sha256"] = sha(observed)
                    self.checkpoint()
                    raise RuntimeError("WRITE_NOT_VERIFIED")
            return
        await self.transfer(area, leaf, "push", data)
        observed = await self.read(area, leaf)
        if observed != data:
            raise RuntimeError("WRITE_NOT_VERIFIED")

    async def recover_pending(self):
        pending = self.journal.get("pending")
        if not pending:
            return
        path = pending["recovered"]
        if (self.state.get("mode") == "classify" and not self.state.get("writeStarted")
                and re.fullmatch(r"aircard-export-probe-[0-9a-f]{12}", self.state["card"])
                and pending.get("area") == "pkpass" and pending.get("leaf") == "pass.json"
                and not pending.get("sha256") and not (self.directory / "pending.bin").exists()
                and self.journal.get("roots", [])[-1:] == [path]
                and not await self.afc.exists(path)):
            # An older scanner accepted this known app-generated probe path as
            # a card ID. It has no Wallet pass.json to restore. Finish below
            # still restores Books and removes only our temporary probe roots.
            self.journal["pending"] = None
            self.checkpoint()
            return
        if not await self.afc.exists(path) and not pending.get("sha256") and not self.state.get("writeStarted"):
            await self.retry_pending_pull(pending)
        if await self.afc.exists(path):
            data = await bounded_file(self.afc, path, 32 * 1024 * 1024)
        elif pending.get("sha256"):
            data = (self.directory / "pending.bin").read_bytes()
        elif self.state.get("writeStarted"):
            # An interrupted move may never have started. Once writes began, the
            # verified pre-operation snapshot is authoritative for rollback.
            key = pending["area"] + "/" + pending["leaf"]
            entry = self.state.get("originals", {}).get(key)
            if entry is None:
                raise RuntimeError("RECOVERY_INDETERMINATE")
            data = self.store.load_blob(self.directory.parent / "before", entry)
            if data is None:
                # No original file is at risk; rollback will remove a new file.
                self.journal["pending"] = None
                self.checkpoint()
                return
        else:
            raise RuntimeError("RECOVERY_INDETERMINATE")
        if pending.get("sha256") and sha(data) != pending["sha256"]:
            raise RuntimeError("INVALID_BACKUP")
        await self.transfer(pending["area"], pending["leaf"], "push", data)
        self.journal["pending"] = None
        self.checkpoint()

    async def retry_pending_pull(self, pending):
        # A pull can finish without a recovered file or a reliable missing-file
        # trace. Replay its existing sync entry once; never assume absence means
        # the original is safe to discard.
        if pending.get("replayAttempted"):
            return
        roots = self.journal.get("roots", [])
        identifiers = self.journal.get("identifiers", [])
        if len(roots) < 3 or len(identifiers) < 2:
            raise RuntimeError("RECOVERY_INDETERMINATE")
        source, link, recovered = roots[-3:]
        match = re.fullmatch(r"aircard-probe-([0-9a-f]{32})-source-0", source)
        if not match or link != f"aircard-probe-{match[1]}-link-0" or recovered != pending["recovered"]:
            raise RuntimeError("RECOVERY_INDETERMINATE")
        token = match[1]
        area, leaf = pending["area"], pending["leaf"]
        target(self.state["card"], area, leaf)
        assets = [[f"../../{source}/p0/p1/p2/link", link], [f"../../{link}/{leaf}", recovered]]
        if identifiers[-2:] != [pair[0] for pair in assets]:
            raise RuntimeError("RECOVERY_INDETERMINATE")
        if not await self.afc.exists(link) or (await self.afc.stat(link)).get("st_ifmt") != "S_IFLNK":
            raise RuntimeError("RECOVERY_INDETERMINATE")
        if await bounded_file(self.afc, source + "/payload") != b"aircard-desktop-staging":
            raise RuntimeError("RECOVERY_INDETERMINATE")
        if await bounded_file(self.afc, "Books/Sync/Books.plist") != canary_books(self.directory, self.snapshot, identifiers):
            raise RuntimeError("RECOVERY_INDETERMINATE")
        pending["replayAttempted"] = True
        self.checkpoint()
        # The first sync asset already moved the nested link into place. Only
        # the second asset is safe to request again.
        retry_assets = [assets[1]]
        await native(self.job(card=self.state["card"], area=area, leaf=leaf, token=token,
                              direction="recover", assets=retry_assets), self.directory)
        await asyncio.sleep(.25)

    async def finish(self):
        if self.journal.get("pending"):
            raise RuntimeError("RECOVERY_REQUIRED")
        await restore_books(self.afc, self.directory, self.snapshot)
        for path in self.journal["roots"]:
            await remove_probe_tree(self.afc, path)
        if not await books_match(self.afc, self.directory, self.snapshot):
            raise RuntimeError("BOOKS_RESTORE_FAILED")
        self.journal["complete"] = True
        self.checkpoint()

    async def isolate_unresolved(self):
        """Restore Books while retaining an unverified card move for later recovery."""
        pending = self.journal.get("pending")
        if (self.state.get("writeStarted") or not pending or not pending.get("replayAttempted")
                or pending.get("sha256") or await self.afc.exists(pending["recovered"])):
            raise RuntimeError("RECOVERY_REQUIRED")
        # No card file is discarded. The unresolved device staging roots and
        # journal remain available if a later recovery can find the original.
        await restore_books(self.afc, self.directory, self.snapshot)
        if not await books_match(self.afc, self.directory, self.snapshot):
            raise RuntimeError("BOOKS_RESTORE_FAILED")
        self.journal["booksRestoredForUnresolved"] = True
        self.checkpoint()
