# Registry migration — Flatworld 0.5.5

## Scope and status

This follow-up strengthens the block/item namespace split, removes known project-specific item aliases, and makes the official Java 26.3 importer's successful-import path safer. It does **not** claim that the complete Vanilla Java 26.3 registries have been downloaded or imported. The current runtime data remains a verified Flatworld subset with explicit gaps.

Target: Minecraft Java Edition 26.3; data version 5023; data pack format 121; resource pack format 97.1; engine target Godot 4.7.2.

## Changes in this pass

1. `blocks.json` / `items.json` are separate identity registries. Item rows do not contain `block_id` and runtime `get_block()` resolves block records only. Item presentation is composed through `get_item_runtime()` without inserting items into the block dictionary.
2. `block_states.json`, `block_render_definitions.json`, `models.json`, `model_fallbacks.json`, `item_visual_definitions.json`, `item_components.json`, `block_item_mappings.json`, `entity_types.json`, `entity_behaviors.json`, `recipes.json`, `tags.json`, `loot_tables.json`, and `worldgen.json` have separate roles.
3. Placement uses explicit `item_to_block` / `block_to_item` adapters. Wheat as an edible inventory item does not place the wheat crop; wheat seeds place the crop. Redstone dust inventory item maps to `redstone_wire`; `water`, `lava`, `farmland`, and `dirt_path` are block states and not standalone inventory items.
4. Target-specific map IDs (e.g. `ocean_monument_map`, `woodland_mansion_map`, `abandoned_camp_map`) are retired as fake item registry IDs. Vanilla uses canonical `map` / `filled_map` items and attached map data. Legacy map IDs migrate to `filled_map`; target-specific structure/map details are not represented as distinct item IDs.
5. `tools/sync_java_26_3_reference.py` now filters pre-existing render adapters, icon adapters, and fallback models against the exact official block/item ID sets after successful import. It will not preserve stale project-only art IDs, and it will not invent an art adapter for an official ID that lacks one.
6. The importer records prerequisite failures in `vanilla_import_status.json` without mutating runtime registry files. Its structural checks reject duplicated state IDs, missing state rows, absent/nonnumeric state IDs, and blocks without exactly one default state.
7. Added 12 importer unit tests, 9 runtime registry contract tests, a 34-check GDScript-oriented source scan, and a repeatable CSV coverage generator. The source scan is intentionally not described as a Godot parser.

## Registry coverage snapshot

Current local subset counts—not official registry totals:

| Data | Count | Status |
|---|---:|---|
| Known block IDs | 300 | subset; vanilla diff pending |
| Project render adapters | 299 | subset; vanilla models not imported |
| Known item IDs | 392 | subset; vanilla diff pending |
| Project item icons | 392 | generated project art; vanilla item models not imported |
| Block state records | 300 | provisional and incomplete |
| Per-item component records | 0 | exact item component source not imported |
| Item-to-block mappings | 288 | explicit supported runtime subset |
| Runtime sample recipes | 194 | sample only; not full Java recipe set |
| Runtime entity definitions | 81 | subset; AI/model/animation parity incomplete |

The per-entry snapshot is `REGISTRY_COVERAGE_CURRENT_SUBSET_0.5.5.csv`. Its `confirmed_in_java_26_3` column intentionally says `UNKNOWN_REFERENCE_NOT_IMPORTED` while the authoritative import has not succeeded.

## Why official import remains blocked

Ran:

```text
python3 tools/sync_java_26_3_reference.py --version 26.3
ERROR: Java 25+ required for Minecraft 26.3; detected 21
```

The current environment has OpenJDK 21. It has no Godot/Godot 4 binary, no Android SDK environment variables, and no found `android.jar`/`sdkmanager` under checked install roots. This stopped the sync **before any Mojang download**; the status file records `download_attempted: false` and `runtime_registries_modified: false`. Therefore, no project-only vs official full-registry ID diff can honestly be published yet.

The source importer is pinned to the official Mojang version manifest and checks JAR SHA-1 and sizes. It runs the selected vanilla server report generator, extracts server datapack data and client model/item JSON, preserves raw file hashes, and validates structural integrity before committing staged registries. Exact imported data can be loaded later on a machine with Java 25+ and network access; opening/running the Godot project is a separate release gate.

## Next implementation gates

1. Run the pinned source importer on Java 25+ with reliable network access and verify raw source hashes.
2. Review `project_only_blocks`, `project_only_items`, `vanilla_blocks_missing_from_project_subset`, and `vanilla_items_missing_from_project_subset`; apply migrations only for mismatches proven by that data.
3. Implement the official block state and model graph in the voxel renderer: defaults, property domains, state ID lookup, inheritance, variants, multipart conditions, model element rotations, UVs, alpha/cutout/transparency and collision shape mapping.
4. Implement full item components and canonical item→block relationships; retain map data as item data on `filled_map` rather than separate item IDs.
5. Implement all recipe serializers, remainders, tags, loot conditions/functions, entity behavior/model coverage, and data-driven world-generation registries and consumers.
6. Run scene/parser/runtime tests in Godot 4.7.2; test every state family in a block gallery; build and install a landscape Android APK; compare controls and results against Java 26.3 reference behavior.

Static data checks passing does not establish renderer correctness, mechanical parity, APK build success, or mobile performance.
