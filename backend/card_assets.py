#!/usr/bin/env python3
from __future__ import annotations

import io
from typing import Final

PNG_ASSET_NAMES: Final = (
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
)
PDF_ASSET_NAME: Final = "cardBackgroundCombined.pdf"
CACHE_FILES: Final = ("FrontFace", "PlaceHolder", "Preview")


def build_card_assets(png_bytes: bytes) -> tuple[tuple[str, bytes], ...]:
    try:
        from PIL import Image
        from reportlab.lib.utils import ImageReader
        from reportlab.pdfgen.canvas import Canvas
    except ImportError:
        # The retained SwiftUI bundle uses the system Python without dependencies.
        import sys
        if sys.platform != "darwin":
            raise
        import subprocess
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory(prefix="aircard-assets-") as temporary:
            source, destination = Path(temporary) / "card.png", Path(temporary) / "card.pdf"
            source.write_bytes(png_bytes)
            subprocess.run(["/usr/bin/sips", "-s", "format", "pdf", str(source), "--out", str(destination)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            return (*((name, png_bytes) for name in PNG_ASSET_NAMES), (PDF_ASSET_NAME, destination.read_bytes()))

    with Image.open(io.BytesIO(png_bytes)) as image:
        image.load()
        output = io.BytesIO()
        canvas = Canvas(output, pagesize=image.size, invariant=1)
        canvas.drawImage(ImageReader(image), 0, 0, *image.size, mask="auto")
        canvas.showPage()
        canvas.save()
        pdf_bytes = output.getvalue()

    png_assets = tuple((name, png_bytes) for name in PNG_ASSET_NAMES)
    return (*png_assets, (PDF_ASSET_NAME, pdf_bytes))
