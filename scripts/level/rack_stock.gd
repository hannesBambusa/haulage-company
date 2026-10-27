@tool
class_name RackStock
extends Node3D
## Stock for an empty rack_bay.glb instance: puts pallets and loose boxes on
## the three beam levels from a pattern. Each level holds two pallet slots
## (the positions rack_bay_loaded.glb uses). StorageGrid reads the slots back:
## a stocked slot is "house stock" and cannot take cargo.
## One string per level (bottom first), one character per slot:
##   a/b/c = pallet_boxes_a/b/c, e = empty pallet, s = two loose boxes,
##   S = a single box, . = gap.
## Older three-character patterns are packed into the two slots left to right.
## `fill` caps the share of slots that get stock, so racks keep free slots
## for cargo; a seeded pick decides which pattern entries stay.

const SCENES: Dictionary = {
	"a": preload("res://assets/models/pallet_boxes_a.glb"),
	"b": preload("res://assets/models/pallet_boxes_b.glb"),
	"c": preload("res://assets/models/pallet_boxes_c.glb"),
	"e": preload("res://assets/models/pallet.glb"),
}
const BOX: PackedScene = preload("res://assets/models/box_single.glb")
## Deck heights of the three levels (beam top + deck), see props_rack.py.
const LEVEL_Y: PackedFloat32Array = [0.225, 1.625, 3.025]
## Pallet slot centres along the beam, as in rack_bay_loaded.glb.
const SLOT_X: PackedFloat32Array = [-0.68, 0.68]

@export var levels: PackedStringArray = PackedStringArray(["a.", "ba", ".c"]):
	set(value):
		levels = value
		_rebuild_if_ready()
@export var random_seed: int = 1:
	set(value):
		random_seed = value
		_rebuild_if_ready()
## Most of the rack's slots that hold house stock (0..1). 1 = pattern as is.
@export_range(0.0, 1.0, 0.05) var fill: float = 0.5:
	set(value):
		fill = value
		_rebuild_if_ready()

## Per level, the slot keys after packing and the fill cap.
var _stock: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_rebuild()


func level_count() -> int:
	return LEVEL_Y.size()


func slots_per_level() -> int:
	return SLOT_X.size()


## Local position of a slot's pallet bottom centre.
func slot_local_position(level: int, slot: int) -> Vector3:
	return Vector3(SLOT_X[slot], LEVEL_Y[level], 0.0)


## True when house stock sits in this slot.
func is_slot_stocked(level: int, slot: int) -> bool:
	if _stock.size() != mini(levels.size(), LEVEL_Y.size()):
		_stock = _stocked_rows()
	if level >= _stock.size():
		return false
	return _stock[level][slot] != "."


## The pattern packed into two slots per level, thinned to `fill`.
func _stocked_rows() -> PackedStringArray:
	var rows: PackedStringArray = PackedStringArray()
	var filled: Array[Vector2i] = []
	for li: int in mini(levels.size(), LEVEL_Y.size()):
		var row: String = _slot_keys(levels[li])
		rows.append(row)
		for si: int in row.length():
			if row[si] != ".":
				filled.append(Vector2i(li, si))
	var keep: int = roundi(LEVEL_Y.size() * SLOT_X.size() * fill)
	if filled.size() <= keep:
		return rows
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = random_seed * 7919 + 17
	while filled.size() > keep:
		var drop: Vector2i = filled.pop_at(rng.randi_range(0, filled.size() - 1))
		var row: String = rows[drop.x]
		row[drop.y] = "."
		rows[drop.x] = row
	return rows


func _slot_keys(row: String) -> String:
	if row.length() == SLOT_X.size():
		return row
	var keys: String = ""
	for ch: String in row:
		if ch != "." and keys.length() < SLOT_X.size():
			keys += ch
	while keys.length() < SLOT_X.size():
		keys += "."
	return keys


func _rebuild_if_ready() -> void:
	if is_node_ready():
		_rebuild()


func _rebuild() -> void:
	for c: Node in get_children():
		if c.has_meta(&"rack_stock"):
			remove_child(c)
			c.queue_free()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = random_seed
	_stock = _stocked_rows()
	for li: int in _stock.size():
		var row: String = _stock[li]
		for si: int in SLOT_X.size():
			var key: String = row[si]
			var at: Vector3 = Vector3(SLOT_X[si] + rng.randf_range(-0.03, 0.03), LEVEL_Y[li], 0.0)
			if SCENES.has(key):
				# pallets sit across the beams: 0.8 m along the rack, 1.2 m deep
				_add(SCENES[key], at, PI * 0.5 + rng.randf_range(-0.03, 0.03))
			elif key == "s":
				_add(BOX, at + Vector3(-0.2, 0.0, 0.1), rng.randf_range(-0.3, 0.3))
				_add(BOX, at + Vector3(0.22, 0.0, -0.15), rng.randf_range(-0.3, 0.3))
			elif key == "S":
				_add(BOX, at, rng.randf_range(-0.4, 0.4))


func _add(scene: PackedScene, at: Vector3, yaw: float) -> void:
	var n: Node3D = scene.instantiate() as Node3D
	n.set_meta(&"rack_stock", true)
	n.position = at
	n.rotation.y = yaw
	add_child(n)
