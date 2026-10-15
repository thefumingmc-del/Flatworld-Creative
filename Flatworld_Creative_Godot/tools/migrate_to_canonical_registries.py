#!/usr/bin/env python3
"""One-time, repeatable Flatworld 0.5.4 canonical-ID + separated-registry migration.

This converts only identifiers confirmed against the Java 26.3 reference registry,
removes project-only pseudo block/item/entity entries, and preserves the current
runtime's visual metadata as a derived fallback. It does NOT claim that the
remaining project catalogue is a complete vanilla registry; use
sync_java_26_3_reference.py to import official reports and datapack JSON.
"""
from __future__ import annotations
import json, re, shutil, hashlib
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "assets" / "data"
BLOCKS_PATH = DATA / "blocks.json"
RECIPES_PATH = DATA / "recipes.json"
ENTITIES_PATH = DATA / "entities.json"
ATLAS_MAP_PATH = ROOT / "assets" / "textures" / "atlas_map.json"
SWATCH_DIR = ROOT / "assets" / "textures" / "blocks"
ATLAS_PATH = ROOT / "assets" / "textures" / "atlas.png"
REG_DIR = DATA / "registries" / "26.3"

COLORS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"]

# Verified against the versioned 26.3 block/item registry snapshot documented in
# docs/VANILLA_26.3_REFERENCE_SOURCES.md.
DROP_IDS = {
    "campfire_cooking", "fallen_poplar_log", "fallen_poplar_tree",
    "raw_iron_block_item", "raw_gold_block_item", "raw_copper_block_item",
}
DROP_ITEM_ONLY_IDS = set()  # themed map aliases normalize to the single vanilla filled_map item

MAP_ALIAS = {
    "explorer_map_ocean_monument": "filled_map",
    "explorer_map_woodland_mansion": "filled_map",
    "explorer_map_buried_treasure": "filled_map",
    "explorer_map_abandoned_camp": "filled_map",
    "explorer_map_buried_trial_chambers": "filled_map",
    "explorer_map_jungle_pyramid": "filled_map",
    "explorer_map_swamp_hut": "filled_map",
    "explorer_map_desert_village": "filled_map",
    "explorer_map_plains_village": "filled_map",
    "explorer_map_savanna_village": "filled_map",
    "explorer_map_snowy_village": "filled_map",
    "explorer_map_taiga_village": "filled_map",
    "explorer_map_buried_ancient_city": "filled_map",
    "explorer_map_buried_mineshaft": "filled_map",
    "explorer_map_desert_pyramid": "filled_map",
    "explorer_map_warm_ocean_ruins": "filled_map",
    "explorer_map_camp_bamboo_jungle": "filled_map",
    "explorer_map_camp_birch_forest": "filled_map",
    "explorer_map_camp_cherry_grove": "filled_map",
    "explorer_map_camp_dappled_forest": "filled_map",
    "explorer_map_camp_flower_forest": "filled_map",
    "explorer_map_camp_pale_garden": "filled_map",
    "explorer_map_camp_swamp": "filled_map",
    "explorer_map_camp_windswept_forest": "filled_map",
    "abandoned_camp_map": "filled_map",
    "buried_ancient_city_map": "filled_map",
    "buried_mineshaft_map": "filled_map",
    "buried_treasure_map": "filled_map",
    "buried_trial_chambers_map": "filled_map",
    "desert_pyramid_map": "filled_map",
    "desert_village_map": "filled_map",
    "jungle_pyramid_map": "filled_map",
    "ocean_monument_map": "filled_map",
    "plains_village_map": "filled_map",
    "savanna_village_map": "filled_map",
    "snowy_village_map": "filled_map",
    "swamp_hut_map": "filled_map",
    "taiga_village_map": "filled_map",
    "warm_ocean_ruins_map": "filled_map",
    "woodland_mansion_map": "filled_map",
}

SIMPLE_ALIASES = {
    "raw_porkchop": "porkchop",
    "raw_beef": "beef",
    "raw_chicken": "chicken",
    "enchanting_book": "enchanted_book",
    "seeds": "wheat_seeds",
}


def canon_id(old: str) -> str | None:
    if old in DROP_IDS or old in DROP_ITEM_ONLY_IDS:
        return None
    if old in MAP_ALIAS:
        return MAP_ALIAS[old]
    if old in SIMPLE_ALIASES:
        return SIMPLE_ALIASES[old]
    m = re.fullmatch(r"(wool|concrete)_([a-z_]+)", old)
    if m:
        material, rest = m.groups()
        for color in sorted(COLORS, key=len, reverse=True):
            if rest == color:
                return f"{color}_{material}"
            if rest in (color + "_slab", color + "_stairs"):
                suffix = rest[len(color):]
                return f"{color}_{material}{suffix}"
    m = re.fullmatch(r"poplar_leaves_(red|orange|yellow)", old)
    if m:
        return f"{m.group(1)}_poplar_leaves"
    if old in {"shelf_mushrooms", "shelf_mushroom_small", "shelf_mushroom_large"}:
        return "shelf_mushroom"
    return old


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def rename_swatch(old_id: str, new_id: str, faces: set[str]) -> None:
    for face in faces:
        src = SWATCH_DIR / f"{old_id}_{face}.png"
        dst = SWATCH_DIR / f"{new_id}_{face}.png"
        if src.exists() and src != dst:
            dst.parent.mkdir(parents=True, exist_ok=True)
            # If canonical destination already exists, canonical destination wins.
            if not dst.exists():
                src.replace(dst)
            else:
                src.unlink()


def build_states(blocks: dict[str, dict]) -> dict:
    """Conservative state requirements for known current blocks; source marks these provisional.

    Exact per-block Java values are filled from the official server report by the sync tool.
    """
    out = {}
    def prop(kind: str, values: list[str] | None = None, minv=None, maxv=None) -> dict:
        d = {"type": kind}
        if values is not None: d["values"] = values
        if minv is not None: d["min"] = minv
        if maxv is not None: d["max"] = maxv
        return d
    for bid, b in blocks.items():
        p: dict[str, dict] = {}
        if bid.endswith("_slab"):
            p = {"type": prop("enum", ["bottom", "top", "double"]), "waterlogged": prop("bool", ["false", "true"])}
        elif bid.endswith("_stairs"):
            p = {"facing": prop("enum", ["north", "south", "west", "east"]), "half": prop("enum", ["top", "bottom"]), "shape": prop("enum", ["straight", "inner_left", "inner_right", "outer_left", "outer_right"]), "waterlogged": prop("bool", ["false", "true"])}
        elif bid.endswith("_door") or bid == "oak_door":
            p = {"facing": prop("enum", ["north", "south", "west", "east"]), "half": prop("enum", ["lower", "upper"]), "hinge": prop("enum", ["left", "right"]), "open": prop("bool", ["false", "true"]), "powered": prop("bool", ["false", "true"])}
        elif bid.endswith("_trapdoor"):
            p = {"facing": prop("enum", ["north", "south", "west", "east"]), "half": prop("enum", ["top", "bottom"]), "open": prop("bool", ["false", "true"]), "powered": prop("bool", ["false", "true"]), "waterlogged": prop("bool", ["false", "true"])}
        elif re.search(r"(?:^|_)(?:stripped_)?(?:oak|spruce|birch|jungle|acacia|dark_oak|cherry|pale_oak|mangrove|poplar)_?(?:log|wood)$", bid) or bid in {"bamboo_block", "stripped_bamboo_block"}:
            p = {"axis": prop("enum", ["x", "y", "z"])}
        elif bid.endswith("_leaves"):
            p = {"distance": prop("int", minv=1, maxv=7), "persistent": prop("bool", ["false", "true"]), "waterlogged": prop("bool", ["false", "true"])}
        elif bid in {"redstone_wire", "redstone_dust"}:
            p = {side: prop("enum", ["none", "side", "up"]) for side in ["north", "east", "south", "west"]}
            p["power"] = prop("int", minv=0, maxv=15)
        elif "rail" in bid:
            p = {"shape": prop("enum", ["north_south", "east_west", "ascending_east", "ascending_west", "ascending_north", "ascending_south", "south_east", "south_west", "north_west", "north_east"])}
            if "powered" in bid or "detector" in bid or "activator" in bid: p["powered"] = prop("bool", ["false", "true"])
        elif bid in {"repeater", "redstone_repeater"}:
            p = {"facing": prop("enum", ["north", "south", "west", "east"]), "delay": prop("int", minv=1, maxv=4), "locked": prop("bool", ["false", "true"]), "powered": prop("bool", ["false", "true"])}
        elif bid in {"comparator", "redstone_comparator"}:
            p = {"facing": prop("enum", ["north", "south", "west", "east"]), "mode": prop("enum", ["compare", "subtract"]), "powered": prop("bool", ["false", "true"])}
        elif bid.endswith("_button") or bid == "stone_button":
            p = {"face": prop("enum", ["floor", "wall", "ceiling"]), "facing": prop("enum", ["north", "south", "west", "east"]), "powered": prop("bool", ["false", "true"])}
        elif bid.endswith("_pressure_plate") or bid in {"stone_pressure_plate", "heavy_weighted_pressure_plate", "light_weighted_pressure_plate"}:
            p = {"powered": prop("bool", ["false", "true"])}
        elif bid in {"shelf_mushroom"}:
            p = {"age": prop("int", minv=0, maxv=1), "facing": prop("enum", ["north", "south", "west", "east"])}
        elif "crop" in bid or bid in {"wheat", "carrots", "potatoes", "beetroots", "nether_wart", "sweet_berry_bush", "cocoa"}:
            max_age = 7 if bid not in {"beetroots", "nether_wart"} else 3
            p = {"age": prop("int", minv=0, maxv=max_age)}
        elif bid in {"redstone_lamp"}:
            p = {"lit": prop("bool", ["false", "true"])}
        if p:
            out[bid] = {"properties": p, "source_status": "provisional_project_mapping", "complete": False}
        else:
            out[bid] = {"properties": {}, "source_status": "not_yet_imported_from_vanilla_report", "complete": False}
    out["air"] = {"properties": {}, "source_status": "verified_registry_id_only", "complete": False}
    return out


def main() -> int:
    old_doc = json.loads(BLOCKS_PATH.read_text(encoding="utf-8"))
    old_blocks: dict[str, dict] = old_doc["blocks"]
    old_map = json.loads(ATLAS_MAP_PATH.read_text(encoding="utf-8"))
    old_recipes_doc = json.loads(RECIPES_PATH.read_text(encoding="utf-8"))
    old_entities_doc = json.loads(ENTITIES_PATH.read_text(encoding="utf-8"))

    migration = {}
    removed = []
    new_blocks: dict[str, dict] = {}
    source_for_key: dict[str, str] = {}
    # Canonical re-keying. Collisions are only used for the single canonical shelf_mushroom:
    # the small shape becomes the visual representative; age state controls model in a future renderer pass.
    ordered_ids = sorted(old_blocks.keys(), key=lambda key: (canon_id(key) != key, key))
    for old_id in ordered_ids:
        definition = old_blocks[old_id]
        new_id = canon_id(old_id)
        if new_id is None:
            removed.append(old_id); continue
        migration[old_id] = new_id
        if new_id == "shelf_mushroom" and new_id in new_blocks:
            # Preserve a single id; base visual from the smaller shape, which is closer to the
            # canonical placed block's reduced geometry. Add explicit age/facing state in state registry.
            if old_id == "shelf_mushroom_small":
                new_blocks[new_id] = dict(definition)
                source_for_key[new_id] = old_id
            continue
        if new_id in new_blocks:
            # `seeds` was a project-generic alias while `wheat_seeds` is the actual Java ID.
            # Keep the canonical entry already present and drop the generic pseudo-item.
            if old_id == "seeds" and new_id == "wheat_seeds":
                removed.append(old_id)
                continue
            raise SystemExit(f"Unplanned canonical ID collision: {old_id} -> {new_id}")
        new_blocks[new_id] = dict(definition)
        source_for_key[new_id] = old_id
    # Force shelf mushroom to use the source file that actually represents small-state geometry.
    if "shelf_mushroom" in new_blocks:
        base = new_blocks["shelf_mushroom"]
        base["name"] = "Shelf Mushroom"
        base["category"] = "Nature"
        base["solid"] = False
        base["placeable"] = True
        base["shape"] = "plant"
        base["width"] = 0.62
        base["height"] = 0.28
        base["states"] = {"age": [0, 1], "facing": ["north", "south", "west", "east"]}

    # Rewrite cross references inside block metadata, including variant IDs.
    for bid, definition in new_blocks.items():
        for key, val in list(definition.items()):
            if isinstance(val, str) and val in migration:
                definition[key] = migration[val]
            elif isinstance(val, list):
                definition[key] = [migration.get(x, x) if isinstance(x, str) else x for x in val]

    # Canonical item/runtime aliases in recipes/entities and GDScript literal refs.
    def mapped(x):
        if not isinstance(x, str): return x
        return migration.get(x, x)
    recipe_records = old_recipes_doc.get("recipes", {})
    new_recipes = {}
    for rid, rec in recipe_records.items():
        new_rid = mapped(rid)
        record = dict(rec)
        record["ingredients"] = {mapped(k): v for k, v in record.get("ingredients", {}).items() if mapped(k) is not None}
        record["result"] = mapped(record.get("result", ""))
        record["recipe_type"] = "flatworld:ingredient_map"
        record["authoritative_vanilla_recipe"] = False
        # Drop recipe entries whose outputs were pseudo items slated for deletion.
        if record["result"] is None or not record["result"]:
            continue
        if new_rid in new_recipes:
            new_rid = f"legacy_{new_rid}"
        new_recipes[new_rid] = record
    # Correct duplicate recipe identifier for the merged shelf mushroom only by omission; there
    # are no recipes that output shelf age variants in the current sample.
    old_entities = old_entities_doc.get("entities", {})
    new_entities = {}
    for eid, rec in old_entities.items():
        if eid == "ghoul":
            continue
        entity = dict(rec)
        entity["drops"] = [{**d, "id": mapped(d.get("id", ""))} for d in entity.get("drops", []) if mapped(d.get("id", ""))]
        new_entities[eid] = entity

    # Rename or remove all texture PNGs based on original -> canonical mappings. For merged
    # shelf-mushroom states, use its small-state textures and delete the redundant variants.
    originals_by_new: dict[str, list[str]] = {}
    for old_id, new_id in migration.items():
        if new_id is not None:
            originals_by_new.setdefault(new_id, []).append(old_id)
    face_sets = {bid: set(defn.get("tiles", {})) for bid, defn in old_blocks.items()}
    for old_id, new_id in migration.items():
        if new_id == old_id:
            continue
        if new_id is not None and new_id != "shelf_mushroom":
            rename_swatch(old_id, new_id, face_sets.get(old_id, set()))
    # For shelf mushroom, explicitly move small textures to the canonical filename. If already
    # present, canonical one wins, then remove plural/large aliases.
    if "shelf_mushroom" in new_blocks:
        if source_for_key.get("shelf_mushroom") == "shelf_mushroom_small":
            rename_swatch("shelf_mushroom_small", "shelf_mushroom", face_sets.get("shelf_mushroom_small", set()))
        else:
            rename_swatch("shelf_mushrooms", "shelf_mushroom", face_sets.get("shelf_mushrooms", set()))
        for old in ["shelf_mushrooms", "shelf_mushroom_small", "shelf_mushroom_large"]:
            if old == source_for_key.get("shelf_mushroom"): continue
            for face in face_sets.get(old, set()):
                p = SWATCH_DIR / f"{old}_{face}.png"
                if p.exists(): p.unlink()
    # Remove all deleted ID swatches and stale output assets.
    for old_id in removed:
        for face in face_sets.get(old_id, set()):
            p = SWATCH_DIR / f"{old_id}_{face}.png"
            if p.exists(): p.unlink()
    # Clean up stale alias swatches left from an interrupted prior run.
    expected_swatch_names = {f"{bid}_{face}.png" for bid, defn in new_blocks.items() for face in defn.get("tiles", {})}
    for p in SWATCH_DIR.glob("*.png"):
        if p.name not in expected_swatch_names:
            p.unlink()

    # Assign tight atlas indices deterministically in block/face order, preserving pixel content.
    tile_size = 16
    columns = 64
    tile_index = 0
    tiles_meta = {}
    old_swatch_images: dict[tuple[str, str], Image.Image] = {}
    for bid, definition in new_blocks.items():
        tile_fields = definition.get("tiles", {})
        new_tiles = {}
        for face in tile_fields:
            p = SWATCH_DIR / f"{bid}_{face}.png"
            if not p.exists():
                # Fallback for a canonical re-key if the desired face was absent: use old id's swatch
                old_candidate = source_for_key.get(bid, bid)
                candidate = SWATCH_DIR / f"{old_candidate}_{face}.png"
                if candidate.exists() and candidate != p:
                    candidate.replace(p)
            if not p.exists():
                raise SystemExit(f"Missing texture swatch after canonical migration: {p}")
            with Image.open(p) as im:
                im = im.convert("RGBA")
                if im.size != (16, 16):
                    raise SystemExit(f"Non-16x16 swatch: {p} {im.size}")
                old_swatch_images[(bid, face)] = im.copy()
            new_tiles[face] = tile_index
            x, y = (tile_index % columns) * tile_size, (tile_index // columns) * tile_size
            tiles_meta.setdefault(bid, {})[face] = {"tile": tile_index, "x": x, "y": y, "width": 16, "height": 16}
            tile_index += 1
        definition["tiles"] = new_tiles
    rows = max(1, (tile_index + columns - 1) // columns)
    atlas = Image.new("RGBA", (columns * tile_size, rows * tile_size), (0, 0, 0, 0))
    for bid, definition in new_blocks.items():
        for face, idx in definition.get("tiles", {}).items():
            atlas.paste(old_swatch_images[(bid, face)], ((idx % columns) * 16, (idx // columns) * 16))
    atlas.save(ATLAS_PATH, optimize=True)
    write_json(ATLAS_MAP_PATH, {"tile_size": 16, "columns": columns, "rows": rows, "tiles": tiles_meta})

    # Re-key original runtime data and keep blocks.json as an easy-to-inspect compatibility export.
    composite = {"schema_version": 2, "atlas_tile_size": 16, "atlas_columns": columns, "atlas_rows": rows, "blocks": new_blocks}
    write_json(BLOCKS_PATH, composite)
    write_json(RECIPES_PATH, {"schema_version": 2, "recipes": new_recipes, "source_status": "sampled_project_recipes_not_vanilla_complete"})
    write_json(ENTITIES_PATH, {"schema_version": 2, "entities": new_entities, "source_status": "partial_runtime_behaviours_not_canonical_full_registry"})

    # Separated registry source of truth, in parallel with the compatibility export.
    block_only_ids = {"piston_head", "nether_portal", "end_portal"}
    block_defs = {}
    item_defs = {}
    for bid, defn in new_blocks.items():
        is_block = bool(defn.get("placeable", False)) or bid in block_only_ids
        # A named item can share an ID with a block, but a block-only technical state is not an item.
        block_record = {
            "id": bid, "name": defn.get("name", bid.replace("_", " ").title()),
            "hardness": defn.get("hardness", 0.0), "solid": defn.get("solid", False),
            "placeable": bool(defn.get("placeable", False)), "transparent": defn.get("transparent", False),
            "emission": defn.get("emission", 0.0), "model_ref": bid,
            "visual": {k: v for k, v in defn.items() if k in {"name","category","color","pattern","solid","placeable","hardness","transparent","emission","tiles","top_color","side_color","bottom_color","shape","height","width","orientation","wood_type","variant_of","tags","emission_when_powered"}},
            "reference_status": "project_entry_needs_official_registry_join"
        }
        if is_block: block_defs[bid] = block_record
        is_item = (bool(defn.get("placeable", False)) or (not is_block and bid not in {"air"})) and bid not in block_only_ids
        if is_item:
            stack = 1 if any(t in bid for t in ["pickaxe","sword","axe","shovel","hoe","bow","crossbow","trident","shield","fishing_rod","flint_and_steel","shears","helmet","chestplate","leggings","boots","elytra","horse_armor","mace","carrot_on_a_stick","warped_fungus_on_a_stick"]) else (16 if bid in {"egg","snowball","ender_pearl","honey_bottle","straw_bed"} else 64)
            item_defs[bid] = {"id": bid, "name": defn.get("name", bid.replace("_", " ").title()), "max_stack_size": stack,
                              "max_damage": None, "block_id": bid if is_block else None,
                              "components": {}, "components_reference_status": "awaiting_official_26_3_item_report",
                              "visual": {k: v for k, v in defn.items() if k in {"name","category","color","pattern","solid","placeable","hardness","transparent","emission","tiles","top_color","side_color","bottom_color","shape","height","width","orientation","wood_type","variant_of","tags","emission_when_powered"}},
                              "reference_status": "stack_size_heuristic_until_official_join"}

    # Keep block technical entries separate from inventory item IDs.
    block_defs["air"] = {"id":"air", "name":"Air", "hardness":0.0, "solid":False, "placeable":False, "transparent":True, "emission":0.0, "model_ref":"air", "visual":{}, "reference_status":"official_registry_id_confirmed; properties_pending_import"}
    write_json(REG_DIR / "blocks.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "partial_project_subset", "blocks": block_defs})
    write_json(REG_DIR / "items.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "partial_project_subset", "items": item_defs})
    write_json(REG_DIR / "block_states.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "provisional_mappings_official_report_required", "block_states": build_states(new_blocks)})
    model_defs = {}
    for bid, definition in new_blocks.items():
        model_defs[bid] = {"model_id": f"flatworld:block/{bid}", "shape": definition.get("shape", "cube"),
                           "textures": {face: f"atlas_tile:{idx}" for face, idx in definition.get("tiles", {}).items()},
                           "state_variants": {}, "source_status": "project_geometry_fallback_official_client_models_required"}
    write_json(REG_DIR / "models.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "project_fallback_official_client_model_import_required", "models": model_defs})
    components = {
      "minecraft:max_stack_size": {"type":"integer", "min":1, "max":99},
      "minecraft:max_damage": {"type":"integer", "min":1},
      "minecraft:damage": {"type":"integer", "min":0},
      "minecraft:food": {"type":"object", "status":"definition_schema_pending_official_component_report"},
      "minecraft:tool": {"type":"object", "status":"definition_schema_pending_official_component_report"},
      "minecraft:equippable": {"type":"object", "status":"definition_schema_pending_official_component_report"},
      "minecraft:consumable": {"type":"object", "status":"definition_schema_pending_official_component_report"},
      "minecraft:potion_contents": {"type":"object", "status":"updated_data_predicate_in_26_3"},
      "minecraft:block_transformer": {"type":"list", "status":"introduced_in_26_3"},
      "minecraft:map_id": {"type":"integer", "status":"item_instance_component_schema_pending_official_report"},
      "minecraft:custom_data": {"type":"object", "status":"schema_pending_official_component_report"}
    }
    write_json(REG_DIR / "item_components.json", {"schema_version": 1, "minecraft_version": "26.3", "data_pack_version": 121, "resource_pack_version": 97.1, "source_status": "component_types_are_scaffold_not_complete_registry", "component_schemas": components})
    write_json(REG_DIR / "entity_types.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "partial_runtime_subset_official_entity_report_required", "entities": {eid: {"id":eid, "name":defn.get("name", eid.replace("_"," ").title()), "runtime_supported": True} for eid,defn in new_entities.items()}})
    write_json(REG_DIR / "entity_behaviors.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "flatworld_ai_subset", "entities": new_entities})
    write_json(REG_DIR / "recipes.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "partial_project_sample_not_vanilla_recipe_dump", "recipes": new_recipes})
    tags = {}
    for bid, defn in new_blocks.items():
        for tag in defn.get("tags", []) if isinstance(defn.get("tags", []), list) else []:
            tags.setdefault(str(tag), []).append(bid)
    write_json(REG_DIR / "tags.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "project-derived-incomplete-official-tags-import-required", "block_tags": {k: sorted(set(v)) for k,v in sorted(tags.items())}, "item_tags": {}, "entity_tags": {}, "biome_tags": {}})
    loot_tables = {f"entity/{eid}": defn.get("drops", []) for eid,defn in new_entities.items() if defn.get("drops")}
    write_json(REG_DIR / "loot_tables.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "partial_entity_drop_behaviors_not_vanilla_loot_tables", "tables": loot_tables})
    write_json(REG_DIR / "worldgen.json", {"schema_version": 1, "minecraft_version": "26.3", "source_status": "hardcoded_generator_not_yet_extracted", "biomes": [], "features": [], "structure_sets": [], "noise_settings": [], "dimensions": ["overworld", "nether", "end"]})
    manifest = {
      "project_schema_version": 1, "target_minecraft_java": "26.3", "minecraft_data_version": 5023,
      "data_pack_version": 121, "resource_pack_version": 97.1,
      "reference_method": "Mojang official server.jar --reports plus data and client resource JSONs; import via tools/sync_java_26_3_reference.py",
      "authoritative_reference_imported": False,
      "status": "MIGRATED_SEPARATE_REGISTRIES_REFERENCE_IMPORT_PENDING",
      "current_counts": {"runtime_catalogue":len(new_blocks), "block_definitions":len(block_defs), "item_definitions":len(item_defs), "block_state_entries":len(new_blocks)+1, "models":len(model_defs), "entity_behaviors":len(new_entities), "recipes":len(new_recipes)},
      "canonical_id_migrations": migration,
      "removed_nonvanilla_or_duplicate_entries": sorted(removed),
      "source": "See docs/VANILLA_26.3_REFERENCE_SOURCES.md. Official version data pack 121.0/resource pack 97.1; source registry snapshot uses vanilla server reports, but runtime import not performed in this offline run."
    }
    write_json(REG_DIR / "manifest.json", manifest)

    # Keep a new canonical-ID manifest separate from the historical 0.5.0 baseline.
    # Accumulate earlier migrations so the complete pre-0.5.4 ID map remains recoverable.
    history_path = REG_DIR / "id_migrations.json"
    previous_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else {}
    previous_migrations = previous_history.get("migrations", {})
    previous_removed = set(previous_history.get("removed_ids", []))
    ids = sorted(new_blocks)
    write_json(ROOT / "docs" / "canonical_registry_ids_0.5.4.json", {"minecraft_version":"26.3", "count":len(ids), "ids":ids, "reference_status":"partial project subset; official import pending"})
    combined_migrations = dict(previous_migrations)
    for old_id, new_id in migration.items():
        if old_id != new_id: combined_migrations[old_id] = new_id
    # Chain prior targets through this migration pass.
    for old_id, target in list(combined_migrations.items()):
        if target in migration and migration[target] != target:
            combined_migrations[old_id] = migration[target]
    combined_removed = sorted(previous_removed.union(removed))
    write_json(REG_DIR / "id_migrations.json", {"source_version":"Flatworld 0.5.0-0.5.3 IDs", "target_version":"Flatworld 0.5.4 canonical-known IDs", "migrations":combined_migrations, "removed_ids":combined_removed, "note":"No released saves were supplied. This records canonical moves; unsupported pseudo IDs are removed rather than aliased indefinitely."})

    # Rewrite project script literal IDs and data resource references to canonical names.
    script_replacements = {k:v for k,v in migration.items() if v is not None and k != v}
    # Add all explicit dropped alias IDs so they can't survive as hard-coded runtime content.
    for p in list((ROOT / "scripts").glob("*.gd")) + list((ROOT / "scenes").glob("*.tscn")):
        txt = p.read_text(encoding="utf-8")
        for old_id, new_id in script_replacements.items():
            txt = txt.replace('"'+old_id+'"', '"'+new_id+'"')
            txt = txt.replace("'"+old_id+"'", "'"+new_id+"'")
        for old_id in removed + list(DROP_ITEM_ONLY_IDS):
            txt = txt.replace('"'+old_id+'"', '""')
            txt = txt.replace("'"+old_id+"'", "''")
        p.write_text(txt, encoding="utf-8")

    # Update resource pointers and registry loader to use the separated registries. The merged
    # BlockRegistry.blocks dictionary remains a runtime facade only, not the source of truth.
    (ROOT / "scripts" / "block_registry.gd").write_text('''extends RefCounted
class_name BlockRegistry

# Runtime compatibility facade over separated Java-versioned registries.
# Authoritative completeness is established only after the 26.3 import tool has run.
const REGISTRY_ROOT := "res://assets/data/registries/26.3/"
static var blocks: Dictionary = {}
static var block_definitions: Dictionary = {}
static var items: Dictionary = {}
static var block_states: Dictionary = {}
static var models: Dictionary = {}
static var entity_types: Dictionary = {}
static var _loaded := false

static func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        push_error("Missing registry file: " + path)
        return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        push_error("Could not open registry file: " + path)
        return {}
    var parsed: Variant = JSON.parse_string(file.get_as_text())
    if parsed is Dictionary:
        return parsed
    push_error("Invalid JSON registry root: " + path)
    return {}

static func load_data() -> void:
    if _loaded:
        return
    var bdoc := _read_json(REGISTRY_ROOT + "blocks.json")
    var idoc := _read_json(REGISTRY_ROOT + "items.json")
    var sdoc := _read_json(REGISTRY_ROOT + "block_states.json")
    var mdoc := _read_json(REGISTRY_ROOT + "models.json")
    var edoc := _read_json(REGISTRY_ROOT + "entity_types.json")
    block_definitions = bdoc.get("blocks", {})
    items = idoc.get("items", {})
    block_states = sdoc.get("block_states", {})
    models = mdoc.get("models", {})
    entity_types = edoc.get("entities", {})
    # Items with block forms inherit the canonical block's gameplay/visual metadata. Item-only
    # definitions supply their own icon and stack information. This view is in-memory only.
    blocks.clear()
    for item_id in items.keys():
        var item: Dictionary = items[item_id]
        var visual: Dictionary = item.get("visual", {})
        var runtime_def := visual.duplicate(true)
        runtime_def["max_stack_size"] = int(item.get("max_stack_size", 64))
        runtime_def["max_damage"] = item.get("max_damage", null)
        runtime_def["item_id"] = item_id
        blocks[item_id] = runtime_def
    for block_id in block_definitions.keys():
        var b: Dictionary = block_definitions[block_id]
        var visual: Dictionary = b.get("visual", {})
        var runtime_def := visual.duplicate(true)
        runtime_def["name"] = str(b.get("name", runtime_def.get("name", block_id.capitalize())))
        runtime_def["solid"] = bool(b.get("solid", runtime_def.get("solid", false)))
        runtime_def["placeable"] = bool(b.get("placeable", false))
        runtime_def["hardness"] = float(b.get("hardness", runtime_def.get("hardness", 0.0)))
        runtime_def["transparent"] = bool(b.get("transparent", runtime_def.get("transparent", false)))
        runtime_def["emission"] = float(b.get("emission", runtime_def.get("emission", 0.0)))
        runtime_def["is_block"] = true
        if block_id != "air":
            blocks[block_id] = runtime_def
    _loaded = true

static func has_block(block_id: String) -> bool:
    load_data()
    return blocks.has(block_id)

static func is_canonical_block(block_id: String) -> bool:
    load_data()
    return block_definitions.has(block_id)

static func has_item(item_id: String) -> bool:
    load_data()
    return items.has(item_id)

static func get_item(item_id: String) -> Dictionary:
    load_data()
    return items.get(item_id, {})

static func get_block(block_id: String) -> Dictionary:
    load_data()
    return blocks.get(block_id, {})

static func get_block_state_definition(block_id: String) -> Dictionary:
    load_data()
    return block_states.get(block_id, {})

static func get_model_definition(block_id: String) -> Dictionary:
    load_data()
    return models.get(block_id, {})

static func get_name(block_id: String) -> String:
    var b := get_block(block_id)
    return str(b.get("name", block_id.replace("_", " ").capitalize()))

static func is_solid(block_id: String) -> bool:
    return bool(get_block(block_id).get("solid", false))

static func is_placeable(block_id: String) -> bool:
    return bool(get_block(block_id).get("placeable", false))

static func get_placeable_ids() -> Array[String]:
    load_data()
    var result: Array[String] = []
    for key in block_definitions.keys():
        if bool(block_definitions[key].get("placeable", false)):
            result.append(str(key))
    result.sort()
    return result

static func get_catalogue_ids() -> Array[String]:
    load_data()
    var result: Array[String] = []
    for key in blocks.keys():
        result.append(str(key))
    result.sort()
    return result

static func get_canonical_block_ids() -> Array[String]:
    load_data()
    var result: Array[String] = []
    for key in block_definitions.keys():
        result.append(str(key))
    result.sort()
    return result

static func get_item_ids() -> Array[String]:
    load_data()
    var result: Array[String] = []
    for key in items.keys():
        result.append(str(key))
    result.sort()
    return result
''', encoding="utf-8")

    # Main keeps AI behavior separate from the canonical entity type inventory.
    (DATA / "entity_behaviors.json").write_text(json.dumps({"schema_version":2,"entities":new_entities,"source_status":"Flatworld runtime subset; not vanilla entity registry"},indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
    # Canonical registry path for existing code is explicit; it's only the known subset until sync.
    (DATA / "entities.json").write_text(json.dumps({"schema_version":2,"entities":{eid:{"name":e.get("name",eid.replace("_"," ").title()),"runtime_supported":True} for eid,e in new_entities.items()},"source_status":"partial known subset; canonical report import pending"},indent=2,ensure_ascii=False)+"\n",encoding="utf-8")

    print(json.dumps({"status":"migrated", "runtime_catalogue":len(new_blocks), "blocks":len(block_defs), "items":len(item_defs), "entities":len(new_entities), "recipes":len(new_recipes), "removed":sorted(removed), "migrations":{k:v for k,v in migration.items() if k!=v}},indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
