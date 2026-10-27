class_name StorageGrid
extends Node3D
## Every pallet position in the terminal, built at runtime from the level:
## - RACK: two slots per beam level of every RackStock rack bay,
## - FLOOR: a grid in the floor storage area,
## - INBOUND / OUTBOUND: grids inside the zone markings.
## Rack and floor slots holding the level's decorative stock are house stock.
## Decorative pallets inside the INBOUND / OUTBOUND zones are hidden, since
## real cargo uses those zones. Also parents the cargo pallets and slot markers.

signal slots_changed

const DECOR_PATTERNS: PackedStringArray = ["pallet", "box_single"]
## Agents stop this far out from a pallet's centre plus their own reach.
const ENTRY_EXTRA: float = 1.2

@export var level_path: NodePath
@export_group("Floor storage")
## Level node whose origin is the first floor slot (+X columns, -Z rows).
## When missing, floor_origin is used.
@export var floor_node_name: StringName = &"FloorStorage"
@export var floor_origin: Vector3 = Vector3(-16.6, 0.0, -2.2)
@export var floor_columns: int = 8
@export var floor_rows: int = 3
## Column (X) and row (Z) spacing. Pallets sit 1.2 m along Z.
@export var floor_pitch: Vector2 = Vector2(1.1, 1.5)
@export_group("Zones")
@export var zone_pitch: Vector2 = Vector2(1.1, 1.45)
@export var zone_margin: float = 0.25
## Decor this close (m, on the ground) to a floor slot makes it house stock.
@export var house_stock_radius: float = 0.75
## Side each zone is driven into from (pallets lie along it): INBOUND faces
## the docks, OUTBOUND faces the hall (its other side is the open yard).
@export var inbound_open: Vector3 = Vector3.BACK
@export var outbound_open: Vector3 = Vector3.LEFT

var slots: Array[StorageSlot] = []
var router: YardRouter = YardRouter.new()
## Dock lanes (ramp + parked trailer), registered by CargoFlow. They raise the
## floor height for agents on the ramps and in trailers.
var bays: Array[TrailerBay] = []
## False when nothing can reach the upper rack levels.
var lift_available: bool = true
var inbound_rect: Rect2
var outbound_rect: Rect2

var cargo_root: Node3D
var _markers: Dictionary = {}  ## StorageSlot -> SlotMarker
var _level: Node3D


func _ready() -> void:
	add_to_group(&"storage_grid")
	cargo_root = Node3D.new()
	cargo_root.name = "Cargo"
	add_child(cargo_root)
	_level = get_node_or_null(level_path) as Node3D
	if _level == null:
		push_error("StorageGrid: level_path does not point at the level")
		return
	build(_level)


## Slots and units point at each other; break the cycles on teardown.
func _exit_tree() -> void:
	for s: StorageSlot in slots:
		s.unit = null
		s.reserved_by = null


func build(level: Node3D) -> void:
	slots.clear()
	inbound_rect = _zone_rect(level, "Inbound", Rect2(-4.0, -18.0, 7.5, 5.5))
	outbound_rect = _zone_rect(level, "Outbound", Rect2(6.8, -17.2, 6.4, 6.4))
	var decor: Array[Node3D] = _decor_nodes(level)
	for n: Node3D in decor:
		if _in_rect(inbound_rect, n.global_position) or _in_rect(outbound_rect, n.global_position):
			n.visible = false
	_build_zone(StorageSlot.Zone.INBOUND, inbound_rect, level.find_child("InboundText", true, false) as Label3D, inbound_open)
	_build_zone(StorageSlot.Zone.OUTBOUND, outbound_rect, level.find_child("OutboundText", true, false) as Label3D, outbound_open)
	_build_racks(level)
	_build_floor(level, decor)
	var materials: Dictionary = {}
	for s: StorageSlot in slots:
		var marker: SlotMarker = SlotMarker.create(s, materials)
		add_child(marker)
		_markers[s] = marker
	print("StorageGrid: %d rack, %d floor, %d inbound, %d outbound slots; %d storage free, %d house stock" % [
		count_zone(StorageSlot.Zone.RACK), count_zone(StorageSlot.Zone.FLOOR),
		count_zone(StorageSlot.Zone.INBOUND), count_zone(StorageSlot.Zone.OUTBOUND),
		free_storage_count(), _house_count()])


# --- queries -----------------------------------------------------------------

func count_zone(zone: StorageSlot.Zone) -> int:
	var n: int = 0
	for s: StorageSlot in slots:
		if s.zone == zone:
			n += 1
	return n


func storage_total() -> int:
	var n: int = 0
	for s: StorageSlot in slots:
		if s.is_storage() and not s.house_stock and s.reachable and (lift_available or not s.needs_lift()):
			n += 1
	return n


## Where the player may put a pallet away: free rack slots, or free floor
## slots only once every reachable rack slot is taken (overflow).
func store_targets() -> Array[StorageSlot]:
	var racks: Array[StorageSlot] = []
	var floor_slots: Array[StorageSlot] = []
	for s: StorageSlot in free_storage_slots():
		if not placement_ok(s, null):
			continue
		if s.zone == StorageSlot.Zone.RACK:
			racks.append(s)
		elif column_clear(s):
			floor_slots.append(s)
	return racks if not racks.is_empty() else floor_slots


## Free rack and floor slots that an agent can reach (total free capacity).
func free_storage_slots() -> Array[StorageSlot]:
	var out: Array[StorageSlot] = []
	for s: StorageSlot in slots:
		if s.is_storage() and s.is_free() and s.reachable and (lift_available or not s.needs_lift()):
			out.append(s)
	return out


func free_storage_count() -> int:
	return free_storage_slots().size()


func first_free(zone: StorageSlot.Zone) -> StorageSlot:
	for s: StorageSlot in slots:
		if s.zone == zone and s.is_free():
			return s
	return null


## Free INBOUND / OUTBOUND slot to drop a pallet into: the deepest free slot
## whose column is clear between it and the open side, so a forklift never
## drives through a pallet. Columns fill from the back.
func drop_slot(zone: StorageSlot.Zone, unit: CargoUnit = null) -> StorageSlot:
	var best: StorageSlot = null
	var best_depth: float = INF
	for s: StorageSlot in slots:
		if s.zone != zone or not s.is_free() or not s.reachable or not column_clear(s) or not placement_ok(s, unit):
			continue
		var depth: float = s.position.dot(s.out_dir)
		if depth < best_depth - 0.01:
			best_depth = depth
			best = s
	return best


## True when no pallet sits (or is due) between the slot and the open side
## of its zone, in the same column.
func column_clear(slot: StorageSlot) -> bool:
	var my_depth: float = slot.position.dot(slot.out_dir)
	for s: StorageSlot in slots:
		if s == slot or s.zone != slot.zone:
			continue
		if s.unit == null and s.reserved_by == null:
			continue
		var lateral: Vector3 = s.position - slot.position
		lateral -= slot.out_dir * lateral.dot(slot.out_dir)
		if lateral.length() < 0.4 and s.position.dot(slot.out_dir) > my_depth + 0.1:
			return false
	return true


## May `unit` be set down in `slot` without blocking anyone? Never in a dock
## lane, a lane apron or another area's approach room; never with a pallet
## (or a reserved delivery) in its own approach, so the placer gets out the
## way it came; never in the approach of a slot another pallet is coming to,
## of a pallet due to be picked up, or of a slot in another area. A resting
## pallet with no job may be stacked in front of (zone columns).
func placement_ok(slot: StorageSlot, unit: CargoUnit) -> bool:
	if slot.keep_clear_hit:
		return false
	for q: StorageSlot in slot.access_blockers:
		if (q.unit != null and q.unit != unit) or (q.reserved_by != null and q.reserved_by != unit):
			return false
	for s: StorageSlot in slot.blocks_access_of:
		if s.reserved_by != null and s.reserved_by != unit:
			return false
		if s.unit == null or s.unit == unit:
			continue
		if s.zone != slot.zone or s.unit.job != null:
			return false
	return true


## Pallets standing in the slot's approach straight (in the way of anyone
## driving in), excluding `unit`.
func obstructions(slot: StorageSlot, unit: CargoUnit = null) -> Array[StorageSlot]:
	var out: Array[StorageSlot] = []
	for q: StorageSlot in slot.access_blockers:
		if q.unit != null and q.unit != unit:
			out.append(q)
	return out


## Where a pallet that stands in `blocked`'s way goes: a free slot it may
## stand in (placement_ok) outside that way, in its own area first (same
## lifecycle state: INBOUND, OUTBOUND, storage), else on the floor, else
## any free storage slot. Nearest first, preferring spots that block nobody.
func relocation_target(unit: CargoUnit, blocked: StorageSlot) -> StorageSlot:
	var from: StorageSlot = unit.slot
	var tiers: Array = []
	match from.zone:
		StorageSlot.Zone.INBOUND, StorageSlot.Zone.OUTBOUND:
			tiers.append(func(s: StorageSlot) -> bool: return s.zone == from.zone)
		_:
			tiers.append(func(s: StorageSlot) -> bool: return s.is_storage())
	tiers.append(func(s: StorageSlot) -> bool: return s.zone == StorageSlot.Zone.FLOOR)
	tiers.append(func(s: StorageSlot) -> bool: return s.is_storage())
	for tier: Callable in tiers:
		var best: StorageSlot = null
		var best_score: float = INF
		for s: StorageSlot in slots:
			if s == from or s == blocked or s.is_trailer() or not s.is_free() or not s.reachable:
				continue
			if not tier.call(s) or (s.needs_lift() and not lift_available):
				continue
			if s in blocked.access_blockers or not placement_ok(s, unit) or not column_clear(s):
				continue
			var blocking: int = 0
			for o: StorageSlot in s.blocks_access_of:
				if o.unit != null or o.reserved_by != null:
					blocking += 1
			var score: float = blocking * 100.0 + s.position.distance_to(from.position)
			if score < best_score:
				best_score = score
				best = s
		if best != null:
			return best
	return null


## Floor height for agents at p: 0, or the ramp / trailer bed of a dock lane.
func ground_height(p: Vector3) -> float:
	var h: float = 0.0
	for b: TrailerBay in bays:
		h = maxf(h, b.ground_height(p))
	return h


func zone_slots(zone: StorageSlot.Zone) -> Array[StorageSlot]:
	var out: Array[StorageSlot] = []
	for s: StorageSlot in slots:
		if s.zone == zone:
			out.append(s)
	return out


## Where an agent with the given reach stops to pick up or drop at a slot.
func approach_point(slot: StorageSlot, reach: float) -> Vector3:
	var p: Vector3 = slot.position + slot.out_dir * reach
	p.y = 0.0
	return p


func entry_point(slot: StorageSlot, reach: float) -> Vector3:
	return approach_point(slot, reach + ENTRY_EXTRA)


# --- occupancy -----------------------------------------------------------------

func reserve(slot: StorageSlot, unit: CargoUnit) -> void:
	slot.reserved_by = unit
	slots_changed.emit()


## The unit now sits in the slot.
func occupy(slot: StorageSlot, unit: CargoUnit) -> void:
	slot.unit = unit
	if slot.reserved_by == unit:
		slot.reserved_by = null
	unit.slot = slot
	slots_changed.emit()


## The unit left the slot.
func release(slot: StorageSlot) -> void:
	if slot.unit != null and slot.unit.slot == slot:
		slot.unit.slot = null
	slot.unit = null
	slots_changed.emit()


func show_markers(targets: Array[StorageSlot]) -> void:
	for s: StorageSlot in _markers:
		(_markers[s] as SlotMarker).set_shown(s in targets)


func hide_markers() -> void:
	show_markers([])


# --- building --------------------------------------------------------------------

## Fills a zone with slots. `open_dir` points from the zone to the side
## forklifts come in from; pallets lie with their 1.2 m side along it, rows
## are numbered from that open side (front row first).
func _build_zone(zone: StorageSlot.Zone, rect: Rect2, text: Label3D, open_dir: Vector3) -> void:
	var avoid: Rect2 = _label_rect(text) if text != null else Rect2()
	var along_x: bool = absf(open_dir.x) > 0.5
	# depth runs along open_dir; pitch.x across it, pitch.y along it
	var half: Vector2 = (Vector2(0.6, 0.4) if along_x else Vector2(0.4, 0.6)) + Vector2.ONE * zone_margin
	var pitch: Vector2 = Vector2(zone_pitch.y, zone_pitch.x) if along_x else zone_pitch
	var usable: Rect2 = rect.grow_individual(-half.x, -half.y, -half.x, -half.y)
	var nx: int = maxi(1, floori(usable.size.x / pitch.x) + 1)
	var nz: int = maxi(1, floori(usable.size.y / pitch.y) + 1)
	var centre: Vector2 = rect.get_center()
	var start: Vector2 = centre - Vector2(nx - 1, nz - 1) * pitch * 0.5
	var points: Array[Vector2] = []
	for ix: int in nx:
		for iz: int in nz:
			points.append(start + Vector2(ix * pitch.x, iz * pitch.y))
	var od: Vector2 = Vector2(open_dir.x, open_dir.z)
	# front (nearest the open side) first, then across
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		var da: float = snappedf(a.dot(od), 0.01)
		var db: float = snappedf(b.dot(od), 0.01)
		if da != db:
			return da > db
		return a.dot(od.orthogonal()) < b.dot(od.orthogonal()))
	var yaw: float = PI * 0.5 if not along_x else atan2(-open_dir.z, open_dir.x)
	var added: int = 0
	var prefix: String = "INBOUND" if zone == StorageSlot.Zone.INBOUND else "OUTBOUND"
	for p: Vector2 in points:
		if added >= GameplayConfig.ZONE_MAX_SLOTS:
			return
		var footprint: Rect2 = Rect2(p - half + Vector2.ONE * zone_margin, (half - Vector2.ONE * zone_margin) * 2.0)
		if avoid.has_area() and footprint.intersects(avoid):
			continue
		var sl: StorageSlot = _new_slot(zone, Vector3(p.x, 0.0, p.y), yaw, open_dir)
		sl.label = "%s-%02d" % [prefix, added + 1]
		added += 1


func _build_racks(level: Node3D) -> void:
	var centre: Vector3 = Vector3(inbound_rect.get_center().x, 0.0, inbound_rect.get_center().y)
	var front: float = -INF
	var rack_no: int = 0
	for node: Node in level.find_children("*", "Node3D", true, false):
		var rack: RackStock = node as RackStock
		if rack == null:
			continue
		rack_no += 1
		var basis: Basis = rack.global_basis.orthonormalized()
		var depth: Vector3 = Vector3(basis.z.x, 0.0, basis.z.z).normalized()
		if (centre - rack.global_position).dot(depth) < 0.0:
			depth = -depth
		var yaw: float = basis.get_euler().y + PI * 0.5
		for li: int in rack.level_count():
			for si: int in rack.slots_per_level():
				var s: StorageSlot = _new_slot(StorageSlot.Zone.RACK, rack.to_global(rack.slot_local_position(li, si)), yaw, depth)
				s.level = li
				s.house_stock = rack.is_slot_stocked(li, si)
				s.label = "%s-L%d-%d" % [rack_code(rack), li + 1, si + 1]
		var r: Rect2 = _footprint(rack, Vector2(2.8, 1.1)).grow(0.15)
		router.obstacles.append(r)
		front = maxf(front, r.end.y)
	router.aisle_z = (front + 1.3) if rack_no > 0 else 0.0


## Stable short name of a rack from its node name: "RackA1" -> "A1".
static func rack_code(rack: Node) -> String:
	var n: String = String(rack.name)
	return n.trim_prefix("Rack") if n.length() > 4 else n


func _build_floor(level: Node3D, decor: Array[Node3D]) -> void:
	var origin: Vector3 = floor_origin
	var marker: Node3D = level.find_child(String(floor_node_name), true, false) as Node3D
	if marker != null:
		origin = marker.global_position
	var n: int = 0
	for r: int in floor_rows:
		for c: int in floor_columns:
			var p: Vector3 = origin + Vector3(c * floor_pitch.x, 0.0, -r * floor_pitch.y)
			var s: StorageSlot = _new_slot(StorageSlot.Zone.FLOOR, p, PI * 0.5, Vector3.BACK)
			n += 1
			s.label = "FLOOR-%02d" % n
			for d: Node3D in decor:
				if d.visible and Vector2(d.global_position.x - p.x, d.global_position.z - p.z).length() < house_stock_radius:
					s.house_stock = true
					break


func _new_slot(zone: StorageSlot.Zone, pos: Vector3, yaw: float, out_dir: Vector3) -> StorageSlot:
	var s: StorageSlot = StorageSlot.new()
	s.id = slots.size()
	s.zone = zone
	s.position = pos
	s.yaw = yaw
	s.out_dir = out_dir
	slots.append(s)
	return s


func _house_count() -> int:
	var n: int = 0
	for s: StorageSlot in slots:
		if s.house_stock:
			n += 1
	return n


## Loose decorative pallets and boxes of the level.
func decor_nodes() -> Array[Node3D]:
	return _decor_nodes(_level)


## Hides level decor for which keep_clear(position) is true (dock aprons).
func hide_decor(keep_clear: Callable) -> int:
	var n: int = 0
	for d: Node3D in _decor_nodes(_level):
		if d.visible and keep_clear.call(d.global_position):
			d.visible = false
			n += 1
	return n


## Decorative pallets and boxes placed straight into the level (not part of a
## scripted prop like a rack or the unloading shuttle).
func _decor_nodes(level: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for node: Node in level.find_children("*", "Node3D", true, false):
		var n3: Node3D = node as Node3D
		if n3.scene_file_path.is_empty() or n3.get_parent() == null or n3.get_parent().get_script() != null:
			continue
		var file: String = n3.scene_file_path.get_file()
		for pattern: String in DECOR_PATTERNS:
			if file.begins_with(pattern):
				out.append(n3)
				break
	return out


func _zone_rect(level: Node3D, prefix: String, fallback: Rect2) -> Rect2:
	var outline: Node3D = level.find_child(prefix + "Outline", true, false) as Node3D
	if outline != null and outline.get(&"points") is PackedVector3Array:
		var pts: PackedVector3Array = outline.get(&"points")
		if pts.size() >= 3:
			var first: Vector3 = outline.to_global(pts[0])
			var rect: Rect2 = Rect2(Vector2(first.x, first.z), Vector2.ZERO)
			for p: Vector3 in pts:
				var g: Vector3 = outline.to_global(p)
				rect = rect.expand(Vector2(g.x, g.z))
			return rect
	var fill: MeshInstance3D = level.find_child(prefix + "Fill", true, false) as MeshInstance3D
	if fill != null:
		var box: AABB = fill.global_transform * fill.get_aabb()
		return Rect2(box.position.x, box.position.z, box.size.x, box.size.z)
	push_warning("StorageGrid: no %sOutline / %sFill in the level, using defaults" % [prefix, prefix])
	return fallback


## Ground rect covered by a flat zone label, estimated from its text so the
## result does not depend on font rendering (headless or not).
func _label_rect(label: Label3D) -> Rect2:
	var w: float = label.text.length() * label.font_size * label.pixel_size * 0.62
	var h: float = label.font_size * label.pixel_size
	var xf: Transform3D = label.global_transform
	var rect: Rect2 = Rect2()
	var first: bool = true
	for corner: Vector2 in [Vector2(-w, -h), Vector2(w, -h), Vector2(w, h), Vector2(-w, h)]:
		var g: Vector3 = xf * Vector3(corner.x * 0.5, corner.y * 0.5, 0.0)
		if first:
			rect = Rect2(Vector2(g.x, g.z), Vector2.ZERO)
			first = false
		else:
			rect = rect.expand(Vector2(g.x, g.z))
	return rect


func _footprint(node: Node3D, size: Vector2) -> Rect2:
	var xf: Transform3D = node.global_transform
	var rect: Rect2 = Rect2()
	var first: bool = true
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var g: Vector3 = xf * Vector3(corner.x * size.x * 0.5, 0.0, corner.y * size.y * 0.5)
		if first:
			rect = Rect2(Vector2(g.x, g.z), Vector2.ZERO)
			first = false
		else:
			rect = rect.expand(Vector2(g.x, g.z))
	return rect


func _in_rect(rect: Rect2, p: Vector3) -> bool:
	return rect.has_point(Vector2(p.x, p.z))
