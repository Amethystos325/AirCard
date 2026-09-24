"""Persistent artwork cache and read/export integration tests."""

import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from backend import aircard_backend
from backend import card_cache
from backend import card_export


HASH = "b" * 27 + "="
NAME = "cardBackgroundCombined@2x.png"
DATA = b"original-card-image-bytes"


def recovery_result(root: Path, data: bytes = DATA) -> card_export.ExportResult:
    root.mkdir(exist_ok=True)
    (root / NAME).write_bytes(data)
    (root / "state.json").write_text(json.dumps({
        "cardHash": HASH,
        "assets": {NAME: {"sha256": hashlib.sha256(data).hexdigest()}},
    }))
    return card_export.ExportResult(root, (NAME,), (), ())


class CacheTests(unittest.TestCase):
    def test_cache_preserves_localized_artwork_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            recovery = base / "recovery"
            names = ("logo@3x.png", "zh-Hans.lproj/logo@3x.png")
            for name in names:
                path = recovery / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(DATA)
            (recovery / "state.json").write_text(json.dumps({
                "cardHash": HASH,
                "assets": {name: {"sha256": hashlib.sha256(DATA).hexdigest()}
                           for name in names},
            }))
            result = card_export.ExportResult(recovery, names, (), ())
            cached = card_cache.save_cached_card(HASH, result, base / "cache")
            self.assertEqual(cached["assets"], list(names))
            self.assertEqual(set(cached["files"]), set(names))
            self.assertEqual(Path(cached["files"][names[1]]).read_bytes(), DATA)

    def test_cache_survives_reload_and_detects_tampering(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            cached = card_cache.save_cached_card(
                HASH, recovery_result(base / "recovery"), base / "cache")
            self.assertEqual(cached["assets"], [NAME])
            self.assertEqual(Path(cached["preview"]).read_bytes(), DATA)
            self.assertEqual(card_cache.get_cached_card(HASH, base / "cache"), cached)
            Path(cached["preview"]).write_bytes(b"modified")
            self.assertIsNone(card_cache.get_cached_card(HASH, base / "cache"))

    def test_bad_new_recovery_keeps_previous_published_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            old = card_cache.save_cached_card(
                HASH, recovery_result(base / "old"), base / "cache")
            bad = recovery_result(base / "bad", b"different")
            (bad.recovery / NAME).write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                card_cache.save_cached_card(HASH, bad, base / "cache")
            self.assertEqual(card_cache.get_cached_card(HASH, base / "cache"), old)

    def test_manual_export_publishes_cache_result(self):
        result = card_export.ExportResult(Path("/tmp/recovery"), (NAME,), (), ())
        cached = {"preview": "/tmp/cached.png", "assets": [NAME],
                  "files": {NAME: "/tmp/cached.png"}}
        output = io.StringIO()
        with (patch.object(aircard_backend, "export_card", return_value=result),
              patch.object(aircard_backend, "save_cached_card", return_value=cached),
              contextlib.redirect_stdout(output)):
            self.assertTrue(aircard_backend.cmd_export_card("device", HASH, "/tmp/card.zip"))
        message = json.loads(output.getvalue())
        self.assertEqual(message["message"], "卡面导出成功。")
        self.assertEqual(message["cache"], cached)

    def test_read_command_uses_same_pipeline_without_zip(self):
        result = card_export.ExportResult(Path("/tmp/recovery"), (NAME,), (), ())
        output = io.StringIO()
        with (patch.object(aircard_backend, "export_card", return_value=result) as export,
              patch.object(aircard_backend, "save_cached_card", return_value={"preview": "/tmp/a.png"}),
              contextlib.redirect_stdout(output)):
            self.assertTrue(aircard_backend.cmd_read_card("device", HASH))
        self.assertIsNone(export.call_args.args[2])
        self.assertEqual(json.loads(output.getvalue())["message"], "卡面读取成功。")


if __name__ == "__main__":
    unittest.main()
