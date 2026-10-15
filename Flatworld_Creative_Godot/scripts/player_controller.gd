extends CharacterBody3D
class_name VoxelPlayer

signal break_requested
signal break_hold_changed(holding: bool)
signal place_requested
signal health_changed(health: int, hunger: int)
signal message_requested(message: String)
signal use_requested
signal inventory_requested
signal mode_toggle_requested
signal flight_toggle_requested
signal hotbar_slot_requested(index: int)

@export var walk_speed := 5.4
@export var jump_speed := 8.0
@export var look_sensitivity := 0.0022
@export var creative_mode := true

var move_input := Vector2.ZERO
var jump_queued := false
var descend_queued := false
var jump_held := false
var descend_held := false
var _last_jump_request_msec := -10000
var flight_mode := false
var sprint_toggled := false
var selected_hotbar_index := 0
var health := 20
var hunger := 20
var saturation := 5.0
var exhaustion := 0.0
var spawn_position := Vector3(0.5, 18.0, 0.5)
var _fall_start_y := 0.0
var look_pitch := 0.0
var _attack_cooldown := 0.0
var _space_was_down := false
var camera: Camera3D

func _ready() -> void:
    name = "Player"
    collision_layer = 1
    collision_mask = 3
    var collider := CollisionShape3D.new()
    var capsule := CapsuleShape3D.new()
    capsule.radius = 0.34
    capsule.height = 1.82
    collider.shape = capsule
    collider.position.y = 0.91
    add_child(collider)
    var camera_node := Camera3D.new()
    camera_node.name = "Camera3D"
    camera_node.position = Vector3(0, 1.62, 0)
    camera_node.fov = 75.0
    camera_node.current = true
    add_child(camera_node)
    camera = camera_node
    if not OS.has_feature("mobile"):
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
    _attack_cooldown = maxf(0.0, _attack_cooldown - delta)
    var keyboard := Vector2.ZERO
    if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): keyboard.x -= 1.0
    if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): keyboard.x += 1.0
    if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): keyboard.y -= 1.0
    if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): keyboard.y += 1.0
    var input_vector := keyboard.normalized() if keyboard.length() > 0.05 else move_input
    var was_on_floor := is_on_floor()
    var position_before_move := global_position
    var space_down := Input.is_key_pressed(KEY_SPACE)
    if space_down and not _space_was_down:
        jump_queued = true
    _space_was_down = space_down
    var forward := -global_transform.basis.z
    forward.y = 0.0
    forward = forward.normalized()
    var right := global_transform.basis.x
    right.y = 0.0
    right = right.normalized()
    var direction := (right * input_vector.x) + (forward * -input_vector.y)
    if direction.length() > 1.0:
        direction = direction.normalized()
    var sprinting := sprint_toggled or Input.is_key_pressed(KEY_SHIFT)
    if not creative_mode and hunger <= 6:
        sprinting = false
        sprint_toggled = false
    # On touch, the downward control acts like sneak on the ground and descends
    # while flying. Sprint and sneak are mutually exclusive, as in Minecraft.
    if descend_held and not flight_mode:
        sprinting = false
    var speed_multiplier := 1.3 if sprinting else (0.3 if descend_held and not flight_mode else 1.0)

    if flight_mode and creative_mode:
        velocity.x = direction.x * walk_speed * 1.15
        velocity.z = direction.z * walk_speed * 1.15
        var vertical_flight_input := 0.0
        if jump_held:
            vertical_flight_input += 1.0
        if descend_held:
            vertical_flight_input -= 1.0
        velocity.y = vertical_flight_input * walk_speed * 1.15
        if jump_queued and not jump_held:
            global_position.y += 1.0
        if descend_queued and not descend_held:
            global_position.y -= 1.0
    else:
        if not is_on_floor():
            velocity.y -= 24.0 * delta
        elif velocity.y < 0.0:
            velocity.y = -0.5
        velocity.x = direction.x * walk_speed * speed_multiplier
        velocity.z = direction.z * walk_speed * speed_multiplier
        if jump_queued and is_on_floor():
            velocity.y = jump_speed
            if not creative_mode:
                add_exhaustion(0.2 if sprinting else 0.05)
    move_and_slide()
    if not creative_mode and not flight_mode:
        var horizontal_distance := Vector2(global_position.x - position_before_move.x, global_position.z - position_before_move.z).length()
        if horizontal_distance > 0.0:
            # Vanilla walking exhaustion is low; this is accumulated per metre
            # and converted to hunger by the survival tick in main.gd.
            add_exhaustion(horizontal_distance * (0.1 if sprinting else 0.01))
        if was_on_floor and not is_on_floor():
            _fall_start_y = position_before_move.y
        elif not was_on_floor and is_on_floor():
            var fall_distance := maxf(0.0, _fall_start_y - global_position.y)
            if fall_distance > 3.0:
                take_damage(floori(fall_distance - 3.0))
    else:
        _fall_start_y = global_position.y
    jump_queued = false
    descend_queued = false
    if global_position.y < -80.0:
        global_position = spawn_position
        velocity = Vector3.ZERO
        health = 20
        hunger = 20
        saturation = 5.0
        exhaustion = 0.0
        sprint_toggled = false
        _fall_start_y = spawn_position.y
        health_changed.emit(health, hunger)
        message_requested.emit("Respawned at world spawn")

func set_move_input(value: Vector2) -> void:
    move_input = value.limit_length(1.0)

func set_hotbar_index(index: int) -> void:
    selected_hotbar_index = posmod(index, 9)

func _cycle_hotbar(direction: int) -> void:
    selected_hotbar_index = posmod(selected_hotbar_index + direction, 9)
    hotbar_slot_requested.emit(selected_hotbar_index)

func request_jump() -> void:
    # Minecraft-style double-tap jump enters/exits Creative flight. A single tap
    # keeps the normal jump behaviour; holding jump climbs while flight is active.
    var now_msec := Time.get_ticks_msec()
    if creative_mode and now_msec - _last_jump_request_msec <= 360:
        toggle_flight()
        jump_queued = false
        _last_jump_request_msec = -10000
        return
    _last_jump_request_msec = now_msec
    jump_queued = true

func set_jump_held(holding: bool) -> void:
    jump_held = holding

func request_descend() -> void:
    descend_queued = true

func set_descend_held(holding: bool) -> void:
    descend_held = holding

func toggle_flight() -> void:
    if not creative_mode:
        message_requested.emit("Flight is only available in Creative mode")
        return
    flight_mode = not flight_mode
    velocity.y = 0.0
    message_requested.emit("Flight " + ("enabled" if flight_mode else "disabled"))

func set_sprinting(enabled: bool) -> void:
    if enabled and not creative_mode and hunger <= 6:
        sprint_toggled = false
        message_requested.emit("You need more food to sprint")
        return
    sprint_toggled = enabled
    message_requested.emit("Sprinting " + ("enabled" if sprint_toggled else "disabled"))

func set_creative_mode(enabled: bool) -> void:
    creative_mode = enabled
    if not creative_mode:
        flight_mode = false
        jump_held = false
        descend_held = false
    message_requested.emit("Mode: " + ("Creative" if creative_mode else "Survival"))

func take_damage(amount: int) -> void:
    if creative_mode or amount <= 0:
        return
    health = maxi(0, health - amount)
    health_changed.emit(health, hunger)
    if health == 0:
        global_position = spawn_position
        velocity = Vector3.ZERO
        health = 20
        hunger = 20
        saturation = 5.0
        exhaustion = 0.0
        sprint_toggled = false
        health_changed.emit(health, hunger)
        message_requested.emit("You were defeated. Respawned at world spawn.")

func heal(amount: int) -> void:
    health = mini(20, health + amount)
    health_changed.emit(health, hunger)

func add_exhaustion(amount: float) -> void:
    if creative_mode or amount <= 0.0:
        return
    exhaustion = minf(40.0, exhaustion + amount)

func eat_food(hunger_points: int, saturation_modifier: float = 0.6) -> bool:
    if creative_mode:
        message_requested.emit("Food effects are disabled in Creative mode")
        return false
    hunger = mini(20, hunger + maxi(0, hunger_points))
    # Food saturation is capped by the resulting hunger level. Eating restores
    # hunger/saturation; health regeneration runs separately at its own rate.
    saturation = minf(float(hunger), saturation + float(maxi(0, hunger_points)) * maxf(0.0, saturation_modifier) * 2.0)
    health_changed.emit(health, hunger)
    return true

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        rotate_y(-event.relative.x * look_sensitivity)
        look_pitch = clampf(look_pitch - event.relative.y * look_sensitivity, -1.48, 1.48)
        camera.rotation.x = look_pitch
    elif event is InputEventScreenDrag:
        var viewport_size := get_viewport().get_visible_rect().size
        if event.position.x > viewport_size.x * 0.38 and event.position.y < viewport_size.y - 235.0:
            rotate_y(-event.relative.x * 0.0042)
            look_pitch = clampf(look_pitch - event.relative.y * 0.0042, -1.48, 1.48)
            camera.rotation.x = look_pitch
    elif event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed:
                if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
                    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
                else:
                    break_hold_changed.emit(true)
            else:
                break_hold_changed.emit(false)
        elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
            place_requested.emit()
        elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            _cycle_hotbar(-1)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            _cycle_hotbar(1)
    elif event is InputEventKey and event.pressed and not event.echo:
        match event.keycode:
            KEY_ESCAPE:
                Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
            KEY_E:
                use_requested.emit()
            KEY_I:
                inventory_requested.emit()
            KEY_F:
                flight_toggle_requested.emit()
            KEY_M:
                mode_toggle_requested.emit()
            KEY_1: _request_hotbar_slot(0)
            KEY_2: _request_hotbar_slot(1)
            KEY_3: _request_hotbar_slot(2)
            KEY_4: _request_hotbar_slot(3)
            KEY_5: _request_hotbar_slot(4)
            KEY_6: _request_hotbar_slot(5)
            KEY_7: _request_hotbar_slot(6)
            KEY_8: _request_hotbar_slot(7)
            KEY_9: _request_hotbar_slot(8)

func _request_hotbar_slot(index: int) -> void:
    set_hotbar_index(index)
    hotbar_slot_requested.emit(selected_hotbar_index)
