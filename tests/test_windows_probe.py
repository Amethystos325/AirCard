import asyncio
import io
import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

import windows_canary as canary
import windows_probe as probe
from windows_airtraffic import validate_canary_assets
from windows_apple_runtime import is_corefp_lookup


class MemoryAFC:
    def __init__(self):
        self.files = {}
        self.dirs = set()
        self.links = {}
        self.removed = []

    async def exists(self, name):
        return name in self.files or name in self.dirs or name in self.links

    async def stat(self, name):
        if name in self.files:
            return {"st_ifmt": "S_IFREG", "st_size": len(self.files[name])}
        if name in self.dirs:
            return {"st_ifmt": "S_IFDIR", "st_size": 0}
        if name in self.links:
            return {"st_ifmt": "S_IFLNK", "st_size": 0}
        raise FileNotFoundError(name)

    async def makedirs(self, name):
        parts = name.split("/")
        self.dirs.update("/".join(parts[:index]) for index in range(1, len(parts) + 1))

    async def set_file_contents(self, name, data):
        self.files[name] = data

    async def get_file_contents(self, name):
        return self.files[name]

    async def fopen(self, name, mode):
        return name

    async def fread(self, handle, size):
        return self.files[handle][:size]

    async def fclose(self, handle):
        pass

    async def rename(self, source, destination):
        self.files[destination] = self.files.pop(source)

    async def listdir(self, name):
        prefix = name + "/"
        return sorted({path[len(prefix):].split("/")[0] for path in
                       [*self.files, *self.dirs, *self.links] if path.startswith(prefix)})

    async def rm_single(self, name):
        if name in self.dirs:
            if await self.listdir(name):
                raise OSError("Directory is not empty")
            self.dirs.remove(name)
        elif name in self.links:
            del self.links[name]
        else:
            del self.files[name]
        self.removed.append(name)


class ZipService:
    def __init__(self, afc):
        self.afc = afc

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def send_plist(self, value, **kwargs):
        self.source = value["MediaSubdir"]

    async def sendall(self, archive):
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            for info in z.infolist():
                name = self.source + "/" + info.filename.rstrip("/")
                if info.is_dir():
                    await self.afc.makedirs(name)
                elif info.filename.endswith("/link"):
                    self.afc.links[name] = z.read(info)
                else:
                    self.afc.files[name] = z.read(info)

    async def recv_plist(self):
        return {"Status": "Complete"}


class Client:
    udid = "synthetic-device"

    def __init__(self, afc):
        self.afc = afc

    async def start_lockdown_service(self, service):
        if service != "com.apple.streaming_zip_conduit":
            raise AssertionError(service)
        return ZipService(self.afc)


class WindowsProbeTests(unittest.IsolatedAsyncioTestCase):
    @unittest.skipUnless(importlib.util.find_spec("pymobiledevice3"), "Optional prototype dependency is not installed")
    async def test_usbmux_client_identity_preserves_connect_request(self):
        from pymobiledevice3 import usbmux
        original = usbmux.PlistMuxConnection._send
        try:
            probe.configure_usbmux_client()
            transport = usbmux.PlistMuxConnection(None)
            with patch.object(usbmux.BinaryMuxConnection, "_send", AsyncMock()) as send:
                await transport._send({"MessageType": "Connect", "DeviceID": 7, "PortNumber": 32498})
            packet = send.call_args.args[1]
            payload = plistlib.loads(packet["data"])
            self.assertEqual(payload["ProgName"], "AirCard")
            self.assertEqual(payload["DeviceID"], 7)
            self.assertEqual(payload["PortNumber"], 32498)
            self.assertEqual(payload["MessageType"], "Connect")
            self.assertEqual(packet["header"]["tag"], 1)
        finally:
            usbmux.PlistMuxConnection._send = original

    async def test_log_framing_uses_different_endianness(self):
        for kind, order in ((1, "big"), (2, "little")):
            service = AsyncMock()
            service.recvall.side_effect = [bytes([kind]) + (3).to_bytes(4, order), b"abc"]
            self.assertEqual(await probe.trace_frame(service), (kind, b"abc"))

    async def test_log_rejects_corrupt_size_before_body_read(self):
        service = AsyncMock()
        service.recvall.return_value = b"\x02" + (probe.MAX_FRAME + 1).to_bytes(4, "little")
        with self.assertRaises(ValueError):
            await probe.trace_frame(service)
        self.assertEqual(service.recvall.await_count, 1)

    def test_log_preserves_multiline_and_rejects_truncation(self):
        process = b"passd\0"
        image = b"PassKit\0"
        message = b"Resource lookup\n/var/mobile/Library/Passes/Cards/" + b"A" * 27 + b"=.pkpass\0"
        header = bytearray(129)
        header[0] = 2
        struct.pack_into("<I", header, 5, len(header))
        struct.pack_into("<H", header, 37, len(process))
        struct.pack_into("<H", header, 107, len(image))
        struct.pack_into("<I", header, 109, len(message))
        record = bytes(header) + process + image + message
        self.assertIn("\n/var/mobile", probe.trace_text(record))
        self.assertIsNone(probe.trace_text(record[:-1]))

    async def test_afc_roundtrip_restores_and_cleans(self):
        afc = MemoryAFC()
        with tempfile.TemporaryDirectory() as temp:
            result = await probe.afc_canary(afc, Path(temp) / "state.json")
        self.assertEqual(result["stage"], "cleaned")
        self.assertFalse(afc.files or afc.dirs)
        self.assertFalse(result["airtrafficVerified"])

    async def test_afc_collision_does_not_touch_existing_path(self):
        afc = MemoryAFC()
        token = "a" * 32
        root = "aircard-probe-" + token
        await afc.makedirs(root)
        afc.files[root + "/canary.bin"] = b"preexisting"
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(RuntimeError):
                await probe.afc_canary(afc, Path(temp) / "state.json", token)
        self.assertEqual(afc.files[root + "/canary.bin"], b"preexisting")
        self.assertFalse(afc.removed)

    async def test_afc_readback_failure_retains_test_artifacts(self):
        afc = MemoryAFC()
        afc.get_file_contents = AsyncMock(return_value=b"corrupt")
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "state.json"
            with self.assertRaises(RuntimeError):
                await probe.afc_canary(afc, path)
            self.assertEqual(json.loads(path.read_text())["status"], "failed")
        self.assertTrue(afc.files)
        self.assertFalse(afc.removed)

    async def test_backup_tampering_prevents_all_restore_writes(self):
        afc = MemoryAFC()
        await afc.makedirs("Books/Sync")
        afc.files[canary.BOOK_FILES[0]] = b"original"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            snapshot = await canary.snapshot_books(afc, root)
            (root / "books-0.bin").write_bytes(b"tampered")
            afc.set_file_contents = AsyncMock()
            with self.assertRaises(ValueError):
                await canary.restore_books(afc, root, snapshot)
            afc.set_file_contents.assert_not_awaited()

    async def test_cleanup_does_not_follow_symlink(self):
        afc = MemoryAFC()
        root = "aircard-probe-" + "a" * 32 + "-source-0"
        await afc.makedirs(root)
        afc.links[root + "/link"] = b"/var/mobile/Library/Passes"
        afc.files["unrelated"] = b"keep"
        await canary.remove_probe_tree(afc, root)
        self.assertEqual(afc.files, {"unrelated": b"keep"})
        with self.assertRaises(ValueError):
            await canary.remove_probe_tree(afc, "Books")

    async def test_airtraffic_failure_restores_books_and_keeps_journal(self):
        afc = MemoryAFC()
        await afc.makedirs("Books/Sync")
        original = plistlib.dumps({"Books": []})
        afc.files["Books/Sync/Books.plist"] = original
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(canary, "native_airtraffic", AsyncMock(side_effect=[{"ok": True}, RuntimeError("test failure")])):
                with self.assertRaises(RuntimeError):
                    await canary.protected_canary(Client(afc), afc, Path(temp), Path(temp) / "result.json")
            state = json.loads(next(Path(temp).glob("recovery-*/state.json")).read_text())
            self.assertTrue(state["booksRestored"])
            self.assertEqual(state["status"], "failed")
            self.assertFalse(state["stagingCleaned"])
        self.assertEqual(afc.files["Books/Sync/Books.plist"], original)

    async def test_protected_cycle_verifies_bytes_restore_and_cleanup(self):
        afc = MemoryAFC()
        await afc.makedirs("Books/Sync")
        original_row = {"Persistent ID": "existing-book", "Item ID": "20", "DSID": "1"}
        original = plistlib.dumps({"Books": [original_row], "KeepThisKey": True})
        afc.files["Books/Sync/Books.plist"] = original
        protected = {}
        previous_ids = set()

        async def transfer(runtime, udid, assets=None, *, check_sync=False):
            if check_sync:
                return {"ok": True}
            staged = plistlib.loads(afc.files["Books/Sync/Books.plist"])
            self.assertTrue(staged["KeepThisKey"])
            self.assertIn(original_row, staged["Books"])
            current_ids = {row["Persistent ID"] for row in staged["Books"]}
            self.assertTrue(previous_ids <= current_ids, "Reconciliation would delete previous assets")
            previous_ids.update(current_ids)
            item_ids = [row["Item ID"] for row in staged["Books"]]
            self.assertEqual(len(item_ids), len(set(item_ids)))
            pairs = json.loads(assets.read_text())
            validate_canary_assets(pairs)
            source_link, destination_link = pairs[0]
            afc.links[destination_link] = afc.links.pop(source_link.removeprefix("../../"))
            source, destination = pairs[1]
            if source.endswith("/payload"):
                protected["canary"] = afc.files.pop(source.removeprefix("../../"))
            else:
                self.assertTrue(source.endswith(".bin"))
                afc.files[destination] = protected.pop("canary")
            return {"ok": True}

        with tempfile.TemporaryDirectory() as temp:
            with patch.object(canary, "native_airtraffic", transfer):
                result = await canary.protected_canary(Client(afc), afc, Path(temp), Path(temp) / "result.json")
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["readbackSHA256"], result["payloadSHA256"])
        self.assertEqual(result["restoredReadbackSHA256"], result["payloadSHA256"])
        self.assertTrue(result["protectedCanaryRemoved"] and result["booksRestored"] and result["stagingCleaned"])
        self.assertFalse(protected)
        self.assertEqual(afc.files, {"Books/Sync/Books.plist": original})
        self.assertEqual(afc.dirs, {"Books", "Books/Sync"})

    async def test_failed_preflight_does_not_stage_or_write_books(self):
        afc = MemoryAFC()
        await afc.makedirs("Books/Sync")
        afc.files["Books/Sync/Books.plist"] = b"original-books"
        afc.set_file_contents = AsyncMock()
        client = Client(afc)
        client.start_lockdown_service = AsyncMock()
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(canary, "native_airtraffic", AsyncMock(side_effect=RuntimeError("Grappa failed"))):
                with self.assertRaises(RuntimeError):
                    await canary.protected_canary(client, afc, Path(temp), Path(temp) / "report.json")
            state = json.loads(next(Path(temp).glob("recovery-*/state.json")).read_text())
            self.assertFalse(state["protectedWriteAttempted"])
            self.assertTrue(state["booksRestored"])
        afc.set_file_contents.assert_not_awaited()
        client.start_lockdown_service.assert_not_awaited()

    async def test_restore_never_truncates_original_files(self):
        afc = MemoryAFC()
        await afc.makedirs("Books/Sync")
        name = "Books/Sync/Books.plist"
        afc.files[name] = b"original"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            snapshot = await canary.snapshot_books(afc, root)
            afc.files[name] = b"changed"
            write = afc.set_file_contents

            async def only_temporary(path, data):
                self.assertNotIn(path, canary.BOOK_FILES)
                await write(path, data)

            afc.set_file_contents = only_temporary
            await canary.restore_books(afc, root, snapshot)
        self.assertEqual(afc.files, {name: b"original"})


class WindowsNativeBoundaryTests(unittest.TestCase):
    def test_registry_redirect_is_limited_to_exact_hklm_corefp_key(self):
        key = "Software\\Apple Inc.\\CoreFP"
        self.assertTrue(is_corefp_lookup(0x80000002, key))
        self.assertTrue(is_corefp_lookup(0xFFFFFFFF80000002, key.upper().encode()))
        for root, path in ((0x80000001, key), (None, key), (0x80000002, None),
                           (0x80000002, key + "\\Other"), (0x80000002, "Software\\Microsoft")):
            self.assertFalse(is_corefp_lookup(root, path))

    def test_canary_guard_rejects_wallet_paths_and_mixed_runs(self):
        token = "a" * 32
        source = f"../../aircard-probe-{token}-source-0/payload"
        destination = f"aircard-probe-{token}-link-0/aircard-probe-{token}.bin"
        validate_canary_assets([[source, destination]])
        for bad in (
            [["../../../../mobile/Library/Passes/aircard-probe-test", destination]],
            [[source, destination + "/../../Wallet"]],
            [[source, destination], [source.replace(token, "b" * 32), destination.replace(token, "b" * 32)]],
        ):
            with self.assertRaises(ValueError):
                validate_canary_assets(bad)


if __name__ == "__main__":
    unittest.main()
