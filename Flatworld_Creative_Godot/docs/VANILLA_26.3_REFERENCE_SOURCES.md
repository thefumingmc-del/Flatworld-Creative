# Java 26.3 reference sources and provenance

1. **Official Mojang release notes:** https://www.minecraft.net/en-us/article/minecraft-java-edition-26-3 — source for release features and data-pack/resource-pack compatibility claims. Release notes are not themselves a full registry dump.
2. **Official Mojang version manifest:** https://piston-meta.mojang.com/mc/game/version_manifest_v2.json — the importer selects exact `26.3` metadata and verifies the client/server JAR SHA-1 and file-size values before use.
3. **Vanilla server reports:** `java -DbundlerMainClass=net.minecraft.data.Main -jar server.jar --reports` — expected to produce authoritative block states, block/item/entity registries and item components for the selected version. The importer requires Java 25 or later for Java 26.3.
4. **Official client JSON:** exact `assets/minecraft/blockstates`, `assets/minecraft/models`, `assets/minecraft/items`, and language JSON are extracted/indexed by the importer. Official raster texture PNGs are deliberately not bundled by this importer.
5. **Official server datapack:** raw `data/` files from the selected version's inner server JAR are indexed for recipes, tags, loot tables, worldgen, dimensions and related registries.
6. **Independent schema cross-check:** https://github.com/RosegoldMC/minecraft-data.cr — useful for understanding data-generation workflows, but not a substitute for the Mojang artifacts. Its README notes that some hardness, collision, and entity dimensions can be derived, carried forward, or source-analyzed rather than emitted directly in Mojang reports. Such fields must be labeled with their provenance.

## Importer status as of Flatworld 0.5.5

The pinned importer has been implemented and its schema/integrity helpers are unit-tested. An actual import was attempted using:

```text
python3 tools/sync_java_26_3_reference.py --version 26.3
ERROR: Java 25+ required for Minecraft 26.3; detected 21
```

This stops before download; no source JAR was fetched or run in this environment. `assets/data/registries/26.3/vanilla_import_status.json` records the blocker, `download_attempted: false`, and `runtime_registries_modified: false`. The current 300 block IDs, 392 item IDs, and provisional state set are **project subset values**, not claimed official counts. The generated coverage CSV explicitly marks official membership unknown until the exact import succeeds.

## Provenance rules

- Registry IDs, numeric block state IDs, item component reports, entity registry IDs, client model/blockstate JSON, recipes, tags, loot, and worldgen files must come from the exact hash-verified Java 26.3 artifacts.
- Generated project artwork and project-specific runtime adapters remain identified as project data; they are not presented as Mojang textures/models.
- Any derived collision, model/behavior inference, or carried-forward entity metadata must be separately labeled and regression-tested.
- A successful data import proves source coverage and structural integrity only. It does not prove that Godot implements the behavior, rendering, lighting, world generation, or Android performance correctly.
