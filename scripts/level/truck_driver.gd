class_name TruckDriver
extends Node3D
## Drives the 3D trucks for one Dock. On TerminalSim.request_truck for its dock
## it spawns a TruckRig at the yard entrance, drives it in, reverses it onto the
## dock, opens the trailer doors and calls Dock.truck_arrived(). On
## Dock.ready_to_depart it shuts the doors, pulls out forwards, calls
## Dock.truck_departed() once clear of the apron, and despawns the rig.
## Also drives the dock's door and status light from Dock.state_changed.
##
## Motion is a tractor-trailer kinematic model (TruckRig.drive):
## - forwards: pure pursuit of the tractor rear axle on a polyline;
## - reverse: the trailer axle tracks a planned path (curve onto a straight
##   final segment square to the dock). Pure pursuit behind the trailer gives
##   the trailer heading it needs, that gives a target articulation, and a
##   P-controller on the articulation sets the tractor steer.
## Paths are XZ polylines (Vector2(x, z)) in this node's space.
## Pass `--reference_state` after `--` to snap dock_id's truck into the parked,
## half-unloaded state used for the reference screenshot (clock frozen).
## CargoFlow books the reference contract onto the dock first when present.

signal truck_spawned(dock_id: int)
signal reverse_started(dock_id: int)
signal truck_parked(dock_id: int)
signal truck_cleared(dock_id: int)
signal truck_despawned(dock_id: int)

enum Phase { ENTRY, REVERSE, OPENING, PARKED, CLOSING, EXIT }

const REFERENCE_FLAG: String = "--reference_state"
## Longest controller step; bigger frame deltas (game speed) are split.
const MAX_STEP: float = 1.0 / 30.0

@export var dock_id: int = 1
@export var sim_path: NodePath
@export var dock_visual_path: NodePath
@export var cab_scene: PackedScene
@export var trailer_scene: PackedScene
@export var brake_lights: bool = true

@export_group("Route")
## Tractor path from the yard entrance (off-screen). Its last leg is the lane
## the truck drives along before reversing; the last point only sets direction.
@export var entry_points: PackedVector3Array = PackedVector3Array()
## Trailer-rear reference points for the reverse. First point = trailer rear
## when the reverse starts (on the lane), last point = parked trailer rear at
## the dock; the last leg gives the dock's square-on direction.
@export var reverse_points: PackedVector3Array = PackedVector3Array()
## Tractor path out of the yard, after pulling straight off the dock.
@export var exit_points: PackedVector3Array = PackedVector3Array()
@export var corner_radius: float = 5.0
## Corners of forward paths are never rounded tighter than this.
@export var min_turn_radius: float = 7.0

@export_group("Driving")
## Yard speed forwards, m/s.
@export var drive_speed: float = 3.0
## Speed on the access road, more than yard_radius from the dock.
@export var road_speed: float = 8.0
@export var yard_radius: float = 26.0
@export var reverse_speed: float = 1.0
@export var accel: float = 1.2
@export var brake: float = 0.9
## Gentler deceleration onto the dock bumpers.
@export var dock_brake: float = 0.35
@export var stop_pause: float = 0.6
## Metres the tractor drives out before the dock is told the truck left.
@export var clear_distance: float = 12.0
@export var lookahead_min: float = 4.0
@export var lookahead_per_speed: float = 0.8

@export_group("Reversing")
## Trailer axle goes this much further along the lane than reverse_points[0]
## implies before the reverse starts (more room to swing in).
@export var swing_extra: float = 3.0
## The truck drifts this far off the entry lane toward the docks before it
## stops, over lane_shift_run metres (room for the cab to swing out).
@export var lane_shift: float = 1.4
@export var lane_shift_run: float = 14.0
## Straight, square-on run of the trailer axle before it stops.
@export var final_straight: float = 3.5
## Cubic control arm as a share of the turn radius (0.55 = circle).
## Clothoid lengths into and out of the turn, as shares of its radius.
@export var spiral_in: float = 0.4
@export var spiral_out: float = 1.2
## Trailer heading correction per metre per radian of heading error.
@export var heading_gain: float = 0.5
## Lateral offset (m) -> heading correction (rad), Stanley style.
@export var lateral_gain: float = 0.3
## Path curvature is read this far ahead to cover the articulation lag.
@export var curvature_lead: float = 0.3
## Articulation error correction per metre driven.
@export var articulation_gain: float = 2.0
@export_range(10.0, 75.0) var max_control_articulation_deg: float = 55.0

@export_group("Dock dressing")
## Dock-local z of the bumper faces the trailer sill stops against.
@export var bumper_face_z: float = 0.31
## LevelerLip fold angle (about local X) when no truck is docked.
@export var lip_folded_deg: float = 90.0
@export var lip_time: float = 0.8
@export var light_idle: Color = Color(1.0, 0.69, 0.13)
@export var light_busy: Color = Color(0.24, 1.0, 0.35)
@export var door_time: float = 1.2

@export_group("Reference state")
@export var handles_reference_state: bool = false
@export var reference_company: String = "LogiTrans"
@export var reference_cargo: String = "General cargo"
@export var reference_pallets_done: int = 4
@export var reference_pallets_total: int = 8
## Clock shown in the reference image (Day 3, 09:40).
@export var reference_minutes: float = 580.0

var _dock: Dock
var _visual: Node3D
var _trips: Array[Trip] = []
var _door_tween: Tween
var _lip: Node3D
var _lip_base_x: float = 0.0
var _lip_tween: Tween
## Rig origin to RearEntry sill, metres (from the last spawned rig).
var _entry_offset: float = 0.115

## The trip currently manoeuvring in the yard (entry, reverse or exit), shared
## by all drivers so two trucks never drive the same lane at once. Others wait:
## off-screen at the entrance, or parked at their dock.
static var _yard_owner: Object = null


class Trip:
	var rig: TruckRig
	var phase: int = 0  ## TruckDriver.Phase
	var path: PackedVector2Array = PackedVector2Array()
	var cum: PackedFloat32Array = PackedFloat32Array()
	var s: float = 0.0  ## progress of the tracked axle along path
	var v: float = 0.0  ## speed magnitude, m/s
	var wait: float = 0.0
	var travelled: float = 0.0
	var cleared: bool = false
	var max_articulation: float = 0.0  ## largest |articulation| this reverse
	var kappa: PackedFloat32Array = PackedFloat32Array()  ## reverse path curvature per point


func _ready() -> void:
	_visual = get_node_or_null(dock_visual_path) as Node3D
	if _visual != null:
		_lip = _visual.find_child("LevelerLip", true, false) as Node3D
		if _lip != null:
			_lip_base_x = _lip.rotation.x
			_set_lip(false, true, Callable())
	_bind.call_deferred()


func _exit_tree() -> void:
	for trip: Trip in _trips:
		if _yard_owner == trip:
			_yard_owner = null


func _bind() -> void:
	var sim: TerminalSim = get_node_or_null(sim_path) as TerminalSim
	if sim == null:
		push_error("TruckDriver %d: sim_path does not point at a TerminalSim" % dock_id)
		return
	_dock = sim.get_dock(dock_id)
	if _dock == null:
		push_error("TruckDriver %d: TerminalSim has no dock %d" % [dock_id, dock_id])
		return
	sim.request_truck.connect(_on_request_truck)
	_dock.ready_to_depart.connect(_on_ready_to_depart)
	_dock.state_changed.connect(_on_dock_state_changed)
	_dock.progress_changed.connect(_on_progress_changed)
	_apply_dock_state(_dock.state, true)
	if handles_reference_state and REFERENCE_FLAG in OS.get_cmdline_user_args():
		_snap_reference_state()


func _process(delta: float) -> void:
	if _trips.is_empty() or GameState.paused:
		return
	var dt: float = delta * float(GameState.speed)
	var steps: int = maxi(1, ceili(dt / MAX_STEP))
	for trip: Trip in _trips.duplicate():
		trip.rig.door_speed_scale = float(GameState.speed)
		for i: int in steps:
			if not _trips.has(trip):
				break
			_step(trip, dt / steps)


## Rig of the truck at this dock (parked, or manoeuvring), else null.
func get_rig() -> TruckRig:
	for trip: Trip in _trips:
		if trip.phase != Phase.EXIT:
			return trip.rig
	return null


## Largest |articulation| (rad) of the current or last reverse of get_rig().
func last_reverse_max_articulation() -> float:
	for trip: Trip in _trips:
		if trip.phase != Phase.EXIT:
			return trip.max_articulation
	return 0.0


## Parked trailer rear (XZ, this node's space) and the dock's outward normal.
## The rig origin (rearmost point, door hinges) stops so the trailer's
## RearEntry sill lands on the dock's bumper face; without a dock visual, the last reverse point.
func dock_stop() -> Vector2:
	if _visual == null:
		return _p(reverse_points[reverse_points.size() - 1])
	return _p(_visual.global_transform * Vector3(0.0, 0.0, bumper_face_z)) - dock_normal() * _entry_offset


func dock_normal() -> Vector2:
	var n: int = reverse_points.size()
	return (_p(reverse_points[n - 2]) - _p(reverse_points[n - 1])).normalized()


func _on_request_truck(dock: Dock) -> void:
	if dock != _dock:
		return
	var trip: Trip = _spawn_trip()
	var start: Vector2 = _p(entry_points[0])
	var dir: Vector2 = (_p(entry_points[1]) - start).normalized()
	trip.rig.place_tractor(start, TruckRig.dir_yaw(dir))
	var pts: PackedVector2Array = PackedVector2Array([start])
	for i: int in range(1, entry_points.size() - 1):
		pts.append(_p(entry_points[i]))
	# drift lane_shift toward the docks, then run straight so the trailer
	# lines up before the stop: keeps the cab's swing-out off the verge
	var stop: Vector2 = _reverse_start_tractor(trip.rig)
	var n_last: int = entry_points.size()
	var lane: Vector2 = (_p(entry_points[n_last - 1]) - _p(entry_points[n_last - 2])).normalized()
	var straight: float = trip.rig.trailer_length + trip.rig.wheelbase + 3.0
	pts.append(stop + dock_normal() * lane_shift - lane * (straight + lane_shift_run))
	pts.append(stop - lane * straight)
	pts.append(stop)
	_set_path(trip, Phase.ENTRY, _rounded(pts, maxf(corner_radius, min_turn_radius)))
	trip.v = road_speed
	_log("spawned (%s, %s)" % [dock.truck_company, dock.cargo_type])
	truck_spawned.emit(dock_id)


func _on_ready_to_depart() -> void:
	for trip: Trip in _trips:
		if trip.phase == Phase.PARKED:
			_log("ready_to_depart")
			trip.phase = Phase.CLOSING
			trip.rig.doors_changed.connect(_on_doors_closed.bind(trip), CONNECT_ONE_SHOT)
			trip.rig.open_rear_doors(false)
			return


func _on_doors_opened(_open: bool, trip: Trip) -> void:
	if trip.phase != Phase.OPENING:
		return
	trip.phase = Phase.PARKED
	_log("arrived")
	_dock.truck_arrived()
	truck_parked.emit(dock_id)


func _on_doors_closed(_open: bool, trip: Trip) -> void:
	if trip.phase != Phase.CLOSING:
		return
	_set_lip(false, false, _pull_out.bind(trip))


func _pull_out(trip: Trip) -> void:
	if trip.phase != Phase.CLOSING:
		return
	trip.rig.set_parked(false)
	var axle: Vector2 = trip.rig.tractor_axle_2d()
	var pts: PackedVector2Array = PackedVector2Array([axle])
	for p: Vector3 in exit_points:
		pts.append(_p(p))
	_set_path(trip, Phase.EXIT, _rounded(pts, maxf(corner_radius, min_turn_radius)))
	trip.wait = stop_pause


func _on_dock_state_changed(state: Dock.State) -> void:
	_apply_dock_state(state, false)


func _on_progress_changed(done: int, total: int) -> void:
	if _dock.is_transferring() and done > 0:
		_log("%s %d/%d" % ["loading" if _dock.loading else "unloading", done, total])


func _apply_dock_state(state: Dock.State, instant: bool) -> void:
	if _visual == null:
		return
	var busy: bool = state == Dock.State.UNLOADING or state == Dock.State.LOADING
	_visual.set(&"light_color", light_busy if busy else light_idle)
	if busy:
		_set_door(1.0, instant)
	elif state == Dock.State.IDLE:
		_set_door(0.0, instant)


func _set_door(amount: float, instant: bool) -> void:
	if _door_tween != null:
		_door_tween.kill()
	if instant:
		_visual.set(&"open_amount", amount)
		return
	_door_tween = create_tween()
	_door_tween.tween_property(_visual, ^"open_amount", amount, door_time / maxf(float(GameState.speed), 1.0))


# --- trips -------------------------------------------------------------------

func _spawn_trip() -> Trip:
	var trip: Trip = Trip.new()
	var rig: TruckRig = TruckRig.new()
	rig.name = "Truck"
	rig.cab_scene = cab_scene
	rig.trailer_scene = trailer_scene
	rig.brake_lights = brake_lights
	add_child(rig, true)
	trip.rig = rig
	_entry_offset = rig.rear_entry_offset()
	_trips.append(trip)
	return trip


func _set_path(trip: Trip, phase: Phase, path: PackedVector2Array) -> void:
	trip.phase = phase
	trip.path = path
	trip.cum = _cumulative(path)
	trip.s = 0.0
	trip.v = 0.0
	trip.travelled = 0.0
	trip.wait = 0.0


func _step(trip: Trip, dt: float) -> void:
	if trip.phase == Phase.PARKED or trip.phase == Phase.OPENING or trip.phase == Phase.CLOSING:
		return
	if trip.wait > 0.0:
		trip.wait -= dt
		return
	if _yard_owner != trip:
		if _yard_owner != null:
			return
		_yard_owner = trip
	if trip.phase == Phase.REVERSE:
		_step_reverse(trip, dt)
	else:
		_step_forward(trip, dt)


## Pure pursuit of the tractor rear axle along trip.path.
func _step_forward(trip: Trip, dt: float) -> void:
	var rig: TruckRig = trip.rig
	var axle: Vector2 = rig.tractor_axle_2d()
	trip.s = _project(trip, axle)
	var total: float = trip.cum[trip.cum.size() - 1]
	var left: float = total - trip.s
	var target: float = road_speed if axle.distance_to(dock_stop()) > yard_radius else drive_speed
	if trip.phase == Phase.ENTRY:
		target = minf(target, sqrt(2.0 * brake * maxf(left, 0.0)))
	if trip.v > target:
		trip.v = move_toward(trip.v, target, brake * 2.0 * dt)
	else:
		trip.v = move_toward(trip.v, target, accel * dt)
	var v: float = maxf(trip.v, 0.25) if left > 0.02 else 0.0
	var ds: float = v * dt
	if trip.phase == Phase.ENTRY:
		ds = minf(ds, maxf(left, 0.0))
	var look: float = lookahead_min + trip.v * lookahead_per_speed
	var to_q: Vector2 = _sample(trip, trip.s + look) - axle
	var alpha: float = wrapf(TruckRig.dir_yaw(to_q) - rig.tractor_yaw(), -PI, PI)
	var steer: float = atan(2.0 * rig.wheelbase * sin(alpha) / maxf(to_q.length(), 0.5))
	rig.drive(ds, steer)
	trip.travelled += ds
	if trip.phase == Phase.EXIT:
		if not trip.cleared and trip.travelled >= clear_distance:
			trip.cleared = true
			_log("departed")
			_dock.truck_departed()
			truck_cleared.emit(dock_id)
		if left <= 0.05:
			_despawn(trip)
	elif left - ds <= 0.02:
		_start_reverse(trip)


func _start_reverse(trip: Trip) -> void:
	var rig: TruckRig = trip.rig
	rig.drive(0.0, 0.0)
	var a0: Vector2 = rig.trailer_axle_2d()
	var b0: Vector2 = -TruckRig.heading_dir(rig.trailer_yaw())
	var n: Vector2 = dock_normal()
	var a_end: Vector2 = dock_stop() + n * rig.rear_overhang
	var a_s: Vector2 = a_end + n * final_straight
	# lead-in along b0, a clothoid-arc-clothoid turn sized so it meets both
	# lines tangentially, then the straight square to the dock (-n). The
	# curvature ramps, so the articulation the turn needs can build up.
	var path: PackedVector2Array = PackedVector2Array([a0])
	var kappa: PackedFloat32Array = PackedFloat32Array([0.0])
	var turn: float = wrapf(TruckRig.dir_yaw(-n) - TruckRig.dir_yaw(b0), -PI, PI)
	var denom: float = b0.cross(n)
	if absf(turn) > 0.02 and absf(denom) > 0.05:
		var u: float = (a_s - a0).cross(n) / denom
		var corner: Vector2 = a0 + b0 * u
		var w: float = (corner - a_s).dot(n)
		var unit: Dictionary = _turn_curve(Vector2.ZERO, TruckRig.dir_yaw(b0), turn, 1.0)
		var r: float = maxf(minf(u / float(unit.t_in), w / float(unit.t_out)), 1.0)
		var lead: float = maxf(u - r * float(unit.t_in), 0.0)
		var curve: Dictionary = _turn_curve(a0 + b0 * lead, TruckRig.dir_yaw(b0), turn, r)
		_log("reverse plan: lead-in %.1f m, turn radius %.1f m, straight %.1f m" % [
			lead, r, w - r * float(unit.t_out) + final_straight])
		path.append_array(curve.points)
		kappa.append_array(curve.kappa)
	path.append(a_s)
	path.append(a_end)
	kappa.append_array(PackedFloat32Array([0.0, 0.0]))
	trip.kappa = kappa
	_set_path(trip, Phase.REVERSE, path)
	trip.max_articulation = 0.0
	trip.wait = stop_pause
	rig.set_reversing(true)
	_log("reversing")
	reverse_started.emit(dock_id)


## Trailer-axle path tracking in reverse (see class doc).
func _step_reverse(trip: Trip, dt: float) -> void:
	var rig: TruckRig = trip.rig
	var axle: Vector2 = rig.trailer_axle_2d()
	trip.s = _project(trip, axle)
	var n: Vector2 = dock_normal()
	var heading_t: Vector2 = TruckRig.heading_dir(rig.trailer_yaw())
	var gamma: float = rig.articulation()
	var left: float = (rig.trailer_rear_2d() - dock_stop()).dot(n)
	var target: float = minf(reverse_speed, sqrt(2.0 * dock_brake * maxf(left, 0.0)) + 0.04)
	trip.v = move_toward(trip.v, target, (accel if trip.v < target else brake) * dt)
	var ds: float = trip.v * dt
	var closing: float = cos(gamma) * heading_t.dot(n)
	ds = minf(ds, maxf(left, 0.0) / maxf(closing, 0.2))
	# feedforward: the articulation the path curvature needs (dθt/ds_axle =
	# -tanγ / L_t when reversing), read a little ahead to cover the lag,
	# plus feedback turning the trailer toward the path tangent and onto it
	var lt: float = rig.trailer_length
	var limit: float = deg_to_rad(max_control_articulation_deg)
	var p_here: Vector2 = _sample(trip, trip.s)
	var tangent: float = _tangent_yaw(trip, trip.s)
	var lateral: float = (axle - p_here).dot(TruckRig.heading_dir(tangent + PI * 0.5))
	var travel: float = rig.trailer_yaw() + PI
	var herr: float = wrapf(travel - (tangent - atan(lateral_gain * lateral)), -PI, PI)
	var ahead: float = trip.s + curvature_lead
	var rate: float = _kappa_at(trip, ahead) - heading_gain * herr
	var gamma_ref: float = clampf(-atan(lt * rate), -limit, limit)
	var rate_next: float = _kappa_at(trip, ahead + 0.25) - heading_gain * herr
	var dref: float = (clampf(-atan(lt * rate_next), -limit, limit) - gamma_ref) / 0.25 * cos(gamma)
	# reversing: dγ/ds = sinγ/L_t - tanδ/L_c ; ask for dγ/ds = dγref/ds + k (γref - γ)
	var tan_d: float = rig.wheelbase * (sin(gamma) / lt - dref - articulation_gain * (gamma_ref - gamma))
	rig.drive(-ds, atan(tan_d))
	trip.max_articulation = maxf(trip.max_articulation, absf(rig.articulation()))
	if left - ds * closing > 0.003:
		return
	rig.drive(0.0, 0.0)
	rig.set_reversing(false)
	rig.set_parked(true)
	_yard_owner = null
	trip.phase = Phase.OPENING
	var rear: Vector2 = rig.trailer_rear_2d()
	_log("parked: rear %.3f m off stop line, %.3f m off centre, trailer %.2f deg, articulation %.2f deg" % [
		(rear - dock_stop()).dot(n), (rear - dock_stop()).cross(n),
		rad_to_deg(wrapf(rig.trailer_yaw() - TruckRig.dir_yaw(n), -PI, PI)), rad_to_deg(rig.articulation())])
	_set_lip(true, false, _open_doors.bind(trip))


func _open_doors(trip: Trip) -> void:
	if trip.phase != Phase.OPENING:
		return
	trip.rig.doors_changed.connect(_on_doors_opened.bind(trip), CONNECT_ONE_SHOT)
	trip.rig.open_rear_doors(true)


## Unfolds the dock leveler lip onto the trailer bed (out) or folds it down
## clear of the roller door, then calls `done` (at once if there is no lip).
func _set_lip(out: bool, instant: bool, done: Callable) -> void:
	if _lip_tween != null:
		_lip_tween.kill()
		_lip_tween = null
	var target: float = _lip_base_x + (0.0 if out else deg_to_rad(lip_folded_deg))
	if _lip == null or instant:
		if _lip != null:
			_lip.rotation.x = target
		if done.is_valid():
			done.call()
		return
	_lip_tween = create_tween()
	_lip_tween.tween_property(_lip, ^"rotation:x", target, lip_time / maxf(float(GameState.speed), 1.0)) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if done.is_valid():
		_lip_tween.finished.connect(done)


func _despawn(trip: Trip) -> void:
	_trips.erase(trip)
	if _yard_owner == trip:
		_yard_owner = null
	trip.rig.queue_free()
	_log("despawned")
	truck_despawned.emit(dock_id)


func _snap_reference_state() -> void:
	GameState.minutes_per_second = 0.0
	GameState.minutes = reference_minutes
	GameState.time_changed.emit(GameState.day, GameState.minutes)
	# CargoFlow may already have booked the reference contract onto this dock
	if _dock.state == Dock.State.IDLE:
		_dock.assign_truck(reference_company, reference_cargo, reference_pallets_total)
	elif _dock.state != Dock.State.ARRIVING:
		push_warning("TruckDriver %d: dock busy, cannot snap reference state" % dock_id)
		return
	var trip: Trip = _spawn_trip()
	trip.rig.place(dock_stop(), TruckRig.dir_yaw(dock_normal()))
	trip.phase = Phase.PARKED
	trip.rig.set_parked(true)
	trip.rig.open_rear_doors(true, true)
	_set_lip(true, true, Callable())
	_dock.truck_arrived()
	_dock.pallets_done = reference_pallets_done
	_dock.progress_changed.emit(_dock.pallets_done, _dock.pallets_total)
	_set_door(1.0, true)
	_log("reference state: unloading %d/%d" % [_dock.pallets_done, _dock.pallets_total])


# --- path helpers ------------------------------------------------------------

## Tractor rear axle where the entry stops: the trailer straight, lane_shift
## off the lane, its axle swing_extra past where reverse_points[0] puts it.
func _reverse_start_tractor(rig: TruckRig) -> Vector2:
	var n: int = entry_points.size()
	var lane: Vector2 = (_p(entry_points[n - 1]) - _p(entry_points[n - 2])).normalized()
	var axle: Vector2 = _p(reverse_points[0]) + lane * (rig.rear_overhang + swing_extra) - dock_normal() * lane_shift
	return axle + lane * (rig.trailer_length + rig.hitch_offset)


## Point in this node's XZ plane.
func _p(world: Vector3) -> Vector2:
	var local: Vector3 = to_local(world) if is_inside_tree() else world
	return Vector2(local.x, local.z)


## Distance along the path of the closest point to `pos`, searched a little
## around the last progress so loops cannot make it jump.
func _project(trip: Trip, pos: Vector2) -> float:
	var best: float = trip.s
	var best_d: float = INF
	for i: int in range(1, trip.path.size()):
		var a: float = trip.cum[i - 1]
		if trip.cum[i] < trip.s - 2.0 or a > trip.s + 8.0:
			continue
		var p0: Vector2 = trip.path[i - 1]
		var seg: Vector2 = trip.path[i] - p0
		var len2: float = seg.length_squared()
		var t: float = 0.0 if len2 < 0.000001 else clampf((pos - p0).dot(seg) / len2, 0.0, 1.0)
		var d: float = pos.distance_squared_to(p0 + seg * t)
		if d < best_d:
			best_d = d
			best = a + t * sqrt(len2)
	return maxf(best, trip.s)


## Points (excluding the start) and signed curvature of a turn by `turn` rad
## starting at `start` heading `yaw0`: clothoid in, arc of radius r, clothoid
## out (longer: unbending in reverse is slow). "t_in"/"t_out" = distance from
## the start/end to where the end tangents meet.
func _turn_curve(start: Vector2, yaw0: float, turn: float, r: float) -> Dictionary:
	var sign_k: float = signf(turn)
	var s_in: float = spiral_in * r
	var s_out: float = spiral_out * r
	var fit: float = minf(1.0, 2.0 * r * absf(turn) / (s_in + s_out))
	s_in *= fit
	s_out *= fit
	var arc: float = r * absf(turn) - (s_in + s_out) * 0.5
	var total: float = s_in + arc + s_out
	var steps: int = maxi(ceili(total / (0.02 * r)), 8)
	var ds: float = total / steps
	var pos: Vector2 = start
	var yaw: float = yaw0
	var points: PackedVector2Array = PackedVector2Array()
	var kappa: PackedFloat32Array = PackedFloat32Array()
	for i: int in steps:
		var k: float = _spiral_k((i + 0.5) * ds, s_in, arc, s_out, r) * sign_k
		yaw += k * ds * 0.5
		pos += TruckRig.heading_dir(yaw) * ds
		yaw += k * ds * 0.5
		if i % 4 == 3 or i == steps - 1:
			points.append(pos)
			kappa.append(_spiral_k((i + 1) * ds, s_in, arc, s_out, r) * sign_k)
	var b: Vector2 = TruckRig.heading_dir(yaw0)
	var e: Vector2 = TruckRig.heading_dir(yaw)
	var cr: float = b.cross(e)
	if absf(cr) < 0.0001:
		return {"points": points, "kappa": kappa, "t_in": total * 0.5, "t_out": total * 0.5}
	return {"points": points, "kappa": kappa,
			"t_in": (pos - start).cross(e) / cr, "t_out": (start - pos).cross(b) / cr}


static func _spiral_k(sm: float, s_in: float, arc: float, s_out: float, r: float) -> float:
	if sm < s_in:
		return sm / s_in / r
	if sm < s_in + arc:
		return 1.0 / r
	return maxf(s_in + arc + s_out - sm, 0.0) / maxf(s_out, 0.0001) / r


## Curvature of the reverse path at distance d (0 past the ends).
func _kappa_at(trip: Trip, d: float) -> float:
	var cum: PackedFloat32Array = trip.cum
	if trip.kappa.size() != cum.size() or d <= 0.0 or d >= cum[cum.size() - 1]:
		return 0.0
	var i: int = maxi(cum.bsearch(d), 1)
	var seg: float = cum[i] - cum[i - 1]
	var t: float = 0.0 if seg <= 0.0 else (d - cum[i - 1]) / seg
	return lerpf(trip.kappa[i - 1], trip.kappa[i], t)


## Yaw of the path direction around distance d.
func _tangent_yaw(trip: Trip, d: float) -> float:
	return TruckRig.dir_yaw(_sample(trip, d + 0.3) - _sample(trip, d - 0.3))


## Point at distance d along the path; past the end it carries on straight.
func _sample(trip: Trip, d: float) -> Vector2:
	var cum: PackedFloat32Array = trip.cum
	var last: int = cum.size() - 1
	if d >= cum[last]:
		var dir: Vector2 = (trip.path[last] - trip.path[last - 1]).normalized()
		return trip.path[last] + dir * (d - cum[last])
	d = maxf(d, 0.0)
	var i: int = maxi(cum.bsearch(d), 1)
	var seg: float = cum[i] - cum[i - 1]
	var t: float = 0.0 if seg <= 0.0 else (d - cum[i - 1]) / seg
	return trip.path[i - 1].lerp(trip.path[i], t)


static func _cumulative(path: PackedVector2Array) -> PackedFloat32Array:
	var cum: PackedFloat32Array = PackedFloat32Array([0.0])
	for i: int in range(1, path.size()):
		cum.append(cum[i - 1] + path[i - 1].distance_to(path[i]))
	return cum


## Rounds every inner corner with a quadratic curve that starts and ends
## radius metres from a right-angle corner (clamped to the legs).
static func _rounded(points: PackedVector2Array, radius: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array([points[0]])
	for i: int in range(1, points.size() - 1):
		var p0: Vector2 = points[i - 1]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var d1: Vector2 = (p0 - p1).normalized()
		var d2: Vector2 = (p2 - p1).normalized()
		var half: float = acos(clampf(d1.dot(d2), -1.0, 1.0)) * 0.5
		var t: float = radius / maxf(tan(half), 0.001)
		# legs shared with another corner can only give half their length
		var lim1: float = p0.distance_to(p1) * (1.0 if i == 1 else 0.5)
		var lim2: float = p1.distance_to(p2) * (1.0 if i == points.size() - 2 else 0.5)
		t = minf(t, minf(lim1, lim2))
		var a: Vector2 = p1 + d1 * t
		var b: Vector2 = p1 + d2 * t
		var steps: int = 14
		for k: int in steps + 1:
			var u: float = float(k) / steps
			out.append(a.lerp(p1, u).lerp(p1.lerp(b, u), u))
	out.append(points[points.size() - 1])
	return out


func _log(msg: String) -> void:
	print("TruckDriver[dock %d]: %s" % [dock_id, msg])
