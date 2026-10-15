# Pixel texture atlas workflow — 0.5.2

- `assets/textures/blocks/` contains editable, lossless 16×16 RGBA face swatches.
- `assets/textures/atlas.png` is the runtime atlas (1024×336 pixels, 64 columns × 21 rows).
- `assets/textures/atlas_map.json` maps every block face to its exact tile index and pixel rectangle.
- `assets/data/blocks.json` registers the face tile IDs for the existing 435-item/block catalogue.
- `scripts/world.gd` samples atlas texel centres and selects `front`/`back` tiles based on saved facing; `scripts/mobile_hud.gd` uses `AtlasTexture` icons with nearest-neighbour UI sampling.

## Regenerate and verify

From the project root:

```sh
python3 tools/improve_all_block_textures.py
python3 tools/validate_project_data.py
```

`tools/regenerate_pixel_textures.py` is a compatibility alias to the same safe generator. It no longer runs the retired script that could append entries to `blocks.json`. The texture generator treats both `blocks.json` and `atlas_map.json` as immutable inputs: it regenerates registered 16×16 swatches and the atlas without changing a block ID, recipe, entity, face index, or map entry.

All tiles are packed into the minimum complete 64-column row count. The validator compares every standalone swatch byte-for-byte with its exact atlas slot and checks that each map rectangle matches the tile index. It also guards the 0.5.0 catalogue ID set, grass turf/soil split, transparent rail/redstone/tripwire backgrounds, distinct portal and lamp textures, directional front/back art, and duplicate complete top/side/bottom texture sets for solid placeable full cubes.

## Directional faces

Blocks whose orientation matters use optional `front` and `back` face slots. To introduce another directional texture to an existing block, append new unique 16×16 tile indices after the current maximum in both JSON files and set each face rectangle to `(tile % 64 × 16, floor(tile / 64) × 16, 16, 16)`. Keep the two files in sync. Do not change the reference catalogue IDs. `tools/add_directional_face_slots.py` is an idempotent metadata migration helper for the current directional face set; it is not needed during ordinary texture regeneration.

## Rendering constraints

- Never upscale the actual swatches. Preview scaling must use nearest-neighbour only.
- Alpha-masked surfaces depend on transparent pixels; do not replace these backgrounds with opaque charcoal.
- The world atlas material uses Godot's nearest filter and alpha transparency. UI atlas icons use `AtlasTexture.filter_clip` to avoid sampling adjacent tiles.
- This workflow produces original procedural pixel art in the Minecraft-like 16×16 voxel style. It does not produce pixel-identical Mojang resource assets, and matching every official model, animation, connected texture or block-state overlay requires additional work.
- Regeneration and static QA do not prove the GDScript parser or actual GPU output. Open the project in Godot 4.7.2 and inspect representative transparent/directional blocks on desktop and Android before release.
