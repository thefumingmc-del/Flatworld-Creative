extends RefCounted
class_name BlockRegistry

# Runtime facade over distinct versioned vanilla registries and project render adapters.
# The vanilla source registry is authoritative only when manifest.authoritative_reference_imported is true.
const REGISTRY_ROOT := "res://assets/data/registries/26.3/"
static var blocks: Dictionary = {}
static var block_definitions: Dictionary = {}
static var items: Dictionary = {}
static var item_visual_definitions: Dictionary = {}
static var item_components: Dictionary = {}
static var item_to_block: Dictionary = {}
static var block_to_item: Dictionary = {}
static var block_render_definitions: Dictionary = {}
static var block_states: Dictionary = {}
static var models: Dictionary = {}
static var model_fallbacks: Dictionary = {}
static var entity_types: Dictionary = {}
static var authoritative_reference_imported := false
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

static func load_data(force_reload: bool = false) -> void:
    if _loaded and not force_reload:
        return
    var bdoc := _read_json(REGISTRY_ROOT + "blocks.json")
    var rdoc := _read_json(REGISTRY_ROOT + "block_render_definitions.json")
    var idoc := _read_json(REGISTRY_ROOT + "items.json")
    var ivdoc := _read_json(REGISTRY_ROOT + "item_visual_definitions.json")
    var icdoc := _read_json(REGISTRY_ROOT + "item_components.json")
    var ibdoc := _read_json(REGISTRY_ROOT + "block_item_mappings.json")
    var sdoc := _read_json(REGISTRY_ROOT + "block_states.json")
    var mdoc := _read_json(REGISTRY_ROOT + "models.json")
    var fdoc := _read_json(REGISTRY_ROOT + "model_fallbacks.json")
    var edoc := _read_json(REGISTRY_ROOT + "entity_types.json")
    var manifest_doc := _read_json(REGISTRY_ROOT + "manifest.json")
    authoritative_reference_imported = bool(manifest_doc.get("authoritative_reference_imported", false))
    block_definitions = bdoc.get("blocks", {})
    block_render_definitions = rdoc.get("block_render_definitions", {})
    items = idoc.get("items", {})
    item_visual_definitions = ivdoc.get("item_visual_definitions", {})
    item_components = icdoc.get("item_components", {})
    item_to_block = ibdoc.get("item_to_block", {})
    block_to_item = ibdoc.get("block_to_item", {})
    block_states = sdoc.get("block_states", {})
    models = mdoc
    model_fallbacks = fdoc.get("models", {})
    entity_types = edoc.get("entities", {})

    blocks.clear()
    # This dictionary is block-only. Item identity, components, and inventory visuals
    # are never inserted here; identical strings in separate registries remain distinct.
    for block_key in block_definitions.keys():
        var block_id := str(block_key)
        var block: Dictionary = block_definitions[block_key]
        var visual: Dictionary = block_render_definitions.get(block_id, {})
        var runtime_block := visual.duplicate(true)
        runtime_block["id"] = block_id
        runtime_block["name"] = str(block.get("name", runtime_block.get("name", block_id.replace("_", " ").capitalize())))
        runtime_block["solid"] = bool(block.get("solid", runtime_block.get("solid", false)))
        runtime_block["placeable"] = bool(block.get("placeable", runtime_block.get("placeable", false)))
        runtime_block["hardness"] = float(block.get("hardness", runtime_block.get("hardness", 0.0)))
        runtime_block["transparent"] = bool(block.get("transparent", runtime_block.get("transparent", false)))
        runtime_block["emission"] = float(block.get("emission", runtime_block.get("emission", 0.0)))
        runtime_block["is_block"] = true
        runtime_block["block_id"] = block_id
        var mapped_item_id := str(block_to_item.get(block_id, ""))
        if not mapped_item_id.is_empty() and items.has(mapped_item_id):
            var item: Dictionary = items[mapped_item_id]
            runtime_block["max_stack_size"] = maxi(1, int(item.get("max_stack_size", item.get("stackSize", 64))))
            runtime_block["max_damage"] = item.get("max_damage", item.get("maxDurability", null))
            runtime_block["item_id"] = mapped_item_id
        else:
            runtime_block["max_stack_size"] = 64
            runtime_block["max_damage"] = null
            runtime_block["item_id"] = ""
        if block_id != "air":
            blocks[block_id] = runtime_block
    _loaded = true

static func has_authoritative_reference() -> bool:
    load_data()
    return authoritative_reference_imported

static func has_block(block_id: String) -> bool:
    load_data()
    return block_definitions.has(block_id)

static func is_canonical_block(block_id: String) -> bool:
    load_data()
    return block_definitions.has(block_id)

static func has_item(item_id: String) -> bool:
    load_data()
    return items.has(item_id)

static func get_item(item_id: String) -> Dictionary:
    # Canonical item registry record only; never returns block/render fields.
    load_data()
    return items.get(item_id, {})

static func get_item_runtime(item_id: String) -> Dictionary:
    # Presentation adapter joins item identity to its own icon/components without
    # mutating the canonical item or block record. Placement is strictly explicit.
    load_data()
    var item: Dictionary = items.get(item_id, {})
    if item.is_empty():
        return {}
    var runtime_item := item.duplicate(true)
    var visual: Dictionary = item_visual_definitions.get(item_id, {})
    for key in visual.keys():
        runtime_item[key] = visual[key]
    runtime_item["id"] = item_id
    runtime_item["item_id"] = item_id
    runtime_item["name"] = str(item.get("name", visual.get("name", item_id.replace("_", " ").capitalize())))
    runtime_item["max_stack_size"] = maxi(1, int(item.get("max_stack_size", item.get("stackSize", 64))))
    runtime_item["max_damage"] = item.get("max_damage", item.get("maxDurability", null))
    runtime_item["components"] = get_item_components(item_id)
    runtime_item["is_block"] = false
    runtime_item["block_id"] = str(item_to_block.get(item_id, ""))
    runtime_item["placeable"] = not str(runtime_item["block_id"]).is_empty()
    return runtime_item

static func get_item_name(item_id: String) -> String:
    load_data()
    var item: Dictionary = items.get(item_id, {})
    if not item.is_empty():
        return str(item.get("name", item_id.replace("_", " ").capitalize()))
    return item_id.replace("_", " ").capitalize()

static func get_item_visual(item_id: String) -> Dictionary:
    load_data()
    return item_visual_definitions.get(item_id, {})

static func get_item_components(item_id: String) -> Dictionary:
    load_data()
    var components: Variant = item_components.get(item_id, {})
    if components is Dictionary and not components.is_empty():
        return components
    var item: Dictionary = items.get(item_id, {})
    var item_components_value: Variant = item.get("components", {})
    return item_components_value if item_components_value is Dictionary else {}

static func get_item_component(item_id: String, component_id: String, default_value: Variant = null) -> Variant:
    var components := get_item_components(item_id)
    var key := component_id if component_id.contains(":") else "minecraft:" + component_id
    if components.has(key):
        return components[key]
    # Current partial data used unqualified names; keep this fallback until official import.
    return components.get(component_id.trim_prefix("minecraft:"), default_value)

static func get_item_icon_path(item_id: String) -> String:
    return str(get_item_visual(item_id).get("icon_path", ""))

static func get_block(block_id: String) -> Dictionary:
    load_data()
    return blocks.get(block_id, {})

static func get_block_render_definition(block_id: String) -> Dictionary:
    load_data()
    return block_render_definitions.get(block_id, {})

static func get_block_state_definition(block_id: String) -> Dictionary:
    load_data()
    return block_states.get(block_id, {})

static func get_model_definition(block_id: String) -> Dictionary:
    load_data()
    # Return the parsed vanilla blockstate JSON when reference assets have been imported.
    # A model index entry points to a project-relative JSON file and is not itself a model.
    var vanilla_states: Dictionary = models.get("blockstates", {})
    var namespaced_id := block_id if block_id.contains(":") else "minecraft:" + block_id
    if vanilla_states.has(namespaced_id):
        var model_doc := _read_indexed_json(vanilla_states[namespaced_id])
        if not model_doc.is_empty():
            return model_doc
    return model_fallbacks.get(block_id, {})

static func get_client_model_definition(model_id: String) -> Dictionary:
    load_data()
    var normalized := model_id if model_id.contains(":") else "minecraft:block/" + model_id
    var model_index: Dictionary = models.get("block_models", {})
    if not model_index.has(normalized):
        var item_index: Dictionary = models.get("item_models", {})
        if item_index.has(normalized):
            return _read_indexed_json(item_index[normalized])
        return {}
    return _read_indexed_json(model_index[normalized])

static func get_item_model_definition(item_id: String) -> Dictionary:
    load_data()
    var item_path := item_id.trim_prefix("minecraft:")
    var normalized := "minecraft:item_definition/" + item_path
    var definition_index: Dictionary = models.get("item_definitions", {})
    if definition_index.has(normalized):
        return _read_indexed_json(definition_index[normalized])
    return get_client_model_definition("minecraft:item/" + item_path)

static func _read_indexed_json(entry: Variant) -> Dictionary:
    if not entry is Dictionary:
        return {}
    var relative_path := str(entry.get("path", ""))
    if relative_path.is_empty():
        return {}
    var full_path := REGISTRY_ROOT + "vanilla_reference/client_json/" + relative_path
    return _read_json(full_path)

static func get_name(item_or_block_id: String) -> String:
    load_data()
    if block_definitions.has(item_or_block_id):
        var block_data: Dictionary = blocks.get(item_or_block_id, {})
        return str(block_data.get("name", item_or_block_id.replace("_", " ").capitalize()))
    return get_item_name(item_or_block_id)

static func is_solid(block_id: String) -> bool:
    return bool(get_block(block_id).get("solid", false))

static func is_placeable(block_id: String) -> bool:
    load_data()
    if not block_definitions.has(block_id):
        return false
    if not blocks.has(block_id):
        return false
    return bool(blocks[block_id].get("placeable", false))

static func get_placeable_ids() -> Array[String]:
    load_data()
    var result: Array[String] = []
    for key in block_to_item.keys():
        var block_id := str(key)
        if block_definitions.has(block_id) and is_placeable(block_id):
            result.append(block_id)
    result.sort()
    return result

static func get_catalogue_ids() -> Array[String]:
    return get_item_ids()

static func get_place_block_id(item_id: String) -> String:
    load_data()
    var block_id := str(item_to_block.get(item_id, ""))
    if block_id.is_empty() or not block_definitions.has(block_id):
        return ""
    return block_id

static func get_item_for_block(block_id: String) -> String:
    load_data()
    var item_id := str(block_to_item.get(block_id, ""))
    return item_id if items.has(item_id) else ""

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
