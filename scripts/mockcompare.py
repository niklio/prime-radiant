#!/usr/bin/env python3
"""Side-by-side sheet: design mocks vs live app screenshots.

Usage: mockcompare.py <out.png> <mock1:shot1|PENDING[:label]> [...]
Each pair renders as one row: mock left, app capture right (PENDING → dark
placeholder), labeled with the screen name. Screenshots are resized to the
mock's height. Run with the venv at ~/.venvs/mockcompare.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

GAP = 14
LABEL_H = 34
BG = (8, 8, 18)
FG = (243, 236, 216)
PENDING_FG = (140, 135, 120)


def load_font(size=15):
    for path in (
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main():
    out = Path(sys.argv[1])
    pairs = []
    for spec in sys.argv[2:]:
        parts = spec.split(":")
        mock, shot = parts[0], parts[1]
        label = parts[2] if len(parts) > 2 else Path(mock).stem
        pairs.append((mock, shot, label))

    font = load_font()
    rows = []
    for mock_path, shot_path, label in pairs:
        mock = Image.open(mock_path).convert("RGB")
        if shot_path == "PENDING":
            shot = Image.new("RGB", mock.size, (16, 16, 24))
            draw = ImageDraw.Draw(shot)
            draw.text(
                (mock.width // 2, mock.height // 2),
                "pending",
                fill=PENDING_FG,
                font=font,
                anchor="mm",
            )
        else:
            shot = Image.open(shot_path).convert("RGB")
            shot = shot.resize(
                (int(shot.width * mock.height / shot.height), mock.height),
                Image.LANCZOS,
            )
        row = Image.new("RGB", (mock.width + GAP + shot.width, mock.height + LABEL_H), BG)
        draw = ImageDraw.Draw(row)
        draw.text((6, 8), f"{label}   (mock | app)", fill=FG, font=font)
        row.paste(mock, (0, LABEL_H))
        row.paste(shot, (mock.width + GAP, LABEL_H))
        rows.append(row)

    width = max(r.width for r in rows)
    sheet = Image.new("RGB", (width, sum(r.height + GAP for r in rows)), BG)
    y = 0
    for row in rows:
        sheet.paste(row, (0, y))
        y += row.height + GAP
    sheet.save(out)
    print(f"wrote {out} ({sheet.width}x{sheet.height}, {len(rows)} rows)")


if __name__ == "__main__":
    main()
