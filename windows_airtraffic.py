"""Isolated ctypes worker for Apple's installed Windows AirTrafficHost DLL.

The parent enforces a process timeout: native reads can block indefinitely.
Apple binaries are not distributed with this project.
"""
from __future__ import annotations

import argparse
import ctypes as C
import json
import os
import plistlib
import re
import time
import uuid
from pathlib import Path


def validate_canary_assets(assets):
    if not isinstance(assets, list) or not 1 <= len(assets) <= 4:
        raise ValueError("Only a small generated canary asset list is supported")
    token = None
    for pair in assets:
        if not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(v, str) for v in pair):
            raise ValueError("Invalid canary asset pair")
        source, destination = pair
        match = re.fullmatch(r"aircard-probe-([0-9a-f]{32})-(link|recovered)-([0-3])(?:/(.+))?", destination)
        if not match:
            raise ValueError("Only generated probe destinations are supported")
        current, kind, index, leaf = match.groups()
        if token is not None and token != current:
            raise ValueError("Cannot mix canary runs")
        token = current
        base = f"../../aircard-probe-{token}-source-{index}"
        if kind == "link" and leaf is None:
            valid = source == base + "/p0/p1/p2/link"
        elif kind == "link" and leaf == f"aircard-probe-{token}.bin":
            valid = source == base + "/payload"
        else:
            valid = kind == "recovered" and leaf is None and source in (
                f"../../../../tmp/aircard-probe-{token}.bin",
                f"../../../../tmp/./aircard-probe-{token}.bin")
        if not valid:
            raise ValueError("Only the generated /var/tmp canary may be transferred")


class AirTraffic:
    def __init__(self, runtime: Path):
        self.search = os.add_dll_directory(str(runtime.resolve()))
        # Native AirTraffic code loads CoreFP dynamically with LoadLibrary.
        # ctypes' own secure search flags do not propagate to those nested loads.
        kernel = C.WinDLL("kernel32", use_last_error=True)
        default_search = self.bind(kernel, "SetDefaultDllDirectories", C.c_bool, [C.c_uint32])
        if not default_search(0x1000):  # LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
            raise C.WinError(C.get_last_error())
        self.cf = C.CDLL(str(runtime / "CoreFoundation.dll"))
        self.at = C.CDLL(str(runtime / "AirTrafficHost.dll"))
        p = C.c_void_p
        n = C.c_ssize_t
        self.release = self.bind(self.cf, "CFRelease", None, [p])
        self.string_create = self.bind(self.cf, "CFStringCreateWithCString", p, [p, C.c_char_p, C.c_uint32])
        self.string_get = self.bind(self.cf, "CFStringGetCString", C.c_bool, [p, p, n, C.c_uint32])
        self.data_create = self.bind(self.cf, "CFDataCreate", p, [p, p, n])
        self.data_size = self.bind(self.cf, "CFDataGetLength", n, [p])
        self.data_bytes = self.bind(self.cf, "CFDataGetBytePtr", p, [p])
        self.plist_create = self.bind(self.cf, "CFPropertyListCreateWithData", p, [p, p, C.c_uint64, p, p])
        self.plist_data = self.bind(self.cf, "CFPropertyListCreateData", p, [p, p, n, C.c_uint64, p])
        self.connect = self.bind(self.at, "ATHostConnectionCreate", p, [p])
        self.disconnect = self.bind(self.at, "ATHostConnectionRelease", None, [p])
        self.read = self.bind(self.at, "ATHostConnectionReadMessage", p, [p])
        self.message_name = self.bind(self.at, "ATCFMessageGetName", p, [p])
        self.message_param = self.bind(self.at, "ATCFMessageGetParam", p, [p, p])
        self.host_info = self.bind(self.at, "ATHostConnectionSendHostInfo", None, [p, p])
        self.sync_request = self.bind(self.at, "ATHostConnectionSendSyncRequest", None, [p, p, p, p])
        self.metadata_finished = self.bind(self.at, "ATHostConnectionSendMetadataSyncFinished", None, [p, p, p])
        self.asset_completed = self.bind(self.at, "ATHostConnectionSendAssetCompleted", None, [p, p, p, p])
        self.grappa_session = self.bind(self.at, "ATHostConnectionGetGrappaSessionId", C.c_uint32, [p])

    @staticmethod
    def bind(lib, name, result, args):
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = args
        return function

    def string(self, value: str):
        result = self.string_create(None, value.encode("utf-8"), 0x08000100)
        if not result:
            raise RuntimeError("CFString creation failed")
        return result

    def text(self, value) -> str:
        if not value:
            return ""
        buf = C.create_string_buffer(4096)
        if not self.string_get(value, buf, len(buf), 0x08000100):
            raise RuntimeError("CFString conversion failed")
        return buf.value.decode("utf-8")

    def plist(self, value):
        encoded = plistlib.dumps(value, fmt=plistlib.FMT_BINARY)
        data = self.data_create(None, encoded, len(encoded))
        if not data:
            raise RuntimeError("CFData creation failed")
        try:
            result = self.plist_create(None, data, 0, None, None)
            if not result:
                raise RuntimeError("CFPropertyList conversion failed")
            return result
        finally:
            self.release(data)

    def value(self, value):
        if not value:
            return None
        data = self.plist_data(None, value, 200, 0, None)
        if not data:
            raise RuntimeError("CFPropertyList serialization failed")
        try:
            size = self.data_size(data)
            if not 0 < size <= 16 * 1024 * 1024:
                raise RuntimeError("Invalid native plist size")
            return plistlib.loads(C.string_at(self.data_bytes(data), size))
        finally:
            self.release(data)

    def wait(self, connection, expected: str, limit: int = 24):
        for _ in range(limit):
            message = self.read(connection)
            if not message:
                time.sleep(0.1)
                continue
            try:
                name = self.text(self.message_name(message))
                print(json.dumps({"event": "message", "name": name}), flush=True)
                if name == expected:
                    if expected == "AssetManifest":
                        key = self.string("AssetManifest")
                        try:
                            return self.value(self.message_param(message, key))
                        finally:
                            self.release(key)
                    return True
                if name in ("SyncFailed", "SyncFinished"):
                    detail = self.value(message)
                    raise RuntimeError("Sync ended before " + expected + ": " + str(detail))
            finally:
                self.release(message)
        raise RuntimeError(expected + " not observed")

    def run(self, udid: str, assets: list | None, check_sync: bool = False):
        identifier = self.string(udid)
        try:
            connection = self.connect(identifier)
        finally:
            self.release(identifier)
        if not connection:
            raise RuntimeError("AirTraffic connection failed")
        try:
            self.wait(connection, "SyncAllowed")
            if assets is None and not check_sync:
                return {"ok": True, "syncAllowed": True, "grappaSessionEstablished": bool(self.grappa_session(connection)),
                        "fileTransferVerified": False}
            host = self.plist({"Type": "iTunes", "Version": "13.7.0.161",
                               "MacOSVersion": "Windows AirCard prototype", "SyncHostName": "AirCard",
                               "LibraryID": str(uuid.uuid4()), "SyncedDataclasses": ["Book"],
                               "SyncedAssetTypes": ["Book"], "Wakeable": False})
            classes = self.plist(["Book"])
            anchors = self.plist({})
            sync_types = self.plist({"Book": 1})
            try:
                self.host_info(connection, host)
                time.sleep(0.2)
                self.sync_request(connection, classes, anchors, host)
                self.wait(connection, "ReadyForSync")
                if check_sync:
                    return {"ok": True, "syncAllowed": True, "readyForSync": True,
                            "grappaSessionEstablished": bool(self.grappa_session(connection)),
                            "fileTransferVerified": False}
                self.metadata_finished(connection, sync_types, anchors)
                manifest = self.wait(connection, "AssetManifest")
                listed = {entry.get("AssetID") for entry in (manifest or {}).get("Book", [])
                          if isinstance(entry, dict) and entry.get("IsDownload")}
                if any(identifier not in listed for identifier, _ in assets):
                    raise RuntimeError("Expected test assets absent from manifest")
                for index, (identifier, destination) in enumerate(assets):
                    values = [self.string(identifier), self.string("Book"), self.string(destination)]
                    try:
                        self.asset_completed(connection, *values)
                    finally:
                        for value in values:
                            self.release(value)
                    time.sleep(0.4 if index == 0 else 0.06)
                time.sleep(2)
                return {"ok": True, "syncAllowed": True, "readyForSync": True,
                        "assetCount": len(assets), "fileTransferVerified": False}
            finally:
                for value in (host, classes, anchors, sync_types):
                    self.release(value)
        finally:
            self.disconnect(connection)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--check-sync", action="store_true", help="Request readiness only; no metadata completion or file transfers")
    args = parser.parse_args()
    assets = None
    if args.assets:
        assets = json.loads(args.assets.read_text(encoding="utf-8"))
        validate_canary_assets(assets)
    try:
        from windows_apple_runtime import CoreFPRegistration

        runtime = args.runtime.resolve()
        native = AirTraffic(runtime)
        with CoreFPRegistration(runtime, native.at):
            result = native.run(args.udid, assets, check_sync=args.check_sync)
        result["coreFPRegistration"] = "process_private_hive"
    except Exception as error:
        result = {"ok": False, "error": type(error).__name__ + ": " + str(error)}
    print(json.dumps(result), flush=True)
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
