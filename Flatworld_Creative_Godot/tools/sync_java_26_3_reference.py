#!/usr/bin/env python3
"""Import hash-verified Minecraft Java 26.3 reports/data into separate registries.

Requires Python 3.10+, Java 25+, and network access. Raw reports and data files are
kept with checksums/provenance. Official PNG textures and downloaded JARs are not
copied into the source archive. Importing source data does not by itself implement
missing Godot gameplay/rendering systems.
"""
from __future__ import annotations
import argparse, hashlib, json, re, shutil, subprocess, sys, tempfile, urllib.error, urllib.request, zipfile
from pathlib import Path, PurePosixPath

VERSION = "26.3"
MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
ROOT = Path(__file__).resolve().parents[1]
DATA_ROOT = ROOT / "assets/data"
REG = ROOT / "assets/data/registries/26.3"
CACHE = ROOT / "tools/.cache/minecraft-26.3"
REPORTS = REG / "vanilla_reference/reports"
SERVER_DATA = REG / "vanilla_reference/server_data"
CLIENT_JSON = REG / "vanilla_reference/client_json"


def readj(path): return json.loads(path.read_text(encoding="utf-8"))
def writej(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
def fetchj(url):
    req = urllib.request.Request(url, headers={"User-Agent":"Flatworld-26.3-reference-sync/0.5.5"})
    with urllib.request.urlopen(req, timeout=60) as r: return json.loads(r.read().decode("utf-8"))
def java_major():
    p = subprocess.run(["java", "-version"], capture_output=True, text=True, timeout=10)
    m = re.search(r'(?:version\s+|openjdk\s+)[" ]?(\d+)', p.stderr + p.stdout, re.I)
    return int(m.group(1)) if m else None

def download_verified(url, dest, sha1, size):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size == size and hashlib.sha1(dest.read_bytes()).hexdigest() == sha1.lower():
        return dest
    temp = dest.with_suffix(dest.suffix + ".partial")
    h, n = hashlib.sha1(), 0
    req = urllib.request.Request(url, headers={"User-Agent":"Flatworld-26.3-reference-sync/0.5.5"})
    try:
        with urllib.request.urlopen(req, timeout=120) as response, temp.open("wb") as out:
            while True:
                chunk = response.read(1024*1024)
                if not chunk: break
                out.write(chunk); h.update(chunk); n += len(chunk)
    except Exception:
        temp.unlink(missing_ok=True); raise
    if n != int(size) or h.hexdigest().lower() != sha1.lower():
        temp.unlink(missing_ok=True)
        raise RuntimeError(f"SHA1/size verification failed: {dest.name} got {n}/{h.hexdigest()}, expected {size}/{sha1}")
    temp.replace(dest)
    return dest

def normalize_map(doc):
    if isinstance(doc, dict): rows = doc.items()
    elif isinstance(doc, list): rows = ((str(x.get("name", x.get("id", i))), x) for i,x in enumerate(doc) if isinstance(x,dict))
    else: return {}
    out = {}
    for rid, row in rows:
        rid = str(rid)
        if rid.startswith("minecraft:"): rid = rid.split(":",1)[1]
        out[rid] = row if isinstance(row,dict) else {"value":row}
    return out

def parse_blocks(doc):
    result, states = {}, {}
    for bid, row in sorted(normalize_map(doc).items()):
        state_rows = row.get("states", []) if isinstance(row.get("states", []),list) else []
        domains, ids, default_id = {}, [], None
        for st in state_rows:
            if not isinstance(st,dict): continue
            props = st.get("properties", st.get("Properties", {}))
            if isinstance(props,dict):
                for k,v in props.items(): domains.setdefault(str(k),set()).add(str(v).lower() if isinstance(v,bool) else str(v))
            try:
                sid = int(st.get("id", st.get("state_id"))); ids.append(sid)
                if st.get("default") is True: default_id = sid
            except (TypeError,ValueError): pass
        for k,v in row.get("properties",{}).items() if isinstance(row.get("properties",{}),dict) else []:
            if isinstance(v,list): domains.setdefault(str(k),set()).update(str(x) for x in v)
            elif isinstance(v,dict) and isinstance(v.get("values"),list): domains.setdefault(str(k),set()).update(str(x) for x in v["values"])
        pd = {}
        for k, vals in sorted(domains.items()):
            ordered = sorted(vals, key=lambda x: (not x.lstrip("-").isdigit(), int(x) if x.lstrip("-").isdigit() else x))
            if set(ordered) <= {"true","false"}: pd[k] = {"type":"bool","values":ordered}
            elif ordered and all(x.lstrip("-").isdigit() for x in ordered): pd[k] = {"type":"int","min":int(ordered[0]),"max":int(ordered[-1]),"values":ordered}
            else: pd[k] = {"type":"enum","values":ordered}
        result[bid] = {"id":bid,"name":str(row.get("name",bid)),"min_state_id":min(ids) if ids else None,
                       "max_state_id":max(ids) if ids else None,"default_state_id":default_id,"state_count":len(state_rows),
                       "source":"Mojang Java 26.3 server --reports/blocks.json"}
        states[bid] = {"properties":pd,"states":state_rows,"state_count":len(state_rows),"min_state_id":min(ids) if ids else None,
                       "max_state_id":max(ids) if ids else None,"default_state_id":default_id,"complete":True,
                       "source":"Mojang Java 26.3 server --reports/blocks.json"}
    return result, states

def validate_state_registry(blocks, states):
    """Return machine-readable integrity checks for the extracted default/block-state IDs."""
    state_ids=[]
    state_rows_total=sum(int(v.get("state_count", 0)) for v in states.values())
    numeric_state_rows=0
    one_default_per_block=True
    for state_doc in states.values():
        defaults=0
        for state_row in state_doc.get("states", []):
            if not isinstance(state_row, dict): continue
            try:
                state_ids.append(int(state_row.get("id", state_row.get("state_id"))))
                numeric_state_rows += 1
            except (TypeError,ValueError):
                pass
            if state_row.get("default") is True: defaults += 1
        if defaults != 1: one_default_per_block=False
    return {
        "all_report_blocks_have_state_record": set(states)==set(blocks),
        "all_reported_state_ids_unique": bool(state_ids) and len(state_ids)==len(set(state_ids)),
        "all_state_rows_have_numeric_ids": numeric_state_rows==state_rows_total,
        "exactly_one_default_state_per_block": one_default_per_block,
        "block_state_records": len(states),
        "block_registry_records": len(blocks),
        "reported_state_rows": state_rows_total,
        "numeric_state_rows": numeric_state_rows,
    }


def parse_items(doc, block_ids):
    """Parse only item-registry facts; never infer block identity from a shared ID."""
    items, components = {}, {}
    for iid,row in sorted(normalize_map(doc).items()):
        c = row.get("components",{}) if isinstance(row.get("components",{}),dict) else {}
        # Preserve canonical namespace-qualified component identifiers.
        c = {str(k):v for k,v in c.items()}
        stack = c.get("minecraft:max_stack_size",c.get("max_stack_size",row.get("max_stack_size",row.get("stackSize",64))))
        damage = c.get("minecraft:max_damage",c.get("max_damage",row.get("max_damage",row.get("maxDurability"))))
        try: stack = int(stack)
        except (ValueError,TypeError): stack = 64
        try: damage = int(damage) if damage is not None else None
        except (ValueError,TypeError): damage = None
        items[iid] = {"id":iid,"numeric_id":row.get("id"),"name":str(row.get("name",iid.replace("_"," ").title())),
                      "max_stack_size":stack,"max_damage":damage,
                      "max_stack_size_provenance":"minecraft:max_stack_size item component" if ("minecraft:max_stack_size" in c or "max_stack_size" in c) else "vanilla report top-level/fallback; inspect report if absent",
                      "max_damage_provenance":"minecraft:max_damage item component" if ("minecraft:max_damage" in c or "max_damage" in c) else "vanilla report top-level/fallback; inspect report if absent",
                      "components":c,"source":"Mojang Java 26.3 server --reports/items.json"}
        components[iid] = c
    return items, components


def build_project_block_item_mappings(blocks, items, render_definitions):
    """Build explicit runtime placement mappings without conflating registries.

    This only maps blocks that already have a project renderer adapter. Matching names
    are not sufficient: the wheat item is food while the wheat block is a crop. The
    official item report takes precedence for item existence; this adapter remains a
    project-specific implementation subset, not a claim about every Java BlockItem.
    """
    item_to_block, block_to_item, unmapped = {}, {}, []
    known_non_item_id_collisions = {"wheat": "The wheat inventory item is food; wheat_seeds plants the wheat crop."}
    known_block_only_ids = {
        "water": "Block state; place through water_bucket, not as an inventory item.",
        "lava": "Block state; place through lava_bucket, not as an inventory item.",
        "farmland": "Transformed block state created by using a hoe; no standalone item.",
        "dirt_path": "Transformed block state created by using a shovel; no standalone item.",
    }
    for block_id, visual in sorted(render_definitions.items()):
        if block_id not in blocks or not visual.get("placeable", False):
            continue
        if block_id in known_block_only_ids:
            unmapped.append({"block_id":block_id,"reason":known_block_only_ids[block_id]})
            continue
        if block_id in known_non_item_id_collisions:
            unmapped.append({"block_id":block_id,"reason":known_non_item_id_collisions[block_id]})
            continue
        if block_id not in items:
            unmapped.append({"block_id":block_id,"reason":"No same-ID item in this report; requires explicit vanilla BlockItem mapping or interaction rule."})
            continue
        components = items[block_id].get("components", {})
        if isinstance(components, dict) and any(k in components for k in ("minecraft:food", "food")):
            unmapped.append({"block_id":block_id,"reason":"Same-ID item has a food component; it is not a placeable BlockItem."})
            continue
        item_to_block[block_id] = block_id
        block_to_item[block_id] = block_id
    # Redstone's vanilla inventory item is named `redstone`; its placed block is `redstone_wire`.
    if "redstone_wire" in blocks and "redstone" in items and render_definitions.get("redstone_wire", {}).get("placeable", False):
        item_to_block["redstone"] = "redstone_wire"
        block_to_item["redstone_wire"] = "redstone"
        unmapped = [row for row in unmapped if row.get("block_id") != "redstone_wire"]
    return {
        "schema_version":1,
        "minecraft_version":VERSION,
        "source_status":"PARTIAL_RUNTIME_MAPPING; only implemented Flatworld render adapters are mapped",
        "known_block_only_ids":known_block_only_ids,
        "known_non_item_id_collisions":known_non_item_id_collisions,
        "item_to_block":dict(sorted(item_to_block.items())),
        "block_to_item":dict(sorted(block_to_item.items())),
        "unmapped_placeable_block_adapters":sorted(unmapped, key=lambda row: row["block_id"]),
        "notes":[
            "Item identity and block identity are separate registries.",
            "Equal IDs do not establish a placement relation (wheat item vs wheat crop).",
            "This map is a runtime subset, not the full official Java 26.3 BlockItem mapping."
        ]
    }


def filter_registry_entries(entries, canonical_ids):
    """Keep project rendering/icon adapters only for IDs in the official registry.

    This prevents stale project pseudo IDs from surviving a successful import while
    intentionally allowing official IDs to lack an adapter (they stay visibly missing).
    """
    canonical = set(canonical_ids)
    return {rid: row for rid, row in entries.items() if rid in canonical}

def filter_runtime_sample_recipes(recipe_doc, canonical_item_ids):
    """Retain only currently executable sample recipes whose item references exist.

    Vanilla recipes are indexed separately and never merged into this lightweight sample
    schema. Unsupported project-only recipe references are dropped only after an official
    registry import succeeds.
    """
    canonical = set(canonical_item_ids)
    recipes = recipe_doc.get("recipes", {}) if isinstance(recipe_doc, dict) else {}
    kept, rejected = {}, []
    for rid, row in recipes.items():
        if not isinstance(row, dict):
            rejected.append(str(rid)); continue
        result = str(row.get("result", ""))
        ingredients = row.get("ingredients", {})
        ingredient_ids = list(ingredients.keys()) if isinstance(ingredients, dict) else []
        if result in canonical and all(str(iid) in canonical for iid in ingredient_ids):
            kept[str(rid)] = row
        else:
            rejected.append(str(rid))
    result_doc = dict(recipe_doc)
    result_doc["recipes"] = kept
    result_doc["source_status"] = "Flatworld executable sample recipes filtered to authoritative Java 26.3 item IDs; not the complete vanilla recipe registry"
    result_doc["excluded_after_authoritative_item_check"] = sorted(rejected)
    return result_doc


def filter_block_render_document(block_doc, canonical_block_ids):
    """Filter root assets/data/blocks.json's render definitions to official block IDs."""
    result = dict(block_doc)
    old_rows = block_doc.get("blocks", {}) if isinstance(block_doc, dict) else {}
    result["blocks"] = filter_registry_entries(old_rows, canonical_block_ids)
    result["source_status"] = "Project render definitions filtered to official Java 26.3 block IDs; does not represent official models"
    return result

def parse_entities(doc):
    return {eid:{"id":eid,"numeric_id":row.get("id"),"name":str(row.get("name",eid.replace("_"," ").title())),
                 "width":row.get("width"),"height":row.get("height"),"category":row.get("category"),
                 "source":"Mojang Java 26.3 server --reports/entities.json"}
            for eid,row in sorted(normalize_map(doc).items())}

def find_reports(work):
    for d in [work/"generated/reports",work/"reports",*work.rglob("reports")]:
        if all((d/n).is_file() for n in ("blocks.json","items.json","entities.json","registries.json")): return d
    raise RuntimeError("Vanilla generator did not emit blocks/items/entities/registries reports")

def extract_inner_server(server, temp):
    import io
    with zipfile.ZipFile(server) as outer:
        names = sorted((x for x in outer.namelist() if x.startswith("META-INF/versions/") and x.endswith(".jar")), key=lambda x:("server-" not in x,len(x)))
        for name in names:
            try:
                z = zipfile.ZipFile(io.BytesIO(outer.read(name)))
                with z:
                    ns = z.namelist()
                    if any(p.endswith("net/minecraft/server/Main.class") for p in ns):
                        dest=temp/"server-inner.jar"; dest.write_bytes(outer.read(name)); return dest
            except zipfile.BadZipFile: pass
    raise RuntimeError("Unable to locate inner server JAR in the official bundle")

def extract_tree(jar, dest, predicate):
    if dest.exists(): shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True); files=[]
    with zipfile.ZipFile(jar) as z:
        for name in z.namelist():
            n=name.replace("\\","/")
            if n.endswith("/") or not predicate(n): continue
            parts=PurePosixPath(n).parts
            if not parts or any(p in ("..","") for p in parts): raise RuntimeError(f"Unsafe archive path: {n}")
            target=dest.joinpath(*parts); target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(z.read(name)); files.append(n)
    return files

def index_files(root, files):
    """Build a collision-safe internal index; registry indexes are normalized separately."""
    out={}
    for f in files:
        rel=f.relative_to(root).as_posix()
        m=re.search(r"(?:^|/)data/([^/]+)/(.+)$",rel)
        if m:
            # Keep the full registry category in the universal index so same-named
            # values from distinct registries (e.g. block and item tags) cannot collide.
            key=f"{m.group(1)}:{m.group(2)}"
        else:
            asset=re.match(r"assets/([^/]+)/(blockstates|models/block|models/item|items)/(.+)\.json$",rel)
            if asset:
                ns, category, model_path = asset.groups()
                prefix = {"blockstates":"", "models/block":"block/", "models/item":"item/", "items":"item_definition/"}[category]
                key=f"{ns}:{prefix}{model_path}"
            else:
                key=rel
        key=re.sub(r"\.json$","",key)
        out[key]={"path":rel,"sha256":hashlib.sha256(f.read_bytes()).hexdigest(),"bytes":f.stat().st_size}
    return out

def server_registry_id(relative_path, kind):
    """Convert a server data path to a canonical resource ID for one registry."""
    rel=relative_path.replace("\\", "/")
    m=re.match(r"data/([^/]+)/(.+)$",rel)
    if not m: return None
    namespace, tail=m.groups()
    if not tail.endswith(".json"): return None
    tail=tail[:-5]
    if kind == "recipes":
        prefixes=("recipe/", "recipes/")
    elif kind == "loot_tables":
        prefixes=("loot_table/", "loot_tables/")
    elif kind == "tags_block":
        prefixes=("tags/block/", "tags/blocks/")
    elif kind == "tags_item":
        prefixes=("tags/item/", "tags/items/")
    elif kind == "tags_entity_type":
        prefixes=("tags/entity_type/", "tags/entity_types/")
    elif kind == "tags_biome":
        prefixes=("tags/worldgen/biome/", "tags/biome/", "tags/biomes/")
    elif kind == "worldgen":
        prefixes=("worldgen/",)
    else:
        prefixes=()
    for prefix in prefixes:
        if tail.startswith(prefix):
            tail=tail[len(prefix):]
            if kind == "worldgen":
                # Runtime consumers partition by registry (biomes/features/structures),
                # so the resource ID is the path under the type directory.
                bits=tail.split("/",1)
                if len(bits)==2: tail=bits[1]
            return f"{namespace}:{tail}"
    return None

def server_tag_registry(relative_path):
    """Return (registry-section, canonical tag resource ID) for a data/.../tags path."""
    rel=relative_path.replace("\\", "/")
    match=re.match(r"data/([^/]+)/tags/(.+)\.json$",rel)
    if not match: return None, None
    namespace, tail=match.groups()
    tag_types=[
        ("worldgen/biome/", "biomes"), ("worldgen/structure/", "structures"),
        ("worldgen/placed_feature/", "placed_features"), ("worldgen/configured_feature/", "configured_features"),
        ("worldgen/structure_set/", "structure_sets"), ("worldgen/flat_level_generator_preset/", "flat_level_generator_presets"),
        ("worldgen/processor_list/", "processor_lists"), ("worldgen/template_pool/", "template_pools"),
        ("worldgen/biome_source/", "biome_sources"), ("block/", "blocks"), ("blocks/", "blocks"),
        ("item/", "items"), ("items/", "items"), ("entity_type/", "entity_types"), ("entity_types/", "entity_types"),
        ("fluid/", "fluids"), ("fluids/", "fluids"), ("game_event/", "game_events"), ("game_events/", "game_events"),
        ("instrument/", "instruments"), ("instruments/", "instruments"), ("point_of_interest_type/", "point_of_interest_types"),
        ("structure/", "structures"), ("damage_type/", "damage_types"), ("enchantment/", "enchantments"),
        ("banner_pattern/", "banner_patterns"), ("function/", "functions"), ("dialog/", "dialogs"),
        ("cat_variant/", "cat_variants"), ("wolf_variant/", "wolf_variants"), ("frog_variant/", "frog_variants"),
        ("villager_profession/", "villager_professions"), ("villager_type/", "villager_types"),
        ("biome/", "biomes")]
    for prefix, section in sorted(tag_types, key=lambda x:len(x[0]), reverse=True):
        if tail.startswith(prefix):
            return section, f"{namespace}:{tail[len(prefix):]}"
    if "/" in tail:
        # Unknown registry tag types are retained in the all-index and are not discarded.
        category, tag_id=tail.split("/",1)
        return "other:" + category, f"{namespace}:{tag_id}"
    return "other", f"{namespace}:{tail}"


def record_sync_blocker(reason: str, detected_java_major=None) -> dict:
    """Record an import prerequisite failure without touching runtime registries."""
    status = {
        "minecraft_version": VERSION,
        "source_status": "BLOCKED_BEFORE_REFERENCE_DOWNLOAD",
        "authoritative_data_validated": False,
        "download_attempted": False,
        "java_major": detected_java_major,
        "required_java_major": 25,
        "reason": reason,
        "official_manifest_url": MANIFEST_URL,
        "runtime_registries_modified": False,
    }
    writej(REG / "vanilla_import_status.json", status)
    manifest_path = REG / "manifest.json"
    if manifest_path.exists():
        manifest_doc = readj(manifest_path)
        manifest_doc["last_source_import_attempt"] = {
            "minecraft_version": VERSION,
            "status": status["source_status"],
            "reason": reason,
            "download_attempted": False,
            "runtime_registries_modified": False,
        }
        writej(manifest_path, manifest_doc)
    return status

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--version",default=VERSION)
    args=ap.parse_args()
    if args.version != VERSION: ap.error(f"Importer is pinned to {VERSION}")
    major=java_major()
    if major is None or major < 25:
        reason=f"Java 25+ required for Minecraft {VERSION}; detected {major}"
        record_sync_blocker(reason, major)
        raise RuntimeError(reason)
    CACHE.mkdir(parents=True,exist_ok=True)
    manifest=fetchj(MANIFEST_URL)
    entry=next((v for v in manifest.get("versions",[]) if v.get("id")==VERSION),None)
    if entry is None: raise RuntimeError(f"Official Mojang manifest does not contain {VERSION}")
    meta=fetchj(entry["url"])
    if meta.get("id") != VERSION: raise RuntimeError(f"Version metadata says {meta.get('id')!r}, expected {VERSION}")
    writej(CACHE/"version.json",meta)
    dl=meta.get("downloads",{})
    for label in ("server","client"):
        if not isinstance(dl.get(label),dict): raise RuntimeError(f"Official metadata has no {label} jar")
    server=download_verified(dl["server"]["url"],CACHE/"server.jar",dl["server"]["sha1"],int(dl["server"]["size"]))
    client=download_verified(dl["client"]["url"],CACHE/"client.jar",dl["client"]["sha1"],int(dl["client"]["size"]))

    with tempfile.TemporaryDirectory(prefix="flatworld-mc-26.3-") as t:
        temp=Path(t); gen=temp/"reports-work"; gen.mkdir()
        # Canonical runtime registries are staged and committed only after all integrity
        # gates pass. A failed import must never leave half-written official registries.
        staged_reg=temp/"registry-output"; staged_reg.mkdir()
        cmd=["java","-DbundlerMainClass=net.minecraft.data.Main","-jar",str(server),"--reports"]
        cp=subprocess.run(cmd,cwd=gen,capture_output=True,text=True,timeout=900)
        (gen/"stdout.log").write_text(cp.stdout,encoding="utf-8"); (gen/"stderr.log").write_text(cp.stderr,encoding="utf-8")
        if cp.returncode != 0: raise RuntimeError(f"Vanilla --reports failed ({cp.returncode}); see {gen}/stderr.log")
        src=find_reports(gen)
        if REPORTS.exists(): shutil.rmtree(REPORTS)
        shutil.copytree(src,REPORTS)
        inner=extract_inner_server(server,temp)
        # Exact raw vanilla datapack entries, including JSON/NBT/functions; nothing is synthesized here.
        server_files=extract_tree(inner,SERVER_DATA,lambda n:n.startswith("data/") and not n.endswith("/"))
        # Exact client model JSON graph only. Official image textures are not copied to the repo.
        client_files=extract_tree(client,CLIENT_JSON,lambda n:n.startswith("assets/minecraft/") and n.endswith((".json",".mcmeta")) and (n.startswith("assets/minecraft/blockstates/") or n.startswith("assets/minecraft/models/") or n.startswith("assets/minecraft/items/") or n=="assets/minecraft/lang/en_us.json"))
        required=[REPORTS/n for n in ("blocks.json","items.json","entities.json","registries.json")]
        if any(not p.is_file() for p in required): raise RuntimeError("Missing one or more required vanilla reports")
        if len(server_files)<100 or len(client_files)<100: raise RuntimeError(f"Unexpectedly few source files: server={len(server_files)}, client JSON={len(client_files)}")

        block_doc=readj(REPORTS/"blocks.json"); item_doc=readj(REPORTS/"items.json"); entity_doc=readj(REPORTS/"entities.json")
        registries_doc=readj(REPORTS/"registries.json")
        blocks,states=parse_blocks(block_doc); items,components=parse_items(item_doc,set(blocks)); entities=parse_entities(entity_doc)
        datapack_json=[p for p in SERVER_DATA.rglob("*.json") if p.is_file()]
        client_json=[p for p in CLIENT_JSON.rglob("*.json") if p.is_file()]
        datapack_index=index_files(SERVER_DATA,datapack_json)
        client_index=index_files(CLIENT_JSON,client_json)
        blockstates={k:v for k,v in client_index.items() if "/blockstates/" in ("/"+v["path"])}
        block_models={k:v for k,v in client_index.items() if "/models/block/" in ("/"+v["path"])}
        item_models={k:v for k,v in client_index.items() if "/models/item/" in ("/"+v["path"])}
        item_definitions={k:v for k,v in client_index.items() if "/items/" in ("/"+v["path"])}
        tags_all={k:v for k,v in datapack_index.items() if "/tags/" in ("/"+v["path"])}
        tags={"all":tags_all}
        for row in tags_all.values():
            section, resource_id=server_tag_registry(row["path"])
            if section is not None and resource_id is not None:
                tags.setdefault(section,{})[resource_id]=row
        recipes={}
        loot={}
        for k,row in datapack_index.items():
            rid=server_registry_id(row["path"],"recipes")
            if rid is not None: recipes[rid]=row
            lid=server_registry_id(row["path"],"loot_tables")
            if lid is not None: loot[lid]=row
        wg={k:v for k,v in datapack_index.items() if "/worldgen/" in ("/"+v["path"])}
        worldgen={"all":wg}
        for group,parts in {
            "biomes":["/worldgen/biome/"], "configured_carvers":["/worldgen/configured_carver/"],
            "configured_features":["/worldgen/configured_feature/"], "placed_features":["/worldgen/placed_feature/"],
            "features":["/worldgen/feature/"], "structures":["/worldgen/structure/"],
            "structure_sets":["/worldgen/structure_set/"], "noise_settings":["/worldgen/noise_settings/"],
            "density_functions":["/worldgen/density_function/"], "noise_parameters":["/worldgen/noise/"],
            "processor_lists":["/worldgen/processor_list/"], "template_pools":["/worldgen/template_pool/"],
            "material_rules":["/worldgen/material_rule/"], "material_conditions":["/worldgen/material_condition/"],
            "flat_level_generator_presets":["/worldgen/flat_level_generator_preset/"],
            "multi_noise_biome_source_parameter_lists":["/worldgen/multi_noise_biome_source_parameter_list/"]}.items():
            worldgen[group]={}
            for k,row in wg.items():
                if any(part in ("/"+row["path"]) for part in parts):
                    rid=server_registry_id(row["path"],"worldgen")
                    if rid is not None: worldgen[group][rid]=row
        # Dimensions and dimension types are sibling datapack registries, not worldgen/ subfolders.
        for group,prefix in (("dimensions","dimension/"),("dimension_types","dimension_type/")):
            worldgen[group]={}
            for k,row in datapack_index.items():
                rel="/"+row["path"]
                match=re.match(r"data/([^/]+)/"+re.escape(prefix)+r"(.+)\.json$",row["path"])
                if match: worldgen[group][f"{match.group(1)}:{match.group(2)}"]=row

        # Preserve original visual adapters only for known project IDs. Any canonical block without
        # a project adapter is marked missing, never silently mapped to another block's texture.
        rv=REG/"block_render_definitions.json"; iv=REG/"item_visual_definitions.json"
        previous_blocks_doc=readj(REG/"blocks.json") if (REG/"blocks.json").exists() else {}
        previous_items_doc=readj(REG/"items.json") if (REG/"items.json").exists() else {}
        previous_block_ids=set(previous_blocks_doc.get("blocks",{}))
        previous_item_ids=set(previous_items_doc.get("items",{}))
        project_visuals=readj(rv).get("block_render_definitions",{}) if rv.exists() else {}
        project_item_visuals=readj(iv).get("item_visual_definitions",{}) if iv.exists() else {}
        # A successful source import must also retire project-only render/icon IDs.
        # Missing official render adapters/icons remain missing; never borrow another ID's art.
        visuals=filter_registry_entries(project_visuals, blocks)
        item_visuals=filter_registry_entries(project_item_visuals, items)
        previous_fallback_doc=readj(REG/"model_fallbacks.json") if (REG/"model_fallbacks.json").exists() else {}
        project_fallbacks=previous_fallback_doc.get("models", {})
        model_fallbacks=filter_registry_entries(project_fallbacks, blocks)
        block_item_mapping=build_project_block_item_mappings(blocks, items, visuals)
        for item_id, item_row in items.items():
            item_row.pop("block_id", None)
        for bid,row in blocks.items():
            row["visual_ref"]=bid if bid in visuals else None
            row["render_status"]="project_renderer_present" if bid in visuals else "missing_renderer_requires_model_adapter"
        for iid,row in items.items(): row["visual_ref"]=iid if iid in item_visuals else None

        writej(staged_reg/"blocks.json",{"schema_version":3,"minecraft_version":VERSION,"registry_kind":"authoritative_vanilla_block_registry","source":"Mojang --reports/blocks.json","blocks":blocks})
        writej(staged_reg/"items.json",{"schema_version":3,"minecraft_version":VERSION,"registry_kind":"authoritative_vanilla_item_registry","source":"Mojang --reports/items.json","items":items})
        writej(staged_reg/"block_render_definitions.json",{"schema_version":1,"minecraft_version":VERSION,"source_status":"project render adapters filtered to authoritative vanilla block IDs; no invented fallback models","block_render_definitions":visuals})
        writej(staged_reg/"item_visual_definitions.json",{"schema_version":1,"minecraft_version":VERSION,"source_status":"project item icons filtered to authoritative vanilla item IDs; official item model graph in models.json","item_visual_definitions":item_visuals})
        writej(staged_reg/"model_fallbacks.json",{"schema_version":1,"minecraft_version":VERSION,"source_status":"project fallback models filtered to authoritative vanilla block IDs; these are not vanilla model definitions","models":model_fallbacks})
        writej(staged_reg/"block_item_mappings.json",block_item_mapping)
        writej(staged_reg/"block_states.json",{"schema_version":3,"minecraft_version":VERSION,"source":"Every state in Mojang --reports/blocks.json","block_states":states})
        writej(staged_reg/"item_components.json",{"schema_version":3,"minecraft_version":VERSION,"source":"Mojang --reports/items.json","item_components":components,"component_registry_report":registries_doc})
        writej(staged_reg/"entity_types.json",{"schema_version":3,"minecraft_version":VERSION,"source":"Mojang --reports/entities.json","entities":entities})
        behavior_doc=readj(REG/"entity_behaviors.json") if (REG/"entity_behaviors.json").exists() else {}
        behavior_rows=filter_registry_entries(behavior_doc.get("entities",{}), entities)
        writej(staged_reg/"entity_behaviors.json",{**behavior_doc,"source_status":"partial Flatworld behavior implementations filtered to official Java 26.3 entity IDs","entities":behavior_rows})
        writej(staged_reg/"models.json",{"schema_version":3,"minecraft_version":VERSION,"source":"Official 26.3 client JSON assets","blockstates":blockstates,"block_models":block_models,"item_models":item_models,"item_definitions":item_definitions,"all_client_json":client_index})
        writej(staged_reg/"vanilla_recipes_index.json",{"minecraft_version":VERSION,"source":"exact official server data files","recipes":recipes})
        writej(staged_reg/"tags.json",{"schema_version":3,"minecraft_version":VERSION,"source":"exact official server data files",**tags})
        writej(staged_reg/"loot_tables.json",{"schema_version":3,"minecraft_version":VERSION,"source":"exact official server data files","tables":loot})
        writej(staged_reg/"worldgen.json",{"schema_version":3,"minecraft_version":VERSION,"source":"exact official server data files",**worldgen})
        status={"minecraft_version":VERSION,"official_manifest_url":MANIFEST_URL,"metadata_url":entry["url"],"java_major":java_major(),
                "server_sha1":dl["server"]["sha1"],"client_sha1":dl["client"]["sha1"],"server_bytes":int(dl["server"]["size"]),"client_bytes":int(dl["client"]["size"]),
                "server_data_file_count":len(server_files),"client_json_file_count":len(client_files),"report_files":[p.name for p in REPORTS.iterdir() if p.is_file()],
                "counts":{"blocks":len(blocks),"items":len(items),"entities":len(entities),"block_ids_with_state_data":len(states),
                          "state_rows":sum(v["state_count"] for v in states.values()),"blockstates":len(blockstates),"block_models":len(block_models),
                          "item_models":len(item_models),"item_definitions":len(item_definitions),"recipes":len(recipes),"tags":len(tags["all"]),"loot_tables":len(loot),"worldgen_files":len(wg),
                          "project_render_adapters":len(visuals),"canonical_blocks_without_project_render_adapter":len(set(blocks)-set(visuals)-{"air"}),
                          "project_item_icons":len(item_visuals),"canonical_items_without_project_icon":len(set(items)-set(item_visuals)),
                          "project_fallback_models":len(model_fallbacks),
                          "project_item_to_block_mappings":len(block_item_mapping["item_to_block"]),
                          "project_behavior_adapters_retained":len(behavior_rows)},
                "project_vs_vanilla_ids":{"project_only_blocks":sorted(previous_block_ids-set(blocks)),
                    "vanilla_blocks_missing_from_project_subset":sorted(set(blocks)-previous_block_ids),
                    "project_only_items":sorted(previous_item_ids-set(items)),
                    "vanilla_items_missing_from_project_subset":sorted(set(items)-previous_item_ids)},
                "datapack_version_from_mojang_release_notes":121,"resource_pack_version_from_mojang_release_notes":"97.1",
                "official_raw_report_sha256":{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in REPORTS.glob("*.json")},
                "source_status":"hash-verified exact Java 26.3 download; Mojang reports and official JSON/data extracted",
                "runtime_status":"imported registry data is not the same as implementing every game mechanic; renderer/recipes/loot/entities/worldgen need behavior-specific runtime tests"}
        # Structural integrity gates: exact version/hash-verified JAR inputs, every block
        # has a state record, state IDs are unique, and all client/server index targets exist
        # and still match their recorded SHA-256. This validates source extraction, not runtime parity.
        state_integrity=validate_state_registry(blocks,states)
        def index_integrity(root_dir, index):
            if not index: return False
            for entry in index.values():
                rel=entry.get("path", "")
                target=root_dir/rel
                if not rel or not target.is_file(): return False
                if hashlib.sha256(target.read_bytes()).hexdigest()!=entry.get("sha256"): return False
            return True
        paths_valid = index_integrity(SERVER_DATA, datapack_index) and index_integrity(CLIENT_JSON, client_index)
        state_ids_valid = bool(state_integrity["all_reported_state_ids_unique"])
        all_rows_have_numeric_ids = bool(state_integrity["all_state_rows_have_numeric_ids"])
        one_default_per_block = bool(state_integrity["exactly_one_default_state_per_block"])
        status["integrity_checks"]={**state_integrity,
            "all_server_index_paths_and_hashes_valid":index_integrity(SERVER_DATA,datapack_index),
            "all_client_index_paths_and_hashes_valid":index_integrity(CLIENT_JSON,client_index),
            "client_blockstates_present":len(blockstates)>100,
            "client_block_models_present":len(block_models)>100,
            "server_datapack_indexes_present":len(datapack_index)>100}
        status["authoritative_data_validated"]=bool(status["server_data_file_count"]>100 and status["client_json_file_count"]>100 and len(blocks)>100 and len(items)>100 and len(entities)>50 and len(states)==len(blocks) and state_ids_valid and all_rows_have_numeric_ids and one_default_per_block and paths_valid and len(blockstates)>100 and len(block_models)>100)
        # Emit actionable per-ID comparison reports. Imported registry coverage is not the
        # same as having a renderer, UI icon, or implemented behavior.
        import csv
        docs_dir=ROOT/"docs"; docs_dir.mkdir(parents=True,exist_ok=True)
        with (docs_dir/"VANILLA_26.3_REGISTRY_DIFF.csv").open("w",encoding="utf-8",newline="") as out:
            writer=csv.writer(out); writer.writerow(["registry","id","present_in_previous_project_subset","present_in_official_26_3","has_project_render_or_behavior_adapter","needs_runtime_work"])
            for bid in sorted(set(previous_block_ids)|set(blocks)):
                in_source=bid in blocks; in_project=bid in previous_block_ids
                has_adapter=bid in visuals
                writer.writerow(["block",bid,in_project,in_source,has_adapter,(not has_adapter) or not in_source])
            behavior_ids=set(readj(REG/"entity_behaviors.json").get("entities",{}))
            for iid in sorted(set(previous_item_ids)|set(items)):
                in_source=iid in items; in_project=iid in previous_item_ids
                writer.writerow(["item",iid,in_project,in_source,iid in item_visuals,(not (iid in item_visuals)) or not in_source])
            for eid in sorted(set(behavior_ids)|set(entities)):
                writer.writerow(["entity_type",eid,eid in behavior_ids,eid in entities,eid in behavior_ids,eid not in behavior_ids])
        with (docs_dir/"VANILLA_26.3_RESOURCE_COVERAGE.csv").open("w",encoding="utf-8",newline="") as out:
            writer=csv.writer(out); writer.writerow(["resource_registry","id","source_file_exists","sha256_recorded","runtime_consumer_status"])
            coverage_groups=[("blockstate",blockstates,"raw JSON indexed; renderer integration pending"),
                ("block_model",block_models,"raw JSON indexed; mesh resolver integration pending"),
                ("item_model",item_models,"raw JSON indexed; item rendering integration pending"),
                ("item_definition",item_definitions,"raw JSON indexed; inventory rendering integration pending"),
                ("recipe",recipes,"raw JSON indexed; serializers pending"),
                ("tag",tags["all"],"raw JSON indexed; consumers pending"),
                ("loot_table",loot,"raw JSON indexed; evaluator pending"),
                ("worldgen",wg,"raw JSON indexed; generation runtime pending")]
            for group,index,consumer_status in coverage_groups:
                for rid,row in sorted(index.items()):
                    writer.writerow([group,rid,(CLIENT_JSON/row["path"]).is_file() if group in ("blockstate","block_model","item_model","item_definition") else (SERVER_DATA/row["path"]).is_file(),bool(row.get("sha256")),consumer_status])
        writej(REG/"vanilla_import_status.json",status)
        if not status["authoritative_data_validated"]:
            # Leave the previously working runtime registries untouched on any failed gate.
            print(json.dumps(status,ensure_ascii=False,indent=2))
            return 2
        for staged_path in sorted(staged_reg.iterdir()):
            if staged_path.is_file():
                shutil.copy2(staged_path, REG / staged_path.name)
        # Keep the legacy texture-authoring view aligned with official block IDs too.
        root_blocks_path = DATA_ROOT / "blocks.json"
        if root_blocks_path.is_file():
            root_blocks_doc = readj(root_blocks_path)
            writej(root_blocks_path, filter_block_render_document(root_blocks_doc, blocks))
        # Sample recipes are not Vanilla recipes; keep only the subset valid against the
        # official item registry. The exact Vanilla recipe index remains separate.
        sample_recipe_path = DATA_ROOT / "recipes.json"
        if sample_recipe_path.is_file():
            sample_recipe_doc = readj(sample_recipe_path)
            writej(sample_recipe_path, filter_runtime_sample_recipes(sample_recipe_doc, items))
        manifest_path=REG/"manifest.json"; manifest=readj(manifest_path) if manifest_path.exists() else {}
        manifest.update({"minecraft_version":VERSION,"authoritative_reference_imported":status["authoritative_data_validated"],
                         "status":"VANILLA_26_3_REFERENCE_IMPORTED" if status["authoritative_data_validated"] else "REFERENCE_EXTRACTED_VALIDATION_INCOMPLETE",
                         "official_registry_counts":status["counts"],"official_raw_report_sha256":status["official_raw_report_sha256"],
                         "canonical_known_block_ids":sorted(blocks),"canonical_known_item_ids":sorted(items),
                         "canonical_known_entity_ids":sorted(entities),"current_counts":{
                             "project_rendered_block_definitions":len(visuals),"project_known_block_registry_entries":len(blocks),
                             "project_known_item_registry_entries":len(items),"project_entity_types":len(entities),
                             "runtime_entity_behaviors":len(readj(REG/"entity_behaviors.json").get("entities",{})),
                             "sample_runtime_recipes":len(readj(DATA_ROOT / "recipes.json").get("recipes",{})) if (DATA_ROOT / "recipes.json").is_file() else 0,
                             "registered_block_face_swatches":sum(len(v.get("tiles",{})) for v in visuals.values()),
                             "project_item_icons":len(item_visuals),
                             "project_item_to_block_mappings":len(block_item_mapping["item_to_block"]),
                             "project_block_state_records":len(states)},
                         "block_registry_source_status":"exact Mojang Java 26.3 server report" if status["authoritative_data_validated"] else "official reference extracted; integrity incomplete",
                         "item_registry_source_status":"exact Mojang Java 26.3 server report" if status["authoritative_data_validated"] else "official reference extracted; integrity incomplete",
                         "runtime_implementation_status":{
                             "blocks_items_states":"full source registries imported; runtime block behaviors/render adapter still partial",
                             "models":"official JSON files indexed; model resolver must still be integrated/tested in voxel renderer",
                             "recipes":"official vanilla recipe source index imported; serializers/runtime matching still partial",
                             "entities":"full source entity types imported; runtime AI/animation/model support remains a subset",
                             "tags_loot_worldgen":"official files indexed; tag consumers, loot evaluator and worldgen execution still require implementation",
                             "android_apk":"not exported or device-tested"}})
        writej(manifest_path,manifest)
        canonical_ids={"minecraft_version":VERSION,"data_version":5023,"project_version":"0.5.5",
            "authoritative_reference_imported":status["authoritative_data_validated"],
            "status":"official report ID lists imported; renderer coverage must still be reviewed" if status["authoritative_data_validated"] else "reference extraction did not pass full integrity checks",
            "block_count":len(blocks),"item_count":len(items),"render_definition_count":len(visuals),
            "block_ids":sorted(blocks),"item_ids":sorted(items),
            "source":"Mojang Java 26.3 reports verified against official manifest JAR hashes"}
        writej(ROOT/"docs/canonical_registry_ids_0.5.5.json",canonical_ids)
        print(json.dumps(status,ensure_ascii=False,indent=2))
        return 0 if status["authoritative_data_validated"] else 2

if __name__ == "__main__":
    try: raise SystemExit(main())
    except (OSError,RuntimeError,urllib.error.URLError,zipfile.BadZipFile,json.JSONDecodeError,subprocess.SubprocessError,KeyError,ValueError) as exc:
        print(f"ERROR: {exc}",file=sys.stderr); raise SystemExit(1)
