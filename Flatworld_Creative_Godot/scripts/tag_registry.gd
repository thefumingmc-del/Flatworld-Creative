extends RefCounted
class_name TagRegistry

const ROOT := "res://assets/data/registries/26.3/"
static var _doc: Dictionary = {}
static var _loaded := false

static func load_data(force_reload: bool = false) -> void:
    if _loaded and not force_reload:
        return
    _doc = _read_json(ROOT + "tags.json")
    _loaded = true

static func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    var value: Variant = JSON.parse_string(file.get_as_text())
    return value if value is Dictionary else {}

static func _normalize_id(value: String) -> String:
    return value.trim_prefix("minecraft:")

static func _tag_index(section: String) -> Dictionary:
    load_data()
    var value: Variant = _doc.get(section, {})
    return value if value is Dictionary else {}

static func get_tag_document(registry_kind: String, tag_id: String) -> Dictionary:
    load_data()
    var section_by_kind := {
        "block": "blocks", "blocks": "blocks",
        "item": "items", "items": "items",
        "entity": "entity_types", "entity_type": "entity_types", "entity_types": "entity_types",
        "biome": "biomes", "biomes": "biomes", "worldgen/biome": "biomes",
        "configured_feature": "configured_features", "configured_features": "configured_features",
        "placed_feature": "placed_features", "placed_features": "placed_features",
        "structure_set": "structure_sets", "structure_sets": "structure_sets",
        "flat_level_generator_preset": "flat_level_generator_presets", "flat_level_generator_presets": "flat_level_generator_presets",
        "processor_list": "processor_lists", "processor_lists": "processor_lists",
        "template_pool": "template_pools", "template_pools": "template_pools",
        "fluid": "fluids", "fluids": "fluids",
        "game_event": "game_events", "game_events": "game_events",
        "instrument": "instruments", "instruments": "instruments",
        "point_of_interest_type": "point_of_interest_types", "point_of_interest_types": "point_of_interest_types",
        "structure": "structures", "structures": "structures",
        "damage_type": "damage_types", "damage_types": "damage_types",
        "enchantment": "enchantments", "enchantments": "enchantments",
        "banner_pattern": "banner_patterns", "banner_patterns": "banner_patterns",
        "function": "functions", "functions": "functions"
    }
    var index_section := str(section_by_kind.get(registry_kind, "all"))
    if registry_kind.begins_with("other:"):
        index_section = registry_kind
    var index := _tag_index(index_section)
    var normalized := _normalize_id(tag_id)
    var row: Variant = index.get(normalized, index.get("minecraft:" + normalized, {}))
    if row is Dictionary and row.has("path"):
        return _read_json(ROOT + "vanilla_reference/server_data/" + str(row["path"]))
    var fallback_key := "block_tags" if index_section == "blocks" else "item_tags" if index_section == "items" else "entity_tags" if index_section == "entity_types" else "biome_tags" if index_section == "biomes" else ""
    var fallback: Variant = []
    if not fallback_key.is_empty():
        var fallback_doc: Variant = _doc.get(fallback_key, {})
        if fallback_doc is Dictionary:
            fallback = fallback_doc.get(normalized, [])
    return {"replace": false, "values": fallback if fallback is Array else []}

static func get_members(registry_kind: String, tag_id: String, depth: int = 0, seen: Array = []) -> Array[String]:
    var result: Array[String] = []
    if depth > 32:
        push_warning("Tag recursion limit exceeded for " + tag_id)
        return result
    var normalized := _normalize_id(tag_id)
    var visit_key := registry_kind + ":" + normalized
    if seen.has(visit_key):
        return result
    var next_seen := seen.duplicate()
    next_seen.append(visit_key)
    var doc := get_tag_document(registry_kind, normalized)
    var values: Variant = doc.get("values", [])
    if not values is Array:
        return result
    for entry in values:
        var member := str(entry) if entry is String else str(entry.get("id", "")) if entry is Dictionary else ""
        if member.is_empty():
            continue
        # Optional values remain part of the tag definition; the consumer decides whether
        # the referenced registry value exists. Do not silently drop them during parsing.
        if member.begins_with("#"):
            for nested in get_members(registry_kind, member.trim_prefix("#"), depth + 1, next_seen):
                if not result.has(nested): result.append(nested)
        else:
            var canonical := _normalize_id(member)
            if not result.has(canonical): result.append(canonical)
    return result

static func contains(registry_kind: String, tag_id: String, member_id: String) -> bool:
    return get_members(registry_kind, tag_id).has(_normalize_id(member_id))
