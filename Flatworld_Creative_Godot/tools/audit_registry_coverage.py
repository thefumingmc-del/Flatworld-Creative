#!/usr/bin/env python3
"""Generate per-ID coverage/delta reports without inventing a vanilla registry.

Before authoritative import, this reports the known Flatworld subset and explicitly
marks Vanilla 26.3 presence unknown. After the pinned Mojang importer succeeds, it
compares the captured pre-import project IDs with the imported complete registries.
"""
from __future__ import annotations
import csv, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REG = ROOT / "assets/data/registries/26.3"
DOCS = ROOT / "docs"
BASELINE = DOCS / "project_subset_ids_0.5.5.json"


def readj(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, obj: dict) -> None:
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def row_next_action(kind, rid, imported, present, render=False, state_status="", model_status="", icon=False, component=False, mapped=False):
    if not imported:
        return "Obtain/import hash-verified Mojang Java 26.3 reports; do not infer canonical presence from this subset."
    if not present:
        return "Retire or migrate this project-only ID using an explicit migration and regression tests."
    if kind == "block":
        tasks=[]
        if state_status != "complete": tasks.append("import and test every official block state/default state")
        if not render: tasks.append("implement the official model/blockstate graph or mark intentionally non-renderable")
        if model_status not in ("MODEL_JSON_PRESENT", "NON_RENDERABLE_OR_NO_BLOCKSTATE_JSON"):
            tasks.append("resolve official model JSON inheritance, variants, multipart and UVs")
        if not tasks: tasks.append("run all-state renderer/placement/collision regression tests in Godot")
        return "; ".join(tasks) + "."
    tasks=[]
    if not component: tasks.append("import exact item components and enforce their semantics")
    if not icon: tasks.append("supply a correct item model/sprite and test icon rendering")
    if not mapped and rid in readj(REG/"items.json").get("items",{}):
        tasks.append("confirm BlockItem/placement behavior from source or explicit interaction rule")
    if not tasks: tasks.append("test stack size, use, drop, pickup and model rendering against Java")
    return "; ".join(tasks) + "."


def main() -> int:
    manifest=readj(REG/"manifest.json")
    block_doc=readj(REG/"blocks.json"); item_doc=readj(REG/"items.json")
    render_doc=readj(REG/"block_render_definitions.json")
    states_doc=readj(REG/"block_states.json")
    item_visual_doc=readj(REG/"item_visual_definitions.json")
    components_doc=readj(REG/"item_components.json")
    mapping=readj(REG/"block_item_mappings.json")
    models=readj(REG/"models.json")
    imported=bool(manifest.get("authoritative_reference_imported", False))
    base=readj(BASELINE) if BASELINE.exists() else {
        "block_ids":sorted(block_doc.get("blocks",{})), "item_ids":sorted(item_doc.get("items",{})),
        "project_version":"0.5.5", "baseline_status":"captured from working-tree subset"
    }
    if not BASELINE.exists(): write_json(BASELINE, base)
    blocks=set(block_doc.get("blocks",{})); items=set(item_doc.get("items",{}))
    render_ids=set(render_doc.get("block_render_definitions",{}))
    states=states_doc.get("block_states",{})
    item_visuals=item_visual_doc.get("item_visual_definitions",{})
    components=components_doc.get("item_components",{})
    item_to_block=mapping.get("item_to_block",{})
    model_paths={str(v.get("path","")) for grp in ("blockstates", "block_models") for v in models.get(grp,{}).values() if isinstance(v,dict)}
    fields=["registry_kind","id","in_0_5_5_project_baseline","currently_registered","authoritative_reference_imported","confirmed_in_java_26_3","render_adapter_or_icon","state_record_status","model_json_status","item_component_record","item_to_block_mapped","delta_status","next_improvement"]
    out=DOCS/"REGISTRY_COVERAGE_CURRENT_SUBSET_0.5.5.csv"
    with out.open("w",newline="",encoding="utf-8") as fh:
        w=csv.DictWriter(fh,fieldnames=fields); w.writeheader()
        for kind, current, baseline in (("block",blocks,set(base.get("block_ids",[]))), ("item",items,set(base.get("item_ids",[])))):
            for rid in sorted(current|baseline):
                present=rid in current
                in_base=rid in baseline
                confirmed=("YES" if present else "NO") if imported else "UNKNOWN_REFERENCE_NOT_IMPORTED"
                adapter=(rid in render_ids) if kind=="block" else (rid in item_visuals)
                state_status="N/A"
                model_status="NOT_APPLICABLE"
                comp=(rid in components) if kind=="item" else False
                mapped=(rid in item_to_block) if kind=="item" else False
                if kind=="block":
                    state=states.get(rid,{})
                    state_status="complete" if state.get("complete") is True else ("provisional" if state else "missing")
                    expected=f"assets/minecraft/blockstates/{rid}.json"
                    has_model=expected in model_paths
                    model_status=("MODEL_JSON_PRESENT" if has_model else "NON_RENDERABLE_OR_NO_BLOCKSTATE_JSON") if imported else "NOT_IMPORTED"
                if not imported:
                    delta = "REFERENCE_NOT_IMPORTED"
                elif not present:
                    delta = "PROJECT_ONLY_ID_REQUIRES_MIGRATION"
                elif not in_base:
                    delta = "VANILLA_ID_MISSING_FROM_ORIGINAL_PROJECT_SUBSET"
                else:
                    delta = "CANONICAL_ID_PRESERVED_FROM_PROJECT_SUBSET"
                action=row_next_action(kind,rid,imported,present,adapter,state_status,model_status,adapter if kind=="item" else False,comp,mapped)
                w.writerow({"registry_kind":kind,"id":rid,"in_0_5_5_project_baseline":in_base,"currently_registered":present,
                    "authoritative_reference_imported":imported,"confirmed_in_java_26_3":confirmed,"render_adapter_or_icon":adapter,
                    "state_record_status":state_status,"model_json_status":model_status,"item_component_record":comp if kind=="item" else "N/A",
                    "item_to_block_mapped":mapped if kind=="item" else "N/A","delta_status":delta,"next_improvement":action})
    summary={"project_version":"0.5.5","minecraft_java_target":"26.3","authoritative_reference_imported":imported,
        "source_of_current_ids":"current Flatworld working-tree registry subset; NOT evidence of full Vanilla 26.3 coverage",
        "baseline_counts":{"blocks":len(base.get("block_ids",[])),"items":len(base.get("item_ids",[]))},
        "current_counts":{"blocks":len(blocks),"render_adapters":len(render_ids),"items":len(items),"item_icons":len(item_visuals),
            "item_component_rows":len(components),"block_state_rows":len(states),"item_to_block_mappings":len(item_to_block)},
        "report":str(out.relative_to(ROOT)),"next_gate":"Run tools/sync_java_26_3_reference.py under Java 25+ with network access; only then can this report claim exact ID presence/absence."}
    write_json(DOCS/"REGISTRY_COVERAGE_CURRENT_SUBSET_0.5.5.json",summary)
    print(json.dumps(summary,indent=2))
    return 0

if __name__ == "__main__": raise SystemExit(main())
