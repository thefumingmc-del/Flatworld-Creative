extends CharacterBody3D
class_name VoxelMob

signal died(drop_id: String, count_value: int, drop_position: Vector3)
signal exploded(explosion_position: Vector3, radius: float)

var entity_id := "pig"
var entity_name := "Pig"
var entity_kind := "passive"
var health := 10
var move_speed := 1.6
var body_color := Color(0.8, 0.6, 0.55)
var player: VoxelPlayer
var _rng := RandomNumberGenerator.new()
var _wander_direction := Vector3.ZERO
var _wander_timer := 0.0
var _attack_timer := 0.0
var _creeper_fuse := -1.0
var _dead := false
var drop_table: Array = []

func configure(data_id: String, data: Dictionary, target: VoxelPlayer, random_seed: int) -> void:
    entity_id = data_id
    entity_name = str(data.get("name", data_id.capitalize()))
    entity_kind = str(data.get("kind", "passive"))
    health = int(data.get("health", 10))
    move_speed = float(data.get("speed", 1.5))
    body_color = Color.from_string(str(data.get("color", "#aaaaaa")), Color.GRAY)
    player = target
    drop_table = data.get("drops", []) if data.get("drops", []) is Array else []
    _rng.seed = random_seed

func _ready() -> void:
    add_to_group("voxel_mob")
    collision_layer = 2
    collision_mask = 1
    var shape_node := CollisionShape3D.new()
    var capsule := CapsuleShape3D.new()
    capsule.radius = 0.17 if entity_id == "rabbit" else (0.34 if entity_id not in ["spider", "chicken"] else 0.25)
    capsule.height = 0.72 if entity_id == "rabbit" else (1.45 if entity_id not in ["spider", "chicken"] else 0.65)
    shape_node.shape = capsule
    shape_node.position.y = capsule.height * 0.5
    add_child(shape_node)
    _build_visuals()
    _wander_direction = Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized()

func _box(name_text: String, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
    var mesh_node := MeshInstance3D.new()
    mesh_node.name = name_text
    var mesh := BoxMesh.new()
    mesh.size = size
    mesh_node.mesh = mesh
    mesh_node.position = pos
    var mat := StandardMaterial3D.new()
    mat.albedo_color = color
    mat.roughness = 0.92
    mesh_node.material_override = mat
    add_child(mesh_node)
    return mesh_node

func _build_visuals() -> void:
    if entity_id == "spider":
        _box("Body", Vector3(0.76, 0.27, 0.66), Vector3(0, 0.48, 0), body_color)
        _box("Head", Vector3(0.35, 0.25, 0.32), Vector3(0, 0.51, -0.43), body_color.darkened(0.12))
        for side in [-1.0, 1.0]:
            for zpos in [-0.35, 0.0, 0.35]:
                _box("Leg", Vector3(0.12, 0.12, 0.65), Vector3(side * 0.48, 0.4, zpos), body_color.darkened(0.2))
        _box("EyeL", Vector3(0.06, 0.06, 0.025), Vector3(-0.09, 0.56, -0.60), Color(0.9, 0.15, 0.12))
        _box("EyeR", Vector3(0.06, 0.06, 0.025), Vector3(0.09, 0.56, -0.60), Color(0.9, 0.15, 0.12))
    elif entity_id == "rabbit":
        _box("Body", Vector3(0.30, 0.25, 0.42), Vector3(0, 0.28, 0), body_color)
        _box("Head", Vector3(0.23, 0.23, 0.24), Vector3(0, 0.43, -0.25), body_color.lightened(0.05))
        _box("EarL", Vector3(0.06, 0.20, 0.055), Vector3(-0.07, 0.62, -0.25), body_color)
        _box("EarR", Vector3(0.06, 0.20, 0.055), Vector3(0.07, 0.62, -0.25), body_color)
        _box("EyeL", Vector3(0.025, 0.03, 0.02), Vector3(-0.07, 0.47, -0.37), Color(0.12, 0.09, 0.07))
        _box("EyeR", Vector3(0.025, 0.03, 0.02), Vector3(0.07, 0.47, -0.37), Color(0.12, 0.09, 0.07))
        for side in [-1.0, 1.0]:
            _box("Leg", Vector3(0.08, 0.19, 0.08), Vector3(side * 0.09, 0.10, 0.12), body_color.darkened(0.08))
    elif entity_id in ["pig", "cow", "sheep", "horse", "wolf", "fox", "goat", "turtle", "donkey", "mule", "llama", "trader_llama", "mooshroom", "camel", "armadillo", "sniffer", "polar_bear", "panda"]:
        var body_size := Vector3(0.8, 0.58, 1.0)
        if entity_id == "cow": body_size = Vector3(0.95, 0.72, 1.1)
        if entity_id == "turtle": body_size = Vector3(0.85, 0.35, 0.95)
        if entity_id == "camel": body_size = Vector3(1.0, 0.75, 1.25)
        if entity_id in ["polar_bear", "panda"]: body_size = Vector3(1.05, 0.82, 1.18)
        _box("Body", body_size, Vector3(0, 0.78, 0), body_color)
        _box("Head", Vector3(0.38, 0.38, 0.42), Vector3(0, 0.94, -0.59), body_color.lightened(0.08))
        for lx in [-0.26, 0.26]:
            for lz in [-0.32, 0.32]:
                _box("Leg", Vector3(0.16, 0.48, 0.16), Vector3(lx, 0.25, lz), body_color.darkened(0.12))
        _box("EyeL", Vector3(0.045, 0.045, 0.025), Vector3(-0.1, 1.02, -0.8), Color(0.12, 0.1, 0.09))
        _box("EyeR", Vector3(0.045, 0.045, 0.025), Vector3(0.1, 1.02, -0.8), Color(0.12, 0.1, 0.09))
    elif entity_id == "chicken":
        _box("Body", Vector3(0.35, 0.45, 0.36), Vector3(0, 0.49, 0), body_color)
        _box("Head", Vector3(0.22, 0.22, 0.22), Vector3(0, 0.74, -0.21), body_color.lightened(0.04))
        _box("Beak", Vector3(0.12, 0.08, 0.12), Vector3(0, 0.70, -0.37), Color(0.87, 0.56, 0.15))
        for side in [-1.0, 1.0]: _box("Leg", Vector3(0.06, 0.22, 0.06), Vector3(side * 0.09, 0.12, 0), Color(0.8, 0.5, 0.18))
    else:
        var shirt := body_color
        if entity_id == "skeleton": shirt = Color(0.75, 0.74, 0.68)
        if entity_id == "villager": shirt = Color(0.49, 0.34, 0.23)
        if entity_id == "creeper":
            _box("Body", Vector3(0.5, 0.86, 0.36), Vector3(0, 0.92, 0), body_color)
            _box("Head", Vector3(0.46, 0.44, 0.44), Vector3(0, 1.58, -0.01), body_color.lightened(0.05))
            for lx in [-0.16, 0.16]:
                for lz in [-0.1, 0.1]: _box("Leg", Vector3(0.17, 0.45, 0.17), Vector3(lx, 0.24, lz), body_color.darkened(0.1))
            _box("EyeL", Vector3(0.1, 0.07, 0.025), Vector3(-0.1, 1.65, -0.24), Color.BLACK)
            _box("EyeR", Vector3(0.1, 0.07, 0.025), Vector3(0.1, 1.65, -0.24), Color.BLACK)
            _box("Mouth", Vector3(0.14, 0.11, 0.025), Vector3(0, 1.49, -0.24), Color.BLACK)
        else:
            _box("Body", Vector3(0.48, 0.72, 0.3), Vector3(0, 1.0, 0), shirt)
            _box("Head", Vector3(0.38, 0.38, 0.38), Vector3(0, 1.57, 0), body_color.lightened(0.08))
            _box("ArmL", Vector3(0.16, 0.62, 0.18), Vector3(-0.34, 1.0, 0), shirt.darkened(0.08))
            _box("ArmR", Vector3(0.16, 0.62, 0.18), Vector3(0.34, 1.0, 0), shirt.darkened(0.08))
            _box("LegL", Vector3(0.19, 0.62, 0.2), Vector3(-0.13, 0.31, 0), shirt.darkened(0.16))
            _box("LegR", Vector3(0.19, 0.62, 0.2), Vector3(0.13, 0.31, 0), shirt.darkened(0.16))
            _box("EyeL", Vector3(0.045, 0.04, 0.025), Vector3(-0.09, 1.61, -0.2), Color(0.1, 0.1, 0.1))
            _box("EyeR", Vector3(0.045, 0.04, 0.025), Vector3(0.09, 1.61, -0.2), Color(0.1, 0.1, 0.1))
            if entity_id == "zombie":
                _box("Nose", Vector3(0.08, 0.11, 0.08), Vector3(0, 1.53, -0.23), body_color.darkened(0.12))

func _physics_process(delta: float) -> void:
    if _dead:
        return
    _wander_timer -= delta
    _attack_timer = maxf(0.0, _attack_timer - delta)
    var toward := Vector3.ZERO
    var distance := 999.0
    var offset := Vector3.ZERO
    if is_instance_valid(player):
        offset = player.global_position - global_position
        distance = offset.length()
        # Creepers prime at close range, stop to fuse, and explode once rather
        # than using the generic hostile melee attack.
        if entity_id == "creeper":
            if distance < 3.15:
                if _creeper_fuse < 0.0:
                    _creeper_fuse = 0.0
                _creeper_fuse += delta
                if _creeper_fuse >= 1.55:
                    _explode()
                    return
                if distance > 1.65:
                    toward = Vector3(offset.x, 0, offset.z).normalized()
                else:
                    toward = Vector3.ZERO
            elif distance > 6.0:
                _creeper_fuse = -1.0
                toward = Vector3(offset.x, 0, offset.z).normalized() if distance < 14.0 else Vector3.ZERO
        elif entity_kind == "hostile" and distance < 14.0:
            if entity_id == "skeleton":
                # Skeletons prefer distance and fire visible shots from range.
                var horizontal := Vector3(offset.x, 0, offset.z).length()
                if horizontal > 8.0:
                    toward = Vector3(offset.x, 0, offset.z).normalized()
                elif horizontal < 4.5:
                    toward = -Vector3(offset.x, 0, offset.z).normalized()
                if horizontal >= 4.5 and horizontal <= 12.0 and _attack_timer <= 0.0:
                    _shoot_at_player()
                    _attack_timer = 2.0
            else:
                toward = Vector3(offset.x, 0, offset.z).normalized()
                if distance < 1.55 and _attack_timer <= 0.0:
                    player.take_damage(2 if entity_id not in ["warden", "ravager", "iron_golem"] else 5)
                    _attack_timer = 1.4
        elif entity_kind == "neutral" and distance < 6.0 and _rng.randf() < 0.01:
            toward = -Vector3(offset.x, 0, offset.z).normalized()
    if toward == Vector3.ZERO:
        if _wander_timer <= 0.0:
            _wander_timer = _rng.randf_range(1.2, 3.4)
            _wander_direction = Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized()
        if entity_id != "creeper" or _creeper_fuse < 0.0:
            toward = _wander_direction
    if not is_on_floor():
        velocity.y -= 24.0 * delta
    else:
        velocity.y = -0.35
        if entity_id in ["slime", "magma_cube", "spider"] and is_instance_valid(player) and distance < 8.0 and _rng.randf() < 0.035:
            velocity.y = 5.0 if entity_id != "magma_cube" else 4.4
    velocity.x = toward.x * move_speed
    velocity.z = toward.z * move_speed
    move_and_slide()

func _shoot_at_player() -> void:
    if not is_instance_valid(player):
        return
    # Use the physics world for line of sight so walls block skeleton attacks.
    var from := global_position + Vector3.UP * 1.15
    var to := player.global_position + Vector3.UP * 0.9
    var query := PhysicsRayQueryParameters3D.create(from, to)
    query.exclude = [get_rid()]
    query.collide_with_areas = true
    query.collide_with_bodies = true
    var hit := get_world_3d().direct_space_state.intersect_ray(query)
    if not hit.is_empty() and hit.get("collider") == player:
        player.take_damage(3)

func _explode() -> void:
    if _dead:
        return
    _dead = true
    exploded.emit(global_position, 3.0)
    queue_free()

func take_damage(amount: int) -> void:
    if _dead or amount <= 0:
        return
    health -= amount
    if health <= 0:
        _dead = true
        # Each drop is data-driven; chance and quantity are independently rolled.
        for raw_drop in drop_table:
            if not raw_drop is Dictionary:
                continue
            var chance := clampf(float(raw_drop.get("chance", 1.0)), 0.0, 1.0)
            if _rng.randf() > chance:
                continue
            var minimum := maxi(0, int(raw_drop.get("min", 1)))
            var maximum := maxi(minimum, int(raw_drop.get("max", minimum)))
            var amount_to_drop := _rng.randi_range(minimum, maximum)
            if amount_to_drop > 0:
                died.emit(str(raw_drop.get("id", "")), amount_to_drop, global_position)
        queue_free()
