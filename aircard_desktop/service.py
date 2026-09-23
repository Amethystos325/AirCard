"""Versioned JSON-lines protocol. Diagnostics never enter stdout."""
import asyncio
import json
import os
import plistlib
import sys
from collections import OrderedDict

from aircard import CARD_REGEXES
from windows_probe import select_device, trace_frame, trace_text
from .engine import Engine
from .transport import device_info
from .worker import CARD


class Server:
    def __init__(self, output, engine=None):
        self.output = output
        self.engine = engine or Engine(emit=self.event)
        self.engine.emit = self.event
        self.completed = OrderedDict()
        self.requests = set()
        self.scan_task = None
        self.scan_stopping = False
        self.closing = False
        self.tasks = set()

    def event(self, event):
        self.output({"v": 1, **event})

    async def scan(self, device):
        seen = set()
        try:
            async with await select_device(device) as client:
                async with await client.start_lockdown_service("com.apple.os_trace_relay") as service:
                    await service.send_plist({"Request": "StartActivity", "Pid": 0xffffffff, "MessageFilter": 0xffff,
                                              "StreamFlags": 0x3c}, fmt=plistlib.FMT_BINARY)
                    kind, initial = await trace_frame(service)
                    if kind != 1 or plistlib.loads(initial).get("Status") != "RequestSuccessful":
                        raise RuntimeError("TRACE_FAILED")
                    while not self.scan_stopping:
                        kind, packet = await trace_frame(service)
                        text = trace_text(packet) if kind == 2 else None
                        if not text:
                            continue
                        for regex in CARD_REGEXES:
                            for match in regex.finditer(text):
                                if self.scan_stopping:
                                    return
                                card = match.group(1)
                                if not CARD.fullmatch(card):
                                    continue
                                if card in seen:
                                    continue
                                seen.add(card)
                                if self.engine.store.quarantined_card(device, card):
                                    continue
                                self.event({"event": "candidate", "card": card})
                                # Classification uses the same lock and durable restore as reads.
                                try:
                                    if self.engine.lock.locked():
                                        seen.discard(card)
                                        continue
                                    await self.engine.operate(device, card, "classify")
                                except Exception as error:
                                    self.event({"event": "scanError", "code": error_code(error)})
                                    if self.engine.store.pending(device):
                                        self.scan_stopping = True
                                        return
        except asyncio.CancelledError:
            pass
        except Exception as error:
            self.event({"event": "scanError", "code": error_code(error)})
        finally:
            self.event({"event": "scanStopped"})

    async def stop_scan(self):
        self.scan_stopping = True
        task = self.scan_task
        if task and not task.done():
            # Do not interrupt a classification's move/writeback operation.
            if self.engine.active:
                self.engine.cancel_requested = True
                while self.engine.active:
                    await asyncio.sleep(.1)
            task.cancel()
            await task
        self.scan_task = None

    async def dispatch(self, method, p):
        if self.closing and method not in ("hello", "overview", "cancel", "shutdown"):
            raise RuntimeError("CLOSING")
        if method == "hello":
            from .migration import import_legacy
            return {"protocol": 1, "backend": "0.2.0", "legacyCandidates": import_legacy(self.engine.store),
                    "scanning": bool(self.scan_task and not self.scan_task.done()), **self.engine.overview()}
        if method == "overview":
            return {"scanning": bool(self.scan_task and not self.scan_task.done()), **self.engine.overview()}
        if method == "device":
            return await device_info()
        if method == "scan.start":
            if self.scan_task and not self.scan_task.done():
                raise RuntimeError("BUSY")
            if self.engine.lock.locked():
                raise RuntimeError("BUSY")
            self.scan_stopping = False
            self.scan_task = asyncio.create_task(self.scan(p["device"]))
            return {"scanning": True}
        if method == "scan.stop":
            await self.stop_scan()
            return {"scanning": False}
        if method == "image.prepare":
            return await asyncio.to_thread(self.engine.prepare_image, p["path"], p.get("crop"))
        if method == "image.inspect":
            from pathlib import Path
            from .images import inspect
            return await asyncio.to_thread(inspect, Path(p["path"]))
        if method in ("card.read", "card.apply", "card.restore", "card.classify"):
            if self.scan_task and not self.scan_task.done():
                raise RuntimeError("STOP_SCAN_FIRST")
            return await self.engine.operate(p["device"], p["card"], method.split('.')[1], p.get("imageId"))
        if method == "card.export":
            return self.engine.export(p["deviceKey"], p["card"], p["destination"])
        if method == "recovery.resume":
            await self.stop_scan()
            return await self.engine.recover(p["operationId"])
        if method == "cancel":
            self.engine.cancel_requested = True
            return {"requested": True}
        if method == "shutdown":
            self.closing = True
            await self.stop_scan()
            while self.engine.active:
                await asyncio.sleep(.1)
            return {"safeToExit": True}
        raise ValueError("UNKNOWN_METHOD")

    async def handle(self, message):
        request_id = message.get("id") if isinstance(message, dict) else None
        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 80:
            self.output({"v": 1, "id": None, "ok": False, "error": {"code": "INVALID_REQUEST"}})
            return
        if request_id in self.completed:
            self.output(self.completed[request_id])
            return
        if request_id in self.requests:
            return  # The original request supplies the one terminal response.
        self.requests.add(request_id)
        try:
            if message.get("v") != 1 or not isinstance(message.get("params", {}), dict):
                raise ValueError("INVALID_REQUEST")
            result = await self.dispatch(message.get("method"), message.get("params", {}))
            reply = {"v": 1, "id": request_id, "ok": True, "result": result}
        except Exception as error:
            print(json.dumps({"event": "diagnostic", "code": error_code(error), "type": type(error).__name__}),
                  file=sys.stderr, flush=True)
            reply = {"v": 1, "id": request_id, "ok": False, "error": {"code": error_code(error)}}
        finally:
            self.requests.discard(request_id)
        self.completed[request_id] = reply
        if len(self.completed) > 256:
            self.completed.popitem(last=False)
        self.output(reply)


def error_code(error):
    text = str(error)
    if text.startswith("No USB device"):
        return "NO_DEVICE"
    if text.startswith("No supported x64 Store iTunes runtime"):
        return "APPLE_COMPONENTS_MISSING"
    if text and len(text) < 60 and all(c.isupper() or c == '_' for c in text):
        return text
    name = type(error).__name__
    return {"PasswordRequiredError": "DEVICE_LOCKED", "PairingDialogResponsePendingError": "TRUST_REQUIRED",
            "ConnectionFailedToUsbmuxdError": "APPLE_COMPONENTS_MISSING", "NoDeviceConnectedError": "NO_DEVICE",
            "TimeoutError": "TIMEOUT", "FileNotFoundError": "FILE_NOT_FOUND"}.get(name, "OPERATION_FAILED")


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdin.reconfigure(encoding="utf-8")
    def output(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)
    server = Server(output)
    lock = (server.engine.store.root / "backend.lock").open("a+b")
    try:
        if os.name == "nt":
            import msvcrt
            lock.seek(0)
            if not lock.read(1):
                lock.write(b"0"); lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        output({"v": 1, "event": "fatal", "code": "ALREADY_RUNNING"})
        return

    async def serve():
        while True:
            line = await asyncio.to_thread(sys.stdin.readline, 4 * 1024 * 1024)
            if not line:
                break
            try:
                if not line.endswith('\n'):
                    while line and not line.endswith('\n'):
                        line = await asyncio.to_thread(sys.stdin.readline, 4 * 1024 * 1024)
                    raise ValueError()
                message = json.loads(line)
            except ValueError:
                output({"v": 1, "id": None, "ok": False, "error": {"code": "INVALID_JSON"}})
                continue
            task = asyncio.create_task(server.handle(message))
            server.tasks.add(task)
            task.add_done_callback(server.tasks.discard)
        await server.stop_scan()
        if server.tasks:
            await asyncio.gather(*server.tasks)
    try:
        asyncio.run(serve())
    finally:
        lock.close()
