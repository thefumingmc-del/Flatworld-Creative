extends RefCounted
class_name LootTableRegistry

const ROOT := "res://assets/data/registries/26.3/"
static var _index: Dictionary = {}
static var _loaded := false

static func load_data(force_reload: bool = false) -> void:
    if _loaded and not force_reload: return
    var doc := _read_json(ROOT + "loot_tables.json")
    _index = doc.get("tables", {})
    _loaded = true

static func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path): return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null: return {}
    var value: Variant = JSON.parse_string(file.get_as_text())
    return value if value is Dictionary else {}

static func get_table_ids() -> Array[String]:
    load_data()
    var ids: Array[String] = []
    for key in _index.keys(): ids.append(str(key))
    ids.sort()
    return ids

static func get_table(table_id: String) -> Dictionary:
    load_data()
    var key := table_id if table_id.contains(":") else "minecraft:" + table_id
    var row: Variant = _index.get(key, {})
    if not row is Dictionary or not row.has("path"):
        return {}
    return _read_json(ROOT + "vanilla_reference/server_data/" + str(row["path"]))

static func has_imported_tables() -> bool:
    load_data()
    return not _index.is_empty()
