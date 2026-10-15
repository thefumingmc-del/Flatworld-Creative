extends Node3D
class_name WorldItemPickup

signal collected(item_id: String, amount_collected: int)

var item_id := ""
var count := 1
var target_player: VoxelPlayer
var inventory: PlayerInventory
var _base_y := 0.0
var _elapsed := 0.0

func configure(data_id: String, amount: int, player: VoxelPlayer, player_inventory: PlayerInventory) -> void:
    item_id = data_id
    count = maxi(1, amount)
    target_player = player
    inventory = player_inventory

func _ready() -> void:
    add_to_group("world_item_pickup")
    _base_y = global_position.y
    var mesh_node := MeshInstance3D.new()
    mesh_node.name = "DroppedItemMesh"
    var item_mesh := BoxMesh.new()
    item_mesh.size = Vector3(0.22, 0.22, 0.22)
    mesh_node.mesh = item_mesh
    var material := StandardMaterial3D.new()
    var definition := BlockRegistry.get_item_runtime(item_id)
    material.albedo_color = Color.from_string(str(definition.get("color", "#d7d7d7")), Color.LIGHT_GRAY)
    material.roughness = 0.75
    mesh_node.material_override = material
    mesh_node.position.y = 0.25
    add_child(mesh_node)

func _process(delta: float) -> void:
    if count <= 0:
        queue_free()
        return
    _elapsed += delta
    rotation.y += delta * 1.8
    global_position.y = _base_y + sin(_elapsed * 3.2) * 0.07
    if not is_instance_valid(target_player) or inventory == null:
        return
    if global_position.distance_to(target_player.global_position + Vector3.UP * 0.7) > 1.45:
        return
    var accepted := inventory.add_item(item_id, count)
    if accepted <= 0:
        return
    count -= accepted
    collected.emit(item_id, accepted)
    if count <= 0:
        queue_free()

func get_save_record() -> Dictionary:
    return {
        "id": item_id,
        "count": count,
        "position": [global_position.x, global_position.y, global_position.z]
    }
