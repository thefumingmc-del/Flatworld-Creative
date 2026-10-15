extends RefCounted
class_name PlayerInventory

const SLOT_COUNT := 36
const HOTBAR_COUNT := 9
const DEFAULT_MAX_STACK := 64

var slots: Array[Dictionary] = []

func _init() -> void:
    for _i in range(SLOT_COUNT):
        slots.append({"id": "", "count": 0})

func count(item_id: String) -> int:
    var total := 0
    for slot in slots:
        if str(slot.get("id", "")) == item_id:
            total += int(slot.get("count", 0))
    return total

func has_item(item_id: String, amount: int = 1) -> bool:
    return count(item_id) >= amount

func add_item(item_id: String, amount: int = 1) -> int:
    if item_id.is_empty() or amount <= 0:
        return 0
    var remaining := amount
    var limit := _max_stack(item_id)
    # Merge into matching stacks before allocating an empty slot.
    for i in range(slots.size()):
        if str(slots[i].get("id", "")) == item_id and int(slots[i].get("count", 0)) < limit:
            var accepted := mini(remaining, limit - int(slots[i]["count"]))
            slots[i]["count"] = int(slots[i]["count"]) + accepted
            remaining -= accepted
            if remaining <= 0:
                return amount
    for i in range(slots.size()):
        if str(slots[i].get("id", "")).is_empty() or int(slots[i].get("count", 0)) <= 0:
            var accepted := mini(remaining, limit)
            slots[i] = {"id": item_id, "count": accepted}
            remaining -= accepted
            if remaining <= 0:
                return amount
    return amount - remaining

func remove_item(item_id: String, amount: int = 1) -> bool:
    if amount <= 0:
        return true
    if count(item_id) < amount:
        return false
    var remaining := amount
    for i in range(slots.size()):
        if str(slots[i].get("id", "")) != item_id:
            continue
        var take := mini(remaining, int(slots[i].get("count", 0)))
        slots[i]["count"] = int(slots[i]["count"]) - take
        remaining -= take
        if int(slots[i]["count"]) <= 0:
            slots[i] = {"id": "", "count": 0}
        if remaining <= 0:
            return true
    return false

func get_slot(index: int) -> Dictionary:
    if index < 0 or index >= slots.size():
        return {"id": "", "count": 0}
    return slots[index].duplicate(true)

func get_hotbar_id(index: int) -> String:
    var slot := get_slot(index)
    return str(slot.get("id", ""))

func can_craft(recipe: Dictionary) -> bool:
    var ingredients: Dictionary = recipe.get("ingredients", {})
    for key in ingredients.keys():
        if count(str(key)) < int(ingredients[key]):
            return false
    return true

func craft(recipe: Dictionary) -> Dictionary:
    if not can_craft(recipe):
        return {"ok": false, "reason": "missing_ingredients"}
    var before := slots.duplicate(true)
    var ingredients: Dictionary = recipe.get("ingredients", {})
    for key in ingredients.keys():
        if not remove_item(str(key), int(ingredients[key])):
            slots = before
            return {"ok": false, "reason": "missing_ingredients"}
    var result_id := str(recipe.get("result", ""))
    var result_count := int(recipe.get("count", 1))
    var accepted := add_item(result_id, result_count)
    if accepted != result_count:
        slots = before
        return {"ok": false, "reason": "inventory_full"}
    return {"ok": true, "result": result_id, "count": result_count}

func to_dict() -> Dictionary:
    return {"slots": slots.duplicate(true)}

func from_dict(data: Dictionary) -> void:
    # Keep malformed/outdated saves from creating over-stacked or negative slots.
    # First restore existing slot positions; then distribute any overflow, so an
    # early overflowing slot cannot be overwritten by a later saved slot.
    slots.clear()
    for _i in range(SLOT_COUNT):
        slots.append({"id": "", "count": 0})
    var saved_slots: Variant = data.get("slots", [])
    if not saved_slots is Array:
        return
    var overflow_items: Array[Dictionary] = []
    for i in range(mini(SLOT_COUNT, saved_slots.size())):
        var entry: Variant = saved_slots[i]
        if not entry is Dictionary:
            continue
        var item_id := str(entry.get("id", ""))
        var amount := maxi(0, int(entry.get("count", 0)))
        if item_id.is_empty() or amount <= 0:
            continue
        var limit := _max_stack(item_id)
        var placed := mini(amount, limit)
        slots[i] = {"id": item_id, "count": placed}
        if amount > placed:
            overflow_items.append({"id": item_id, "count": amount - placed})
    for overflow in overflow_items:
        add_item(str(overflow["id"]), int(overflow["count"]))

func _max_stack(item_id: String) -> int:
    # Use the independent item registry. Name heuristics are only a defensive fallback
    # while authoritative item component data is still pending; canonical item components
    # replace these values after the 26.3 source import.
    var item_definition := BlockRegistry.get_item(item_id)
    # A positive max-damage component is definitive evidence that this item is
    # damageable and normally stack-size one, even before the full source import.
    if int(item_definition.get("max_damage", item_definition.get("maxDurability", 0))) > 0:
        return 1
    if BlockRegistry.has_authoritative_reference():
        var imported_limit := int(item_definition.get("max_stack_size", item_definition.get("stackSize", 0)))
        if imported_limit > 0:
            return imported_limit
    var lower := item_id.to_lower()
    for marker in ["pickaxe", "sword", "axe", "shovel", "hoe", "bow", "crossbow", "trident", "shield", "fishing_rod", "flint_and_steel", "shears", "helmet", "chestplate", "leggings", "boots", "elytra", "horse_armor", "mace", "carrot_on_a_stick", "warped_fungus_on_a_stick"]:
        if lower.contains(marker):
            return 1
    if lower in ["water_bucket", "lava_bucket", "milk_bucket", "powder_snow_bucket", "written_book", "writable_book", "potion", "splash_potion", "lingering_potion"]:
        return 1
    if lower in ["bucket", "egg", "snowball", "ender_pearl", "honey_bottle"]:
        return 16
    return DEFAULT_MAX_STACK
