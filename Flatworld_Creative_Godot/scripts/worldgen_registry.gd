extends RefCounted
class_name WorldgenRegistry

const ROOT := "res://assets/data/registries/26.3/"
static var _index: Dictionary = {}
static var _loaded := false

static func load_data(force_reload: bool = false) -> void:
    if _loaded and not force_reload: return
    _index = _read_json(ROOT + "worldgen.json")
    _loaded = true

static func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path): return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null: return {}
    var value: Variant = JSON.parse_string(file.get_as_text())
    return value if value is Dictionary else {}

static func get_ids(category: String = "all") -> Array[String]:
    load_data()
    var group: Variant = _index.get(category, {})
    var ids: Array[String] = []
    if group is Dictionary:
        for key in group.keys(): ids.append(str(key))
    elif group is Array:
        for value in group: ids.append(str(value))
    ids.sort()
    return ids

static func get_definition(category: String, resource_id: String) -> Dictionary:
    load_data()
    var group: Variant = _index.get(category, {})
    if not group is Dictionary: return {}
    var key := resource_id if resource_id.contains(":") else "minecraft:" + resource_id
    var row: Variant = group.get(key, {})
    if not row is Dictionary or not row.has("path"): return {}
    return _read_json(ROOT + "vanilla_reference/server_data/" + str(row["path"]))

static func has_imported_data() -> bool:
    load_data()
    return _index.get("all", {}).size() > 0
