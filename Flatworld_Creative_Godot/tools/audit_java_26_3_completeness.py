#!/usr/bin/env python3
"""Static completeness/gap audit for Flatworld against Minecraft Java 26.3.

This is a conservative project-data audit, not a replacement for extracting the
actual 26.3 client/server registries or running the project in Godot. It records
known identifiers and requirements from Mojang's release notes and can compare
externally extracted canonical registries when a versioned --reference-dir is supplied.
"""
from __future__ import annotations
import argparse, csv, json, re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
DATA = ROOT / "assets" / "data"

OFFICIAL_RELEASE = "https://www.minecraft.net/en-us/article/minecraft-java-edition-26-3"
OFFICIAL_CHANGELOG = "https://feedback.minecraft.net/hc/en-us/articles/48913133328013-Minecraft-Java-Edition-26-3"
PRISMARINE_26_3 = "https://github.com/PrismarineJS/minecraft-data/pull/1300"
PRISMARINE_26_3_FOLLOWUP = "https://github.com/PrismarineJS/minecraft-data/pull/1301"
PRISMARINE_BLOCKS_26_1 = "https://raw.githubusercontent.com/PrismarineJS/minecraft-data/master/data/pc/26.1/blocks.json"
PRISMARINE_ITEMS_26_1 = "https://raw.githubusercontent.com/PrismarineJS/minecraft-data/master/data/pc/26.1/items.json"

COLORS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"]

# IDs whose current spelling is clearly inconsistent with Java Edition's normal
# registry naming convention. The old IDs are deliberately preserved in this
# audit; normalization must be a separate, save-migrating implementation step.
def expected_feature_rows(blocks: dict) -> list[dict]:
    rows: list[dict] = []
    def add(feature, kind, canonical, current, status, confidence, reason, next_step):
        rows.append({"feature": feature, "registry_kind": kind, "canonical_candidate": canonical,
                     "current_id_or_ids": current, "status": status, "confidence": confidence,
                     "evidence_or_reason": reason, "next_improvement": next_step})

    for color in COLORS:
        for kind, canonical, current in [
            ("block", f"{color}_wool", f"wool_{color}"),
            ("block", f"{color}_wool_slab", f"wool_{color}_slab"),
            ("block", f"{color}_wool_stairs", f"wool_{color}_stairs"),
            ("block", f"{color}_concrete", f"concrete_{color}"),
            ("block", f"{color}_concrete_slab", f"concrete_{color}_slab"),
            ("block", f"{color}_concrete_stairs", f"concrete_{color}_stairs"),
        ]:
            exists = current in blocks
            status = "legacy_alias_present" if exists else "missing"
            # The new stair/slab IDs were added in 26.3; base block IDs predate it.
            confidence = "high"
            reason = "Current project uses reversed color/material ordering; vanilla Java identifiers use color first. Java 26.3 release notes specifically add wool and concrete stairs/slabs for every corresponding color."
            next_step = "Normalize to the canonical ID and add a save migration for old IDs; update recipes, world generation, texture names, atlas maps, and tests together."
            add("wool_and_concrete_color_families", kind, canonical, current if exists else "(none)", status, confidence, reason, next_step)

    poplar = [
        ("poplar_log", "block", "poplar_log", "high"),
        ("poplar_wood", "block", "poplar_wood", "high"),
        ("stripped_poplar_log", "block", "stripped_poplar_log", "high"),
        ("stripped_poplar_wood", "block", "stripped_poplar_wood", "high"),
        ("poplar_planks", "block", "poplar_planks", "high"),
        ("poplar_stairs", "block", "poplar_stairs", "high"),
        ("poplar_slab", "block", "poplar_slab", "high"),
        ("poplar_fence", "block", "poplar_fence", "high"),
        ("poplar_fence_gate", "block", "poplar_fence_gate", "high"),
        ("poplar_door", "block", "poplar_door", "high"),
        ("poplar_trapdoor", "block", "poplar_trapdoor", "high"),
        ("poplar_pressure_plate", "block", "poplar_pressure_plate", "high"),
        ("poplar_button", "block", "poplar_button", "high"),
        ("poplar_sign", "block/item", "poplar_sign", "high"),
        ("poplar_hanging_sign", "block/item", "poplar_hanging_sign", "high"),
        ("poplar_sapling", "block/item", "poplar_sapling", "high"),
        ("poplar_boat", "item/entity", "poplar_boat", "medium"),
        ("poplar_chest_boat", "item/entity", "poplar_chest_boat", "medium"),
    ]
    for feature, kind, canonical, conf in poplar:
        present = canonical in blocks
        add("poplar_wood_set", kind, canonical, canonical if present else "(none)",
            "present_project_id" if present else "missing", conf,
            "Official 26.3 notes add a Poplar wood set. Boat/chest-boat entries are expected from the standard wood-set scope and require final verification against the 26.3 item registry." if "boat" in canonical else "Official 26.3 notes add Poplar Logs and a complete Poplar wood set.",
            "Verify model, recipe, drops, item form and relevant orientation/state against the official 26.3 registry; implement any missing form without making it a cube substitute.")
    for color in ("red", "orange", "yellow"):
        canonical = f"{color}_poplar_leaves"
        current = f"poplar_leaves_{color}"
        add("poplar_leaf_variants", "block/item", canonical, current if current in blocks else "(none)",
            "legacy_alias_present" if current in blocks else ("present_project_id" if canonical in blocks else "missing"),
            "high", "The official 26.3 release names Red, Orange, and Yellow Poplar Leaves; current IDs reverse the color order.",
            "Normalize ID with save migration; implement leaf distance/persistence, tint, drops, growth, decay, and matching falling-leaf particles.")

    for canonical, kind, evidence in [
        ("red_shrub", "block/item", "Official 26.3 feature, already represented by this ID."),
        ("cushion", "block/item", "Official 26.3 feature, but colors/states, placement, collision and entity bounce require registry verification."),
        ("straw_bed", "block/item", "Official 26.3 feature, but paired bed states, sleep/respawn, occupied state and orientation require verification."),
        ("leaf_litter", "block/item", "Mentioned as naturally generating on/around Poplar Trees in the official 26.3 notes; verify its exact registry/version history."),
    ]:
        present = canonical in blocks
        add("26_3_named_feature", kind, canonical, canonical if present else "(none)",
            "present_project_id" if present else "missing", "high", evidence,
            "Compare exact 26.3 registry/model/state/loot behavior; presence of an ID alone is not implementation parity.")

    add("shelf_mushroom", "block/item", "shelf_mushroom", "; ".join(x for x in ["shelf_mushrooms", "shelf_mushroom_small", "shelf_mushroom_large"] if x in blocks) or "(none)",
        "needs_registry_normalization", "medium", "Official notes describe one Shelf Mushroom item and small/large growth forms; current project uses a plural ID plus separate small/large entries. This risks duplicate inventory IDs and incorrectly modelled block states.",
        "Read the actual 26.3 block/item registry, determine whether size is a state or a separate ID, then represent the block/item relationship and growth/drop rules exactly.")
    add("poplar_generation", "worldgen feature", "configured fallen-poplar/tree feature (not assumed to be a standalone block ID)",
        "; ".join(x for x in ["fallen_poplar_tree", "fallen_poplar_log"] if x in blocks) or "(none)",
        "likely_worldgen_as_block_misclassification", "medium", "Official notes say fallen Poplar Trees generate in the Dappled Forest. A generated tree/feature should not automatically be represented as a new independent block ID; horizontal wood is usually a block state/orientation.",
        "Compare 26.3 block registry; if these are not registry IDs, migrate saves/structures to poplar_log with axis/facing state and put the tree pattern in worldgen features.")
    add("map_items", "item/component", "filled_map", "; ".join(sorted(x for x in blocks if x.startswith("explorer_map_"))) or "(none)",
        "noncanonical_pseudo_item_family", "high", "Project models each explorer-map destination as a separate catalogue ID. Java maps are item stacks with map data/components; target-specific explorer map contents are not a unique item ID family.",
        "Replace pseudo-items with canonical filled-map item stacks and map target/data components; preserve current saves with an inventory migration.")

    for current, canonical, evidence in [
        ("campfire_cooking", "internal recipe/station state; not a placeable vanilla block ID", "Project marks this as a solid placeable cube even though the name describes a cooking action/station process."),
        ("raw_copper_block_item", "raw_copper item or raw_copper_block block, depending on intended form", "Project adds a custom *_item identifier rather than the vanilla item/block identifier; distinguish raw copper items from the Raw Copper Block."),
        ("wheat_crop", "wheat block state", "Vanilla crop is the wheat block with age state, not a separate wheat_crop registry block."),
        ("carrot_crop", "carrots block state", "Vanilla crop is the carrots block with age state, not a separate carrot_crop registry block."),
        ("potato_crop", "potatoes block state", "Vanilla crop is the potatoes block with age state, not a separate potato_crop registry block."),
        ("beetroot_crop", "beetroots block state", "Vanilla crop is the beetroots block with age state, not a separate beetroot_crop registry block."),
        ("poplar_leaves", "red_poplar_leaves / orange_poplar_leaves / yellow_poplar_leaves", "Official notes describe three coloured Poplar Leaves block variants; a generic uncoloured poplar_leaves ID may be an extra placeholder."),
        ("ghoul", "(no vanilla entity ID known)", "The entity catalogue includes ghoul, which is not a vanilla Minecraft Java entity type. It must be excluded unless the official 26.3 registry proves otherwise."),
    ]:
        is_entity = current == "ghoul"
        present = current in (json.loads((DATA / "entities.json").read_text()).get("entities", {}) if is_entity else blocks)
        add("canonical_id_suspects", "entity" if is_entity else "block/item", canonical, current if present else "(none)",
            "strong_suspect_noncanonical_or_misclassified" if present else "not_present", "high" if current in {"campfire_cooking","raw_copper_block_item","wheat_crop","carrot_crop","potato_crop","beetroot_crop","ghoul"} else "medium",
            evidence, "Verify against the authoritative Java 26.3 registry, then migrate or reclassify instead of silently deleting data; never expose a project-only ID as a vanilla Creative catalogue entry.")
    return rows

STATE_REQUIREMENTS = [
("Logs/wood", "axis=x|y|z and correct end-grain/side UV selection", "Partial", "poplar logs have a separate fallen-tree ID instead of fully using block axis/orientation.", "Use a state schema and test all three axes for each wood family."),
("Leaves", "distance=1..7, persistent, correct leaf tint/decay/drop rules", "Partial/unknown", "No explicit per-block state schema; biome tint/decay and exact leaf drop logic are not represented as registry data.", "Implement and test distance propagation, persistence, tint, decay, shears/tool behavior and falling-leaf particles."),
("Saplings", "stage, growth conditions and species/variant choice", "Partial", "Poplar sapling growth exists as a custom hook but lacks canonical variant/model validation.", "Use canonical Poplar Sapling and verified random red/orange/yellow tree variant selection."),
("Slabs", "type=bottom|top|double and waterlogged", "Partial", "Geometry stores half; the state is not defined declaratively for every slab and waterlogging is not fully supported.", "Implement all vanilla slab states, merge/split, waterlogging, drops and light/collision behavior."),
("Stairs", "facing, half, shape=straight|inner_left|inner_right|outer_left|outer_right, waterlogged", "Partial", "The current shape builder has a simple stepped geometry with facing/half; corner shapes and waterlogging are not represented.", "Implement neighbour-derived stair shapes and verify corner geometry/collision and UV rotation."),
("Doors", "facing, half, hinge, open, powered", "Partial", "The project stores selected open/facing/half properties; hinge and neighbour update parity are absent.", "Implement paired-door placement/removal, hinge side, redstone interaction, sound and state propagation."),
("Trapdoors", "facing, half, open, powered, waterlogged", "Partial", "Only selected open/half/facing state behavior exists; powered/waterlogged parity is missing.", "Validate orientation, opening direction, redstone and waterlogging."),
("Fences/gates/walls", "directional connection booleans, in_wall, open/powered and waterlogging", "Partial", "Fence connections exist for a limited set; wall block/model/state family is missing.", "Add canonical wall model family and all connectivity/occlusion variants."),
("Rails", "shape-specific rails, ascending directions, curves, powered/detector/activator states", "Partial", "The current rail geometry is a flat rectangular strip rather than Java's many rail models and states.", "Implement actual rail shape meshes, powered state transitions, slope collision and redstone integration."),
("Crops/plants", "correct registry ID plus age/stage and per-state model/collision", "Partial/incorrect IDs", "Four crops are project-suffixed IDs; visual height is approximated via age, without authoritative block-state names/models.", "Normalize IDs, use exact age ranges, hit/collision boxes, placement and drops."),
("Fluids", "level, falling, source, waterlogging, flow vectors/surfaces", "Partial", "Tick spread is simplified; fluid mesh UV/flow, face-height seams, waterlogging and Java scheduling are missing.", "Implement fluid surface heights/UV animation and parity tests for source, falling, corner and mixed fluid states."),
("Redstone dust", "north/east/south/west connection modes, power 0..15, dot/cross shapes", "Partial", "Power propagation exists, but state-specific wire connections and Java update order are not implemented.", "Implement connection states and compare loop/tick timing against controlled Java 26.3 circuits."),
("Repeaters/comparators", "facing, delay/mode, powered/locked plus exact signal rules", "Partial", "Basic delay/compare behavior exists; lock state, exact tick scheduling and side-input semantics are incomplete.", "Create table-driven truth tests and exact tick durations."),
("Pistons", "facing, extended, sticky type, piston-head type/short state and movable-block rules", "Partial", "Limited extend/retract logic; quasi-connectivity, block push reactions, slime/honey constraints and update order incomplete.", "Implement Java block movement reaction registry and regression fixtures."),
("Containers", "facing and single/left/right chest type; block entity inventory; open state", "Partial", "Basic saved container state exists; canonical block state/block-entity schemas and double-container joining need validation.", "Use block entity schemas, sided inventories, double-chest joining and comparator strength parity."),
("Beds/straw beds", "facing, part, occupied; bed spawn/sleep/explosion rules by dimension", "Partial", "Straw bed geometry is a single cuboid and doesn't prove pair states, sleep/respawn or bed state parity.", "Implement two-cell placement/state/drop and exact sleep/respawn/explosion behavior."),
("Signs/hanging signs", "rotation/facing, waterlogged, attached/support and text block entities", "Missing/partial", "Poplar sign IDs exist but sign/hanging-sign models, attachment states and text block entities are absent.", "Implement canonical sign models/state, front/back text, attachment/drop behavior and item components."),
("Portals", "axis/shape/valid frame and dimension teleport behavior", "Partial", "Portal plane and dimension transitions exist in simplified form; frame validation and portal collision/activation rules need parity.", "Test valid/invalid portal frames, axes, portal spread, lighting, and spectator interaction from 26.3."),
]

MECHANICS = [
("Blocks registry", "All canonical block IDs, state properties, collision/selection shapes, hardness/resistance, drops, light, sound, tags", "Critical", "Only 301 placeable definitions; combined project list is not a canonical Java registry and explicit state metadata is missing.", "Extract Java 26.3 client/server registry/model data, make a machine-readable reference manifest, compare every ID and field."),
("Models/rendering", "Each blockstate variant -> model, face texture, UV rotation, geometry, AO/lighting and transparency group", "Critical", "24-ish custom shape types; default cube fallback; no full blockstate/model graph or exact shape/state coverage.", "Import model/state metadata and add a rendered gallery/regression snapshot for all state variants."),
("Items/components", "All item IDs, stack limits, components, durability, food/fuel/equipment, use actions, block item links", "Critical", "Items are mixed into blocks.json, with per-target explorer-map pseudo IDs and no canonical component definitions.", "Separate item registry and item-stack component schema; migrate pseudo IDs to canonical components."),
("Recipes", "All crafting/cooking/smithing/stonecutting/brewing/special recipes and ingredients/conditions/remainders", "Critical", "194 simplified ingredient-map records; no full shaped/shapeless grid, recipe serializers, remainder logic or 26.3 data-driven brewing registry.", "Extract all 26.3 recipes; implement typed recipe serializers and a test for each type and result."),
("Entities", "Canonical entity-type registry, attributes, models, animation, AI, navigation, spawn rules, loot", "Critical", "82 simplified definitions and primitive visuals; includes suspect non-vanilla ghoul; many types are never fully spawned/implemented.", "Compare canonical entity registry, remove/migrate project-only types, add structured attributes/AI/model/loot/spawn schemas."),
("Biome/worldgen", "Biomes, dimension types, noise settings, configured/placed features, carvers, structure sets/pieces, placement rules", "Critical", "Dappled Forest and camp generation are approximations, not the data-driven Java worldgen registry.", "Import 26.3 worldgen registry inventory; implement/test each required dimension, biome, feature and structure placement."),
("Redstone", "Java signal levels, strong/weak power, quasi-connectivity, observer edges, repeater locks, update order/ticks", "Critical", "Subset simulation; exact tick scheduling, directional connectivity, inventory signal, quasi-connectivity and move reactions are incomplete.", "Build an automated known-circuit suite and compare signal traces to Java 26.3 reference runs."),
("Fluids/fire/weather", "Flow/surface levels, waterlogging, fluid reactions, fire ticks, weather, snow/ice, bubble columns", "Critical", "Basic fluid spread and hazards only; no full Java schedule, surfaces, waterlogging or weather rules.", "Implement state transitions and seeded regression scenes for boundaries, flowing water/lava, rain, ice and fire."),
("Lighting", "Block light, skylight, propagation/removal, occlusion, ambient occlusion, emissive model flags", "Critical", "Approximate day/night plus localized lights; no Java-equivalent propagation and sky/block light maps.", "Implement a voxel light engine and snapshot-test light shafts, caves, emission and transparency."),
("Loot/drops", "Block/entity loot tables, tool conditions, fortune/silk touch, components, random sequences", "High", "Entity drop tables exist in simplified dictionaries; no complete 26.3 loot-table registry or conditions.", "Extract and execute canonical loot tables with deterministic seeded tests."),
("Tags", "block/item/entity/biome/recipe/function tags and nested references", "High", "Sparse custom tags in per-block defs; no canonical versioned tag registries.", "Import tag definitions and validate all references and inherited membership."),
("26.3 data pack changes", "Data pack 121.0/resource pack 97.1; data-driven pottery sherds and potion recipes; block transformer; version-specific state/component formats", "High", "No data-driven registry layer for all these changes; item/recipe state is currently hard-coded/simple.", "Version schema to 26.3 and add tests for potion brewing, decorated-pot components, block transformations and new tag sets."),
("Mobile/render runtime", "Landscape APK, crisp 16x16 sampling, stable chunk mesh/collision, touch input and memory/performance", "High", "Static texture mapping only; no Godot parse, runtime-render or Android APK/device test was available during this audit.", "Run on Godot 4.7.2 and device, record screenshots plus startup, chunk seam, collision and performance checks."),
]


def dump_csv(path: Path, rows: list[dict]) -> None:
    if not rows: return
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)


def _registry_names(data, preferred_key: str | None = None) -> set[str]:
    """Extract simple registry identifiers from common Prismarine-style JSON layouts."""
    if isinstance(data, dict):
        if preferred_key and isinstance(data.get(preferred_key), (dict, list)):
            return _registry_names(data[preferred_key])
        # Mapping id -> definition
        if data and all(isinstance(k, str) for k in data.keys()):
            if all(isinstance(v, dict) for v in data.values()):
                return set(data.keys())
        values = data.values()
    elif isinstance(data, list):
        values = data
    else:
        return set()
    found = set()
    for value in values:
        if isinstance(value, str):
            found.add(value.removeprefix("minecraft:"))
        elif isinstance(value, dict):
            for key in ("name", "id", "identifier", "key"):
                if isinstance(value.get(key), str):
                    found.add(value[key].removeprefix("minecraft:"))
                    break
    return found


def optional_reference_compare(reference_dir: Path | None, blocks: dict, recipes: dict, entities: dict) -> dict:
    if reference_dir is None:
        return {"status": "not_supplied", "message": "No actual Java 26.3 registry dump was supplied/extracted in this environment; do not claim a full canonical ID diff.", "files_checked": []}
    manifest_path = reference_dir / "manifest.json"
    if not manifest_path.is_file():
        return {"status": "rejected_unversioned_reference", "message": "Provide manifest.json with version=26.3 and data_pack_version=121.0. Older-version data or an unverified scaffold must not be used for a parity claim.", "files_checked": []}
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"status": "invalid_reference_manifest", "message": str(exc), "files_checked": []}
    if str(manifest.get("version", "")) != "26.3" or str(manifest.get("data_pack_version", "")) not in {"121", "121.0"}:
        return {"status": "rejected_wrong_reference_version", "manifest": manifest, "message": "Reference must be a version-verified Java 26.3 snapshot with data pack version 121.0.", "files_checked": []}
    expected = ["blocks.json", "items.json", "recipes.json", "entities.json"]
    loaded = {}; results=[]
    for name in expected:
        p = reference_dir / name
        if not p.exists():
            results.append({"file": name, "status": "missing"})
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8")); loaded[name] = data
            results.append({"file": name, "status": "readable", "root_type": type(data).__name__, "entries": len(data) if hasattr(data, "__len__") else None})
        except Exception as e:
            results.append({"file": name, "status": "invalid_json", "error": str(e)})
    if "blocks.json" not in loaded or "items.json" not in loaded:
        return {"status": "incomplete_reference_dir", "manifest": manifest, "files_checked": results, "message": "Canonical comparison needs readable blocks.json and items.json at minimum."}
    vanilla_blocks = _registry_names(loaded["blocks.json"], "blocks")
    vanilla_items = _registry_names(loaded["items.json"], "items")
    vanilla_entity_names = _registry_names(loaded["entities.json"], "entities") if "entities.json" in loaded else set()
    vanilla_recipes = loaded.get("recipes.json", [])
    project_ids = set(blocks)
    canonical_content_ids = vanilla_blocks | vanilla_items
    diffs=[]
    for bid in sorted(project_ids - canonical_content_ids):
        diffs.append({"registry": "combined_project_catalogue", "identifier": bid, "status": "project_id_not_in_vanilla_block_or_item_registry", "action": "verify_alias; migrate/reclassify before release"})
    for bid in sorted(canonical_content_ids - project_ids):
        diffs.append({"registry": "block_or_item", "identifier": bid, "status": "vanilla_id_missing_from_project_catalogue", "action": "add canonical definition, model/state/item link and texture; do not invent an ID"})
    for eid in sorted(set(entities) - vanilla_entity_names) if vanilla_entity_names else []:
        diffs.append({"registry": "entity", "identifier": eid, "status": "project_entity_id_not_in_vanilla_registry", "action": "verify or remove as non-vanilla with save migration"})
    for eid in sorted(vanilla_entity_names - set(entities)):
        diffs.append({"registry": "entity", "identifier": eid, "status": "vanilla_entity_missing_from_project", "action": "implement definition, model, behavior, spawn rules, drops and sounds"})
    dump_csv(DOCS / "JAVA_26.3_EXTERNAL_REGISTRY_DIFF.csv", diffs)
    good = all(x["status"] == "readable" for x in results)
    return {"status": "canonical_id_diff_generated" if good else "partial_registry_diff_generated", "manifest": manifest,
            "files_checked": results, "vanilla_block_ids": len(vanilla_blocks), "vanilla_item_ids": len(vanilla_items),
            "vanilla_entity_ids": len(vanilla_entity_names), "vanilla_recipe_records": len(vanilla_recipes) if hasattr(vanilla_recipes, "__len__") else None,
            "project_catalogue_ids_not_in_vanilla": sum(x["status"] == "project_id_not_in_vanilla_block_or_item_registry" for x in diffs),
            "vanilla_block_or_item_ids_missing_from_project": sum(x["status"] == "vanilla_id_missing_from_project_catalogue" for x in diffs),
            "project_entities_not_in_vanilla": sum(x["status"] == "project_entity_id_not_in_vanilla_registry" for x in diffs),
            "vanilla_entities_missing_from_project": sum(x["status"] == "vanilla_entity_missing_from_project" for x in diffs),
            "diff_csv": "docs/JAVA_26.3_EXTERNAL_REGISTRY_DIFF.csv",
            "message": "ID diff generated against caller-supplied versioned reference. Model/state/recipe semantics still need schema-aware comparison and runtime tests."}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference-dir", type=Path, help="Optional directory containing canonical 26.3 blocks/items/recipes/entities JSON dumps")
    args = ap.parse_args()
    blocks_doc = json.loads((DATA / "blocks.json").read_text(encoding="utf-8"))
    recipes_doc = json.loads((DATA / "recipes.json").read_text(encoding="utf-8"))
    entities_doc = json.loads((DATA / "entities.json").read_text(encoding="utf-8"))
    blocks = blocks_doc.get("blocks", {})
    recipes = recipes_doc.get("recipes", {})
    entities = entities_doc.get("entities", {})
    atlas_map = json.loads((ROOT / "assets/textures/atlas_map.json").read_text(encoding="utf-8")).get("tiles", {})
    root_counts = {"catalogue_entries": len(blocks), "placeable_entries": sum(bool(x.get("placeable")) for x in blocks.values()),
                   "solid_entries": sum(bool(x.get("solid")) for x in blocks.values()),
                   "solid_placeable_entries": sum(bool(x.get("placeable")) and bool(x.get("solid")) for x in blocks.values()),
                   "recipe_records": len(recipes), "entity_definitions": len(entities),
                   "face_swatches": sum(len(x.get("tiles", {})) for x in blocks.values()),
                   "unique_shape_labels": len(set(str(x.get("shape", "cube")) for x in blocks.values()))}
    cat_rows = []
    for bid, d in blocks.items():
        cat_rows.append({"id": bid, "display_name": d.get("name", ""), "category": d.get("category", ""),
                         "placeable": bool(d.get("placeable", False)), "solid": bool(d.get("solid", False)),
                         "shape": d.get("shape", "cube"), "face_count": len(d.get("tiles", {})),
                         "canonical_status": "not_verified_against_full_26_3_registry",
                         "audit_note": "Combined block/item catalogue entry; canonical registry identity/model/state not proven by local project data.",
                         "next_improvement": "Compare ID, item form, model/state variants, drops, tags and recipe mapping with the extracted 26.3 registry."})
    feature_rows = expected_feature_rows(blocks)
    state_rows = [{"family": a, "expected_vanilla_state_or_behavior": b, "current_coverage": c, "observed_gap": d, "next_improvement": e} for a,b,c,d,e in STATE_REQUIREMENTS]
    mechanics_rows = [{"system": a, "expected_java_26_3_scope": b, "priority": c, "observed_gap": d, "next_improvement": e} for a,b,c,d,e in MECHANICS]

    # Reference and internal consistency checks, intentionally separated from external canonical completeness.
    reference_ids_doc = json.loads((DOCS / "catalogue_ids_0.5.0_reference.json").read_text(encoding="utf-8"))
    base_ids = set(reference_ids_doc.get("ids", [])); curr_ids = set(blocks)
    added_vs_baseline = sorted(curr_ids - base_ids); removed_vs_baseline = sorted(base_ids - curr_ids)
    missing_recipe_refs = []
    for rid, recipe in recipes.items():
        out = recipe.get("result", rid)
        if out not in curr_ids: missing_recipe_refs.append({"recipe": rid, "field": "result", "missing_id": out})
        for ing in recipe.get("ingredients", {}):
            if ing not in curr_ids: missing_recipe_refs.append({"recipe": rid, "field": "ingredient", "missing_id": ing})
    missing_drops = []
    for eid, ed in entities.items():
        for drop in ed.get("drops", []):
            if drop.get("id") not in curr_ids: missing_drops.append({"entity": eid, "missing_drop_id": drop.get("id")})
    ref_status = optional_reference_compare(args.reference_dir, blocks, recipes, entities)
    report_payload = {"target": {"edition": "Minecraft Java Edition", "version": "26.3", "data_pack_version": "121.0", "resource_pack_version": "97.1", "engine": "Godot 4.7.2"},
                      "project_version": (ROOT / "VERSION.txt").read_text().splitlines()[0].replace("Version: ", ""),
                      "counts": root_counts, "baseline_preservation": {"baseline_ids": len(base_ids), "current_ids": len(curr_ids), "added_vs_0_5_0": added_vs_baseline, "removed_vs_0_5_0": removed_vs_baseline},
                      "internal_references": {"recipes_with_missing_catalogue_refs": missing_recipe_refs, "entity_drops_missing_from_catalogue": missing_drops},
                      "official_reference_dump": ref_status, "feature_delta_audit": feature_rows,
                      "sources": {"official_release": OFFICIAL_RELEASE, "official_changelog": OFFICIAL_CHANGELOG, "prismarine_26_3_pr": PRISMARINE_26_3, "prismarine_26_3_followup": PRISMARINE_26_3_FOLLOWUP, "schema_example_26_1_blocks": PRISMARINE_BLOCKS_26_1, "schema_example_26_1_items": PRISMARINE_ITEMS_26_1}}

    DOCS.mkdir(exist_ok=True)
    dump_csv(DOCS / "JAVA_26.3_CATALOGUE_COVERAGE_0.5.3.csv", cat_rows)
    dump_csv(DOCS / "JAVA_26.3_FEATURE_DELTA_AUDIT_0.5.3.csv", feature_rows)
    dump_csv(DOCS / "JAVA_26.3_BLOCK_STATE_GAPS_0.5.3.csv", state_rows)
    dump_csv(DOCS / "JAVA_26.3_MECHANICS_GAPS_0.5.3.csv", mechanics_rows)
    (DOCS / "JAVA_26.3_AUDIT_DATA_0.5.3.json").write_text(json.dumps(report_payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    alias_n = sum(r["status"] == "legacy_alias_present" for r in feature_rows)
    missing_n = sum(r["status"] == "missing" for r in feature_rows)
    suspect_n = sum(r["status"] in {"noncanonical_pseudo_item_family", "strong_suspect_noncanonical_or_misclassified", "needs_registry_normalization", "likely_worldgen_as_block_misclassification"} for r in feature_rows)
    md = f"""# Java 26.3 completeness audit — Flatworld {report_payload['project_version']}\n\n**Scope of this pass:** catalogue/state/model/item/recipe/entity/mechanics audit first. This pass does not change or remove any gameplay catalogue entries, and it does not claim the game is complete.\n\n## Executive result\n\nThe current project contains **{root_counts['catalogue_entries']} combined catalogue entries** ({root_counts['placeable_entries']} placeable, {root_counts['solid_placeable_entries']} solid+placeable), **{root_counts['recipe_records']} recipe records**, **{root_counts['entity_definitions']} entity definitions**, **{root_counts['face_swatches']} registered face swatches**, and {root_counts['unique_shape_labels']} explicit shape labels. These counts are project-data counts, **not** vanilla Java 26.3 registry counts. The catalogue combines blocks, items, crops, map variants and station-like entries into one structure; there is no independent canonical item registry or declarative per-block state registry.\n\nThe local integrity checks show **{len(missing_recipe_refs)} recipe result/ingredient references missing from the current catalogue** and **{len(missing_drops)} entity drop references missing from the current catalogue**. These checks validate only project-internal IDs, not vanilla completeness.\n\nBaseline preservation: {len(base_ids)} IDs are in the 0.5.0 manifest; current={len(curr_ids)}, added={len(added_vs_baseline)}, removed={len(removed_vs_baseline)}. This audit pass itself made no catalogue changes.\n\n## Highest-priority findings\n\n1. **Canonical IDs are not consistently vanilla.** The color/material order is reversed for all wool and concrete base blocks and their stair/slab families. This creates {alias_n} legacy-alias rows in the feature audit. These should be normalized using save migrations, not by simply deleting/renaming keys.\n2. **26.3 additions need authoritative ID/state normalization.** The official release adds a Dappled Forest, Poplar wood set, three Poplar Leaves colors, shelf mushrooms, red shrubs, abandoned camps, explorer maps, cushions, straw beds, and wool/concrete stairs/slabs for all colors. The current catalogue has several candidate placeholders and does not prove correct canonical IDs, item stacks, states, models, or world-generation semantics. The feature audit marks {missing_n} expected family entries missing and {suspect_n} groups requiring normalization/registry verification.\n3. **Blocks and items are conflated.** Inventory is built from every key in `blocks.json`, including non-placeable items, pseudo-map variants and processing/station-like entries. This invites non-vanilla IDs and duplicate items. A proper implementation needs separate block, item-stack/component, model, and block-entity registries.\n4. **Block-state properties are runtime ad hoc dictionaries.** There is no canonical declarative state registry. Only selected fields such as `facing`, `half`, `open`, `powered`, `power`, `level`, `age`, `extended` and `eye` are accessed in current code. This is insufficient for all Java block-state variants, connection shapes, waterlogging, door hinge, stair corners, rail curves/slopes, leaf decay, and many other states. See `JAVA_26.3_BLOCK_STATE_GAPS_0.5.3.csv`.\n5. **Models are broad geometry categories, not the vanilla model/state graph.** The mesher provides a fallback cube, plus simple slab/stair, plant, fence, rail, door/trapdoor and selected component shapes. State-derived geometry is incomplete; the presence of a texture tile does not mean the state/model renders correctly.\n6. **Recipes are a sample, not the full registry.** The project has {root_counts['recipe_records']} simplified records using a direct ingredient map and one result/count. This cannot represent all Java recipe serializers, shaped/shapeless grids, remainders, conditions, smithing/stonecutting/cooking details or the 26.3 data-driven brewing recipe system.\n7. **Entity catalogue needs canonical diff and behavior coverage.** There are {root_counts['entity_definitions']} simple definitions, and `ghoul` is a strong non-vanilla-ID suspect. Defined entities are not necessarily spawned, modelled, animated, navigable or behavior-complete.\n8. **World-gen/technical registries are missing.** Dappled Forest and camp hooks are project-side approximations, not full Java biome/feature/structure registries. 26.3 also identifies data pack version **121.0**, resource pack version **97.1**, data-driven pottery sherds and potion recipes, block transformers, and changes to state/component semantics.\n9. **No Godot or Android runtime test was possible in this environment.** Static data review cannot verify parsing, material rendering, collision, mobile controls, landscape APK startup or performance.\n\n## Canonical 26.3 content audit\n\nThe official 26.3 changelog is used to establish the update-specific feature delta. The CSV lists each expected family/member and the current project ID or nearest alias. Some rows are marked medium confidence where the exact block-vs-item/state representation must be confirmed from the version's actual registry rather than guessed.\n\n- `JAVA_26.3_FEATURE_DELTA_AUDIT_0.5.3.csv`: individual expected feature IDs, current aliases, confidence and next step.\n- `JAVA_26.3_CATALOGUE_COVERAGE_0.5.3.csv`: all current catalogue entries and the fields still needing authoritative registry/model/state comparison.\n- `JAVA_26.3_BLOCK_STATE_GAPS_0.5.3.csv`: key block-state families.\n- `JAVA_26.3_MECHANICS_GAPS_0.5.3.csv`: block, model, item, recipe, entity, worldgen and mechanics gaps.\n- `JAVA_26.3_AUDIT_DATA_0.5.3.json`: machine-readable audit counts and results.\n\n## Reference-data limitation — do not overclaim\n\nThe official Mojang article gives the 26.3 release delta and version numbers, but the actual full 26.3 client/server registry dump was not available locally during this pass. PrismarineJS's 26.3 data PR and follow-up are useful public schema/coverage leads; the PR discussion explicitly warns that the initial 26.3 branch was a version scaffold and must not be treated as complete registry validation. Therefore this is a **grounded first-pass audit**, not a claim that every one of the thousands of canonical registry entries has been compared yet. The next required operation is to extract/version-check authoritative 26.3 registries (blocks, states, items, models, recipes, entities, tags, biomes, configured/placed features, structures, loot and sounds), then generate a full name-by-name diff.\n\n## Safe implementation sequence\n\n1. Extract a verifiably 26.3 client/server data reference; store provenance, hashes, and extraction steps. Do not use an older-version scaffold as if it were exact.\n2. Normalize IDs with a legacy save migration and compatibility tests. Do not add pseudo-items as new vanilla entries.\n3. Separate registries: block definitions/states, item IDs/components, block/item models, recipes, entities/loot, tags, biome/worldgen/features/structures, sounds.\n4. Fill every canonical registry ID and state/model variant; generate material/geometry where required instead of rendering unsupported models as cubes. Preserve all authentic vanilla content while removing only project-created aliases after they are migrated.\n5. Add reference-driven tests for every block state, model render, collision/selection shape, recipes and mechanics. Finally run Godot 4.7.2 and Android APK/device QA before calling it release-ready.\n\n## Sources\n\n- Official Minecraft Java Edition 26.3 release: {OFFICIAL_RELEASE}\n- Official Minecraft Java Edition 26.3 changelog: {OFFICIAL_CHANGELOG}\n- PrismarineJS 26.3 support PR (version scaffold/coverage lead): {PRISMARINE_26_3}\n- PrismarineJS follow-up 26.3 data PR: {PRISMARINE_26_3_FOLLOWUP}\n- 26.1 public data schema examples (not used as an exact 26.3 reference): {PRISMARINE_BLOCKS_26_1} and {PRISMARINE_ITEMS_26_1}\n"""
    (DOCS / "JAVA_26.3_COMPLETENESS_AUDIT_0.5.3.md").write_text(md, encoding="utf-8")
    feature_manifest = {
        "target": {"edition": "Minecraft Java Edition", "version": "26.3", "data_pack_version": 121, "resource_pack_version": "97.1"},
        "official_delta_sources": [OFFICIAL_RELEASE, OFFICIAL_CHANGELOG],
        "families": [
            {"id": "dappled_forest", "kind": "biome/worldgen", "official": True, "expected_scope": ["biome definition", "placement conditions near cold biomes", "poplar tree and fallen-tree features", "red shrub patches", "abandoned camp variant", "cold variants for sheep/chicken/cow/pig/rabbit/fox" ]},
            {"id": "poplar_wood_set", "kind": "block/item/model/recipe", "official": True, "expected_members": ["poplar_log", "poplar_wood", "stripped_poplar_log", "stripped_poplar_wood", "poplar_planks", "poplar_stairs", "poplar_slab", "poplar_fence", "poplar_fence_gate", "poplar_door", "poplar_trapdoor", "poplar_pressure_plate", "poplar_button", "poplar_sign", "poplar_hanging_sign", "poplar_sapling", "poplar_boat", "poplar_chest_boat", "red_poplar_leaves", "orange_poplar_leaves", "yellow_poplar_leaves"], "notes": "Boats are medium-confidence until checked against actual 26.3 registry. Need log axis, stripped variants, wood set recipes, leaves decay/variant drops and particle tints."},
            {"id": "shelf_mushroom", "kind": "block/item/state/recipe", "official": True, "expected_scope": ["small/large forms", "bonemeal small-to-large growth", "large break drops two items", "stew use", "wandering trader trade", "bed-like bounce"]},
            {"id": "red_shrub", "kind": "block/worldgen/bonemeal/compost", "official": True, "expected_scope": ["Dappled Forest patch generation", "compostable", "bonemeal grows adjacent shrub if valid space"]},
            {"id": "abandoned_camp", "kind": "structure/worldgen/loot", "official": True, "expected_scope": ["structure definitions and placement", "Dappled Forest variant", "loot/blocks/entities", "structure pieces not extra vanilla block IDs"]},
            {"id": "explorer_maps", "kind": "item components/trades", "official": True, "expected_scope": ["canonical map item stack/data/components", "target structure data", "wandering/villager trades if applicable", "cloning/extension tags"]},
            {"id": "cushions", "kind": "block/model/state/collision", "official": True, "expected_scope": ["shape/collision", "placement/support", "collision-shape raycast tag", "dampens vibration tag membership"]},
            {"id": "straw_beds", "kind": "block/model/state/sleep", "official": True, "expected_scope": ["paired halves", "facing", "occupied", "sleep/respawn", "bounce and dimensions behavior"]},
            {"id": "wool_slabs_stairs", "kind": "block/model/state/tag", "official": True, "colors": COLORS, "expected_members_per_color": ["{color}_wool_slab", "{color}_wool_stairs"], "expected_scope": ["all vanilla stair/slab states", "collision and selection shapes", "waterlogging", "dampens_vibrations tag"]},
            {"id": "concrete_slabs_stairs", "kind": "block/model/state/recipe", "official": True, "colors": COLORS, "expected_members_per_color": ["{color}_concrete_slab", "{color}_concrete_stairs"], "expected_scope": ["all vanilla stair/slab states", "collision/selection shapes", "recipes and item links"]},
            {"id": "26_3_technical", "kind": "data-driven mechanics", "official": True, "expected_scope": ["data pack 121.0", "resource pack 97.1", "potion brewing recipes data-driven", "pottery sherds data-driven", "block_transformer registry", "updated block state and item component formats", "26.3 tags and loot/data conditions"]},
        ],
        "not_a_complete_registry_dump": True,
        "reason": "Official changelog-derived feature coverage only; full canonical IDs/state properties/models/recipes/entities still require version-verified 26.3 client/server registry extraction."
    }
    (DOCS / "JAVA_26.3_EXPECTED_FEATURES_0.5.3.json").write_text(json.dumps(feature_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(json.dumps({"counts": root_counts, "feature_audit_rows": len(feature_rows), "state_gap_rows": len(state_rows), "mechanics_gap_rows": len(mechanics_rows),
                      "missing_recipe_refs": len(missing_recipe_refs), "missing_entity_drop_refs": len(missing_drops), "baseline_added": added_vs_baseline, "baseline_removed": removed_vs_baseline,
                      "reference_dump": ref_status["status"], "outputs": ["docs/JAVA_26.3_COMPLETENESS_AUDIT_0.5.3.md", "docs/JAVA_26.3_CATALOGUE_COVERAGE_0.5.3.csv", "docs/JAVA_26.3_FEATURE_DELTA_AUDIT_0.5.3.csv", "docs/JAVA_26.3_BLOCK_STATE_GAPS_0.5.3.csv", "docs/JAVA_26.3_MECHANICS_GAPS_0.5.3.csv", "docs/JAVA_26.3_AUDIT_DATA_0.5.3.json", "docs/JAVA_26.3_EXPECTED_FEATURES_0.5.3.json"]}, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
