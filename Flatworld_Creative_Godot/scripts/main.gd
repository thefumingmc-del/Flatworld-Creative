extends Node3D

const WorldScript = preload("res://scripts/world.gd")
const PlayerScript = preload("res://scripts/player_controller.gd")
const HudScript = preload("res://scripts/mobile_hud.gd")
const MobScript = preload("res://scripts/mob.gd")
const InventoryScript = preload("res://scripts/player_inventory.gd")
const PickupScript = preload("res://scripts/item_pickup.gd")

var world: VoxelWorld
var player: VoxelPlayer
var hud: MobileHUD
var sun: DirectionalLight3D
var environment_node: WorldEnvironment
var sky_material: ProceduralSkyMaterial
var world_seed := 260326
var dimension_worlds: Dictionary = {}
var dimension_positions: Dictionary = {}
var _portal_cooldown := 0.0
var _contact_timer := 0.0
var tool_durability: Dictionary = {}
var _biome_timer := 0.0
# Minecraft-style day clock: 24,000 ticks per 20-minute day.
var _day_time := 0.0
var _mob_spawn_timer := 4.0
var _autosave_timer := 120.0
var _survival_accumulator := 0.0
var _regeneration_timer := 0.0
var _starvation_timer := 0.0
var _hazard_timer := 0.0
var _mining_held := false
var _mining_cell := Vector3i(2147483647, 2147483647, 2147483647)
var _mining_target_id := ""
var _mining_progress := 0.0
var _mining_mob_locked := false
var _mining_ui_timer := 0.0
var _hostile_sun_timer := 0.0
var _entity_catalogue: Dictionary = {}
var inventory: PlayerInventory
var pending_smelt: Array[Dictionary] = []
var containers: Dictionary = {}

func _ready() -> void:
    BlockRegistry.load_data()
    randomize()
    _create_environment()
    var saved := SaveManager.load_world()
    inventory = InventoryScript.new()
    if saved.get("inventory", {}) is Dictionary:
        inventory.from_dict(saved.get("inventory", {}))
    var pending_smelt_data: Variant = saved.get("pending_smelt", [])
    pending_smelt.clear()
    if pending_smelt_data is Array:
        for pending_entry in pending_smelt_data:
            if pending_entry is Dictionary:
                pending_smelt.append(pending_entry)
    containers = saved.get("containers", {}) if saved.get("containers", {}) is Dictionary else {}
    tool_durability = saved.get("tool_durability", {}) if saved.get("tool_durability", {}) is Dictionary else {}
    world_seed = int(saved.get("seed", Time.get_unix_time_from_system()))
    _day_time = fposmod(float(saved.get("day_time", 1000.0)), 24000.0)
    dimension_worlds = saved.get("dimensions", {}) if saved.get("dimensions", {}) is Dictionary else {}
    dimension_positions = saved.get("dimension_positions", {}) if saved.get("dimension_positions", {}) is Dictionary else {}
    var initial_dimension := str(saved.get("dimension", "overworld"))
    var initial_dimension_save: Dictionary = dimension_worlds.get(initial_dimension, {})
    world = WorldScript.new()
    world.name = "VoxelWorld"
    add_child(world)
    world.generate_world(world_seed, initial_dimension)
    var saved_mods: Dictionary = initial_dimension_save.get("modified", saved.get("modified", {}))
    if not saved_mods.is_empty():
        world.apply_modifications(saved_mods, initial_dimension_save.get("block_states", saved.get("block_states", {})), initial_dimension_save.get("fluid_active", saved.get("fluid_active", {})))
    player = PlayerScript.new()
    player.name = "Player"
    add_child(player)
    player.spawn_position = world.get_spawn_position()
    player.global_position = player.spawn_position
    var saved_player: Dictionary = saved.get("player", {})
    if not saved_player.is_empty():
        player.creative_mode = bool(saved_player.get("creative_mode", true))
        player.health = clampi(int(saved_player.get("health", 20)), 0, 20)
        player.hunger = clampi(int(saved_player.get("hunger", 20)), 0, 20)
        player.saturation = clampf(float(saved_player.get("saturation", 5.0)), 0.0, float(player.hunger))
        player.exhaustion = clampf(float(saved_player.get("exhaustion", 0.0)), 0.0, 40.0)
        var saved_position: Variant = saved_player.get("position", [])
        if saved_position is Array and saved_position.size() == 3:
            player.global_position = Vector3(float(saved_position[0]), float(saved_position[1]), float(saved_position[2]))
        else:
            var dp_value: Variant = dimension_positions.get(initial_dimension, [])
            if dp_value is Array and dp_value.size() == 3:
                var dp: Array = dp_value
                player.global_position = Vector3(float(dp[0]), float(dp[1]), float(dp[2]))
    world.prepare_position(player.global_position)
    player.health_changed.connect(_on_health_changed)
    player.message_requested.connect(_show_message)
    player.break_hold_changed.connect(_on_break_hold_changed)
    player.place_requested.connect(_on_place_pressed)
    player.use_requested.connect(_on_use_pressed)
    player.inventory_requested.connect(_toggle_inventory)
    player.mode_toggle_requested.connect(_toggle_mode)
    player.flight_toggle_requested.connect(player.toggle_flight)
    player.hotbar_slot_requested.connect(_select_hotbar_slot)
    _load_entity_catalogue()
    _spawn_mobs()
    hud = HudScript.new()
    hud.name = "MobileHUD"
    add_child(hud)
    hud.break_hold_changed.connect(_on_break_hold_changed)
    hud.place_pressed.connect(_on_place_pressed)
    hud.jump_pressed.connect(player.request_jump)
    hud.jump_hold_changed.connect(player.set_jump_held)
    hud.descend_pressed.connect(player.request_descend)
    hud.descend_hold_changed.connect(player.set_descend_held)
    hud.use_pressed.connect(_on_use_pressed)
    hud.save_pressed.connect(_save_world)
    hud.load_pressed.connect(_load_world)
    hud.mode_pressed.connect(_toggle_mode)
    hud.flight_pressed.connect(player.toggle_flight)
    hud.sprint_toggled.connect(_on_sprint_toggled)
    hud.selected_block.connect(_on_block_selected)
    hud.hotbar_index_changed.connect(player.set_hotbar_index)
    hud.craft_requested.connect(_on_craft_requested)
    hud.container_action.connect(_on_container_action)
    hud.joystick_changed.connect(player.set_move_input)
    hud.set_selected_block("grass_block")
    hud.set_sprint_text(player.sprint_toggled)
    hud.set_mode_text(player.creative_mode)
    hud.set_inventory_state(inventory, player.creative_mode)
    hud.set_health(player.health, player.hunger)
    hud.set_biome(world.get_biome_display(floori(player.global_position.x), floori(player.global_position.z)))
    _restore_item_pickups(saved.get("item_pickups", []))
    _update_daylight()
    if saved.is_empty():
        hud.show_message("New world · seed %d · tap to look around" % world_seed, 5.0)
    else:
        hud.show_message("Loaded saved world · seed %d" % world_seed, 5.0)

func _notification(what: int) -> void:
    # Mobile apps can be suspended or closed without the user pressing Save.
    if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
        _write_save_data(false)
        if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
            get_tree().quit()

func _create_environment() -> void:
    environment_node = WorldEnvironment.new()
    var env := Environment.new()
    env.background_mode = Environment.BG_SKY
    var sky := Sky.new()
    sky_material = ProceduralSkyMaterial.new()
    sky_material.sky_top_color = Color(0.18, 0.36, 0.72)
    sky_material.sky_horizon_color = Color(0.69, 0.79, 0.91)
    sky_material.ground_bottom_color = Color(0.17, 0.2, 0.16)
    sky_material.ground_horizon_color = Color(0.62, 0.68, 0.68)
    sky_material.sun_angle_max = 18.0
    sky.sky_material = sky_material
    env.sky = sky
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.68, 0.72, 0.79)
    env.ambient_light_energy = 0.42
    env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    env.tonemap_exposure = 1.0
    env.fog_enabled = true
    env.fog_light_color = Color(0.62, 0.73, 0.84)
    env.fog_density = 0.0012
    environment_node.environment = env
    add_child(environment_node)
    sun = DirectionalLight3D.new()
    sun.name = "Sunlight"
    sun.rotation_degrees = Vector3(-49, -34, 0)
    sun.light_energy = 1.25
    sun.shadow_enabled = true
    sun.directional_shadow_max_distance = 120.0
    add_child(sun)
    _update_daylight()

func _process(delta: float) -> void:
    if is_instance_valid(world) and is_instance_valid(player):
        _contact_timer -= delta
        if _contact_timer <= 0.0:
            _contact_timer = 0.12
            var contact_positions: Array[Vector3] = [player.global_position]
            for mob_node in get_tree().get_nodes_in_group("voxel_mob"):
                if mob_node is Node3D and mob_node.global_position.distance_to(player.global_position) <= 8.0:
                    contact_positions.append(mob_node.global_position)
            world.update_entity_contacts(contact_positions)
        _portal_cooldown = maxf(0.0, _portal_cooldown - delta)
        if _portal_cooldown <= 0.0:
            var feet := Vector3i(floori(player.global_position.x), floori(player.global_position.y), floori(player.global_position.z))
            var portal_id := world.get_block_id(feet)
            if portal_id not in ["nether_portal", "end_portal"]:
                portal_id = world.get_block_id(feet + Vector3i.UP)
            if portal_id == "nether_portal":
                _switch_dimension("nether" if world.dimension_id == "overworld" else "overworld")
            elif portal_id == "end_portal":
                _switch_dimension("end" if world.dimension_id != "end" else "overworld")
    _tick_pending_smelt(delta)
    _tick_block_mining(delta)
    _mob_spawn_timer -= delta
    if _mob_spawn_timer <= 0.0:
        _mob_spawn_timer = 4.0
        _maintain_nearby_mobs()
    _autosave_timer -= delta
    if _autosave_timer <= 0.0:
        _autosave_timer = 120.0
        _write_save_data(false)
    _biome_timer -= delta
    if _biome_timer <= 0.0 and is_instance_valid(player) and is_instance_valid(hud):
        _biome_timer = 1.25
        hud.set_biome(world.get_biome_display(floori(player.global_position.x), floori(player.global_position.z)))
    _day_time = fposmod(_day_time + delta * 20.0, 24000.0)
    _update_daylight()
    _tick_survival(delta)
    if is_instance_valid(player) and is_instance_valid(hud):
        hud.set_sprint_text(player.sprint_toggled)
    _hostile_sun_timer += delta
    if _hostile_sun_timer >= 1.0:
        _hostile_sun_timer = 0.0
        _burn_exposed_undead()
    _hazard_timer -= delta
    if _hazard_timer <= 0.0:
        _hazard_timer = 0.5
        _tick_player_hazards()

func _is_night_time() -> bool:
    return _day_time >= 13000.0 and _day_time < 23000.0

func _update_daylight() -> void:
    if not is_instance_valid(sun) or not is_instance_valid(environment_node) or environment_node.environment == null:
        return
    var phase := fposmod(_day_time, 24000.0) / 24000.0
    var daylight := maxf(0.0, sin(phase * TAU))
    if is_instance_valid(world) and world.dimension_id == "nether":
        daylight = 0.12
    elif is_instance_valid(world) and world.dimension_id == "end":
        daylight = 0.2
    # Rotate through the full day instead of oscillating between two daytime
    # angles; sun intensity, sky gradient and ambient fill track the same phase.
    sun.rotation_degrees.x = phase * 360.0 - 180.0
    sun.light_energy = 1.25 * daylight
    var env := environment_node.environment
    var in_nether := is_instance_valid(world) and world.dimension_id == "nether"
    var in_end := is_instance_valid(world) and world.dimension_id == "end"
    sun.visible = not in_nether and not in_end
    env.ambient_light_energy = 0.075 + daylight * 0.43
    env.ambient_light_color = Color(0.12, 0.15, 0.27).lerp(Color(0.68, 0.72, 0.79), daylight)
    env.fog_light_color = Color(0.055, 0.07, 0.15).lerp(Color(0.62, 0.73, 0.84), daylight)
    if in_nether:
        env.ambient_light_color = Color(0.34, 0.12, 0.075)
        env.fog_light_color = Color(0.30, 0.075, 0.035)
        env.ambient_light_energy = 0.22
    elif in_end:
        env.ambient_light_color = Color(0.20, 0.16, 0.27)
        env.fog_light_color = Color(0.12, 0.08, 0.19)
        env.ambient_light_energy = 0.16
    if sky_material != null:
        if in_nether:
            sky_material.sky_top_color = Color(0.10, 0.012, 0.008)
            sky_material.sky_horizon_color = Color(0.29, 0.055, 0.02)
            sky_material.ground_bottom_color = Color(0.09, 0.012, 0.008)
            sky_material.ground_horizon_color = Color(0.23, 0.045, 0.018)
        elif in_end:
            sky_material.sky_top_color = Color(0.008, 0.004, 0.018)
            sky_material.sky_horizon_color = Color(0.025, 0.012, 0.04)
            sky_material.ground_bottom_color = Color(0.005, 0.003, 0.01)
            sky_material.ground_horizon_color = Color(0.018, 0.01, 0.03)
        else:
            sky_material.sky_top_color = Color(0.006, 0.01, 0.035).lerp(Color(0.18, 0.36, 0.72), daylight)
            sky_material.sky_horizon_color = Color(0.035, 0.045, 0.085).lerp(Color(0.69, 0.79, 0.91), daylight)
            sky_material.ground_bottom_color = Color(0.012, 0.015, 0.025).lerp(Color(0.17, 0.2, 0.16), daylight)
            sky_material.ground_horizon_color = Color(0.045, 0.05, 0.09).lerp(Color(0.62, 0.68, 0.68), daylight)

func _tick_survival(delta: float) -> void:
    if not is_instance_valid(player) or player.creative_mode:
        _survival_accumulator = 0.0
        _regeneration_timer = 0.0
        _starvation_timer = 0.0
        return
    # A half-second simulation slice gives saturated natural regeneration its
    # faster vanilla-style cadence while keeping the main frame loop lightweight.
    _survival_accumulator += delta
    while _survival_accumulator >= 0.5:
        _survival_accumulator -= 0.5
        while player.exhaustion >= 4.0:
            player.exhaustion -= 4.0
            if player.saturation > 0.0:
                player.saturation = maxf(0.0, player.saturation - 1.0)
            elif player.hunger > 0:
                player.hunger -= 1
                player.health_changed.emit(player.health, player.hunger)
        if player.hunger >= 18 and player.health < 20:
            _regeneration_timer += 0.5
            var regen_interval := 0.5 if player.saturation > 0.0 else 4.0
            if _regeneration_timer >= regen_interval:
                player.heal(1)
                player.add_exhaustion(6.0)
                _regeneration_timer = 0.0
        else:
            _regeneration_timer = 0.0
        if player.hunger <= 0 and player.health > 1:
            _starvation_timer += 0.5
            if _starvation_timer >= 4.0:
                player.take_damage(1)
                _starvation_timer = 0.0
        else:
            _starvation_timer = 0.0

func _burn_exposed_undead() -> void:
    # The Overworld day burns exposed undead; the Nether and End have no
    # vanilla sun cycle. An upward collision ray prevents burning under roofs.
    if not is_instance_valid(world) or world.dimension_id != "overworld" or _is_night_time():
        return
    var space := get_world_3d().direct_space_state
    for node in get_tree().get_nodes_in_group("voxel_mob"):
        if not is_instance_valid(node) or not node is Node3D:
            continue
        var mob := node as Node3D
        if str(mob.get("entity_id")) not in ["zombie", "skeleton", "stray", "husk", "bogged", "zombie_villager"]:
            continue
        if mob.global_position.y < float(world.get_surface_y(floori(mob.global_position.x), floori(mob.global_position.z))) - 1.2:
            continue
        var ray_start := mob.global_position + Vector3.UP * 1.2
        var query := PhysicsRayQueryParameters3D.create(ray_start, ray_start + Vector3.UP * 16.0)
        var excluded_rids: Array[RID] = []
        if mob is CollisionObject3D:
            excluded_rids.append((mob as CollisionObject3D).get_rid())
        query.exclude = excluded_rids
        query.collide_with_bodies = true
        query.collide_with_areas = false
        if space.intersect_ray(query).is_empty() and mob.has_method("take_damage"):
            mob.call("take_damage", 1)

func _tick_player_hazards() -> void:
    if not is_instance_valid(player) or player.creative_mode or not is_instance_valid(world):
        return
    var feet := Vector3i(floori(player.global_position.x), floori(player.global_position.y), floori(player.global_position.z))
    var head := feet + Vector3i.UP
    var below_id := world.get_block_id(feet + Vector3i.DOWN)
    var feet_id := world.get_block_id(feet)
    var head_id := world.get_block_id(head)
    if feet_id == "lava" or head_id == "lava" or below_id == "lava":
        player.take_damage(4)
    elif feet_id == "fire" or head_id == "fire" or below_id in ["fire", "campfire", "soul_campfire", "magma_block"]:
        player.take_damage(1)

func _load_entity_catalogue() -> void:
    _entity_catalogue = EntityRegistry.get_runtime_behaviors()

func _spawn_mobs() -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = world_seed + 1337
    for _i in range(14):
        _spawn_one_mob_near_player(rng)

func world_radius_local() -> int:
    return 21

func _maintain_nearby_mobs() -> void:
    if not is_instance_valid(player) or not is_instance_valid(world):
        return
    var local_mobs: Array[Node] = []
    for node in get_tree().get_nodes_in_group("voxel_mob"):
        if not is_instance_valid(node):
            continue
        var mob_node := node as Node3D
        if mob_node == null:
            continue
        if mob_node.global_position.distance_to(player.global_position) > 72.0:
            mob_node.queue_free()
        else:
            local_mobs.append(mob_node)
    if local_mobs.size() >= 18:
        return
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var spawn_count := mini(2, 18 - local_mobs.size())
    for _i in range(spawn_count):
        _spawn_one_mob_near_player(rng)

func _spawn_one_mob_near_player(rng: RandomNumberGenerator) -> void:
    if not is_instance_valid(player):
        return
    var types: Array[String] = []
    if is_instance_valid(world):
        if world.dimension_id == "nether":
            types = ["piglin", "zombified_piglin", "blaze", "ghast", "magma_cube", "wither_skeleton", "hoglin", "strider"]
        elif world.dimension_id == "end":
            types = ["enderman", "shulker"]
        elif _is_night_time():
            types = ["zombie", "skeleton", "spider", "creeper", "slime"]
        else:
            types = ["pig", "cow", "sheep", "chicken", "rabbit", "fox", "villager", "wolf"]
    for attempt in range(8):
        var angle := rng.randf_range(0.0, TAU)
        var distance := rng.randf_range(13.0, 28.0)
        var x := floori(player.global_position.x + cos(angle) * distance)
        var z := floori(player.global_position.z + sin(angle) * distance)
        var biome := world.get_biome_at(x, z)
        var eligible: Array[String] = []
        for entity_id in types:
            if not _entity_catalogue.has(entity_id):
                continue
            var defn: Dictionary = _entity_catalogue[entity_id]
            var biomes: Array = defn.get("biomes", ["all"])
            if "all" in biomes or biome in biomes:
                eligible.append(entity_id)
        if eligible.is_empty():
            continue
        var ground_y := world.get_surface_y(x, z)
        if ground_y < -48 or ground_y > 318:
            continue
        var floor_id := world.get_block_id(Vector3i(x, ground_y - 1, z))
        var feet_id := world.get_block_id(Vector3i(x, ground_y, z))
        var head_id := world.get_block_id(Vector3i(x, ground_y + 1, z))
        if not BlockRegistry.is_solid(floor_id) or feet_id != "air" or head_id != "air":
            continue
        var entity_id := eligible[rng.randi_range(0, eligible.size() - 1)]
        var mob := MobScript.new()
        mob.configure(entity_id, _entity_catalogue[entity_id], player, rng.randi())
        mob.died.connect(_on_mob_died)
        mob.exploded.connect(_on_mob_exploded)
        add_child(mob)
        mob.global_position = Vector3(float(x) + 0.5, float(ground_y) + 0.08, float(z) + 0.5)
        return

func _raycast_target() -> Dictionary:
    if not is_instance_valid(player) or not is_instance_valid(player.camera):
        return {}
    var origin := player.camera.global_position
    var end := origin + (-player.camera.global_transform.basis.z) * 6.5
    var query := PhysicsRayQueryParameters3D.create(origin, end)
    query.exclude = [player.get_rid()]
    query.collide_with_areas = true
    query.collide_with_bodies = true
    return get_world_3d().direct_space_state.intersect_ray(query)

func _raycast_voxel_cell(max_distance: float = 6.5) -> Dictionary:
    # 3D DDA traverses voxel cells, so crossed-quad plants can be targeted even
    # though they deliberately have no player-blocking collision shape.
    if not is_instance_valid(player) or not is_instance_valid(player.camera):
        return {}
    var origin: Vector3 = player.camera.global_position
    var direction: Vector3 = (-player.camera.global_transform.basis.z).normalized()
    var cell := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
    var step_x := 1 if direction.x > 0.0 else (-1 if direction.x < 0.0 else 0)
    var step_y := 1 if direction.y > 0.0 else (-1 if direction.y < 0.0 else 0)
    var step_z := 1 if direction.z > 0.0 else (-1 if direction.z < 0.0 else 0)
    var delta_x := absf(1.0 / direction.x) if step_x != 0 else 1.0e20
    var delta_y := absf(1.0 / direction.y) if step_y != 0 else 1.0e20
    var delta_z := absf(1.0 / direction.z) if step_z != 0 else 1.0e20
    var max_x := (float(cell.x + 1) - origin.x) / direction.x if step_x > 0 else ((origin.x - float(cell.x)) / absf(direction.x) if step_x < 0 else 1.0e20)
    var max_y := (float(cell.y + 1) - origin.y) / direction.y if step_y > 0 else ((origin.y - float(cell.y)) / absf(direction.y) if step_y < 0 else 1.0e20)
    var max_z := (float(cell.z + 1) - origin.z) / direction.z if step_z > 0 else ((origin.z - float(cell.z)) / absf(direction.z) if step_z < 0 else 1.0e20)
    var distance := 0.0
    var normal := Vector3i.ZERO
    for _iteration in range(192):
        var block_id := world.get_block_id(cell)
        if block_id != "air":
            return {"cell": cell, "normal": normal, "distance": distance, "block_id": block_id}
        if max_x < max_y and max_x < max_z:
            distance = max_x
            max_x += delta_x
            cell += Vector3i(step_x, 0, 0)
            normal = Vector3i(-step_x, 0, 0)
        elif max_y < max_z:
            distance = max_y
            max_y += delta_y
            cell += Vector3i(0, step_y, 0)
            normal = Vector3i(0, -step_y, 0)
        else:
            distance = max_z
            max_z += delta_z
            cell += Vector3i(0, 0, step_z)
            normal = Vector3i(0, 0, -step_z)
        if distance > max_distance:
            return {}
    return {}

func _on_sprint_toggled(enabled: bool) -> void:
    if is_instance_valid(player):
        player.set_sprinting(enabled)
        if is_instance_valid(hud):
            hud.set_sprint_text(player.sprint_toggled)

func _on_break_hold_changed(holding: bool) -> void:
    _mining_held = holding
    if not holding:
        _mining_progress = 0.0
        _mining_target_id = ""
        _mining_cell = Vector3i(2147483647, 2147483647, 2147483647)
        _mining_mob_locked = false
        if is_instance_valid(hud):
            hud.set_mining_progress(0.0, "", false)
        return
    _mining_progress = 0.0
    _mining_target_id = ""
    _mining_cell = Vector3i(2147483647, 2147483647, 2147483647)
    _mining_mob_locked = false

func _is_mob_target_in_front() -> bool:
    var target := _raycast_target()
    if target.is_empty():
        return false
    var collider: Object = target.get("collider")
    if not collider is Node or not collider.is_in_group("voxel_mob"):
        return false
    var hit_position: Vector3 = target.get("position", Vector3.ZERO)
    var mob_distance := player.camera.global_position.distance_to(hit_position)
    var block_hit := _raycast_voxel_cell()
    var block_distance := float(block_hit.get("distance", 999.0))
    return mob_distance <= block_distance

func _tick_block_mining(delta: float) -> void:
    if not _mining_held or not is_instance_valid(player) or not is_instance_valid(world) or not is_instance_valid(hud):
        return
    if _is_mob_target_in_front():
        if not _mining_mob_locked:
            _on_break_pressed()
            _mining_mob_locked = true
        return
    _mining_mob_locked = false
    var hit := _raycast_voxel_cell()
    if hit.is_empty():
        _mining_cell = Vector3i(2147483647, 2147483647, 2147483647)
        _mining_target_id = ""
        _mining_progress = 0.0
        hud.set_mining_progress(0.0, "", false)
        return
    var cell: Vector3i = hit["cell"]
    var block_id := str(world.get_block_id(cell))
    if block_id in ["air", "bedrock"] or cell.y <= VoxelWorld.MIN_WORLD_Y:
        _mining_progress = 0.0
        _mining_target_id = block_id
        _mining_cell = cell
        hud.set_mining_progress(0.0, BlockRegistry.get_name(block_id), false)
        return
    if cell != _mining_cell or block_id != _mining_target_id:
        _mining_cell = cell
        _mining_target_id = block_id
        _mining_progress = 0.0
        if player.creative_mode:
            _on_break_pressed()
            _mining_cell = Vector3i(2147483647, 2147483647, 2147483647)
            hud.set_mining_progress(0.0, "", false)
            return
    if player.creative_mode:
        return
    var definition := BlockRegistry.get_block(block_id)
    var hardness := float(definition.get("hardness", 1.5))
    if hardness < 0.0 or hardness >= 999.0:
        hud.set_mining_progress(0.0, BlockRegistry.get_name(block_id), false)
        return
    if hardness <= 0.0:
        _mining_progress = 1.0
    else:
        var selected_tool := hud.chosen_block
        var harvestable := _can_harvest_block(block_id, selected_tool)
        var speed := _block_mining_speed(block_id, selected_tool)
        var divisor := 30.0 if harvestable else 100.0
        var seconds_to_break := maxf(0.05, hardness * divisor / (20.0 * speed))
        _mining_progress = minf(1.0, _mining_progress + delta / seconds_to_break)
    hud.set_mining_progress(_mining_progress, BlockRegistry.get_name(block_id), true)
    if _mining_progress >= 1.0:
        _on_break_pressed()
        _mining_progress = 0.0
        _mining_target_id = ""
        _mining_cell = Vector3i(2147483647, 2147483647, 2147483647)
        hud.set_mining_progress(0.0, "", false)

func _block_mining_speed(block_id: String, tool_id: String) -> float:
    var correct_tool := _is_correct_tool_for_block(block_id, tool_id)
    if not correct_tool:
        return 1.0
    if tool_id.begins_with("wooden_"):
        return 2.0
    if tool_id.begins_with("stone_"):
        return 4.0
    if tool_id.begins_with("iron_"):
        return 6.0
    if tool_id.begins_with("diamond_"):
        return 8.0
    if tool_id.begins_with("netherite_"):
        return 9.0
    if tool_id.begins_with("golden_"):
        return 12.0
    if tool_id == "shears":
        return 5.0
    return 1.0

func _is_correct_tool_for_block(block_id: String, tool_id: String) -> bool:
    if _required_pickaxe_tier(block_id) >= 0:
        return _selected_pickaxe_tier(tool_id) >= _required_pickaxe_tier(block_id)
    if block_id.contains("log") or block_id.ends_with("_wood") or block_id.ends_with("_planks") or "fence" in block_id or "door" in block_id or "trapdoor" in block_id:
        return tool_id.ends_with("_axe")
    if block_id in ["dirt", "grass_block", "coarse_dirt", "rooted_dirt", "mud", "sand", "red_sand", "gravel", "clay", "farmland", "dirt_path", "snow_block", "snow"]:
        return tool_id.ends_with("_shovel")
    if "leaves" in block_id or block_id == "cobweb" or block_id.begins_with("wool_"):
        return tool_id == "shears" or tool_id.ends_with("_sword")
    return false

func _on_break_pressed() -> void:
    var block_hit := _raycast_voxel_cell()
    var target := _raycast_target()
    if not target.is_empty():
        var collider: Object = target.get("collider")
        var hit_position: Vector3 = target.get("position", Vector3.ZERO)
        var mob_distance := player.camera.global_position.distance_to(hit_position)
        var block_distance := float(block_hit.get("distance", 999.0))
        if collider is Node and collider.is_in_group("voxel_mob") and mob_distance <= block_distance:
            var weapon_id := hud.chosen_block
            var damage := _melee_damage_for(weapon_id)
            if collider.has_method("take_damage"):
                collider.call("take_damage", damage)
            if not player.creative_mode and _is_durable_tool(weapon_id) and inventory.has_item(weapon_id, 1):
                _damage_tool(weapon_id, 1)
                hud.refresh_inventory()
            hud.show_message("Hit %s for %d damage" % [str(collider.get("entity_name")), damage])
            return
    if block_hit.is_empty():
        return
    var cell: Vector3i = block_hit["cell"]
    var target_block := world.get_block_id(cell)
    var selected_tool := hud.chosen_block
    var block_state_before := world.get_block_state(cell)
    var can_harvest := player.creative_mode or _can_harvest_block(target_block, selected_tool)
    var broken := world.break_block(cell)
    if not broken.is_empty():
        if not player.creative_mode:
            var drop := _block_drop_for(broken, block_state_before) if can_harvest else ""
            if not drop.is_empty():
                var drop_amount := _block_drop_count(broken, block_state_before)
                if drop_amount > 0:
                    var accepted := inventory.add_item(drop, drop_amount)
                    if accepted > 0:
                        hud.refresh_inventory()
                    if accepted < drop_amount:
                        _spawn_item_pickup(drop, drop_amount - accepted, Vector3(cell.x + 0.5, cell.y + 0.55, cell.z + 0.5))
            if broken == "wheat" and int(block_state_before.get("age", 0)) >= 7:
                _give_item_or_spawn("wheat_seeds", randi_range(1, 3), Vector3(cell.x + 0.5, cell.y + 0.55, cell.z + 0.5))
            elif broken == "beetroots" and int(block_state_before.get("age", 0)) >= 3:
                _give_item_or_spawn("beetroot_seeds", randi_range(1, 3), Vector3(cell.x + 0.5, cell.y + 0.55, cell.z + 0.5))
            if _should_damage_selected_tool(broken, selected_tool) and inventory.has_item(selected_tool, 1):
                _damage_tool(selected_tool, 1)
                hud.refresh_inventory()
            if not can_harvest:
                hud.show_message("Broke %s — requires a suitable pickaxe for drops" % BlockRegistry.get_name(broken), 2.0)
                return
        hud.show_message("Broke " + BlockRegistry.get_name(broken), 1.5)

func _on_place_pressed() -> void:
    var selected_item := hud.chosen_block
    if selected_item in ["water_bucket", "lava_bucket"]:
        _place_bucket_fluid(selected_item)
        return
    # Inventory IDs and world block IDs are different registries. Resolve only
    # explicit supported item->block mappings; never infer from equal names.
    var place_block_id := BlockRegistry.get_place_block_id(selected_item)
    if place_block_id.is_empty() or not BlockRegistry.is_placeable(place_block_id):
        hud.show_message("Selected item cannot be placed as a block")
        return
    var target := _raycast_voxel_cell()
    if target.is_empty():
        return
    var target_cell: Vector3i = target["cell"]
    var face_normal: Vector3i = target["normal"]
    if face_normal == Vector3i.ZERO:
        hud.show_message("Aim at a block face to place adjacent to it")
        return
    var cell := target_cell + face_normal
    var ray_direction: Vector3 = (-player.camera.global_transform.basis.z).normalized()
    var hit_position: Vector3 = player.camera.global_position + ray_direction * float(target.get("distance", 0.0))
    var hit_height_fraction := clampf(hit_position.y - float(target_cell.y), 0.0, 1.0)
    var player_cell := Vector3i(floori(player.global_position.x), floori(player.global_position.y), floori(player.global_position.z))
    if cell == player_cell or cell == player_cell + Vector3i.UP:
        hud.show_message("You cannot place a block inside yourself", 1.5)
        return
    if not player.creative_mode and not inventory.has_item(selected_item, 1):
        hud.show_message("You need this item in your inventory", 1.5)
        return
    var placement_state: Dictionary = {}
    var forward: Vector3 = -player.global_transform.basis.z
    if absf(forward.x) > absf(forward.z):
        placement_state["facing"] = "east" if forward.x > 0.0 else "west"
    else:
        placement_state["facing"] = "south" if forward.z > 0.0 else "north"
    if place_block_id.ends_with("_slab"):
        if face_normal.y > 0:
            placement_state["half"] = "bottom"
        elif face_normal.y < 0:
            placement_state["half"] = "top"
        else:
            placement_state["half"] = "top" if hit_height_fraction > 0.5 else "bottom"
    elif place_block_id.ends_with("_stairs"):
        # Side-face placement uses the hit height; top/bottom faces map to the
        # expected normal stair orientation.
        var upside_down := face_normal.y < 0 or (face_normal.y == 0 and hit_height_fraction > 0.5)
        placement_state["half"] = "top" if upside_down else "bottom"
    if world.place_block(cell, place_block_id, placement_state):
        if not player.creative_mode:
            inventory.remove_item(selected_item, 1)
            hud.refresh_inventory()
        hud.show_message("Placed " + BlockRegistry.get_name(place_block_id), 1.2)

func _replace_world_block(cell: Vector3i, replacement_id: String) -> bool:
    var old_id := world.get_block_id(cell)
    if old_id == "air":
        return false
    if world.break_block(cell).is_empty():
        return false
    return world.place_block(cell, replacement_id)

func _place_bucket_fluid(bucket_id: String) -> void:
    if not player.creative_mode and not inventory.has_item(bucket_id, 1):
        hud.show_message("You do not have that filled bucket")
        return
    var target := _raycast_voxel_cell()
    if target.is_empty():
        hud.show_message("Aim at a block face to pour the fluid")
        return
    var target_cell: Vector3i = target["cell"]
    var normal: Vector3i = target["normal"]
    if normal == Vector3i.ZERO:
        return
    var destination := target_cell + normal
    var existing := world.get_block_id(destination)
    if existing not in ["air", "short_grass", "tall_grass", "red_shrub", "water", "lava"]:
        hud.show_message("There is no space for the fluid")
        return
    var fluid_id := "water" if bucket_id == "water_bucket" else "lava"
    if not world.place_block(destination, fluid_id, {"level": 0, "source": true, "falling": false}):
        hud.show_message("Could not place the fluid here")
        return
    world.set_block_state(destination, {"level": 0, "source": true, "falling": false})
    if not player.creative_mode:
        inventory.remove_item(bucket_id, 1)
        inventory.add_item("bucket", 1)
        hud.refresh_inventory()
        hud.set_selected_block("bucket")
    hud.show_message("Poured " + fluid_id)

func _on_use_pressed() -> void:
    var selected_item := hud.chosen_block
    var target := _raycast_voxel_cell()
    if target.is_empty():
        if _use_selected_food(selected_item):
            return
        hud.show_message("Look at a target block to use it")
        return
    var cell: Vector3i = target["cell"]
    var id := world.get_block_id(cell)
    if selected_item == "bucket" and id in ["water", "lava"]:
        var fluid_state := world.get_block_state(cell)
        var fluid_level := int(fluid_state.get("level", 0))
        var fluid_source := bool(fluid_state.get("source", fluid_level == 0))
        if fluid_source and fluid_level == 0:
            world.break_block(cell)
            if not player.creative_mode:
                inventory.remove_item("bucket", 1)
                var filled_bucket := "water_bucket" if id == "water" else "lava_bucket"
                inventory.add_item(filled_bucket, 1)
                hud.refresh_inventory()
                hud.set_selected_block(filled_bucket)
            hud.show_message("Collected a source of " + id)
        else:
            hud.show_message("A bucket can only collect a source block")
        return
    if selected_item.ends_with("_hoe") and id in ["grass_block", "dirt", "coarse_dirt", "rooted_dirt"]:
        if not player.creative_mode and not inventory.has_item(selected_item, 1):
            hud.show_message("You need that hoe in your inventory")
            return
        if world.get_block_id(cell + Vector3i.UP) != "air":
            hud.show_message("Clear the space above the soil before tilling")
            return
        if _replace_world_block(cell, "farmland"):
            if not player.creative_mode:
                _damage_tool(selected_item, 1)
                hud.refresh_inventory()
            hud.show_message("Tilled soil")
        return
    if selected_item.ends_with("_shovel") and id in ["grass_block", "dirt", "coarse_dirt"]:
        if not player.creative_mode and not inventory.has_item(selected_item, 1):
            hud.show_message("You need that shovel in your inventory")
            return
        if world.get_block_id(cell + Vector3i.UP) != "air":
            hud.show_message("Clear the space above the block before making a path")
            return
        if _replace_world_block(cell, "dirt_path"):
            if not player.creative_mode:
                _damage_tool(selected_item, 1)
                hud.refresh_inventory()
            hud.show_message("Made a dirt path")
        return
    var seed_to_crop := {"wheat_seeds":"wheat", "carrot":"carrots", "potato":"potatoes", "beetroot_seeds":"beetroots"}
    if seed_to_crop.has(selected_item) and id == "farmland":
        if not player.creative_mode and not inventory.has_item(selected_item, 1):
            hud.show_message("You need seeds or produce in your inventory")
            return
        var crop_cell := cell + Vector3i.UP
        if world.get_block_id(crop_cell) != "air":
            hud.show_message("There is no room to plant here")
            return
        if world.place_block(crop_cell, str(seed_to_crop[selected_item])):
            if not player.creative_mode:
                inventory.remove_item(selected_item, 1)
                hud.refresh_inventory()
            hud.show_message("Planted " + BlockRegistry.get_name(str(seed_to_crop[selected_item])))
        return
    if not player.creative_mode and selected_item in ["flint_and_steel", "ender_eye"] and not inventory.has_item(selected_item, 1):
        hud.show_message("You need " + BlockRegistry.get_item_name(selected_item) + " in your inventory")
        return
    if selected_item == "flint_and_steel" and id == "obsidian":
        if world.activate_nether_portal(cell):
            if not player.creative_mode:
                _damage_tool(selected_item, 1)
                hud.refresh_inventory()
            hud.show_message("Nether portal activated")
        else:
            hud.show_message("Frame incomplete: make an obsidian rectangle 4×5 or larger")
        return
    if selected_item == "ender_eye" and id == "end_portal_frame":
        if world.use_end_portal_frame(cell):
            if not player.creative_mode:
                inventory.remove_item("ender_eye", 1)
                hud.refresh_inventory()
            hud.show_message("Eye of Ender placed")
        return
    if id in ["lever", "stone_button", "poplar_button", "oak_door", "poplar_door", "oak_trapdoor", "poplar_trapdoor", "oak_fence_gate", "poplar_fence_gate", "tripwire_hook"]:
        if world.toggle_block(cell):
            hud.show_message("Switched " + BlockRegistry.get_name(id))
            return
    if selected_item == "bone_meal":
        if not player.creative_mode and not inventory.has_item("bone_meal", 1):
            hud.show_message("You need bone meal in your inventory")
            return
        match id:
            "wheat", "carrots", "potatoes", "beetroots":
                var crop_state := world.get_block_state(cell)
                crop_state["age"] = mini(7, int(crop_state.get("age", 0)) + randi_range(2, 4))
                world.set_block_state(cell, crop_state)
                if not player.creative_mode:
                    inventory.remove_item("bone_meal", 1)
                    hud.refresh_inventory()
                hud.show_message("Crop growth accelerated")
                return
            "shelf_mushroom":
                if world.break_block(cell) != "":
                    world.place_block(cell, "shelf_mushroom")
                    hud.show_message("The shelf mushroom grew")
                return
            "red_shrub":
                var rng := RandomNumberGenerator.new()
                rng.randomize()
                var candidates: Array[Vector3i] = [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK, Vector3i(1,0,1), Vector3i(-1,0,-1)]
                for _attempt in range(candidates.size()):
                    var candidate := cell + candidates[rng.randi_range(0, candidates.size() - 1)]
                    if world.get_block_id(candidate) == "air" and world.place_block(candidate, "red_shrub"):
                        hud.show_message("Bone meal grew a nearby red shrub")
                        return
                hud.show_message("There is no space for a new red shrub")
                return
            "poplar_sapling":
                hud.show_message("Poplar grew" if world.grow_poplar_sapling(cell) else "Poplar sapling could not grow")
                return
        hud.show_message("Bone meal has no effect on " + BlockRegistry.get_name(id))
        return
    match id:
        "crafting_table":
            hud.show_station("crafting_table")
        "furnace":
            hud.show_station("furnace")
        "chest", "barrel", "shulker_box":
            var key := _cell_key(cell)
            if not containers.has(key):
                containers[key] = {}
            hud.show_container(key, _container_summary(key))
        "campfire":
            hud.show_station("campfire")
        "oak_door", "poplar_door", "iron_door", "oak_trapdoor", "poplar_trapdoor", "iron_trapdoor", "oak_fence_gate", "poplar_fence_gate":
            if world.toggle_block(cell):
                hud.show_message("Opened/closed " + BlockRegistry.get_name(id))
        "straw_bed":
            if world.dimension_id != "overworld":
                hud.show_message("You can only sleep in a bed in the Overworld")
                return
            var danger_nearby := false
            for mob_node in get_tree().get_nodes_in_group("voxel_mob"):
                if is_instance_valid(mob_node) and mob_node.get("entity_kind") == "hostile" and mob_node.global_position.distance_to(player.global_position) < 8.0:
                    danger_nearby = true
                    break
            if danger_nearby:
                hud.show_message("You cannot sleep while hostile mobs are nearby")
                return
            player.spawn_position = Vector3(cell.x + 0.5, cell.y + 1.05, cell.z + 0.5)
            _day_time = 1000.0
            _update_daylight()
            hud.show_message("Respawn point set; you slept until morning")
        "shelf_mushroom":
            player.velocity.y = maxf(player.velocity.y, 5.0)
            hud.show_message("Bounced on shelf mushroom")
        "wheat", "carrots", "potatoes", "beetroots":
            if _use_selected_food(selected_item):
                return
            hud.show_message("Crop growth: %d/7" % int(world.get_block_state(cell).get("age", 0)))
        _:
            if _use_selected_food(selected_item):
                return
            hud.show_message("Used " + BlockRegistry.get_name(id))

func _use_selected_food(item_id: String) -> bool:
    var hunger_points := 0
    var saturation_modifier := 0.6
    match item_id:
        "bread": hunger_points = 5; saturation_modifier = 0.6
        "apple": hunger_points = 4; saturation_modifier = 0.3
        "cooked_beef": hunger_points = 8; saturation_modifier = 0.8
        "carrot": hunger_points = 3; saturation_modifier = 0.6
        "potato": hunger_points = 1; saturation_modifier = 0.3
        "baked_potato": hunger_points = 5; saturation_modifier = 0.6
        "cooked_porkchop": hunger_points = 8; saturation_modifier = 0.8
        "cooked_mutton": hunger_points = 6; saturation_modifier = 0.8
        "cooked_chicken": hunger_points = 6; saturation_modifier = 0.6
        "cooked_rabbit": hunger_points = 5; saturation_modifier = 0.6
        "cooked_cod": hunger_points = 5; saturation_modifier = 0.6
        "cooked_salmon": hunger_points = 6; saturation_modifier = 0.8
        "golden_carrot": hunger_points = 6; saturation_modifier = 1.2
        "mushroom_stew": hunger_points = 6; saturation_modifier = 0.6
        "suspicious_stew": hunger_points = 6; saturation_modifier = 0.6
        "pumpkin_pie": hunger_points = 8; saturation_modifier = 0.3
        "melon_slice": hunger_points = 2; saturation_modifier = 0.3
        "sweet_berries": hunger_points = 2; saturation_modifier = 0.1
        "glow_berries": hunger_points = 2; saturation_modifier = 0.1
        _:
            return false
    if not player.creative_mode and not inventory.has_item(item_id, 1):
        hud.show_message("You do not have that food item")
        return true
    if player.eat_food(hunger_points, saturation_modifier):
        if not player.creative_mode:
            inventory.remove_item(item_id, 1)
            hud.refresh_inventory()
        hud.show_message("Ate " + BlockRegistry.get_item_name(item_id))
    return true

func _on_block_selected(block_id: String) -> void:
    if BlockRegistry.has_block(block_id):
        hud.set_selected_block(block_id)

func _toggle_inventory() -> void:
    if is_instance_valid(hud):
        hud.toggle_inventory_from_input()

func _select_hotbar_slot(index: int) -> void:
    if is_instance_valid(hud):
        hud.select_hotbar_index(index)

func _toggle_mode() -> void:
    player.set_creative_mode(not player.creative_mode)
    hud.set_mode_text(player.creative_mode)
    hud.set_inventory_state(inventory, player.creative_mode)
    if player.creative_mode:
        player.health = 20
        player.hunger = 20
        player.saturation = 20.0
        player.exhaustion = 0.0
        hud.set_health(player.health, player.hunger)

func _on_health_changed(health: int, hunger: int) -> void:
    if is_instance_valid(hud):
        hud.set_health(health, hunger)

func _show_message(message: String) -> void:
    if is_instance_valid(hud):
        hud.show_message(message)

func _save_world() -> void:
    var saved_ok := _write_save_data(false)
    if is_instance_valid(hud):
        hud.show_message("World saved to this device" if saved_ok else "Save failed")

func _write_save_data(show_feedback: bool = false) -> bool:
    if not is_instance_valid(world) or not is_instance_valid(player) or inventory == null:
        return false
    var save_data := world.get_save_data()
    save_data["dimension"] = world.dimension_id
    save_data["day_time"] = _day_time
    dimension_worlds[world.dimension_id] = save_data.duplicate(true)
    dimension_positions[world.dimension_id] = [player.global_position.x, player.global_position.y, player.global_position.z]
    save_data["dimensions"] = dimension_worlds.duplicate(true)
    save_data["dimension_positions"] = dimension_positions.duplicate(true)
    save_data["inventory"] = inventory.to_dict()
    save_data["pending_smelt"] = pending_smelt.duplicate(true)
    save_data["containers"] = containers.duplicate(true)
    save_data["tool_durability"] = tool_durability.duplicate(true)
    save_data["item_pickups"] = _collect_item_pickup_records()
    save_data["player"] = {
        "creative_mode": player.creative_mode,
        "health": player.health,
        "hunger": player.hunger,
        "saturation": player.saturation,
        "exhaustion": player.exhaustion,
        "position": [player.global_position.x, player.global_position.y, player.global_position.z]
    }
    var saved_ok := SaveManager.save_world(save_data)
    if show_feedback and is_instance_valid(hud):
        hud.show_message("World saved to this device" if saved_ok else "Save failed")
    return saved_ok

func _load_world() -> void:
    var saved := SaveManager.load_world()
    if saved.is_empty():
        hud.show_message("No save exists on this device")
        return
    world_seed = int(saved.get("seed", world_seed))
    _day_time = fposmod(float(saved.get("day_time", 1000.0)), 24000.0)
    dimension_worlds = saved.get("dimensions", {}) if saved.get("dimensions", {}) is Dictionary else {}
    dimension_positions = saved.get("dimension_positions", {}) if saved.get("dimension_positions", {}) is Dictionary else {}
    var dimension := str(saved.get("dimension", "overworld"))
    var dimension_save: Dictionary = dimension_worlds.get(dimension, saved)
    world.generate_world(world_seed, dimension)
    world.apply_modifications(dimension_save.get("modified", saved.get("modified", {})), dimension_save.get("block_states", saved.get("block_states", {})), dimension_save.get("fluid_active", saved.get("fluid_active", {})))
    inventory.from_dict(saved.get("inventory", {}))
    pending_smelt = saved.get("pending_smelt", []) if saved.get("pending_smelt", []) is Array else []
    containers = saved.get("containers", {}) if saved.get("containers", {}) is Dictionary else {}
    tool_durability = saved.get("tool_durability", {}) if saved.get("tool_durability", {}) is Dictionary else {}
    player.spawn_position = world.get_spawn_position()
    var saved_player: Dictionary = saved.get("player", {})
    if not saved_player.is_empty():
        player.creative_mode = bool(saved_player.get("creative_mode", player.creative_mode))
        player.health = clampi(int(saved_player.get("health", player.health)), 0, 20)
        player.hunger = clampi(int(saved_player.get("hunger", player.hunger)), 0, 20)
        player.saturation = clampf(float(saved_player.get("saturation", player.saturation)), 0.0, float(player.hunger))
        player.exhaustion = clampf(float(saved_player.get("exhaustion", player.exhaustion)), 0.0, 40.0)
        var saved_position: Variant = saved_player.get("position", [])
        if saved_position is Array and saved_position.size() == 3:
            player.global_position = Vector3(float(saved_position[0]), float(saved_position[1]), float(saved_position[2]))
        else:
            player.global_position = player.spawn_position
    else:
        var dimension_position: Variant = dimension_positions.get(dimension, [])
        player.global_position = Vector3(float(dimension_position[0]), float(dimension_position[1]), float(dimension_position[2])) if dimension_position is Array and dimension_position.size() == 3 else player.spawn_position
    world.prepare_position(player.global_position)
    player.velocity = Vector3.ZERO
    _clear_item_pickups()
    _restore_item_pickups(saved.get("item_pickups", []))
    hud.set_mode_text(player.creative_mode)
    hud.set_inventory_state(inventory, player.creative_mode)
    hud.set_health(player.health, player.hunger)
    _update_daylight()
    hud.show_message("Saved world loaded")


func _cell_key(cell: Vector3i) -> String:
    return "%d,%d,%d" % [cell.x, cell.y, cell.z]

func _container_summary(cell_key: String) -> String:
    var contents: Dictionary = containers.get(cell_key, {})
    if contents.is_empty():
        return "Container is empty."
    var lines: Array[String] = []
    for item_id in contents.keys():
        lines.append("%s ×%d" % [BlockRegistry.get_item_name(str(item_id)), int(contents[item_id])])
    lines.sort()
    return "Stored items (%d/27 item types):\n%s" % [contents.size(), "\n".join(lines)]

func _on_container_action(action: String, cell_key: String) -> void:
    var selected := hud.chosen_block
    if selected.is_empty() or not BlockRegistry.has_block(selected):
        hud.show_message("Select an item first")
        return
    var contents: Dictionary = containers.get(cell_key, {})
    var stack_limit := inventory._max_stack(selected)
    var current := int(contents.get(selected, 0))
    if action == "deposit":
        var capacity := maxi(0, stack_limit - current)
        if not contents.has(selected) and contents.size() < 27:
            capacity = stack_limit
        elif not contents.has(selected):
            capacity = 0
        var move_count := mini(inventory.count(selected), capacity)
        if move_count <= 0:
            hud.show_message("Container stack is full or all 27 item slots are used")
            return
        if inventory.remove_item(selected, move_count):
            contents[selected] = current + move_count
            containers[cell_key] = contents
            world.notify_container_contents_changed(world._cell_from_key(cell_key))
            hud.refresh_inventory()
            hud.show_message("Stored %s ×%d" % [BlockRegistry.get_item_name(selected), move_count])
    elif action == "withdraw":
        if current <= 0:
            hud.show_message("That item is not stored here")
            return
        var wanted := mini(current, stack_limit)
        var accepted := inventory.add_item(selected, wanted)
        if accepted <= 0:
            hud.show_message("Your inventory is full")
            return
        current -= accepted
        if current <= 0:
            contents.erase(selected)
        else:
            contents[selected] = current
        containers[cell_key] = contents
        world.notify_container_contents_changed(world._cell_from_key(cell_key))
        hud.refresh_inventory()
        hud.show_message("Withdrew %s ×%d" % [BlockRegistry.get_item_name(selected), accepted])
    hud.show_container(cell_key, _container_summary(cell_key))

func _is_durable_tool(item_id: String) -> bool:
    return item_id.ends_with("_pickaxe") or item_id.ends_with("_axe") or item_id.ends_with("_sword") or item_id.ends_with("_shovel") or item_id.ends_with("_hoe") or item_id in ["flint_and_steel", "shears", "fishing_rod", "bow", "crossbow", "shield"]

func _max_tool_durability(item_id: String) -> int:
    if item_id.begins_with("wooden_"): return 59 if not item_id.ends_with("_sword") else 59
    if item_id.begins_with("stone_"): return 131
    if item_id.begins_with("iron_"): return 250
    if item_id.begins_with("golden_"): return 32
    if item_id.begins_with("diamond_"): return 1561
    if item_id.begins_with("netherite_"): return 2031
    if item_id == "flint_and_steel": return 64
    if item_id == "bow": return 384
    if item_id == "fishing_rod": return 64
    if item_id == "shield": return 336
    if item_id == "shears": return 238
    return 64

func _damage_tool(item_id: String, amount: int = 1) -> void:
    var maximum := _max_tool_durability(item_id)
    var current := int(tool_durability.get(item_id, maximum)) - amount
    if current <= 0:
        tool_durability.erase(item_id)
        inventory.remove_item(item_id, 1)
        hud.show_message(item_id.replace("_", " ").capitalize() + " broke")
    else:
        tool_durability[item_id] = current
        hud.show_message("Tool durability: %d/%d" % [current, maximum], 1.0)

func _melee_damage_for(item_id: String) -> int:
    if item_id.ends_with("_sword"):
        if item_id.begins_with("wooden_") or item_id.begins_with("golden_"): return 4
        if item_id.begins_with("stone_"): return 5
        if item_id.begins_with("iron_"): return 6
        if item_id.begins_with("diamond_"): return 7
        if item_id.begins_with("netherite_"): return 8
    if item_id.ends_with("_axe"):
        if item_id.begins_with("wooden_") or item_id.begins_with("golden_"): return 3
        if item_id.begins_with("stone_"): return 4
        if item_id.begins_with("iron_"): return 5
        if item_id.begins_with("diamond_"): return 6
        if item_id.begins_with("netherite_"): return 7
    return 1

func _selected_pickaxe_tier(item_id: String) -> int:
    if not item_id.ends_with("_pickaxe"):
        return -1
    if item_id.begins_with("wooden_") or item_id.begins_with("golden_"): return 0
    if item_id.begins_with("stone_"): return 1
    if item_id.begins_with("iron_"): return 2
    if item_id.begins_with("diamond_"): return 3
    if item_id.begins_with("netherite_"): return 4
    return -1

func _required_pickaxe_tier(block_id: String) -> int:
    if block_id in ["obsidian", "crying_obsidian", "ancient_debris", "respawn_anchor"]:
        return 3
    if block_id in ["diamond_ore", "deepslate_diamond_ore", "emerald_ore", "deepslate_emerald_ore", "gold_ore", "deepslate_gold_ore", "redstone_ore", "deepslate_redstone_ore"]:
        return 2
    if block_id in ["iron_ore", "deepslate_iron_ore", "copper_ore", "deepslate_copper_ore", "lapis_ore", "deepslate_lapis_ore"]:
        return 1
    if block_id.ends_with("_ore") or block_id in ["stone", "deepslate", "cobblestone", "cobbled_deepslate", "blackstone", "basalt", "end_stone", "nether_bricks", "quartz_block", "smooth_quartz", "prismarine", "dark_prismarine"]:
        return 0
    return -1

func _can_harvest_block(block_id: String, selected_tool: String) -> bool:
    var required := _required_pickaxe_tier(block_id)
    return required < 0 or _selected_pickaxe_tier(selected_tool) >= required

func _should_damage_selected_tool(block_id: String, selected_tool: String) -> bool:
    if not _is_durable_tool(selected_tool) or not inventory.has_item(selected_tool, 1):
        return false
    if selected_tool.ends_with("_pickaxe") and _required_pickaxe_tier(block_id) >= 0:
        return _can_harvest_block(block_id, selected_tool)
    return selected_tool.ends_with("_axe") and ("log" in block_id or block_id.ends_with("_stem") or block_id.ends_with("_planks"))

func _block_drop_for(block_id: String, state: Dictionary = {}) -> String:
    match block_id:
        "grass_block", "rooted_dirt": return "dirt"
        "stone": return "cobblestone"
        "deepslate": return "cobbled_deepslate"
        "coal_ore", "deepslate_coal_ore": return "coal"
        "diamond_ore", "deepslate_diamond_ore": return "diamond"
        "emerald_ore", "deepslate_emerald_ore": return "emerald"
        "iron_ore", "deepslate_iron_ore": return "raw_iron"
        "gold_ore", "deepslate_gold_ore": return "raw_gold"
        "copper_ore", "deepslate_copper_ore": return "raw_copper"
        "redstone_ore", "deepslate_redstone_ore": return "redstone"
        "lapis_ore", "deepslate_lapis_ore": return "lapis_lazuli"
        "nether_gold_ore": return "gold_nugget"
        "nether_quartz_ore": return "quartz"
        "short_grass", "tall_grass": return "wheat_seeds" if randi_range(0, 3) == 0 else ""
        "wheat": return "wheat" if int(state.get("age", 0)) >= 7 else "wheat_seeds"
        "carrots": return "carrot" if int(state.get("age", 0)) >= 7 else ""
        "potatoes": return "potato" if int(state.get("age", 0)) >= 7 else ""
        "beetroots": return "beetroot" if int(state.get("age", 0)) >= 3 else "beetroot_seeds"
        "oak_leaves", "birch_leaves", "spruce_leaves", "red_poplar_leaves", "orange_poplar_leaves", "yellow_poplar_leaves":
            var sapling := "oak_sapling"
            if block_id == "birch_leaves":
                sapling = "birch_sapling"
            elif block_id == "spruce_leaves":
                sapling = "spruce_sapling"
            elif block_id in ["red_poplar_leaves", "orange_poplar_leaves", "yellow_poplar_leaves"]:
                sapling = "poplar_sapling"
            if randi_range(0, 19) == 0 and BlockRegistry.has_block(sapling): return sapling
            if randi_range(0, 19) == 0: return "stick"
            return ""
        "gravel": return "flint" if randi_range(0, 9) == 0 else "gravel"
        _:
            # Drops are item IDs, not block IDs. Use the explicit supported mapping;
            # blocks such as redstone_wire drop the item redstone, while state-only
            # blocks (water, lava, farmland, dirt_path) have no standalone item.
            return BlockRegistry.get_item_for_block(block_id)

func _block_drop_count(block_id: String, state: Dictionary = {}) -> int:
    if block_id in ["short_grass", "tall_grass"]:
        return 1
    if block_id in ["redstone_ore", "deepslate_redstone_ore"]:
        return randi_range(4, 5)
    if block_id in ["lapis_ore", "deepslate_lapis_ore"]:
        return randi_range(4, 9)
    if block_id == "nether_gold_ore":
        return randi_range(2, 6)
    if block_id in ["carrots", "potatoes"] and int(state.get("age", 0)) >= 7:
        return randi_range(1, 4)
    return 1

func _switch_dimension(target_dimension: String) -> void:
    if not target_dimension in ["overworld", "nether", "end"] or target_dimension == world.dimension_id:
        return
    dimension_worlds[world.dimension_id] = world.get_save_data().duplicate(true)
    dimension_positions[world.dimension_id] = [player.global_position.x, player.global_position.y, player.global_position.z]
    for mob_node in get_tree().get_nodes_in_group("voxel_mob"):
        if is_instance_valid(mob_node):
            mob_node.queue_free()
    var destination_save: Dictionary = dimension_worlds.get(target_dimension, {})
    world.generate_world(world_seed, target_dimension)
    world.apply_modifications(destination_save.get("modified", {}), destination_save.get("block_states", {}), destination_save.get("fluid_active", {}))
    var target_position: Variant = dimension_positions.get(target_dimension, [])
    if target_position is Array and target_position.size() == 3:
        player.global_position = Vector3(float(target_position[0]), float(target_position[1]), float(target_position[2]))
    elif target_dimension == "nether" and dimension_positions.has("overworld"):
        var overworld_pos: Array = dimension_positions["overworld"]
        player.global_position = Vector3(float(overworld_pos[0]) / 8.0, float(world.get_surface_y(floori(float(overworld_pos[0]) / 8.0), floori(float(overworld_pos[2]) / 8.0))) + 0.05, float(overworld_pos[2]) / 8.0)
    elif target_dimension == "overworld" and dimension_positions.has("nether"):
        var nether_pos: Array = dimension_positions["nether"]
        player.global_position = Vector3(float(nether_pos[0]) * 8.0, float(world.get_surface_y(floori(float(nether_pos[0]) * 8.0), floori(float(nether_pos[2]) * 8.0))) + 0.05, float(nether_pos[2]) * 8.0)
    else:
        player.global_position = world.get_spawn_position()
    player.velocity = Vector3.ZERO
    player.spawn_position = world.get_spawn_position()
    world.prepare_position(player.global_position)
    _update_daylight()
    _portal_cooldown = 3.0
    _write_save_data(false)
    if is_instance_valid(hud):
        hud.show_message("Entered " + target_dimension.capitalize(), 3.0)

func _on_craft_requested(recipe_id: String, station_id: String) -> void:
    # The runtime crafting UI currently supports the explicitly labelled Flatworld sample
    # recipe schema. RecipeRegistry separately exposes imported vanilla JSON recipes so they
    # cannot be mistaken for executable shaped/shapeless/serializer-specific recipes.
    var recipe: Dictionary = RecipeRegistry.get_sample_recipe(recipe_id)
    if recipe.is_empty():
        hud.show_message("Unknown or unsupported recipe: " + recipe_id)
        return
    if station_id == "campfire":
        var campfire_ingredients: Dictionary = recipe.get("ingredients", {})
        for item_id in campfire_ingredients.keys():
            if not inventory.has_item(str(item_id), int(campfire_ingredients[item_id])):
                hud.show_message("Missing campfire input: " + BlockRegistry.get_item_name(str(item_id)))
                return
        for item_id in campfire_ingredients.keys():
            inventory.remove_item(str(item_id), int(campfire_ingredients[item_id]))
        pending_smelt.append({"recipe_id": recipe_id, "result": str(recipe.get("result", "")), "count": int(recipe.get("count", 1)), "remaining": 30.0, "station": "campfire"})
        hud.refresh_inventory()
        hud.show_message("Campfire cooking started · 30 seconds")
        return
    if station_id == "furnace":
        var ingredients: Dictionary = recipe.get("ingredients", {})
        var fuel_requirements: Dictionary = recipe.get("fuel", {"coal": 1})
        for item_id in ingredients.keys():
            if not inventory.has_item(str(item_id), int(ingredients[item_id])):
                hud.show_message("Missing smelting input: " + BlockRegistry.get_item_name(str(item_id)))
                return
        for fuel_id in fuel_requirements.keys():
            if not inventory.has_item(str(fuel_id), int(fuel_requirements[fuel_id])):
                hud.show_message("Missing furnace fuel: " + BlockRegistry.get_item_name(str(fuel_id)))
                return
        for item_id in ingredients.keys():
            inventory.remove_item(str(item_id), int(ingredients[item_id]))
        for fuel_id in fuel_requirements.keys():
            inventory.remove_item(str(fuel_id), int(fuel_requirements[fuel_id]))
        pending_smelt.append({"recipe_id": recipe_id, "result": str(recipe.get("result", "")), "count": int(recipe.get("count", 1)), "remaining": 10.0})
        hud.refresh_inventory()
        hud.show_message("Smelting started · 10 seconds")
        return
    var result := inventory.craft(recipe)
    if not bool(result.get("ok", false)):
        hud.show_message("Inventory is full" if str(result.get("reason", "")) == "inventory_full" else "Missing ingredients")
        return
    hud.refresh_inventory()
    hud.show_message("Crafted %s ×%d" % [BlockRegistry.get_item_name(str(result["result"])), int(result["count"])])

func _tick_pending_smelt(delta: float) -> void:
    if pending_smelt.is_empty() or not is_instance_valid(hud):
        return
    for i in range(pending_smelt.size() - 1, -1, -1):
        var job: Dictionary = pending_smelt[i]
        job["remaining"] = maxf(0.0, float(job.get("remaining", 0.0)) - delta)
        if float(job["remaining"]) > 0.0:
            pending_smelt[i] = job
            continue
        var result_id := str(job.get("result", ""))
        var remaining_count := int(job.get("count", 1))
        var accepted := inventory.add_item(result_id, remaining_count)
        if accepted > 0:
            remaining_count -= accepted
            job["count"] = remaining_count
            hud.refresh_inventory()
            if remaining_count <= 0:
                pending_smelt.remove_at(i)
                var station_name := "cooking" if str(job.get("station", "furnace")) == "campfire" else "smelting"
                hud.show_message("Finished %s %s" % [station_name, BlockRegistry.get_item_name(result_id)])
            else:
                job["remaining"] = 0.0
                pending_smelt[i] = job
        else:
            # Keep the completed output queued rather than silently deleting it.
            job["remaining"] = 0.0
            pending_smelt[i] = job

func _on_mob_exploded(explosion_position: Vector3, radius: float) -> void:
    if is_instance_valid(player):
        var distance_to_player := player.global_position.distance_to(explosion_position)
        if distance_to_player < radius + 0.75:
            var damage := clampi(int((radius + 0.75 - distance_to_player) * 5.5), 1, 20)
            player.take_damage(damage)
    for record in world.explode_blocks(explosion_position, radius):
        var block_id := str(record.get("id", ""))
        var cell: Vector3i = record.get("cell", Vector3i.ZERO)
        if randf() < 0.28 and BlockRegistry.is_placeable(block_id):
            _spawn_item_pickup(block_id, 1, Vector3(cell.x + 0.5, cell.y + 0.6, cell.z + 0.5))
    if is_instance_valid(hud):
        hud.show_message("Creeper explosion")

func _on_mob_died(drop_id: String, count_value: int, drop_position: Vector3) -> void:
    # Survival drops appear at the mob's location as collectible entities, just
    # like block drops; they are not magically inserted into the inventory.
    if player.creative_mode or drop_id.is_empty() or count_value <= 0:
        return
    _spawn_item_pickup(drop_id, count_value, drop_position + Vector3(0.0, 0.25, 0.0))

func _give_item_or_spawn(item_id: String, amount: int, world_position: Vector3) -> void:
    if amount <= 0 or item_id.is_empty():
        return
    var accepted := inventory.add_item(item_id, amount)
    if accepted > 0:
        hud.refresh_inventory()
    if accepted < amount:
        _spawn_item_pickup(item_id, amount - accepted, world_position)

func _spawn_item_pickup(item_id: String, amount: int, world_position: Vector3) -> void:
    if item_id.is_empty() or amount <= 0 or not BlockRegistry.has_block(item_id):
        return
    var pickup := PickupScript.new() as WorldItemPickup
    if pickup == null:
        return
    pickup.configure(item_id, amount, player, inventory)
    pickup.position = world_position
    pickup.collected.connect(_on_item_pickup_collected)
    add_child(pickup)

func _on_item_pickup_collected(_item_id: String, _amount_collected: int) -> void:
    if is_instance_valid(hud):
        hud.refresh_inventory()

func _collect_item_pickup_records() -> Array[Dictionary]:
    var records: Array[Dictionary] = []
    for node in get_tree().get_nodes_in_group("world_item_pickup"):
        if not is_instance_valid(node):
            continue
        var pickup := node as WorldItemPickup
        if pickup != null and pickup.count > 0:
            records.append(pickup.get_save_record())
    return records

func _clear_item_pickups() -> void:
    for node in get_tree().get_nodes_in_group("world_item_pickup"):
        if is_instance_valid(node):
            node.queue_free()

func _restore_item_pickups(raw_records: Variant) -> void:
    if not raw_records is Array:
        return
    for raw_record in raw_records:
        if not raw_record is Dictionary:
            continue
        var item_id := str(raw_record.get("id", ""))
        var amount := maxi(0, int(raw_record.get("count", 0)))
        var position_data: Variant = raw_record.get("position", [])
        if item_id.is_empty() or amount <= 0 or not position_data is Array or position_data.size() != 3:
            continue
        var drop_position := Vector3(float(position_data[0]), float(position_data[1]), float(position_data[2]))
        _spawn_item_pickup(item_id, amount, drop_position)
