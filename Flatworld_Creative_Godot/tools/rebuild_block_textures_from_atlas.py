#!/usr/bin/env python3
"""Rebuild derived 16x16 block-face PNGs from the committed atlas without changing pixels.

The game renderer loads assets/textures/atlas.png directly. Individual PNGs in
assets/textures/blocks are editable source copies; every one is recoverable from
atlas_map.json. This script restores those files pixel-identically and verifies
that every mapped face resolves to a unique in-bounds 16x16 region.
"""
from __future__ import annotations
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ATLAS_PATH = ROOT / "assets/textures/atlas.png"
MAP_PATH = ROOT / "assets/textures/atlas_map.json"
OUTPUT = ROOT / "assets/textures/blocks"

def main() -> int:
    doc = json.loads(MAP_PATH.read_text(encoding="utf-8"))
    tile_size = int(doc.get("tile_size", 16))
    columns = int(doc.get("columns", 64))
    if tile_size != 16:
        raise SystemExit(f"Expected 16x16 atlas cells, got {tile_size}")
    atlas = Image.open(ATLAS_PATH).convert("RGBA")
    tiles = doc.get("tiles", {})
    if not tiles:
        raise SystemExit("atlas_map.json has no tiles")
    expected = 0
    used = set()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for block_id, faces in tiles.items():
        if not isinstance(faces, dict):
            raise SystemExit(f"Invalid atlas map entry: {block_id}")
        for face, slot in faces.items():
            if not isinstance(slot, dict):
                raise SystemExit(f"Invalid face mapping: {block_id}/{face}")
            x, y = int(slot["x"]), int(slot["y"])
            w, h = int(slot.get("width", tile_size)), int(slot.get("height", tile_size))
            if (w, h) != (tile_size, tile_size) or x < 0 or y < 0 or x + w > atlas.width or y + h > atlas.height:
                raise SystemExit(f"Out-of-bounds or wrong-sized tile: {block_id}/{face}")
            slot_key = (x, y, w, h)
            if slot_key in used:
                raise SystemExit(f"Duplicate atlas rectangle: {block_id}/{face}")
            used.add(slot_key)
            image = atlas.crop((x, y, x + w, y + h))
            image.save(OUTPUT / f"{block_id}_{face}.png", optimize=True)
            expected += 1
    actual = len(list(OUTPUT.glob("*.png")))
    if actual != expected:
        raise SystemExit(f"Expected {expected} restored swatches, found {actual}")
    print(f"Restored {actual} block-face PNGs pixel-identically from atlas.png.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
