"""Restricted AirTraffic worker, also invoked by the frozen backend executable."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

CARD = re.compile(r"[-A-Za-z0-9_+=]{20,64}\Z")
ART = {"cardBackgroundCombined@3x.png", "cardBackgroundCombined@2x.png", "cardBackgroundCombined.pdf"}
CACHE = {"FrontFace", "PlaceHolder", "Preview"}


def target(card, area, leaf):
    if not isinstance(card, str) or not CARD.fullmatch(card):
        raise ValueError("INVALID_CARD")
    allowed = ART | {"pass.json", "manifest.json"} if area == "pkpass" else CACHE
    if area not in ("pkpass", "cache", "pkcache") or leaf not in allowed:
        raise ValueError("INVALID_ASSET")
    return f"/var/mobile/Library/Passes/Cards/{card}.{area}", leaf


def validate(job):
    if job.get("checkSync"):
        if job.get("assets"):
            raise ValueError("INVALID_JOB")
        return
    target(job["card"], job["area"], job["leaf"])
    token = job["token"]
    if not re.fullmatch(r"[0-9a-f]{32}", token):
        raise ValueError("INVALID_JOB")
    source, link, recovered = (f"aircard-probe-{token}-{kind}-0" for kind in ("source", "link", "recovered"))
    expected = [[f"../../{source}/p0/p1/p2/link", link]]
    if job["direction"] == "push":
        expected.append([f"../../{source}/payload", link + "/" + job["leaf"]])
    elif job["direction"] == "pull":
        expected.append([f"../../{link}/{job['leaf']}", recovered])
    else:
        raise ValueError("INVALID_JOB")
    if job["assets"] != expected:
        raise ValueError("INVALID_JOB")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("job", type=Path)
    args = parser.parse_args(argv)
    try:
        job = json.loads(args.job.read_text("utf-8"))
        validate(job)
        print(json.dumps({"event": "worker", "stage": "validated"}), flush=True)
        if sys.platform == "win32":
            from windows_airtraffic import AirTraffic
            from windows_apple_runtime import CoreFPRegistration
            runtime = Path(job["runtime"])
            print(json.dumps({"event": "worker", "stage": "loadingLibraries"}), flush=True)
            native = AirTraffic(runtime)
            print(json.dumps({"event": "worker", "stage": "registeringCoreFP"}), flush=True)
            with CoreFPRegistration(runtime, native.at):
                print(json.dumps({"event": "worker", "stage": "connecting"}), flush=True)
                result = native.run(job["udid"], job.get("assets"), check_sync=job.get("checkSync", False))
        else:
            if job.get("checkSync"):
                # The existing macOS helper checks readiness before every transfer.
                result = {"ok": True, "deferredToTransfer": True}
            else:
                binary = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1])) / "bin" / "airtraffic_host"
                if not binary.is_file():
                    binary = Path(__file__).resolve().parents[1] / "build" / "airtraffic_host"
                proc = subprocess.run([str(binary), job["udid"], *[v for pair in job["assets"] for v in pair]],
                                      stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=40)
                result = next((json.loads(line) for line in reversed(proc.stdout.splitlines()) if line.startswith('{')), {})
                result["ok"] = bool(result.get("ok") and proc.returncode == 0)
    except Exception as error:
        result = {"ok": False, "error": type(error).__name__}
    print(json.dumps(result), flush=True)
    return 0 if result.get("ok") else 2
