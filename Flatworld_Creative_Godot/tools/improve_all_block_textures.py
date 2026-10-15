#!/usr/bin/env python3
"""Improve every existing Flatworld texture without changing the block catalogue.

All source artwork is original procedural pixel art. The script treats blocks.json
and atlas_map.json as immutable inputs: no block/item ID, recipe, entity, or tile
index is created, deleted, or renumbered. Every existing 16x16 face swatch is
regenerated and repacked into the already-registered atlas slots.

Run from any directory with Python 3 and Pillow installed:
    python3 tools/improve_all_block_textures.py
"""
from __future__ import annotations

import hashlib
import json
import math
import random
from pathlib import Path
from typing import Iterable
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
BLOCKS_PATH = ROOT / "assets/data/blocks.json"
MAP_PATH = ROOT / "assets/textures/atlas_map.json"
ATLAS_PATH = ROOT / "assets/textures/atlas.png"
SWATCH_DIR = ROOT / "assets/textures/blocks"
TILE = 16
VERSION_SALT = "flatworld-original-pixel-art-v4"


def rgb(value: str | None, fallback=(128, 128, 128)) -> tuple[int, int, int]:
    if not value:
        return fallback
    try:
        s = value.strip().lstrip("#")
        if len(s) == 3:
            s = "".join(ch * 2 for ch in s)
        return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))
    except (ValueError, IndexError):
        return fallback


def clip_color(color: Iterable[int]) -> tuple[int, int, int]:
    return tuple(max(0, min(255, int(round(c)))) for c in color)  # type: ignore[return-value]


def shade(color, amount: int):
    return clip_color(c + amount for c in color)


def mix(a, b, t: float):
    return clip_color(x * (1.0 - t) + y * t for x, y in zip(a, b))


def rng_for(block_id: str, face: str) -> random.Random:
    digest = hashlib.sha256(f"{block_id}:{face}:{VERSION_SALT}".encode()).digest()
    return random.Random(int.from_bytes(digest[:8], "big"))


def setpx(im: Image.Image, x: int, y: int, color, alpha=255):
    if 0 <= x < TILE and 0 <= y < TILE:
        im.putpixel((x, y), (*clip_color(color), max(0, min(255, int(alpha)))))


def noise_clusters(im: Image.Image, base, rng: random.Random, amplitude=10, scale=2,
                    density=0.48, alpha=255):
    """Clustered colour noise: legible pixel groups instead of blurry gradients."""
    px = im.load()
    for cy in range(0, TILE, scale):
        for cx in range(0, TILE, scale):
            amount = rng.randint(-amplitude, amplitude) if rng.random() < density else 0
            color = shade(base, amount)
            for y in range(cy, min(TILE, cy + scale)):
                for x in range(cx, min(TILE, cx + scale)):
                    local = rng.choice([-2, -1, 0, 0, 0, 1, 2])
                    px[x, y] = (*shade(color, local), alpha)


def flecks(im, base, rng, count, dark_range=(-22, -7), light_range=(7, 18), size_choices=(1, 1, 2)):
    d = ImageDraw.Draw(im)
    for _ in range(count):
        x, y = rng.randrange(16), rng.randrange(16)
        w = rng.choice(size_choices)
        amount = rng.randint(*dark_range) if rng.random() < 0.62 else rng.randint(*light_range)
        d.rectangle((x, y, min(15, x + w - 1), min(15, y + w - 1)), fill=(*shade(base, amount), 255))


def rocky(im, base, rng, kind="stone", block_id="stone"):
    """Textured pixel-stone with distinct clustered grains and optional joints."""
    noise_clusters(im, base, rng, 14 if kind in ("gravel", "bedrock") else 9, 2, .62)
    d = ImageDraw.Draw(im)
    if kind in ("cobble", "mossy_cobble"):
        # A jittered, tileable-ish 4x4 field of irregular stones with subdued grout.
        centers = []
        for gy in range(-1, 4):
            for gx in range(-1, 4):
                centers.append((gx * 5 + rng.randint(-1, 1) + 2,
                                gy * 5 + rng.randint(-1, 1) + 2))
        px = im.load()
        for y in range(16):
            for x in range(16):
                distances = sorted((x-cx)**2 + (y-cy)**2 for cx, cy in centers)
                if len(distances) > 1 and distances[1] - distances[0] < rng.choice([1, 2, 3, 4]):
                    color = shade(base, -27)
                else:
                    color = shade(base, rng.choice([-18, -12, -7, -2, 3, 8, 12]))
                    if kind == "mossy_cobble" and rng.random() < .18:
                        color = mix(color, (69, 111, 49), rng.uniform(.38, .74))
                px[x, y] = (*color, 255)
        # Pixel-edge glints add stone volume without a smooth/3-D gradient.
        for x, y in [(2,2),(7,1),(12,3),(4,7),(10,6),(1,12),(8,11),(13,14)]:
            if rng.random() < .75:
                setpx(im, x, y, shade(base, rng.randint(10, 20)))
    elif kind == "gravel":
        d = ImageDraw.Draw(im)
        for _ in range(15):
            x, y = rng.randrange(16), rng.randrange(16)
            c = shade(base, rng.choice([-34, -25, -12, 10, 19, 28]))
            d.rectangle((x, y, min(15, x + rng.choice([0,1,2])), min(15, y + rng.choice([0,1])),), fill=(*c,255))
    elif kind == "bedrock":
        for _ in range(7):
            x, y = rng.randrange(1,15), rng.randrange(1,15)
            d.rectangle((x,y,min(15,x+rng.randrange(1,3)),min(15,y+rng.randrange(0,2))), fill=(*shade(base, rng.choice([-28,-20,17])),255))
    elif kind in ("brick", "cracked_brick", "mossy_brick", "sandstone", "nether_brick"):
        mortar = shade(base, -31)
        for y in (0, 5, 10, 15):
            d.line((0, y, 15, y), fill=(*mortar, 255))
        # Offset courses, avoid the monotonous all-columns-aligned pattern.
        for row, y in enumerate((0,5,10)):
            shift = 0 if row % 2 == 0 else 4
            for x in (shift, shift + 8, shift + 16):
                xx = x % 16
                d.line((xx, y, xx, min(15, y+4)), fill=(*shade(base,-25),255))
        flecks(im, base, rng, 7, (-8,-3), (4,9), (1,1))
        if kind == "cracked_brick":
            d.line((4,2,5,3,5,5,7,6), fill=(*shade(base,-35),255))
            d.line((12,10,10,11,10,13), fill=(*shade(base,-32),255))
        if kind == "mossy_brick":
            for _ in range(22):
                x,y = rng.randrange(16),rng.randrange(16)
                setpx(im,x,y,mix(base,(67,105,45),rng.uniform(.38,.72)))
    else:
        flecks(im, base, rng, 12 if kind != "polished" else 5)
        # Rare tiny mineral facets / stone chips.
        for x,y in [(3,5),(11,2),(8,12)]:
            if rng.random() < .5: setpx(im,x,y,shade(base,14))


def dirt(im, base, rng, block_id: str, face: str):
    noise_clusters(im, base, rng, 13, 2, .68)
    d = ImageDraw.Draw(im)
    if "coarse" in block_id:
        for _ in range(20):
            x,y=rng.randrange(16),rng.randrange(16)
            c=shade(base,rng.choice([-23,-10,16,25]))
            d.rectangle((x,y,min(15,x+1),min(15,y+1)), fill=(*c,255))
    elif "rooted" in block_id:
        root=shade(base,-22)
        for path in [[(2,0),(3,3),(5,5),(4,8),(7,11),(8,15)],[(13,0),(12,4),(10,6),(11,9),(8,12)],[(0,8),(3,9),(4,12),(2,15)]]:
            d.line(path, fill=(*root,255), width=1)
        for _ in range(8):
            x,y=rng.randrange(16),rng.randrange(16)
            setpx(im,x,y,shade(base,rng.choice([-21,17])))
    elif "podzol" in block_id or (block_id == "podzol"):
        for _ in range(20):
            x,y=rng.randrange(16),rng.randrange(5,16)
            setpx(im,x,y,shade(base,rng.choice([-22,-10,12,18])))
    else:
        for _ in range(12):
            x,y=rng.randrange(16),rng.randrange(16)
            setpx(im,x,y,shade(base,rng.choice([-23,-12,12,21])))


def sand(im, base, rng, red=False):
    noise_clusters(im, base, rng, 6, 2, .45)
    # Sparse low-contrast grains read as sand rather than noise.
    palette=[shade(base,-13),shade(base,-7),shade(base,7),shade(base,12)]
    px=im.load()
    for y in range(16):
        for x in range(16):
            if rng.random()<.19:
                px[x,y]=(*rng.choice(palette),255)
    if red:
        for _ in range(5):
            x,y=rng.randrange(16),rng.randrange(16)
            setpx(im,x,y,mix(base,(122,54,33),rng.uniform(.2,.5)))


def grass_top(im, base, rng, block_id):
    # Dense grass pixel-clusters with patchy olive/light green variation.
    noise_clusters(im, base, rng, 10, 2, .72)
    d=ImageDraw.Draw(im)
    dark=mix(base,(53,104,37),.36); bright=mix(base,(140,175,62),.40)
    for _ in range(25):
        x,y=rng.randrange(16),rng.randrange(16)
        color=rng.choice([shade(dark,-4),dark,bright,shade(base,12)])
        d.rectangle((x,y,min(15,x+rng.choice([0,1])),min(15,y+rng.choice([0,1]))),fill=(*color,255))
    if block_id == "podzol":
        # Dead leaf litter/twigs over packed soil; decidedly not green turf.
        palette=[(90,62,35),(115,73,39),(145,100,48),(71,55,35),(164,119,57)]
        for _ in range(19):
            x,y=rng.randrange(16),rng.randrange(16)
            d.line((x,y,min(15,x+rng.choice([1,2])),min(15,y+rng.choice([0,1]))),fill=(*rng.choice(palette),255))
        for _ in range(8): setpx(im,rng.randrange(16),rng.randrange(16),(166,125,61))
    elif block_id == "mycelium":
        spore=mix(base,(176,151,174),.45)
        dark=mix(base,(71,63,74),.42)
        for _ in range(24):
            x,y=rng.randrange(16),rng.randrange(16)
            setpx(im,x,y,rng.choice([spore,dark,shade(base,13)]))


def grass_side(im, soil, turf, rng, block_id):
    dirt(im, soil, rng, "dirt", "side")
    px=im.load()
    if block_id == "grass_block":
        for y in range(3):
            for x in range(16):
                delta=rng.choice([-7,-4,-1,0,2,5,8])
                px[x,y]=(*shade(turf,delta),255)
        # Natural tufts hang 1–3 pixels into the dirt, varying in length.
        for x in [1,3,6,7,10,12,14]:
            length=rng.choice([0,1,2,2,3])
            for i in range(length):
                if 3+i<16: px[x,3+i]=(*shade(turf,rng.choice([-10,-4,2,7])),255)
    elif block_id == "podzol":
        cap=mix(soil,(102,74,43),.42)
        for y in range(2):
            for x in range(16): px[x,y]=(*shade(cap,rng.randint(-6,6)),255)
        for x in (1,4,8,12,15):
            if rng.random()<.8: px[x,2]=(*shade(cap,rng.choice([-15,10,16])),255)
    elif block_id == "mycelium":
        cap=mix(soil,(126,111,128),.48)
        for y in range(2):
            for x in range(16): px[x,y]=(*shade(cap,rng.randint(-6,6)),255)
        for x,y in [(2,3),(7,4),(12,3),(4,5),(14,6)]: setpx(im,x,y,mix(cap,(177,142,184),.35))


def log_texture(im, base, rng, face, block_id):
    stripped = "stripped" in block_id
    if face in ("top", "bottom"):
        center=(7,7)
        # Concentric square growth rings, with irregular growth and a dark bark rim.
        bark=shade(base,-35)
        d=ImageDraw.Draw(im)
        d.rectangle((0,0,15,15),fill=(*bark,255))
        wood=mix(base,(205,169,111),.28) if stripped else mix(base,(185,141,80),.22)
        d.rectangle((1,1,14,14),fill=(*wood,255))
        rings=[shade(wood,-21),shade(wood,-7),shade(wood,7),shade(wood,-12),shade(wood,13),shade(wood,-4),shade(wood,8)]
        for i,c in enumerate(rings):
            inset=2+i
            if inset<8:
                d.rectangle((inset,inset,15-inset,15-inset),outline=(*c,255))
        d.rectangle((6,6,9,9),outline=(*shade(wood,-9),255))
        setpx(im,7,7,shade(wood,16)); setpx(im,8,7,shade(wood,6))
        if stripped:
            # A pale sapwood strip replaces bark on stripped wood ends.
            for x in range(1,15):
                if x in [2,3,12,13]: setpx(im,x,1,shade(wood,14))
    else:
        # Side bark: vertical ridges, thin lighter seams and a few knot pixels.
        noise_clusters(im, base, rng, 5 if stripped else 8, 2, .45)
        d=ImageDraw.Draw(im)
        for x in [0,4,8,12,15]:
            c=shade(base, -15 if (x//4)%2==0 else 10)
            d.line((x,0,x,15),fill=(*c,255))
            if x+1<16: d.line((x+1,0,x+1,15),fill=(*shade(base,5 if stripped else -5),255))
        for y in (4,11):
            x=rng.randrange(1,13)
            d.point((x,y),fill=(*shade(base,-20),255))
            if x+1<16: d.point((x+1,y),fill=(*shade(base,12),255))
        if stripped:
            for x in (2,7,13): d.line((x,0,x,15),fill=(*shade(base,9),255))


def planks(im, base, rng, block_id, face):
    noise_clusters(im, base, rng, 5, 2, .3)
    d=ImageDraw.Draw(im)
    row_h=4
    wood_id=block_id
    seam=shade(base,-25)
    highlight=shade(base,10)
    for row,y0 in enumerate(range(0,16,row_h)):
        d.line((0,y0,15,y0),fill=(*seam,255))
        # Slightly offset grain strokes in every plank; avoid uniform striping.
        for _ in range(2):
            x=rng.randrange(1,13); y=rng.randrange(y0+1,min(16,y0+4))
            end=min(15,x+rng.randrange(1,4))
            d.line((x,y,end,y),fill=(*shade(base,rng.choice([-9,-4,4,8])),255))
        if rng.random()<.75:
            x=rng.randrange(2,13); y=min(15,y0+2)
            d.point((x,y),fill=(*shade(base,-14),255))
            if x+1<16:d.point((x+1,y),fill=(*highlight,255))
    if face in ("top", "bottom") and ("crafting_table" in block_id):
        d.rectangle((0,0,15,15),fill=(*shade(base,-5),255))
        for y in (0,5,10,15): d.line((0,y,15,y),fill=(*shade(base,-26),255))
        for x in (0,5,10,15): d.line((x,0,x,15),fill=(*shade(base,-24),255))
        for x,y in [(3,3),(8,3),(13,3),(3,8),(8,8),(13,8),(3,13),(8,13),(13,13)]: setpx(im,x,y,shade(base,12))


def leaf_texture(im, base, rng, block_id):
    im.putdata([(0,0,0,0)]*256)
    px=im.load()
    leaf_dark=mix(base,(34,62,29),.45)
    leaf_light=mix(base,(175,194,93),.36)
    autumn = "poplar_leaves" in block_id or "red" in block_id or "orange" in block_id or "yellow" in block_id
    # Fill clumps of leaves, preserving transparent gaps so foliage stays cutout.
    centers=[(3,4),(8,3),(12,6),(4,10),(10,11),(7,7)]
    for y in range(16):
        for x in range(16):
            distances=[(x-cx)**2+(y-cy)**2 for cx,cy in centers]
            if min(distances)>rng.choice([15,18,21,24]) and rng.random()<.62:
                continue
            roll=rng.random()
            color=leaf_dark if roll<.17 else (leaf_light if roll>.82 else shade(base,rng.randint(-9,9)))
            px[x,y]=(*color,255)
    # A few small branching vein lines keep the 16px leaf cluster readable.
    vein=mix(base,(39,75,30),.40)
    for path in [[(2,2),(5,5),(7,7)],[(12,4),(10,6),(9,8)],[(3,12),(6,10),(8,8)]]:
        if rng.random()<.75:
            ImageDraw.Draw(im).line(path,fill=(*vein,255),width=1)


def wool_texture(im, base, rng, block_id):
    noise_clusters(im, base, rng, 8, 2, .56)
    d=ImageDraw.Draw(im)
    dark=shade(base,-12); light=shade(base,10)
    # Short interlocking fibre dashes rather than random single-pixel static.
    for y in range(1,16,3):
        offset=rng.randrange(3)
        for x in range(offset,16,4):
            if rng.random()<.86:
                d.line((x,y,min(15,x+1),y),fill=(*rng.choice([dark,light,shade(base,-4)]),255))
    if block_id == "cushion":
        d.line((2,3,13,3),fill=(*shade(base,18),255))
        d.line((2,12,13,12),fill=(*shade(base,-20),255))
        d.point((3,4),fill=(*shade(base,-17),255)); d.point((12,11),fill=(*shade(base,-17),255))


def metal_block(im, base, rng, block_id, face):
    # Subtle beveled metal plates, tuned per material; no blurred gradients.
    noise_clusters(im, base, rng, 3, 2, .15)
    d=ImageDraw.Draw(im)
    dark=shade(base,-28); light=shade(base,15)
    if block_id == "gold_block" or "gold_block" in block_id:
        light=mix(base,(255,230,104),.28)
    elif "diamond" in block_id:
        light=mix(base,(194,255,242),.24)
    elif "emerald" in block_id:
        light=mix(base,(170,255,177),.24)
    elif "copper" in block_id:
        light=mix(base,(255,172,108),.22)
        dark=mix(base,(93,75,52),.22)
    d.line((1,1,14,1),fill=(*light,255))
    d.line((1,1,1,14),fill=(*light,255))
    d.line((2,14,14,14),fill=(*dark,255))
    d.line((14,2,14,14),fill=(*dark,255))
    # Large areas stay relatively quiet, matching pixel-era solid metal blocks.
    for y in (4,10):
        if rng.random()<.45:d.line((3,y,12,y),fill=(*shade(base,rng.choice([-5,4,8])),255))


def ore_texture(im, base, rng, block_id):
    # Ore speckles embedded in stone (not an ore-coloured panel).
    host=base
    if "deepslate" in block_id:
        host=(70,70,78)
        noise_clusters(im,host,rng,8,2,.60)
        d=ImageDraw.Draw(im)
        for y in (3,8,13):
            shift=rng.randrange(4)
            d.line((shift,y,15,y),fill=(*shade(host,-14),255))
    elif "nether" in block_id:
        host=(91,42,37)
        noise_clusters(im,host,rng,10,2,.55)
    else:
        noise_clusters(im,host,rng,10,2,.58)
    name=block_id.lower()
    ore_palette={
        "coal":(40,38,37),"iron":(209,168,133),"copper":(209,112,64),
        "gold":(244,193,40),"diamond":(74,211,202),"emerald":(35,184,76),
        "lapis":(40,79,178),"redstone":(174,36,27),"quartz":(228,219,204),
        "ancient_debris":(157,105,58)
    }
    ore_key=next((k for k in ore_palette if k in name),"coal")
    ore=ore_palette[ore_key]
    d=ImageDraw.Draw(im)
    # 3–5 uneven mineral clusters with shadow pixels around brighter chips.
    count=4 if ore_key not in ("coal","quartz") else 5
    for _ in range(count):
        cx,cy=rng.randrange(2,14),rng.randrange(2,14)
        points={(cx,cy)}
        for _j in range(rng.randint(2,5)):
            points.add((max(0,min(15,cx+rng.choice([-2,-1,0,1,2]))),max(0,min(15,cy+rng.choice([-1,0,1])))))
        for x,y in points:
            setpx(im,x,y,shade(ore,rng.randint(-13,13)))
            if x>0 and rng.random()<.28:setpx(im,x-1,y,mix(host,ore,.28))
            if y>0 and rng.random()<.19:setpx(im,x,y-1,shade(host,-14))
    if ore_key=="redstone" and rng.random()<.8:
        for x,y in [(4,3),(10,9),(12,5)]: setpx(im,x,y,(207,54,39))


def brick_texture(im, base, rng, block_id, face):
    if block_id == "tnt":
        noise_clusters(im,base,rng,5,2,.24)
        d=ImageDraw.Draw(im)
        d.rectangle((0,5,15,10),fill=(222,215,197,255))
        d.line((0,4,15,4),fill=(154,43,32,255)); d.line((0,11,15,11),fill=(136,38,29,255))
        for x in (2,5,9,13): d.point((x,7),fill=(54,48,44,255))
        return
    kind="brick"
    if "cracked" in block_id: kind="cracked_brick"
    elif "mossy" in block_id: kind="mossy_brick"
    elif "sandstone" in block_id: kind="sandstone"
    elif "nether_brick" in block_id: kind="nether_brick"
    rocky(im,base,rng,kind,block_id)
    if "nether" in block_id:
        d=ImageDraw.Draw(im)
        for _ in range(6):
            x,y=rng.randrange(16),rng.randrange(16)
            setpx(im,x,y,shade(base,rng.choice([-20,10,18])))


def crystal_texture(im, base, rng, block_id):
    noise_clusters(im,shade(base,-12),rng,6,2,.22)
    d=ImageDraw.Draw(im)
    dark=shade(base,-27); mid=shade(base,7); light=shade(base,35)
    # Jagged, stair-stepped facets form readable crystal geometry.
    facets=[[(1,7),(4,3),(6,6),(5,11),(2,12)],[(6,5),(9,1),(12,4),(11,10),(7,11)],[(11,8),(13,6),(15,9),(14,13),(11,12)]]
    for i,poly in enumerate(facets):
        c=[mid,light,shade(base,16)][i]
        d.polygon(poly,fill=(*c,255))
        d.line([poly[0],poly[1],poly[2]],fill=(*light,255))
        d.line([poly[2],poly[3],poly[4]],fill=(*dark,255))
    for _ in range(5): setpx(im,rng.randrange(16),rng.randrange(16),rng.choice([light,dark]))


def glass_texture(im, base, rng, block_id):
    alpha=54 if block_id!="tinted_glass" else 116
    if "tinted" in block_id:
        base=mix(base,(35,32,45),.45)
    im.putdata([(*base,alpha)]*256)
    d=ImageDraw.Draw(im)
    bright=mix(base,(255,255,255),.70)
    low=mix(base,(18,25,34),.25)
    d.line((0,0,15,0),fill=(*bright,180))
    d.line((0,0,0,15),fill=(*bright,145))
    d.point((2,2),fill=(*bright,205))
    d.line((11,13,14,15),fill=(*low,95))
    if block_id=="beacon":
        d.line((0,15,15,0),fill=(*mix(base,(255,255,255),.45),180))
        d.point((8,7),fill=(224,255,250,230))


def ice_texture(im, base, rng, block_id, face):
    alpha=150 if block_id == "ice" else 185 if block_id == "packed_ice" else 200
    im.putdata([(*mix(base,(241,251,255),.10),alpha)]*256)
    d=ImageDraw.Draw(im)
    bright=mix(base,(240,255,255),.6); shade_c=mix(base,(54,105,156),.35)
    for path in [[(1,3),(4,2),(6,4),(8,3)],[(8,9),(10,8),(12,10),(14,9)]]:
        if rng.random()<.7:d.line(path,fill=(*bright,175),width=1)
    if block_id=="blue_ice":
        d.line((2,12,5,10,7,11),fill=(*shade_c,210))
        d.point((12,3),fill=(*bright,220))
    elif block_id=="packed_ice":
        for x,y in [(4,5),(5,5),(10,12),(11,12)]: setpx(im,x,y,bright,alpha)


def fluid_texture(im, base, rng, block_id, face):
    d=ImageDraw.Draw(im)
    if block_id=="water":
        c=mix(base,(38,107,205),.20)
        alpha=150 if face not in ("top", "lit_top") else 178
        im.putdata([(*c,alpha)]*256)
        for y in (3,8,13):
            x=rng.randrange(0,5)
            d.line((x,y,min(15,x+4),y),fill=(*mix(c,(182,224,246),.38),min(220,alpha+35)))
            if y+1<16 and x+2<16:setpx(im,x+2,y+1,mix(c,(126,187,229),.22),alpha)
    else:
        base_dark=mix(base,(70,18,8),.50)
        px=im.load()
        palette=[mix(base_dark,(150,36,9),.35),mix(base,(243,94,18),.38),mix(base,(255,180,43),.60)]
        for y in range(16):
            for x in range(16):
                color=rng.choices(palette,[.30,.54,.16])[0]
                if (x*3+y*5)%17==0: color=palette[2]
                px[x,y]=(*color,235)
        for path in [[(1,3),(4,2),(6,4),(10,3)],[(7,12),(10,10),(13,11),(15,9)]]:
            if rng.random()<.7:d.line(path,fill=(255,171,42,245),width=1)


def plant_texture(im, base, rng, block_id, pattern):
    im.putdata([(0,0,0,0)]*256)
    d=ImageDraw.Draw(im); px=im.load()
    green=clip_color(base) if isinstance(base, (tuple, list)) else rgb(base, (83,139,57))
    dark=mix(green,(35,75,31),.48); light=mix(green,(177,207,89),.35)
    # A stem + species-specific leaves/flower silhouette on transparent pixels.
    if "sapling" in block_id or "shrub" in block_id:
        d.line((7,15,7,7),fill=(*dark,255),width=1)
        d.line((7,11,3,7),fill=(*green,255),width=1)
        d.line((7,9,12,4),fill=(*green,255),width=1)
        for cx,cy in [(3,5),(5,3),(7,5),(10,3),(12,5),(4,8),(9,7),(12,8)]:
            for dx,dy in [(0,0),(1,0),(0,1),(1,1)]:
                setpx(im,cx+dx,cy+dy,light if (cx+cy)%3==0 else green)
    elif any(s in block_id for s in ("poppy","dandelion","tulip","orchid","allium","flower")) or pattern=="flower":
        d.line((7,7,7,15),fill=(49,105,37,255),width=1)
        if "dandelion" in block_id: petal=(239,200,43); center=(255,233,99)
        elif "allium" in block_id: petal=(171,115,210); center=(227,198,244)
        elif "orchid" in block_id: petal=(93,149,206); center=(230,226,184)
        elif "tulip" in block_id: petal=(225,98,118) if "red" not in block_id else (211,54,63); center=(248,187,160)
        else: petal=(193,57,68); center=(235,200,112)
        for x,y in [(7,1),(5,2),(6,2),(8,2),(9,2),(4,3),(5,3),(6,3),(7,3),(8,3),(9,3),(10,3),(5,4),(6,4),(7,4),(8,4),(9,4),(6,5),(7,5),(8,5)]: setpx(im,x,y,center if (x,y) in [(7,3),(7,4)] else petal)
        for x,y in [(6,9),(8,10),(5,12)]: setpx(im,x,y,light)
    elif "mushroom" in block_id:
        stem = (221, 202, 173)
        cap = (174, 61, 52) if "red" in block_id else (155, 108, 79)
        light_cap = mix(cap, (239, 213, 169), .38)
        if block_id == "shelf_mushrooms":
            # The cluster entry depicts a cluster, not a duplicate of either single cap.
            for x0, y0, w, h, col in [(1, 7, 5, 4, (144, 99, 74)), (5, 4, 6, 5, (189, 139, 98)), (10, 7, 5, 4, (126, 84, 65))]:
                d.rectangle((x0 + 1, y0 + h - 1, x0 + w - 1, 15), fill=(*stem, 255))
                d.rectangle((x0, y0, x0 + w, y0 + 2), fill=(*col, 255))
                d.rectangle((x0 + 1, y0 - 1, x0 + w - 1, y0), fill=(*mix(col, (226, 183, 133), .22), 255))
                setpx(im, x0 + max(1, w // 2), y0 + 1, mix(col, (238, 211, 171), .45))
        elif block_id == "shelf_mushroom_small":
            d.rectangle((7, 8, 8, 15), fill=(*stem, 255))
            d.rectangle((5, 5, 10, 8), fill=(*cap, 255))
            d.rectangle((6, 4, 9, 5), fill=(*light_cap, 255))
            setpx(im, 6, 6, mix(cap, (236, 209, 166), .48))
        elif block_id == "shelf_mushroom_large":
            d.rectangle((6, 7, 9, 15), fill=(*stem, 255))
            d.rectangle((2, 4, 13, 8), fill=(*cap, 255))
            d.rectangle((4, 2, 11, 5), fill=(*light_cap, 255))
            d.rectangle((6, 3, 9, 4), fill=(*cap, 255))
            for x, y in [(3, 5), (5, 4), (10, 4), (12, 6)]: setpx(im, x, y, mix(cap, (239, 212, 169), .35))
        else:
            d.rectangle((6, 7, 9, 15), fill=(*stem, 255))
            d.rectangle((3, 3, 12, 7), fill=(*cap, 255)); d.rectangle((5, 2, 10, 2), fill=(*light_cap, 255))
            for x, y in [(5, 4), (9, 3), (7, 6)]: setpx(im, x, y, (237, 220, 193))
    elif "crop" in block_id or block_id in ("wheat","carrot","potato","beetroot","wheat_seeds","beetroot_seeds","seeds"):
        if "wheat" in block_id:
            for x in (5,7,9): d.line((7,15,x,3+rng.randrange(4)),fill=(*dark,255))
            for x,y in [(5,4),(6,3),(7,5),(8,2),(9,4),(10,5),(6,6),(8,7)]:setpx(im,x,y,(190,163,73))
        elif "carrot" in block_id:
            d.line((7,13,4,3),fill=(*green,255)); d.line((7,13,10,2),fill=(*dark,255)); d.line((7,13,12,6),fill=(*light,255))
        else:
            for x,y in [(5,5),(8,3),(10,7),(4,9),(7,11),(11,12),(6,14)]:
                setpx(im,x,y,green); setpx(im,x+1,y,light)
            d.line((7,15,7,6),fill=(*dark,255))
    elif "grass" in block_id or "fern" in block_id or "leaf" in block_id:
        d.line((7,15,7,5),fill=(*dark,255))
        for y in range(5,15,2):
            side=rng.choice([-1,1]); x=7+side*rng.randrange(2,5)
            d.line((7,y,x,max(0,y-2)),fill=(*green,255))
            for q in range(2): setpx(im,x+q if x+q<16 else x,y-2,light)
    else:
        d.line((7,15,7,6),fill=(*dark,255))
        for x,y in [(5,8),(4,7),(6,6),(8,6),(9,5),(10,8),(6,11),(9,12)]:
            setpx(im,x,y,light if (x+y)%2==0 else green)


def item_icon(im, base, rng, block_id, definition):
    """Small transparent 16px inventory sprite for non-placeable item entries."""
    im.putdata([(0,0,0,0)]*256)
    d=ImageDraw.Draw(im)
    name=block_id.lower(); pattern=str(definition.get("pattern","item"))
    # Resource sprites remain original, chunky, and distinguishable at 16px.
    if any(k in name for k in ("pickaxe","axe","shovel","hoe","sword","flint_and_steel")):
        material=(139,91,48)
        if any(k in name for k in ("stone_",)): head=(119,121,124)
        elif any(k in name for k in ("iron_",)): head=(198,202,204)
        elif "gold" in name or "golden" in name: head=(240,190,43)
        elif "diamond" in name: head=(67,209,193)
        elif "netherite" in name: head=(78,67,72)
        else: head=(146,102,62)
        if "sword" in name:
            for i in range(9): setpx(im,3+i,11-i,head if i>1 else material)
            for x,y in [(4,11),(5,12),(6,13)]:setpx(im,x,y,material)
        elif "pickaxe" in name:
            for i in range(9): setpx(im,4+i,12-i,material)
            d.line((2,4,6,2,10,3,13,5),fill=(*head,255),width=2)
            setpx(im,5,4,shade(head,-20)); setpx(im,8,4,shade(head,14))
        elif "axe" in name:
            for i in range(9): setpx(im,4+i,12-i,material)
            d.polygon([(2,2),(8,2),(10,4),(8,7),(4,6),(3,4)],fill=(*head,255))
        elif "shovel" in name:
            for i in range(9): setpx(im,4+i,12-i,material)
            d.polygon([(2,1),(5,1),(7,3),(5,6),(3,5)],fill=(*head,255))
        else:
            d.line((4,3,11,12),fill=(*material,255),width=2); d.rectangle((3,2,7,6),fill=(*head,255))
    elif "apple" in name:
        d.ellipse((3,4,12,13),fill=(*rgb(definition.get("color")),255)); d.rectangle((7,2,8,5),fill=(91,62,35,255)); d.line((8,3,11,1),fill=(57,132,48,255),width=2)
        setpx(im,5,6,mix(rgb(definition.get("color")),(255,153,113),.42))
    elif "carrot" in name:
        d.polygon([(3,4),(12,4),(10,10),(7,15),(5,10)],fill=(230,121,33,255)); d.line((7,5,5,1),fill=(60,137,42,255),width=2);d.line((8,5,10,1),fill=(88,160,53,255),width=2)
    elif "potato" in name:
        d.ellipse((2,4,13,12),fill=(177,137,83,255));
        for x,y in [(5,6),(9,8),(7,10)]:setpx(im,x,y,(99,72,43))
    elif "bread" in name:
        d.polygon([(2,8),(4,4),(11,3),(14,7),(13,12),(4,13)],fill=(205,153,77,255));d.line((5,5,5,10),fill=(239,201,126,255));d.line((9,4,9,10),fill=(224,176,98,255))
    elif any(k in name for k in ("beef","porkchop","chicken","mutton","rabbit","steak","flesh")):
        cooked=any(k in name for k in ("cooked",))
        meat=(126,54,43) if not cooked else (105,54,35)
        d.polygon([(3,4),(6,3),(8,5),(12,4),(14,8),(11,12),(5,13),(2,9)],fill=(*meat,255))
        d.line((5,5,8,7,11,6),fill=(220,154,126,255) if not cooked else (184,130,78,255),width=2)
    elif "ingot" in name or name in ("iron_nugget","gold_nugget"):
        c=rgb(definition.get("color"), (180,180,180))
        if "iron" in name:c=(193,198,202)
        elif "copper" in name:c=(199,111,68)
        elif "gold" in name:c=(240,190,44)
        d.polygon([(2,5),(5,3),(12,3),(14,6),(12,12),(4,12)],fill=(*shade(c,-22),255))
        d.polygon([(3,5),(6,4),(12,4),(13,6),(11,10),(5,10)],fill=(*c,255));d.line((5,5,10,5),fill=(*shade(c,18),255))
    elif "diamond" in name or "emerald" in name or "ender_pearl" in name or "ghast_tear" in name or "nether_star" in name or name in ("quartz","amethyst_shard"):
        c=rgb(definition.get("color"),(89,206,189))
        d.polygon([(7,1),(12,4),(13,9),(8,14),(3,10),(3,5)],fill=(*shade(c,-22),255))
        d.polygon([(7,2),(10,4),(11,8),(8,11),(5,9),(5,5)],fill=(*c,255)); d.line((6,3,8,2,10,4),fill=(*shade(c,30),255))
    elif "bucket" in name:
        d.polygon([(3,4),(12,4),(11,13),(4,13)],fill=(164,172,181,255));d.line((4,4,5,2,10,2,12,4),fill=(202,207,211,255),width=1)
        if "water" in name:d.rectangle((5,7,10,11),fill=(48,108,200,255))
        if "lava" in name:d.rectangle((5,7,10,11),fill=(229,77,19,255));setpx(im,7,8,(255,174,43))
    elif "map" in name or "paper" in pattern or name in ("book","enchanting_book","name_tag"):
        d.polygon([(2,2),(12,1),(14,3),(13,14),(3,13)],fill=(222,207,158,255))
        if "map" in name:
            for path,c in [([(3,4),(6,3),(8,6),(12,4)],(93,140,75)), ([(4,10),(7,8),(11,11)],(58,116,173))]:d.line(path,fill=(*c,255),width=2)
            setpx(im,8,7,(188,73,52))
        elif "book" in name:
            d.line((5,2,5,13),fill=(141,91,51,255),width=1);d.line((7,4,11,4),fill=(167,135,87,255))
    elif "bone" in name or "bone_meal" in name:
        d.line((3,4,12,12),fill=(228,222,197,255),width=3)
        for x,y in [(2,3),(4,2),(11,12),(13,11)]:d.rectangle((x,y,x+1,y+1),fill=(228,222,197,255))
    elif "feather" in name:
        d.polygon([(3,13),(5,6),(11,2),(13,3),(11,9),(6,13)],fill=(225,224,214,255));d.line((3,14,12,3),fill=(144,143,132,255))
    elif "string" in name or "tripwire" in name:
        d.line((3,13,5,10,4,7,8,4,10,7,13,2),fill=(222,219,202,255),width=1)
    elif "bow" in name:
        d.line((4,2,10,4,12,8,10,12,4,14),fill=(133,86,43,255),width=2);d.line((4,2,4,14),fill=(223,213,190,255))
    elif "shield" in name:
        d.polygon([(3,2),(12,2),(13,8),(8,14),(3,8)],fill=(129,88,53,255));d.line((4,4,11,4),fill=(194,159,102,255))
    elif "egg" in name:
        d.ellipse((4,2,11,14),fill=(228,222,200,255));setpx(im,6,5,(245,240,222))
    elif "feather" in name: d.line((4,13,12,3),fill=(231,231,222,255),width=2)
    elif "slime" in name:
        d.rectangle((3,4,12,12),fill=(99,198,85,255));d.rectangle((5,6,6,7),fill=(42,89,40,255));d.rectangle((9,6,10,7),fill=(42,89,40,255));d.line((6,10,9,10),fill=(42,89,40,255))
    elif "blaze_powder" in name or "fire_charge" in name:
        c=(233,153,38) if "blaze" in name else (229,86,33)
        d.polygon([(7,1),(10,5),(13,6),(11,10),(9,14),(4,12),(3,8)],fill=(*c,255));d.point((8,7),fill=(255,220,87,255))
    elif "seed" in name:
        for x,y in [(4,5),(8,3),(11,7),(6,10),(10,12)]:d.point((x,y),fill=(96,130,53,255));d.point((x+1,y),fill=(159,179,73,255))
    else:
        # Readable material-specific silhouette, fall back to a neat square swatch only for unknown items.
        c=rgb(definition.get("color"),tuple(base))
        if pattern in ("food","meat"):d.polygon([(3,5),(8,3),(13,6),(12,11),(6,13),(2,9)],fill=(*c,255))
        elif pattern in ("crystal","glow"):d.polygon([(7,2),(12,5),(11,10),(7,14),(4,10),(3,5)],fill=(*c,255))
        else:
            d.polygon([(3,3),(12,2),(14,6),(12,13),(4,12),(2,7)],fill=(*c,255))
            d.line((4,4,10,3),fill=(*shade(c,22),255))


def target_texture(im, base, rng):
    d=ImageDraw.Draw(im)
    d.rectangle((0,0,15,15),fill=(*shade(base,-13),255))
    d.rectangle((1,1,14,14),fill=(183,53,43,255))
    d.rectangle((3,3,12,12),fill=(225,218,197,255))
    d.rectangle((5,5,10,10),fill=(183,53,43,255))
    d.rectangle((7,7,8,8),fill=(225,218,197,255))
    if rng.random()<.6:setpx(im,14,2,shade(base,15))


def portal_texture(im: Image.Image, base, rng: random.Random, block_id: str, face: str) -> None:
    """Distinct portal fields; opaque pixel art with a readable moving-surface motif."""
    d = ImageDraw.Draw(im)
    if block_id == "nether_portal":
        dark = (34, 12, 62)
        purple = (91, 37, 145)
        magenta = (156, 61, 194)
        cyan = (83, 105, 203)
        im.paste((*dark, 255), (0, 0, 16, 16))
        # Narrow diagonal bands imply the characteristic purple portal swirl.
        for y in range(16):
            for x in range(16):
                wave = (x * 2 + y + (2 if face == "top" else 0)) % 9
                if wave in (0, 1, 2): setpx(im, x, y, mix(purple, magenta, wave / 3), 245)
                elif wave in (5, 6): setpx(im, x, y, mix(dark, cyan, .45), 238)
        d.line([(0, 12), (4, 9), (7, 10), (10, 6), (15, 4)], fill=(*magenta, 255), width=2)
        d.line([(0, 14), (5, 11), (8, 12), (12, 8), (15, 7)], fill=(*purple, 255), width=1)
        for _ in range(7):
            x, y = rng.randrange(16), rng.randrange(16)
            setpx(im, x, y, rng.choice([magenta, cyan, (202, 111, 222)]), 255)
    else:
        dark = (8, 7, 18)
        im.paste((*dark, 255), (0, 0, 16, 16))
        for _ in range(34):
            x, y = rng.randrange(16), rng.randrange(16)
            c = rng.choice([(37, 25, 62), (44, 58, 101), (85, 52, 126), (90, 143, 154), (52, 102, 127)])
            setpx(im, x, y, c, 255)
        d.line([(1, 12), (4, 9), (6, 10), (9, 6), (11, 7), (15, 2)], fill=(47, 78, 125, 255), width=2)
        setpx(im, 7, 7, (148, 203, 198))


def rail_texture(im: Image.Image, base, rng: random.Random, block_id: str, face: str) -> None:
    """Transparent track texture with sleepers and rail-specific colour accents."""
    im.putdata([(0, 0, 0, 0)] * (TILE * TILE))
    if face not in ("top", "front"):
        # Edge swatches only retain the thin rail profile; no opaque square background.
        d = ImageDraw.Draw(im)
        rail_color = (173, 171, 160, 255)
        d.line((0, 6, 15, 6), fill=(72, 68, 60, 255), width=3)
        d.line((0, 8, 15, 8), fill=rail_color, width=1)
        return
    d = ImageDraw.Draw(im)
    wood = (91, 61, 38, 255)
    wood_hi = (139, 95, 55, 255)
    metal = (99, 101, 102, 255)
    metal_hi = (205, 202, 190, 255)
    powered = block_id == "powered_rail"
    activator = block_id == "activator_rail"
    detector = block_id == "detector_rail"
    for y in (1, 5, 9, 13):
        d.rectangle((1, y, 14, min(15, y + 1)), fill=wood)
        d.line((2, y, 13, y), fill=wood_hi, width=1)
    for x in (3, 12):
        d.line((x, 0, x, 15), fill=(47, 46, 43, 255), width=3)
        d.line((x, 0, x, 15), fill=metal, width=2)
        d.line((x, 0, x, 15), fill=metal_hi, width=1)
    if powered:
        d.line((7, 1, 7, 14), fill=(156, 51, 24, 255), width=2)
        for y in (3, 7, 11): setpx(im, 7, y, (246, 86, 35), 255)
    elif activator:
        for y in (2, 6, 10, 14):
            d.rectangle((6, y, 9, min(15, y + 1)), fill=(138, 43, 28, 255))
            setpx(im, 8, y, (221, 85, 38), 255)
    elif detector:
        d.rectangle((5, 4, 10, 11), fill=(107, 78, 51, 255))
        d.rectangle((6, 5, 9, 10), fill=(155, 113, 66, 255))
        d.line((6, 7, 9, 7), fill=(212, 180, 112, 255))


def redstone_dust_texture(im: Image.Image, rng: random.Random, block_id: str, face: str) -> None:
    """Alpha-only wire swatch so dust doesn't render as an opaque coloured square."""
    im.putdata([(0, 0, 0, 0)] * (TILE * TILE))
    d = ImageDraw.Draw(im)
    powered = face.startswith("powered_")
    dark = (91, 15, 18, 255) if powered else (87, 17, 21, 255)
    red = (255, 80, 49, 255) if powered else (173, 31, 33, 255)
    hot = (255, 175, 95)
    if face.endswith("top"):
        # Branching redstone trace and a few tiny dust clumps; background remains alpha 0.
        paths = [
            [(0, 11), (3, 11), (3, 7), (7, 7), (7, 3), (11, 3), (11, 8), (15, 8)],
            [(3, 11), (5, 13), (9, 13), (11, 15)],
            [(7, 7), (9, 6), (12, 6), (14, 4)],
        ]
        for path in paths: d.line(path, fill=dark, width=3)
        for path in paths: d.line(path, fill=red, width=1 if not powered else 2)
        for x, y in [(3, 11), (7, 7), (11, 3), (11, 8)]:
            setpx(im, x, y, hot if powered else red[:3], 255)
        if powered:
            for x, y in [(5, 12), (8, 7), (12, 6)]: setpx(im, x, y, hot, 255)
    else:
        # The 3D dust plate has thin edges; only one-pixel traces should be visible there.
        y = 7 if face.endswith("side") else 14
        d.line((0, y, 15, y), fill=dark, width=2)
        d.line((0, y, 15, y), fill=red, width=1)


def soul_texture(im: Image.Image, base, rng: random.Random, block_id: str, face: str) -> None:
    """Soul sand's fossil-like top and soul soil's ash/blue embers differ clearly."""
    noise_clusters(im, base, rng, 7 if block_id == "soul_sand" else 9, 2, .45)
    d = ImageDraw.Draw(im)
    if block_id == "soul_sand" and face == "top":
        pale = (119, 89, 72, 255)
        dark = (30, 24, 23, 255)
        # Fossil/faces embedded in the sand rather than generic stone flecks.
        d.rectangle((2, 3, 6, 6), fill=pale); d.rectangle((9, 2, 13, 5), fill=pale)
        d.rectangle((3, 4, 4, 5), fill=dark); d.rectangle((10, 3, 11, 4), fill=dark)
        d.line((2, 8, 5, 10, 8, 9, 12, 11, 14, 9), fill=(*shade(base, -23), 255), width=2)
        for _ in range(14): setpx(im, rng.randrange(16), rng.randrange(16), rng.choice([shade(base, -10), shade(base, 12)]))
    elif block_id == "soul_soil":
        dark = (31, 27, 28)
        d.line((0, 4, 4, 6, 6, 3, 10, 5, 15, 2), fill=(*dark, 255), width=1)
        d.line((1, 12, 5, 10, 9, 13, 13, 10, 15, 12), fill=(*shade(base, -18), 255), width=1)
        for _ in range(7):
            x, y = rng.randrange(16), rng.randrange(16)
            setpx(im, x, y, rng.choice([(34, 103, 126), (52, 149, 163), (72, 63, 57)]))
    else:
        # Horizontally layered edges distinguish the sides from the marked top.
        for y in (3, 7, 12): d.line((0, y, 15, y), fill=(*shade(base, -13), 255), width=1)
        for _ in range(12): setpx(im, rng.randrange(16), rng.randrange(16), shade(base, rng.choice([-17, 11])))


def directional_texture(block_id: str, face: str, base, rng: random.Random) -> Image.Image | None:
    """Authored per-block front/back sprites for blocks with meaningful orientation."""
    if face not in ("front", "back"):
        return None
    im = Image.new("RGBA", (16, 16), (*base, 255))
    d = ImageDraw.Draw(im)
    name = block_id
    if name == "crafting_table":
        noise_clusters(im, base, rng, 6, 2, .25)
        plank_dark = shade(base, -28)
        for x in (1, 5, 9, 13): d.line((x, 0, x, 15), fill=(*plank_dark, 255))
        tool_dark = (67, 45, 28, 255)
        tool_light = (206, 182, 132, 255)
        if face == "front":
            # Hammer head, handle and saw teeth for the workbench side.
            d.line((2, 11, 7, 6), fill=tool_dark, width=2)
            d.line((5, 4, 10, 4), fill=tool_light, width=3)
            d.line((7, 4, 7, 12), fill=tool_dark, width=1)
            for x in (10, 12, 14): d.line((x, 9, x - 1, 13), fill=tool_light, width=1)
        else:
            d.line((2, 5, 13, 5), fill=tool_light, width=2)
            d.line((3, 4, 12, 9), fill=tool_dark, width=2)
            d.line((12, 8, 13, 13), fill=tool_dark, width=2)
            for x in (3, 6, 9, 12): setpx(im, x, 5, (230, 211, 159))
        return im

    if name in ("furnace", "dispenser", "dropper", "observer"):
        noise_clusters(im, base, rng, 7, 2, .45)
        outline = shade(base, -30)
        d.rectangle((1, 1, 14, 14), outline=(*outline, 255))
        if name == "furnace":
            if face == "front":
                d.rectangle((3, 4, 12, 12), fill=(45, 42, 39, 255))
                d.rectangle((4, 5, 11, 11), fill=(18, 18, 17, 255))
                d.rectangle((5, 10, 10, 11), fill=(99, 49, 26, 255))
                setpx(im, 7, 10, (171, 73, 27)); setpx(im, 8, 10, (133, 46, 22))
            else:
                d.line((2, 4, 13, 4), fill=(*shade(base, 9), 255))
                d.line((3, 11, 12, 11), fill=(*shade(base, -14), 255))
        elif name in ("dispenser", "dropper"):
            d.rectangle((3, 3, 12, 12), fill=(47, 46, 43, 255))
            d.rectangle((4, 4, 11, 11), outline=(137, 136, 128, 255), width=1)
            if name == "dispenser":
                d.rectangle((6, 6, 9, 9), fill=(29, 29, 27, 255))
                setpx(im, 7, 6, (180, 179, 167)); setpx(im, 8, 9, (78, 77, 71))
            else:
                d.rectangle((5, 5, 10, 10), fill=(39, 39, 38, 255))
                d.rectangle((7, 7, 8, 8), fill=(16, 16, 16, 255))
        else:  # observer output and detection faces
            d.rectangle((3, 3, 12, 12), fill=(46, 44, 43, 255))
            if face == "back":
                d.rectangle((5, 5, 10, 10), fill=(120, 30, 28, 255))
                d.rectangle((6, 6, 9, 9), fill=(197, 44, 38, 255))
                setpx(im, 7, 7, (255, 99, 73))
            else:
                d.rectangle((5, 5, 10, 10), fill=(24, 23, 22, 255))
                d.rectangle((6, 6, 9, 9), fill=(65, 68, 63, 255))
                d.line((6, 8, 9, 8), fill=(109, 111, 103, 255))
        return im
    if name in ("chest", "barrel", "shulker_box"):
        noise_clusters(im, base, rng, 4, 2, .22)
        if name == "shulker_box":
            edge = shade(base, -35); hi = shade(base, 21)
            d.rectangle((1, 1, 14, 14), fill=(*shade(base, -10), 255), outline=(*edge, 255))
            d.rectangle((3, 3, 12, 12), outline=(*hi, 255))
            d.line((3, 7, 12, 7), fill=(*edge, 255))
            if face == "front": d.rectangle((7, 7, 8, 9), fill=(224, 206, 161, 255))
        else:
            edge = shade(base, -28)
            d.rectangle((1, 2, 14, 14), outline=(*edge, 255))
            if name == "barrel":
                d.line((3, 2, 3, 14), fill=(*shade(base, -19), 255), width=2)
                d.line((12, 2, 12, 14), fill=(*shade(base, -19), 255), width=2)
                d.line((1, 5, 14, 5), fill=(*shade(base, -7), 255))
                d.line((1, 11, 14, 11), fill=(*shade(base, -7), 255))
            else:
                d.line((2, 5, 13, 5), fill=(*shade(base, -17), 255))
                d.line((2, 11, 13, 11), fill=(*shade(base, -14), 255))
                if face == "front":
                    d.rectangle((6, 6, 9, 9), fill=(184, 145, 65, 255))
                    setpx(im, 7, 7, (239, 208, 121))
        return im
    if name in ("oak_door", "iron_door", "poplar_door"):
        noise_clusters(im, base, rng, 4 if name != "iron_door" else 3, 2, .18)
        if name == "iron_door":
            for x in (2, 6, 10, 13):
                d.line((x, 0, x, 15), fill=(*shade(base, -19), 255), width=1)
            for y in (1, 7, 14): d.line((0, y, 15, y), fill=(*shade(base, 8), 255), width=1)
            d.rectangle((8, 6, 10, 10), fill=(76, 78, 76, 255))
            setpx(im, 9, 8, (210, 184, 105))
        else:
            dark = shade(base, -27); light = shade(base, 11)
            d.rectangle((1, 0, 14, 15), outline=(*dark, 255))
            for x in (4, 8, 12): d.line((x, 1, x, 14), fill=(*dark, 255))
            if name == "oak_door":
                d.rectangle((2, 2, 6, 6), outline=(*light, 255))
                d.rectangle((9, 2, 13, 6), outline=(*light, 255))
                d.rectangle((2, 9, 6, 13), outline=(*light, 255))
                d.rectangle((9, 9, 13, 13), outline=(*light, 255))
            else:
                d.rectangle((2, 2, 13, 13), outline=(*light, 255))
                d.line((2, 7, 13, 7), fill=(*dark, 255))
                d.line((8, 2, 8, 13), fill=(*dark, 255))
            if face == "front":
                d.rectangle((12, 7, 13, 9), fill=(202, 162, 74, 255))
        return im
    if name in ("jack_o_lantern", "carved_pumpkin"):
        noise_clusters(im, base, rng, 6, 2, .28)
        for x in (2, 6, 10, 14):
            d.line((x, 0, x, 15), fill=(*shade(base, -19), 255))
            if x > 0: d.line((x-1, 0, x-1, 15), fill=(*shade(base, 8), 255))
        if face == "front":
            cut = (245, 194, 59, 255) if name == "jack_o_lantern" else (38, 27, 17, 255)
            d.polygon([(3, 4), (6, 5), (7, 8), (4, 7)], fill=cut)
            d.polygon([(9, 5), (12, 4), (12, 7), (9, 8)], fill=cut)
            d.polygon([(5, 10), (7, 9), (9, 10), (11, 9), (10, 12), (6, 12)], fill=cut)
            if name == "jack_o_lantern":
                setpx(im, 5, 5, (255, 227, 102)); setpx(im, 10, 5, (255, 227, 102))
        return im
    if name in ("piston", "sticky_piston"):
        noise_clusters(im, base, rng, 7, 2, .35)
        d.rectangle((1, 1, 14, 14), outline=(44, 43, 39, 255))
        if face == "front":
            d.rectangle((3, 3, 12, 12), fill=(119, 82, 46, 255) if name == "piston" else (86, 139, 64, 255))
            d.rectangle((4, 4, 11, 11), outline=(174, 125, 68, 255) if name == "piston" else (156, 207, 106, 255))
            for x in (5, 8, 11): d.line((x, 4, x, 11), fill=(85, 60, 37, 255) if name == "piston" else (56, 105, 43, 255))
        else:
            d.rectangle((3, 3, 12, 12), fill=(94, 92, 82, 255))
            d.line((4, 5, 11, 5), fill=(164, 162, 148, 255))
            d.line((4, 10, 11, 10), fill=(63, 62, 56, 255))
            if name == "sticky_piston":
                setpx(im, 7, 7, (94, 155, 66)); setpx(im, 8, 8, (66, 129, 51))
        return im
    return None


def make_texture(block_id: str, defn: dict, face: str) -> Image.Image:
    rng=rng_for(block_id,face)
    pattern=str(defn.get("pattern","stone")).lower()
    shape=str(defn.get("shape","cube")).lower()
    actual_face=face
    for prefix in ("powered_","lit_"):
        if actual_face.startswith(prefix): actual_face=actual_face[len(prefix):]
    if actual_face=="eye_top": actual_face="top"
    if actual_face not in ("top","side","bottom","front"): actual_face="side"
    color_field={"top":"top_color","bottom":"bottom_color","side":"side_color","front":"side_color"}[actual_face]
    base=rgb(defn.get(color_field,defn.get("color","#808080")))
    if face.startswith("lit_"):
        base=mix(base,(255,179,65),.47)
    elif face.startswith("powered_"):
        base=mix(base,(255,38,26),.68)
    im=Image.new("RGBA",(16,16),(*base,255))
    name=block_id.lower()

    # Non-placeable entries are inventory sprites, except portal field blocks,
    # which must remain world textures despite not being inventory-placeable.
    if not bool(defn.get("placeable",False)) and shape != "portal":
        item_icon(im,base,rng,block_id,defn)
        return im

    if shape == "portal" or name in ("nether_portal", "end_portal"):
        portal_texture(im, base, rng, name, face)
        return im

    directional = directional_texture(name, face, base, rng)
    if directional is not None:
        return directional

    # Redstone lamps have a distinct inset glass panel; the prior material
    # metadata labelled the unlit lamp as stone, which incorrectly bypassed glow art.
    if name == "redstone_lamp":
        lit = face.startswith("lit_")
        d = ImageDraw.Draw(im)
        dark = (66, 47, 32) if not lit else (124, 73, 35)
        frame = (112, 78, 45) if not lit else (171, 112, 49)
        pane = (139, 103, 61) if not lit else (255, 207, 93)
        hot = (172, 132, 73) if not lit else (255, 244, 157)
        noise_clusters(im, base, rng, 4 if not lit else 8, 2, .25)
        d.rectangle((0, 0, 15, 15), fill=(*dark, 255))
        d.rectangle((1, 1, 14, 14), fill=(*frame, 255))
        d.rectangle((2, 2, 13, 13), fill=(*dark, 255))
        d.rectangle((3, 3, 12, 12), fill=(*pane, 255))
        for y in (4, 7, 10):
            for x in (4, 7, 10):
                color = hot if lit or rng.random() < .42 else shade(pane, -17)
                d.rectangle((x, y, x + 1, y + 1), fill=(*color, 255))
        if lit:
            for x, y in [(3, 3), (12, 3), (3, 12), (12, 12)]: setpx(im, x, y, (255, 240, 150))
        return im

    # Alpha sprites for redstone wire, rails and tripwire must not become
    # opaque coloured squares when assigned to a thin plane/crossed quad.
    if name == "redstone_dust" or shape == "redstone_dust":
        redstone_dust_texture(im, rng, name, face)
        return im
    if name == "tripwire":
        im.putdata([(0, 0, 0, 0)] * (TILE * TILE))
        d = ImageDraw.Draw(im)
        string = (203, 198, 174, 255)
        shadow = (65, 61, 50, 220)
        y = 8 if face in ("side", "top") else 9
        d.line((0, y + 1, 15, y + 1), fill=shadow, width=1)
        d.line((0, y, 15, y), fill=string, width=1)
        for x in (2, 7, 12): setpx(im, x, y - 1, (229, 222, 195), 245)
        return im
    if shape == "rail" or name.endswith("_rail") or name == "rail":
        rail_texture(im, base, rng, name, face)
        return im

    if name in ("soul_sand", "soul_soil"):
        soul_texture(im, base, rng, name, actual_face)
        return im

    if name == "end_portal_frame" and actual_face == "top" and face != "eye_top":
        d = ImageDraw.Draw(im)
        rim = (57, 91, 78)
        rim_hi = (94, 140, 116)
        stone = (155, 160, 132)
        d.rectangle((0, 0, 15, 15), fill=(*shade(rim, -18), 255))
        d.rectangle((1, 1, 14, 14), fill=(*rim, 255))
        d.rectangle((2, 2, 13, 13), fill=(*rim_hi, 255))
        d.rectangle((4, 4, 11, 11), fill=(*stone, 255))
        d.rectangle((5, 5, 10, 10), fill=(*shade(stone, -13), 255))
        d.rectangle((6, 6, 9, 9), fill=(*stone, 255))
        for x, y in [(2, 2), (13, 3), (3, 13), (12, 12)]: setpx(im, x, y, shade(rim_hi, 18))
        return im

    if face=="eye_top" or (name=="end_portal_frame" and actual_face=="top" and False):
        d=ImageDraw.Draw(im)
        d.rectangle((0,0,15,15),fill=(*shade(base,-13),255))
        d.rectangle((2,2,13,13),fill=(*shade(base,9),255))
        d.rectangle((4,4,11,11),fill=(39,67,55,255))
        d.rectangle((6,5,9,10),fill=(80,208,141,255));setpx(im,8,7,(224,246,194))
        return im

    if shape=="plant" or pattern in ("flower","plant"):
        # Shape is transparent; generator uses the catalogue face colour as the foliage palette.
        plant_base=base
        if name in ("short_grass","oak_sapling","birch_sapling","spruce_sapling","poplar_sapling","red_shrub"):
            plant_base=rgb(defn.get("color",defn.get("top_color","#5c913b")))
        plant_texture(im,plant_base,rng,block_id,pattern)
        return im
    if shape=="leaf_litter" or pattern=="leaf_litter":
        im.putdata([(0,0,0,0)]*256); d=ImageDraw.Draw(im)
        colors=[base,shade(base,-18),shade(base,18),(174,124,55),(118,82,44)]
        for leaf in range(13):
            x,y=rng.randrange(1,14),rng.randrange(2,13)
            color=rng.choice(colors)
            d.line((x,y,min(15,x+2),max(0,y-1)),fill=(*color,255),width=1)
            setpx(im,x,y,color)
        return im
    if shape=="fluid" or pattern in ("water","lava"):
        fluid_texture(im,base,rng,block_id,actual_face);return im
    if pattern in ("grass","grass_side") or name in ("grass_block","podzol","mycelium"):
        if name=="grass_block":
            if actual_face=="top": grass_top(im,base,rng,name)
            elif actual_face=="bottom": dirt(im,rgb(defn.get("bottom_color")),rng,"dirt",actual_face)
            else: grass_side(im,rgb(defn.get("side_color")),rgb(defn.get("top_color")),rng,name)
        elif name in ("podzol","mycelium"):
            if actual_face=="top":
                noise_clusters(im,base,rng,9,2,.54)
                if name=="podzol":
                    for _ in range(25):
                        x,y=rng.randrange(16),rng.randrange(16)
                        c=rng.choice([(112,78,42),(143,91,45),(84,65,39),(168,120,56)])
                        setpx(im,x,y,c)
                    d=ImageDraw.Draw(im);d.line((3,4,6,5,8,3),fill=(77,56,36,255))
                else:
                    spore=shade(base,20); dark=shade(base,-17)
                    for _ in range(22):setpx(im,rng.randrange(16),rng.randrange(16),rng.choice([spore,dark]))
            elif actual_face=="bottom": dirt(im,rgb(defn.get("bottom_color")),rng,"dirt",actual_face)
            else: grass_side(im,rgb(defn.get("side_color")),base,rng,name)
        else:
            noise_clusters(im,base,rng,9,2,.45)
        return im

    if pattern.startswith("ore_") or name.endswith("_ore") or "_ore_" in name:
        ore_texture(im,base,rng,block_id);return im
    if name.endswith("_log") or name.endswith("_wood") or pattern in ("log","birch_log","poplar_log") or "crimson_stem" in name or "warped_stem" in name:
        log_texture(im,base,rng,actual_face,block_id);return im
    if "leaves" in name or pattern in ("leaves","autumn_leaves","poplar_leaves"):
        leaf_texture(im,base,rng,block_id);return im
    if name in ("chest", "barrel", "shulker_box"):
        if name == "chest":
            noise_clusters(im, base, rng, 5, 2, .22)
            d = ImageDraw.Draw(im)
            edge = shade(base, -29)
            d.rectangle((1, 1, 14, 14), outline=(*edge, 255))
            if actual_face == "top":
                d.rectangle((2, 2, 13, 13), fill=(*shade(base, 8), 255))
                d.line((2, 4, 13, 4), fill=(*shade(base, -13), 255))
                d.line((2, 11, 13, 11), fill=(*shade(base, -16), 255))
                for x in (3, 12): d.rectangle((x, 2, x + 1, 3), fill=(197, 160, 77, 255))
            elif actual_face == "bottom":
                d.rectangle((2, 2, 13, 13), fill=(*shade(base, -8), 255))
                d.line((2, 8, 13, 8), fill=(*shade(base, -22), 255))
            else:
                d.line((2, 5, 13, 5), fill=(*shade(base, -17), 255))
                d.line((2, 11, 13, 11), fill=(*shade(base, -14), 255))
        elif name == "barrel":
            if actual_face in ("top", "bottom"):
                log_texture(im, base, rng, actual_face, "oak_log")
                d = ImageDraw.Draw(im)
                d.rectangle((1, 1, 14, 14), outline=(71, 49, 30, 255))
                d.rectangle((3, 3, 12, 12), outline=(148, 105, 57, 255))
            else:
                noise_clusters(im, base, rng, 5, 2, .20)
                d = ImageDraw.Draw(im)
                for x in (1, 2, 13, 14): d.line((x, 0, x, 15), fill=(*shade(base, -22), 255))
                for y in (3, 12):
                    d.rectangle((0, y, 15, y + 1), fill=(69, 65, 58, 255))
                    d.line((0, y, 15, y), fill=(166, 155, 125, 255))
                for y in (6, 9): d.line((3, y, 12, y), fill=(*shade(base, -12), 255))
        else:
            noise_clusters(im, base, rng, 5, 2, .18)
            d = ImageDraw.Draw(im)
            shell = shade(base, -22)
            d.rectangle((1, 1, 14, 14), outline=(*shell, 255))
            d.rectangle((3, 3, 12, 12), outline=(*shade(base, 14), 255))
            if actual_face == "top": d.rectangle((4, 4, 11, 11), fill=(*shade(base, -7), 255))
            elif actual_face == "bottom": d.rectangle((3, 5, 12, 10), fill=(*shell, 255))
            else: d.line((2, 7, 13, 7), fill=(*shell, 255))
        return im

    if name == "crafting_table":
        if actual_face == "top":
            noise_clusters(im, base, rng, 7, 2, .27)
            d = ImageDraw.Draw(im)
            d.rectangle((0, 0, 15, 15), outline=(*shade(base, -31), 255), width=2)
            d.rectangle((2, 2, 13, 13), fill=(*shade(base, -11), 255))
            for x in (5, 9): d.line((x, 3, x, 12), fill=(72, 49, 29, 255), width=1)
            for y in (5, 9): d.line((3, y, 12, y), fill=(72, 49, 29, 255), width=1)
            for x, y in [(3,3),(7,3),(11,3),(3,7),(7,7),(11,7),(3,11),(7,11),(11,11)]:
                d.rectangle((x, y, x + 1, y + 1), fill=(*shade(base, 9), 255))
        elif actual_face == "bottom":
            planks(im, base, rng, "oak_planks", actual_face)
        else:
            planks(im, base, rng, "oak_planks", "side")
            d = ImageDraw.Draw(im)
            dark = (64, 43, 27, 255)
            tool = (195, 173, 128, 255)
            # Distinct pixel-art saw/pick tools on the two long sides.
            if face == "side":
                d.line((2, 12, 7, 5, 12, 7), fill=dark, width=2)
                d.line((4, 10, 8, 4), fill=tool, width=1)
                d.line((9, 4, 14, 4), fill=tool, width=2)
                d.line((11, 4, 11, 12), fill=dark, width=1)
                d.line((1, 14, 6, 14), fill=dark, width=1)
        return im
    if name == "daylight_detector":
        if actual_face == "top":
            noise_clusters(im, base, rng, 5, 2, .22)
            d = ImageDraw.Draw(im)
            d.rectangle((0, 0, 15, 15), outline=(*shade(base, -28), 255), width=2)
            d.rectangle((2, 2, 13, 13), fill=(66, 87, 91, 255))
            for y in (3, 6, 9, 12):
                for x in (3, 6, 9, 12):
                    col = rng.choice([(116, 145, 143), (145, 166, 155), (79, 113, 119), (184, 173, 132)])
                    d.rectangle((x, y, x + 1, y + 1), fill=(*col, 255))
        else:
            planks(im, base, rng, "oak_planks", actual_face)
            d = ImageDraw.Draw(im)
            d.line((0, 2, 15, 2), fill=(*shade(base, -18), 255))
        return im

    if pattern in ("planks","bookshelf") or name.endswith("_planks"):
        bookshelf = pattern == "bookshelf" or name.startswith("bookshelf")
        planks(im,base,rng,"oak_planks" if bookshelf else block_id,actual_face)
        if bookshelf and actual_face not in ("top", "bottom"):
            d=ImageDraw.Draw(im); shelf=shade(base,-24)
            for y in (1,6,11):
                d.line((0,y,15,y),fill=(*shelf,255))
                for x in (1,5,9,13):
                    c=rng.choice([(135,57,43),(45,72,132),(65,107,54),(173,119,57),(117,75,134)])
                    d.rectangle((x,y+1,min(15,x+2),min(15,y+4)),fill=(*c,255))
        return im
    if pattern in ("cobble","mossy_cobble","stone","bedrock","gravel","sandstone","soul_sand"):
        kind=pattern
        if name=="cobbled_deepslate":kind="cobble"
        rocky(im,base,rng,kind,block_id)
        if name in ("blackstone","calcite","dripstone_block","tuff","polished_andesite","polished_diorite","polished_granite"):
            # Material-specific grain makes these stone families recognizable without changing IDs.
            if name=="blackstone": flecks(im,base,rng,12,(-20,-8),(4,10))
            elif name=="calcite":
                for _ in range(24):setpx(im,rng.randrange(16),rng.randrange(16),rng.choice([shade(base,-7),shade(base,8),(233,231,221)]))
            elif name=="dripstone_block":
                d=ImageDraw.Draw(im)
                for y in (3,8,13):d.line((0,y,15,y),fill=(*shade(base,-18),255))
                for _ in range(8):setpx(im,rng.randrange(16),rng.randrange(16),shade(base,rng.choice([-18,11])))
        return im
    if pattern in ("sand","powder") or "sand" in name:
        sand(im,base,rng,"red_sand" in name);return im
    if pattern in ("dirt","roots","mud") or "dirt" in name:
        dirt(im,base,rng,block_id,actual_face);return im
    if pattern in ("brick","cracked_brick","mossy_brick","terracotta") or name in ("tnt","nether_bricks","packed_mud"):
        if name in ("terracotta",) or pattern=="terracotta":
            noise_clusters(im,base,rng,4,2,.24);flecks(im,base,rng,5,(-7,-3),(4,7),(1,))
            return im
        brick_texture(im,base,rng,block_id,actual_face);return im
    if pattern in ("metal",) or name.endswith("_block") and any(x in name for x in ("iron","gold","diamond","emerald","copper","redstone")):
        metal_block(im,base,rng,block_id,actual_face);return im
    if pattern=="crystal" or name in ("amethyst_block","quartz_block","nether_star"):
        crystal_texture(im,base,rng,block_id);return im
    if pattern=="glow" or name in ("glowstone","sea_lantern","shroomlight","redstone_lamp"):
        noise_clusters(im,base,rng,13,2,.5)
        d=ImageDraw.Draw(im)
        bright=mix(base,(255,239,155),.48)
        for _ in range(18):
            x,y=rng.randrange(16),rng.randrange(16)
            setpx(im,x,y,shade(bright,rng.randint(-10,13)))
        if face.startswith("lit_"):
            for _ in range(25):setpx(im,rng.randrange(16),rng.randrange(16),mix(base,(255,246,174),rng.uniform(.45,.8)))
        return im
    if pattern=="pumpkin" or "pumpkin" in name or name=="jack_o_lantern":
        noise_clusters(im,base,rng,7,2,.35)
        d=ImageDraw.Draw(im)
        if actual_face in ("top","bottom"):
            d.rectangle((2,2,13,13),outline=(*shade(base,-13),255))
            d.rectangle((6,6,9,9),fill=(68,104,40,255))
        else:
            for x in (2,6,10,14):
                d.line((x,0,x,15),fill=(*shade(base,-17),255))
                if x>0:d.line((x-1,0,x-1,15),fill=(*shade(base,7),255))
            if name in ("jack_o_lantern","carved_pumpkin"):
                d.polygon([(3,5),(6,4),(7,7),(4,7)],fill=(31,25,15,255));d.polygon([(9,4),(12,5),(11,7),(9,7)],fill=(31,25,15,255))
                d.rectangle((5,9,10,10),fill=(35,27,15,255))
        return im
    if pattern in ("wool","cushion") or name.startswith("wool_"):
        wool_texture(im,base,rng,block_id);return im
    if pattern=="concrete" or name.startswith("concrete_"):
        noise_clusters(im,base,rng,2,2,.12)
        return im
    if pattern in ("clay",):
        noise_clusters(im,base,rng,5,2,.35);flecks(im,base,rng,5,(-7,-3),(3,7),(1,));return im
    if pattern in ("deepslate","basalt","netherrack","endstone","magma","obsidian","ancient_debris") or any(k in name for k in ("deepslate","basalt","netherrack","end_stone","magma_block","obsidian","ancient_debris")):
        if pattern=="deepslate" or "deepslate" in name:
            noise_clusters(im,base,rng,7,2,.32);d=ImageDraw.Draw(im)
            for y in (3,7,12):
                shift=rng.randrange(3);d.line((shift,y,15,y),fill=(*shade(base,-17),255));d.line((0,min(15,y+1),max(0,shift-2),min(15,y+1)),fill=(*shade(base,7),255))
        elif pattern=="basalt" or "basalt" in name:
            noise_clusters(im,base,rng,5,2,.22);d=ImageDraw.Draw(im)
            for x in (2,6,11,14):d.line((x,0,x,15),fill=(*shade(base,-17),255));
            for x in (3,7,12):d.line((x,0,x,15),fill=(*shade(base,7),255))
        elif pattern=="netherrack" or "netherrack" in name:
            noise_clusters(im,base,rng,13,2,.6);flecks(im,base,rng,14,(-29,-15),(15,22),(1,2))
        elif pattern=="endstone" or "end_stone" in name:
            noise_clusters(im,base,rng,7,2,.48);flecks(im,base,rng,8,(-15,-6),(8,15),(1,2))
        elif pattern=="magma" or "magma_block" in name:
            dark=mix(base,(28,20,18),.65);noise_clusters(im,dark,rng,5,2,.22);d=ImageDraw.Draw(im)
            cracks=[(1,0),(2,3),(5,4),(6,7),(10,8),(11,12),(15,14)];d.line(cracks,fill=(217,69,16,255),width=2);d.line([(x,max(0,y-1)) for x,y in cracks],fill=(255,152,35,255),width=1)
        elif pattern=="obsidian" or "obsidian" in name:
            noise_clusters(im,mix(base,(12,10,22),.55),rng,5,2,.25);flecks(im,base,rng,5,(-5,-2),(17,24),(1,1));
            d=ImageDraw.Draw(im);d.line((1,13,4,10,8,11),fill=(*mix(base,(110,83,148),.45),255))
        else:
            noise_clusters(im,base,rng,6,2,.30);flecks(im,base,rng,9,(-17,-7),(13,31),(1,1,2))
            d=ImageDraw.Draw(im)
            for y in (3,8,13):d.line((0,y,15,y),fill=(*shade(base,-13),255))
        return im
    if pattern in ("farmland","dirt_path") or shape in ("farmland","dirt_path"):
        dirt(im,base,rng,block_id,actual_face)
        if actual_face=="top":
            d=ImageDraw.Draw(im)
            if pattern=="farmland" or shape=="farmland":
                for y in (3,7,11,15):d.line((0,y,15,y),fill=(*shade(base,-23),255))
            else:
                d.line((0,0,0,15),fill=(*shade(base,-24),255));d.line((15,0,15,15),fill=(*shade(base,-24),255))
        return im
    if pattern in ("crafting","furnace","chest","barrel","campfire","lantern","torch","ladder","cactus","lever","piston","observer","redstone_component","target","hay","mushroom","wood","paper","map","food","meat","bone","item","leather","plant","portal"):
        if pattern=="target": target_texture(im,base,rng);return im
        if pattern in ("paper","map"):
            noise_clusters(im,base,rng,4,2,.25);d=ImageDraw.Draw(im)
            d.rectangle((1,1,14,14),outline=(*shade(base,-24),255))
            for _ in range(8):
                x,y=rng.randrange(2,14),rng.randrange(2,14);setpx(im,x,y,rng.choice([(74,119,61),(61,99,148),(176,133,69)]))
            return im
        if pattern=="hay" or name=="straw_bed":
            noise_clusters(im,base,rng,9,2,.40);d=ImageDraw.Draw(im)
            for y in (3,7,11,14):d.line((0,y,15,y),fill=(*shade(base,-14),255))
            for _ in range(12):setpx(im,rng.randrange(16),rng.randrange(16),shade(base,rng.choice([-18,-9,12,20])))
            return im
        if pattern=="cactus":
            noise_clusters(im,base,rng,7,2,.4);d=ImageDraw.Draw(im)
            for x in (2,7,12):d.line((x,0,x,15),fill=(*shade(base,-17),255))
            for y in (3,8,13):d.line((0,y,15,y),fill=(*shade(base,8),255))
            return im
        if pattern in ("torch","lantern"):
            noise_clusters(im,base,rng,3,2,.15);d=ImageDraw.Draw(im)
            d.rectangle((7,5,8,15),fill=(103,65,35,255))
            if name == "redstone_torch":
                d.rectangle((6,2,9,6),fill=(150,32,26,255))
                d.rectangle((6,2,9,4),fill=(215,47,34,255))
                setpx(im,7,2,(255,104,62));setpx(im,8,3,(246,71,48))
            elif "soul_torch" in name:
                d.rectangle((6,2,9,6),fill=(47,139,153,255))
                d.rectangle((7,2,8,4),fill=(106,222,213,255))
            else:
                d.rectangle((6,2,9,6),fill=(246,169,43,255));d.point((7,2),fill=(255,232,119,255))
            if pattern=="lantern":d.rectangle((4,4,11,12),outline=(83,65,43,255));d.line((4,4,11,4),fill=(220,178,86,255))
            return im
        if pattern=="ladder":
            im.putdata([(0,0,0,0)]*256);d=ImageDraw.Draw(im);d.line((3,0,3,15),fill=(101,70,39,255),width=2);d.line((12,0,12,15),fill=(101,70,39,255),width=2)
            for y in (3,8,13):d.line((3,y,12,y),fill=(182,142,82,255),width=2)
            return im
        if pattern in ("furnace","observer","piston") or name in ("furnace","dispenser","dropper","observer","piston","sticky_piston","piston_head"):
            noise_clusters(im,base,rng,7,2,.36);d=ImageDraw.Draw(im)
            if name == "piston_head":
                wood = (124, 87, 50) if "sticky" not in name else (89, 142, 63)
                if actual_face == "top":
                    d.rectangle((1,1,14,14),fill=(*wood,255),outline=(52,48,40,255))
                    for x in (4,8,12):d.line((x,2,x,13),fill=(*shade(wood,-23),255))
                else:
                    d.rectangle((2,2,13,13),outline=(*shade(base,-27),255))
                    d.line((3,5,12,5),fill=(*shade(base,10),255));d.line((3,10,12,10),fill=(*shade(base,-16),255))
            elif actual_face == "top":
                d.rectangle((2,2,13,13),outline=(*shade(base,-32),255))
                d.rectangle((4,4,11,11),fill=(*shade(base,-11),255))
                d.line((5,5,10,5),fill=(*shade(base,8),255))
            elif name in ("observer", "piston", "sticky_piston"):
                # Side casing only. The sensing/output/head artwork lives on directional tiles.
                d.line((1,3,14,3),fill=(*shade(base,-19),255))
                d.line((1,12,14,12),fill=(*shade(base,-16),255))
                d.line((4,5,11,5),fill=(*shade(base,8),255))
            else:
                # Plain stone casing: dispenser/dropper/furnace openings are front-only.
                d.rectangle((1,1,14,14),outline=(*shade(base,-32),255))
                d.line((2,5,13,5),fill=(*shade(base,9),255))
                d.line((2,11,13,11),fill=(*shade(base,-14),255))
            return im
        if pattern in ("chest","barrel") or name in ("chest","barrel","shulker_box"):
            noise_clusters(im,base,rng,5,2,.23);d=ImageDraw.Draw(im)
            d.rectangle((1,2,14,14),outline=(*shade(base,-29),255));d.line((2,5,13,5),fill=(*shade(base,-19),255));d.line((2,11,13,11),fill=(*shade(base,-17),255))
            d.rectangle((7,6,8,9),fill=(202,171,85,255))
            if name=="barrel":
                d.line((3,2,3,14),fill=(*shade(base,-25),255));d.line((12,2,12,14),fill=(*shade(base,-25),255))
            return im
        if pattern=="campfire":
            noise_clusters(im,base,rng,7,2,.34);d=ImageDraw.Draw(im)
            if actual_face == "top":
                d.rectangle((0,0,15,15),fill=(43,32,24,255))
                d.line((1,13,14,3),fill=(87,56,31,255),width=4)
                d.line((1,12,14,2),fill=(157,103,52,255),width=2)
                d.line((2,3,13,14),fill=(100,64,34,255),width=4)
                d.line((2,3,13,14),fill=(178,119,59,255),width=1)
                for x,y in [(6,5),(7,3),(8,6),(10,5),(5,8),(9,9),(12,7)]:setpx(im,x,y,rng.choice([(226,62,17),(248,114,24),(255,182,43)]))
            elif actual_face == "bottom":
                d.rectangle((0,0,15,15),fill=(39,29,21,255))
                for y in (3,7,11,14):d.line((1,y,14,y),fill=(85,56,32,255),width=2)
                for _ in range(18):setpx(im,rng.randrange(16),rng.randrange(16),rng.choice([(35,25,20),(84,51,30),(111,64,31)]))
            else:
                d.line((2,0,2,15),fill=(74,48,29,255),width=3)
                d.line((13,0,13,15),fill=(91,60,34,255),width=3)
                d.rectangle((4,4,11,13),fill=(44,31,22,255))
                for x,y in [(6,8),(8,6),(9,10)]:setpx(im,x,y,rng.choice([(206,50,15),(241,94,18),(255,164,38)]))
            return im
        if pattern=="lever":
            noise_clusters(im,base,rng,4,2,.2);d=ImageDraw.Draw(im);d.rectangle((4,10,11,13),fill=(91,72,50,255));d.line((7,11,10,4),fill=(171,166,151,255),width=2);d.rectangle((9,2,12,5),fill=(126,121,113,255));return im
        if pattern=="redstone_component":
            noise_clusters(im,base,rng,4,2,.18);d=ImageDraw.Draw(im)
            if "repeater" in name or "comparator" in name:
                d.rectangle((1,5,14,11),fill=(68,57,47,255));d.line((2,6,13,6),fill=(142,22,20,255),width=2);d.line((2,10,13,10),fill=(179,30,23,255),width=1)
                for x in (4,8,12):d.rectangle((x,7,x+1,9),fill=(215,62,39,255))
            else:
                path=[(0,11),(3,11),(3,7),(7,7),(7,3),(11,3),(11,8),(15,8)]
                d.line(path,fill=(124,22,20,255),width=3);d.line(path,fill=(224,49,30,255),width=1)
            return im
        noise_clusters(im,base,rng,8,2,.4)
        return im
    # Material-aware catch-all for categories introduced in the block catalogue.
    if "glass" in name: glass_texture(im,base,rng,block_id)
    elif "ice" in name: ice_texture(im,base,rng,block_id,actual_face)
    elif pattern in ("leather",):
        noise_clusters(im,base,rng,7,2,.38);flecks(im,base,rng,6,(-16,-8),(6,14),(1,1))
    elif pattern in ("meat","food"):
        noise_clusters(im,base,rng,8,2,.44);flecks(im,base,rng,9,(-15,-6),(10,18),(1,2))
    elif pattern in ("wool",):wool_texture(im,base,rng,block_id)
    elif pattern in ("concrete",):noise_clusters(im,base,rng,2,2,.1)
    else:
        noise_clusters(im,base,rng,8,2,.4)
        flecks(im,base,rng,6,(-13,-5),(7,13),(1,1))
    return im


def main():
    data=json.loads(BLOCKS_PATH.read_text(encoding="utf-8"))
    atlas_map=json.loads(MAP_PATH.read_text(encoding="utf-8"))
    blocks=data.get("blocks",{})
    tile_map=atlas_map.get("tiles",{})
    original_ids=tuple(blocks.keys())
    original_blocks_hash=hashlib.sha256(BLOCKS_PATH.read_bytes()).hexdigest()
    original_map_hash=hashlib.sha256(MAP_PATH.read_bytes()).hexdigest()
    columns=int(atlas_map.get("columns",data.get("atlas_columns",64)))
    tile_size=int(atlas_map.get("tile_size",data.get("atlas_tile_size",16)))
    if tile_size != TILE:
        raise SystemExit(f"Expected a 16x16 atlas tile; found {tile_size}")
    if tuple(tile_map.keys()) != original_ids:
        # Ordering must be identical as well because the validator compares the
        # block JSON order against the atlas map's explicit per-face tile map.
        if set(tile_map) != set(original_ids):
            raise SystemExit("Block catalogue and atlas map IDs differ; refusing to alter either file")
    all_entries=[]; max_tile=-1
    for block_id,defn in blocks.items():
        if block_id not in tile_map:
            raise SystemExit(f"No atlas-map entry for existing ID {block_id}")
        for face,tile in defn.get("tiles",{}).items():
            entry=tile_map[block_id].get(face)
            if not isinstance(entry,dict) or int(entry.get("tile",-1)) != int(tile):
                raise SystemExit(f"Tile mapping mismatch before texture update: {block_id}/{face}")
            if (int(entry.get("width",0)),int(entry.get("height",0))) != (16,16):
                raise SystemExit(f"Non-16x16 atlas entry: {block_id}/{face}")
            max_tile=max(max_tile,int(tile))
            all_entries.append((block_id,defn,face,int(tile)))
    rows=max(1,math.ceil((max_tile+1)/columns))
    atlas=Image.new("RGBA",(columns*TILE,rows*TILE),(0,0,0,0))
    SWATCH_DIR.mkdir(parents=True,exist_ok=True)
    changed=0
    for block_id,defn,face,tile_index in all_entries:
        im=make_texture(block_id,defn,face)
        if im.mode!="RGBA": im=im.convert("RGBA")
        if im.size!=(TILE,TILE): raise RuntimeError(f"bad swatch size: {block_id}/{face}: {im.size}")
        path=SWATCH_DIR/f"{block_id}_{face}.png"
        im.save(path,optimize=True)
        atlas.paste(im,((tile_index%columns)*TILE,(tile_index//columns)*TILE))
        changed+=1
    atlas.save(ATLAS_PATH,optimize=True)
    # A hard safety guarantee: catalogue/mapping inputs are not rewritten.
    assert hashlib.sha256(BLOCKS_PATH.read_bytes()).hexdigest()==original_blocks_hash
    assert hashlib.sha256(MAP_PATH.read_bytes()).hexdigest()==original_map_hash
    assert tuple(json.loads(BLOCKS_PATH.read_text(encoding="utf-8"))["blocks"].keys())==original_ids
    print(f"Improved {changed} existing 16x16 swatches across {len(blocks)} existing catalogue IDs.")
    print(f"Atlas: {atlas.width}x{atlas.height}, {columns} columns x {rows} rows, max tile index {max_tile}.")
    print("Catalogue IDs, recipes, entities, atlas map, and tile indices unchanged.")

if __name__=="__main__":
    main()
