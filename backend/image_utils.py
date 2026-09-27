"""Validated image loading shared by all upload endpoints."""
import io

from PIL import Image, UnidentifiedImageError


MAX_IMAGE_UPLOAD_BYTES = 10 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 40_000_000


def load_upload_image(file, max_bytes: int = MAX_IMAGE_UPLOAD_BYTES) -> Image.Image:
    data = file.file.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise ValueError("Image is too large (maximum 10 MB)")
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
        return image.convert("RGB")
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as exc:
        raise ValueError("Invalid or unsafe image file") from exc
