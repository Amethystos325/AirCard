"""Export safety checks with device operations simulated."""

import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import card_export


PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" +
       b"\x00" * 13 + b"\x00\x00\x00\x00IEND\x00\x00\x00\x00")
PDF = b"%PDF-1.4\n%%EOF\n"
HASH = "a" * 27 + "="


def ok(**operation):
    return {"exitCode": 0, "targetGatePassed": True,
            "operation": {"ok": True, **operation}}


class ExportTests(unittest.TestCase):
    def test_classifies_secure_element_and_ordinary_passes(self):
        cases = (
            ({"paymentCard": {}}, "secure-element"),
            ({"paymentCard": {}, "transitCard": {}}, "secure-element"),
            ({"storeCard": {}}, "ordinary"),
            ({"coupon": {}}, "ordinary"),
            ({"generic": {}}, "ordinary"),
            ({"boardingPass": {}}, "ordinary"),
            ({"eventTicket": {}}, "ordinary"),
            ({"description": "unknown"}, "unknown"),
        )
        for document, kind in cases:
            with self.subTest(document=document):
                self.assertEqual(card_export.classify_pass_data(json.dumps(document).encode()), kind)

    def test_classification_reads_only_pass_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            def fake_one(_udid, _target, name, _directory, _state):
                self.assertEqual(name, "pass.json")
                return json.dumps({"paymentCard": {}}).encode()
            with patch.object(card_export, "_export_one", side_effect=fake_one):
                kind, recovery = card_export.classify_card("device", HASH, Path(temp))
            self.assertEqual(kind, "secure-element")
            state = json.loads((recovery / "state.json").read_text())
            self.assertEqual(state["classification"], kind)
            self.assertEqual(state["status"], "complete")

    def test_manifest_discovers_component_artwork_and_localizations(self):
        manifest = json.dumps({
            "pass.json": "a" * 40,
            "logo@3x.png": "b" * 40,
            "strip@2x.png": "c" * 40,
            "zh-Hans.lproj/logo@3x.png": "d" * 40,
            "../secret.png": "e" * 40,
        }).encode()
        expected = ("strip@2x.png", "logo@3x.png",
                    "zh-Hans.lproj/logo@3x.png")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def fake_one(_udid, _target, name, directory, state):
                if name == "manifest.json":
                    return manifest
                self.assertIn(name, expected)
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(PNG)
                state["assets"][name] = {"sha256": hashlib.sha256(PNG).hexdigest(),
                                         "formatRecognized": True}
                return PNG
            with patch.object(card_export, "_export_one", side_effect=fake_one):
                result = card_export.export_card("device", HASH, root / "face.zip", root / "recovery")
            self.assertEqual(result.exported, expected)
            with zipfile.ZipFile(root / "face.zip") as archive:
                self.assertEqual(archive.namelist(), list(expected))

    def test_manifest_rejects_unsupported_paths(self):
        self.assertFalse(card_export.supported_artwork_name("../strip.png"))
        self.assertFalse(card_export.supported_artwork_name("bad.lproj/../../logo.png"))
        self.assertTrue(card_export.supported_artwork_name("zh-Hans.lproj/logo@3x.png"))
        self.assertTrue(card_export.supported_artwork_name("customArt@2x.png"))
        self.assertFalse(card_export.supported_artwork_name("pass.json"))

    def test_archive_contains_only_all_fixed_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def fake_one(_udid, _target, name, _directory, _state):
                return PDF if name.endswith(".pdf") else PNG
            with patch.object(card_export, "_export_one", side_effect=fake_one):
                result = card_export.export_card("device", HASH, root / "face.zip",
                                                 root / "recovery")
            with zipfile.ZipFile(root / "face.zip") as archive:
                self.assertEqual(archive.namelist(), list(card_export.ASSETS))
                self.assertEqual(archive.read(card_export.ASSETS[2]), PDF)
            self.assertEqual(result.exported, card_export.ASSETS)
            self.assertEqual(json.loads((result.recovery / "state.json").read_text())["status"], "complete")

    def test_read_without_export_zip_recovers_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def fake_one(_udid, _target, name, directory, _state):
                if name != card_export.ASSETS[0]:
                    raise card_export.AssetUnavailable("missing")
                (directory / name).write_bytes(PNG)
                return PNG
            with patch.object(card_export, "_export_one", side_effect=fake_one):
                result = card_export.export_card("device", HASH, None, root)
            self.assertEqual(result.exported, (card_export.ASSETS[0],))
            self.assertEqual(json.loads((result.recovery / "state.json").read_text())["output"], None)
            self.assertEqual(list(root.rglob("*.zip")), [])

    def test_missing_asset_keeps_backup_and_exports_other_formats(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "face.zip"
            def fake_one(_udid, _target, name, directory, _state):
                if name == card_export.ASSETS[1]:
                    raise card_export.AssetUnavailable("missing")
                data = PDF if name.endswith(".pdf") else PNG
                (directory / name).write_bytes(data)
                return data
            with patch.object(card_export, "_export_one", side_effect=fake_one):
                result = card_export.export_card("device", HASH, output, root / "recovery")
            self.assertEqual(result.unavailable, (card_export.ASSETS[1],))
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.namelist(), [card_export.ASSETS[0], card_export.ASSETS[2]])
                self.assertEqual(archive.read(card_export.ASSETS[2]), PDF)
            self.assertEqual((result.recovery / card_export.ASSETS[0]).read_bytes(), PNG)
            self.assertEqual(json.loads((result.recovery / "state.json").read_text())["status"], "complete-partial")

    def test_all_unavailable_fails_without_replacing_existing_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "face.zip"
            output.write_bytes(b"existing export")
            with patch.object(card_export, "_export_one", side_effect=card_export.AssetUnavailable("missing")):
                with self.assertRaises(card_export.ExportError):
                    card_export.export_card("device", HASH, output, root / "recovery")
            self.assertEqual(output.read_bytes(), b"existing export")

    def test_read_failure_preserves_device_original_and_restores_books(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = {"assets": {}}
            calls = []
            def fake_native(command, _udid, *args):
                calls.append(command)
                if command == "afc-stat":
                    return ok(kind="S_IFREG", size=len(PNG))
                if command == "afc-read":
                    return {"exitCode": 1, "operation": {"ok": False}}
                return ok()
            with (patch.object(card_export.airlift, "native", side_effect=fake_native),
                  patch.object(card_export.airlift, "run_json", return_value={"ok": True, "exitCode": 0}),
                  patch.object(card_export.airlift, "write_file") as write):
                with self.assertRaises(card_export.ExportError):
                    card_export._export_one("device", "/var/tmp", card_export.ASSETS[0], root, state)
            write.assert_not_called()
            self.assertIn("finish-export-preserve", calls)
            self.assertNotIn("finish-write", calls)

    def test_writeback_failure_keeps_verified_mac_and_device_backups(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = {"assets": {}}
            calls = []
            def fake_native(command, _udid, *args):
                calls.append(command)
                if command == "afc-stat":
                    return ok(kind="S_IFREG", size=len(PNG))
                if command == "afc-read":
                    Path(args[1]).write_bytes(PNG)
                    return ok(size=len(PNG))
                return ok()
            with (patch.object(card_export.airlift, "native", side_effect=fake_native),
                  patch.object(card_export.airlift, "run_json", return_value={"ok": True, "exitCode": 0}),
                  patch.object(card_export.airlift, "write_file", return_value=False)):
                with self.assertRaises(card_export.ExportError):
                    card_export._export_one("device", "/var/tmp", card_export.ASSETS[0], root, state)
            self.assertEqual((root / card_export.ASSETS[0]).read_bytes(), PNG)
            self.assertIn("finish-export-preserve", calls)
            self.assertTrue(state["assets"][card_export.ASSETS[0]]["booksRestored"])
            self.assertEqual(state["assets"][card_export.ASSETS[0]]["status"], "needs-recovery")

    def test_absent_asset_restores_books_and_is_safe_to_skip(self):
        with tempfile.TemporaryDirectory() as temp:
            state = {"assets": {}}
            calls = []
            def fake_native(command, _udid, *args):
                calls.append(command)
                if command == "afc-stat":
                    return {"exitCode": 1, "operation": {"ok": False}}
                return ok()
            with (patch.object(card_export.airlift, "native", side_effect=fake_native),
                  patch.object(card_export.airlift, "run_json", return_value={"ok": True, "exitCode": 0})):
                with self.assertRaises(card_export.AssetUnavailable):
                    card_export._export_one("device", "/var/tmp", card_export.ASSETS[0], Path(temp), state)
            self.assertIn("finish-export", calls)
            self.assertEqual(state["assets"][card_export.ASSETS[0]]["status"], "unavailable")

    def test_unknown_signature_is_exported_as_original_bytes(self):
        raw = b"unrecognized-card-artwork-bytes"
        with tempfile.TemporaryDirectory() as temp:
            state = {"assets": {}}
            def fake_native(command, _udid, *args):
                if command == "afc-stat":
                    return ok(kind="S_IFREG", size=len(raw))
                if command == "afc-read":
                    Path(args[1]).write_bytes(raw)
                    return ok(size=len(raw))
                return ok()
            with (patch.object(card_export.airlift, "native", side_effect=fake_native),
                  patch.object(card_export.airlift, "run_json", return_value={"ok": True, "exitCode": 0}),
                  patch.object(card_export.airlift, "write_file", return_value=True),
                  patch.object(card_export.airlift, "read_file", return_value=raw)):
                data = card_export._export_one("device", "/var/tmp", card_export.ASSETS[0], Path(temp), state)
            self.assertEqual(data, raw)
            self.assertFalse(state["assets"][card_export.ASSETS[0]]["formatRecognized"])

    def test_localized_resource_uses_its_directory_for_writeback(self):
        name = "zh-Hans.lproj/logo@3x.png"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = {"assets": {}}
            probes = 0
            def fake_native(command, _udid, *args):
                nonlocal probes
                if command == "afc-stat":
                    probes += 1
                    return (ok(kind="S_IFREG", size=len(PNG)) if probes == 1 else
                            {"exitCode": 1, "operation": {"ok": False}})
                if command == "afc-read":
                    Path(args[1]).write_bytes(PNG)
                    return ok(size=len(PNG))
                return ok()
            with (patch.object(card_export.airlift, "native", side_effect=fake_native),
                  patch.object(card_export.airlift, "run_json", return_value={"ok": True, "exitCode": 0}),
                  patch.object(card_export.airlift, "write_file", return_value=True) as write,
                  patch.object(card_export.airlift, "read_file", return_value=PNG) as read):
                self.assertEqual(card_export._export_one("device", "/var/tmp", name, root, state), PNG)
            write.assert_called_once_with("device", "/var/tmp/zh-Hans.lproj", "logo@3x.png", PNG)
            read.assert_called_once_with("device", "/var/tmp/zh-Hans.lproj", "logo@3x.png")
            self.assertEqual((root / name).read_bytes(), PNG)

    def test_mac_backup_is_retained_when_device_staging_copy_disappears(self):
        with tempfile.TemporaryDirectory() as temp:
            state = {"assets": {}}
            probes = 0
            def fake_native(command, _udid, *args):
                nonlocal probes
                if command == "afc-stat":
                    probes += 1
                    return (ok(kind="S_IFREG", size=len(PNG)) if probes == 1 else
                            {"exitCode": 1, "operation": {"ok": False}})
                if command == "afc-read":
                    Path(args[1]).write_bytes(PNG)
                    return ok(size=len(PNG))
                return ok()
            with (patch.object(card_export.airlift, "native", side_effect=fake_native),
                  patch.object(card_export.airlift, "run_json", return_value={"ok": True, "exitCode": 0}),
                  patch.object(card_export.airlift, "write_file", return_value=True),
                  patch.object(card_export.airlift, "read_file", return_value=PNG)):
                data = card_export._export_one("device", "/var/tmp", card_export.ASSETS[0], Path(temp), state)
            self.assertEqual(data, PNG)
            item = state["assets"][card_export.ASSETS[0]]
            self.assertEqual(item["status"], "exported-with-mac-recovery")
            self.assertFalse(item["deviceOriginalRetained"])
            self.assertTrue(item["booksRestored"])
            self.assertEqual((Path(temp) / card_export.ASSETS[0]).read_bytes(), PNG)

    def test_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                card_export.export_card("device", "../bad", Path(temp) / "x.zip")


if __name__ == "__main__":
    unittest.main()
