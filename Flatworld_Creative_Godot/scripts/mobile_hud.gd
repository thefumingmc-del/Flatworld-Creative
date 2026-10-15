extends CanvasLayer
class_name MobileHUD

signal break_pressed
signal break_hold_changed(holding: bool)
signal sprint_toggled(enabled: bool)
signal place_pressed
signal jump_pressed
signal jump_hold_changed(holding: bool)
signal descend_pressed
signal descend_hold_changed(holding: bool)
signal use_pressed
signal save_pressed
signal load_pressed
signal inventory_pressed
signal mode_pressed
signal flight_pressed
signal selected_block(block_id: String)
signal hotbar_index_changed(index: int)
signal joystick_changed(value: Vector2)
signal craft_requested(recipe_id: String, station_id: String)
signal container_action(action: String, cell_key: String)

var root: Control
var status_label: Label
var biome_label: Label
var health_label: Label
var mining_bar: ProgressBar
var mining_label: Label
var joystick_control: Control
var hotbar_container: HBoxContainer
var _sprint_enabled := false
var selected_label: Label
var inventory_panel: PanelContainer
var inventory_grid: GridContainer
var station_panel: PanelContainer
var station_items: VBoxContainer
var hotbar_buttons: Array[Button] = []
var _atlas_texture: Texture2D
var _atlas_icon_cache: Dictionary = {}
var hotbar_ids: Array[String] = ["grass_block", "dirt", "stone", "cobblestone", "oak_planks", "oak_log", "glass", "torch", "crafting_table"]
var chosen_block := "grass_block"
var selected_hotbar_index := 0
var _station_title: Label
var _message_timer := 0.0
var _creative_mode := true
var inventory_ref: Object

class FlatworldVirtualJoystick extends Control:
    signal value_changed(value: Vector2)
    var finger_id := -99
    var stick_value := Vector2.ZERO
    var active := false

    func _ready() -> void:
        mouse_filter = Control.MOUSE_FILTER_STOP
        queue_redraw()

    func _draw() -> void:
        var center := size * 0.5
        draw_circle(center, minf(size.x, size.y) * 0.48, Color(0.05, 0.07, 0.09, 0.45))
        draw_circle(center, minf(size.x, size.y) * 0.40, Color(0.8, 0.84, 0.86, 0.18))
        draw_circle(center + stick_value * minf(size.x, size.y) * 0.29, minf(size.x, size.y) * 0.18, Color(0.84, 0.89, 0.91, 0.72))

    func _gui_input(event: InputEvent) -> void:
        if event is InputEventScreenTouch:
            if event.pressed:
                active = true
                finger_id = event.index
                _update_from_position(event.position)
            elif event.index == finger_id:
                active = false
                finger_id = -99
                stick_value = Vector2.ZERO
                value_changed.emit(stick_value)
                queue_redraw()
        elif event is InputEventScreenDrag and event.index == finger_id:
            _update_from_position(event.position)
        elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
            active = event.pressed
            if active:
                _update_from_position(event.position)
            else:
                stick_value = Vector2.ZERO
                value_changed.emit(stick_value)
                queue_redraw()
        elif event is InputEventMouseMotion and active and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
            _update_from_position(event.position)

    func _update_from_position(pos: Vector2) -> void:
        var center := size * 0.5
        var radius := maxf(1.0, minf(size.x, size.y) * 0.40)
        stick_value = ((pos - center) / radius).limit_length(1.0)
        value_changed.emit(stick_value)
        queue_redraw()

func _ready() -> void:
    BlockRegistry.load_data()
    _atlas_texture = load("res://assets/textures/atlas.png") as Texture2D
    root = Control.new()
    root.name = "TouchHUD"
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_PASS
    add_child(root)
    _build_top_bar()
    _build_joystick()
    _build_action_buttons()
    _build_hotbar()
    _build_crosshair()
    _build_inventory_panel()
    _build_station_panel()
    set_selected_block(chosen_block)
    root.resized.connect(_adapt_layout)
    get_viewport().size_changed.connect(_adapt_layout)
    call_deferred("_adapt_layout")

func _process(delta: float) -> void:
    _message_timer = maxf(0.0, _message_timer - delta)
    if _message_timer <= 0.0 and status_label != null and status_label.text.begins_with("•"):
        status_label.text = "• World ready"

func _make_button(text_value: String, node_name: String, parent: Control, width: float, height: float, font_size: int = 16) -> Button:
    var button := Button.new()
    button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    button.name = node_name
    button.text = text_value
    button.custom_minimum_size = Vector2(width, height)
    button.add_theme_font_size_override("font_size", font_size)
    button.focus_mode = Control.FOCUS_NONE
    parent.add_child(button)
    return button

func _anchor_top_button(button: Control, left: float, width: float) -> void:
    button.anchor_left = 0.0
    button.anchor_right = 0.0
    button.anchor_top = 0.0
    button.anchor_bottom = 0.0
    button.offset_left = left
    button.offset_right = left + width
    button.offset_top = 12
    button.offset_bottom = 56

func _build_top_bar() -> void:
    var save_btn := _make_button("SAVE", "SaveButton", root, 76, 44, 15)
    _anchor_top_button(save_btn, 12, 76)
    save_btn.pressed.connect(func(): save_pressed.emit())
    var load_btn := _make_button("LOAD", "LoadButton", root, 76, 44, 15)
    _anchor_top_button(load_btn, 94, 76)
    load_btn.pressed.connect(func(): load_pressed.emit())
    var inv_btn := _make_button("INVENTORY", "InventoryButton", root, 112, 44, 14)
    _anchor_top_button(inv_btn, 176, 112)
    inv_btn.pressed.connect(func(): _toggle_inventory())
    var mode_btn := _make_button("CREATIVE", "ModeButton", root, 100, 44, 14)
    _anchor_top_button(mode_btn, 294, 100)
    mode_btn.pressed.connect(func(): mode_pressed.emit())
    var fly_btn := _make_button("FLY", "FlightButton", root, 62, 44, 14)
    _anchor_top_button(fly_btn, 400, 62)
    fly_btn.pressed.connect(func(): flight_pressed.emit())
    var use_btn := _make_button("USE", "UseButton", root, 62, 44, 14)
    _anchor_top_button(use_btn, 468, 62)
    use_btn.pressed.connect(func(): use_pressed.emit())

    biome_label = Label.new()
    biome_label.name = "BiomeLabel"
    biome_label.text = "Biome: Plains"
    biome_label.add_theme_font_size_override("font_size", 17)
    biome_label.anchor_left = 1.0
    biome_label.anchor_right = 1.0
    biome_label.anchor_top = 0.0
    biome_label.anchor_bottom = 0.0
    biome_label.offset_left = -270
    biome_label.offset_right = -16
    biome_label.offset_top = 14
    biome_label.offset_bottom = 40
    biome_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    root.add_child(biome_label)

    health_label = Label.new()
    health_label.name = "HealthLabel"
    health_label.text = "❤ 20   ◆ 20"
    health_label.add_theme_font_size_override("font_size", 20)
    health_label.anchor_left = 1.0
    health_label.anchor_right = 1.0
    health_label.anchor_top = 0.0
    health_label.anchor_bottom = 0.0
    health_label.offset_left = -240
    health_label.offset_right = -16
    health_label.offset_top = 42
    health_label.offset_bottom = 74
    health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    root.add_child(health_label)

    status_label = Label.new()
    status_label.name = "StatusLabel"
    status_label.text = "• World ready"
    status_label.add_theme_font_size_override("font_size", 16)
    status_label.anchor_left = 0.0
    status_label.anchor_right = 0.0
    status_label.anchor_top = 0.0
    status_label.anchor_bottom = 0.0
    status_label.offset_left = 14
    status_label.offset_right = 430
    status_label.offset_top = 62
    status_label.offset_bottom = 91
    root.add_child(status_label)

func _build_joystick() -> void:
    var pad := FlatworldVirtualJoystick.new()
    pad.name = "MoveJoystick"
    pad.anchor_left = 0.0
    pad.anchor_right = 0.0
    pad.anchor_top = 1.0
    pad.anchor_bottom = 1.0
    pad.offset_left = 22
    pad.offset_right = 202
    pad.offset_top = -202
    pad.offset_bottom = -22
    root.add_child(pad)
    joystick_control = pad
    pad.value_changed.connect(func(value: Vector2): joystick_changed.emit(value))

func _anchor_bottom_right(button: Control, left_offset: float, right_offset: float, top_offset: float, bottom_offset: float) -> void:
    button.anchor_left = 1.0
    button.anchor_right = 1.0
    button.anchor_top = 1.0
    button.anchor_bottom = 1.0
    button.offset_left = left_offset
    button.offset_right = right_offset
    button.offset_top = top_offset
    button.offset_bottom = bottom_offset

func _build_action_buttons() -> void:
    var break_btn := _make_button("BREAK", "BreakButton", root, 102, 66, 17)
    _anchor_bottom_right(break_btn, -128, -20, -178, -112)
    break_btn.button_down.connect(func(): break_hold_changed.emit(true))
    break_btn.button_up.connect(func(): break_hold_changed.emit(false))
    break_btn.pressed.connect(func(): break_pressed.emit())
    var place_btn := _make_button("PLACE", "PlaceButton", root, 102, 66, 17)
    _anchor_bottom_right(place_btn, -242, -134, -102, -36)
    place_btn.pressed.connect(func(): place_pressed.emit())
    var jump_btn := _make_button("JUMP", "JumpButton", root, 102, 66, 17)
    _anchor_bottom_right(jump_btn, -128, -20, -102, -36)
    jump_btn.button_down.connect(func():
        jump_hold_changed.emit(true)
        jump_pressed.emit()
    )
    jump_btn.button_up.connect(func(): jump_hold_changed.emit(false))
    var down_btn := _make_button("DOWN", "DescendButton", root, 82, 50, 14)
    _anchor_bottom_right(down_btn, -220, -134, -166, -116)
    down_btn.button_down.connect(func(): descend_hold_changed.emit(true))
    down_btn.button_up.connect(func(): descend_hold_changed.emit(false))
    down_btn.pressed.connect(func(): descend_pressed.emit())
    var sprint_btn := _make_button("RUN OFF", "SprintButton", root, 92, 42, 13)
    sprint_btn.anchor_left = 1.0
    sprint_btn.anchor_right = 1.0
    sprint_btn.anchor_top = 1.0
    sprint_btn.anchor_bottom = 1.0
    sprint_btn.offset_left = -236.0
    sprint_btn.offset_right = -144.0
    sprint_btn.offset_top = -252.0
    sprint_btn.offset_bottom = -210.0
    sprint_btn.pressed.connect(func():
        _sprint_enabled = not _sprint_enabled
        sprint_toggled.emit(_sprint_enabled)
        set_sprint_text(_sprint_enabled)
    )

func _build_hotbar() -> void:
    var hotbar := HBoxContainer.new()
    hotbar.name = "Hotbar"
    hotbar.anchor_left = 0.5
    hotbar.anchor_right = 0.5
    hotbar.anchor_top = 1.0
    hotbar.anchor_bottom = 1.0
    hotbar.offset_left = -360
    hotbar.offset_right = 360
    hotbar.offset_top = -76
    hotbar.offset_bottom = -10
    hotbar.add_theme_constant_override("separation", 4)
    root.add_child(hotbar)
    hotbar_container = hotbar
    for i in range(hotbar_ids.size()):
        var block_id := hotbar_ids[i]
        var button := _make_button("%d\n%s" % [i + 1, BlockRegistry.get_name(block_id)], "HotbarSlot%d" % i, hotbar, 76, 64, 12)
        button.icon = _atlas_icon_for_block(block_id)
        button.icon_max_width = 18
        button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        button.pressed.connect(_select_hotbar.bind(i))
        hotbar_buttons.append(button)
    _refresh_hotbar()

func _build_crosshair() -> void:
    var crosshair := Label.new()
    crosshair.name = "Crosshair"
    crosshair.text = "+"
    crosshair.add_theme_font_size_override("font_size", 28)
    crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
    crosshair.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
    crosshair.add_theme_constant_override("shadow_offset_x", 1)
    crosshair.add_theme_constant_override("shadow_offset_y", 1)
    crosshair.anchor_left = 0.5
    crosshair.anchor_right = 0.5
    crosshair.anchor_top = 0.5
    crosshair.anchor_bottom = 0.5
    crosshair.offset_left = -11
    crosshair.offset_right = 11
    crosshair.offset_top = -18
    crosshair.offset_bottom = 18
    crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.add_child(crosshair)
    mining_label = Label.new()
    mining_label.name = "MiningTargetLabel"
    mining_label.text = ""
    mining_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    mining_label.add_theme_font_size_override("font_size", 13)
    mining_label.add_theme_color_override("font_color", Color(0.94, 0.94, 0.9, 0.95))
    mining_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
    mining_label.add_theme_constant_override("shadow_offset_x", 1)
    mining_label.add_theme_constant_override("shadow_offset_y", 1)
    mining_label.anchor_left = 0.5
    mining_label.anchor_right = 0.5
    mining_label.anchor_top = 0.5
    mining_label.anchor_bottom = 0.5
    mining_label.offset_left = -140
    mining_label.offset_right = 140
    mining_label.offset_top = 30
    mining_label.offset_bottom = 52
    mining_label.visible = false
    mining_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    root.add_child(mining_label)
    mining_bar = ProgressBar.new()
    mining_bar.name = "MiningProgress"
    mining_bar.min_value = 0.0
    mining_bar.max_value = 100.0
    mining_bar.value = 0.0
    mining_bar.show_percentage = false
    mining_bar.anchor_left = 0.5
    mining_bar.anchor_right = 0.5
    mining_bar.anchor_top = 0.5
    mining_bar.anchor_bottom = 0.5
    mining_bar.offset_left = -94
    mining_bar.offset_right = 94
    mining_bar.offset_top = 52
    mining_bar.offset_bottom = 62
    mining_bar.visible = false
    mining_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var bg_style := StyleBoxFlat.new()
    bg_style.bg_color = Color(0.08, 0.08, 0.08, 0.92)
    bg_style.border_color = Color(0.38, 0.38, 0.38, 0.95)
    bg_style.set_border_width_all(1)
    mining_bar.add_theme_stylebox_override("background", bg_style)
    var fill_style := StyleBoxFlat.new()
    fill_style.bg_color = Color(0.78, 0.78, 0.72, 1.0)
    mining_bar.add_theme_stylebox_override("fill", fill_style)
    root.add_child(mining_bar)

func set_mining_progress(progress: float, block_name: String = "", visible_value: bool = true) -> void:
    if mining_bar == null or mining_label == null:
        return
    mining_bar.value = clampf(progress, 0.0, 1.0) * 100.0
    mining_label.text = block_name
    mining_bar.visible = visible_value
    mining_label.visible = visible_value and not block_name.is_empty()

func _build_inventory_panel() -> void:
    inventory_panel = PanelContainer.new()
    inventory_panel.name = "CreativeInventory"
    inventory_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    inventory_panel.offset_left = -310
    inventory_panel.offset_right = 310
    inventory_panel.offset_top = -288
    inventory_panel.offset_bottom = 288
    inventory_panel.visible = false
    inventory_panel.z_index = 10
    root.add_child(inventory_panel)
    var column := VBoxContainer.new()
    inventory_panel.add_child(column)
    var header := HBoxContainer.new()
    column.add_child(header)
    var title := Label.new()
    title.text = "CREATIVE CATALOGUE · BLOCKS & ITEMS"
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title.add_theme_font_size_override("font_size", 18)
    header.add_child(title)
    var close_btn := _make_button("CLOSE", "InventoryClose", header, 82, 36, 13)
    close_btn.pressed.connect(func(): inventory_panel.visible = false)
    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.add_child(scroll)
    inventory_grid = GridContainer.new()
    inventory_grid.columns = 5
    inventory_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    inventory_grid.add_theme_constant_override("h_separation", 4)
    inventory_grid.add_theme_constant_override("v_separation", 4)
    scroll.add_child(inventory_grid)
    BlockRegistry.load_data()
    for block_id in BlockRegistry.get_catalogue_ids():
        var defn := BlockRegistry.get_item_runtime(block_id)
        var text_value := str(defn.get("name", block_id))
        var item_btn := _make_button(text_value, "Item_" + block_id, inventory_grid, 110, 43, 12)
        item_btn.icon = _atlas_icon_for_block(block_id)
        item_btn.icon_max_width = 20
        item_btn.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
        item_btn.tooltip_text = block_id + " · " + str(defn.get("category", "Item"))
        item_btn.pressed.connect(_on_catalogue_item_selected.bind(block_id))

func _build_station_panel() -> void:
    station_panel = PanelContainer.new()
    station_panel.name = "StationPanel"
    station_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
    station_panel.offset_left = -235
    station_panel.offset_right = 235
    station_panel.offset_top = -235
    station_panel.offset_bottom = 235
    station_panel.visible = false
    station_panel.z_index = 12
    root.add_child(station_panel)
    var column := VBoxContainer.new()
    station_panel.add_child(column)
    var header := HBoxContainer.new()
    column.add_child(header)
    _station_title = Label.new()
    _station_title.text = "WORKBENCH"
    _station_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _station_title.add_theme_font_size_override("font_size", 18)
    header.add_child(_station_title)
    var close_btn := _make_button("CLOSE", "StationClose", header, 80, 34, 12)
    close_btn.pressed.connect(func(): station_panel.visible = false)
    var hint := Label.new()
    hint.text = "Creative mode: choose a recipe output to select it."
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(hint)
    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    column.add_child(scroll)
    station_items = VBoxContainer.new()
    station_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(station_items)

func set_biome(text_value: String) -> void:
    if biome_label != null:
        biome_label.text = "Biome: " + text_value

func set_health(health: int, hunger: int) -> void:
    if health_label != null:
        health_label.text = "❤ %d/20   ◆ %d/20" % [health, hunger]

func set_selected_block(block_id: String) -> void:
    chosen_block = block_id
    if selected_label != null:
        selected_label.text = BlockRegistry.get_item_name(block_id)
    for i in range(hotbar_buttons.size()):
        var b := hotbar_buttons[i]
        var bid := hotbar_ids[i]
        if bid == chosen_block:
            b.modulate = Color(1.0, 0.9, 0.55, 1.0)
        else:
            b.modulate = Color(1, 1, 1, 1)

func set_mode_text(is_creative: bool) -> void:
    _creative_mode = is_creative
    for child in root.get_children():
        if child is Button and child.name == "ModeButton":
            child.text = "CREATIVE" if is_creative else "SURVIVAL"
    _refresh_hotbar()

func set_inventory_state(inventory: Object, is_creative: bool) -> void:
    inventory_ref = inventory
    _creative_mode = is_creative
    _refresh_hotbar()

func refresh_inventory() -> void:
    _refresh_hotbar()

func _refresh_hotbar() -> void:
    if hotbar_buttons.is_empty():
        return
    if not _creative_mode and inventory_ref != null and inventory_ref.has_method("get_hotbar_id"):
        for i in range(hotbar_ids.size()):
            hotbar_ids[i] = str(inventory_ref.call("get_hotbar_id", i))
    else:
        hotbar_ids = ["grass_block", "dirt", "stone", "cobblestone", "oak_planks", "oak_log", "glass", "torch", "crafting_table"]
    for i in range(hotbar_buttons.size()):
        var block_id := hotbar_ids[i]
        var count_value := 0
        if inventory_ref != null and inventory_ref.has_method("count") and not block_id.is_empty():
            count_value = int(inventory_ref.call("count", block_id))
        var full_label := "Empty" if block_id.is_empty() else BlockRegistry.get_item_name(block_id)
        hotbar_buttons[i].tooltip_text = full_label + (" ×%d" % count_value if not _creative_mode and not block_id.is_empty() else "")
        var label_text := _short_item_label(block_id) if not block_id.is_empty() else "Empty"
        if not _creative_mode and not block_id.is_empty():
            label_text += " %d" % count_value if count_value > 1 else ""
        hotbar_buttons[i].text = "%d\n%s" % [i + 1, label_text]
        hotbar_buttons[i].icon = _atlas_icon_for_block(block_id) if not block_id.is_empty() else null
        hotbar_buttons[i].disabled = (not _creative_mode and block_id.is_empty())


func _atlas_icon_for_block(block_id: String) -> Texture2D:
    if block_id.is_empty():
        return null
    if _atlas_icon_cache.has(block_id):
        return _atlas_icon_cache[block_id] as Texture2D

    # Inventory sprites have their own canonical item identity and must not be inferred
    # from the block's top face (e.g. wheat item versus the growing wheat block).
    var item_icon_path := BlockRegistry.get_item_icon_path(block_id)
    if not item_icon_path.is_empty() and ResourceLoader.exists(item_icon_path):
        var item_icon := ResourceLoader.load(item_icon_path) as Texture2D
        if item_icon != null:
            _atlas_icon_cache[block_id] = item_icon
            return item_icon

    if _atlas_texture == null:
        _atlas_texture = load("res://assets/textures/atlas.png") as Texture2D
    if _atlas_texture == null:
        push_warning("Neither item icon nor block atlas could be loaded for " + block_id)
        return null
    var mapped_block_id := BlockRegistry.get_place_block_id(block_id)
    var texture_source_id := mapped_block_id if not mapped_block_id.is_empty() else block_id
    var definition := BlockRegistry.get_block(texture_source_id)
    var tiles: Dictionary = definition.get("tiles", {})
    var tile_index := int(tiles.get("top", tiles.get("side", -1)))
    if tile_index < 0:
        push_warning("No item icon or atlas swatch is registered for " + block_id)
        return null
    var columns := maxi(1, int(_atlas_texture.get_width() / 16))
    var rows := maxi(1, int(_atlas_texture.get_height() / 16))
    if tile_index >= columns * rows:
        push_warning("Texture tile index out of atlas bounds for " + block_id)
        return null
    var icon_texture := AtlasTexture.new()
    icon_texture.atlas = _atlas_texture
    icon_texture.region = Rect2((tile_index % columns) * 16, int(tile_index / columns) * 16, 16, 16)
    icon_texture.filter_clip = true
    _atlas_icon_cache[block_id] = icon_texture
    return icon_texture

func _short_item_label(block_id: String) -> String:
    var aliases := {
        "grass_block": "Grass", "cobblestone": "Cobble", "oak_planks": "Planks",
        "crafting_table": "Craft", "redstone": "Redstone", "diamond_ore": "Diamond",
        "iron_ore": "Iron Ore", "gold_ore": "Gold Ore", "water_bucket": "Water",
        "lava_bucket": "Lava", "cooked_beef": "Steak", "oak_log": "Log"
    }
    if aliases.has(block_id):
        return str(aliases[block_id])
    var item_name := BlockRegistry.get_item_name(block_id)
    if item_name.length() > 8:
        return item_name.substr(0, 7) + "…"
    return item_name

func set_sprint_text(enabled: bool) -> void:
    _sprint_enabled = enabled
    var sprint_btn := root.get_node_or_null("SprintButton") as Button
    if sprint_btn != null:
        sprint_btn.text = "RUN ON" if enabled else "RUN OFF"
        sprint_btn.modulate = Color(0.78, 0.92, 0.66, 1.0) if enabled else Color.WHITE

func _adapt_layout() -> void:
    if root == null:
        return
    var viewport_size := get_viewport().get_visible_rect().size
    if viewport_size.x < 1.0 or viewport_size.y < 1.0:
        return
    var top_names := ["SaveButton", "LoadButton", "InventoryButton", "ModeButton", "FlightButton", "UseButton"]
    var top_widths := [76.0, 76.0, 112.0, 100.0, 62.0, 62.0]
    var top_fonts := [15, 15, 14, 14, 14, 14]
    var base_total := 0.0
    for width in top_widths:
        base_total += float(width)
    base_total += float(top_names.size() - 1) * 5.0
    var top_scale := minf(1.0, maxf(0.55, (viewport_size.x - 20.0) / base_total))
    var cursor_x := 10.0
    for i in range(top_names.size()):
        var button := root.get_node_or_null(top_names[i]) as Button
        if button == null:
            continue
        var width := float(top_widths[i]) * top_scale
        button.offset_left = cursor_x
        button.offset_right = cursor_x + width
        button.offset_top = 8.0
        button.offset_bottom = 8.0 + 44.0 * top_scale
        button.add_theme_font_size_override("font_size", maxi(9, roundi(float(top_fonts[i]) * top_scale)))
        cursor_x += width + 5.0 * top_scale
    var control_scale := clampf(minf(viewport_size.x / 430.0, viewport_size.y / 800.0), 0.62, 1.0)
    var bottom_layout := {
        "BreakButton": [-128.0, -20.0, -178.0, -112.0, 102.0, 66.0, 17],
        "PlaceButton": [-242.0, -134.0, -102.0, -36.0, 102.0, 66.0, 17],
        "JumpButton": [-128.0, -20.0, -102.0, -36.0, 102.0, 66.0, 17],
        "DescendButton": [-220.0, -134.0, -166.0, -116.0, 82.0, 50.0, 14],
    }
    for button_name in bottom_layout.keys():
        var button := root.get_node_or_null(str(button_name)) as Button
        if button == null:
            continue
        var layout: Array = bottom_layout[button_name]
        button.offset_left = float(layout[0]) * control_scale
        button.offset_right = float(layout[1]) * control_scale
        button.offset_top = float(layout[2]) * control_scale
        button.offset_bottom = float(layout[3]) * control_scale
        button.add_theme_font_size_override("font_size", maxi(9, roundi(float(layout[6]) * control_scale)))
    var sprint_btn := root.get_node_or_null("SprintButton") as Button
    if sprint_btn != null:
        sprint_btn.anchor_left = 1.0
        sprint_btn.anchor_right = 1.0
        sprint_btn.anchor_top = 1.0
        sprint_btn.anchor_bottom = 1.0
        sprint_btn.offset_left = -236.0 * control_scale
        sprint_btn.offset_right = -144.0 * control_scale
        sprint_btn.offset_top = -252.0 * control_scale
        sprint_btn.offset_bottom = -210.0 * control_scale
        sprint_btn.add_theme_font_size_override("font_size", maxi(9, roundi(13.0 * control_scale)))
    if joystick_control != null:
        joystick_control.offset_left = 18.0 * control_scale
        joystick_control.offset_right = 198.0 * control_scale
        joystick_control.offset_top = -202.0 * control_scale
        joystick_control.offset_bottom = -22.0 * control_scale
    if hotbar_container != null:
        var hotbar_width := minf(viewport_size.x * 0.96, 720.0)
        var hotbar_scale := hotbar_width / 720.0
        hotbar_container.offset_left = -hotbar_width * 0.5
        hotbar_container.offset_right = hotbar_width * 0.5
        hotbar_container.offset_top = -76.0 * hotbar_scale
        hotbar_container.offset_bottom = -8.0 * hotbar_scale
        hotbar_container.add_theme_constant_override("separation", maxi(1, roundi(4.0 * hotbar_scale)))
        var slot_width := maxf(24.0, (hotbar_width - float(hotbar_buttons.size() - 1) * maxi(1, roundi(4.0 * hotbar_scale))) / float(maxi(1, hotbar_buttons.size())))
        for slot_button in hotbar_buttons:
            slot_button.custom_minimum_size = Vector2(slot_width, 64.0 * hotbar_scale)
            slot_button.add_theme_font_size_override("font_size", maxi(7, roundi(12.0 * hotbar_scale)))
    if biome_label != null:
        biome_label.visible = viewport_size.x >= 720.0
        biome_label.offset_left = -270.0
        biome_label.offset_right = -16.0
        biome_label.add_theme_font_size_override("font_size", 17)
    if health_label != null and status_label != null:
        if viewport_size.x < 720.0:
            # On portrait phones, move vital stats and status below the compact
            # button row instead of overlapping the Save/Inventory/Mode controls.
            health_label.anchor_left = 0.5
            health_label.anchor_right = 0.5
            health_label.offset_left = -130.0
            health_label.offset_right = 130.0
            health_label.offset_top = 56.0
            health_label.offset_bottom = 80.0
            health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
            health_label.add_theme_font_size_override("font_size", 15)
            status_label.offset_left = 14.0
            status_label.offset_right = viewport_size.x - 14.0
            status_label.offset_top = 80.0
            status_label.offset_bottom = 102.0
            status_label.add_theme_font_size_override("font_size", 12)
        else:
            health_label.anchor_left = 1.0
            health_label.anchor_right = 1.0
            health_label.offset_left = -240.0
            health_label.offset_right = -16.0
            health_label.offset_top = 42.0
            health_label.offset_bottom = 74.0
            health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
            health_label.add_theme_font_size_override("font_size", 20)
            status_label.offset_left = 14.0
            status_label.offset_right = 430.0
            status_label.offset_top = 62.0
            status_label.offset_bottom = 91.0
            status_label.add_theme_font_size_override("font_size", 16)
    if inventory_panel != null:
        var panel_width := minf(620.0, viewport_size.x * 0.92)
        var panel_height := minf(576.0, viewport_size.y * 0.84)
        inventory_panel.offset_left = -panel_width * 0.5
        inventory_panel.offset_right = panel_width * 0.5
        inventory_panel.offset_top = -panel_height * 0.5
        inventory_panel.offset_bottom = panel_height * 0.5
        if inventory_grid != null:
            inventory_grid.columns = 5 if panel_width >= 580.0 else (3 if panel_width >= 380.0 else 2)
            var item_width := maxf(92.0, (panel_width - 32.0 - float(inventory_grid.columns - 1) * 4.0) / float(inventory_grid.columns))
            for child in inventory_grid.get_children():
                if child is Button:
                    child.custom_minimum_size.x = item_width
    if station_panel != null:
        var station_width := minf(470.0, viewport_size.x * 0.90)
        var station_height := minf(470.0, viewport_size.y * 0.80)
        station_panel.offset_left = -station_width * 0.5
        station_panel.offset_right = station_width * 0.5
        station_panel.offset_top = -station_height * 0.5
        station_panel.offset_bottom = station_height * 0.5

func show_message(message: String, seconds: float = 3.0) -> void:
    if status_label != null:
        status_label.text = "• " + message
        _message_timer = seconds

func toggle_inventory_from_input() -> void:
    _toggle_inventory()

func select_hotbar_index(index: int) -> void:
    _select_hotbar(index)

func _toggle_inventory() -> void:
    inventory_panel.visible = not inventory_panel.visible
    if inventory_panel.visible and station_panel.visible:
        station_panel.visible = false
    inventory_pressed.emit()

func _select_hotbar(index: int) -> void:
    if index < 0 or index >= hotbar_ids.size():
        return
    selected_hotbar_index = index
    hotbar_index_changed.emit(index)
    var block_id := hotbar_ids[index]
    if block_id.is_empty():
        show_message("That hotbar slot is empty")
        return
    selected_block.emit(block_id)
    set_selected_block(block_id)

func _on_catalogue_item_selected(block_id: String) -> void:
    var defn := BlockRegistry.get_item_runtime(block_id)
    if not _creative_mode and (inventory_ref == null or not inventory_ref.has_method("has_item") or not bool(inventory_ref.call("has_item", block_id, 1))):
        show_message("You do not have that item in Survival mode")
        return
    selected_block.emit(block_id)
    set_selected_block(block_id)
    inventory_panel.visible = false
    if not BlockRegistry.get_place_block_id(block_id).is_empty():
        show_message("Selected " + str(defn.get("name", block_id)))
    else:
        show_message("Selected item: " + str(defn.get("name", block_id)))

func show_station(station_id: String) -> void:
    inventory_panel.visible = false
    station_panel.visible = true
    _station_title.text = station_id.replace("_", " ").to_upper()
    for child in station_items.get_children():
        child.queue_free()
    var recipes: Dictionary = RecipeRegistry.get_sample_recipes()
    if recipes.is_empty():
        show_message("No supported runtime recipes are loaded")
        return
    var any_recipe := false
    for key in recipes.keys():
        var recipe: Dictionary = recipes[key]
        var recipe_station := str(recipe.get("station", "inventory"))
        if station_id == "crafting_table":
            if recipe_station not in ["crafting_table", "inventory"]:
                continue
        elif station_id != "creative" and recipe_station != station_id:
            continue
        any_recipe = true
        var ingredients: Dictionary = recipe.get("ingredients", {})
        var ingredient_text := ""
        for item_id in ingredients.keys():
            if not ingredient_text.is_empty(): ingredient_text += " + "
            ingredient_text += "%s ×%s" % [BlockRegistry.get_item_name(str(item_id)), str(ingredients[item_id])]
        var verb := "Select" if _creative_mode else ("Smelt" if station_id == "furnace" else "Craft")
        var recipe_button := _make_button("%s ×%s · %s\n%s" % [BlockRegistry.get_item_name(str(recipe.get("result", key))), str(recipe.get("count", 1)), verb, ingredient_text], "Recipe_" + str(key), station_items, 400, 54, 12)
        if _creative_mode:
            recipe_button.pressed.connect(_choose_recipe.bind(str(recipe.get("result", key))))
        else:
            recipe_button.pressed.connect(func(): craft_requested.emit(str(key), station_id))
    if not any_recipe:
        var empty_label := Label.new()
        empty_label.text = "No recipes are assigned to this station yet."
        station_items.add_child(empty_label)

func show_container(cell_key: String, summary: String) -> void:
    inventory_panel.visible = false
    station_panel.visible = true
    _station_title.text = "CONTAINER STORAGE"
    for child in station_items.get_children():
        child.queue_free()
    var description := Label.new()
    description.text = summary
    description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    description.custom_minimum_size = Vector2(380, 90)
    station_items.add_child(description)
    var hint := Label.new()
    hint.text = "Choose an item in the catalogue/hotbar, then move one stack. Storage supports up to 27 item types."
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    station_items.add_child(hint)
    var deposit_button := _make_button("DEPOSIT SELECTED STACK", "ContainerDeposit", station_items, 400, 52, 14)
    deposit_button.pressed.connect(func(): container_action.emit("deposit", cell_key))
    var withdraw_button := _make_button("WITHDRAW SELECTED STACK", "ContainerWithdraw", station_items, 400, 52, 14)
    withdraw_button.pressed.connect(func(): container_action.emit("withdraw", cell_key))

func _choose_recipe(result_id: String) -> void:
    var defn := BlockRegistry.get_item_runtime(result_id)
    if not BlockRegistry.get_place_block_id(result_id).is_empty():
        chosen_block = result_id
        set_selected_block(result_id)
        selected_block.emit(result_id)
        show_message("Selected recipe output: " + str(defn.get("name", result_id)))
    else:
        show_message("Recipe output recorded: " + str(defn.get("name", result_id)))
