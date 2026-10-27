class_name TrailerBay
extends Node
## The lane between one dock's leveler ramp and the trailer parked at it.
## Knows the ramp (RampBottom / RampTop empties in the dock_door), the parked
## truck (from its TruckDriver), the trailer's cargo slots and its rear doors.
## Gives agents the floor height along the lane, so they climb the ramp, and
## the waypoints into and out of the trailer. Only one agent may be inside the
## lane (ramp + trailer) at a time: try_reserve() / release().
## Created and owned by CargoFlow, one per dock.

signal freed
signal doors_changed(open: bool)

## Fallback leveler geometry when the dock_door has no ramp empties.
const FALLBACK_RAMP_LENGTH: float = 3.2
const FALLBACK_BED_HEIGHT: float = 1.15
## Half width of the lane (ramp and trailer interior), for height queries.
const LANE_HALF_WIDTH: float = 1.3
## Trailer interior length past the rear entry, for height queries.
const TRAILER_DEPTH: float = 14.0

## Metres in front of RampBottom where agents line up before climbing.
@export var stage_distance: float = 2.6
## Where a second agent queues while the lane is taken: this far behind
## RampBottom and wait_side to the side away from `toward`, clear of the
## first agent's way out.
@export var wait_distance: float = 9.5
@export var wait_side: float = 3.8

var dock: Dock = null
## Where loads from this dock usually go (the INBOUND zone centre).
var toward: Vector3 = Vector3.ZERO
var driver: Node3D = null
var door: Node3D = null
## Parked truck rig and its trailer node (pallets are parented to it).
var rig: Node3D = null
var trailer: Node3D = null
var slots: Array[StorageSlot] = []
var doors_open: bool = false
## Agent inside the lane, or null.
var occupant: Object = null
## Queue spot chosen by Traffic (clear of walls and zones): [Vector2, yaw].
var wait_spot: Array = []

## Unit vector on the ground from the warehouse towards the truck.
var axis: Vector3 = Vector3.BACK
var lateral: Vector3 = Vector3.RIGHT
var ramp_bottom: Vector3 = Vector3.ZERO
var ramp_top: Vector3 = Vector3.ZERO


func setup(p_dock: Dock, p_driver: Node3D, p_door: Node3D) -> void:
	dock = p_dock
	driver = p_driver
	door = p_door
	name = "Bay%d" % dock.dock_id
	_measure_lane()


func _measure_lane() -> void:
	var door_pos: Vector3 = door.global_position if door != null else Vector3.ZERO
	axis = Vector3.BACK
	var pts: Variant = driver.get(&"reverse_points") if driver != null else null
	if pts is PackedVector3Array and (pts as PackedVector3Array).size() >= 2:
		var p: PackedVector3Array = pts
		var d: Vector3 = p[p.size() - 2] - p[p.size() - 1]
		d.y = 0.0
		if d.length() > 0.01:
			axis = d.normalized()
	lateral = Vector3(axis.z, 0.0, -axis.x)
	var bottom: Node3D = door.find_child("RampBottom", true, false) as Node3D if door != null else null
	var top: Node3D = door.find_child("RampTop", true, false) as Node3D if door != null else null
	if bottom != null and top != null:
		ramp_bottom = bottom.global_position
		ramp_top = top.global_position
	else:
		ramp_bottom = door_pos - axis * FALLBACK_RAMP_LENGTH
		ramp_bottom.y = 0.0
		ramp_top = door_pos + Vector3(0.0, FALLBACK_BED_HEIGHT, 0.0)
		print("TrailerBay %d: dock door has no RampBottom/RampTop, using a %.1f m fallback ramp" % [dock.dock_id, FALLBACK_RAMP_LENGTH])


# --- truck -------------------------------------------------------------------

## The newest truck rig of this dock's driver (the one arriving or parked).
func find_rig() -> Node3D:
	if driver == null:
		return null
	var found: Node3D = null
	for c: Node in driver.get_children():
		if c is TruckRig and not c.is_queued_for_deletion():
			found = c as Node3D
	return found


## Binds the truck that just spawned or parked. late = it is already parked
## (doors already opened before we listened).
func bind_rig(p_rig: Node3D, late: bool) -> void:
	if p_rig == rig:
		return
	unbind_rig()
	rig = p_rig
	if rig == null:
		return
	var t: Variant = rig.get(&"trailer")
	trailer = t as Node3D if t is Node3D else rig
	if rig.has_signal(&"doors_changed"):
		rig.connect(&"doors_changed", _on_doors_changed)
		doors_open = bool(rig.call(&"are_doors_open")) if rig.has_method(&"are_doors_open") else late
	else:
		doors_open = true
	_build_slots()


func unbind_rig() -> void:
	if rig != null and is_instance_valid(rig) and rig.is_connected(&"doors_changed", _on_doors_changed):
		rig.disconnect(&"doors_changed", _on_doors_changed)
	rig = null
	trailer = null
	slots.clear()
	doors_open = false


func has_truck() -> bool:
	return rig != null and is_instance_valid(rig)


func _on_doors_changed(open: bool) -> void:
	doors_open = open
	doors_changed.emit(open)


func rear_entry() -> Transform3D:
	if has_truck() and rig.has_method(&"get_rear_entry"):
		return rig.call(&"get_rear_entry")
	if has_truck():
		return rig.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, FALLBACK_BED_HEIGHT, 0.0))
	return Transform3D(Basis.IDENTITY, ramp_top + axis * 0.8)


func bed_height() -> float:
	return rear_entry().origin.y


func _build_slots() -> void:
	slots.clear()
	var xfs: Array = []
	if rig.has_method(&"get_cargo_slots"):
		xfs = rig.call(&"get_cargo_slots")
	if xfs.is_empty():
		xfs = _fallback_slots()
	var inv: Transform3D = trailer.global_transform.affine_inverse()
	# the truck may still be on its way in: compare with the trailer's own axis
	var length_axis: Vector3 = trailer.global_basis.z
	length_axis.y = 0.0
	length_axis = length_axis.normalized()
	for i: int in xfs.size():
		var xf: Transform3D = xfs[i]
		# pallets ride with their 1.2 m side (model X) along the trailer
		var x: Vector3 = xf.basis.x
		x.y = 0.0
		if x.length() > 0.01 and absf(x.normalized().dot(length_axis)) < 0.7:
			xf.basis = xf.basis * Basis(Vector3.UP, PI * 0.5)
		xfs[i] = xf
		var s: StorageSlot = StorageSlot.new()
		s.zone = StorageSlot.Zone.TRAILER
		s.id = 10000 + dock.dock_id * 100 + i
		s.index = i
		s.anchor = trailer
		s.local = inv * (xfs[i] as Transform3D)
		s.out_dir = -axis
		s.bay = self
		s.label = "T-Dock%d-%02d" % [dock.dock_id, i + 1]
		slots.append(s)


## 2 across x 5 rows from the nose, pallets 1.2 m along the trailer, for a
## trailer without Slot_* empties. Rig origin = trailer rear on the ground,
## front is -Z.
func _fallback_slots() -> Array:
	var out: Array = []
	for row: int in 5:
		for col: int in 2:
			var local: Vector3 = Vector3(-0.6 + col * 1.2, FALLBACK_BED_HEIGHT, -7.0 + row * 1.25)
			out.append(rig.global_transform * Transform3D(Basis(Vector3.UP, PI * 0.5), local))
	return out


## Free slot for the next pallet to load: Slot_01 first.
func next_free_slot() -> StorageSlot:
	for s: StorageSlot in slots:
		if s.is_free():
			return s
	return null


## Occupied slots, rearmost (nearest the doors) first.
func slots_rear_first() -> Array[StorageSlot]:
	var out: Array[StorageSlot] = slots.duplicate()
	out.sort_custom(func(a: StorageSlot, b: StorageSlot) -> bool: return along(a.position) < along(b.position))
	return out


# --- lane geometry -------------------------------------------------------------

## Distance along the lane from RampBottom (towards the truck).
func along(p: Vector3) -> float:
	return Vector3(p.x - ramp_bottom.x, 0.0, p.z - ramp_bottom.z).dot(axis)


func across(p: Vector3) -> float:
	return Vector3(p.x - ramp_bottom.x, 0.0, p.z - ramp_bottom.z).dot(lateral)


func ramp_length() -> float:
	return maxf(along(ramp_top), 0.01)


## Ground point on the lane at distance s and lateral offset (y = 0).
func lane_point(s: float, offset: float) -> Vector3:
	var p: Vector3 = ramp_bottom + axis * s + lateral * offset
	p.y = 0.0
	return p


## Floor height under p, or -INF when p is not on this lane.
func ground_height(p: Vector3) -> float:
	var s: float = along(p)
	if s < 0.0 or absf(across(p)) > LANE_HALF_WIDTH:
		return -INF
	var length: float = ramp_length()
	if s <= length:
		return lerpf(ramp_bottom.y, ramp_top.y, s / length)
	if not has_truck():
		return ramp_top.y if s <= length + 0.6 else -INF
	var entry: Transform3D = rear_entry()
	var s_entry: float = along(entry.origin)
	if s > s_entry + TRAILER_DEPTH:
		return -INF
	if s <= s_entry and s_entry > length + 0.01:
		return lerpf(ramp_top.y, entry.origin.y, (s - length) / (s_entry - length))
	return entry.origin.y


## True when p is inside the trailer (past the rear entry).
func in_trailer(p: Vector3) -> bool:
	if not has_truck():
		return false
	var s: float = along(p) - along(rear_entry().origin)
	return s > 0.05 and s < TRAILER_DEPTH and absf(across(p)) < LANE_HALF_WIDTH


## Lateral offset of the slot's column from the lane centre line.
func column_offset(slot: StorageSlot) -> float:
	return across(slot.position)


## Floor point where an agent lines up for the slot's column, facing the truck.
func stage_point(slot: StorageSlot) -> Vector3:
	return lane_point(-stage_distance, column_offset(slot))


## Where an agent waits while another one is in the lane: [Vector2, yaw],
## facing the truck.
func wait_pose(slot: StorageSlot) -> Array:
	if not wait_spot.is_empty():
		return wait_spot
	var side: float = -1.0 if across(toward) >= 0.0 else 1.0
	var p: Vector3 = lane_point(-wait_distance, column_offset(slot) + side * wait_side)
	return [Vector2(p.x, p.z), atan2(-axis.x, -axis.z)]


## Waypoints from the stage point up the ramp to where the agent's origin
## stops so its load centre is `reach` ahead over the slot. The whole route is
## driven at ramp speed.
func entry_route(slot: StorageSlot, reach: float) -> PackedVector3Array:
	var off: float = column_offset(slot)
	var s_entry: float = along(rear_entry().origin)
	var s_stop: float = along(slot.position) - reach
	var pts: PackedVector3Array = PackedVector3Array([lane_point(0.0, off), lane_point(ramp_length(), off)])
	if s_entry > ramp_length() + 0.05:
		pts.append(lane_point(s_entry, off))
	pts.append(lane_point(maxf(s_stop, s_entry + 0.1), off))
	return pts


## Reverse waypoints from the slot back down to the stage point.
func exit_route(slot: StorageSlot) -> PackedVector3Array:
	var off: float = column_offset(slot)
	var s_entry: float = along(rear_entry().origin)
	var pts: PackedVector3Array = PackedVector3Array()
	if s_entry > ramp_length() + 0.05:
		pts.append(lane_point(s_entry, off))
	pts.append(lane_point(ramp_length(), off))
	pts.append(lane_point(0.0, off))
	pts.append(lane_point(-stage_distance, off))
	return pts


## Floor in front of the ramp that agents line up, queue and manoeuvre on
## (wide on the side away from `toward`, where the queue waits).
func on_apron(p: Vector3) -> bool:
	var s: float = along(p)
	if s < -wait_distance - 3.0 or s > 0.5:
		return false
	var side: float = across(p) * (1.0 if across(toward) >= 0.0 else -1.0)
	return side > -wait_side - 2.2 and side < 1.8


# --- reservation ---------------------------------------------------------------

func is_free_for(agent: Object) -> bool:
	return occupant == null or occupant == agent


func try_reserve(agent: Object) -> bool:
	if not is_free_for(agent):
		return false
	occupant = agent
	return true


func release(agent: Object) -> void:
	if occupant != agent:
		return
	occupant = null
	freed.emit()
