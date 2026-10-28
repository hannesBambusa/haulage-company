@tool
class_name TruckRig
extends Node3D
## Semi tractor and an optional box trailer. The trailer is coupled at runtime
## by putting its Kingpin over the cab's FifthWheel, so trailer length changes
## in the .glb need no scene edits.
## Rig origin = rear centre of the trailer (or cab) on the ground, front is -Z.
##
## At runtime drive() moves the rig with a tractor-trailer kinematic model:
## the tractor is a bicycle (rear axle + steered front axle), the trailer
## heading follows dθt/ds = sin(θc - θt) / L_t (plus the fifth-wheel offset
## term when the coupling is not over the drive axle). The rig node itself
## follows the trailer; the cab pivots about the kingpin by the articulation,
## so the kingpin never leaves the fifth wheel.
## Headings are Godot yaws (rotation.y): forward = (-sin θ, -cos θ) in XZ.

signal doors_changed(open: bool)
signal parked_changed(parked: bool)

@export var cab_scene: PackedScene:
	set(value):
		cab_scene = value
		_rebuild_if_ready()
@export var trailer_scene: PackedScene:
	set(value):
		trailer_scene = value
		_rebuild_if_ready()
## Adds a small red glow at the trailer rear.
@export var brake_lights: bool = false:
	set(value):
		brake_lights = value
		_rebuild_if_ready()

## Parked at a dock, the trailer's sides and roof fade to see-through so
## the pallets inside stay visible (bed, chassis and wheels stay solid).
@export var xray_when_parked: bool = true
@export_range(0.0, 1.0) var xray_alpha: float = 0.15
@export_group("Kinematics")
@export_range(10.0, 45.0) var max_steer_deg: float = 35.0
## Hard articulation limit (jackknife guard). Drivers should stay inside it.
@export_range(30.0, 89.0) var max_articulation_deg: float = 80.0
## Integration step along the path, metres.
@export var substep: float = 0.05

@export_group("Rear doors")
@export var door_open_deg: float = 270.0
## Swing direction per door (sign of the yaw); DoorL swings out to the left.
@export var door_l_sign: float = -1.0
@export var door_r_sign: float = 1.0
@export var door_time: float = 1.4
## Multiplies door animation speed (the driver sets it to the game speed).
var door_speed_scale: float = 1.0

const BED_HEIGHT: float = 1.15

var cab: Node3D
var trailer: Node3D

## Geometry along the rig's straight axis, in rig space (front = -Z).
var wheelbase: float = 3.45  ## cab front axle to cab rear axle
var trailer_length: float = 4.6  ## kingpin to trailer axle group centre (L_t)
var hitch_offset: float = 0.0  ## fifth wheel behind the cab rear axle
var rear_overhang: float = 2.0  ## trailer axle centre to trailer rear

var _cab_base: Transform3D
var _kingpin_z: float = 0.0  ## rig-space z of the kingpin (straight pose)
var _cab_axle_z: float = 0.0
var _front_axle_z: float = 0.0
var _trailer_axle_z: float = 0.0

## State. Trailer pose = this node's transform; articulation = θc - θt.
var _articulation: float = 0.0
var _steer: float = 0.0
var _parked: bool = false

var _front_wheels: Array[Node3D] = []
var _cab_wheels: Array[Node3D] = []
var _trailer_wheels: Array[Node3D] = []
var _wheel_base: Dictionary = {}  ## Node3D -> Transform3D
var _wheel_spin: Dictionary = {}  ## Node3D -> float
var _wheel_radius: Dictionary = {}  ## Node3D -> float
var _reverse_lights: Array[Node3D] = []

var _doors: Array[Node3D] = []
var _door_base: Array[Basis] = []
var _door_sign: Array[float] = []
var _door_amount: float = 0.0
var _doors_open: bool = false
var _door_tween: Tween


func _ready() -> void:
	_rebuild()


func _rebuild_if_ready() -> void:
	if is_node_ready():
		_rebuild()


func _rebuild() -> void:
	for c: Node in get_children():
		if c.has_meta(&"truck_rig_part"):
			remove_child(c)
			c.queue_free()
	cab = null
	trailer = null
	_xray_mats.clear()
	_front_wheels.clear()
	_cab_wheels.clear()
	_trailer_wheels.clear()
	_wheel_base.clear()
	_wheel_spin.clear()
	_wheel_radius.clear()
	_reverse_lights.clear()
	_doors.clear()
	_door_base.clear()
	_door_sign.clear()
	_articulation = 0.0
	_steer = 0.0
	if cab_scene == null:
		return
	cab = _add_part(cab_scene)
	if trailer_scene == null:
		cab.position.z = -_rear_z(cab)
		_measure_cab()
		_cab_base = cab.transform
		return
	trailer = _add_part(trailer_scene)
	trailer.position.z = -_rear_z(trailer)
	var kingpin: Node3D = trailer.find_child("Kingpin", true, false) as Node3D
	var fifth: Node3D = cab.find_child("FifthWheel", true, false) as Node3D
	if kingpin == null or fifth == null:
		push_warning("%s: Kingpin or FifthWheel empty missing" % name)
		_measure_cab()
		_cab_base = cab.transform
		return
	var kp: Vector3 = _local_pos(kingpin)
	var fw: Vector3 = _local_pos(fifth)
	cab.position += Vector3(kp.x - fw.x, 0.0, kp.z - fw.z)
	_cab_base = cab.transform
	if absf(kp.y - fw.y) > 0.08:
		push_warning("%s: Kingpin %.2f m vs FifthWheel %.2f m height" % [name, kp.y, fw.y])
	_kingpin_z = kp.z
	_measure_cab()
	hitch_offset = _kingpin_z - _cab_axle_z
	_trailer_axle_z = _axle_z(_trailer_wheels, _kingpin_z + 4.6)
	trailer_length = _trailer_axle_z - _kingpin_z
	rear_overhang = -_trailer_axle_z
	for door_name: String in ["DoorL", "DoorR"]:
		var door: Node3D = trailer.find_child(door_name, true, false) as Node3D
		if door != null:
			_doors.append(door)
			_door_base.append(door.basis)
			_door_sign.append(door_l_sign if door_name == "DoorL" else door_r_sign)
	_reverse_lights.append_array(_find_reverse_lights(trailer))
	if brake_lights:
		var glow: OmniLight3D = OmniLight3D.new()
		glow.set_meta(&"truck_rig_part", true)
		glow.light_color = Color(1.0, 0.12, 0.08)
		glow.light_energy = 1.5
		glow.omni_range = 1.6
		glow.position = Vector3(0.0, 1.0, 0.35)
		add_child(glow)


func _measure_cab() -> void:
	for w: Node in cab.find_children("Wheel_*", "Node3D", true, false):
		var wheel: Node3D = w as Node3D
		_register_wheel(wheel)
		if String(wheel.name).begins_with("Wheel_F"):
			_front_wheels.append(wheel)
		else:
			_cab_wheels.append(wheel)
	_front_axle_z = _axle_z(_front_wheels, -3.0)
	_cab_axle_z = _axle_z(_cab_wheels, 0.0)
	wheelbase = maxf(_cab_axle_z - _front_axle_z, 1.0)
	_reverse_lights.append_array(_find_reverse_lights(cab))
	if trailer != null:
		for w: Node in trailer.find_children("Wheel_*", "Node3D", true, false):
			_register_wheel(w as Node3D)
			_trailer_wheels.append(w as Node3D)


func _register_wheel(wheel: Node3D) -> void:
	_wheel_base[wheel] = wheel.transform
	_wheel_spin[wheel] = 0.0
	_wheel_radius[wheel] = maxf(_local_pos(wheel).y, 0.2)


## Mean rig-space z of a wheel set (fallback if empty).
func _axle_z(wheels: Array[Node3D], fallback: float) -> float:
	if wheels.is_empty():
		return fallback
	var z: float = 0.0
	for w: Node3D in wheels:
		z += _local_pos(w).z
	return z / wheels.size()


func _find_reverse_lights(part: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n: Node in part.find_children("*", "Node3D", true, false):
		if String(n.name).to_lower().contains("revers"):
			(n as Node3D).visible = false
			out.append(n as Node3D)
	return out


func _add_part(scene: PackedScene) -> Node3D:
	var part: Node3D = scene.instantiate() as Node3D
	part.set_meta(&"truck_rig_part", true)
	add_child(part)
	return part


## Position of a descendant in this rig's space (straight pose), without
## needing the tree.
func _local_pos(node: Node3D) -> Vector3:
	var xf: Transform3D = Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != self:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf.origin


## Largest local Z of the part's visible meshes (its rear end).
func _rear_z(part: Node3D) -> float:
	var rear: float = 0.0
	for mi: Node in part.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi as MeshInstance3D
		if String(m.name).ends_with("-colonly"):
			continue
		var xf: Transform3D = Transform3D.IDENTITY
		var n: Node = m
		while n != null and n != part:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var box: AABB = xf * m.get_aabb()
		rear = maxf(rear, box.end.z)
	return rear


# --- kinematic state (parent space, XZ as Vector2(x, z)) ---------------------

static func heading_dir(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


static func dir_yaw(dir: Vector2) -> float:
	return atan2(-dir.x, -dir.y)


func trailer_yaw() -> float:
	return rotation.y


func tractor_yaw() -> float:
	return rotation.y + _articulation


## Articulation θc - θt in radians (positive = cab turned left of trailer).
func articulation() -> float:
	return _articulation


func steer() -> float:
	return _steer


func max_steer() -> float:
	return deg_to_rad(max_steer_deg)


func max_articulation() -> float:
	return deg_to_rad(max_articulation_deg)


func kingpin_2d() -> Vector2:
	return _rig_point(_kingpin_z)


func trailer_axle_2d() -> Vector2:
	return _rig_point(_trailer_axle_z)


func trailer_rear_2d() -> Vector2:
	return Vector2(position.x, position.z)


func tractor_axle_2d() -> Vector2:
	return kingpin_2d() + heading_dir(tractor_yaw()) * hitch_offset


func front_axle_2d() -> Vector2:
	return tractor_axle_2d() + heading_dir(tractor_yaw()) * wheelbase


## Straight rig-space point on the trailer axis, in parent space.
func _rig_point(z: float) -> Vector2:
	return trailer_rear_2d() - heading_dir(rotation.y) * z


## Places the rig with the trailer rear at `rear` (parent space XZ), trailer
## heading `yaw_t` and the given articulation.
func place(rear: Vector2, yaw_t: float, articulation_rad: float = 0.0) -> void:
	position = Vector3(rear.x, position.y, rear.y)
	rotation = Vector3(0.0, yaw_t, 0.0)
	_articulation = articulation_rad
	_apply_cab()


## Places the rig so the tractor rear axle sits at `axle`, tractor heading
## `yaw_c`, articulation `articulation_rad`.
func place_tractor(axle: Vector2, yaw_c: float, articulation_rad: float = 0.0) -> void:
	var yaw_t: float = yaw_c - articulation_rad
	var kp: Vector2 = axle - heading_dir(yaw_c) * hitch_offset
	place(kp + heading_dir(yaw_t) * _kingpin_z, yaw_t, articulation_rad)


## Moves the tractor rear axle `distance` metres along its heading (negative =
## reversing) with the front wheels at `steer_rad` (positive = left). The
## trailer follows the kingpin. Wheels spin by the distance each axle rolled.
func drive(distance: float, steer_rad: float) -> void:
	_steer = clampf(steer_rad, -max_steer(), max_steer())
	if absf(distance) < 0.000001:
		_apply_wheels(0.0, 0.0, 0.0)
		return
	var steps: int = maxi(1, ceili(absf(distance) / maxf(substep, 0.005)))
	var ds: float = distance / steps
	var axle: Vector2 = tractor_axle_2d()
	var yaw_c: float = tractor_yaw()
	var yaw_t: float = trailer_yaw()
	var front_old: Vector2 = front_axle_2d()
	var trailer_old: Vector2 = trailer_axle_2d()
	var curvature: float = tan(_steer) / wheelbase
	var limit: float = max_articulation()
	for i: int in steps:
		var gamma: float = yaw_c - yaw_t
		var yaw_rate: float = ds * curvature
		axle += heading_dir(yaw_c + yaw_rate * 0.5) * ds
		yaw_c += yaw_rate
		# dθt = (ds sin γ - h dθc cos γ) / L_t, h = fifth wheel behind the axle
		yaw_t += (ds * sin(gamma) - hitch_offset * yaw_rate * cos(gamma)) / trailer_length
		var g: float = wrapf(yaw_c - yaw_t, -PI, PI)
		if absf(g) > limit:
			yaw_t = yaw_c - clampf(g, -limit, limit)
	var kp: Vector2 = axle - heading_dir(yaw_c) * hitch_offset
	place(kp + heading_dir(yaw_t) * _kingpin_z, yaw_t, wrapf(yaw_c - yaw_t, -PI, PI))
	var front_roll: float = (front_axle_2d() - front_old).dot(heading_dir(yaw_c + _steer))
	var trailer_roll: float = (trailer_axle_2d() - trailer_old).dot(heading_dir(yaw_t))
	_apply_wheels(front_roll, distance, trailer_roll)


func _apply_cab() -> void:
	if cab == null:
		return
	var pivot: Vector3 = Vector3(0.0, 0.0, _kingpin_z)
	var turn: Transform3D = Transform3D(Basis(Vector3.UP, _articulation), pivot) \
			* Transform3D(Basis.IDENTITY, -pivot)
	cab.transform = turn * _cab_base


func _apply_wheels(front_roll: float, cab_roll: float, trailer_roll: float) -> void:
	for w: Node3D in _front_wheels:
		_spin(w, front_roll, _steer)
	for w: Node3D in _cab_wheels:
		_spin(w, cab_roll, 0.0)
	for w: Node3D in _trailer_wheels:
		_spin(w, trailer_roll, 0.0)


## Forward roll turns the wheel top toward -Z (negative angle about +X).
func _spin(w: Node3D, roll: float, steer_rad: float) -> void:
	var angle: float = wrapf(float(_wheel_spin[w]) - roll / float(_wheel_radius[w]), -TAU, TAU)
	_wheel_spin[w] = angle
	var base: Transform3D = _wheel_base[w]
	w.transform = Transform3D(Basis(Vector3.UP, steer_rad) * Basis(Vector3.RIGHT, angle) * base.basis, base.origin)


## How far the RearEntry sill sits forward of the rig origin (the rearmost
## mesh point, e.g. door hinge knuckles); 0 without a RearEntry empty.
func rear_entry_offset() -> float:
	if trailer == null:
		return 0.0
	var entry: Node3D = trailer.find_child("RearEntry", true, false) as Node3D
	return maxf(-_local_pos(entry).z, 0.0) if entry != null else 0.0


## Distance between the trailer Kingpin and the cab FifthWheel (should be 0).
func coupling_error() -> float:
	if cab == null or trailer == null:
		return 0.0
	var kp: Node3D = trailer.find_child("Kingpin", true, false) as Node3D
	var fw: Node3D = cab.find_child("FifthWheel", true, false) as Node3D
	if kp == null or fw == null:
		return 0.0
	var a: Vector3 = kp.global_position
	var b: Vector3 = fw.global_position
	return Vector2(a.x - b.x, a.z - b.z).length()


func set_reversing(on: bool) -> void:
	for light: Node3D in _reverse_lights:
		light.visible = on


func set_parked(parked: bool) -> void:
	if parked == _parked:
		return
	_parked = parked
	if xray_when_parked:
		set_xray(parked)
	parked_changed.emit(parked)


## Trailer materials faded by set_xray(): the white shell (sides, roof,
## front) and the cargo walls, rails and ribs inside it.
const XRAY_MATERIALS: PackedStringArray = ["M_trailer_white", "M_cargo_wall", "M_cargo_rail", "M_cargo_rib"]
const XRAY_TIME: float = 0.6

var _xray_mats: Array[BaseMaterial3D] = []
var _xray_tween: Tween = null


## Fades the trailer's sides and roof to xray_alpha (on) or back to solid.
## The shell casts no shadow while faded, so the load is not in its shade.
func set_xray(on: bool) -> void:
	var body: MeshInstance3D = trailer.find_child("Body", true, false) as MeshInstance3D if trailer != null else null
	if body == null:
		return
	if _xray_mats.is_empty():
		for i: int in body.mesh.get_surface_count():
			var src: BaseMaterial3D = body.mesh.surface_get_material(i) as BaseMaterial3D
			if src == null or not src.resource_name in XRAY_MATERIALS:
				continue
			var m: BaseMaterial3D = src.duplicate() as BaseMaterial3D
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			m.cull_mode = BaseMaterial3D.CULL_BACK
			body.set_surface_override_material(i, m)
			_xray_mats.append(m)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if _xray_tween != null:
		_xray_tween.kill()
	_xray_tween = create_tween().set_parallel(true)
	for m: BaseMaterial3D in _xray_mats:
		_xray_tween.tween_property(m, ^"albedo_color:a", xray_alpha if on else 1.0, XRAY_TIME)


func is_parked() -> bool:
	return _parked


# --- interface for the unloading side ----------------------------------------

## Swings the trailer's DoorL/DoorR open (flat against the sides) or shut.
## doors_changed(open) fires when the swing finishes (at once if the trailer
## has no doors or `instant`).
func open_rear_doors(open: bool, instant: bool = false) -> void:
	if _door_tween != null:
		_door_tween.kill()
		_door_tween = null
	_doors_open = open
	var target: float = 1.0 if open else 0.0
	if _doors.is_empty() or instant or not is_inside_tree():
		_set_door_amount(target)
		doors_changed.emit(open)
		return
	var duration: float = door_time * absf(target - _door_amount) / maxf(door_speed_scale, 0.01)
	_door_tween = create_tween()
	_door_tween.tween_method(_set_door_amount, _door_amount, target, maxf(duration, 0.01)) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_door_tween.finished.connect(func() -> void: doors_changed.emit(open))


func are_doors_open() -> bool:
	return _doors_open and _door_amount >= 1.0


func _set_door_amount(amount: float) -> void:
	_door_amount = amount
	var angle: float = deg_to_rad(door_open_deg) * amount
	for i: int in _doors.size():
		_doors[i].basis = Basis(Vector3.UP, _door_sign[i] * angle) * _door_base[i]


## Global transforms of the trailer's Slot_01..Slot_10 empties, in order.
func get_cargo_slots() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if trailer == null:
		return out
	for i: int in range(1, 11):
		var slot: Node3D = trailer.find_child("Slot_%02d" % i, true, false) as Node3D
		if slot != null:
			out.append(slot.global_transform)
	return out


## Global transform of the trailer's RearEntry empty, else the rear centre at
## bed height (basis = trailer's, so -Z points into the trailer).
func get_rear_entry() -> Transform3D:
	if trailer != null:
		var entry: Node3D = trailer.find_child("RearEntry", true, false) as Node3D
		if entry != null:
			return entry.global_transform
	var xf: Transform3D = global_transform
	return Transform3D(xf.basis, xf * Vector3(0.0, BED_HEIGHT, 0.0))
