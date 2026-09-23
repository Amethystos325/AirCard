#!/usr/bin/env python3
"""
Backend engine for AirCard native macOS GUI app.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# Augment PATH so bundled tools and system tools are always found
script_dir = Path(__file__).resolve().parent
bundled_bin = script_dir / "bin"
bundled_lib = script_dir / "lib"
app_bin = Path("/Applications/DittoCard.app/Contents/Resources/bin")
app_lib = Path("/Applications/DittoCard.app/Contents/Resources/lib")

paths_to_add = [
    str(bundled_bin),
    str(app_bin),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
]
for p in reversed(paths_to_add):
    if os.path.isdir(p) and p not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{p}:{os.environ.get('PATH', '')}"

lib_paths = [str(bundled_lib), str(app_lib)]
for lp in lib_paths:
    if os.path.isdir(lp):
        cur_dyld = os.environ.get("DYLD_LIBRARY_PATH", "")
        os.environ["DYLD_LIBRARY_PATH"] = f"{lp}:{cur_dyld}" if cur_dyld else lp

from apply_card_skin import (
    native,
    operation_ok,
    write_file,
    write_files_batch,
    remove_files,
)
from card_assets import CACHE_FILES, build_card_assets
from card_export import classify_card, export_card
from card_cache import get_cached_card, save_cached_card
from aircard import (
    find_device_helper,
    get_connected_device,
    load_saved_cards,
    save_cards,
)


def cmd_device():
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing"}))
        return
    device = get_connected_device()
    if not device:
        print(json.dumps({"connected": False, "error": "no_device"}))
        return
    probe = native("probe", device["udid"])
    device["airlift_compatible"] = operation_ok(probe)
    device["connected"] = True
    print(json.dumps(device))


def cmd_get_saved_cards():
    cards = load_saved_cards()
    print(json.dumps({"ok": True, "cards": cards}))


def cmd_save_cards(cards_json: str):
    try:
        cards = json.loads(cards_json)
        if isinstance(cards, list):
            save_cards(cards)
            print(json.dumps({"ok": True}))
            return
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return
    print(json.dumps({"ok": False, "error": "Invalid format"}))


def cmd_prepare_image(src: str, dst: str):
    path = Path(src).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": f"File not found: {src}"}))
        return
    try:
        from PIL import Image, ImageOps
        with Image.open(path) as img:
            img = img.convert("RGBA")
            target_size = (1536, 969)
            fitted = ImageOps.fit(img, target_size, method=Image.Resampling.LANCZOS)
            fitted.save(dst, format="PNG")
        print(json.dumps({"ok": True, "path": dst}))
        return
    except ImportError:
        pass
    except Exception as e:
        pass
    
    # Fallback to macOS built-in sips tool (built into every macOS, 0 dependencies!)
    try:
        import subprocess
        subprocess.check_call([
            "/usr/bin/sips",
            "-s", "format", "png",
            "-z", "969", "1536",
            str(path),
            "--out", str(dst)
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(json.dumps({"ok": True, "path": dst}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def cmd_flash(udid: str, card_hash: str, image_path: str) -> bool:
    img_path = Path(image_path)
    if not img_path.is_file():
        print(json.dumps({"ok": False, "error": "Image file not found"}))
        return False

    try:
        asset_payloads = build_card_assets(img_path.read_bytes())
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "message": "Failed to prepare card artwork"
        }))
        sys.stdout.flush()
        return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    
    total_steps = 4
    step = 0
    all_ok = True

    step += 1
    print(json.dumps({
        "type": "progress",
        "card": card_hash,
        "step": step,
        "total": total_steps,
        "message": f"Writing {len(asset_payloads)} artwork files (fast batch)..."
    }))
    sys.stdout.flush()

    try:
        ok = write_files_batch(udid, pkpass_dir, asset_payloads)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        ok = False

    if not ok:
        # Fallback to individual writes if batch fails
        for asset, payload in asset_payloads:
            try:
                ok_single = write_file(udid, pkpass_dir, asset, payload)
            except Exception:
                ok_single = False
            if not ok_single:
                all_ok = False

    # Wallet v2: genuinely unlink rendered faces. Writing corrupt bytes here can
    # leave the previous artwork resident indefinitely on iOS 27.
    for ext in [".cache", ".pkcache"]:
        cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
        step += 1
        print(json.dumps({
            "type": "progress",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "message": f"Invalidating cache ({ext})..."
        }))
        sys.stdout.flush()
        try:
            ok_cache = remove_files(udid, cache_dir, list(CACHE_FILES))
        except Exception:
            ok_cache = False
        if not ok_cache:
            all_ok = False
            print(json.dumps({
                "type": "error",
                "card": card_hash,
                "step": step,
                "total": total_steps,
                "message": f"Could not clear Wallet cache ({ext}); card was not reported as updated."
            }))
            sys.stdout.flush()

    step += 1
    if not all_ok:
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "message": f"Failed to update {card_hash[:12]}..."
        }))
        sys.stdout.flush()
        return False

    print(json.dumps({
        "type": "success",
        "card": card_hash,
        "step": step,
        "total": total_steps,
        "message": f"Successfully updated {card_hash[:12]}..."
    }))
    sys.stdout.flush()
    return True


def cmd_export_card(udid: str, card_hash: str, output_path: str) -> bool:
    try:
        result = export_card(udid, card_hash, Path(output_path).expanduser())
        try:
            cached = save_cached_card(card_hash, result)
            cache_error = None
        except (OSError, ValueError) as error:
            cached = None
            cache_error = str(error)
        print(json.dumps({"ok": True, "type": "success", "message": "卡面导出成功。",
                          "output": output_path, "recovery": str(result.recovery),
                          "cache": cached, "cacheError": cache_error,
                          "exported": result.exported,
                          "unavailable": result.unavailable,
                          "unrecognized": result.unrecognized}, ensure_ascii=False))
        return True
    except Exception as error:
        print(json.dumps({"ok": False, "type": "error", "message":
                          f"Export failed: {error}. Check the AirCard Recovery folder "
                          "before trying again."}))
        return False


def cmd_read_card(udid: str, card_hash: str) -> bool:
    try:
        result = export_card(udid, card_hash, None)
        cached = save_cached_card(card_hash, result)
        print(json.dumps({"ok": True, "type": "success", "message": "卡面读取成功。",
                          "cache": cached, "recovery": str(result.recovery),
                          "exported": result.exported}, ensure_ascii=False))
        return True
    except Exception as error:
        print(json.dumps({"ok": False, "type": "error", "message":
                          f"卡面读取失败：{error}"}, ensure_ascii=False))
        return False


def cmd_classify_card(udid: str, card_hash: str) -> bool:
    try:
        kind, recovery = classify_card(udid, card_hash)
        print(json.dumps({"ok": True, "kind": kind, "recovery": str(recovery)}))
        return True
    except Exception as error:
        print(json.dumps({"ok": False, "kind": "unknown", "message": str(error)}))
        return False


def cmd_cached_cards(hashes_json: str) -> None:
    try:
        hashes = json.loads(hashes_json)
        if not isinstance(hashes, list):
            raise ValueError("Expected a list of card hashes")
        cards = {}
        for card_hash in hashes:
            if not isinstance(card_hash, str):
                continue
            try:
                cached = get_cached_card(card_hash)
            except ValueError:
                cached = None
            if cached is not None:
                cards[card_hash] = cached
        print(json.dumps({"ok": True, "cards": cards}, ensure_ascii=False))
    except (ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}))


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No command provided"}))
        sys.exit(1)

    cmd = sys.argv[1]
    norm_cmd = cmd.lstrip("-")
    if norm_cmd == "device":
        cmd_device()
    elif norm_cmd == "cards":
        cmd_get_saved_cards()
    elif norm_cmd == "save-cards" and len(sys.argv) > 2:
        cmd_save_cards(sys.argv[2])
    elif norm_cmd == "prepare-image" and len(sys.argv) > 3:
        cmd_prepare_image(sys.argv[2], sys.argv[3])
    elif norm_cmd == "flash" and len(sys.argv) > 4:
        if not cmd_flash(sys.argv[2], sys.argv[3], sys.argv[4]):
            sys.exit(1)
    elif norm_cmd == "export-card" and len(sys.argv) > 4:
        if not cmd_export_card(sys.argv[2], sys.argv[3], sys.argv[4]):
            sys.exit(1)
    elif norm_cmd == "read-card" and len(sys.argv) > 3:
        if not cmd_read_card(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "classify-card" and len(sys.argv) > 3:
        if not cmd_classify_card(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "cached-cards" and len(sys.argv) > 2:
        cmd_cached_cards(sys.argv[2])
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
