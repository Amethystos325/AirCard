"""Versioned JSON-lines protocol. Diagnostics never enter stdout."""
import asyncio
import json
import os
import plistlib
import re
import sys
from collections import OrderedDict
from urllib.parse import unquote

from backend.aircard import CARD_REGEXES
from backend.windows_probe import select_device, trace_frame, trace_text
from .engine import Engine
from .storage import identity, read
from .transport import device_info
from .worker import CARD, SCANNED_CARD

ENCODED_CARD_PATH = re.compile(r"/(?:Cards|Passes/Cards)/([A-Za-z0-9_+=%\-]{20,192})\.(?:pkpass|cache|pkcache)", re.IGNORECASE)


def card_candidates(message):
    lower = message.lower()
    if not any(word in lower for word in ("passd", "passbook", "passkit", "stockholm", "nanopassd", "wallet", "/cards/")):
        return []
    if not any(word in lower for word in ("card", "pass", "payment", "uniqueid", "identifier", "face", "cache", "stockholm")):
        return []
    candidates = []
    for index, regex in enumerate(CARD_REGEXES):
        for match in regex.finditer(message):
            card = match.group(1)
            # A full Wallet resource path is stronger evidence than an isolated
            # hash. Keep the strict padded form for hash-only log messages.
            if (CARD.fullmatch(card) and not card.startswith(("aircard-", "airlift-"))
                    and (index < 2 or SCANNED_CARD.fullmatch(card))):
                candidates.append(card)
    for match in ENCODED_CARD_PATH.finditer(message):
        if "%" in match.group(1):
            card = unquote(match.group(1))
            if CARD.fullmatch(card) and not card.startswith(("aircard-", "airlift-")):
                candidates.append(card)
    return list(dict.fromkeys(candidates))


class Server:
    def __init__(self, output, engine=None):
        self.output = output
        self.engine = engine or Engine(emit=self.event)
        self.engine.emit = self.event
        self.completed = OrderedDict()
        self.requests = set()
        self.scan_task = None
        self.scan_stopping = False
        self.scan_drain = False
        self.scan_ready = None
        self.scan_start_error = None
        self.closing = False
        self.tasks = set()

    def event(self, event):
        self.output({"v": 1, **event})

    async def scan(self, device):
        seen = set()
        attempts = {}
        queue = asyncio.Queue(maxsize=256)
        try:
            async with await select_device(device) as client:
                async with await client.start_lockdown_service("com.apple.os_trace_relay") as service:
                    await service.send_plist({"Request": "StartActivity", "Pid": 0xffffffff, "MessageFilter": 0xffff,
                                              "StreamFlags": 0x3c}, fmt=plistlib.FMT_BINARY)
                    kind, initial = await trace_frame(service)
                    if kind != 1 or plistlib.loads(initial).get("Status") != "RequestSuccessful":
                        raise RuntimeError("TRACE_FAILED")
                    if self.scan_ready:
                        self.scan_ready.set()

                    async def collect():
                        # Keep draining the log while a slow device transfer
                        # classifies an earlier card. Otherwise later card
                        # selections can disappear from the trace stream.
                        while not self.scan_stopping:
                            kind, packet = await trace_frame(service)
                            if self.scan_stopping:
                                break
                            text = trace_text(packet) if kind == 2 else None
                            if not text:
                                continue
                            for card in card_candidates(text):
                                if card in seen or attempts.get(card, 0) >= 2:
                                    continue
                                seen.add(card)
                                try:
                                    queue.put_nowait(card)
                                except asyncio.QueueFull:
                                    seen.discard(card)
                                    self.event({"event": "scanError", "code": "SCAN_BACKLOG"})

                    reader = asyncio.create_task(collect())
                    try:
                        while not self.scan_stopping or (self.scan_drain and not queue.empty()):
                            if reader.done() and queue.empty():
                                await reader
                                break
                            try:
                                card = await asyncio.wait_for(queue.get(), .25)
                            except TimeoutError:
                                continue
                            if self.scan_stopping and not self.scan_drain:
                                break
                            attempts[card] = attempts.get(card, 0) + 1
                            if self.engine.store.quarantined_card(device, card):
                                continue
                            self.event({"event": "candidate", "card": card})
                            stored = read(self.engine.store.card(device, card) / "card.json", {})
                            if (isinstance(stored, dict) and stored.get("card") == card
                                    and stored.get("deviceKey") == identity(device)
                                    and stored.get("kind") in ("secure-element", "ordinary")):
                                continue
                            try:
                                if self.engine.lock.locked():
                                    raise RuntimeError("BUSY")
                                result = await self.engine.operate(device, card, "classify")
                                if result["card"]["kind"] == "unknown" and attempts[card] < 2:
                                    seen.discard(card)
                            except Exception as error:
                                if not self.engine.store.pending(device) and attempts[card] < 2:
                                    seen.discard(card)
                                self.event({"event": "scanError", "code": error_code(error)})
                                if self.engine.store.pending(device):
                                    self.scan_stopping = True
                                    return
                    finally:
                        reader.cancel()
                        try:
                            await reader
                        except asyncio.CancelledError:
                            pass
        except asyncio.CancelledError:
            self.scan_start_error = "CANCELLED"
        except Exception as error:
            self.scan_start_error = error_code(error)
            self.event({"event": "scanError", "code": error_code(error)})
        finally:
            if self.scan_ready:
                self.scan_ready.set()
            self.event({"event": "scanStopped"})

    async def stop_scan(self, drain=False):
        self.scan_drain = drain
        self.scan_stopping = True
        task = self.scan_task
        if task and not task.done():
            if not drain:
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
            return {"scanning": bool(self.scan_task and not self.scan_task.done()),
                    **self.engine.overview(p.get("knownPreviews"))}
        if method == "device":
            return await device_info()
        if method == "scan.start":
            if self.scan_task and not self.scan_task.done():
                raise RuntimeError("BUSY")
            if self.engine.lock.locked():
                raise RuntimeError("BUSY")
            self.scan_stopping = False
            self.scan_drain = False
            self.scan_ready = asyncio.Event()
            self.scan_start_error = None
            self.scan_task = asyncio.create_task(self.scan(p["device"]))
            try:
                await asyncio.wait_for(self.scan_ready.wait(), 15)
            except TimeoutError:
                await self.stop_scan()
                raise RuntimeError("TRACE_FAILED")
            if self.scan_start_error:
                raise RuntimeError(self.scan_start_error)
            if self.scan_task.done():
                raise RuntimeError("TRACE_FAILED")
            return {"scanning": True}
        if method == "scan.stop":
            await self.stop_scan(drain=True)
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
        if method == "recovery.isolate":
            await self.stop_scan()
            return await self.engine.isolate_unresolved(p["operationId"])
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
