"""Durable file writes shared by the legacy and cross-platform clients."""
import os
from pathlib import Path


def sync_directory(path: Path):
    # Windows CRT cannot open a directory for fsync. File handles are still
    # flushed before atomic replacement; POSIX additionally flushes the parent.
    if os.name == "nt":
        return
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
