import io
from pathlib import Path

from PIL import Image, ImageCms, ImageOps
from .storage import put

SIZE = (1536, 969)


def artwork_preview(assets):
    for name in ("cardBackgroundCombined@3x.png", "cardBackgroundCombined@2x.png"):
        if assets.get(name):
            return assets[name]
    if assets.get("cardBackgroundCombined.pdf"):
        import pypdfium2 as pdfium
        with pdfium.PdfDocument(assets["cardBackgroundCombined.pdf"]) as document:
            page = document[0]
            try:
                bitmap = page.render(scale=min(1536 / page.get_width(), 969 / page.get_height()))
                try:
                    output = io.BytesIO()
                    bitmap.to_pil().save(output, "PNG")
                    return output.getvalue()
                finally:
                    bitmap.close()
            finally:
                page.close()
    return None


def oriented_srgb(opened):
    image = ImageOps.exif_transpose(opened)
    icc = image.info.get("icc_profile")
    if icc:
        image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(icc)),
                                         ImageCms.createProfile("sRGB"), outputMode="RGBA")
    return image.convert("RGBA")


def inspect(source: Path):
    import base64
    if source.suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp") or source.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("IMAGE_FORMAT")
    with Image.open(source) as opened:
        if opened.width * opened.height > 40_000_000:
            raise ValueError("IMAGE_TOO_LARGE")
        image = oriented_srgb(opened)
        width, height = image.size
        image.thumbnail((1400, 1400))
        output = io.BytesIO()
        image.save(output, format="PNG")
    return {"width": width, "height": height, "preview": "data:image/png;base64," + base64.b64encode(output.getvalue()).decode()}


def prepare(source: Path, destination: Path, crop: dict | None = None):
    if source.suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp"):
        raise ValueError("IMAGE_FORMAT")
    if source.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("IMAGE_TOO_LARGE")
    with Image.open(source) as opened:
        if opened.width * opened.height > 40_000_000:
            raise ValueError("IMAGE_TOO_LARGE")
        image = oriented_srgb(opened)
        if crop:
            x, y, width, height = [float(crop[k]) for k in ("x", "y", "width", "height")]
            if not (0 <= x < 1 and 0 <= y < 1 and 0 < width <= 1 and 0 < height <= 1
                    and x + width <= 1.00001 and y + height <= 1.00001):
                raise ValueError("INVALID_CROP")
            image = image.crop((round(x * image.width), round(y * image.height),
                                round((x + width) * image.width), round((y + height) * image.height)))
        image = ImageOps.fit(image, SIZE, method=Image.Resampling.LANCZOS)
        output = io.BytesIO()
        image.save(output, format="PNG")
        put(destination, output.getvalue())
    return destination
