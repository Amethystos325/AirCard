"""Airlift validation limited to a random /var/tmp canary, never Wallet files."""
from __future__ import annotations

import asyncio
import json
import os
import plistlib
import posixpath
import re
import secrets
from pathlib import Path

from apply_card_skin import AIRLOCK_ROOT, build_archive
from windows_probe import digest, native_airtraffic, write_report

BOOK_FILES = (
    "Books/Books.plist", "Books/Sync/Books.plist", "Books/Sync/Upload.plist",
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
)
BOOK_DIRS = ("Books", "Books/Sync", "Books/Sync/Database")
PROBE_ROOT = re.compile(r"aircard-probe-[0-9a-f]{32}-(?:source|link|recovered)-[0-3]\Z")


def durable_bytes(path: Path, data: bytes):
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


async def bounded_file(afc, path: str, limit: int = 128 * 1024 * 1024) -> bytes:
    info = await afc.stat(path)
    size = int(info.get("st_size", -1))
    if info.get("st_ifmt") != "S_IFREG" or not 0 <= size <= limit:
        raise RuntimeError("Unexpected file type or size: " + path)
    # Use a bounded read, even if the file grows after stat.
    handle = await afc.fopen(path, "r")
    try:
        data = await afc.fread(handle, size)
    finally:
        await afc.fclose(handle)
    if len(data) != size:
        raise RuntimeError("Incomplete read: " + path)
    return data


async def snapshot_books(afc, directory: Path) -> dict:
    snapshot = {"files": {}, "directories": {}}
    total = 0
    # Validate parents before touching files below them.
    for name in BOOK_DIRS:
        exists = await afc.exists(name)
        if exists and (await afc.stat(name)).get("st_ifmt") != "S_IFDIR":
            raise RuntimeError("Unexpected Books directory type")
        snapshot["directories"][name] = exists
    for index, name in enumerate(BOOK_FILES):
        row = {"exists": await afc.exists(name), "local": f"books-{index}.bin"}
        if row["exists"]:
            data = await bounded_file(afc, name)
            total += len(data)
            if total > 256 * 1024 * 1024:
                raise RuntimeError("Books snapshot exceeds prototype size limit")
            durable_bytes(directory / row["local"], data)
            row.update(size=len(data), sha256=digest(data))
        snapshot["files"][name] = row
    write_report(directory / "books-snapshot.json", snapshot)
    if not await books_match(afc, directory, snapshot):
        raise RuntimeError("Books changed during backup; close sync applications and retry")
    return snapshot


def checked_snapshot(directory: Path, snapshot: dict) -> dict[str, bytes | None]:
    if set(snapshot["files"]) != set(BOOK_FILES) or set(snapshot["directories"]) != set(BOOK_DIRS):
        raise ValueError("Invalid Books snapshot schema")
    data = {}
    for index, name in enumerate(BOOK_FILES):
        row = snapshot["files"][name]
        if row["local"] != f"books-{index}.bin" or type(row["exists"]) is not bool:
            raise ValueError("Invalid Books snapshot file")
        if row["exists"]:
            payload = (directory / row["local"]).read_bytes()
            if len(payload) != row["size"] or digest(payload) != row["sha256"]:
                raise ValueError("Books backup integrity check failed")
            data[name] = payload
        else:
            data[name] = None
    if any(type(value) is not bool for value in snapshot["directories"].values()):
        raise ValueError("Invalid directory state")
    return data


async def books_match(afc, directory: Path, snapshot: dict) -> bool:
    expected = checked_snapshot(directory, snapshot)
    for name, exists in snapshot["directories"].items():
        if await afc.exists(name) != exists:
            return False
        if exists and (await afc.stat(name)).get("st_ifmt") != "S_IFDIR":
            return False
    for name, data in expected.items():
        if await afc.exists(name) != (data is not None):
            return False
        if data is not None and await bounded_file(afc, name) != data:
            return False
    return True


async def restore_books(afc, directory: Path, snapshot: dict):
    # Validate every local backup before making the first device write.
    expected = checked_snapshot(directory, snapshot)
    for name in BOOK_DIRS:
        if await afc.exists(name):
            if (await afc.stat(name)).get("st_ifmt") != "S_IFDIR":
                raise RuntimeError("Books parent type changed; refusing restoration through a link")
        elif snapshot["directories"][name]:
            await afc.makedirs(name)
    for name, data in expected.items():
        exists = await afc.exists(name)
        if exists and (await afc.stat(name)).get("st_ifmt") != "S_IFREG":
            raise RuntimeError("Books file type changed; refusing restoration")
        if data is None:
            if exists:
                await afc.rm_single(name)
        else:
            # Never truncate a file that atc may still have memory-mapped.
            # Replace its directory entry only after checking the staged bytes.
            temporary = name + ".aircard-restore-" + secrets.token_hex(16)
            if await afc.exists(temporary):
                raise RuntimeError("Restore staging path is not fresh")
            try:
                await afc.set_file_contents(temporary, data)
                if await bounded_file(afc, temporary) != data:
                    raise RuntimeError("Restore staging readback mismatch")
                await afc.rename(temporary, name)
            finally:
                if await afc.exists(temporary):
                    await afc.rm_single(temporary)
    for name in reversed(BOOK_DIRS):
        if not snapshot["directories"][name] and await afc.exists(name):
            await afc.rm_single(name)  # Empty directories only.
    if not await books_match(afc, directory, snapshot):
        raise RuntimeError("Books restoration verification failed; retain the local backup")


def canary_books(directory: Path, snapshot: dict, identifiers: list[str]) -> bytes:
    """Keep existing and prior-cycle rows so reconciliation cannot delete them."""
    saved = checked_snapshot(directory, snapshot)
    document = {}
    rows = {}
    for name in BOOK_FILES[:2]:
        if saved[name] is None:
            continue
        value = plistlib.loads(saved[name])
        if not isinstance(value, dict) or not isinstance(value.get("Books", []), list):
            raise ValueError("Unsupported Books input schema")
        document.update(value)
        for row in value.get("Books", []):
            if not isinstance(row, dict) or not isinstance(row.get("Persistent ID"), str):
                raise ValueError("Unsupported Books row schema")
            rows[row["Persistent ID"]] = row
    next_item = max((int(row.get("Item ID", "0")) for row in rows.values()
                     if str(row.get("Item ID", "0")).isdigit()), default=0) + 1
    for identifier in dict.fromkeys(identifiers):
        if identifier in rows:
            raise ValueError("Canary identifier conflicts with an existing Books row")
        rows[identifier] = {"Persistent ID": identifier, "Item ID": str(next_item), "DSID": "1"}
        next_item += 1
    document["Books"] = list(rows.values())
    return plistlib.dumps(document, fmt=plistlib.FMT_BINARY)


async def remove_probe_tree(afc, root: str):
    if not PROBE_ROOT.fullmatch(root):
        raise ValueError("Refusing to clean a non-probe root")

    async def remove(path: str, depth: int = 0):
        if depth > 32:
            raise RuntimeError("Unexpected probe directory depth")
        if not await afc.exists(path):
            return
        kind = (await afc.stat(path)).get("st_ifmt")
        if kind == "S_IFDIR":
            for name in await afc.listdir(path):
                if name in (".", ".."):
                    continue
                if not name or "/" in name or "\\" in name:
                    raise RuntimeError("Unexpected directory entry")
                await remove(path + "/" + name, depth + 1)
        elif kind not in ("S_IFREG", "S_IFLNK"):
            raise RuntimeError("Unexpected staging file type")
        # AFC's file info reports symlinks as S_IFLNK; never descend through one.
        await afc.rm_single(path)

    await remove(root)
    if await afc.exists(root):
        raise RuntimeError("Probe staging remained after cleanup")


async def protected_canary(client, afc, runtime: Path, report: Path) -> dict:
    token = secrets.token_hex(16)
    leaf = f"aircard-probe-{token}.bin"
    directory = report.parent / f"recovery-{token}"
    directory.mkdir(parents=True, exist_ok=False)
    payload = b"AirCard Windows protected-file canary\n" + secrets.token_bytes(256)
    durable_bytes(directory / "canary.bin", payload)
    state = {"status": "pending", "target": "/var/tmp/" + leaf,
             "deviceFingerprint": digest(client.udid.encode()),
             "payloadSHA256": digest(payload), "recovery": str(directory),
             "booksRestored": False, "protectedCanaryRemoved": False,
             "protectedWriteAttempted": False,
             "stagingCleaned": False, "transfers": []}

    def checkpoint(stage):
        state["stage"] = stage
        write_report(directory / "state.json", state)

    checkpoint("snapshot_books")
    snapshot = await snapshot_books(afc, directory)
    roots = []
    all_identifiers = []
    touched_books = False
    failure = None
    try:
        checkpoint("preflight_sync")
        state["preflight"] = await native_airtraffic(runtime, client.udid, check_sync=True)
        if not await books_match(afc, directory, snapshot):
            raise RuntimeError("Books changed before staging; refusing to start")
        canary_books(directory, snapshot, [])  # Reject unknown schemas before staging.
        for index in range(4):
            # Write -> move/read -> restore -> move/read/remove the restored canary.
            # Only this fresh random filename outside Media is ever addressed.
            writing = index in (0, 2)
            source = f"aircard-probe-{token}-source-{index}"
            link = f"aircard-probe-{token}-link-{index}"
            recovered = f"aircard-probe-{token}-recovered-{index}"
            for path in (source, link, recovered):
                if await afc.exists(path):
                    raise RuntimeError("Generated staging path is not fresh")
            roots.extend([source, link, recovered])
            state["stagingRoots"] = roots.copy()
            checkpoint(f"stage_{index}")
            archive = build_archive("/var/tmp", payload)
            async with await client.start_lockdown_service("com.apple.streaming_zip_conduit") as service:
                await service.send_plist({"MediaSubdir": source}, fmt=plistlib.FMT_BINARY)
                await service.sendall(archive)
                try:
                    await asyncio.wait_for(service.recv_plist(), 10)
                except TimeoutError:
                    # As in the macOS helper, AFC staging checks are authoritative.
                    pass
            if (await afc.stat(source + "/p0/p1/p2/link")).get("st_ifmt") != "S_IFLNK":
                raise RuntimeError("StreamingZip did not stage the expected link")
            if await bounded_file(afc, source + "/payload", 4096) != payload:
                raise RuntimeError("StreamingZip payload verification failed")
            identifiers = [f"../../{source}/p0/p1/p2/link"]
            destinations = [link]
            if writing:
                identifiers.append(f"../../{source}/payload")
                destinations.append(link + "/" + leaf)
            else:
                identifier = posixpath.relpath(state["target"], AIRLOCK_ROOT)
                if index == 3:
                    # A separate asset identity for the second read of the same file.
                    parent, basename = posixpath.split(identifier)
                    identifier = parent + "/./" + basename
                identifiers.append(identifier)
                destinations.append(recovered)
            all_identifiers.extend(identifiers)
            # Mark BEFORE the write so even a partial write causes restoration.
            touched_books = True
            checkpoint(f"write_books_{index}")
            if not await afc.exists("Books/Sync"):
                await afc.makedirs("Books/Sync")
            await afc.set_file_contents("Books/Sync/Books.plist", canary_books(directory, snapshot, all_identifiers))
            assets = directory / f"assets-{index}.json"
            durable_bytes(assets, json.dumps(list(zip(identifiers, destinations))).encode())
            checkpoint(f"sync_{index}")
            if index == 0:
                state["protectedWriteAttempted"] = True
                checkpoint(f"sync_{index}")
            transfer = await native_airtraffic(runtime, client.udid, assets)
            state["transfers"].append(transfer)
            if not writing:
                observed = await bounded_file(afc, recovered, 4096)
                if observed != payload:
                    raise RuntimeError("Protected canary readback mismatch")
                state["readbackSHA256" if index == 1 else "restoredReadbackSHA256"] = digest(observed)
                if index == 3:
                    state["protectedCanaryRemoved"] = True
            checkpoint(f"verified_{index}")
    except BaseException as error:
        failure = error
        state["error"] = type(error).__name__ + ": " + str(error)
    finally:
        checkpoint("restore_books")
        if touched_books:
            try:
                await asyncio.wait_for(restore_books(afc, directory, snapshot), 30)
                state["booksRestored"] = True
            except BaseException as error:
                state["restoreError"] = type(error).__name__ + ": " + str(error)
                failure = failure or error
        else:
            try:
                state["booksRestored"] = await asyncio.wait_for(books_match(afc, directory, snapshot), 15)
                if not state["booksRestored"]:
                    # No explicit write happened, so do not overwrite concurrent changes.
                    state["restoreError"] = "Books changed independently before staging; backup retained without writeback."
            except Exception as error:
                state["restoreError"] = type(error).__name__
                failure = failure or error
        checkpoint("books_restore_checked")
    if failure is None:
        try:
            checkpoint("cleanup_staging")
            for root in roots:
                await remove_probe_tree(afc, root)
            state["stagingCleaned"] = True
        except BaseException as error:
            failure = error
            state["cleanupError"] = type(error).__name__ + ": " + str(error)
    early_stop = failure is not None and not roots and not touched_books
    if early_stop:
        state["stagingCleaned"] = True  # No staging was created.
    state["status"] = "passed" if failure is None else ("blocked" if early_stop else "failed")
    checkpoint("complete" if failure is None else ("blocked_before_staging" if early_stop else "recovery_required"))
    if failure is not None:
        error = RuntimeError(f"Protected canary stopped; inspect record at {directory / 'state.json'}")
        error.canary_result = state
        if hasattr(failure, "native_result"):
            error.native_result = failure.native_result
        raise error from failure
    return state
