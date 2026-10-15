# Feature coverage — development milestone 0.5.2 (base implementation 0.5.0)

This matrix describes code in this repository, not feature parity with Minecraft Java Edition 26.3. A catalogue definition is not proof that the corresponding item/entity is complete.

## Implemented in code (a functional subset)

- Seeded 16×16 horizontal chunk columns with player-centred streaming, queueing and unloading. Deterministic generation and sparse edits support effectively unbounded horizontal exploration during normal play. World coordinates are supported from Y = −64 through Y = 319.
- Terrain includes multiple regions/biome labels, surface and underground layers, caves/ores, water/lava areas, trees, and basic Nether/End terrain generation. Chunks build synchronously and the generation rules are intentionally simplified.
- Chunk meshes/collisions, voxel DDA targeting, block placement and breaking, generated texture atlas, and partial non-cube models. Compatible opposite-half slabs can merge into a double slab; slab/stair placement uses the target face/hit height; face culling preserves exposed strips beside full blocks; fences add rails toward connected neighbours; paired doors are cleared together by explosions. Many state, orientation, connection and collision rules are still incomplete.
- Android-style touch joystick, drag-to-look, hold-to-mine with a progress bar, mobile sprint toggle, jump/break/place/use actions, landscape Android-oriented layout and nine-slot hotbar. Keyboard keys 1–9 and mouse-wheel selection support desktop testing.
- Day-time persistence, day/night sky and ambient changes, exposed-undead daylight damage, fall/fire/lava/magma hazards, hunger/saturation/exhaustion, starvation and natural-regeneration cadence are implemented in simplified form.
- 36 inventory slots, item stack merging, count checks, partial pickup handling, common single-stack tool limits, and inventory restoration/normalization.
- 194 recipe data records; a working subset of crafting and delayed furnace/campfire processing consumes inputs and appropriate fuel for the furnace subset. This is not the full Java recipe registry or station logic.
- Basic block states for selected doors, trapdoors, beds, furnaces, containers, crops, buttons/pressure plates, redstone components, piston heads, portals and fluid blocks.
- Basic water/lava tick-based spread/reactions, active-fluid persistence, sand/gravel/concrete-powder fall checks, tilling/path conversion, planting and periodic crop growth, bucket fluid collection/placement, and simple bone-meal growth.
- Basic redstone dust signal relaxation, directional repeater output with selectable 1–4 delay and delayed switching, compare/subtract comparator output, observer state-change pulses, power source handling, redstone lamps, iron-door/trapdoor power handling, and limited piston extend/retract behaviour. The circuit model still differs substantially from Java in tick scheduling, inventory signals, update order, quasi-connectivity, and many wiring rules.
- Three dimension generators (Overworld, Nether, End), dimension-specific edits/fluids/block states, saved dimension positions and simplified portal transitions.
- 82 entity definitions with a subset spawned. Nearby spawn/despawn, basic AI for passive/hostile mobs, creeper fuse/explosions, skeleton ranged attacks, data-driven drop tables and in-world collectible drops are present in simplified form.
- Coordinate-keyed basic container state, world pickups, block modifications, fluid states, inventory, pending cooking/smelting, player state, dimension positions and tool durability are saved in JSON. Temporary-file replacement and a backup path provide basic interrupted-save recovery.
- 435 block/item catalogue definitions; 82 entity definitions; 194 recipe records; 1,342 unique face tiles in a 1,024×336 atlas. Registry counts are data counts, not counts of fully implemented Minecraft features.

## Partially implemented / significantly different from Java

- **World generation:** current biome, surface, cave, structure, and dimension generation approximates a voxel sandbox. It does not reproduce Java's exact noise settings, biome placement, feature placement, village/structure generation, ore distributions or seed compatibility. Chunk generation/mesh building can hitch because they are synchronous.
- **Infinite world:** horizontal coordinates can keep extending as chunks stream, but RAM, device storage, save-file size, floating-point precision and mobile performance remain finite. There is no tested mobile budget or region-file database.
- **Blocks and block states:** slabs/stairs and selected shape geometry exist; every facing, upside-down orientation, waterlogging state, block-specific collision/hit shape, neighbour shape updates, redstone connectivity, all door/bed halves, rails, signs, containers and every other Java block state are not implemented to parity.
- **Fluids/fire:** basic active fluid spread is present; Java-equivalent flow scheduling, flow distances, waterlogging, bubble columns, water/lava tick rules, fire spread, burn damage, extinguishing, ice/snow/weather interactions and all fluid edge cases are missing.
- **Redstone:** dust, repeaters, compare/subtract comparators, observers, lamps, selected iron mechanisms and pistons now have basic behaviour. Inventory/container signal levels, all directional/strong/weak power rules, quasi-connectivity, scheduled update order, repeater locking, observer edge/cooldown semantics, component sound/particles, and Java tick timing are not parity-complete.
- **Crafting/smelting:** 194 recipe records are only a subset. Full shaped/shapeless recipe logic, recipe-book behavior, recipes for all items/blocks, station times, smoker/blast furnace, fuel values, container remainders and byproducts remain incomplete.
- **Entities:** primitive meshes and simplified locomotion are used. All 82 definitions are not all spawned or fully interactable; full AI/pathfinding, navigation, animation, equipment, projectiles, breeding, villager jobs/trading, loot conditions, boss encounters and spawn conditions are incomplete.
- **Survival:** hunger/health and selected tool/drop rules are simplified. Full armor/enchanting/anvil/brewing/status effects/XP/advancements, hostile spawning and daylight rules, fishing, transport, farming mechanics and progression are not complete.
- **Visual/audio fidelity:** all 1,342 registered face swatches are generated as crisp 16×16 RGBA pixel art, with material-specific patterns, transparent cutout sprites, and directional front/back variants where the current block definitions need them. The atlas uses nearest-neighbour sampling and is statically checked against every swatch pixel. These are original generated textures that aim for Minecraft-like readability, not Mojang’s exact pixel assets. Entity geometry, biome tinting, face lighting, connected textures, animation, shadows, sound, particles, and a Godot-rendered visual pass still need refinement.
- **Persistence:** JSON save/recovery is safer than a direct overwrite, but huge worlds may create large save files. There is no chunk/region storage, compression strategy, transactional per-chunk persistence, or save corruption recovery tested in Godot.

## Not implemented to Java 26.3 parity

- A verified complete Java 26.3 item/block/entity/biome/structure/recipe/loot registry with every associated behaviour, state, sound, model, texture and animation.
- Exact Java Edition world generation and seed compatibility; full lighting propagation, skylight and block light engine, ambient occlusion/render parity, weather and all structures.
- Complete redstone automation, villagers/economy, dimensions/bosses/events, potions/enchanting/anvils, all transport/mount systems, commands/datapacks, advancements/statistics, full multiplayer/server logic, and countless additional mechanics.
- Confirmed Godot 4.7.2 editor startup and GDScript type/parser check; actual mobile playtesting; exported APK; installation/performance/memory test on Android.

## Next validation gate

1. Open with Godot 4.7.2 Stable; resolve all parser/type/runtime errors and run world, chunk-seam, collision, save/reload, dimension, inventory, craft, fluid, redstone and mob test scenes.
2. Profile chunk generation/mesh collision and saves on the target Android device. Refactor into vertical chunk sections/job-based mesh generation if profiling indicates hitches.
3. Implement a real chunk/region persistence layer and crash/restart tests for very large edited worlds.
4. Continue block-state-by-block-state implementation and maintain automated tests for each mechanic; compare against a legal Java 26.3 reference checklist.
5. Only after runtime stability, configure Android export templates and build/install APK. GitHub publishing/CI is a later step and was not performed for this archive.
