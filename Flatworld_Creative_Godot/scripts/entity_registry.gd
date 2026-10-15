extends RefCounted
class_name EntityRegistry

const ROOT := "res://assets/data/registries/26.3/"
static var _types: Dictionary = {}
static var _behaviors: Dictionary = {}
static var _loaded := false

static func load_data(force_reload: bool = false) -> void:
    if _loaded and not force_reload:
        return
    var type_doc := _read_json(ROOT + "entity_types.json")
    var behavior_doc := _read_json(ROOT + "entity_behaviors.json")
    _types = type_doc.get("entities", {})
    _behaviors = behavior_doc.get("entities", {})
    _loaded = true

static func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        push_warning("Missing entity registry data: " + path)
        return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    var value: Variant = JSON.parse_string(file.get_as_text())
    return value if value is Dictionary else {}

static func get_entity_type(entity_id: String) -> Dictionary:
    load_data()
    return _types.get(entity_id, {})

static func get_runtime_behaviors() -> Dictionary:
    load_data()
    return _behaviors.duplicate(true)

static func get_canonical_entity_ids() -> Array[String]:
    load_data()
    var result: Array[String] = []
    for key in _types.keys():
        result.append(str(key))
    result.sort()
    return result

static func is_runtime_supported(entity_id: String) -> bool:
    load_data()
    return bool(_behaviors.get(entity_id, {}).get("runtime_supported", false))
