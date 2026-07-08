#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${TMPDIR:-/tmp}/qixi-board-recognition-smoke"
IMAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qixi-board-recognition-images.XXXXXX")"

cleanup() {
  rm -rf "$IMAGE_DIR"
}
trap cleanup EXIT

BOARD="$NATIVE_DIR/Qixi/Resources/Images/board06InkPaper.png" \
BLACK="$NATIVE_DIR/Qixi/Resources/Images/black19Yunzi.png" \
WHITE="$NATIVE_DIR/Qixi/Resources/Images/whiteStone.png" \
IMAGE_DIR="$IMAGE_DIR" \
python3 - <<'PY'
import os
from PIL import Image, ImageDraw, ImageEnhance

board = Image.open(os.environ["BOARD"]).convert("RGBA")
black = Image.open(os.environ["BLACK"]).convert("RGBA")
white = Image.open(os.environ["WHITE"]).convert("RGBA")
image_dir = os.environ["IMAGE_DIR"]
side = board.width
pad = side * (60.0 / 960.0)
step = side * ((840.0 / 18.0) / 960.0)
stone_size = int(round(step * 0.94))

def render(name, stones, brightness=1.0):
    image = board.copy()
    for color, x, y in stones:
        source = black if color == "B" else white
        cx = int(round(pad + x * step))
        cy = int(round(pad + y * step))
        stone = source.resize((stone_size, stone_size))
        image.alpha_composite(stone, (cx - stone_size // 2, cy - stone_size // 2))
    rgb = image.convert("RGB")
    if brightness != 1.0:
        rgb = ImageEnhance.Brightness(rgb).enhance(brightness)
    rgb.save(os.path.join(image_dir, f"{name}.png"))
    return rgb

render("empty", [])
standard = render("standard", [
    ("B", 3, 3),
    ("W", 15, 3),
    ("B", 10, 10),
    ("W", 16, 16),
])
render("dimmed", [
    ("B", 3, 3),
    ("W", 15, 3),
    ("B", 10, 10),
    ("W", 16, 16),
], brightness=0.82)
render("dense", [
    ("B", 3, 3),
    ("W", 15, 3),
    ("B", 10, 10),
    ("W", 16, 16),
    ("B", 4, 15),
    ("W", 14, 4),
    ("B", 16, 10),
    ("W", 10, 16),
])

padded = Image.new("RGB", (1500, 1300), (238, 232, 220))
scaled = standard.resize((1050, 1050))
padded.paste(scaled, (230, 120))
padded.save(os.path.join(image_dir, "padded.png"))

rotated = standard.rotate(
    2.0,
    resample=Image.Resampling.BICUBIC,
    expand=True,
    fillcolor=(238, 232, 220),
)
rotated.save(os.path.join(image_dir, "rotated.png"))

w, h = standard.size
perspective = standard.transform(
    (w, h),
    Image.Transform.QUAD,
    (25, 45, 55, h - 5, w - 10, h - 30, w - 70, 10),
    resample=Image.Resampling.BICUBIC,
    fillcolor=(238, 232, 220),
)
perspective.save(os.path.join(image_dir, "perspective.png"))

glare_overlay = Image.new("RGBA", standard.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(glare_overlay)
draw.ellipse((760, 105, 1110, 455), fill=(255, 255, 255, 120))
glare = Image.alpha_composite(standard.convert("RGBA"), glare_overlay).convert("RGB")
glare.save(os.path.join(image_dir, "glare.png"))

large = standard.resize((3200, 3200), Image.Resampling.BICUBIC)
large.save(os.path.join(image_dir, "large.png"))

exif = Image.Exif()
exif[274] = 6
standard.rotate(90, expand=True).save(
    os.path.join(image_dir, "exif-oriented.jpg"),
    quality=95,
    exif=exif,
)
PY

swiftc \
  "$NATIVE_DIR/Qixi/L10n.swift" \
  "$NATIVE_DIR/Qixi/QixiModels.swift" \
  "$NATIVE_DIR/Qixi/QixiBoardImageRecognizer.swift" \
  "$SCRIPT_DIR/board_recognition_smoke.swift" \
  -o "$OUT"

"$OUT" \
  "$IMAGE_DIR/empty.png" \
  "$IMAGE_DIR/standard.png" \
  "$IMAGE_DIR/dimmed.png" \
  "$IMAGE_DIR/dense.png" \
  "$IMAGE_DIR/padded.png" \
  "$IMAGE_DIR/rotated.png" \
  "$IMAGE_DIR/perspective.png" \
  "$IMAGE_DIR/glare.png" \
  "$IMAGE_DIR/large.png" \
  "$IMAGE_DIR/exif-oriented.jpg"
