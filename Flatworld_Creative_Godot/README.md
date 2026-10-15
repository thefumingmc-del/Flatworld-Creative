# Flatworld Creative — Godot 4.7.2 project

A standalone, data-driven voxel sandbox project aimed at Android touch controls and later APK export. This is a new project, not based on an existing GitHub repository. It uses original GDScript and generated pixel textures; it does not bundle Minecraft's source code or proprietary asset archive.


## 0.5.5 strict registry namespace correction (audit package; not a complete vanilla import)

- Separated the canonical block and item lookups at runtime. Item identity/visuals/components are not inserted into the block dictionary; placing an item uses only `block_item_mappings.json`.
- Removed fake target-specific map item IDs such as `ocean_monument_map` and `woodland_mansion_map`; legacy values migrate to the canonical `filled_map` identity, where map data belongs as item data rather than separate registry IDs.
- Fixed migration collisions: wheat food vs wheat crop, seed→crop placement, redstone dust item→`redstone_wire`, and block-only fluid/transform states.
- Hardened the successful official importer path so stale project-only render adapters, item icons and fallback models are filtered to official IDs. The importer writes a blocker status without changing runtime registries when prerequisites fail.
- Added a repeatable per-entry registry coverage report and a five-issue remediation matrix. Current subset contains 300 block IDs and 392 item IDs; these are **not claimed to be complete Vanilla 26.3 totals**. The per-ID report marks official presence unknown until the versioned Mojang import is successful.
- QA this iteration: 12 importer unit tests, 9 runtime registry contract tests, 34 static GDScript-source checks, and 47 project data checks pass. Six warnings intentionally identify unimported official data and incomplete runtime systems.

**Blocking release gate:** the importer was attempted but stopped before network access because this environment has Java 21 while Java 26.3 source data generation requires Java 25+. No Godot executable or Android SDK/export templates were found. So the exact Mojang registry diff, Godot parse/run, Android APK export and phone test remain outstanding. Do not treat 0.5.5 as a verified APK or 1:1 clone.

See `docs/REGISTRY_MIGRATION_0.5.5.md`, `docs/REGISTRY_COVERAGE_CURRENT_SUBSET_0.5.5.csv`, `docs/ISSUE_REMEDIATION_MATRIX_0.5.5.csv`, `docs/STATIC_QA_REPORT_0.5.5.md`, and `docs/VANILLA_26.3_REFERENCE_SOURCES.md`.


## 0.5.4 canonical registry migration (historical step; superseded by 0.5.5)

- Separate canonical-data roles: `blocks.json`, `block_states.json`, `block_render_definitions.json`, `items.json`, `item_components.json`, and `item_visual_definitions.json`. Runtime facades expose independent block/item/components/model, entity, tag, loot-table, worldgen and recipe data.
- Normalized the known noncanonical crop, redstone, pressure-plate, quartz-ore, Poplar Leaves, and raw-metal block identities. Block and item migration maps are separate because legacy `carrot_crop`, for example, means block `carrots` but item `carrot`.
- Added the Java 26.3 importer, pinned to data version 5023, that downloads Mojang's exact server/client jars, verifies their manifest SHA-1+size, runs the vanilla report generator, extracts report/datapack/client JSON, writes SHA-256 file indexes and validates IDs/path integrity.
- **The full authoritative import has not run in this work environment:** only Java 21 is installed (26.3 needs Java 25), outbound downloads fail DNS, and Godot 4.7.2/Android export tools are absent. So the registry files still contain a corrected project subset; they are not advertised as complete official registries.
- The 194 sample recipes stay executable for now but are clearly separated from the pending official vanilla recipe index. Indexing official JSON does not automatically implement the recipe serializer or mechanics.
- See `docs/REGISTRY_MIGRATION_0.5.4.md`, `docs/VANILLA_26.3_REFERENCE_SOURCES.md`, and `docs/RELEASE_NOTES_0.5.4.md` for each issue, its current fix, next improvements, and strict source-import/run-time release gates.

**Still needs improvement:** run the importer on Java 25+ with working downloads, compare the full canonical data, implement official model and recipe resolution in the actual renderer/gameplay, then test in Godot and on Android. Do not treat 0.5.4 as a finished 1:1 clone or APK-ready release.

## 0.5.3 Java 26.3 completeness audit (historical audit-first pass)

- Added a repeatable, conservative audit covering the current combined block/item catalogue, official 26.3 update-specific feature families, block-state gaps, model/state rendering coverage, recipe schema, entity registry, world generation, mechanics and runtime verification.
- Preserved the complete 0.5.0 baseline catalogue ID set; this audit pass makes no gameplay catalogue changes and adds no speculative block/item IDs.
- Identified legacy ID naming that needs save-safe normalization: wool/concrete color-family IDs and the three Poplar Leaves variants. Also documented suspect pseudo-items/worldgen-as-block entries for canonical registry confirmation before modification.
- Generated per-catalogue-entry coverage and per-feature, per-state-family, and per-mechanic CSV matrices. See `docs/JAVA_26.3_COMPLETENESS_AUDIT_0.5.3.md` and `docs/RELEASE_NOTES_0.5.3.md`.
- To regenerate the audit: `python tools/audit_java_26_3_completeness.py`.

**Scope warning:** this is a grounded first-pass audit, not a complete name-by-name comparison against every Java 26.3 registry entry. A version-verified 26.3 registry dump must be extracted before claiming canonical completeness; the report explains the required inputs and migration order.

## 0.5.2 all-block texture and renderer QA pass

- Reworked every registered face swatch using crisp original 16×16 pixel art. All **1,342 swatches** remain 16×16, nearest-neighbour sampled, and checked byte-for-byte against their atlas locations.
- Preserved all **435 original catalogue IDs** from the 0.5.0 archive: the checked ID manifest detects additions or removals. This pass adds no blocks/items/recipes/entities; it adds 30 face-texture slots to 15 existing directional blocks.
- Added state-facing front/back atlas tiles for crafting tables, furnaces, dispensers, droppers, observers, chests, barrels, shulker boxes, doors, pumpkins, and pistons. World cube and shaped-block meshing now select the mapped front/back tile according to block facing.
- Fixed the earlier grass-side bug; also corrected the nether/end portal item-icon fallback, the redstone lamp's generic-stone fallback, redstone dust/rail alpha backgrounds, tripwire's crossed-plant geometry, and repeated chest/furnace front art on non-front faces.
- Added material-specific soul sand/soil, crafting table, bookshelf tops, daylight detector, campfire, end portal frame, and redstone torch/rail/dust patterns. The inventory and nine-slot hotbar show cropped atlas icons with nearest-neighbour filtering.
- Extended static QA to check the original catalogue-ID set, every tile's exact atlas rectangle and pixels, transparent sprite backgrounds, distinct portal/lamp states, distinct front/back art, and duplicate complete cube texture sets.

**Release status:** the static asset/data checks pass. Godot 4.7.2 runtime parsing, actual in-game rendering, touch testing and Android APK export still need editor/device verification. The project uses original generated art rather than pixel-identical Mojang textures and is not a full 1:1 Minecraft Java 26.3 implementation yet.

## 0.5.1 texture and mobile QA hotfix (history)

- Fixed the grass block side texture so its upper turf band uses the top/surface colour, with soil underneath. Podzol and mycelium use distinct surface/soil colours.
- Compact atlas and static checks were introduced; the current 0.5.2 pass now extends them to directional faces and alpha-masked elements.

## 0.5.0 development update

- **Chunk world:** seeded 16×16 horizontal chunk columns stream around the player and unload behind them. World coordinates and deterministic terrain allow effectively unbounded horizontal exploration in normal play. Build height follows the Java-like Y range **−64 through 319**. Generated terrain is kept compact in memory where possible and user edits are stored separately.
- **Dimensions:** separate Overworld, Nether and End generators, dimension-specific edited-block state, player positions, and basic portal transitions.
- **Voxel interactions:** ray-based targeting; block break/place; slab merging and hit-height-aware slab/stair halves; improved partial-face occlusion; stateful doors/trapdoors; beds/respawn; farmland, path blocks, seed planting and crop growth; bucket collection/placement for basic fluids; basic gravity for sand/gravel/concrete powder.
- **Crafting and stations:** a 194-record sample recipe catalogue, transactional ingredient consumption, sample furnace/fuel processing, and delayed campfire cooking. The catalogue is still incomplete compared with Java Edition.
- **Signals and fluids:** basic redstone dust/power propagation, lamps, iron doors, pistons, pressure plates and buttons; queued water/lava spread with basic reactions; neither system implements all Java rules or edge cases.
- **Entities:** 82 entity definitions, a spawned subset, basic nearby spawn/despawn, species-specific creeper fuse/explosion and skeleton ranged attack, data-driven drops, and collectible world item drops.
- **Save recovery:** player/world state, dimension edits, block states, fluids, inventory, containers, pending recipes, durability and world drops are saved. Saves write to a temporary file and preserve a previous backup to improve recovery from interruptions.
- **Reliability fixes:** repeater output is retained as numeric signal strength while a delay is pending, repeater/comparator meshes rotate to match facing, shaped geometry supports directional face tiles, and the daylight ray test excludes the mob through a typed collision-object RID.
- **Mobile-focused UI:** landscape Android layout, left movement joystick, drag-to-look, progressive hold-to-mine, right-side break/place/jump/down controls, sprint toggle, double-tap jump to toggle Creative flight, hold jump to ascend and hold down to descend while flying or sneak-walk on the ground. The nine-slot hotbar supports touch selection plus keyboard 1–9 and mouse-wheel slot cycling for desktop testing.
- **Survival pass:** saved day time, day/night ambient sky changes, daylight damage to exposed undead, fall/fire/lava/magma hazards, exhaustion, hunger/saturation, starvation and natural regeneration cadence.
- **Expanded redstone subset:** repeaters have selectable delay and delayed on/off transitions, comparators have compare/subtract modes and read the stored contents of chests/barrels to produce basic comparator strength, and observers pulse when adjacent observed state changes. Container changes mark the signal simulation dirty. These still differ from Java timing, complete inventory semantics, update order and directional connection rules.
- **Pixel textures:** every currently registered atlas face has a separate editable 16×16 PNG. The compact 1024×336 RGBA atlas uses nearest-neighbour filtering; these are original procedural pixel patterns intended to evoke classic voxel textures, not pixel-identical Mojang assets.

## Open the project

Open this folder in **Godot 4.7.2 Stable** and run `scenes/main.tscn`. No third-party plugin is required. Android orientation is set to Godot `SCREEN_LANDSCAPE` (enum value `0`), and the design viewport is 1280×720. Android export and GitHub publishing remain blocked on a Godot editor/runtime test, because the engine and Android build tools are not present in this working environment.

## Texture workflow

- Editable swatches: `assets/textures/blocks/`
- Atlas: `assets/textures/atlas.png`
- UV/face map: `assets/textures/atlas_map.json`
- Regenerate atlas after editing block metadata or generated swatches: `python tools/regenerate_pixel_textures.py`
- Apply manually supplied swatches as overrides: `python tools/apply_texture_overrides.py`

Keep swatches at 16×16 and use nearest-neighbour scaling. Directional `front`/`back` tiles must be added to both `assets/data/blocks.json` and `assets/textures/atlas_map.json`; append new slots after the existing maximum tile index. Do not change the catalogue ID list while editing textures. The reference manifest at `docs/catalogue_ids_0.5.0_reference.json` makes the validator reject accidental additions/removals.

## Static checks

Run:

```sh
python3 tools/test_java_26_3_sync.py
python3 tools/test_runtime_registry_contracts.py
python3 tools/check_gdscript_static.py
python3 tools/audit_registry_coverage.py
python3 tools/validate_project_data.py
python3 -m py_compile tools/*.py
# On Java 25+ with network access only:
python3 tools/sync_java_26_3_reference.py --version 26.3
python3 tools/validate_project_data.py --require-authoritative-reference
```

The static validator checks the immutable baseline catalogue ID set, JSON references, tight atlas packing, each swatch's exact atlas coordinates and pixels, grass turf/soil colours, directional face mappings, alpha backgrounds, distinct lamp/portal states, duplicate full-cube texture sets, landscape orientation, required catalogue families, duplicate top-level function names, basic delimiter pairing, selected gameplay hooks and bundled `res://` references. It is **not** a GDScript parser or gameplay test.

## Important limitations

This is **not a finished or exact Minecraft Java 26.3 clone**. The catalogue entries do not mean every item is fully implemented. Many block models/states, drops, crafting recipes, behaviours and entity definitions remain simplified or data-only. Redstone and fluid ticks cover selected behaviours, not all Java mechanics. Terrain generation/meshing is synchronous and has not had mobile performance testing; lighting, heightmap/biome/structure parity and large-scale save performance are incomplete. Entity visuals are primitive generated models rather than the full Minecraft models/animations. Multiplayer, datapacks, command systems, many farms/automation systems, villager economies, status effects, enchanting, brewing, transport, boss fights and a large amount of content remain missing or partial.

Static data/asset checks now also compare every 16×16 swatch with its exact atlas slot, assert the green turf/soil split, require the atlas to use the minimum row count, and reject duplicate full texture sets among solid placeable full cubes. Godot editor parsing/runtime, Android export, APK installation and device performance have **not** been verified here because a Godot executable, Android SDK and matching export templates were not available. See `docs/REGISTRY_MIGRATION_0.5.5.md`, `docs/STATIC_QA_REPORT_0.5.5.md`, `docs/REGISTRY_COVERAGE_CURRENT_SUBSET_0.5.5.csv`, `docs/ISSUE_REMEDIATION_MATRIX_0.5.5.csv`, `docs/VANILLA_26.3_REFERENCE_SOURCES.md`, `docs/JAVA_26.3_COMPLETENESS_AUDIT_0.5.3.md`, the related 0.5.3 CSV/JSON audit files, `docs/FEATURE_MATRIX.md`, `docs/STATIC_QA_REPORT.md`, `docs/BLOCK_TEXTURE_AUDIT_0.5.2.csv`, prior release notes and `docs/ANDROID_EXPORT.md`.

## Rebuilding derived block-face PNGs

The packed `assets/textures/atlas.png` and `assets/textures/atlas_map.json` are retained in the project. The individual 16×16 files under `assets/textures/blocks/` are deterministic derived copies of atlas cells and can be restored without changing pixels:

```sh
python3 -m pip install Pillow
python3 tools/rebuild_block_textures_from_atlas.py
```

The GitHub Actions Android build workflow performs this restoration before data validation, Godot import, and ARM64 debug APK export.
