extends Node3D
class_name VoxelWorld

const ATLAS_PATH := "res://assets/textures/atlas.png"
const TILE_SIZE := 16
const CHUNK_SIZE := 16
const SEA_LEVEL := 63
const MIN_WORLD_Y := -64
const MAX_WORLD_Y := 319
const LOAD_RADIUS := 2 # Keep the resident mesh/collision budget appropriate for mobile.
const UNLOAD_MARGIN := 1
const MAX_CHUNKS_PER_FRAME := 1
const MAX_LOCAL_BLOCK_LIGHTS := 36
const BLOCK_LIGHT_SCAN_INTERVAL := 0.75
const FLUID_TICK_INTERVAL := 0.22
const REDSTONE_TICK_INTERVAL := 0.10
const DIRECTIONS: Array[Vector3i] = [
    Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
    Vector3i(0, 1, 0), Vector3i(0, -1, 0),
    Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]
const FACE_CORNERS: Array = [
    [Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],
    [Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],
    [Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],
    [Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],
    [Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1), Vector3(0,0,1)],
    [Vector3(0,0,0), Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0)]
]

# Only nearby chunks are resident in memory. The integer seed and sparse edit map
# define all other chunks, making horizontal travel effectively unbounded.
var blocks: Dictionary = {}
var modifications: Dictionary = {}
var modifications_by_chunk: Dictionary = {}
var block_states: Dictionary = {} # Cell-key -> state dictionary (facing, half, open, power, fluid level).
var surface_heights: Dictionary = {}
var terrain_height_cache: Dictionary = {}
var biome_cache: Dictionary = {}
var active_pressure_plates: Dictionary = {}
var fluid_active: Dictionary = {}
var _fluid_tick_accumulator := 0.0
var _crop_tick_accumulator := 0.0
var falling_queue: Array[Vector3i] = []
var falling_queued: Dictionary = {}
var _redstone_tick_accumulator := 0.0
var _redstone_dirty := true
var _button_expiry: Dictionary = {}
var chunk_cells: Dictionary = {}
var chunk_nodes: Dictionary = {}
var seed_value: int = 260326
var dimension_id: String = "overworld"
var biome_noise := FastNoiseLite.new()
var height_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()
var cave_noise := FastNoiseLite.new()
var atlas_material: StandardMaterial3D
var atlas_texture: Texture2D
var atlas_columns := 32
var atlas_rows := 19
var rebuilding := false
var streaming_center := Vector2i(0, 0)
var stream_queue: Array[Vector2i] = []
var _queued_coords: Dictionary = {}
var _generated_chunk_count := 0
var _block_light_nodes: Dictionary = {}
var _block_emission_cache: Dictionary = {}
var _block_light_scan_accumulator := 0.0

func _ready() -> void:
    BlockRegistry.load_data()
    atlas_texture = load(ATLAS_PATH) as Texture2D
    if atlas_texture != null:
        atlas_columns = maxi(1, atlas_texture.get_width() / TILE_SIZE)
        atlas_rows = maxi(1, atlas_texture.get_height() / TILE_SIZE)
        atlas_material = StandardMaterial3D.new()
        atlas_material.albedo_texture = atlas_texture
        atlas_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
        atlas_material.vertex_color_use_as_albedo = true
        atlas_material.roughness = 1.0
        atlas_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        atlas_material.cull_mode = BaseMaterial3D.CULL_BACK

func _process(delta: float) -> void:
    _fluid_tick_accumulator += delta
    _crop_tick_accumulator += delta
    _redstone_tick_accumulator += delta
    if _crop_tick_accumulator >= 6.0:
        _crop_tick_accumulator = 0.0
        _tick_crops(96)
    if _fluid_tick_accumulator >= FLUID_TICK_INTERVAL:
        _fluid_tick_accumulator = 0.0
        _tick_fluids(48)
        _tick_falling_blocks(64)
    _tick_transient_states(delta)
    if _redstone_tick_accumulator >= REDSTONE_TICK_INTERVAL:
        _redstone_tick_accumulator = 0.0
        if _redstone_dirty:
            _tick_redstone()
    var parent_node := get_parent()
    var light_target := Vector3.ZERO
    if parent_node != null:
        var player_node := parent_node.get_node_or_null("Player")
        if player_node is Node3D:
            light_target = player_node.global_position
            update_streaming(player_node.global_position)
    _block_light_scan_accumulator += delta
    if _block_light_scan_accumulator >= BLOCK_LIGHT_SCAN_INTERVAL:
        _block_light_scan_accumulator = 0.0
        _refresh_block_lights(light_target)
    var generated_this_frame := 0
    while not stream_queue.is_empty() and generated_this_frame < MAX_CHUNKS_PER_FRAME:
        var coord: Vector2i = stream_queue.pop_front()
        _queued_coords.erase(coord)
        if not chunk_nodes.has(coord) and _within_load_radius(coord, streaming_center):
            _load_chunk(coord)
            _refresh_chunk_and_neighbours(coord)
            generated_this_frame += 1

func generate_world(new_seed: int, new_dimension: String = "overworld") -> void:
    seed_value = new_seed
    dimension_id = new_dimension if new_dimension in ["overworld", "nether", "end"] else "overworld"
    blocks.clear()
    surface_heights.clear()
    terrain_height_cache.clear()
    biome_cache.clear()
    active_pressure_plates.clear()
    modifications.clear()
    modifications_by_chunk.clear()
    block_states.clear()
    fluid_active.clear()
    falling_queue.clear()
    falling_queued.clear()
    _fluid_tick_accumulator = 0.0
    _crop_tick_accumulator = 0.0
    _redstone_tick_accumulator = 0.0
    _redstone_dirty = true
    chunk_cells.clear()
    chunk_nodes.clear()
    stream_queue.clear()
    _queued_coords.clear()
    _generated_chunk_count = 0
    for child in get_children():
        remove_child(child)
        child.free()
    _configure_noise()
    streaming_center = Vector2i.ZERO
    # Load the spawn neighbourhood first so a player never begins inside an
    # empty/unloaded region. Further rings are streamed incrementally afterwards.
    for radius in range(0, 2):
        for cx in range(-radius, radius + 1):
            for cz in range(-radius, radius + 1):
                if maxi(absi(cx), absi(cz)) == radius:
                    _load_chunk(Vector2i(cx, cz))
    _refresh_all_loaded_chunk_meshes()
    _queue_chunks_around(streaming_center)

func prepare_position(world_position: Vector3) -> void:
    var center := Vector2i(floori(world_position.x / float(CHUNK_SIZE)), floori(world_position.z / float(CHUNK_SIZE)))
    streaming_center = center
    stream_queue.clear()
    _queued_coords.clear()
    var unload_coords: Array[Vector2i] = []
    for raw_coord in chunk_nodes.keys():
        var coord: Vector2i = raw_coord
        if not _within_radius(coord, center, LOAD_RADIUS + UNLOAD_MARGIN):
            unload_coords.append(coord)
    for coord in unload_coords:
        _unload_chunk(coord)
    # Load the immediate 3x3 neighbourhood synchronously so terrain collision
    # exists before the player starts physics at a saved/portal destination.
    for radius in range(0, 2):
        for cx in range(center.x - radius, center.x + radius + 1):
            for cz in range(center.y - radius, center.y + radius + 1):
                var coord := Vector2i(cx, cz)
                if maxi(absi(cx - center.x), absi(cz - center.y)) != radius:
                    continue
                if not chunk_nodes.has(coord):
                    _load_chunk(coord)
    _refresh_all_loaded_chunk_meshes()
    _queue_chunks_around(center)

func update_streaming(world_position: Vector3) -> void:
    var new_center := Vector2i(floori(world_position.x / float(CHUNK_SIZE)), floori(world_position.z / float(CHUNK_SIZE)))
    if new_center == streaming_center:
        return
    streaming_center = new_center
    _queue_chunks_around(streaming_center)
    var unload_coords: Array[Vector2i] = []
    for key in chunk_nodes.keys():
        var coord: Vector2i = key
        if not _within_radius(coord, streaming_center, LOAD_RADIUS + UNLOAD_MARGIN):
            unload_coords.append(coord)
    for coord in unload_coords:
        _unload_chunk(coord)

func _within_load_radius(coord: Vector2i, center: Vector2i) -> bool:
    return _within_radius(coord, center, LOAD_RADIUS)

func _within_radius(coord: Vector2i, center: Vector2i, radius: int) -> bool:
    return maxi(absi(coord.x - center.x), absi(coord.y - center.y)) <= radius

func _queue_chunks_around(center: Vector2i) -> void:
    stream_queue.clear()
    _queued_coords.clear()
    # Ring ordering means the terrain directly around the player appears first.
    for radius in range(0, LOAD_RADIUS + 1):
        for cx in range(center.x - radius, center.x + radius + 1):
            for cz in range(center.y - radius, center.y + radius + 1):
                var coord := Vector2i(cx, cz)
                if maxi(absi(cx - center.x), absi(cz - center.y)) != radius:
                    continue
                if not chunk_nodes.has(coord) and not _queued_coords.has(coord):
                    stream_queue.append(coord)
                    _queued_coords[coord] = true

func _create_chunk_nodes(coord: Vector2i) -> void:
    if chunk_nodes.has(coord):
        return
    var chunk_root := Node3D.new()
    chunk_root.name = "Chunk_%d_%d" % [coord.x, coord.y]
    add_child(chunk_root)
    var mesh_node := MeshInstance3D.new()
    mesh_node.name = "TerrainMesh"
    chunk_root.add_child(mesh_node)
    var body := StaticBody3D.new()
    body.name = "TerrainCollision"
    chunk_root.add_child(body)
    var shape := CollisionShape3D.new()
    shape.name = "CollisionShape"
    body.add_child(shape)
    chunk_nodes[coord] = {"root": chunk_root, "mesh": mesh_node, "body": body, "shape": shape}
    chunk_cells[coord] = {}

func _load_chunk(coord: Vector2i) -> void:
    if chunk_nodes.has(coord):
        return
    _create_chunk_nodes(coord)
    var x_start := coord.x * CHUNK_SIZE
    var z_start := coord.y * CHUNK_SIZE
    # First cache column heights for the entire chunk. Then materialize only
    # surface-visible cells. The previous implementation accumulated every solid
    # voxel in a temporary Dictionary (tens of thousands per chunk) before
    # discarding its interior, which caused avoidable mobile memory spikes.
    for x in range(x_start, x_start + CHUNK_SIZE):
        for z in range(z_start, z_start + CHUNK_SIZE):
            surface_heights[Vector2i(x, z)] = _terrain_height_at(x, z)
    for x in range(x_start, x_start + CHUNK_SIZE):
        for z in range(z_start, z_start + CHUNK_SIZE):
            var terrain_height := int(surface_heights[Vector2i(x, z)])
            var top_y := terrain_height
            if dimension_id == "overworld" and terrain_height < SEA_LEVEL:
                top_y = SEA_LEVEL
            elif dimension_id == "nether":
                top_y = 127
            for y in range(MIN_WORLD_Y, top_y + 1):
                var cell := Vector3i(x, y, z)
                var block_id := _base_block_at(cell)
                if block_id != "air" and _base_cell_has_visible_face(cell, block_id):
                    _write_generated_block(coord, cell, block_id)
    _generate_chunk_vegetation(coord)
    _generate_camp_piece_for_chunk(coord)
    _apply_chunk_modifications(coord)
    _generated_chunk_count += 1

func _base_block_at(cell: Vector3i) -> String:
    if dimension_id == "nether":
        return _nether_block_at(cell)
    if dimension_id == "end":
        return _end_block_at(cell)
    if cell.y < MIN_WORLD_Y or cell.y > MAX_WORLD_Y:
        return "air"
    var terrain_height := int(surface_heights.get(Vector2i(cell.x, cell.z), _terrain_height_at(cell.x, cell.z)))
    var biome := get_biome_at(cell.x, cell.z)
    if cell.y > terrain_height:
        if terrain_height < SEA_LEVEL and cell.y <= SEA_LEVEL:
            return "water"
        return "air"
    if cell.y <= MIN_WORLD_Y:
        return "bedrock"
    # Java-like irregular bedrock floor rather than a single uniform plane.
    if cell.y < MIN_WORLD_Y + 5:
        var bedrock_roll := absf(sin(float(cell.x * 73428767 + cell.z * 912931 + cell.y * 19349663 + seed_value)))
        if bedrock_roll > float(cell.y - MIN_WORLD_Y) / 6.0:
            return "bedrock"
    if cell.y < terrain_height - 4:
        if _is_cave_cell(cell):
            return "air"
        return _ore_or_stone(cell.x, cell.y, cell.z, _rng_for_cell(cell))
    if cell.y < terrain_height - 1:
        if biome in ["desert", "beach"]:
            return "sand"
        if biome == "badlands":
            return "red_sand"
        if biome == "swamp":
            return "mud"
        return "dirt"
    if cell.y < terrain_height:
        if biome in ["desert", "beach"]:
            return "sand"
        if biome == "badlands":
            return "red_sand"
        if biome == "swamp":
            return "mud"
        return "dirt"
    match biome:
        "desert", "beach": return "sand"
        "badlands": return "red_sand"
        "snowy": return "snow_block"
        "swamp": return "mud"
        _: return "grass_block"

func _nether_height_at(x: int, z: int) -> int:
    var broad := height_noise.get_noise_2d(float(x) * 0.7, float(z) * 0.7)
    var detail := detail_noise.get_noise_2d(float(x), float(z))
    return clampi(48 + int(broad * 14.0 + detail * 7.0), 32, 78)

func _nether_block_at(cell: Vector3i) -> String:
    if cell.y < MIN_WORLD_Y or cell.y > MAX_WORLD_Y:
        return "air"
    if cell.y <= MIN_WORLD_Y or (cell.y < MIN_WORLD_Y + 5 and absf(sin(float(cell.x * 19349663 + cell.z * 83492791 + cell.y + seed_value))) > float(cell.y - MIN_WORLD_Y) / 6.0):
        return "bedrock"
    # Nether ceiling has its own bedrock layer and leaves buildable space in between.
    if cell.y >= 123 and cell.y <= 127:
        var ceiling_roll := absf(sin(float(cell.x * 73856093 + cell.z * 912931 + cell.y + seed_value)))
        if cell.y >= 126 or ceiling_roll > float(127 - cell.y) / 5.0:
            return "bedrock"
    if cell.y > 127:
        return "air"
    if cell.y == 31:
        return "lava"
    var floor_height := _nether_height_at(cell.x, cell.z)
    if cell.y > floor_height:
        if cell.y <= 31:
            return "lava"
        return "air"
    if cell.y < floor_height - 4 and _is_cave_cell(cell):
        return "air"
    var hash_value := int(absf(sin(float(cell.x * 73856093 + cell.y * 19349663 + cell.z * 83492791 + seed_value)) * 100000.0)) % 1000
    if cell.y < floor_height - 1 and hash_value < 45:
        return "nether_gold_ore" if hash_value < 18 else "nether_quartz_ore" if BlockRegistry.has_block("nether_quartz_ore") else "netherrack"
    if cell.y < floor_height - 1:
        if hash_value < 85: return "blackstone" if hash_value < 48 else "basalt"
        return "netherrack"
    return "soul_sand" if hash_value < 140 else "netherrack"

func _end_block_at(cell: Vector3i) -> String:
    if cell.y < MIN_WORLD_Y or cell.y > MAX_WORLD_Y:
        return "air"
    var distance := Vector2(float(cell.x), float(cell.z)).length()
    var island_radius := 92.0 + height_noise.get_noise_2d(float(cell.x) * 0.55, float(cell.z) * 0.55) * 22.0
    var ring_distance := absf(fposmod(distance - 420.0, 560.0) - 280.0)
    var has_main_island := distance < island_radius
    var has_outer_island := distance > 160.0 and ring_distance < 42.0 and detail_noise.get_noise_2d(float(cell.x) * 0.09, float(cell.z) * 0.09) > -0.45
    if not has_main_island and not has_outer_island:
        return "air"
    if cell.y <= MIN_WORLD_Y:
        return "bedrock"
    var surface := 48 + int(height_noise.get_noise_2d(float(cell.x), float(cell.z)) * 9.0)
    if has_outer_island:
        surface += int(detail_noise.get_noise_2d(float(cell.x) * 0.2, float(cell.z) * 0.2) * 7.0)
    if cell.y > surface:
        return "air"
    if cell.y < surface - 4 and _is_cave_cell(cell):
        return "air"
    return "end_stone"

func _is_cave_cell(cell: Vector3i) -> bool:
    if cell.y < MIN_WORLD_Y + 6 or cell.y > _terrain_height_at(cell.x, cell.z) - 5:
        return false
    var broad := cave_noise.get_noise_3d(float(cell.x), float(cell.y), float(cell.z))
    var detail := detail_noise.get_noise_3d(float(cell.x) * 0.68, float(cell.y) * 0.8, float(cell.z) * 0.68)
    return broad + detail * 0.22 > 0.48

func _rng_for_cell(cell: Vector3i) -> RandomNumberGenerator:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(seed_value + cell.x * 73856093 + cell.y * 19349663 + cell.z * 83492791)
    return rng

func _base_cell_has_visible_face(cell: Vector3i, block_id: String) -> bool:
    var definition := BlockRegistry.get_block(block_id)
    var current_transparent := bool(definition.get("transparent", false))
    var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]
    for direction in directions:
        var neighbour_cell := cell + direction
        var neighbour_id := str(modifications.get(_cell_key(neighbour_cell), _base_block_at(neighbour_cell)))
        if blocks.has(neighbour_cell) and not modifications.has(_cell_key(neighbour_cell)):
            neighbour_id = str(blocks[neighbour_cell])
        if neighbour_id == "air":
            return true
        var neighbour_def := BlockRegistry.get_block(neighbour_id)
        var neighbour_transparent := bool(neighbour_def.get("transparent", false))
        var neighbour_solid := bool(neighbour_def.get("solid", false))
        if neighbour_id != block_id and (current_transparent or neighbour_transparent or not neighbour_solid):
            return true
    return false

func _write_generated_block(owner_chunk: Vector2i, cell: Vector3i, block_id: String) -> void:
    if _chunk_for_cell(cell) != owner_chunk:
        return
    blocks[cell] = block_id
    var index: Dictionary = chunk_cells[owner_chunk]
    index[cell] = true

func _unload_chunk(coord: Vector2i) -> void:
    if not chunk_nodes.has(coord):
        return
    var index: Dictionary = chunk_cells.get(coord, {})
    for key in index.keys():
        var cell: Vector3i = key
        blocks.erase(cell)
    var x_start := coord.x * CHUNK_SIZE
    var z_start := coord.y * CHUNK_SIZE
    for x in range(x_start, x_start + CHUNK_SIZE):
        for z in range(z_start, z_start + CHUNK_SIZE):
            var column := Vector2i(x, z)
            surface_heights.erase(column)
            terrain_height_cache.erase(column)
            biome_cache.erase(column)
            active_pressure_plates.erase(_cell_key(Vector3i(x, 0, z)))
    var chunk_info: Dictionary = chunk_nodes[coord]
    var root: Node = chunk_info["root"]
    remove_child(root)
    root.queue_free()
    chunk_nodes.erase(coord)
    chunk_cells.erase(coord)
    # Rebuild neighbouring boundary faces so unloaded terrain is visible from here.
    rebuilding = true
    for neighbour in [coord + Vector2i.LEFT, coord + Vector2i.RIGHT, coord + Vector2i.UP, coord + Vector2i.DOWN]:
        if chunk_nodes.has(neighbour):
            _rebuild_chunk_mesh(neighbour)
    rebuilding = false

func _configure_noise() -> void:
    height_noise.seed = seed_value + (17011 if dimension_id == "nether" else 25013 if dimension_id == "end" else 0)
    height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    height_noise.frequency = 0.0085
    detail_noise.seed = seed_value + 1031 + (17011 if dimension_id == "nether" else 25013 if dimension_id == "end" else 0)
    detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
    detail_noise.frequency = 0.035
    biome_noise.seed = seed_value + 4927 + (17011 if dimension_id == "nether" else 25013 if dimension_id == "end" else 0)
    biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    biome_noise.frequency = 0.0028
    cave_noise.seed = seed_value + 7919 + (17011 if dimension_id == "nether" else 25013 if dimension_id == "end" else 0)
    cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    cave_noise.frequency = 0.042

func _terrain_height_at(x: int, z: int) -> int:
    if dimension_id == "nether":
        return _nether_height_at(x, z)
    if dimension_id == "end":
        var d := Vector2(float(x), float(z)).length()
        var island_radius := 92.0 + height_noise.get_noise_2d(float(x) * 0.55, float(z) * 0.55) * 22.0
        var ring_distance := absf(fposmod(d - 420.0, 560.0) - 280.0)
        if d < island_radius or (d > 160.0 and ring_distance < 42.0 and detail_noise.get_noise_2d(float(x) * 0.09, float(z) * 0.09) > -0.45):
            return 48 + int(height_noise.get_noise_2d(float(x), float(z)) * 9.0)
        return MIN_WORLD_Y
    var column := Vector2i(x, z)
    if surface_heights.has(column):
        return int(surface_heights[column])
    if terrain_height_cache.has(column):
        return int(terrain_height_cache[column])
    var continental := height_noise.get_noise_2d(float(x), float(z))
    var detail := detail_noise.get_noise_2d(float(x) * 1.35, float(z) * 1.35)
    var biome := get_biome_at(x, z)
    var height := 63 + int(round(continental * 23.0 + detail * 7.0))
    if biome == "mountains":
        var ridge := 1.0 - absf(detail)
        height += int(30.0 + ridge * 105.0 + absf(continental) * 28.0)
    elif biome == "badlands":
        height += int(absf(detail) * 13.0)
    elif biome == "dappled_forest":
        height += int(detail * 3.0)
    elif biome == "swamp":
        height = 59 + int(round(continental * 5.0 + detail * 2.0))
    elif biome == "desert":
        height += int(absf(detail) * 5.0)
    height = clampi(height, MIN_WORLD_Y + 8, 280)
    terrain_height_cache[column] = height
    return height

func _chunk_seed(coord: Vector2i) -> int:
    return int(seed_value + coord.x * 73428767 + coord.y * 912931)

func get_biome_at(x: int, z: int) -> String:
    if dimension_id == "nether":
        var nether_climate := biome_noise.get_noise_2d(float(x) * 1.7, float(z) * 1.7)
        if nether_climate > 0.35: return "basalt_deltas"
        if nether_climate < -0.35: return "soul_sand_valley"
        return "nether_wastes"
    if dimension_id == "end":
        return "the_end"
    var column := Vector2i(x, z)
    if biome_cache.has(column):
        return str(biome_cache[column])
    var climate := biome_noise.get_noise_2d(float(x), float(z))
    var moisture := detail_noise.get_noise_2d(float(x) + 240.0, float(z) - 130.0)
    var elevation := height_noise.get_noise_2d(float(x), float(z))
    var result := "forest"
    if elevation > 0.55:
        result = "mountains"
    elif climate > 0.48:
        result = "desert"
    elif climate < -0.55:
        result = "snowy"
    elif climate > 0.18 and moisture > -0.1:
        result = "dappled_forest"
    elif moisture < -0.48:
        result = "swamp"
    elif climate > 0.32:
        result = "badlands"
    elif absf(climate) < 0.11:
        result = "plains"
    biome_cache[column] = result
    return result

func get_biome_display(x: int, z: int) -> String:
    match get_biome_at(x, z):
        "dappled_forest": return "Dappled Forest"
        "basalt_deltas": return "Basalt Deltas"
        "soul_sand_valley": return "Soul Sand Valley"
        "nether_wastes": return "Nether Wastes"
        "the_end": return "The End"
        "badlands": return "Red Badlands"
        "snowy": return "Snowy Plains"
        "desert": return "Desert"
        "swamp": return "Swamp"
        "mountains": return "Mountains"
        "beach": return "Beach"
        "plains": return "Plains"
        _: return "Forest"

func _ore_or_stone(x: int, y: int, z: int, rng: RandomNumberGenerator) -> String:
    var hash_value := int(absf(sin(float(x * 73856093 + y * 19349663 + z * 83492791 + seed_value)) * 100000.0)) % 1000
    if y < 5 and hash_value < 3:
        return "diamond_ore"
    if y < 9 and hash_value < 8:
        return "gold_ore"
    if hash_value < 21:
        return "iron_ore"
    if hash_value < 43:
        return "coal_ore"
    if hash_value < 48:
        return "copper_ore"
    return "stone"

func _generate_chunk_vegetation(coord: Vector2i) -> void:
    var x_start := coord.x * CHUNK_SIZE
    var z_start := coord.y * CHUNK_SIZE
    # Evaluate candidate tree centers in a two-block apron and only write cells
    # owned by this chunk. Tree crowns therefore join cleanly across chunk edges.
    for x in range(x_start - 2, x_start + CHUNK_SIZE + 2):
        for z in range(z_start - 2, z_start + CHUNK_SIZE + 2):
            var biome := get_biome_at(x, z)
            var top_y := _terrain_height_at(x, z)
            if top_y <= SEA_LEVEL:
                continue
            var rng := RandomNumberGenerator.new()
            rng.seed = int(seed_value + x * 73856093 + z * 19349663)
            var roll := rng.randi_range(0, 999)
            if biome == "desert" or biome == "badlands":
                if roll < 9:
                    var cactus_height := rng.randi_range(2, 4)
                    for cactus_y in range(1, cactus_height + 1):
                        _write_generated_block(coord, Vector3i(x, top_y + cactus_y, z), "cactus")
                continue
            var chance := 27 if biome in ["forest", "dappled_forest", "snowy"] else 8
            if biome == "dappled_forest" and roll < 4:
                var fallen_length := rng.randi_range(2, 4)
                for fallen_offset in range(fallen_length):
                    _write_generated_block(coord, Vector3i(x + fallen_offset, top_y + 1, z), "")
                _write_generated_block(coord, Vector3i(x + 1, top_y + 2, z), "shelf_mushroom")
            elif roll < chance:
                var tree_id := "oak"
                if biome == "dappled_forest": tree_id = "poplar"
                elif biome == "snowy": tree_id = "spruce"
                var trunk := rng.randi_range(4, 6)
                var log_id := "oak_log"
                var leaves_id := "oak_leaves"
                if tree_id == "poplar":
                    log_id = "poplar_log"
                    leaves_id = ["red_poplar_leaves", "orange_poplar_leaves", "yellow_poplar_leaves"][rng.randi_range(0, 2)]
                elif tree_id == "spruce":
                    log_id = "spruce_log"
                    leaves_id = "spruce_leaves"
                for ty in range(1, trunk + 1):
                    _write_generated_block(coord, Vector3i(x, top_y + ty, z), log_id)
                for ly in range(top_y + trunk - 2, top_y + trunk + 2):
                    var crown_radius := 2 if ly < top_y + trunk else 1
                    for lx in range(x - crown_radius, x + crown_radius + 1):
                        for lz in range(z - crown_radius, z + crown_radius + 1):
                            if abs(lx - x) + abs(lz - z) <= crown_radius + 1 and not (lx == x and lz == z and ly < top_y + trunk):
                                var leaf_cell := Vector3i(lx, ly, lz)
                                if _chunk_for_cell(leaf_cell) == coord and not blocks.has(leaf_cell):
                                    _write_generated_block(coord, leaf_cell, leaves_id)
            elif biome == "dappled_forest" and roll < 36:
                _write_generated_block(coord, Vector3i(x, top_y + 1, z), "red_shrub")
            elif biome == "dappled_forest" and roll < 45:
                _write_generated_block(coord, Vector3i(x, top_y + 1, z), "leaf_litter")
            elif biome == "dappled_forest" and roll < 48:
                _write_generated_block(coord, Vector3i(x, top_y + 1, z), "shelf_mushroom")
            elif roll < 55 and biome != "snowy":
                _write_generated_block(coord, Vector3i(x, top_y + 1, z), "short_grass")
            elif roll < 58 and biome in ["plains", "dappled_forest"]:
                _write_generated_block(coord, Vector3i(x, top_y + 1, z), "poppy" if rng.randf() < 0.5 else "dandelion")

func _generate_camp_piece_for_chunk(coord: Vector2i) -> void:
    var sx := 13
    var sz := -7
    var ground := _terrain_height_at(sx, sz)
    if get_biome_at(sx, sz) == "desert":
        sx = 9
        sz = 8
        ground = _terrain_height_at(sx, sz)
    if not _within_radius(coord, _chunk_for_cell(Vector3i(sx, 0, sz)), 1):
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value + 260326
    for dx in range(-2, 3):
        for dz in range(-2, 3):
            var cell := Vector3i(sx + dx, ground + 1, sz + dz)
            if abs(dx) == 2 or abs(dz) == 2:
                if rng.randf() < 0.65:
                    _write_generated_block(coord, cell, "coarse_dirt")
            elif rng.randf() < 0.4:
                _write_generated_block(coord, cell, "coarse_dirt")
    for data in [
        [Vector3i(sx, ground + 1, sz), "campfire"],
        [Vector3i(sx + 1, ground + 1, sz), "straw_bed"],
        [Vector3i(sx + 1, ground + 1, sz + 1), "cushion"],
        [Vector3i(sx - 1, ground + 1, sz + 1), "crafting_table"],
        [Vector3i(sx - 2, ground + 1, sz), "barrel"],
        [Vector3i(sx - 2, ground + 2, sz), "oak_log"],
        [Vector3i(sx + 2, ground + 1, sz + 1), "oak_log"]
    ]:
        var c: Vector3i = data[0]
        _write_generated_block(coord, c, str(data[1]))

func get_surface_y(x: int, z: int) -> int:
    var column := Vector2i(x, z)
    var surface := int(surface_heights.get(column, _terrain_height_at(x, z)))
    return surface + 1

func get_spawn_position() -> Vector3:
    if dimension_id == "nether":
        return Vector3(0.5, float(_nether_height_at(0, 0)) + 1.05, 0.5)
    if dimension_id == "end":
        return Vector3(0.5, float(_terrain_height_at(0, 0)) + 1.05, 0.5)
    for radius in range(0, CHUNK_SIZE - 1):
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                if maxi(absi(x), absi(z)) != radius:
                    continue
                var ground_y := int(surface_heights.get(Vector2i(x, z), _terrain_height_at(x, z)))
                if ground_y < SEA_LEVEL + 1:
                    continue
                var ground_id := get_block_id(Vector3i(x, ground_y, z))
                if not BlockRegistry.is_solid(ground_id):
                    continue
                var head_one := get_block_id(Vector3i(x, ground_y + 1, z))
                var head_two := get_block_id(Vector3i(x, ground_y + 2, z))
                if (head_one == "air" or not BlockRegistry.is_solid(head_one)) and (head_two == "air" or not BlockRegistry.is_solid(head_two)):
                    return Vector3(float(x) + 0.5, float(ground_y) + 1.05, float(z) + 0.5)
    return Vector3(0.5, float(get_surface_y(0, 0)) + 0.2, 0.5)

func grow_poplar_sapling(cell: Vector3i) -> bool:
    if get_block_id(cell) != "poplar_sapling":
        return false
    var rng := RandomNumberGenerator.new()
    rng.seed = seed_value + cell.x * 73856093 + cell.y * 19349663 + cell.z * 83492791
    var trunk_height := rng.randi_range(4, 5)
    var leaves_id: String = ["red_poplar_leaves", "orange_poplar_leaves", "yellow_poplar_leaves"][rng.randi_range(0, 2)]
    var dirty_cells: Array[Vector3i] = []
    _set_saved_block(cell, "air")
    dirty_cells.append(cell)
    for y_offset in range(0, trunk_height):
        var trunk_cell := cell + Vector3i(0, y_offset, 0)
        _set_saved_block(trunk_cell, "poplar_log")
        dirty_cells.append(trunk_cell)
    for layer in range(trunk_height - 2, trunk_height + 2):
        var crown_radius := 2 if layer < trunk_height else 1
        for x_offset in range(-crown_radius, crown_radius + 1):
            for z_offset in range(-crown_radius, crown_radius + 1):
                if abs(x_offset) + abs(z_offset) > crown_radius + 1:
                    continue
                var leaf_cell := cell + Vector3i(x_offset, layer, z_offset)
                if leaf_cell == cell + Vector3i(0, trunk_height - 1, 0):
                    continue
                var existing := get_block_id(leaf_cell)
                if existing != "air" and BlockRegistry.is_solid(existing):
                    continue
                _set_saved_block(leaf_cell, leaves_id)
                dirty_cells.append(leaf_cell)
    var dirty_chunks: Dictionary = {}
    for changed_cell in dirty_cells:
        _ensure_cell_chunk_loaded(changed_cell)
        var coord := _chunk_for_cell(changed_cell)
        dirty_chunks[coord] = true
        var local_x := changed_cell.x - coord.x * CHUNK_SIZE
        var local_z := changed_cell.z - coord.y * CHUNK_SIZE
        if local_x == 0: dirty_chunks[coord + Vector2i(-1, 0)] = true
        if local_x == CHUNK_SIZE - 1: dirty_chunks[coord + Vector2i(1, 0)] = true
        if local_z == 0: dirty_chunks[coord + Vector2i(0, -1)] = true
        if local_z == CHUNK_SIZE - 1: dirty_chunks[coord + Vector2i(0, 1)] = true
    rebuilding = true
    for coord in dirty_chunks.keys():
        if chunk_nodes.has(coord):
            _rebuild_chunk_mesh(coord)
    rebuilding = false
    return true

func _set_saved_block(cell: Vector3i, block_id: String) -> void:
    if cell.y < MIN_WORLD_Y or cell.y > MAX_WORLD_Y:
        return
    _ensure_cell_chunk_loaded(cell)
    var key := _cell_key(cell)
    var old_id := get_block_id(cell)
    if block_id == "air":
        blocks.erase(cell)
        block_states.erase(key)
        active_pressure_plates.erase(key)
        _button_expiry.erase(key)
        fluid_active.erase(key)
        _update_chunk_index_cell(cell, false)
    else:
        blocks[cell] = block_id
        _update_chunk_index_cell(cell, true)
        if old_id != block_id:
            block_states.erase(key)
    modifications[key] = block_id
    _index_modification(cell, block_id)
    if block_id in ["water", "lava"]:
        if not block_states.has(key):
            block_states[key] = {"level": 0, "source": true, "falling": false}
        fluid_active[key] = true
    else:
        fluid_active.erase(key)
    _mark_redstone_dirty_near(cell)
    _queue_falling_check(cell)
    _queue_falling_check(cell + Vector3i.UP)

func _mark_redstone_dirty_near(cell: Vector3i) -> void:
    var id := get_block_id(cell)
    if id in ["redstone_wire", "redstone_block", "lever", "stone_button", "poplar_button", "iron_door", "stone_pressure_plate", "poplar_pressure_plate", "heavy_weighted_pressure_plate", "light_weighted_pressure_plate", "repeater", "comparator", "redstone_lamp", "piston", "sticky_piston", "observer", "redstone_torch", "iron_door", "iron_trapdoor"]:
        _redstone_dirty = true
        return
    for direction in DIRECTIONS:
        var neighbour_id := get_block_id(cell + direction)
        if neighbour_id in ["redstone_wire", "redstone_block", "lever", "stone_button", "poplar_button", "stone_pressure_plate", "poplar_pressure_plate", "heavy_weighted_pressure_plate", "light_weighted_pressure_plate", "repeater", "comparator", "redstone_lamp", "piston", "sticky_piston", "observer", "redstone_torch", "iron_door", "iron_trapdoor"]:
            _redstone_dirty = true
            return

func _ensure_cell_chunk_loaded(cell: Vector3i) -> void:
    var coord := _chunk_for_cell(cell)
    if not chunk_nodes.has(coord):
        _load_chunk(coord)
        _rebuild_chunk_mesh(coord)

func get_block_id(cell: Vector3i) -> String:
    if cell.y < MIN_WORLD_Y or cell.y > MAX_WORLD_Y:
        return "air"
    var key := _cell_key(cell)
    if modifications.has(key):
        return str(modifications[key])
    var coord := _chunk_for_cell(cell)
    if not chunk_nodes.has(coord):
        return "air"
    if blocks.has(cell):
        return str(blocks[cell])
    return _base_block_at(cell)

func break_block(cell: Vector3i) -> String:
    var id := get_block_id(cell)
    if id == "air" or id == "bedrock" or cell.y <= MIN_WORLD_Y:
        return ""
    var state := get_block_state(cell)
    var linked_cell := cell
    if id.ends_with("_door") or id.ends_with("_trapdoor"):
        if str(state.get("half", "lower")) == "upper":
            linked_cell = cell + Vector3i.DOWN
        elif id.ends_with("_door"):
            linked_cell = cell + Vector3i.UP
    var cells_to_clear: Array[Vector3i] = [cell]
    if linked_cell != cell and get_block_id(linked_cell) == id:
        cells_to_clear.append(linked_cell)
    for changed in cells_to_clear:
        blocks.erase(changed)
        modifications[_cell_key(changed)] = "air"
        block_states.erase(_cell_key(changed))
        _button_expiry.erase(_cell_key(changed))
        active_pressure_plates.erase(_cell_key(changed))
        _index_modification(changed, "air")
        _update_chunk_index_cell(changed, false)
        _refresh_exposed_cells_near(changed)
        _rebuild_affected_chunks(changed)
        _queue_falling_check(changed + Vector3i.UP)
    _redstone_dirty = true
    return id

func explode_blocks(center: Vector3, radius: float) -> Array[Dictionary]:
    # Destruction is applied in one batch so a creeper blast rebuilds each
    # affected chunk at most once instead of rebuilding it for every block.
    var destroyed: Array[Dictionary] = []
    if radius <= 0.0:
        return destroyed
    var min_cell := Vector3i(floori(center.x - radius), floori(center.y - radius), floori(center.z - radius))
    var max_cell := Vector3i(floori(center.x + radius), floori(center.y + radius), floori(center.z + radius))
    var touched_chunks: Dictionary = {}
    var cells_to_refresh: Array[Vector3i] = []
    for x in range(min_cell.x, max_cell.x + 1):
        for y in range(maxi(min_cell.y, MIN_WORLD_Y + 1), mini(max_cell.y, MAX_WORLD_Y) + 1):
            for z in range(min_cell.z, max_cell.z + 1):
                var cell := Vector3i(x, y, z)
                if Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5).distance_to(center) > radius:
                    continue
                var coord := _chunk_for_cell(cell)
                # Blasts affect active nearby chunks only; unknown/unloaded chunks
                # are left untouched until they are loaded by world streaming.
                if not chunk_nodes.has(coord):
                    continue
                var block_id := get_block_id(cell)
                if block_id in ["", "air", "bedrock", "obsidian", "crying_obsidian", "ancient_debris", "end_portal_frame", "end_portal", "nether_portal"]:
                    continue
                var cells_to_clear: Array[Vector3i] = [cell]
                # Doors occupy two voxels but produce one drop. If either half is
                # caught in a blast, remove the linked half too.
                if block_id.ends_with("_door") and not block_id.ends_with("_trapdoor"):
                    var door_state := get_block_state(cell)
                    var linked_cell := cell + (Vector3i.DOWN if str(door_state.get("half", "lower")) == "upper" else Vector3i.UP)
                    if chunk_nodes.has(_chunk_for_cell(linked_cell)) and get_block_id(linked_cell) == block_id:
                        cells_to_clear.append(linked_cell)
                for changed_cell in cells_to_clear:
                    var changed_coord := _chunk_for_cell(changed_cell)
                    blocks.erase(changed_cell)
                    var changed_key := _cell_key(changed_cell)
                    modifications[changed_key] = "air"
                    block_states.erase(changed_key)
                    _button_expiry.erase(changed_key)
                    active_pressure_plates.erase(changed_key)
                    fluid_active.erase(changed_key)
                    _index_modification(changed_cell, "air")
                    _update_chunk_index_cell(changed_cell, false)
                    _queue_falling_check(changed_cell + Vector3i.UP)
                    cells_to_refresh.append(changed_cell)
                    touched_chunks[changed_coord] = true
                    var local_x := changed_cell.x - changed_coord.x * CHUNK_SIZE
                    var local_z := changed_cell.z - changed_coord.y * CHUNK_SIZE
                    if local_x == 0: touched_chunks[changed_coord + Vector2i(-1, 0)] = true
                    if local_x == CHUNK_SIZE - 1: touched_chunks[changed_coord + Vector2i(1, 0)] = true
                    if local_z == 0: touched_chunks[changed_coord + Vector2i(0, -1)] = true
                    if local_z == CHUNK_SIZE - 1: touched_chunks[changed_coord + Vector2i(0, 1)] = true
                destroyed.append({"id": block_id, "cell": cell})
    # Reveal deterministic terrain just behind exposed faces, then rebuild meshes once.
    for cell in cells_to_refresh:
        _refresh_exposed_cells_near(cell)
    _redstone_dirty = true
    rebuilding = true
    for coord in touched_chunks.keys():
        if chunk_nodes.has(coord):
            _rebuild_chunk_mesh(coord)
    rebuilding = false
    return destroyed

func place_block(cell: Vector3i, block_id: String, initial_state: Dictionary = {}) -> bool:
    if not BlockRegistry.has_block(block_id) or not BlockRegistry.is_placeable(block_id):
        return false
    if cell.y < MIN_WORLD_Y or cell.y > MAX_WORLD_Y:
        return false
    var coord := _chunk_for_cell(cell)
    if not chunk_nodes.has(coord):
        return false
    var current := get_block_id(cell)
    # Two compatible half-slabs combine into one full block instead of requiring
    # the player to break the first half manually.
    if current == block_id and block_id.ends_with("_slab"):
        var old_half := str(get_block_state(cell).get("half", "bottom"))
        var new_half := str(initial_state.get("half", "bottom"))
        if old_half != new_half and old_half != "double":
            _set_saved_block(cell, block_id)
            block_states[_cell_key(cell)] = {"half": "double"}
            _refresh_exposed_cells_near(cell)
            _rebuild_affected_chunks(cell)
            return true
        return false
    var current_shape := str(BlockRegistry.get_block(current).get("shape", "cube")) if current != "air" else "cube"
    var replaceable := current == "air" or current == "water" or current_shape in ["plant", "leaf_litter", "redstone_wire", "rail"]
    if not replaceable:
        return false
    var is_door := block_id.ends_with("_door") and not block_id.ends_with("_trapdoor")
    if is_door:
        var upper := cell + Vector3i.UP
        var support_id := get_block_id(cell + Vector3i.DOWN)
        if upper.y > MAX_WORLD_Y or get_block_id(upper) != "air":
            return false
        if support_id == "air" or not BlockRegistry.is_solid(support_id):
            return false
    if block_id in ["wheat", "carrots", "potatoes", "beetroots"] and get_block_id(cell + Vector3i.DOWN) != "farmland":
        return false
    var placement_shape := str(BlockRegistry.get_block(block_id).get("shape", "cube"))
    if placement_shape in ["torch", "redstone_wire", "rail", "stone_pressure_plate", "plant", "leaf_litter", "repeater", "comparator"]:
        var support_id := get_block_id(cell + Vector3i.DOWN)
        if support_id == "air" or not BlockRegistry.is_solid(support_id):
            return false
    if placement_shape in ["button", "lever"]:
        var has_support := false
        for support_direction in DIRECTIONS:
            var side_support := get_block_id(cell + support_direction)
            if side_support != "air" and BlockRegistry.is_solid(side_support):
                has_support = true
                break
        if not has_support:
            return false
    if block_id in ["sand", "red_sand", "gravel", "concrete_powder_white", "concrete_powder_orange", "concrete_powder_magenta", "concrete_powder_light_blue", "concrete_powder_yellow", "concrete_powder_lime", "concrete_powder_pink", "concrete_powder_gray", "concrete_powder_light_gray", "concrete_powder_cyan", "concrete_powder_purple", "concrete_powder_blue", "concrete_powder_brown", "concrete_powder_green", "concrete_powder_red", "concrete_powder_black"]:
        _queue_falling_check(cell)
    if block_id == "cushion":
        var support_id := get_block_id(cell + Vector3i.DOWN)
        if support_id == "air" or not BlockRegistry.is_solid(support_id):
            return false
        for neighbour in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]:
            if get_block_id(cell + neighbour) == "cushion":
                return false
    var state := initial_state.duplicate(true)
    if str(BlockRegistry.get_block(block_id).get("shape", "cube")) in ["slab", "stair", "door", "trapdoor", "fence_gate", "rail", "button", "lever", "repeater", "comparator", "observer"]:
        if not state.has("facing"):
            state["facing"] = "south"
        if block_id.ends_with("_slab") and not state.has("half"):
            state["half"] = "bottom"
        if block_id.ends_with("_stairs") and not state.has("half"):
            state["half"] = "bottom"
        if is_door and not state.has("half"):
            state["half"] = "lower"
        if block_id.ends_with("_trapdoor") and not state.has("half"):
            state["half"] = "bottom"
    _set_saved_block(cell, block_id)
    if not state.is_empty():
        block_states[_cell_key(cell)] = state
    if is_door:
        var upper_cell := cell + Vector3i.UP
        _set_saved_block(upper_cell, block_id)
        var upper_state := state.duplicate(true)
        upper_state["half"] = "upper"
        block_states[_cell_key(upper_cell)] = upper_state
        _update_chunk_index_cell(upper_cell, true)
    if block_id in ["water", "lava"]:
        block_states[_cell_key(cell)] = {"level": 0, "source": true}
        fluid_active[_cell_key(cell)] = true
    if block_id in ["lever", "stone_button", "poplar_button", "stone_pressure_plate", "poplar_pressure_plate", "redstone_wire", "redstone_block", "redstone_lamp", "piston", "sticky_piston"]:
        _redstone_dirty = true
    _refresh_exposed_cells_near(cell)
    _rebuild_affected_chunks(cell)
    if is_door:
        _refresh_exposed_cells_near(cell + Vector3i.UP)
        _rebuild_affected_chunks(cell + Vector3i.UP)
    return true

func apply_modifications(saved_mods: Dictionary, saved_states: Dictionary = {}, saved_fluids: Dictionary = {}) -> void:
    modifications = saved_mods.duplicate(true)
    block_states = saved_states.duplicate(true)
    fluid_active = saved_fluids.duplicate(true)
    _redstone_dirty = true
    _rebuild_modification_index()
    for key in modifications.keys():
        var parts := str(key).split(",")
        if parts.size() != 3:
            continue
        var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
        var coord := _chunk_for_cell(cell)
        if not chunk_nodes.has(coord):
            continue
        var value := str(modifications[key])
        if value == "air":
            blocks.erase(cell)
        elif BlockRegistry.has_block(value):
            blocks[cell] = value
    _rebuild_chunk_index()
    rebuild_mesh()

func get_save_data() -> Dictionary:
    return {"format": 5, "seed": seed_value, "dimension": dimension_id, "modified": modifications.duplicate(true), "block_states": block_states.duplicate(true), "fluid_active": fluid_active.duplicate(true)}

func _tick_transient_states(delta: float) -> void:
    var touched_chunks: Dictionary = {}
    for key in _button_expiry.keys():
        _button_expiry[key] = float(_button_expiry[key]) - delta
        if float(_button_expiry[key]) <= 0.0:
            _button_expiry.erase(key)
            var parts := str(key).split(",")
            if parts.size() != 3: continue
            var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
            var state := get_block_state(cell)
            state["powered"] = false
            block_states[key] = state
            _redstone_dirty = true
            _mark_chunk_mesh_updates(cell, touched_chunks)
    # Repeater delays and observer pulses are saved in block state, so a save/reload
    # does not silently lose their pending transition. This is a local simulation,
    # not Java's complete scheduled block-tick engine.
    for raw_key in block_states.keys():
        var key := str(raw_key)
        var state_raw: Variant = block_states.get(key, {})
        if not state_raw is Dictionary:
            continue
        var state: Dictionary = state_raw.duplicate(true)
        if state.has("delay_remaining"):
            state["delay_remaining"] = float(state["delay_remaining"]) - delta
            if float(state["delay_remaining"]) <= 0.0:
                state["powered"] = bool(state.get("pending_power", false))
                state["power"] = 15 if bool(state["powered"]) else 0
                state.erase("pending_power")
                state.erase("delay_remaining")
                _redstone_dirty = true
                var repeater_cell := _cell_from_key(key)
                _mark_chunk_mesh_updates(repeater_cell, touched_chunks)
            block_states[key] = state
        elif state.has("pulse_remaining"):
            state["pulse_remaining"] = float(state["pulse_remaining"]) - delta
            if float(state["pulse_remaining"]) <= 0.0:
                state["powered"] = false
                state["power"] = 0
                state.erase("pulse_remaining")
                _redstone_dirty = true
                var observer_cell := _cell_from_key(key)
                _mark_chunk_mesh_updates(observer_cell, touched_chunks)
            block_states[key] = state
    rebuilding = true
    for coord in touched_chunks.keys():
        if chunk_nodes.has(coord):
            _rebuild_chunk_mesh(coord)
    rebuilding = false

func _cell_from_key(key: String) -> Vector3i:
    var parts := key.split(",")
    if parts.size() != 3:
        return Vector3i.ZERO
    return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))

func update_player_contacts(player_position: Vector3) -> void:
    update_entity_contacts([player_position])

func update_entity_contacts(entity_positions: Array[Vector3]) -> void:
    var candidates: Dictionary = {}
    var plate_ids := ["stone_pressure_plate", "poplar_pressure_plate", "heavy_weighted_pressure_plate", "light_weighted_pressure_plate"]
    for entity_position in entity_positions:
        var feet_cell := Vector3i(floori(entity_position.x), floori(entity_position.y), floori(entity_position.z))
        for x in range(feet_cell.x - 1, feet_cell.x + 2):
            for y in range(feet_cell.y - 1, feet_cell.y + 1):
                for z in range(feet_cell.z - 1, feet_cell.z + 2):
                    var cell := Vector3i(x, y, z)
                    var id := get_block_id(cell)
                    if id not in plate_ids:
                        continue
                    var dx := (float(cell.x) + 0.5) - entity_position.x
                    var dz := (float(cell.z) + 0.5) - entity_position.z
                    var standing_height := float(cell.y) + 1.0
                    var active := absf(dx) < 0.43 and absf(dz) < 0.43 and absf(entity_position.y - standing_height) < 0.28
                    var key := _cell_key(cell)
                    candidates[key] = bool(candidates.get(key, false)) or active
    for raw_key in candidates.keys():
        var key := str(raw_key)
        var parts := key.split(",")
        if parts.size() != 3:
            continue
        var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
        var active := bool(candidates[key])
        var state := get_block_state(cell)
        if bool(state.get("powered", false)) != active:
            state["powered"] = active
            block_states[key] = state
            _redstone_dirty = true
        if active:
            active_pressure_plates[key] = true
    for raw_key in active_pressure_plates.keys():
        var key := str(raw_key)
        if candidates.get(key, false):
            continue
        var parts := key.split(",")
        if parts.size() == 3:
            var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
            var state := get_block_state(cell)
            if bool(state.get("powered", false)):
                state["powered"] = false
                block_states[key] = state
                _redstone_dirty = true
        active_pressure_plates.erase(key)

func get_block_state(cell: Vector3i) -> Dictionary:
    var raw_state: Variant = block_states.get(_cell_key(cell), {})
    if raw_state is Dictionary:
        return raw_state.duplicate(true)
    return {}

func set_block_state(cell: Vector3i, state: Dictionary) -> void:
    var key := _cell_key(cell)
    if state.is_empty():
        block_states.erase(key)
    else:
        block_states[key] = state.duplicate(true)
    if get_block_id(cell) in ["water", "lava"]:
        fluid_active[key] = true
    _mark_redstone_dirty_near(cell)
    _rebuild_affected_chunks(cell)

func toggle_block(cell: Vector3i) -> bool:
    var id := get_block_id(cell)
    var state := get_block_state(cell)
    if id == "lever":
        state["powered"] = not bool(state.get("powered", false))
        set_block_state(cell, state)
        return true
    if id in ["stone_button", "poplar_button", "tripwire_hook"]:
        state["powered"] = true
        set_block_state(cell, state)
        _button_expiry[_cell_key(cell)] = 0.8
        return true
    if id == "repeater":
        state["delay"] = posmod(int(state.get("delay", 1)), 4) + 1
        set_block_state(cell, state)
        return true
    if id == "comparator":
        state["mode"] = "subtract" if str(state.get("mode", "compare")) == "compare" else "compare"
        set_block_state(cell, state)
        return true
    if id == "iron_door" or id == "iron_trapdoor":
        return false # iron versions only respond to redstone power
    if id.ends_with("_door") or id.ends_with("_trapdoor") or id.ends_with("_fence_gate"):
        var open_now := not bool(state.get("open", false))
        if id.ends_with("_door") and not id.ends_with("_trapdoor"):
            var other_cell := cell + (Vector3i.DOWN if str(state.get("half", "lower")) == "upper" else Vector3i.UP)
            if get_block_id(other_cell) == id:
                var other_state := get_block_state(other_cell)
                state["open"] = open_now
                if not state.has("facing"):
                    state["facing"] = "north"
                other_state["open"] = open_now
                if not other_state.has("facing"):
                    other_state["facing"] = str(state["facing"])
                block_states[_cell_key(cell)] = state.duplicate(true)
                block_states[_cell_key(other_cell)] = other_state.duplicate(true)
                _rebuild_affected_chunks(cell)
                _rebuild_affected_chunks(other_cell)
                return true
        state["open"] = open_now
        if not state.has("facing"):
            state["facing"] = "north"
        set_block_state(cell, state)
        return true
    if id in ["furnace", "crafting_table", "barrel", "chest"]:
        return true
    return false

func activate_nether_portal(frame_cell: Vector3i) -> bool:
    if get_block_id(frame_cell) != "obsidian":
        return false
    # Search the legal small-to-medium portal rectangles around the clicked frame
    # block. The portal is represented as persistent blocks, not a visual effect.
    for along_x in [true, false]:
        var tangent := frame_cell.x if along_x else frame_cell.z
        for width in range(4, 11):
            for height in range(5, 11):
                for start_tangent in range(tangent - width + 1, tangent + 1):
                    var rel_tangent := tangent - start_tangent
                    for start_y in range(frame_cell.y - height + 1, frame_cell.y + 1):
                        var rel_y := frame_cell.y - start_y
                        if not (rel_tangent == 0 or rel_tangent == width - 1 or rel_y == 0 or rel_y == height - 1):
                            continue
                        var valid := true
                        for u in range(width):
                            for v in range(height):
                                var border := u == 0 or u == width - 1 or v == 0 or v == height - 1
                                if not border or ((u == 0 or u == width - 1) and (v == 0 or v == height - 1)):
                                    continue # vanilla portals do not require corner blocks
                                var check_cell := Vector3i(start_tangent + u, start_y + v, frame_cell.z) if along_x else Vector3i(frame_cell.x, start_y + v, start_tangent + u)
                                if get_block_id(check_cell) != "obsidian":
                                    valid = false
                                    break
                            if not valid:
                                break
                        if not valid:
                            continue
                        var changed: Array[Vector3i] = []
                        for u in range(1, width - 1):
                            for v in range(1, height - 1):
                                var portal_cell := Vector3i(start_tangent + u, start_y + v, frame_cell.z) if along_x else Vector3i(frame_cell.x, start_y + v, start_tangent + u)
                                if get_block_id(portal_cell) != "air":
                                    valid = false
                                    break
                                changed.append(portal_cell)
                            if not valid:
                                break
                        if not valid:
                            continue
                        for portal_cell in changed:
                            _set_saved_block(portal_cell, "nether_portal")
                            block_states[_cell_key(portal_cell)] = {"axis": "x" if along_x else "z"}
                        for portal_cell in changed:
                            _refresh_exposed_cells_near(portal_cell)
                            _rebuild_affected_chunks(portal_cell)
                        return true
    return false

func use_end_portal_frame(frame_cell: Vector3i) -> bool:
    if get_block_id(frame_cell) != "end_portal_frame":
        return false
    # Find the 5x5 frame centered around the clicked block; each of the twelve
    # frame blocks stores its eye state independently and persists through saves.
    for center_x in range(frame_cell.x - 2, frame_cell.x + 3):
        for center_z in range(frame_cell.z - 2, frame_cell.z + 3):
            var dx := frame_cell.x - center_x
            var dz := frame_cell.z - center_z
            if max(abs(dx), abs(dz)) != 2 or (abs(dx) == 2 and abs(dz) == 2):
                continue
            var frame_y := frame_cell.y
            var valid := true
            for xoff in range(-2, 3):
                for zoff in range(-2, 3):
                    if max(abs(xoff), abs(zoff)) != 2 or (abs(xoff) == 2 and abs(zoff) == 2):
                        continue
                    if get_block_id(Vector3i(center_x + xoff, frame_y, center_z + zoff)) != "end_portal_frame":
                        valid = false
                        break
                if not valid:
                    break
            if not valid:
                continue
            var key := _cell_key(frame_cell)
            var state := get_block_state(frame_cell)
            state["eye"] = true
            block_states[key] = state
            var complete := true
            for xoff in range(-2, 3):
                for zoff in range(-2, 3):
                    if max(abs(xoff), abs(zoff)) != 2 or (abs(xoff) == 2 and abs(zoff) == 2):
                        continue
                    var frame_state := get_block_state(Vector3i(center_x + xoff, frame_y, center_z + zoff))
                    if not bool(frame_state.get("eye", false)):
                        complete = false
            if complete:
                for xoff in range(-1, 2):
                    for zoff in range(-1, 2):
                        if get_block_id(Vector3i(center_x + xoff, frame_y, center_z + zoff)) not in ["air", "fire"]:
                            complete = false
                if not complete:
                    continue
                for xoff in range(-1, 2):
                    for zoff in range(-1, 2):
                        var portal_cell := Vector3i(center_x + xoff, frame_y, center_z + zoff)
                        _set_saved_block(portal_cell, "end_portal")
                for xoff in range(-1, 2):
                    for zoff in range(-1, 2):
                        _refresh_exposed_cells_near(Vector3i(center_x + xoff, frame_y, center_z + zoff))
                rebuild_mesh()
            else:
                _rebuild_affected_chunks(frame_cell)
            return true
    var fallback_state := get_block_state(frame_cell)
    fallback_state["eye"] = true
    set_block_state(frame_cell, fallback_state)
    return true

func _refresh_exposed_cells_near(cell: Vector3i) -> void:
    # Mining an exposed surface can reveal previously procedural, unallocated
    # blocks behind it. Materialize just that local neighbourhood into the mesh cache.
    var affected_cells: Array[Vector3i] = [cell]
    for direction in DIRECTIONS:
        affected_cells.append(cell + direction)
    for candidate in affected_cells:
        var coord := _chunk_for_cell(candidate)
        if not chunk_nodes.has(coord) or modifications.has(_cell_key(candidate)):
            continue
        var base_id := _base_block_at(candidate)
        var cached_id := str(blocks.get(candidate, ""))
        if base_id != "air" and _base_cell_has_visible_face(candidate, base_id):
            if cached_id.is_empty() or cached_id == base_id:
                blocks[candidate] = base_id
                _update_chunk_index_cell(candidate, true)
        elif not cached_id.is_empty() and cached_id == base_id:
            blocks.erase(candidate)
            _update_chunk_index_cell(candidate, false)

func _tick_crops(max_steps: int) -> void:
    # Deterministic block-state-based crop aging. Crops only grow when planted on
    # farmland with clear space above; state persists in the world save.
    var crop_ids := ["wheat", "carrots", "potatoes", "beetroots"]
    var candidates: Array[Vector3i] = []
    for raw_cell in blocks.keys():
        var cell: Vector3i = raw_cell
        if get_block_id(cell) in crop_ids:
            candidates.append(cell)
    var processed := 0
    for cell in candidates:
        if processed >= max_steps:
            break
        processed += 1
        if get_block_id(cell + Vector3i.DOWN) != "farmland" or get_block_id(cell + Vector3i.UP) != "air":
            continue
        var state := get_block_state(cell)
        var age := clampi(int(state.get("age", 0)), 0, 7)
        if age >= 7 or randf() >= 0.24:
            continue
        state["age"] = age + 1
        set_block_state(cell, state)

func _tick_fluids(max_steps: int) -> void:
    if fluid_active.is_empty():
        return
    var keys: Array = fluid_active.keys()
    var processed := 0
    for raw_key in keys:
        if processed >= max_steps:
            break
        var key := str(raw_key)
        var parts := key.split(",")
        if parts.size() != 3:
            fluid_active.erase(key)
            continue
        var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
        # Unloaded regions pause their local fluid simulation. Keep the active
        # key so the flow resumes when the player returns to that chunk.
        if not chunk_nodes.has(_chunk_for_cell(cell)):
            continue
        fluid_active.erase(key)
        var fluid_id := get_block_id(cell)
        if fluid_id not in ["water", "lava"]:
            continue
        processed += 1
        var state := get_block_state(cell)
        var level := int(state.get("level", 0))
        var source := bool(state.get("source", level == 0))
        var below := cell + Vector3i.DOWN
        var below_id := get_block_id(below)
        if below.y >= MIN_WORLD_Y and (below_id == "air" or _is_replaceable_fluid_target(below_id)):
            _flow_into(below, fluid_id, 8, false, source)
            fluid_active[key] = true
            continue
        if below_id in ["water", "lava"] and below_id != fluid_id:
            _flow_into(below, fluid_id, 8, false, source)
            continue
        var falling := bool(state.get("falling", false)) or level == 8
        if level >= 7 and not falling:
            continue
        var next_level := 1 if source or falling else level + (2 if fluid_id == "lava" else 1)
        if next_level > 7:
            continue
        var retry_at_chunk_edge := false
        for direction in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]:
            var target: Vector3i = cell + direction
            if not chunk_nodes.has(_chunk_for_cell(target)):
                retry_at_chunk_edge = true
                continue
            var target_id := get_block_id(target)
            if target_id == "air" or _is_replaceable_fluid_target(target_id) or (target_id in ["water", "lava"] and target_id != fluid_id):
                _flow_into(target, fluid_id, next_level, false, source)
        if source and retry_at_chunk_edge:
            # Resume flow into a neighboring chunk as soon as it is streamed in.
            fluid_active[key] = true
        if fluid_id == "water" and not source:
            var source_neighbours := 0
            for direction in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]:
                var neighbour: Vector3i = cell + direction
                if get_block_id(neighbour) == "water" and bool(get_block_state(neighbour).get("source", false)):
                    source_neighbours += 1
            if source_neighbours >= 2 and below_id != "air" and not _is_replaceable_fluid_target(below_id):
                set_block_state(cell, {"level": 0, "source": true, "falling": false})
                fluid_active[key] = true

func _is_replaceable_fluid_target(block_id: String) -> bool:
    if block_id in ["water", "lava"]:
        return false
    return str(BlockRegistry.get_block(block_id).get("shape", "cube")) in ["plant", "leaf_litter"]

func _flow_into(cell: Vector3i, fluid_id: String, level: int, source: bool, came_from_source: bool = false) -> void:
    # Fluids only update in resident chunks; a source cannot recursively load and
    # flood the entire effectively infinite world while the player is elsewhere.
    if not chunk_nodes.has(_chunk_for_cell(cell)):
        return
    var old_id := get_block_id(cell)
    if old_id in ["water", "lava"] and old_id != fluid_id:
        # Water/lava contacts yield obsidian for source lava, cobblestone for
        # flowing lava, and stone when water reaches a lava fluid block.
        var old_state := get_block_state(cell)
        var lava_is_source := false
        if old_id == "lava":
            lava_is_source = bool(old_state.get("source", int(old_state.get("level", 8)) == 0)) or int(old_state.get("level", 8)) == 0
        elif fluid_id == "lava":
            # A lava block flowing into water is itself not a source, even if it
            # ultimately originated at a source several blocks away.
            lava_is_source = source
        var reaction := "obsidian" if lava_is_source else "cobblestone"
        _set_saved_block(cell, reaction)
        block_states.erase(_cell_key(cell))
        fluid_active.erase(_cell_key(cell))
        _refresh_exposed_cells_near(cell)
        _rebuild_affected_chunks(cell)
        return
    if old_id == fluid_id:
        var existing_state := get_block_state(cell)
        if int(existing_state.get("level", 8)) <= level and not bool(existing_state.get("falling", false)):
            return
    elif not _is_replaceable_fluid_target(old_id) and old_id != "air":
        return
    _set_saved_block(cell, fluid_id)
    set_block_state(cell, {"level": level, "source": source, "falling": level == 8})
    fluid_active[_cell_key(cell)] = true
    for direction in DIRECTIONS:
        var neighbour := cell + direction
        if get_block_id(neighbour) == fluid_id:
            fluid_active[_cell_key(neighbour)] = true
    _refresh_exposed_cells_near(cell)
    _rebuild_affected_chunks(cell)

func _queue_falling_check(cell: Vector3i) -> void:
    if not chunk_nodes.has(_chunk_for_cell(cell)):
        return
    var id := get_block_id(cell)
    if id not in ["sand", "red_sand", "gravel"] and not id.begins_with("concrete_powder_"):
        return
    var key := _cell_key(cell)
    if falling_queued.has(key):
        return
    falling_queued[key] = true
    falling_queue.append(cell)

func _tick_falling_blocks(max_steps: int) -> void:
    var processed := 0
    while not falling_queue.is_empty() and processed < max_steps:
        var cell: Vector3i = falling_queue.pop_front()
        var key := _cell_key(cell)
        falling_queued.erase(key)
        processed += 1
        var block_id := get_block_id(cell)
        if block_id not in ["sand", "red_sand", "gravel"] and not block_id.begins_with("concrete_powder_"):
            continue
        var below := cell + Vector3i.DOWN
        var below_id := get_block_id(below)
        if below.y < MIN_WORLD_Y or (below_id != "air" and below_id not in ["water", "lava"] and not _is_replaceable_fluid_target(below_id)):
            continue
        var moved_state := get_block_state(cell)
        _set_saved_block(cell, "air")
        _set_saved_block(below, block_id)
        if not moved_state.is_empty():
            block_states[_cell_key(below)] = moved_state
        _refresh_exposed_cells_near(cell)
        _refresh_exposed_cells_near(below)
        _rebuild_affected_chunks(cell)
        _rebuild_affected_chunks(below)
        _queue_falling_check(below)

func _redstone_signal_to(source_cell: Vector3i, target_cell: Vector3i) -> int:
    var id := get_block_id(source_cell)
    var state := get_block_state(source_cell)
    if id == "redstone_block":
        return 15
    if id == "redstone_wire":
        return clampi(int(state.get("power", 0)), 0, 15)
    if id == "repeater":
        var repeater_signal_facing := _facing_vector(str(state.get("facing", "south")))
        return 15 if target_cell - source_cell == repeater_signal_facing and bool(state.get("powered", false)) else 0
    if id == "comparator":
        var comparator_signal_facing := _facing_vector(str(state.get("facing", "south")))
        return clampi(int(state.get("power", 0)), 0, 15) if target_cell - source_cell == comparator_signal_facing else 0
    if id == "observer":
        var observer_signal_facing := _facing_vector(str(state.get("facing", "south")))
        return 15 if target_cell - source_cell == -observer_signal_facing and bool(state.get("powered", false)) else 0
    if id == "redstone_torch":
        return 15
    if id in ["lever", "stone_button", "poplar_button", "stone_pressure_plate", "poplar_pressure_plate", "heavy_weighted_pressure_plate", "light_weighted_pressure_plate"] and bool(state.get("powered", false)):
        return 15
    return 0

func notify_container_contents_changed(_cell: Vector3i) -> void:
    # Comparator outputs are reevaluated on the next redstone tick when a
    # chest/barrel's stored stacks change.
    _redstone_dirty = true

func _container_signal_strength(cell: Vector3i) -> int:
    var parent_node := get_parent()
    if parent_node == null:
        return 0
    var raw_containers: Variant = parent_node.get("containers")
    if not raw_containers is Dictionary:
        return 0
    var contents_value: Variant = raw_containers.get(_cell_key(cell), {})
    if not contents_value is Dictionary:
        return 0
    var contents: Dictionary = contents_value
    if contents.is_empty():
        return 0
    var inventory_value: Variant = parent_node.get("inventory")
    var fullness := 0.0
    for raw_item_id in contents.keys():
        var item_id := str(raw_item_id)
        var default_max := 64
        if inventory_value is Object and inventory_value.has_method("_max_stack"):
            default_max = maxi(1, int(inventory_value.call("_max_stack", item_id)))
        var count := clampi(int(contents[raw_item_id]), 0, default_max)
        fullness += float(count) / float(default_max)
    # This storage UI holds one stack per item type, with 27 type slots.
    # Convert normalized fullness to Minecraft's comparator range 1–15.
    return clampi(floori((fullness / 27.0) * 14.0) + 1, 1, 15)

func _tick_redstone() -> void:
    _redstone_dirty = false
    var nodes: Array[Vector3i] = []
    var dust_nodes: Array[Vector3i] = []
    var dirty_mesh_chunks: Dictionary = {}
    for raw_cell in blocks.keys():
        var cell: Vector3i = raw_cell
        var id := get_block_id(cell)
        if id in ["redstone_wire", "redstone_block", "lever", "stone_button", "poplar_button", "stone_pressure_plate", "poplar_pressure_plate", "heavy_weighted_pressure_plate", "light_weighted_pressure_plate", "repeater", "comparator", "redstone_lamp", "piston", "sticky_piston", "observer", "redstone_torch", "iron_door", "iron_trapdoor"]:
            nodes.append(cell)
            if id == "redstone_wire": dust_nodes.append(cell)
    # Repeated relaxation carries diminishing power along basic dust lines.
    # Repeater/comparator/observer behaviour below is first-pass, not Java parity.
    for _pass in range(15):
        var changed := false
        for cell in dust_nodes:
            var power := 0
            for direction in DIRECTIONS:
                var neighbour := cell + direction
                var neighbour_id := get_block_id(neighbour)
                var neighbour_state := get_block_state(neighbour)
                var direct_power := _redstone_signal_to(neighbour, cell)
                power = maxi(power, direct_power)
                if neighbour_id == "redstone_wire":
                    power = maxi(power, maxi(0, int(neighbour_state.get("power", 0)) - 1))
            var state := get_block_state(cell)
            if int(state.get("power", 0)) != power:
                state["power"] = power
                block_states[_cell_key(cell)] = state
                changed = true
                _mark_chunk_mesh_updates(cell, dirty_mesh_chunks)
        if not changed: break
    for cell in nodes:
        var id := get_block_id(cell)
        var state := get_block_state(cell)
        if id == "repeater":
            var repeater_facing := _facing_vector(str(state.get("facing", "south")))
            var back_cell := cell - repeater_facing
            var input_power := _redstone_signal_to(back_cell, cell)
            var repeater_side := Vector3i(repeater_facing.z, 0, -repeater_facing.x)
            var side_power := maxi(_redstone_signal_to(cell + repeater_side, cell), _redstone_signal_to(cell - repeater_side, cell))
            var candidate_power := 15 if input_power > 0 and side_power == 0 else 0
            var current_power := int(state.get("power", 0))
            if candidate_power != current_power:
                if int(state.get("pending_power", -1)) != candidate_power:
                    state["pending_power"] = candidate_power
                    state["delay_remaining"] = float(clampi(int(state.get("delay", 1)), 1, 4)) * 0.1
                    block_states[_cell_key(cell)] = state
            elif state.has("pending_power"):
                state.erase("pending_power")
                state.erase("delay_remaining")
                block_states[_cell_key(cell)] = state
        elif id == "comparator":
            var comparator_facing := _facing_vector(str(state.get("facing", "south")))
            var comparator_input_cell := cell - comparator_facing
            var main_power := _redstone_signal_to(comparator_input_cell, cell)
            if get_block_id(comparator_input_cell) in ["chest", "barrel"]:
                main_power = _container_signal_strength(comparator_input_cell)
            var comparator_side := Vector3i(comparator_facing.z, 0, -comparator_facing.x)
            var side_power := maxi(_redstone_signal_to(cell + comparator_side, cell), _redstone_signal_to(cell - comparator_side, cell))
            var comparator_output := main_power if str(state.get("mode", "compare")) == "compare" and main_power >= side_power else (maxi(0, main_power - side_power) if str(state.get("mode", "compare")) == "subtract" else 0)
            if int(state.get("power", 0)) != comparator_output:
                state["power"] = comparator_output
                state["powered"] = comparator_output > 0
                block_states[_cell_key(cell)] = state
                _redstone_dirty = true
                _mark_chunk_mesh_updates(cell, dirty_mesh_chunks)
        elif id == "observer":
            var observer_facing := _facing_vector(str(state.get("facing", "south")))
            var observed_cell := cell + observer_facing
            var observed_state := get_block_state(observed_cell)
            var signature := get_block_id(observed_cell) + "|" + JSON.stringify(observed_state)
            var previous_signature := str(state.get("observed_signature", signature))
            if previous_signature != signature and not state.has("pulse_remaining"):
                state["powered"] = true
                state["power"] = 15
                state["pulse_remaining"] = 0.2
                block_states[_cell_key(cell)] = state
                _redstone_dirty = true
                _mark_chunk_mesh_updates(cell, dirty_mesh_chunks)
            state["observed_signature"] = signature
            block_states[_cell_key(cell)] = state
        elif id == "redstone_lamp":
            var powered := false
            for direction in DIRECTIONS:
                var neighbour := cell + direction
                var neighbour_id := get_block_id(neighbour)
                var neighbour_state := get_block_state(neighbour)
                if neighbour_id == "redstone_block" or int(neighbour_state.get("power", 0)) > 0 or bool(neighbour_state.get("powered", false)) or neighbour_id == "redstone_torch":
                    powered = true
                    break
            if bool(state.get("powered", false)) != powered:
                state["powered"] = powered
                block_states[_cell_key(cell)] = state
                _mark_chunk_mesh_updates(cell, dirty_mesh_chunks)
        elif id in ["iron_door", "iron_trapdoor"]:
            var powered := false
            for direction in DIRECTIONS:
                var neighbour := cell + direction
                var neighbour_state := get_block_state(neighbour)
                var neighbour_id := get_block_id(neighbour)
                if neighbour_id == "redstone_block" or int(neighbour_state.get("power", 0)) > 0 or bool(neighbour_state.get("powered", false)) or neighbour_id == "redstone_torch":
                    powered = true
                    break
            if bool(state.get("open", false)) != powered:
                state["open"] = powered
                state["powered"] = powered
                block_states[_cell_key(cell)] = state
                if id == "iron_door":
                    var other_cell := cell + (Vector3i.DOWN if str(state.get("half", "lower")) == "upper" else Vector3i.UP)
                    if get_block_id(other_cell) == id:
                        var other_state := get_block_state(other_cell)
                        other_state["open"] = powered
                        other_state["powered"] = powered
                        block_states[_cell_key(other_cell)] = other_state
                        _mark_chunk_mesh_updates(other_cell, dirty_mesh_chunks)
                _mark_chunk_mesh_updates(cell, dirty_mesh_chunks)
        elif id in ["piston", "sticky_piston"]:
            var powered := false
            for direction in DIRECTIONS:
                var neighbour := cell + direction
                var neighbour_state := get_block_state(neighbour)
                if get_block_id(neighbour) == "redstone_block" or int(neighbour_state.get("power", 0)) > 0 or bool(neighbour_state.get("powered", false)) or get_block_id(neighbour) == "redstone_torch":
                    powered = true
                    break
            var was_powered := bool(state.get("powered", false))
            if powered and not was_powered:
                _try_extend_piston(cell, id == "sticky_piston", state)
            elif not powered and was_powered:
                _try_retract_piston(cell, id == "sticky_piston", state)
            state["powered"] = powered
            block_states[_cell_key(cell)] = state

    rebuilding = true
    for chunk_coord in dirty_mesh_chunks.keys():
        if chunk_nodes.has(chunk_coord):
            _rebuild_chunk_mesh(chunk_coord)
    rebuilding = false

func _mark_chunk_mesh_updates(cell: Vector3i, touched: Dictionary) -> void:
    var coord := _chunk_for_cell(cell)
    touched[coord] = true
    var local_x := cell.x - coord.x * CHUNK_SIZE
    var local_z := cell.z - coord.y * CHUNK_SIZE
    if local_x == 0: touched[coord + Vector2i(-1, 0)] = true
    if local_x == CHUNK_SIZE - 1: touched[coord + Vector2i(1, 0)] = true
    if local_z == 0: touched[coord + Vector2i(0, -1)] = true
    if local_z == CHUNK_SIZE - 1: touched[coord + Vector2i(0, 1)] = true

func _try_extend_piston(cell: Vector3i, sticky: bool, state: Dictionary) -> void:
    var facing := str(state.get("facing", "north"))
    var direction := _facing_vector(facing)
    var target := cell + direction
    var front_id := get_block_id(target)
    if front_id == "air" or front_id == "water":
        _set_saved_block(target, "piston_head")
        block_states[_cell_key(target)] = {"facing": facing}
        state["extended"] = true
        return
    var beyond := target + direction
    if get_block_id(beyond) != "air" or front_id in ["bedrock", "obsidian", "piston", "sticky_piston", "piston_head"]:
        return
    var front_state := get_block_state(target)
    _set_saved_block(beyond, front_id)
    if not front_state.is_empty():
        block_states[_cell_key(beyond)] = front_state.duplicate(true)
    _set_saved_block(target, "piston_head")
    block_states[_cell_key(target)] = {"facing": facing}
    if sticky:
        state["sticky_front_id"] = front_id
        state["sticky_front_state"] = front_state.duplicate(true)
    state["extended"] = true
    _rebuild_affected_chunks(target)
    _rebuild_affected_chunks(beyond)
    _redstone_dirty = true

func _try_retract_piston(cell: Vector3i, sticky: bool, state: Dictionary) -> void:
    var direction := _facing_vector(str(state.get("facing", "north")))
    var target := cell + direction
    if get_block_id(target) == "piston_head":
        _set_saved_block(target, "air")
        if sticky:
            var beyond := target + direction
            var pulled_id := str(state.get("sticky_front_id", ""))
            if not pulled_id.is_empty() and get_block_id(beyond) == pulled_id:
                var pulled_state: Dictionary = state.get("sticky_front_state", {})
                _set_saved_block(beyond, "air")
                _set_saved_block(target, pulled_id)
                if not pulled_state.is_empty():
                    block_states[_cell_key(target)] = pulled_state.duplicate(true)
                state.erase("sticky_front_id")
                state.erase("sticky_front_state")
        state["extended"] = false
    _redstone_dirty = true

func _facing_vector(facing: String) -> Vector3i:
    match facing:
        "east": return Vector3i.RIGHT
        "west": return Vector3i.LEFT
        "south": return Vector3i.BACK
        _: return Vector3i.FORWARD

func _face_tile_for_state(tiles: Dictionary, face_index: int, face_name: String, state: Dictionary) -> int:
    # Directional blocks (furnace, chest, observer, doors, pumpkins, pistons)
    # use their authored front/back swatches only on the matching world-facing side.
    var tile_index := int(tiles.get(face_name, tiles.get("side", 0)))
    if face_index in [0, 1, 4, 5]:
        var face_direction: Vector3i = DIRECTIONS[face_index]
        var front_direction := _facing_vector(str(state.get("facing", "south")))
        if tiles.has("front") and face_direction == front_direction:
            return int(tiles["front"])
        if tiles.has("back") and face_direction == -front_direction:
            return int(tiles["back"])
    return tile_index

func _cell_key(cell: Vector3i) -> String:
    return "%d,%d,%d" % [cell.x, cell.y, cell.z]

func _chunk_for_cell(cell: Vector3i) -> Vector2i:
    return Vector2i(floori(float(cell.x) / float(CHUNK_SIZE)), floori(float(cell.z) / float(CHUNK_SIZE)))

func _index_modification(cell: Vector3i, block_id: String) -> void:
    var coord := _chunk_for_cell(cell)
    if not modifications_by_chunk.has(coord):
        modifications_by_chunk[coord] = {}
    var chunk_mods: Dictionary = modifications_by_chunk[coord]
    chunk_mods[_cell_key(cell)] = block_id

func _rebuild_modification_index() -> void:
    modifications_by_chunk.clear()
    for key in modifications.keys():
        var parts := str(key).split(",")
        if parts.size() != 3:
            continue
        var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
        _index_modification(cell, str(modifications[key]))

func _apply_chunk_modifications(coord: Vector2i) -> void:
    var chunk_mods: Dictionary = modifications_by_chunk.get(coord, {})
    for key in chunk_mods.keys():
        var parts := str(key).split(",")
        if parts.size() != 3:
            continue
        var cell := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
        var value := str(chunk_mods[key])
        if value == "air":
            blocks.erase(cell)
            var idx: Dictionary = chunk_cells[coord]
            idx.erase(cell)
        elif BlockRegistry.has_block(value):
            blocks[cell] = value
            var idx2: Dictionary = chunk_cells[coord]
            idx2[cell] = true

func _rebuild_chunk_index() -> void:
    for coord in chunk_nodes.keys():
        chunk_cells[coord] = {}
    for key in blocks.keys():
        var cell: Vector3i = key
        var coord := _chunk_for_cell(cell)
        if chunk_cells.has(coord):
            var index: Dictionary = chunk_cells[coord]
            index[cell] = true

func _update_chunk_index_cell(cell: Vector3i, exists: bool) -> void:
    var coord := _chunk_for_cell(cell)
    if not chunk_cells.has(coord):
        return
    var index: Dictionary = chunk_cells[coord]
    if exists:
        index[cell] = true
    else:
        index.erase(cell)

func _rebuild_affected_chunks(cell: Vector3i) -> void:
    if rebuilding:
        return
    var coord := _chunk_for_cell(cell)
    var affected: Array[Vector2i] = [coord]
    var local_x := cell.x - coord.x * CHUNK_SIZE
    var local_z := cell.z - coord.y * CHUNK_SIZE
    if local_x == 0: affected.append(coord + Vector2i(-1, 0))
    if local_x == CHUNK_SIZE - 1: affected.append(coord + Vector2i(1, 0))
    if local_z == 0: affected.append(coord + Vector2i(0, -1))
    if local_z == CHUNK_SIZE - 1: affected.append(coord + Vector2i(0, 1))
    rebuilding = true
    for chunk_coord in affected:
        if chunk_nodes.has(chunk_coord):
            _rebuild_chunk_mesh(chunk_coord)
    rebuilding = false

func rebuild_mesh() -> void:
    if rebuilding or atlas_material == null:
        return
    rebuilding = true
    for coord in chunk_nodes.keys():
        _rebuild_chunk_mesh(coord)
    rebuilding = false

func _refresh_all_loaded_chunk_meshes() -> void:
    if atlas_material == null:
        return
    rebuilding = true
    for coord in chunk_nodes.keys():
        _rebuild_chunk_mesh(coord)
    rebuilding = false

func _refresh_chunk_and_neighbours(coord: Vector2i) -> void:
    if atlas_material == null:
        return
    rebuilding = true
    for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        var affected: Vector2i = coord + offset
        if chunk_nodes.has(affected):
            _rebuild_chunk_mesh(affected)
    rebuilding = false

func _emission_for_block(cell: Vector3i, block_id: String) -> float:
    var definition := BlockRegistry.get_block(block_id)
    var emission := float(definition.get("emission", 0.0))
    # A few vanilla light sources are state-dependent or use catalogue defaults
    # without a numeric light value in the compact block database.
    if block_id == "redstone_lamp":
        emission = 1.0 if bool(get_block_state(cell).get("powered", false)) else 0.0
    elif block_id in ["campfire", "soul_campfire"]:
        emission = 1.0 if bool(get_block_state(cell).get("lit", true)) else 0.0
    elif block_id in ["soul_torch", "soul_lantern"]:
        emission = maxf(emission, 0.6)
    elif block_id in ["shroomlight", "end_rod", "sea_pickle"]:
        emission = maxf(emission, 0.8)
    return clampf(emission, 0.0, 1.0)

func _refresh_block_lights(player_position: Vector3) -> void:
    # Godot has no built-in voxel light propagation in this implementation.
    # Keep a strict, nearest-first budget of local point lights so torches and
    # other emitters visibly illuminate terrain without swamping mobile GPUs.
    var candidates: Array[Dictionary] = []
    var max_distance_squared := 30.0 * 30.0
    for raw_cell in blocks.keys():
        var cell: Vector3i = raw_cell
        var block_id := str(blocks[raw_cell])
        var emission := _emission_for_block(cell, block_id)
        if emission <= 0.0:
            continue
        var light_position := Vector3(float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5)
        var distance_squared := light_position.distance_squared_to(player_position)
        if distance_squared > max_distance_squared:
            continue
        candidates.append({
            "key": _cell_key(cell),
            "cell": cell,
            "id": block_id,
            "emission": emission,
            "distance_squared": distance_squared,
            "position": light_position
        })
    candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a["distance_squared"]) < float(b["distance_squared"])
    )
    var wanted: Dictionary = {}
    var wanted_count := mini(MAX_LOCAL_BLOCK_LIGHTS, candidates.size())
    for candidate_index in range(wanted_count):
        var candidate: Dictionary = candidates[candidate_index]
        wanted[str(candidate["key"])] = candidate
    for existing_key in _block_light_nodes.keys():
        var existing: Dictionary = _block_light_nodes[existing_key]
        var keep := wanted.has(str(existing_key)) and str(wanted[str(existing_key)].get("id", "")) == str(existing.get("id", ""))
        if not keep:
            var existing_node: Node = existing.get("node")
            if is_instance_valid(existing_node):
                existing_node.queue_free()
            _block_light_nodes.erase(existing_key)
    for light_key in wanted.keys():
        if _block_light_nodes.has(light_key):
            continue
        var candidate: Dictionary = wanted[light_key]
        var cell: Vector3i = candidate["cell"]
        var block_id := str(candidate["id"])
        var definition := BlockRegistry.get_block(block_id)
        var light := OmniLight3D.new()
        light.name = "BlockLight_" + str(light_key).replace(",", "_")
        light.light_color = Color.from_string(str(definition.get("color", "#ffffff")), Color.WHITE)
        light.light_energy = 1.35 * float(candidate["emission"])
        light.omni_range = 5.5 + 3.0 * float(candidate["emission"])
        light.omni_attenuation = 1.2
        light.shadow_enabled = false
        light.position = candidate["position"]
        add_child(light)
        _block_light_nodes[light_key] = {"node": light, "id": block_id, "cell": cell}

func _rebuild_chunk_mesh(chunk_coord: Vector2i) -> void:
    if not chunk_nodes.has(chunk_coord):
        return
    var chunk_info: Dictionary = chunk_nodes[chunk_coord]
    var mesh_node: MeshInstance3D = chunk_info["mesh"]
    var collision_node: CollisionShape3D = chunk_info["shape"]
    var local_cells: Dictionary = chunk_cells.get(chunk_coord, {})
    var vertices := PackedVector3Array()
    var uvs := PackedVector2Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var collision_faces := PackedVector3Array()
    var face_normals: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
    for key in local_cells.keys():
        var cell: Vector3i = key
        var block_id := str(blocks.get(cell, "air"))
        if block_id == "air" or not BlockRegistry.has_block(block_id):
            continue
        var definition := BlockRegistry.get_block(block_id)
        var block_solid := bool(definition.get("solid", false))
        var transparent := bool(definition.get("transparent", false))
        var tiles: Dictionary = definition.get("tiles", {}).duplicate(true)
        var state := get_block_state(cell)
        if block_id == "redstone_lamp" and bool(state.get("powered", false)):
            for face_name in ["top", "side", "bottom"]:
                tiles[face_name] = int(tiles.get("lit_" + face_name, tiles.get(face_name, 0)))
        elif block_id == "redstone_wire" and int(state.get("power", 0)) > 0:
            for face_name in ["top", "side", "bottom"]:
                tiles[face_name] = int(tiles.get("powered_" + face_name, tiles.get(face_name, 0)))
        elif block_id == "end_portal_frame" and bool(state.get("eye", false)):
            tiles["top"] = int(tiles.get("eye_top", tiles.get("top", 0)))
        var shape_id := str(definition.get("shape", "cube"))
        if block_id == "redstone_wire": shape_id = "redstone_wire"
        if shape_id in ["slab", "stair", "cushion", "straw_bed", "door", "trapdoor", "fence_gate", "fence", "torch", "redstone_wire", "rail", "button", "stone_pressure_plate", "lever", "repeater", "comparator", "piston_head", "portal", "fluid", "farmland", "dirt_path"]:
            _append_shaped_block_geometry(cell, shape_id, tiles, block_solid, state, vertices, uvs, normals, colors, indices, collision_faces)
            continue
        if shape_id in ["plant", "leaf_litter"]:
            _append_plant_geometry(cell, definition, state, vertices, uvs, normals, colors, indices)
            continue
        for face_index in range(6):
            var neighbour := cell + DIRECTIONS[face_index]
            var neighbour_id := get_block_id(neighbour)
            var neighbour_def := BlockRegistry.get_block(neighbour_id) if neighbour_id != "air" else {}
            var neighbour_solid := bool(neighbour_def.get("solid", false))
            var neighbour_transparent := bool(neighbour_def.get("transparent", false))
            var visible := neighbour_id == "air" or (neighbour_id != block_id and (transparent or neighbour_transparent or not neighbour_solid))
            if not visible:
                continue
            var face: Array = FACE_CORNERS[face_index]
            var face_uv: Array[Vector2] = [_tile_uv(int(tiles.get("side", 0)), 0, 0), _tile_uv(int(tiles.get("side", 0)), 0, 1), _tile_uv(int(tiles.get("side", 0)), 1, 1), _tile_uv(int(tiles.get("side", 0)), 1, 0)]
            var face_name := "side"
            if face_index == 0: face_name = "east"
            elif face_index == 1: face_name = "west"
            elif face_index == 2: face_name = "top"
            elif face_index == 3: face_name = "bottom"
            elif face_index == 4: face_name = "south"
            elif face_index == 5: face_name = "north"
            var tile_index := _face_tile_for_state(tiles, face_index, face_name, state)
            face_uv = [_tile_uv(tile_index, 0, 0), _tile_uv(tile_index, 0, 1), _tile_uv(tile_index, 1, 1), _tile_uv(tile_index, 1, 0)]
            var base_index := vertices.size()
            var face_shade: float = [0.82, 0.82, 1.0, 0.58, 0.74, 0.74][face_index]
            for i in range(4):
                vertices.append(Vector3(cell.x, cell.y, cell.z) + face[i])
                uvs.append(face_uv[i])
                normals.append(face_normals[face_index])
                colors.append(Color(face_shade, face_shade, face_shade, 1.0))
            indices.append_array(PackedInt32Array([base_index, base_index + 1, base_index + 2, base_index, base_index + 2, base_index + 3]))
            if block_solid:
                collision_faces.append(Vector3(cell.x, cell.y, cell.z) + face[0])
                collision_faces.append(Vector3(cell.x, cell.y, cell.z) + face[1])
                collision_faces.append(Vector3(cell.x, cell.y, cell.z) + face[2])
                collision_faces.append(Vector3(cell.x, cell.y, cell.z) + face[0])
                collision_faces.append(Vector3(cell.x, cell.y, cell.z) + face[2])
                collision_faces.append(Vector3(cell.x, cell.y, cell.z) + face[3])
    if vertices.is_empty():
        mesh_node.mesh = null
    else:
        var arrays: Array = []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = vertices
        arrays[Mesh.ARRAY_TEX_UV] = uvs
        arrays[Mesh.ARRAY_NORMAL] = normals
        arrays[Mesh.ARRAY_COLOR] = colors
        arrays[Mesh.ARRAY_INDEX] = indices
        var mesh := ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        mesh.surface_set_material(0, atlas_material)
        mesh_node.mesh = mesh
    if collision_faces.is_empty():
        collision_node.shape = null
    else:
        var concave := ConcavePolygonShape3D.new()
        concave.set_faces(collision_faces)
        collision_node.shape = concave

func _append_shaped_block_geometry(cell: Vector3i, shape_id: String, tiles: Dictionary, block_solid: bool, state: Dictionary, vertices: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, collision_faces: PackedVector3Array) -> void:
    # Shapes are composed from cuboids with block-state-driven half/facing/open
    # transforms. This keeps mesh collision and visuals on the same geometry.
    var boxes: Array[Dictionary] = []
    var half := str(state.get("half", "bottom"))
    match shape_id:
        "farmland": boxes.append({"min": Vector3.ZERO, "max": Vector3(1.0, 0.9375, 1.0)})
        "dirt_path": boxes.append({"min": Vector3.ZERO, "max": Vector3(1.0, 0.9375, 1.0)})
        "slab":
            if half == "top": boxes.append({"min": Vector3(0, 0.5, 0), "max": Vector3(1, 1, 1)})
            elif half == "double": boxes.append({"min": Vector3.ZERO, "max": Vector3.ONE})
            else: boxes.append({"min": Vector3(0, 0, 0), "max": Vector3(1, 0.5, 1)})
        "stair":
            if half == "top":
                boxes.append({"min": Vector3(0, 0.5, 0), "max": Vector3(1, 1, 1)})
                boxes.append({"min": Vector3(0, 0, 0.5), "max": Vector3(1, 0.5, 1)})
            else:
                boxes.append({"min": Vector3(0, 0, 0), "max": Vector3(1, 0.5, 1)})
                boxes.append({"min": Vector3(0, 0.5, 0.5), "max": Vector3(1, 1, 1)})
        "repeater":
            boxes.append({"min": Vector3(0.04, 0.0, 0.04), "max": Vector3(0.96, 0.12, 0.96)})
            boxes.append({"min": Vector3(0.43, 0.12, 0.18), "max": Vector3(0.57, 0.28, 0.32)})
            boxes.append({"min": Vector3(0.43, 0.12, 0.68), "max": Vector3(0.57, 0.28, 0.82)})
        "comparator":
            boxes.append({"min": Vector3(0.04, 0.0, 0.04), "max": Vector3(0.96, 0.12, 0.96)})
            boxes.append({"min": Vector3(0.43, 0.12, 0.2), "max": Vector3(0.57, 0.28, 0.34)})
            boxes.append({"min": Vector3(0.2, 0.12, 0.58), "max": Vector3(0.34, 0.28, 0.72)})
            boxes.append({"min": Vector3(0.66, 0.12, 0.58), "max": Vector3(0.8, 0.28, 0.72)})
        "cushion": boxes.append({"min": Vector3(0.07, 0.0, 0.07), "max": Vector3(0.93, 0.23, 0.93)})
        "straw_bed": boxes.append({"min": Vector3(0.02, 0.0, 0.04), "max": Vector3(0.98, 0.33, 0.96)})
        "door": boxes.append({"min": Vector3(0.0, 0.0, 0.04), "max": Vector3(1.0, 1.0, 0.19)})
        "trapdoor":
            if bool(state.get("open", false)):
                boxes.append({"min": Vector3(0.0, 0.0, 0.04), "max": Vector3(1.0, 1.0, 0.19)})
            elif half == "top": boxes.append({"min": Vector3(0, 0.8125, 0), "max": Vector3(1, 1, 1)})
            else: boxes.append({"min": Vector3(0, 0, 0), "max": Vector3(1, 0.1875, 1)})
        "fence":
            boxes.append({"min": Vector3(0.375, 0, 0.375), "max": Vector3(0.625, 1, 0.625)})
            if _fence_connects_to(cell, Vector3i.LEFT):
                boxes.append({"min": Vector3(0, 0.35, 0.4375), "max": Vector3(0.5, 0.5, 0.5625)})
                boxes.append({"min": Vector3(0, 0.7, 0.4375), "max": Vector3(0.5, 0.85, 0.5625)})
            if _fence_connects_to(cell, Vector3i.RIGHT):
                boxes.append({"min": Vector3(0.5, 0.35, 0.4375), "max": Vector3(1, 0.5, 0.5625)})
                boxes.append({"min": Vector3(0.5, 0.7, 0.4375), "max": Vector3(1, 0.85, 0.5625)})
            if _fence_connects_to(cell, Vector3i.FORWARD):
                boxes.append({"min": Vector3(0.4375, 0.35, 0), "max": Vector3(0.5625, 0.5, 0.5)})
                boxes.append({"min": Vector3(0.4375, 0.7, 0), "max": Vector3(0.5625, 0.85, 0.5)})
            if _fence_connects_to(cell, Vector3i.BACK):
                boxes.append({"min": Vector3(0.4375, 0.35, 0.5), "max": Vector3(0.5625, 0.5, 1)})
                boxes.append({"min": Vector3(0.4375, 0.7, 0.5), "max": Vector3(0.5625, 0.85, 1)})
        "fence_gate":
            if not bool(state.get("open", false)):
                boxes.append({"min": Vector3(0, 0.35, 0.4), "max": Vector3(1, 0.5, 0.6)})
                boxes.append({"min": Vector3(0, 0.7, 0.4), "max": Vector3(1, 0.85, 0.6)})
                boxes.append({"min": Vector3(0.1, 0, 0.43), "max": Vector3(0.2, 1, 0.57)})
                boxes.append({"min": Vector3(0.8, 0, 0.43), "max": Vector3(0.9, 1, 0.57)})
        "torch":
            boxes.append({"min": Vector3(0.4, 0, 0.4), "max": Vector3(0.6, 0.62, 0.6)})
            boxes.append({"min": Vector3(0.32, 0.52, 0.32), "max": Vector3(0.68, 0.72, 0.68)})
        "redstone_wire": boxes.append({"min": Vector3(0.02, 0.015, 0.02), "max": Vector3(0.98, 0.045, 0.98)})
        "rail": boxes.append({"min": Vector3(0, 0.025, 0), "max": Vector3(1, 0.075, 1)})
        "button": boxes.append({"min": Vector3(0.36, 0.25, 0.36), "max": Vector3(0.64, 0.43, 0.64)})
        "stone_pressure_plate": boxes.append({"min": Vector3(0.0625, 0, 0.0625), "max": Vector3(0.9375, 0.0625, 0.9375)})
        "lever":
            boxes.append({"min": Vector3(0.22, 0, 0.22), "max": Vector3(0.78, 0.10, 0.78)})
            boxes.append({"min": Vector3(0.45, 0.08, 0.45), "max": Vector3(0.55, 0.62, 0.55)})
            boxes.append({"min": Vector3(0.32, 0.55, 0.32), "max": Vector3(0.68, 0.72, 0.68)})
        "piston_head":
            boxes.append({"min": Vector3(0.375, 0.375, 0.20), "max": Vector3(0.625, 0.625, 0.80)})
            boxes.append({"min": Vector3(0.0, 0.16, 0.0), "max": Vector3(1.0, 0.84, 0.22)})
        "portal": boxes.append({"min": Vector3(0.0, 0.0, 0.47), "max": Vector3(1.0, 1.0, 0.53)})
        "fluid":
            var fluid_level := int(state.get("level", 0))
            var fluid_source := bool(state.get("source", fluid_level == 0))
            var falling := bool(state.get("falling", false)) or fluid_level == 8
            var fluid_height := 1.0 if fluid_source or falling else clampf(1.0 - float(fluid_level) / 8.0, 0.125, 1.0)
            boxes.append({"min": Vector3(0.0, 0.0, 0.0), "max": Vector3(1.0, fluid_height, 1.0)})
        _:
            boxes.append({"min": Vector3.ZERO, "max": Vector3.ONE})

    # Rotate the local shape from its authored south-facing pose.
    var facing := str(state.get("facing", "south"))
    var turns := 0
    match facing:
        "north": turns = 2
        "east": turns = 1
        "west": turns = 3
        _: turns = 0
    if shape_id in ["door", "trapdoor", "stair", "fence_gate", "piston_head", "repeater", "comparator"]:
        if bool(state.get("open", false)) and shape_id in ["door", "trapdoor", "fence_gate"]:
            turns = (turns + 1) % 4
        for i in range(boxes.size()):
            var b: Dictionary = boxes[i]
            var old_min: Vector3 = b["min"]
            var old_max: Vector3 = b["max"]
            for _turn in range(turns):
                var x0 := old_min.x; var x1 := old_max.x
                var z0 := old_min.z; var z1 := old_max.z
                old_min.x = 1.0 - z1; old_max.x = 1.0 - z0
                old_min.z = x0; old_max.z = x1
            b["min"] = old_min; b["max"] = old_max
            boxes[i] = b

    var face_normals: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]
    for box_index in range(boxes.size()):
        var bounds: Dictionary = boxes[box_index]
        var box_min: Vector3 = bounds["min"]
        var box_max: Vector3 = bounds["max"]
        for face_index in range(6):
            if _box_face_is_internal(box_index, face_index, boxes):
                continue
            var at_cell_boundary := _box_face_at_cell_boundary(box_min, box_max, face_index)
            var neighbour_id := "air"
            if at_cell_boundary:
                neighbour_id = get_block_id(cell + DIRECTIONS[face_index])
                var neighbour_definition := BlockRegistry.get_block(neighbour_id) if neighbour_id != "air" else {}
                var neighbour_shape := str(neighbour_definition.get("shape", "cube"))
                var neighbour_full := bool(neighbour_definition.get("solid", false)) and not bool(neighbour_definition.get("transparent", false)) and neighbour_shape not in ["slab", "stair", "cushion", "straw_bed", "farmland", "dirt_path", "plant", "leaf_litter"]
                if neighbour_full and _box_face_fully_covers_cell_face(box_min, box_max, face_index):
                    continue
            var face_name := "side"
            if face_index == 0: face_name = "east"
            elif face_index == 1: face_name = "west"
            elif face_index == 2: face_name = "top"
            elif face_index == 3: face_name = "bottom"
            elif face_index == 4: face_name = "south"
            elif face_index == 5: face_name = "north"
            var tile_index := _face_tile_for_state(tiles, face_index, face_name, state)
            var base_index := vertices.size()
            var corners: Array = FACE_CORNERS[face_index]
            var face_uvs: Array[Vector2] = [
                _tile_uv(tile_index, 0, 0), _tile_uv(tile_index, 0, 1),
                _tile_uv(tile_index, 1, 1), _tile_uv(tile_index, 1, 0)
            ]
            for corner_index in range(4):
                var unit_corner: Vector3 = corners[corner_index]
                var mapped := Vector3(
                    lerpf(box_min.x, box_max.x, unit_corner.x),
                    lerpf(box_min.y, box_max.y, unit_corner.y),
                    lerpf(box_min.z, box_max.z, unit_corner.z)
                )
                vertices.append(Vector3(cell.x, cell.y, cell.z) + mapped)
                uvs.append(face_uvs[corner_index])
                normals.append(face_normals[face_index])
                var face_shade: float = [0.82, 0.82, 1.0, 0.58, 0.74, 0.74][face_index]
                colors.append(Color(face_shade, face_shade, face_shade, 1.0))
            indices.append_array(PackedInt32Array([base_index, base_index+1, base_index+2, base_index, base_index+2, base_index+3]))
            if block_solid:
                var p0 := vertices[base_index]
                var p1 := vertices[base_index + 1]
                var p2 := vertices[base_index + 2]
                var p3 := vertices[base_index + 3]
                collision_faces.append_array(PackedVector3Array([p0,p1,p2,p0,p2,p3]))

func _fence_connects_to(cell: Vector3i, direction: Vector3i) -> bool:
    var neighbour_cell := cell + direction
    var neighbour_id := get_block_id(neighbour_cell)
    if neighbour_id == "air":
        return false
    var definition := BlockRegistry.get_block(neighbour_id)
    var shape := str(definition.get("shape", "cube"))
    if shape in ["fence", "fence_gate"] or neighbour_id.ends_with("_fence") or neighbour_id.ends_with("_fence_gate"):
        return true
    return bool(definition.get("solid", false)) and not bool(definition.get("transparent", false)) and shape not in ["slab", "stair", "plant", "leaf_litter", "rail"]

func _box_face_is_internal(box_index: int, face_index: int, boxes: Array[Dictionary]) -> bool:
    var bounds: Dictionary = boxes[box_index]
    var box_min: Vector3 = bounds["min"]
    var box_max: Vector3 = bounds["max"]
    var axis := 0 if face_index <= 1 else (1 if face_index <= 3 else 2)
    var positive := face_index in [0, 2, 4]
    var plane := _vector_component(box_max, axis) if positive else _vector_component(box_min, axis)
    var other_axis_a: int = 1 if axis == 0 else 0
    var other_axis_b: int = 2 if axis != 2 else 1
    for other_index in range(boxes.size()):
        if other_index == box_index:
            continue
        var other: Dictionary = boxes[other_index]
        var other_min: Vector3 = other["min"]
        var other_max: Vector3 = other["max"]
        var other_plane := _vector_component(other_min, axis) if positive else _vector_component(other_max, axis)
        if absf(other_plane - plane) > 0.0001:
            continue
        var fully_covered := true
        for overlap_index in range(2):
            var overlap_axis: int = other_axis_a if overlap_index == 0 else other_axis_b
            var face_min: float = _vector_component(box_min, overlap_axis)
            var face_max: float = _vector_component(box_max, overlap_axis)
            var covering_min: float = _vector_component(other_min, overlap_axis)
            var covering_max: float = _vector_component(other_max, overlap_axis)
            if covering_min > face_min + 0.0001 or covering_max < face_max - 0.0001:
                fully_covered = false
                break
        if fully_covered:
            return true
    return false

func _vector_component(value: Vector3, axis: int) -> float:
    if axis == 0:
        return value.x
    if axis == 1:
        return value.y
    return value.z

func _box_face_fully_covers_cell_face(box_min: Vector3, box_max: Vector3, face_index: int) -> bool:
    # Do not cull the exposed strip of a partial-height/partial-width shape merely
    # because a full neighbouring cube occupies the same adjacent cell.
    if face_index in [0, 1]:
        return is_zero_approx(box_min.y) and is_equal_approx(box_max.y, 1.0) and is_zero_approx(box_min.z) and is_equal_approx(box_max.z, 1.0)
    if face_index in [2, 3]:
        return is_zero_approx(box_min.x) and is_equal_approx(box_max.x, 1.0) and is_zero_approx(box_min.z) and is_equal_approx(box_max.z, 1.0)
    return is_zero_approx(box_min.x) and is_equal_approx(box_max.x, 1.0) and is_zero_approx(box_min.y) and is_equal_approx(box_max.y, 1.0)

func _box_face_at_cell_boundary(box_min: Vector3, box_max: Vector3, face_index: int) -> bool:
    if face_index == 0: return is_equal_approx(box_max.x, 1.0)
    if face_index == 1: return is_zero_approx(box_min.x)
    if face_index == 2: return is_equal_approx(box_max.y, 1.0)
    if face_index == 3: return is_zero_approx(box_min.y)
    if face_index == 4: return is_equal_approx(box_max.z, 1.0)
    return is_zero_approx(box_min.z)

func _append_plant_geometry(cell: Vector3i, definition: Dictionary, state: Dictionary, vertices: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array) -> void:
    # Crossed alpha-cutout quads for small plants, plus flat special meshes for litter/wire.
    var tiles: Dictionary = definition.get("tiles", {})
    var shape_id := str(definition.get("shape", "plant"))
    var tile_index := int(tiles.get("side", 0))
    if str(definition.get("name", "")).to_lower() == "tripwire":
        # Tripwire is a horizontal 1-pixel thread, not two crossed plant cards.
        # UVs are pinned to the string row of the side swatch so the narrow mesh
        # is filled by the fibre rather than sampling mostly-transparent rows.
        var facing := str(state.get("facing", "south"))
        var y := 0.065
        var corners: Array[Vector3]
        var face_uvs: Array[Vector2]
        var tile := int(tiles.get("side", tiles.get("top", 0)))
        if facing in ["north", "south"]:
            corners = [Vector3(0.4875, y, 0.0), Vector3(0.4875, y, 1.0), Vector3(0.5125, y, 1.0), Vector3(0.5125, y, 0.0)]
            face_uvs = [_tile_uv_pixel(tile, 0.5, 8.5), _tile_uv_pixel(tile, 15.5, 8.5), _tile_uv_pixel(tile, 15.5, 8.5), _tile_uv_pixel(tile, 0.5, 8.5)]
        else:
            corners = [Vector3(0.0, y, 0.4875), Vector3(0.0, y, 0.5125), Vector3(1.0, y, 0.5125), Vector3(1.0, y, 0.4875)]
            face_uvs = [_tile_uv_pixel(tile, 0.5, 8.5), _tile_uv_pixel(tile, 0.5, 8.5), _tile_uv_pixel(tile, 15.5, 8.5), _tile_uv_pixel(tile, 15.5, 8.5)]
        var base_index := vertices.size()
        for i in range(4):
            vertices.append(Vector3(cell.x, cell.y, cell.z) + corners[i])
            uvs.append(face_uvs[i])
            normals.append(Vector3.UP)
            colors.append(Color(1.0, 1.0, 1.0, 1.0))
        indices.append_array(PackedInt32Array([base_index, base_index + 1, base_index + 2, base_index, base_index + 2, base_index + 3]))
        return
    if shape_id == "leaf_litter":
        var y := 0.04
        var corners: Array[Vector3] = [Vector3(0.03,y,0.03), Vector3(0.03,y,0.97), Vector3(0.97,y,0.97), Vector3(0.97,y,0.03)]
        var face_uvs: Array[Vector2] = [_tile_uv(tile_index,0,0), _tile_uv(tile_index,0,1), _tile_uv(tile_index,1,1), _tile_uv(tile_index,1,0)]
        var base_index := vertices.size()
        for i in range(4):
            vertices.append(Vector3(cell.x,cell.y,cell.z)+corners[i])
            uvs.append(face_uvs[i])
            normals.append(Vector3.UP)
            colors.append(Color(0.92, 0.92, 0.92, 1.0))
        indices.append_array(PackedInt32Array([base_index,base_index+1,base_index+2,base_index,base_index+2,base_index+3]))
        return
    var height := clampf(float(definition.get("height", 0.78)), 0.2, 1.0)
    var definition_tags: Array = definition.get("tags", [])
    if definition_tags.has("crop"):
        height = lerpf(0.18, 0.88, clampf(float(state.get("age", 0)) / 7.0, 0.0, 1.0))
    var width := clampf(float(definition.get("width", 0.76)), 0.2, 1.0)
    var low := (1.0-width)*0.5
    var high := low+width
    var planes: Array = [
        {"corners": [Vector3(low,0,low), Vector3(low,height,low), Vector3(high,height,high), Vector3(high,0,high)], "normal": Vector3(1,0,-1).normalized()},
        {"corners": [Vector3(high,0,low), Vector3(high,height,low), Vector3(low,height,high), Vector3(low,0,high)], "normal": Vector3(1,0,1).normalized()}
    ]
    for plane in planes:
        var corners: Array = plane["corners"]
        var original_normal: Vector3 = plane["normal"]
        for reverse_side in [false, true]:
            var face_corners: Array = corners.duplicate()
            var face_uvs: Array[Vector2] = [
                _tile_uv(tile_index, 0, 0), _tile_uv(tile_index, 0, 1),
                _tile_uv(tile_index, 1, 1), _tile_uv(tile_index, 1, 0)
            ]
            var normal := original_normal
            if reverse_side:
                face_corners = [corners[3], corners[2], corners[1], corners[0]]
                face_uvs = [face_uvs[3], face_uvs[2], face_uvs[1], face_uvs[0]]
                normal = -original_normal
            var base_index := vertices.size()
            for corner_index in range(4):
                vertices.append(Vector3(cell.x, cell.y, cell.z) + face_corners[corner_index])
                uvs.append(face_uvs[corner_index])
                normals.append(normal)
                colors.append(Color(1.0, 1.0, 1.0, 1.0))
            indices.append_array(PackedInt32Array([base_index, base_index+1, base_index+2, base_index, base_index+2, base_index+3]))

func _tile_uv_pixel(tile_index: int, pixel_x: float, pixel_y: float) -> Vector2:
    var atlas_x := float((tile_index % atlas_columns) * TILE_SIZE) + pixel_x
    var atlas_y := float(int(floor(float(tile_index) / float(atlas_columns))) * TILE_SIZE) + pixel_y
    return Vector2(atlas_x / float(atlas_columns * TILE_SIZE), atlas_y / float(atlas_rows * TILE_SIZE))

func _tile_uv(tile_index: int, u: int, v: int) -> Vector2:
    var px := float((tile_index % atlas_columns) * TILE_SIZE) + (0.5 if u == 0 else TILE_SIZE - 0.5)
    var row := int(floor(float(tile_index) / float(atlas_columns)))
    var py := float(row * TILE_SIZE) + (0.5 if v == 0 else TILE_SIZE - 0.5)
    return Vector2(px / float(atlas_columns * TILE_SIZE), py / float(atlas_rows * TILE_SIZE))
