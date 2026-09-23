"""Windows feasibility probe. Never writes Wallet files.

afc-canary uses a generated Media file. airlift-canary additionally snapshots
Books inputs and, only after sync readiness succeeds, tests a /var/tmp file.

Device tests require the optional requirements-windows-prototype.txt environment.
Use run_windows_probe.ps1 for setup and bounded execution.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import os
import platform
import plistlib
import re
import secrets
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MAX_FRAME = 16 * 1024 * 1024
ATC_EXPORTS = (
    "ATHostConnectionCreate", "ATHostConnectionReadMessage",
    "ATHostConnectionSendHostInfo", "ATHostConnectionSendSyncRequest",
    "ATHostConnectionSendMetadataSyncFinished", "ATHostConnectionSendAssetCompleted",
    "ATCFMessageGetName", "ATCFMessageGetParam",
)
DLL_NAMES = {"airtraffichost.dll", "mobiledevice.dll", "itunesmobiledevice.dll", "corefoundation.dll"}
CANARY_DIRECTORY = re.compile(r"aircard-probe-[0-9a-f]{32}\Z")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_report(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + ".pending")
    with pending.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(pending, path)


def powershell_json(script: str) -> dict:
    executable = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    result = subprocess.run(
        [str(executable), "-NoProfile", "-NonInteractive", "-Command",
         "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); " + script],
        stdin=subprocess.DEVNULL, capture_output=True, encoding="utf-8", timeout=35,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Windows inventory failed")
    return json.loads(result.stdout.lstrip("\ufeff"))


def inventory() -> dict:
    if sys.platform != "win32":
        return {"status": "unsupported", "reason": "Windows is required"}
    # Only Apple installation roots and USB status are read. No registry writes.
    result = powershell_json(r"""
        $ErrorActionPreference = 'Stop'
        $packages = @(Get-AppxPackage | Where-Object { $_.Name -match 'Apple|iTunes' })
        $roots = @($packages | ForEach-Object { $_.InstallLocation })
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($base) {
                $roots += Join-Path $base 'Common Files\Apple'
                $roots += Join-Path $base 'iTunes'
            }
        }
        foreach ($key in @('HKLM:\SOFTWARE\Apple Inc.',
                          'HKLM:\SOFTWARE\WOW6432Node\Apple Inc.',
                          'HKLM:\SOFTWARE\Apple Computer, Inc.')) {
            if (Test-Path -LiteralPath $key) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $key -Recurse)) {
                    $props = Get-ItemProperty -LiteralPath $entry.PSPath
                    foreach ($name in @('InstallDir','InstallPath')) {
                        if ($props.PSObject.Properties.Name -contains $name) {
                            $roots += $props.$name
                        }
                    }
                }
            }
        }
        $services = @(Get-Service | Where-Object { $_.Name -match 'Apple|Bonjour' } |
            Select-Object Name,@{n='Status';e={$_.Status.ToString()}})
        $usb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match 'VID_05AC' } |
            Select-Object Status,Class,FriendlyName)
        @{roots=@($roots | Where-Object { $_ } | Select-Object -Unique);
          packages=@($packages | Select-Object Name,Version);
          services=$services; usb=$usb} | ConvertTo-Json -Depth 5 -Compress
    """)
    result["status"] = "observed"
    return result


def inspect_dll(path: Path) -> dict:
    import pefile

    with pefile.PE(str(path), fast_load=True) as pe:
        pe.parse_data_directories(directories=[
            pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"],
            pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"],
        ])
        exports = sorted(s.name.decode("ascii", "replace") for s in
                         getattr(getattr(pe, "DIRECTORY_ENTRY_EXPORT", None), "symbols", []) if s.name)
        machine = {0x8664: "AMD64", 0x14C: "x86", 0xAA64: "ARM64"}.get(pe.FILE_HEADER.Machine, "unknown")
        result = {"path": str(path), "machine": machine, "sha256": digest(path.read_bytes()),
                  "imports": [entry.dll.decode("ascii", "replace") for entry in
                              getattr(pe, "DIRECTORY_ENTRY_IMPORT", [])]}
        if path.name.lower() == "airtraffichost.dll":
            result["airtrafficExports"] = [name for name in exports if name.startswith(("ATHostConnection", "ATCFMessage"))]
            result["missingMacEquivalentExports"] = sorted(set(ATC_EXPORTS) - set(exports))
            result["releaseExports"] = [name for name in exports if name in
                                        ("ATHostConnectionRelease", "ATHostConnectionDestroy")]
        return result


def doctor(extra_roots: list[str]) -> dict:
    result = {"python": platform.python_version(), "platform": platform.platform(),
              "machine": platform.machine(), "pointerBits": struct.calcsize("P") * 8}
    result["dependencies"] = {}
    for name in ("pymobiledevice3", "pefile"):
        try:
            result["dependencies"][name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            result["dependencies"][name] = None
    result["windows"] = inventory()
    paths = set()
    for root in [*result["windows"].get("roots", []), *extra_roots]:
        path = Path(root)
        if path.is_file() and path.name.lower() in DLL_NAMES:
            paths.add(path.resolve())
        elif path.is_dir():
            for folder, _, files in os.walk(path):
                paths.update((Path(folder) / name).resolve() for name in files if name.lower() in DLL_NAMES)
    result["dlls"] = []
    for path in sorted(paths):
        try:
            result["dlls"].append(inspect_dll(path))
        except Exception as error:
            result["dlls"].append({"path": str(path), "error": type(error).__name__ + ": " + str(error)})
    # Export existence alone does not establish ABI or a working connection.
    result["airtrafficVerified"] = False
    return result


def prepare_apple_runtime(cache_root: Path | None = None) -> Path:
    """Copy installed Store DLLs to a local probe directory (no redistribution).

    Windows denied LoadLibrary directly under WindowsApps in the tested setup.
    Load a private copy of the same installed binaries and their dependencies.
    """
    for root in inventory().get("roots", []):
        source = Path(root)
        cf = source / "CoreFoundation.dll"
        at = source / "AMDS64" / "AirTrafficHost.dll"
        md = source / "AMDS64" / "MobileDevice.dll"
        if not all(path.is_file() for path in (cf, at, md)):
            continue
        if any(inspect_dll(path)["machine"] != "AMD64" for path in (cf, at, md)):
            continue
        if platform.machine().upper() not in ("AMD64", "X86_64"):
            raise RuntimeError("This native prototype requires x64 Python")
        libraries = sorted([*source.glob("*.dll"), *(source / "AMDS64").glob("*.dll")])
        identity = digest("".join(digest(path.read_bytes()) for path in libraries).encode())[:16]
        destination = (cache_root or ROOT / ".tmp" / "apple-runtime") / identity
        destination.mkdir(parents=True, exist_ok=True)
        for folder in (source, source / "AMDS64"):
            for path in folder.glob("*.dll"):
                target = destination / path.name
                if not target.is_file() or digest(target.read_bytes()) != digest(path.read_bytes()):
                    shutil.copy2(path, target)
        return destination
    raise RuntimeError("No supported x64 Store iTunes runtime found. Install iTunes or specify --apple-runtime.")


async def native_airtraffic(runtime: Path, udid: str, assets: Path | None = None, *, check_sync: bool = False) -> dict:
    command = [sys.executable, str(ROOT / "windows_airtraffic.py"),
               "--runtime", str(runtime), "--udid", udid]
    if assets is not None:
        command.extend(["--assets", str(assets)])
    if check_sync:
        command.append("--check-sync")
    process = await asyncio.create_subprocess_exec(
        *command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), 40)
    except BaseException:
        if process.returncode is None:
            process.kill()
        await process.wait()
        raise
    records = []
    for line in stdout.decode("utf-8", "replace").splitlines():
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    result = next((row for row in reversed(records) if "ok" in row), {})
    result["messages"] = [row["name"] for row in records if row.get("event") == "message"]
    result["exitCode"] = process.returncode
    if assets is not None:
        write_report(assets.with_suffix(".native.json"), result)
    if process.returncode or not result.get("ok"):
        error = RuntimeError("AirTraffic worker failed: " + result.get("error", f"exit {process.returncode}"))
        error.native_result = result
        raise error
    return result


async def select_device(udid: str | None):
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux

    configure_usbmux_client()
    devices = [d for d in await asyncio.wait_for(usbmux.list_devices(), 10) if d.is_usb]
    if udid:
        devices = [d for d in devices if d.matches_udid(udid)]
    if not devices:
        raise RuntimeError("No USB device. Install/open iTunes, connect and unlock the iPhone, then trust this PC.")
    if len(devices) != 1:
        raise RuntimeError("Multiple USB devices: specify --udid to choose the test device.")
    client = await asyncio.wait_for(create_using_usbmux(
        serial=devices[0].serial, connection_type="USB", pair_timeout=20,
        label="AirCard Windows prototype",
    ), 25)
    if not client.product_type.startswith("iPhone"):
        await client.close()
        raise RuntimeError("Selected device is not an iPhone")
    return client


def configure_usbmux_client() -> None:
    """Identify this application to Apple's Windows usbmux service.

    On the tested Store iTunes build, Connect with the upstream qt4i-usbmuxd /
    pymobiledevice3 labels timed out; the identical request with AirCard labels
    completed. Keep this version-pinned workaround inside this probe process.
    """
    from pymobiledevice3 import usbmux

    if importlib.metadata.version("pymobiledevice3") != "11.17.0":
        raise RuntimeError("The prototype transport adapter requires pymobiledevice3 11.17.0")

    async def send(self, data):
        request = {"ClientVersionString": "AirCard Windows prototype",
                   "ProgName": "AirCard", "kLibUSBMuxVersion": 3}
        request.update(data)
        await usbmux.BinaryMuxConnection._send(self, {
            "header": {"version": self._version, "message": usbmux.usbmuxd_msgtype.PLIST, "tag": self._tag},
            "data": plistlib.dumps(request),
        })

    usbmux.PlistMuxConnection._send = send


async def trace_frame(service) -> tuple[int, bytes]:
    header = await service.recvall(5)
    kind = header[0]
    if kind not in (1, 2):
        raise ValueError("Unsupported unified-log frame type")
    size = int.from_bytes(header[1:], "big" if kind == 1 else "little")
    if not 0 < size <= MAX_FRAME:
        raise ValueError("Invalid unified-log frame length")
    return kind, await service.recvall(size)


def trace_text(data: bytes) -> str | None:
    # Same bounds and offsets as Sources/os_trace.h; multiline messages survive.
    if len(data) < 129 or data[0] != 2:
        return None
    header = struct.unpack_from("<I", data, 5)[0]
    process = struct.unpack_from("<H", data, 37)[0]
    image = struct.unpack_from("<H", data, 107)[0]
    message = struct.unpack_from("<I", data, 109)[0]
    if header < 129 or header > len(data) or not process or not message:
        return None
    if process + image + message > len(data) - header:
        return None
    return data[header:header + process + image + message].replace(b"\0", b" ").decode("utf-8", "replace")


async def trace_probe(client, seconds: int) -> dict:
    from aircard import CARD_REGEXES

    result = {"service": "com.apple.os_trace_relay", "streamStarted": False,
              "records": 0, "walletRecords": 0, "candidateCount": 0,
              "classificationVerified": False}
    candidates = set()
    async with await client.start_lockdown_service(result["service"]) as service:
        await service.send_plist({"Request": "StartActivity", "Pid": 0xFFFFFFFF,
                                  "MessageFilter": 0xFFFF, "StreamFlags": 0x3C}, fmt=plistlib.FMT_BINARY)
        kind, payload = await asyncio.wait_for(trace_frame(service), 10)
        if kind != 1 or plistlib.loads(payload).get("Status") != "RequestSuccessful":
            raise RuntimeError("Device refused the unified log stream")
        result["streamStarted"] = True
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                kind, payload = await asyncio.wait_for(trace_frame(service), max(0.01, deadline - time.monotonic()))
            except TimeoutError:
                break
            if kind != 2:
                continue
            text = trace_text(payload)
            if text is None:
                continue
            result["records"] += 1
            if not any(word in text.lower() for word in ("passd", "passkit", "passbook", "wallet", "stockholm", "/cards/")):
                continue
            result["walletRecords"] += 1
            for regex in CARD_REGEXES:
                candidates.update(match.group(1) for match in regex.finditer(text))
    # Neither raw logs nor pass identifiers are saved in reports.
    result["candidateCount"] = len(candidates)
    result["status"] = "passed"
    return result


async def afc_canary(afc, journal: Path, token: str | None = None) -> dict:
    directory = "aircard-probe-" + (token or secrets.token_hex(16))
    if not CANARY_DIRECTORY.fullmatch(directory):
        raise ValueError("Invalid canary directory")
    remote = directory + "/canary.bin"
    original = b"AirCard Windows AFC canary\n" + secrets.token_bytes(128)
    replacement = b"AirCard Windows AFC replacement\n" + secrets.token_bytes(128)
    state = {"directory": directory, "scope": "/var/mobile/Media only",
             "originalSHA256": digest(original), "replacementSHA256": digest(replacement),
             "status": "pending", "airtrafficVerified": False}

    def checkpoint(stage: str):
        state["stage"] = stage
        write_report(journal, state)

    async def checked_read(expected: bytes):
        info = await afc.stat(remote)
        if info.get("st_ifmt") != "S_IFREG" or int(info.get("st_size", -1)) != len(expected):
            raise RuntimeError("Canary type/size changed; retaining test directory")
        data = await afc.get_file_contents(remote)
        if data != expected:
            raise RuntimeError("Canary content mismatch; retaining test directory")

    checkpoint("checking_fresh_path")
    try:
        if await afc.exists(directory):
            raise RuntimeError("Canary directory already exists; refusing to reuse it")
        checkpoint("creating_directory")
        await afc.makedirs(directory)
        if (await afc.stat(directory)).get("st_ifmt") != "S_IFDIR":
            raise RuntimeError("Canary directory is not a real directory")
        checkpoint("writing_original")
        await afc.set_file_contents(remote, original)
        await checked_read(original)
        checkpoint("writing_replacement")
        await afc.set_file_contents(remote, replacement)
        await checked_read(replacement)
        checkpoint("restoring_original")
        await afc.set_file_contents(remote, original)
        await checked_read(original)
        checkpoint("removing_verified_test_file")
        await afc.rm_single(remote)  # Never recursively delete device directories.
        await afc.rm_single(directory)
        if await afc.exists(directory):
            raise RuntimeError("Canary directory remained after cleanup")
        state["status"] = "passed"
        checkpoint("cleaned")
    except BaseException as error:
        state["status"] = "failed"
        state["error"] = type(error).__name__ + ": " + str(error)
        state["recoveryNote"] = "Only a generated test directory may remain. No Wallet/Books files were touched."
        write_report(journal, state)
        raise
    return state


async def atc_listen(client) -> dict:
    """Observe the service's initial wire header without sending sync requests.

    Do not guess the proprietary message framing or treat service availability
    as proof of SyncAllowed/ReadyForSync or protected-file read/write support.
    """
    result = {"service": "com.apple.atc", "syncVerified": False}
    async with await client.start_lockdown_service(result["service"]) as service:
        result["serviceOpened"] = True
        try:
            header = await asyncio.wait_for(service.recvall(4), 8)
            result["initialHeaderHex"] = header.hex()
            result["status"] = "observed"
            result["nextStep"] = "Validate AirTraffic framing/Windows DLL ABI before sending sync messages."
        except TimeoutError:
            result["status"] = "inconclusive"
            result["reason"] = "No initial bytes before timeout; the service may require host initialization."
    return result


async def device_probe(args) -> dict:
    from pymobiledevice3.services.afc import AfcService

    async with await select_device(args.udid) as client:
        result = {"device": {"product": client.product_type, "version": client.product_version,
                             "paired": client.paired}, "airtrafficVerified": False}
        if args.command == "device":
            result["status"] = "passed"
        elif args.command == "trace":
            result["trace"] = await trace_probe(client, args.seconds)
        elif args.command == "atc-listen":
            result["atc"] = await atc_listen(client)
        elif args.command in ("atc-handshake", "atc-sync-check"):
            runtime = args.apple_runtime or prepare_apple_runtime()
            result["atc"] = await native_airtraffic(runtime, client.udid, check_sync=args.command == "atc-sync-check")
        elif args.command == "airlift-canary":
            from windows_canary import protected_canary
            runtime = args.apple_runtime or prepare_apple_runtime()
            async with AfcService(client) as afc:
                result["canary"] = await protected_canary(client, afc, runtime, args.report)
                result["airtrafficVerified"] = result["canary"]["status"] == "passed"
        elif args.command == "afc-canary":
            async with AfcService(client) as afc:
                result["afc"] = await afc_canary(afc, args.report.with_suffix(".canary.json"))
        elif args.command == "services":
            result["services"] = []
            for name in ("com.apple.afc", "com.apple.os_trace_relay",
                         "com.apple.streaming_zip_conduit", "com.apple.atc"):
                try:
                    async with await asyncio.wait_for(client.start_lockdown_service(name), 10):
                        result["services"].append({"name": name, "status": "opened"})
                except Exception as error:
                    result["services"].append({"name": name, "status": "failed", "error": type(error).__name__})
            result["status"] = "passed" if all(item["status"] == "opened" for item in result["services"]) else "failed"
        return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("doctor", "device", "services", "trace", "afc-canary", "atc-listen", "atc-handshake", "atc-sync-check", "airlift-canary"))
    parser.add_argument("--udid", help="Required when multiple USB devices are attached; omitted from reports")
    parser.add_argument("--dll-dir", action="append", default=[], help="Additional Apple installation directory to inspect")
    parser.add_argument("--seconds", type=int, default=15, help="Trace observation window, 1-30 seconds")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--apple-runtime", type=Path, help="Directory containing loadable x64 Apple DLLs; default: copy installed Store components")
    args = parser.parse_args(argv)
    if not 1 <= args.seconds <= 30:
        parser.error("--seconds must be between 1 and 30")
    if args.report is None:
        args.report = ROOT / "build" / "windows-probe" / f"{args.command}-{time.time_ns()}.json"
    report = {"command": args.command, "airtrafficVerified": False, "walletWriteVerified": False}
    try:
        if sys.platform != "win32":
            raise RuntimeError("Run this prototype on Windows")
        if args.command == "doctor":
            report["result"] = doctor(args.dll_dir)
        else:
            # Overall bound includes connection setup; partial canary state is durable.
            report["result"] = asyncio.run(asyncio.wait_for(device_probe(args), 240 if args.command == "airlift-canary" else 65))
            report["airtrafficVerified"] = report["result"].get("airtrafficVerified", False)
        status = report["result"].get("status")
        if args.command == "atc-listen":
            report["status"] = "inconclusive"
        elif args.command == "doctor":
            report["status"] = "observed"
        else:
            report["status"] = "failed" if status == "failed" else "passed"
    except KeyboardInterrupt:
        report["status"] = "interrupted"
    except Exception as error:
        report["status"] = "blocked"
        report["errorType"] = type(error).__name__
        # Exception text can contain a device serial; avoid putting it in the report.
        report["nextStep"] = {
            "ConnectionFailedToUsbmuxdError": "Install/open iTunes and ensure Apple Mobile Device Service is running.",
            "PairingDialogResponsePendingError": "Unlock the iPhone and accept Trust This Computer.",
            "PasswordRequiredError": "Unlock the iPhone and retry.",
            "ModuleNotFoundError": "Run run_windows_probe.ps1 -Setup with Python 3.12.",
            "TimeoutError": "Operation timed out. Check the canary journal, reconnect/unlock the iPhone, and retry.",
        }.get(type(error).__name__, "Check Apple components, unlock/trust the iPhone, and inspect the canary journal if present.")
        if isinstance(error, RuntimeError):
            report["reason"] = str(error)
        if hasattr(error, "native_result"):
            report["native"] = error.native_result
            report["nextStep"] = "Inspect the AirTraffic failure and Grappa session setup; SyncAllowed alone does not prove sync readiness."
        if hasattr(error, "canary_result"):
            report["result"] = {"canary": error.canary_result}
            report["status"] = error.canary_result["status"]
            report["nextStep"] = "Inspect the recorded recovery state before another canary run; preserve its Books backup."
    write_report(args.report, report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Report: {args.report}", file=sys.stderr)
    return 0 if report["status"] in ("passed", "observed") else 2


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
