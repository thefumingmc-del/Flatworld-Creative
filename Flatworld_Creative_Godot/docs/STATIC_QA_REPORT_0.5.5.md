# Static QA report — Flatworld 0.5.5

## Result

**Static validation: PASS with known blockers. This is not a verified APK or 1:1 release.**

## Commands and results

| Command | Result |
|---|---|
| `python3 -m py_compile tools/*.py` | Passed |
| `python3 tools/test_java_26_3_sync.py` | 12 tests passed |
| `python3 tools/test_runtime_registry_contracts.py` | 9 tests passed |
| `python3 tools/check_gdscript_static.py` | 34 source/static checks passed, 0 failures |
| `python3 tools/validate_project_data.py` | 47 checks passed, 6 warnings, 0 errors |
| `python3 tools/audit_registry_coverage.py` | Passed; emitted current-subset per-ID CSV/JSON |
| `python3 tools/sync_java_26_3_reference.py --version 26.3` | Blocked before network/download: Java 25+ required, detected Java 21 |

## Verified locally

- Separate block and item root registry documents; item rows do not embed block identity.
- Runtime accessors keep block lookup strict and use the explicit item→block placement adapter.
- Wheat food item does not place wheat crop; redstone inventory item maps to `redstone_wire`.
- `water`, `lava`, `farmland`, and `dirt_path` remain block-only and are not registered as standalone inventory items.
- Fake per-structure map item IDs removed; `map` and `filled_map` remain canonical item identities, with legacy map IDs migrated to `filled_map`.
- 300 current known block IDs, 299 render adapters, 392 current known item IDs, 392 project item icons, 300 provisional state rows, 288 supported item→block mappings, 194 sample recipes, and 81 runtime entity definitions.
- All current face swatches map to valid atlas tiles; current block textures are 16×16 and exact atlas pixels; item icon paths exist and resolve to crisp 16×16 PNGs.
- No duplicate complete top/side/bottom texture set was detected among current solid full cube block render adapters.
- Importer stages and validates source registries before committing. Successful import prunes project visual/fallback records to the official ID sets. A precondition failure produces status metadata and does not touch runtime registries.

## Warnings that remain real

1. Official Mojang Java 26.3 reports and client model/data files have not been fetched or imported; `confirmed_in_java_26_3` remains unknown in the current coverage CSV.
2. Current 300 block IDs / 392 item IDs are project subset counts, not official vanilla totals.
3. Current 300 block-state rows are provisional; official defaults/numeric state IDs/property domains are not imported.
4. Current `models.json` has no official blockstate/model graph; runtime uses project fallback geometry.
5. Current per-item component registry has zero per-item component rows; item components are not fully implemented.
6. Complete Java recipes, tags, loot tables, worldgen definitions/execution and entity behaviors remain partial.
7. No Godot 4.7.2 binary/editor was present, so scripts were not parsed/executed by Godot. The source scan only checks selected syntax-adjacent conditions and paths.
8. No Android SDK/export templates were found, so no APK was exported/installed and no on-device landscape/touch/performance test ran.

## Import blocker evidence

`assets/data/registries/26.3/vanilla_import_status.json` reports:

```json
{
  "source_status": "BLOCKED_BEFORE_REFERENCE_DOWNLOAD",
  "java_major": 21,
  "required_java_major": 25,
  "download_attempted": false,
  "runtime_registries_modified": false
}
```

This result is deliberately not described as an authoritative registry comparison. The exact comparison is blocked until the importer can run against the official hash-verified version artifacts.
