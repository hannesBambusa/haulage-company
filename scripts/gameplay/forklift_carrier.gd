class_name ForkliftCarrier
extends CarryAgent
## Drives a forklift.glb for carry jobs. Each forklift has one role (its own
## driver): the Unloader empties trailers into INBOUND, the Rack forklift
## puts pallets away and picks them to OUTBOUND (it reaches the upper beam
## levels), the Loader fills pickup trailers from OUTBOUND. Rear-wheel steered: arcs no tighter than 1.8 m about the front
## axle, never turning on the spot. The Forks child (origin at the heel)
## moves at LIFT_SPEED, only while stopped or creeping: down to set a pallet
## on its slot, about 0.1 m up to carry, higher on the leveler ramp so the
## fork tips and the load clear the slope, and up to the beam for racks.
## Wheels roll with the distance driven; the rear wheels steer.

## Forks height with the blades on the floor (pallet resting on its slot).
const FORKS_DOWN: float = 0.02
## Lift above FORKS_DOWN while carrying.
const CARRY_LIFT: float = 0.1
## Forks height on the ramp, so the tips clear the slope.
const RAMP_FORKS: float = 0.55
## Clearance over a rack beam when sliding a pallet in or out.
const BEAM_CLEARANCE: float = 0.1
## Fork lift speed in m/s at 1x.
const LIFT_SPEED: float = 0.35
const FRONT_WHEEL_R: float = 0.32
const REAR_WHEEL_R: float = 0.26
## Body (mast to counterweight) and forks, local Z, and half widths.
const BODY_Z: Vector2 = Vector2(-0.42, 1.56)
const BODY_HALF_W: float = 0.63
const FORK_TIP_Z: float = -1.56
const FORK_HALF_W: float = 0.47

var number: int = 1
var role: CarryJob.Role = CarryJob.Role.UNLOADER
var _forks: Node3D = null
var _heel_z: float = -0.44
var _fork_target: float = FORKS_DOWN
var _front_wheels: Array[Node3D] = []
var _rear_wheels: Array[Node3D] = []
var _wheel_base: Dictionary = {}  ## Node3D -> Basis
var _wheel_roll: Dictionary = {}  ## Node3D -> float
var _load_depth: float = 0.0


func setup(p_body: Node3D, p_grid: StorageGrid, p_number: int, p_role: CarryJob.Role) -> void:
	body = p_body
	grid = p_grid
	number = p_number
	role = p_role
	label = "Forklift %d (%s)" % [p_number, CarryJob.ROLE_NAMES[p_role]]
	move_speed = 2.0
	lane_speed = 1.2
	turn_speed = 1.2
	reverse_speed = 1.2
	accel = 1.0
	creep_speed = 0.4
	min_turn_radius = 1.8
	handover_time = 0.35
	axle_front = 0.15
	axle_rear = 1.07
	_forks = p_body.find_child("Forks", true, false) as Node3D
	if _forks != null:
		_heel_z = _forks.position.z
		_forks.position.y = FORKS_DOWN
	else:
		push_warning("ForkliftCarrier: forklift has no Forks node, pallets ride at ground level")
	load_heel = -_heel_z
	for w: String in ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]:
		var n: Node3D = p_body.find_child(w, true, false) as Node3D
		if n == null:
			continue
		_wheel_base[n] = n.basis
		_wheel_roll[n] = 0.0
		if w.begins_with("Wheel_F"):
			_front_wheels.append(n)
		else:
			_rear_wheels.append(n)
	_sync_pose()
	set_home_here()


## Only jobs of its own role: Unloader, Rack or Loader (never jack jobs).
func suits(p_job: CarryJob) -> bool:
	return p_job.role() == role and not p_job.wants_worker()


func footprints_at(p: Vector2, yaw_at: float, bare: bool = false) -> Array:
	var out: Array = [FootprintBox.local_span(p, yaw_at, BODY_Z.x, BODY_Z.y, BODY_HALF_W)]
	if not bare:
		var tip: float = FORK_TIP_Z
		if _load_depth > 0.0:
			tip = minf(tip, _heel_z - _load_depth - 0.03)
		out.append(FootprintBox.local_span(p, yaw_at, tip, BODY_Z.x, FORK_HALF_W))
	return out


func footprint_variant() -> float:
	return _load_depth


func body_boxes_at(p: Vector2, yaw_at: float) -> Array:
	return [FootprintBox.local_span(p, yaw_at, BODY_Z.x, BODY_Z.y, BODY_HALF_W)]


## Forks height (forklift space) that puts a pallet bottom at world height y.
func _forks_for(y: float) -> float:
	return y - body.global_position.y + FORKS_DOWN


func _holder() -> Node3D:
	return _forks if _forks != null else body


# --- forks -----------------------------------------------------------------------

func _forks_busy() -> bool:
	return _forks != null and absf(_forks.position.y - _fork_target) > 0.002


func _tick_forks(dt: float) -> void:
	if not _forks_busy() or speed > creep_speed + 0.01:
		return
	var y: float = _forks.position.y
	_forks.position.y = move_toward(y, _fork_target, LIFT_SPEED * dt)


## Sets the forks moving (they move while stopped or creeping).
func _set_forks(y: float) -> void:
	_fork_target = y


## Moves the forks and waits for them, standing still.
func _lift_to(y: float) -> void:
	_fork_target = y
	while _forks_busy():
		await _wait(0.05)


func forks_height() -> float:
	return _forks.position.y if _forks != null else FORKS_DOWN


func _forks_height() -> float:
	return forks_height()


# --- handling ----------------------------------------------------------------------

func _prepare_approach(slot: StorageSlot, loaded: bool) -> void:
	# loaded: hold the pallet just above its slot; empty: slide in under it
	var target: float = _forks_for(slot.position.y) + (BEAM_CLEARANCE if loaded else 0.0)
	await _lift_to(maxf(target, FORKS_DOWN))


func _pick(j: CarryJob) -> void:
	var node: Node3D = j.unit.node
	await _wait(handover_time)
	# the forks are in the pallet: lift it as it is
	node.reparent(_holder(), true)
	_load_depth = CarryAgent._depth_for(_held_yaw(node, _holder()))
	_taken(j)
	await _lift_to(forks_height() + CARRY_LIFT)


func _attach_now(j: CarryJob) -> void:
	var node: Node3D = j.unit.node
	var held: float = _held_yaw(node, _holder())
	_load_depth = CarryAgent._depth_for(held)
	node.reparent(_holder(), false)
	node.transform = hold_transform(held)
	_fork_target = FORKS_DOWN + CARRY_LIFT
	if _forks != null:
		_forks.position.y = _fork_target


## Where a carried pallet sits on the forks (holder space).
func hold_transform(held_yaw: float) -> Transform3D:
	var depth: float = CarryAgent._depth_for(held_yaw)
	var z: float = -(depth * 0.5 + 0.03)
	if _forks == null:
		z += _heel_z
	return Transform3D(Basis(Vector3.UP, held_yaw), Vector3(0.0, -FORKS_DOWN, z))


func _place(j: CarryJob) -> void:
	await _lift_to(maxf(_forks_for(j.to_slot.position.y), FORKS_DOWN))
	await _wait(handover_time)
	_set_down(j.unit.node, j.to_slot)
	_load_depth = 0.0
	_settled(j)
	await _lift_to(maxf(forks_height() - 0.04, FORKS_DOWN - 0.02))


func _after_back_out(_slot: StorageSlot) -> void:
	await _lift_to(FORKS_DOWN + (CARRY_LIFT if _loaded() else 0.0))


func _lane_climb(_loaded_now: bool) -> void:
	_set_forks(RAMP_FORKS)


func _lane_inside(slot: StorageSlot, loaded: bool) -> void:
	var target: float = slot.position.y - grid.ground_height(slot.position) + FORKS_DOWN
	_set_forks(target + (BEAM_CLEARANCE if loaded else 0.0))


func _lane_settle(slot: StorageSlot, loaded: bool) -> void:
	await _prepare_approach(slot, loaded)


func _before_lane_exit(_loaded_now: bool) -> void:
	pass


func _lane_leave(_loaded_now: bool) -> void:
	_set_forks(RAMP_FORKS)


func _lane_left(loaded: bool) -> void:
	_set_forks(FORKS_DOWN + (CARRY_LIFT if loaded else 0.0))


# --- wheels ----------------------------------------------------------------------

func _on_travel(ds: float) -> void:
	# forward travel (-Z) rolls the wheel tops forwards: negative turn about X
	var steer: float = atan(curvature * (axle_rear - axle_front))
	for w: Node3D in _front_wheels:
		_wheel_roll[w] = float(_wheel_roll[w]) - ds / FRONT_WHEEL_R
		w.basis = (_wheel_base[w] as Basis) * Basis(Vector3.RIGHT, _wheel_roll[w])
	for w: Node3D in _rear_wheels:
		_wheel_roll[w] = float(_wheel_roll[w]) - ds / REAR_WHEEL_R
		# rear-wheel steering turns the wheels against the curve
		w.basis = Basis(Vector3.UP, -steer) * (_wheel_base[w] as Basis) * Basis(Vector3.RIGHT, _wheel_roll[w])
