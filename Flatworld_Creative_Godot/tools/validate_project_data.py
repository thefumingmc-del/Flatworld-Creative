#!/usr/bin/env python3
"""Static Flatworld data validation. Does not substitute for Godot runtime/device tests."""
from __future__ import annotations
import argparse, hashlib, json, sys
from collections import defaultdict
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "assets/data"
REG = DATA / "registries/26.3"
TEX = ROOT / "assets/textures/blocks"
ITEM_TEX = ROOT / "assets/textures/items"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--require-authoritative-reference", action="store_true", help="Fail unless the verified Java 26.3 report/data import is present")
    args = ap.parse_args()
    errors, warnings, checks = [], [], []
    def check(condition, message):
        (checks if condition else errors).append(message)
    def warn(message): warnings.append(message)

    required = [DATA/"blocks.json", DATA/"recipes.json", DATA/"entities.json",
                REG/"blocks.json", REG/"items.json", REG/"block_states.json", REG/"models.json",
                REG/"block_render_definitions.json", REG/"item_visual_definitions.json", REG/"block_item_mappings.json", REG/"entity_types.json",
                REG/"entity_behaviors.json", REG/"item_components.json", REG/"recipes.json",
                REG/"tags.json", REG/"loot_tables.json", REG/"worldgen.json", REG/"manifest.json"]
    check(all(p.is_file() for p in required), f"required JSON/data files present ({sum(p.is_file() for p in required)}/{len(required)})")
    if errors:
        print("ERRORS:\n"+"\n".join("- "+x for x in errors)); return 1
    # Ensure every shipped JSON parses before accessing schemas.
    broken=[]
    for p in ROOT.rglob("*.json"):
        if ".git" in p.parts or "tools/.cache" in p.as_posix(): continue
        try: load(p)
        except Exception as exc: broken.append(f"{p.relative_to(ROOT)}: {exc}")
    check(not broken, f"all JSON files parse ({len(broken)} failures)" if not broken else "all JSON files parse; failures: "+"; ".join(broken[:10]))

    blocks_doc=load(REG/"blocks.json"); items_doc=load(REG/"items.json")
    states_doc=load(REG/"block_states.json"); render_doc=load(REG/"block_render_definitions.json")
    item_visual_doc=load(REG/"item_visual_definitions.json"); models_doc=load(REG/"models.json")
    block_item_doc=load(REG/"block_item_mappings.json")
    manifest=load(REG/"manifest.json")
    blocks=blocks_doc.get("blocks",{}); items=items_doc.get("items",{})
    states=states_doc.get("block_states",{}); render=render_doc.get("block_render_definitions",{})
    item_visuals=item_visual_doc.get("item_visual_definitions",{})
    item_to_block=block_item_doc.get("item_to_block",{})
    block_to_item=block_item_doc.get("block_to_item",{})
    check(len(blocks)>0 and "air" in blocks, f"block registry contains air and {len(blocks)} block IDs")
    check(len(items)>0, f"separate item registry has {len(items)} item IDs")
    check(set(render).issubset(set(blocks)), f"all {len(render)} block render definitions reference canonical block IDs")
    check(set(item_visuals).issubset(set(items)), f"all {len(item_visuals)} item visual definitions reference item IDs")
    check(set(states)==set(blocks), f"block-state registry has exactly one record for every known block ID ({len(states)}/{len(blocks)})")
    ids_manifest=load(ROOT/"docs/canonical_registry_ids_0.5.5.json")
    check(set(ids_manifest.get("block_ids",[]))==set(blocks) and set(ids_manifest.get("item_ids",[]))==set(items), "canonical ID manifest exactly matches current registry files")
    check(bool(ids_manifest.get("authoritative_reference_imported",False))==bool(load(REG/"manifest.json").get("authoritative_reference_imported",False)), "canonical ID manifest provenance flag matches registry manifest")
    if not bool(load(REG/"manifest.json").get("authoritative_reference_imported",False)):
        falsely_complete=[bid for bid, row in states.items() if row.get("complete") is True]
        check(not falsely_complete, "partial block-state catalogue does not falsely mark provisional rows complete" if not falsely_complete else "unverified state rows claim completeness: "+", ".join(falsely_complete[:12]))

    # IDs known from Mojang's released 26.3 nomenclature; reject old project placeholders.
    obsolete_block_ids={"wheat_crop","carrot_crop","potato_crop","beetroot_crop","redstone_dust","pressure_plate","quartz_ore","bookshelf_spruce","iron_pressure_plate","poplar_leaves","fallen_poplar_log","fallen_poplar_tree","campfire_cooking"}
    check(not (set(blocks)&obsolete_block_ids), "block registry has no known noncanonical legacy pseudo-block IDs")
    obsolete_map_item_ids={"abandoned_camp_map","buried_ancient_city_map","buried_mineshaft_map","buried_treasure_map","buried_trial_chambers_map","desert_pyramid_map","desert_village_map","jungle_pyramid_map","ocean_monument_map","plains_village_map","savanna_village_map","snowy_village_map","swamp_hut_map","taiga_village_map","warm_ocean_ruins_map","woodland_mansion_map"}
    obsolete_item_ids={"wheat_crop","carrot_crop","potato_crop","beetroot_crop","redstone_dust","iron_pressure_plate","poplar_leaves","raw_iron_block_item","raw_gold_block_item","raw_copper_block_item","explorer_map_camp_dappled_forest","seeds","water","lava","farmland","dirt_path"}|obsolete_map_item_ids
    check(not (set(items)&obsolete_item_ids), "item registry has no known noncanonical legacy pseudo-item IDs")
    check("map" in items and "filled_map" in items and not (set(items)&obsolete_map_item_ids), "map variants use canonical map/filled_map item IDs rather than themed pseudo-items")
    check("redstone_wire" in blocks and "redstone" in items and "redstone_dust" not in items, "redstone block and redstone inventory item have distinct canonical IDs")
    check(not (set(items) & {"water","lava","farmland","dirt_path"}), "block-only fluids/transform states are not falsely registered as inventory items")
    check(all("block_id" not in item for item in items.values()), "canonical item records do not embed block-registry identities")
    check("wheat" in items and "wheat" not in item_to_block, "same-name wheat food item is not coupled to the wheat crop block")
    bad_i2b=[f"{i}->{b}" for i,b in item_to_block.items() if i not in items or b not in blocks or b not in render or not render[b].get("placeable",False)]
    bad_b2i=[f"{b}->{i}" for b,i in block_to_item.items() if b not in blocks or i not in items or item_to_block.get(i)!=b]
    check(not bad_i2b and not bad_b2i, "explicit item/block placement mappings resolve and invert without collisions" if not (bad_i2b or bad_b2i) else "invalid item/block placement map: "+", ".join((bad_i2b+bad_b2i)[:12]))
    check(item_to_block.get("redstone")=="redstone_wire" and "wheat" not in item_to_block, "placement mapping supports redstone dust and rejects false wheat-block inference")
    check(all(x in blocks for x in ("wheat","carrots","potatoes","beetroots")), "four canonical crop block IDs exist")
    check(all(x in items for x in ("wheat","carrot","potato","beetroot")), "crop drops use distinct canonical inventory item IDs")
    check(all(x in blocks for x in ("red_poplar_leaves","orange_poplar_leaves","yellow_poplar_leaves")) and "poplar_leaves" not in blocks, "only the three canonical coloured Poplar Leaves block variants are registered")
    check(all(x in blocks and x in items for x in ("raw_iron_block","raw_gold_block","raw_copper_block")), "raw metal blocks have canonical block and item identities")
    check("stone_pressure_plate" in blocks and "iron_pressure_plate" not in blocks, "pressure plate identifiers use canonical IDs (no fake iron plate)")
    check("nether_quartz_ore" in blocks and "quartz_ore" not in blocks, "quartz ore identifier is canonical")
    check("shelf_mushroom" in blocks and all(x not in blocks for x in ("shelf_mushrooms","shelf_mushroom_small","shelf_mushroom_large")), "shelf mushroom is one canonical stateful block, not fake size variants")
    if "shelf_mushroom" in states:
        props=states["shelf_mushroom"].get("properties",{})
        check("age" in props and "facing" in props, "shelf mushroom has age and facing state properties")
    else: check(False,"shelf mushroom state definition exists")

    # Recipe sample consistency is different from full vanilla recipe coverage.
    recipe_doc=load(DATA/"recipes.json"); recipes=recipe_doc.get("recipes",{})
    recipe_missing=[]
    for rid, rec in recipes.items():
        result=rec.get("result")
        if result not in items: recipe_missing.append(f"{rid}: result {result}")
        for ing in rec.get("ingredients",{}):
            if ing not in items: recipe_missing.append(f"{rid}: ingredient {ing}")
    check(not recipe_missing, f"all {len(recipes)} currently implemented sample recipes reference item IDs" if not recipe_missing else "recipe references resolve: "+"; ".join(recipe_missing[:12]))
    if not recipe_doc.get("source_status", "").find("not_vanilla_complete") >= 0:
        warn("Current runtime recipes are still a Flatworld sample, not the full vanilla recipe registry.")
    check("ghoul" not in load(REG/"entity_types.json").get("entities",{}), "no non-vanilla ghoul entity ID")

    # Every historical ID mapping must end at a valid target in the right namespace.
    migrations=load(REG/"id_migrations.json")
    block_maps=migrations.get("block_id_migrations",{})
    item_maps=migrations.get("item_id_migrations",{})
    bad_block_migrations=[f"{old}->{new}" for old,new in block_maps.items() if new not in blocks]
    bad_item_migrations=[f"{old}->{new}" for old,new in item_maps.items() if new not in items]
    check(not bad_block_migrations, "all legacy block ID migrations target known blocks" if not bad_block_migrations else "invalid block migration destinations: "+", ".join(bad_block_migrations))
    check(not bad_item_migrations, "all legacy item ID migrations target known items" if not bad_item_migrations else "invalid item migration destinations: "+", ".join(bad_item_migrations))
    block_items_overlap=set(block_maps)&set(item_maps)
    check("carrot_crop" in block_maps and block_maps.get("carrot_crop")=="carrots" and item_maps.get("carrot_crop")=="carrot" and item_maps.get("wheat_crop")=="wheat_seeds" and item_maps.get("beetroot_crop")=="beetroot_seeds", "crop migration keeps crop blocks separate from planting/food inventory items")
    removed_blocks=set(migrations.get("removed_block_ids",[])) & set(blocks)
    removed_items=set(migrations.get("removed_item_ids",[])) & set(items)
    check(not removed_blocks and not removed_items, "removed legacy IDs are absent from their canonical registries")
    tag_doc=load(REG/"tags.json")
    tag_text=json.dumps(tag_doc,ensure_ascii=False)
    check(all(x not in tag_text for x in ['"carrot_crop"','"wheat_crop"','"redstone_dust"','"pressure_plate"']), "current runtime tag subset contains no known obsolete IDs")

    # Pixel-level verification of block face PNGs and the exact atlas cells.
    block_visuals=load(DATA/"blocks.json").get("blocks",{})
    atlas_path=ROOT/"assets/textures/atlas.png"; map_path=ROOT/"assets/textures/atlas_map.json"
    check(atlas_path.is_file() and map_path.is_file(), "atlas image and tile map exist")
    if atlas_path.is_file() and map_path.is_file():
        atlas=Image.open(atlas_path).convert("RGBA"); amap=load(map_path)
        check(atlas.width==int(amap.get("columns",0))*16 and atlas.height==int(amap.get("rows",0))*16 and atlas.width%16==0 and atlas.height%16==0,
              f"atlas dimensions align to exact 16x16 tiles ({atlas.width}x{atlas.height})")
        seen_indices=set(); seen_faces={}; missing_faces=[]; bad_size=[]; wrong_slot=[]; duplicate_sets=[]
        for bid, definition in block_visuals.items():
            tiles=definition.get("tiles",{})
            map_entry=amap.get("tiles",{}).get(bid,{})
            for face,index in tiles.items():
                p=TEX/f"{bid}_{face}.png"
                if not p.is_file(): missing_faces.append(f"{bid}.{face}"); continue
                im=Image.open(p).convert("RGBA")
                if im.size != (16,16): bad_size.append(f"{bid}.{face}={im.size}"); continue
                slot=map_entry.get(face,{})
                if not slot:
                    wrong_slot.append(f"{bid}.{face}: missing atlas map slot"); continue
                x,y=int(slot.get("x",-1)),int(slot.get("y",-1))
                if int(slot.get("tile",-1)) != int(index) or int(slot.get("width",0))!=16 or int(slot.get("height",0))!=16 or x<0 or y<0 or x+16>atlas.width or y+16>atlas.height:
                    wrong_slot.append(f"{bid}.{face}: invalid atlas coordinates"); continue
                crop=atlas.crop((x,y,x+16,y+16))
                if crop.tobytes()!=im.tobytes(): wrong_slot.append(f"{bid}.{face}: pixels differ from atlas slot")
                seen_indices.add(index); seen_faces[(bid,face)]=im
        check(not missing_faces, f"all registered face PNGs exist ({len(missing_faces)} missing)")
        check(not bad_size, f"all registered face textures are 16x16 ({len(bad_size)} failures)")
        check(not wrong_slot, f"every registered face matches its exact atlas slot ({len(wrong_slot)} failures)")
        check(len(seen_indices)==sum(len(v.get("tiles",{})) for v in block_visuals.values()), "atlas tile indices unique across every registered block face")
        sets={}
        for bid,definition in block_visuals.items():
            if definition.get("shape")!="cube" or not definition.get("solid",False): continue
            faces=[]
            for face in ("top","side","bottom"):
                if (bid,face) not in seen_faces: faces=[]; break
                faces.append(hashlib.sha256(seen_faces[(bid,face)].tobytes()).hexdigest())
            if len(faces)!=3: continue
            sig=tuple(faces)
            if sig in sets: duplicate_sets.append((sets[sig],bid))
            else: sets[sig]=bid
        check(not duplicate_sets, "no duplicate complete top/side/bottom textures across solid full-cube blocks" if not duplicate_sets else "duplicate cube textures: "+str(duplicate_sets[:12]))

    missing_icons=[]; bad_icons=[]
    for iid, visual in item_visuals.items():
        rel=str(visual.get("icon_path", ""))
        if not rel.startswith("res://assets/textures/items/"):
            missing_icons.append(f"{iid}: invalid icon path {rel}"); continue
        p=ROOT/rel.removeprefix("res://")
        if not p.is_file(): missing_icons.append(iid); continue
        try:
            if Image.open(p).size != (16,16): bad_icons.append(iid)
        except Exception: bad_icons.append(iid)
    check(not missing_icons, f"all {len(item_visuals)} registered item icon paths resolve ({len(missing_icons)} missing)")
    check(not bad_icons, f"all registered item icons are crisp 16x16 PNGs ({len(bad_icons)} failures)")

    # The GDScript facade must keep item and block registries independent.
    registry_source=(ROOT/"scripts/block_registry.gd").read_text(encoding="utf-8")
    check("return blocks.get(block_id, {})" in registry_source and "return items.get(item_id, {})" in registry_source,
          "runtime block and item getters query separate dictionaries")
    check("blocks[item_id] = runtime_item" not in registry_source and "func get_item_runtime(item_id: String)" in registry_source,
          "runtime does not insert item rows into the block dictionary")
    check("item_to_block.get(item_id, \"\")" in registry_source and "static func get_place_block_id(item_id: String)" in registry_source,
          "runtime placement uses the explicit item-to-block adapter")

    # Ensure current project runtime scripts don't reference obsolete IDs as gameplay identifiers.
    script_text="\n".join(p.read_text(encoding="utf-8") for d in (ROOT/"scripts",ROOT/"scenes") for p in d.rglob("*.gd") if p.is_file())
    forbidden_literals=['"wheat_crop"','"carrot_crop"','"potato_crop"','"beetroot_crop"','"iron_pressure_plate"','"poplar_leaves"','"quartz_ore"','"pressure_plate"']
    bad_literals=[x for x in forbidden_literals if x in script_text]
    check(not bad_literals, "runtime GDScript/scenes contain no known legacy gameplay ID literals" if not bad_literals else "obsolete gameplay ID literals remain: "+", ".join(bad_literals))

    imported=bool(manifest.get("authoritative_reference_imported",False))
    blocks_without_render=sorted(set(blocks)-set(render)-{"air"})
    items_without_icons=sorted(set(items)-set(item_visuals))
    if blocks_without_render or items_without_icons:
        warn(f"Visual coverage gap: {len(blocks_without_render)} known blocks lack a renderer adapter and {len(items_without_icons)} items lack a dedicated icon; imported vanilla models are not yet wired into mesh/icon rendering.")
    if imported:
        status_file=REG/"vanilla_import_status.json"
        check(status_file.is_file(), "authoritative import has a machine-readable provenance report")
        if status_file.is_file():
            st=load(status_file)
            check(st.get("minecraft_version")=="26.3" and st.get("authoritative_data_validated") is True, "source import is verified for exact Java 26.3")
            check((REG/"vanilla_reference/reports/blocks.json").is_file() and (REG/"vanilla_reference/reports/items.json").is_file(), "raw official blocks/items reports are retained")
            integrity=st.get("integrity_checks",{})
            required_integrity=["all_report_blocks_have_state_record","all_reported_state_ids_unique","all_state_rows_have_numeric_ids","exactly_one_default_state_per_block","all_server_index_paths_and_hashes_valid","all_client_index_paths_and_hashes_valid","client_blockstates_present","client_block_models_present","server_datapack_indexes_present"]
            check(all(integrity.get(k) is True for k in required_integrity), "official report state IDs and all indexed server/client paths/hashes passed integrity checks")
            # Reconcile normalized registries to exact raw report names; no inferred extra or missing IDs.
            raw_blocks=load(REG/"vanilla_reference/reports/blocks.json")
            raw_items=load(REG/"vanilla_reference/reports/items.json")
            def vanilla_names(doc):
                rows=doc.keys() if isinstance(doc,dict) else [x.get("name",x.get("id","")) for x in doc if isinstance(x,dict)] if isinstance(doc,list) else []
                result=set()
                for key in rows:
                    key=str(key)
                    if key.startswith("minecraft:"): key=key.split(":",1)[1]
                    result.add(key)
                return result
            check(set(blocks)==vanilla_names(raw_blocks), "canonical block registry exactly matches Mojang blocks report IDs")
            check(set(items)==vanilla_names(raw_items), "canonical item registry exactly matches Mojang items report IDs")
    else:
        warn("Full official Java 26.3 reports/client models/datapack data have not been imported in this environment; run tools/sync_java_26_3_reference.py with Java 25+ and network access.")
        if args.require_authoritative_reference: errors.append("strict release gate failed: authoritative Java 26.3 reference import is pending")
    # Include scope statuses so a clean static pass is not mistaken for full gameplay readiness.
    if not models_doc.get("blockstates"):
        warn("Official client blockstate/model JSON is not imported; renderer uses named Flatworld fallback geometry.")
    else:
        warn("Official model JSON is indexed only; the voxel mesher has not been verified to resolve variants/multipart/model parents/texture variables at runtime.")
    if len(load(REG/"loot_tables.json").get("tables",{})) == 0:
        warn("Complete vanilla loot tables are not imported; block drops remain simplified hardcoded behavior.")
    else:
        warn("Official loot tables are indexed, but vanilla loot conditions/functions are not yet evaluated by runtime drop code.")
    if not load(REG/"worldgen.json").get("all"):
        warn("Complete vanilla world-generation data is not imported or executed.")
    else:
        warn("Official world-generation files are indexed, but vanilla biome/feature/structure/noise generation is not executed by the runtime.")
    if not load(REG/"tags.json").get("all"):
        warn("Complete vanilla block/item/entity/biome tags are not imported.")
    else:
        warn("Official tags are indexed; all game systems still need to consume tags in place of hardcoded membership lists.")
    if not imported:
        warn("All vanilla recipe serializers/components and entity behavior remain partial; imported source data is required before registry parity claims.")

    print(f"Flatworld static validation: {len(checks)} checks passed, {len(warnings)} warnings, {len(errors)} errors")
    for x in checks: print("PASS: "+x)
    for x in warnings: print("WARN: "+x)
    for x in errors: print("ERROR: "+x)
    return 1 if errors else 0

if __name__ == "__main__": raise SystemExit(main())
