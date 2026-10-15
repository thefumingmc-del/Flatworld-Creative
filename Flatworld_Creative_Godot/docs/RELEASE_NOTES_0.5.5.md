# Release notes — Flatworld Creative 0.5.5

## Registry integrity and migration

- Strictly separated block identity from item identity in the data layer and runtime facade.
- Reworked UI/drop/placement lookups to compose item icon/presentation data through the item API and placement through explicit item→block mappings.
- Removed fake target-specific map item IDs and consolidated their legacy migration to vanilla `filled_map`; map/structure content must live in item data, not separate registry IDs.
- Corrected crop/seed migration and retained `wheat` as both a block ID and food item ID only within distinct registries, with no inferred placement edge.
- Added official-import filtering of renderer, item-icon, and fallback-model IDs so successful hydration cannot retain noncanonical project-only adapters.
- Added auditable import-blocker status writing, ID coverage CSV/JSON generation, regression tests, and QA/remediation matrices.

## Current validation

- Importer/schema tests: 12 passed.
- Runtime registry contract tests: 9 passed.
- GDScript-oriented static checks: 34 passed.
- Project data/texture validator: 47 passed, 6 expected gap warnings, 0 errors.
- Python bytecode compilation passed.

## Limitations and release gate

The exact Mojang 26.3 import did not run because the environment contains Java 21 and the importer requires Java 25+. The attempt stopped before network access and did not mutate runtime registries. Godot 4.7.2 parsing/runtime, official model resolution, full recipes/components/tags/loot/world generation/entities, Android export, device installation and landscape/touch/performance verification remain outstanding. This is a development/QA package, not an APK-ready or complete Java 26.3 recreation.
