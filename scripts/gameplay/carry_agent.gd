class_name CarryAgent
extends Node
## Something that carries pallets for the JobBoard: moves a 3D `body` and runs
## one CarryJob at a time: go to the source slot, pick up, back out, go to the
## target slot, put down, back out. Subclasses add the vehicle: how the
## pallet is held and how it turns (ForkliftCarrier, WorkerCarrier).
##
## Motion is continuous. Every move is a MotionPath leg (straights and arcs no
## tighter than min_turn_radius, driven forward or in reverse) followed with
## limited acceleration and braking, slower on arcs, on the ramp and in the
## trailer. Vehicles never rotate in place (min_turn_radius > 0); people may
## pivot at pivot_rate. Grid slots are approached square-on along a straight
## of at least 2 m and left by reversing along it. Trailer slots go through
## the dock's TrailerBay: one agent in the lane at a time, up the ramp and in
## load first, and all the way back out in reverse. The body follows the
## floor height of ramp and trailer and pitches with it.
## Traffic: the agent yields when its path ahead comes within the safety
## distance of another mover; on a deadlock (Traffic decides) the loser backs
## off and re-plans. Moves on real time scaled by GameState.speed.

signal job_done(agent: CarryAgent, job: CarryJob)
## A unit was picked up from its slot / put down in its target slot.
signal unit_picked(agent: CarryAgent, job: CarryJob)
signal unit_placed(agent: CarryAgent, job: CarryJob)
## A pallet that stood in this agent's way was moved to another slot
## (job.kind == RELOCATE; its lifecycle state is unchanged).
signal unit_relocated(agent: CarryAgent, job: CarryJob)
## Done with its work and standing at its rest spot.
signal became_idle(agent: CarryAgent)
signal _leg_finished(aborted: bool)
signal _action_done
signal _became_still

## Longest simulation step; bigger frames are split so fast-forward stays exact.
const MAX_STEP: float = 1.0 / 60.0
## Sub-steps between traffic checks.
const CONFLICT_EVERY: int = 4
## Planned braking (leg ends, stopping for others) uses this share of
## accel, so the last-millimetre stop on the mark stays within accel.
const PLAN_DECEL: float = 0.9
## Making way: how far it retreats towards its parking spot at most.
const BACK_OFF_DISTANCE: float = 4.0
## Travelled distance after leaving a lane before the lane is freed.
const LANE_RELEASE_DISTANCE: float = 2.5
## Distance driven after backing out of a zone or rack before its lock is freed.
const LOCK_RELEASE_DISTANCE: float = 9.0
## A fixed manoeuvre into or out of a slot that has waited this long on a
## person is given up: the agent stops, backs out along it and tries again
## (the person has been asked to clear the way).
const PERSON_ABORT_TIME: float = 4.0

@export var move_speed: float = 1.3
## Speed on the ramp, inside trailers and on the final approach to a slot.
@export var lane_speed: float = 1.0
## Speed on arcs.
@export var turn_speed: float = 1.0
@export var reverse_speed: float = 0.9
@export var accel: float = 1.0
## Speed while the forks move.
@export var creep_speed: float = 0.35
## 0 = pivots (a person). > 0 = steers along arcs this tight, never in place.
@export var min_turn_radius: float = 0.0
## People: pivot rate in rad/s.
@export var pivot_rate: float = 2.0
## Distance from the body origin to the heel of the load (forks or jack).
@export var load_heel: float = 0.44
## Seconds (at 1x) the driver takes between steps (pick up, set down).
@export var handover_time: float = 0.35
## Local Z of the front and rear axles, for pitching on ramps (0, 0 = no pitch).
@export var axle_front: float = 0.0
@export var axle_rear: float = 0.0

static var _next_uid: int = 1

var body: Node3D = null
var grid: StorageGrid = null
var traffic: Traffic = null
var job: CarryJob = null
var label: String = "Agent"
var uid: int = 0
## False keeps the JobBoard from giving it jobs (for other duties later).
var available: bool = true
## TrailerBay this agent holds the lane of, or null.
var bay: TrailerBay = null
## Traffic bookkeeping: who we are waiting on and for how long (game s).
var blocked_by: Node = null
var blocked_time: float = 0.0
## Current speed along the leg (m/s, >= 0) and signed curvature.
var speed: float = 0.0
var curvature: float = 0.0
## Total distance driven (for tests: wheel odometry).
var odometer: float = 0.0

var _pos: Vector2 = Vector2.ZERO
var _yaw: float = 0.0
var _pitch: float = 0.0
var _leg: MotionPath = null
var _s: float = 0.0
var _leg_abortable: bool = false
var _abort: bool = false
var _give_way_from: Node = null
var _event_index: int = 0
var _conflict: float = INF
var _conflict_by: Node = null
var _pivot_to: float = NAN
var _pivot_center: Vector2 = Vector2.ZERO
var _action: Callable = Callable()
var _action_time: float = 0.0
var _action_length: float = 0.0
var _home_pos: Vector2 = Vector2.ZERO
var _home_yaw: float = 0.0
var _homing: bool = false
var _waiting_lock: bool = false
var _in_lane: bool = false
var _since_lane: float = 0.0
## Out of the trailer again; the lane is freed after LANE_RELEASE_DISTANCE.
var _lane_done: bool = false
var _held_lock: Traffic.ZoneLock = null
var _lock_release_in: float = -1.0
var _abort_home: bool = false
var _reroute: bool = false
var _pending_give_way: Node = null
## Zone lock or dock lane this agent is queuing for (null when none).
var _wait_lock: Traffic.ZoneLock = null
var _wait_bay: TrailerBay = null
## Game seconds spent queuing for the current lock (Traffic counts it).
var lock_wait_time: float = 0.0
## Pallet on the carrier right now (between pick-up and set-down), or null.
var _load_unit: CargoUnit = null
var _fp_cache: Array = []
var _fp_key: Vector4 = Vector4(INF, INF, INF, INF)
var _future_cache: Array = []
var _future_key: Vector3i = Vector3i(-1, -1, -1)
var _future_leg: MotionPath = null


func _init() -> void:
	uid = _next_uid
	_next_uid += 1


func is_idle() -> bool:
	return job == null


## Is this the kind of agent the job is meant for (forklift or worker)?
func suits(_job: CarryJob) -> bool:
	return true


func start(p_job: CarryJob) -> void:
	job = p_job
	p_job.agent = self
	if _homing:
		_abort = true
		_abort_home = true
	_run(p_job)


## Reference screenshot: start a job with the pallet already on board, the
## body at `at` facing `yaw`, heading for the target slot.
func start_carrying(p_job: CarryJob, at: Vector3, yaw: float) -> void:
	job = p_job
	p_job.agent = self
	_pos = Vector2(at.x, at.z)
	_yaw = yaw
	_apply_pose()
	_begin()
	_attach_now(p_job)
	_taken(p_job)
	_deliver(p_job)


func _run(j: CarryJob) -> void:
	while _homing:
		await _became_still
	_abort = false
	_begin()
	await _clear_access(j.from_slot, j)
	await _go_to_slot(j.from_slot)
	await _pick(j)
	_taken(j)
	await _back_out(j.from_slot)
	await _deliver(j)


func _deliver(j: CarryJob) -> void:
	_check_target(j)
	await _go_to_slot(j.to_slot)
	await _place(j)
	_settled(j)
	await _back_out(j.to_slot)
	_finish()
	job = null
	if _held_lock != null and not _in_lock_area(_held_lock):
		_release_lock()
	job_done.emit(self, j)
	if job == null:
		_go_home()


# --- obstructions ------------------------------------------------------------------

## Before driving in for a pick-up: pallets standing in the slot's approach
## (someone set one down where it blocks the way) are moved out of the way
## first, each to a slot where it blocks nobody, then the job goes on.
func _clear_access(slot: StorageSlot, j: CarryJob) -> void:
	if slot.is_trailer() or traffic == null:
		return
	var tries: int = 0
	while tries < 12:
		var in_way: Array[StorageSlot] = grid.obstructions(slot, j.unit)
		if in_way.is_empty():
			return
		tries += 1
		# the nearest one first (the front of the approach)
		in_way.sort_custom(func(a: StorageSlot, b: StorageSlot) -> bool:
			return a.position.dot(slot.out_dir) > b.position.dot(slot.out_dir))
		var o: StorageSlot = in_way[0]
		var u: CargoUnit = o.unit
		var busy: CarryJob = u.job as CarryJob
		if busy != null and busy.agent != null:
			await _wait(1.0)  # someone is already moving it
			continue
		var target: StorageSlot = grid.relocation_target(u, slot)
		if target == null:
			push_warning("%s: %s blocks the way to %s and has nowhere to go" % [label, u.code, slot.label])
			await _wait(3.0)
			continue
		await _relocate(u, target)


## Picks `u` up and sets it down in `target` (same lifecycle state), logged
## in the pallet's history as moved to clear the path.
func _relocate(u: CargoUnit, target: StorageSlot) -> void:
	var r: CarryJob = CarryJob.new(CarryJob.Kind.RELOCATE, u, target)
	r.agent = self
	r.set_meta(&"queued", u.job)
	u.job = r
	grid.reserve(target, u)
	print("%s: %s stands in the way, moving it %s -> %s" % [label, u.code, r.from_slot.label, target.label])
	await _go_to_slot(r.from_slot)
	await _pick(r)
	_taken(r)
	await _back_out(r.from_slot)
	await _go_to_slot(target)
	await _place(r)
	_settled(r)
	await _back_out(target)


## The pallet has just left its slot onto the carrier (subclasses call this
## the moment they take it; called again after _pick, it does nothing).
## Its state, slot and location follow at once.
func _taken(j: CarryJob) -> void:
	if j.has_meta(&"taken"):
		return
	j.set_meta(&"taken", true)
	_load_unit = j.unit
	grid.release(j.from_slot)
	if j.kind == CarryJob.Kind.RELOCATE:
		j.unit.relocate(label)  # same lifecycle state, on the forks
		unit_relocated.emit(self, j)
	else:
		PalletLog.stamp(j.unit, j.carried_state(), label, label)
		unit_picked.emit(self, j)


## The pallet has just been set down in its target slot (off the carrier).
func _settled(j: CarryJob) -> void:
	if j.has_meta(&"settled"):
		return
	j.set_meta(&"settled", true)
	_load_unit = null
	grid.occupy(j.to_slot, j.unit)
	if j.kind == CarryJob.Kind.RELOCATE:
		var queued: CarryJob = j.get_meta(&"queued") as CarryJob if j.has_meta(&"queued") else null
		j.unit.job = queued
		if queued != null:
			queued.from_slot = j.to_slot
		PalletLog.stamp(j.unit, j.unit.state, j.to_slot.label, "Moved to clear path by %s" % label)
		unit_relocated.emit(self, j)
	else:
		j.unit.job = null
		PalletLog.stamp(j.unit, j.placed_state(), j.to_slot.label, label)
		unit_placed.emit(self, j)


## Before setting a pallet down: the target must still be a spot where it
## blocks nobody (and has a clear way in); otherwise take another one.
func _check_target(j: CarryJob) -> void:
	var t: StorageSlot = j.to_slot
	if t == null or t.is_trailer():
		return
	if grid.placement_ok(t, j.unit) and grid.obstructions(t, j.unit).is_empty() and grid.column_clear(t):
		return
	var other: StorageSlot = null
	if t.zone == StorageSlot.Zone.INBOUND or t.zone == StorageSlot.Zone.OUTBOUND:
		other = grid.drop_slot(t.zone, j.unit)
	else:
		var best: float = INF
		for s: StorageSlot in grid.store_targets():
			if s.needs_lift() and not (self is ForkliftCarrier):
				continue
			var d: float = s.position.distance_to(t.position)
			if d < best:
				best = d
				other = s
	if other == null:
		push_warning("%s: %s would block the way at %s, but no other slot is free" % [label, j.unit.code, t.label])
		return
	print("%s: %s would block the way at %s, taking %s instead" % [label, j.unit.code, t.label, other.label])
	if t.reserved_by == j.unit:
		t.reserved_by = null
	j.to_slot = other
	grid.reserve(other, j.unit)


# --- hooks ---------------------------------------------------------------------

func _begin() -> void:
	pass


## At the approach point, the load under the pallet. Must attach j.unit.node.
func _pick(_j: CarryJob) -> void:
	await _wait(handover_time)


## At the approach point, the pallet over its slot. Must hand j.unit.node over.
func _place(_j: CarryJob) -> void:
	await _wait(handover_time)


## Puts the pallet on the carrier at once (start_carrying).
func _attach_now(_j: CarryJob) -> void:
	pass


func _finish() -> void:
	pass


## At the staging pose of a grid slot, before driving in.
func _prepare_approach(_slot: StorageSlot, _loaded: bool) -> void:
	pass


## After backing out of a grid slot.
func _after_back_out(_slot: StorageSlot) -> void:
	pass


## Lane leg events (fired while moving, so they may only set targets).
func _lane_climb(_loaded: bool) -> void:
	pass


func _lane_inside(_slot: StorageSlot, _loaded: bool) -> void:
	pass


func _lane_leave(_loaded: bool) -> void:
	pass


func _lane_left(_loaded: bool) -> void:
	pass


## Inside the trailer, stopped at the slot: finish fork moves before handling.
func _lane_settle(_slot: StorageSlot, _loaded_now: bool) -> void:
	pass


## Inside the trailer, before reversing out (forks to a safe height).
func _before_lane_exit(_loaded_now: bool) -> void:
	pass


## True while the forks (or anything that limits speed to a creep) move.
func _forks_busy() -> bool:
	return false


func _tick_forks(_dt: float) -> void:
	pass


## Called with the distance travelled (signed: < 0 reversing) each step.
func _on_travel(_ds: float) -> void:
	pass


func _on_move(_moving: bool) -> void:
	pass


## Called after every pose update (e.g. to tilt a pallet jack on the ramp).
func _after_pose() -> void:
	pass


func _loaded() -> bool:
	return _load_unit != null


## Footprints for traffic: boxes at a hypothetical pose. `bare` = body only.
func footprints_at(_p: Vector2, _yaw_at: float, _bare: bool = false) -> Array:
	return []


## Body without forks / jack, for rack reachability.
func body_boxes_at(p: Vector2, yaw_at: float) -> Array:
	return footprints_at(p, yaw_at, true)


func traffic_kind() -> int:
	return Traffic.Kind.VEHICLE


## Current footprints, rebuilt only when the pose or the load changes.
func traffic_footprints() -> Array:
	var key: Vector4 = Vector4(_pos.x, _pos.y, _yaw, footprint_variant())
	if key != _fp_key:
		_fp_key = key
		_fp_cache = footprints_at(_pos, _yaw)
	return _fp_cache


## Changes when the footprint shape changes (a load on the forks).
func footprint_variant() -> float:
	return 0.0


func traffic_footprints_at(p: Vector2, yaw_at: float) -> Array:
	return footprints_at(p, yaw_at)


func traffic_active() -> bool:
	return body != null and body.is_visible_in_tree()


func traffic_moving() -> bool:
	return speed > 0.02 or not is_nan(_pivot_to)


## Doing work that others should wait for (not idle, not just queuing).
func traffic_working() -> bool:
	return job != null and not _waiting_lock


func traffic_priority() -> int:
	var p: int = 0
	if traffic != null and traffic.token_holder == self:
		p += 100000
	if bay != null or _held_lock != null:
		p += 4000
	if _loaded():
		p += 2000
	if job == null:
		p -= 50000  # idle always yields to one with work
	return p - uid


## Asked to plan again around whatever blocks it (it stops, then re-plans;
## stopped movers count as obstacles). False when its leg cannot change.
func traffic_reroute() -> bool:
	if _leg == null or not _leg_abortable:
		return false
	_reroute = true
	_abort = true
	return true


## Asked to make way for `winner`. Returns false when it cannot (in a lane
## leg or on a final approach).
func traffic_give_way(winner: Node) -> bool:
	if _leg != null and not _leg_abortable:
		return false
	if traffic != null and traffic.token_holder == self:
		return false
	if job == null and traffic != null and traffic.board != null and traffic.board.holds.has(self):
		return false  # a worker is servicing it: it does not move
	_give_way_from = winner
	if _leg != null:
		_abort = true
	elif job == null and not _homing:
		# idle: go to the parking spot, unless that is in the other's way too;
		# then (or when already there) wait somewhere clear of its way
		if _pos.distance_to(_home_pos) > 0.5 and not _in_way_of(winner, _home_pos, _home_yaw):
			_go_home()
		else:
			_idle_back_off(winner)
	elif _waiting_lock and not _homing:
		# queuing for a lock: wait at the parking spot instead
		if _pos.distance_to(_home_pos) > 0.5:
			_go_home()
		else:
			_idle_back_off(winner)
	else:
		# between two moves (a job, or the trip home, waiting to plan
		# again): move off before the next try
		_pending_give_way = winner
	return true


## The agent holding the lock or dock lane this one queues for, or null.
func lock_holder_waited_for() -> Node:
	if _wait_lock != null:
		return _wait_lock.holder as Node
	if _wait_bay != null:
		return _wait_bay.occupant as Node
	return null


## Asked by Traffic to leave a work area it idles in (someone waits for the
## area's lock): drive to the parking spot, or free the lock once there.
func traffic_leave() -> void:
	if job != null or _homing or _leg != null or _action.is_valid():
		return
	if traffic != null and traffic.board != null and traffic.board.holds.has(self):
		return
	if _pos.distance_to(_home_pos) > 0.5:
		_go_home()
	else:
		_release_lock()


## Standing in a zone front, a dock lane, a rack aisle or a slot approach.
func in_keep_clear() -> bool:
	return traffic != null and traffic.in_keep_clear(traffic_footprints())


## New parking spot (Traffic moves it off the work areas at startup).
func move_home(p: Vector2, yaw_at: float) -> void:
	_home_pos = p
	_home_yaw = yaw_at
	_pos = p
	_yaw = yaw_at
	_apply_pose()


# --- routes ----------------------------------------------------------------------

## Body origin to load centre for this slot: heel plus half the pallet's
## depth along the approach direction.
func reach_for(slot: StorageSlot) -> float:
	var x: Vector3 = slot.pallet_transform().basis.x
	x.y = 0.0
	var along: float = absf(x.normalized().dot(slot.out_dir.normalized())) if x.length() > 0.01 else 1.0
	return load_heel + lerpf(0.8, 1.2, along) * 0.5 + 0.03


func _go_to_slot(slot: StorageSlot) -> void:
	if slot.is_trailer():
		await _enter_trailer(slot)
		return
	var lock: Traffic.ZoneLock = traffic.lock_for(slot)
	if lock != null:
		await _acquire(lock)
	var reach: float = reach_for(slot)
	var pose: Array = traffic.staging_pose(slot, reach)
	await _travel_to(pose[0], pose[1], [slot])
	await _prepare_approach(slot, _loaded())
	var approach: Vector3 = grid.approach_point(slot, reach)
	var a2: Vector2 = Vector2(approach.x, approach.z)
	if absf(angle_difference(_yaw, atan2(-(a2 - _pos).x, -(a2 - _pos).y))) > 0.02:
		push_warning("%s: not square to %s at the staging pose" % [label, slot.label])
	var start: Vector2 = _pos
	while _pos.distance_to(a2) > 0.002:
		var leg: MotionPath = MotionPath.from_pose(_pos, _yaw, false, &"approach")
		leg.straight(_pos.distance_to(a2))
		leg.profile(lane_speed, turn_speed, accel * PLAN_DECEL)
		if await _run_leg(leg, false):
			break
		# someone stood in the way of the drive in: back out along it to the
		# staging pose, give them time to clear, then drive in again
		if _pos.distance_to(start) > 0.02:
			var back: MotionPath = MotionPath.from_pose(_pos, _yaw, true, &"back_out")
			back.straight(_pos.distance_to(start))
			back.profile(reverse_speed, turn_speed, accel * PLAN_DECEL)
			await _run_leg(back, false)
		await _wait(2.0)


func _back_out(slot: StorageSlot) -> void:
	if slot.is_trailer():
		await _exit_trailer(slot)
		return
	var reach: float = reach_for(slot)
	var pose: Array = traffic.staging_pose(slot, reach)
	var to: Vector2 = pose[0]
	while _pos.distance_to(to) > 0.002:
		var leg: MotionPath = MotionPath.from_pose(_pos, _yaw, true, &"back_out")
		leg.straight(_pos.distance_to(to))
		leg.profile(reverse_speed, turn_speed, accel * PLAN_DECEL)
		if await _run_leg(leg, false):
			break
		await _wait(2.0)  # a person behind: they are clearing the way
	await _after_back_out(slot)
	_lock_release_in = LOCK_RELEASE_DISTANCE


func _acquire(lock: Traffic.ZoneLock) -> void:
	if _held_lock == lock:
		_lock_release_in = -1.0  # straight on to another slot of the same area
		return
	_release_lock()
	if not lock.try_acquire(self):
		_waiting_lock = true
		_wait_lock = lock
		lock_wait_time = 0.0
		# never queue inside a work area: wait at the parking spot instead
		if in_keep_clear() and not _homing:
			_go_home()
		while not lock.try_acquire(self):
			await lock.freed
		_waiting_lock = false
		_wait_lock = null
	_held_lock = lock
	await _stop_homing()


## Ends a trip to the parking spot made while queuing.
func _stop_homing() -> void:
	if _homing:
		_abort = true
		_abort_home = true
		while _homing:
			await _became_still


## True while the footprints still touch the lock's area.
func _in_lock_area(lock: Traffic.ZoneLock) -> bool:
	return lock.box != null and FootprintBox.set_overlaps(traffic_footprints(), [lock.box], 0.0)


func _release_lock() -> void:
	_lock_release_in = -1.0
	if _held_lock != null:
		var l: Traffic.ZoneLock = _held_lock
		_held_lock = null
		l.release(self)


func _enter_trailer(slot: StorageSlot) -> void:
	var b: TrailerBay = slot.bay as TrailerBay
	var stage: Vector3 = b.stage_point(slot)
	var stage_yaw: float = atan2(-b.axis.x, -b.axis.z)
	if not b.try_reserve(self):
		var wait: Array = b.wait_pose(slot)
		_waiting_lock = true
		_wait_bay = b
		lock_wait_time = 0.0
		await _travel_to(wait[0], wait[1], [])
		while not b.try_reserve(self):
			await b.freed
		_waiting_lock = false
		_wait_bay = null
		await _stop_homing()
	bay = b
	_lane_done = false
	while not b.doors_open and b.has_truck():
		await b.doors_changed
	await _travel_to(Vector2(stage.x, stage.z), stage_yaw, [])
	var loaded: bool = _loaded()
	_in_lane = true
	var route: PackedVector3Array = b.entry_route(slot, reach_for(slot))
	var last: Vector3 = route[route.size() - 1]
	var entry_s: float = maxf(b.along(b.rear_entry().origin) - b.along(stage), 0.0)
	var leg: MotionPath = MotionPath.from_pose(_pos, _yaw, false, &"lane")
	leg.straight(_pos.distance_to(Vector2(last.x, last.z)))
	leg.profile(lane_speed, turn_speed, accel * PLAN_DECEL)
	leg.add_event(0.0, func() -> void: _lane_climb(loaded))
	leg.add_event(entry_s, func() -> void: _lane_inside(slot, loaded))
	await _run_leg(leg, false)
	await _lane_settle(slot, loaded)


## Reverses out of the trailer and down the ramp to the stage point. The lane
## is freed once the agent has driven LANE_RELEASE_DISTANCE further.
func _exit_trailer(slot: StorageSlot) -> void:
	var b: TrailerBay = slot.bay as TrailerBay
	var loaded: bool = _loaded()
	var stage: Vector3 = b.stage_point(slot)
	var here: Vector3 = Vector3(_pos.x, 0.0, _pos.y)
	var entry_d: float = maxf(b.along(here) - b.along(b.rear_entry().origin), 0.0)
	var bottom_d: float = maxf(b.along(here), 0.0)
	await _before_lane_exit(loaded)
	var leg: MotionPath = MotionPath.from_pose(_pos, _yaw, true, &"lane")
	leg.straight(_pos.distance_to(Vector2(stage.x, stage.z)))
	leg.profile(lane_speed, turn_speed, accel * PLAN_DECEL)
	leg.add_event(entry_d, func() -> void: _lane_leave(loaded))
	leg.add_event(bottom_d + 0.3, func() -> void: _lane_left(loaded))
	await _run_leg(leg, false)
	_in_lane = false
	_since_lane = 0.0
	_lane_done = true


# --- travel ----------------------------------------------------------------------

## Drives (or walks) to a pose along clear, drivable legs; on a give-way
## request backs off and plans again.
func _travel_to(goal: Vector2, goal_yaw: float, exempt: Array) -> void:
	var attempt: int = 0
	while true:
		attempt += 1
		if attempt % 10 == 0:
			push_warning("%s: still re-planning to %s (attempt %d): %s, giving way to %s" % [label, goal, attempt, debug_state(),
					_give_way_from.call(&"debug_state") if _give_way_from != null and _give_way_from.has_method(&"debug_state") else str(_give_way_from)])
		var aborted: bool = false
		if min_turn_radius > 0.0:
			# no clear way yet: wait and look again; after a few tries take the
			# least bad way (a trip home too: idling in a work area blocks others)
			var legs: Array = _plan(goal, goal_yaw, exempt, attempt > 4, attempt)
			if legs.is_empty() and _homing and attempt > 2 and traffic != null:
				# no way in at the parking heading: park the other way round
				# (or across) when that pose is as clear
				for turn: float in [PI, PI * 0.5, -PI * 0.5]:
					var alt: float = wrapf(goal_yaw + turn, -PI, PI)
					if traffic.parking_problem(self, goal, alt, []).is_empty():
						legs = _plan(goal, alt, exempt, false)
						if not legs.is_empty():
							break
			if OS.get_environment("TRAFFIC_DEBUG") == "1" and attempt > 3:
				print("TRAVEL %s attempt %d legs %d lens %s" % [label, attempt, legs.size(), legs.map(func(l: MotionPath) -> String: return "%.2f" % l.length())])
			if legs.is_empty():
				if _homing and (_abort_home or job != null and not _waiting_lock):
					_abort_home = false
					return
				await _wait(2.0)
				if _homing and (_abort_home or job != null and not _waiting_lock):
					_abort_home = false
					return
				if _pending_give_way != null:
					var w: Node = _pending_give_way
					_pending_give_way = null
					if _homing and job == null:
						# idle with no way home: clear off the working one's way
						if await _clear_way(w):
							return
					await _back_off(w)
				continue
			for leg: MotionPath in legs:
				if not await _run_leg(leg, true):
					aborted = true
					break
		else:
			aborted = not await _walk_to(goal, goal_yaw)
		if not aborted:
			return
		if _homing and (job != null and not _waiting_lock or _abort_home):
			_abort_home = false
			return  # a new job (or a granted lock) took over the trip home
		if _reroute:
			_reroute = false
			await _wait(0.5)
			continue
		if _homing and job == null and _give_way_from != null:
			# idle: drive off its way to any free spot, home can wait
			if await _clear_way(_give_way_from):
				return
		await _back_off(_give_way_from)


func _plan(goal: Vector2, goal_yaw: float, exempt: Array, fallback: bool, attempt: int = 0) -> Array:
	# a trip home (or out of the way) with no job keeps the clearances to
	# others and waits for them; only after a while does it squeeze by
	var idle_trip: bool = _homing and job == null and attempt <= 8
	var legs: Array = traffic.plan_vehicle(self, _pos, _yaw, goal, goal_yaw, exempt, fallback and not idle_trip, 1 if idle_trip else 2)
	for leg: MotionPath in legs:
		if leg.reverse:
			leg.profile(reverse_speed, turn_speed, accel * PLAN_DECEL)
		else:
			leg.profile(move_speed, turn_speed, accel * PLAN_DECEL)
	return legs


## People: straight walks between router waypoints, pivoting at each corner
## (about the jack's load wheels when pushing one, so the wheels pass over
## each waypoint and the final pivot lands exactly on the goal pose).
func _walk_to(goal: Vector2, goal_yaw: float) -> bool:
	var lead: float = (_pos - _pivot_point()).length()
	var f_goal: Vector2 = Vector2(-sin(goal_yaw), -cos(goal_yaw))
	var final_point: Vector2 = goal + f_goal * lead
	var pts: PackedVector3Array = grid.router.plan(Vector3(_pos.x, 0.0, _pos.y), Vector3(final_point.x, 0.0, final_point.y))
	for p: Vector3 in pts:
		var q: Vector2 = Vector2(p.x, p.z)
		var to: Vector2 = q - _pivot_point()
		if to.length() < 0.05:
			continue
		await _face(atan2(-to.x, -to.y))
		to = q - _pivot_point()
		var dist: float = to.length() if lead > 0.0 else (q - _pos).length()
		if dist < 0.02:
			continue
		var leg: MotionPath = MotionPath.begin(_pos, atan2(to.y, to.x), false, &"travel")
		leg.straight(dist)
		leg.profile(move_speed, turn_speed, accel * PLAN_DECEL)
		if not await _run_leg(leg, true):
			return false
	await _face(goal_yaw)
	return true


## People turn to face a yaw (pivot); vehicles are aligned by their paths.
func _face(yaw: float) -> void:
	if min_turn_radius > 0.0 or absf(angle_difference(_yaw, yaw)) < 0.01:
		return
	_pivot_to = yaw
	_pivot_center = _pivot_point()
	await _action_done


## Point people pivot about (their feet; a pallet jack's load wheels).
func _pivot_point() -> Vector2:
	return _pos


## Backs away from `from` (or just waits when that is impossible), then
## lets it pass before planning again.
func _back_off(from: Node) -> void:
	_give_way_from = null
	var moved: bool = false
	if min_turn_radius > 0.0 and traffic != null and _pos.distance_to(_home_pos) > 3.0:
		# retreat towards the parking spot along a planned, clear path: the first
		# few metres are enough to clear the way
		var legs: Array = traffic.plan_vehicle(self, _pos, _yaw, _home_pos, _home_yaw, [], false)
		if not legs.is_empty() and _keeps_away(legs[0], from):
			var leg0: MotionPath = (legs[0] as MotionPath).head(BACK_OFF_DISTANCE)
			leg0.profile(reverse_speed if leg0.reverse else move_speed, turn_speed, accel * PLAN_DECEL)
			leg0.ignore_mover = from
			moved = await _run_leg(leg0, true)
	if not moved:
		var leg: MotionPath = _escape_leg(from)
		if leg != null:
			await _run_leg(leg, false)
	await _wait(1.0)
	for i: int in 16:
		if from == null or not is_instance_valid(from):
			break
		var theirs: Array = from.call(&"traffic_footprints")
		if theirs.is_empty() or FootprintBox.set_distance(footprints_at(_pos, _yaw), theirs) > 5.0 \
				or not bool(from.call(&"traffic_moving")) and from.get(&"blocked_by") != self:
			break
		await _wait(0.5)


func _idle_back_off(from: Node) -> void:
	if _homing:
		return
	_homing = true
	if not await _clear_way(from):
		var leg: MotionPath = _escape_leg(from)
		if leg != null:
			await _run_leg(leg, false)
	_homing = false
	_became_still.emit()


## Idle (or on the way home) and in the way of `from`: drive to any free
## spot off its way (the parking spot is back on the trip after the next
## job). An idle forklift never holds up a working one. True when it moved.
func _clear_way(from: Node) -> bool:
	_give_way_from = null
	_pending_give_way = null
	if min_turn_radius <= 0.0 or traffic == null:
		return false
	for spot: Array in _rooms_away_from(from, 8):
		var legs: Array = traffic.plan_vehicle(self, _pos, _yaw, spot[0], spot[1], [], false, 2)
		if legs.is_empty() or not _legs_clear_of(legs, from):
			continue
		for leg: MotionPath in legs:
			leg.profile(reverse_speed if leg.reverse else move_speed, turn_speed, accel * PLAN_DECEL)
			leg.ignore_mover = from
		for leg: MotionPath in legs:
			if not await _run_leg(leg, true):
				break
		return true
	return false


## No point of the legs comes within the hard vehicle distance of where
## `from` stands or is about to drive.
func _legs_clear_of(legs: Array, from: Node) -> bool:
	if from == null or not is_instance_valid(from):
		return true
	var danger: Array = [from.call(&"traffic_footprints")]
	if from.has_method(&"future_footprints"):
		danger.append_array(from.call(&"future_footprints", 12.0))
	var now: float = INF
	for d: Array in danger:
		now = minf(now, FootprintBox.set_distance(footprints_at(_pos, _yaw), d))
	for leg: MotionPath in legs:
		var s: float = 0.0
		while s <= leg.length():
			var fp: Array = footprints_at(leg.pos_at(s), leg.yaw_at(s))
			for d: Array in danger:
				# may start close (it is in the way), but never gets closer
				if FootprintBox.set_distance(fp, d) < minf(Traffic.HARD_VV - 1.0, now - 0.05):
					return false
			s += 0.5
	return true


## Would a forklift parked at this pose stand in `who`'s way (where it is or
## is about to drive)?
func _in_way_of(who: Node, p: Vector2, y: float) -> bool:
	if who == null or not is_instance_valid(who):
		return false
	var fp: Array = footprints_at(p, y)
	if FootprintBox.set_distance(fp, who.call(&"traffic_footprints")) < Traffic.SAFE_VV + 0.5:
		return true
	if who.has_method(&"future_footprints"):
		for f: Array in who.call(&"future_footprints", 12.0):
			if FootprintBox.set_distance(fp, f) < Traffic.SAFE_VV + 0.5:
				return true
	return false


## Up to `limit` parking poses 3 to 13 m away, nearest first, that keep well
## clear of where `from` is and is going and of every other forklift; proper
## parking poses (Traffic.parking_problem) before merely free floor.
func _rooms_away_from(from: Node, limit: int) -> Array:
	var danger: Array = []
	if from != null and is_instance_valid(from):
		danger.append(from.call(&"traffic_footprints"))
		if from.has_method(&"future_footprints"):
			danger.append_array(from.call(&"future_footprints", 12.0))
	var others: Array = []
	for m: Node in traffic.movers:
		if m != self and m != from and m.call(&"traffic_active"):
			others.append(m.call(&"traffic_footprints"))
	var good: Array = []
	var fair: Array = []
	for r: float in [3.0, 4.5, 6.0, 7.5, 9.0, 11.0, 13.0]:
		for k: int in 16:
			var p: Vector2 = _pos + Vector2.from_angle(k * TAU / 16.0) * r
			if not traffic.open_floor(p):
				continue
			for turn: float in [0.0, PI, PI * 0.5, -PI * 0.5]:
				var y: float = wrapf(_yaw + turn, -PI, PI)
				var fp: Array = footprints_at(p, y)
				if not traffic.inside_hall(fp) or traffic.static_hit(fp, 0.3) >= 0 or traffic.in_keep_clear(fp):
					continue
				var clear: bool = true
				for d: Array in danger:
					if FootprintBox.set_distance(fp, d) < Traffic.SAFE_VV + 1.0:
						clear = false
						break
				for o: Array in others:
					if clear and FootprintBox.set_distance(fp, o) < Traffic.SAFE_VV:
						clear = false
				if not clear:
					continue
				if traffic.parking_problem(self, p, y, []).is_empty():
					good.append([p, y])
				else:
					fair.append([p, y])
				break  # one heading per point is enough
			if good.size() >= limit:
				return good
	good.append_array(fair)
	return good.slice(0, limit)


## A short straight (forward or back) or arc that gets furthest from every
## mover nearby (and from `from` above all) and stays clear of obstacles.
func _escape_leg(from: Node) -> MotionPath:
	var others: Array = []
	if traffic != null:
		for m: Node in traffic.movers:
			if m != self and m.call(&"traffic_active"):
				var fp: Array = m.call(&"traffic_footprints")
				if not fp.is_empty() and (fp[0] as FootprintBox).c.distance_to(_pos) < 9.0:
					others.append(fp)
	# where the one we make way for is about to drive
	var their_path: Array = []
	if from != null and is_instance_valid(from) and from.has_method(&"future_footprints"):
		their_path = from.call(&"future_footprints", 6.0)
	var score_at: Callable = func(p: Vector2, y: float) -> float:
		var mine: Array = footprints_at(p, y)
		var worst: float = INF
		for fp: Array in others:
			worst = minf(worst, FootprintBox.set_distance(mine, fp))
		for fp: Array in their_path:
			worst = minf(worst, FootprintBox.set_distance(mine, fp) * 0.8)
		if from != null and is_instance_valid(from):
			worst = minf(worst, FootprintBox.set_distance(mine, from.call(&"traffic_footprints")) * 0.8)
		return worst
	var now: float = score_at.call(_pos, _yaw)
	var best: MotionPath = null
	var best_d: float = now + 0.2
	var specs: Array = [[true, 0.0, 2.5], [false, 0.0, 2.5],
		[true, PI * 0.33, 0.0], [true, -PI * 0.33, 0.0], [false, PI * 0.33, 0.0], [false, -PI * 0.33, 0.0],
		[true, PI * 0.5, 0.0], [true, -PI * 0.5, 0.0], [false, PI * 0.5, 0.0], [false, -PI * 0.5, 0.0]]
	for spec: Array in specs:
		var leg: MotionPath = MotionPath.from_pose(_pos, _yaw, spec[0], &"escape")
		if min_turn_radius <= 0.0:
			if absf(spec[1]) > 0.0 or spec[2] > 3.0:
				continue
			leg.straight(1.5)
		elif absf(spec[1]) > 0.0:
			leg.arc(spec[1], min_turn_radius * 1.1)
		else:
			leg.straight(spec[2])
		if traffic != null and min_turn_radius > 0.0 and not traffic.path_clear(self, leg, [], 2):
			continue
		if traffic != null and not traffic.open_floor(leg.end_pos()) and (traffic.open_floor(_pos) or leg.length() > 1.0):
			continue  # do not back into a corner the router cannot get out of
		if traffic != null and min_turn_radius > 0.0 and not in_keep_clear() and traffic.in_keep_clear(footprints_at(leg.end_pos(), leg.end_yaw())):
			continue  # nor into a work area (zone front, lane apron, aisle)
		if not _keeps_away(leg, from):
			continue
		var d: float = score_at.call(leg.end_pos(), leg.end_yaw())
		if d > best_d:
			best_d = d
			best = leg
	if best != null:
		best.profile(reverse_speed if best.reverse else lane_speed, turn_speed, accel * PLAN_DECEL)
		best.ignore_mover = from
	return best


## On a leg that cannot be changed (in a lane, approaching or backing out of
## a slot): others must keep clear of where it is going.
func committed() -> bool:
	return _leg != null and not _leg_abortable and _leg.tag != &"escape"


## True when no point of the leg comes closer to `from` than it is now.
func _keeps_away(leg: MotionPath, from: Node) -> bool:
	if from == null or not is_instance_valid(from):
		return true
	var theirs: Array = from.call(&"traffic_footprints")
	if theirs.is_empty():
		return true
	var now: float = FootprintBox.set_distance(footprints_at(_pos, _yaw), theirs)
	var s: float = 0.25
	while s <= leg.length():
		if FootprintBox.set_distance(footprints_at(leg.pos_at(s), leg.yaw_at(s)), theirs) < now - 0.05:
			return false
		s += 0.25
	return true


## Footprints along the rest of the current leg (every 0.5 m, up to `ahead`).
func future_footprints(ahead: float) -> Array:
	if _leg == null:
		if _future_leg != null or not _future_cache.is_empty():
			_future_cache = []
			_future_leg = null
		return _future_cache
	# samples every 0.5 m on the leg's fixed grid, shared with the traffic checks
	var k0: int = ceili(_s / Traffic.CONFLICT_STRIDE)
	var k1: int = floori(minf(_s + ahead, _leg.length()) / Traffic.CONFLICT_STRIDE)
	var key: Vector3i = Vector3i(k0, k1, int(footprint_variant() * 1000.0))
	if _leg == _future_leg and key == _future_key:
		return _future_cache
	if _leg.fp_variant != footprint_variant():
		_leg.fp_cache.clear()
		_leg.fp_variant = footprint_variant()
	_future_leg = _leg
	_future_key = key
	_future_cache = []
	var k: int = k0
	while k <= k1:
		var cached: Variant = _leg.fp_cache.get(k)
		if cached == null:
			var sk: float = minf(k * Traffic.CONFLICT_STRIDE, _leg.length())
			cached = footprints_at(_leg.pos_at(sk), _leg.yaw_at(sk))
			_leg.fp_cache[k] = cached
		_future_cache.append(cached)
		k += 2
	return _future_cache


## Idle: drive back to the rest spot and stand there.
func _go_home() -> void:
	if _pos.distance_to(_home_pos) >= 0.5:
		_homing = true
		await _travel_to(_home_pos, _home_yaw, [])
		_homing = false
		_became_still.emit()
		if job == null and _pos.distance_to(_home_pos) >= 0.5 and _give_way_from != null:
			# no way home from here: at least move out of the way
			var from: Node = _give_way_from
			_give_way_from = null
			_idle_back_off(from)
	if job == null:
		became_idle.emit(self)


## Stops the walk or drive to the rest spot (a job or another duty takes over).
func interrupt_rest() -> void:
	if _homing:
		_abort = true
		_abort_home = true


func set_home_here() -> void:
	_home_pos = _pos
	_home_yaw = _yaw


# --- leg execution --------------------------------------------------------------------

## Follows one leg to its end. Returns false when aborted (give way).
func _run_leg(leg: MotionPath, abortable: bool) -> bool:
	if leg == null or leg.pts.size() < 2:
		return true
	_leg = leg
	_s = 0.0
	_event_index = 0
	_leg_abortable = abortable
	_conflict = INF
	_on_move(true)
	var aborted: bool = await _leg_finished
	_on_move(false)
	return not aborted


## Waits `seconds` of 1x time, honouring pause and game speed.
func _wait(seconds: float) -> void:
	await _animate(seconds, Callable())


## Calls fn(t) with t going 0..1 over `seconds` of 1x time (agent stopped).
func _animate(seconds: float, fn: Callable) -> void:
	_action = fn if fn.is_valid() else func(_t: float) -> void: pass
	_action_time = 0.0
	_action_length = maxf(seconds, 0.001)
	await _action_done


func _process(delta: float) -> void:
	if body == null or GameState.paused:
		return
	var left: float = delta * float(GameState.speed)
	# traffic is checked every CONFLICT_EVERY sub-steps (at most 1/15 s of
	# game time apart), so fast-forward reacts as early as 1x
	var n: int = 0
	while left > 0.0:
		if n % CONFLICT_EVERY == 0:
			_update_conflict(minf(left, MAX_STEP * CONFLICT_EVERY))
		var dt: float = minf(left, MAX_STEP)
		left -= dt
		_tick(dt)
		n += 1


func _update_conflict(react: float) -> void:
	_conflict = INF
	_conflict_by = null
	if _leg == null or traffic == null:
		return
	var look: float = speed * speed / (2.0 * accel * PLAN_DECEL) + 1.5
	var r: Array = traffic.conflict_ahead(self, _leg, _s, look + speed * react, _leg.ignore_mover, react)
	_conflict = r[0]
	_conflict_by = r[1]


func _tick(dt: float) -> void:
	_tick_forks(dt)
	if _action.is_valid():
		_action_time += dt
		var t: float = clampf(_action_time / _action_length, 0.0, 1.0)
		var fn: Callable = _action
		fn.call(t)
		if t >= 1.0:
			_action = Callable()
			_action_done.emit()
		return
	if not is_nan(_pivot_to):
		_tick_pivot(dt)
		return
	if _leg == null:
		speed = 0.0
		return
	var length: float = _leg.length()
	var cap: float = _leg.vmax_at(_s)
	if _s < length - 0.002:
		cap = maxf(cap, 0.02)  # creep the last fraction of a millimetre onto the mark
	if _forks_busy():
		cap = minf(cap, creep_speed)
	var blocked: bool = false
	if _conflict < INF:
		var room: float = maxf(_conflict - 0.3, 0.0)
		var v_room: float = sqrt(2.0 * accel * PLAN_DECEL * room)
		if v_room < cap:
			cap = v_room
			blocked = cap < 0.05
	if _abort and _leg_abortable:
		cap = 0.0
	if _leg.tag == &"escape" and blocked_time > 1.5:
		_abort = true
		_leg_abortable = true  # an escape that is itself blocked just stops
		cap = 0.0
	# limited acceleration and braking (never harder than accel)
	if cap > speed:
		speed = minf(cap, speed + accel * dt)
	else:
		speed = maxf(cap, speed - accel * dt)
	if blocked or (_conflict < 0.6 and speed < 0.06):
		blocked_by = _conflict_by
		blocked_time += dt
	elif speed > 0.15:
		blocked_by = null
		blocked_time = 0.0
	if not _leg_abortable and blocked_time > PERSON_ABORT_TIME and (_leg.tag == &"approach" or _leg.tag == &"back_out") \
			and blocked_by != null and is_instance_valid(blocked_by) and int(blocked_by.call(&"traffic_kind")) == Traffic.Kind.PERSON:
		# a person stands in the way of a slot manoeuvre: give it up (stop at
		# accel), the caller backs out and tries again
		_abort = true
		_leg_abortable = true
		blocked_time = 0.0
	var ds: float = minf(speed * dt, length - _s)
	if ds > 0.0:
		_s += ds
		odometer += ds
		if _conflict < INF:
			_conflict -= ds
		_pos = _leg.pos_at(_s)
		_yaw = _leg.yaw_at(_s)
		curvature = _leg.curv_at(_s)
		_on_travel(-ds if _leg.reverse else ds)
		if _held_lock != null and _lock_release_in >= 0.0:
			_lock_release_in -= ds
			if _lock_release_in < 0.0 or not _in_lock_area(_held_lock):
				_release_lock()
		if bay != null and _lane_done:
			_since_lane += ds
			if _since_lane >= LANE_RELEASE_DISTANCE:
				var b: TrailerBay = bay
				bay = null
				_lane_done = false
				b.release(self)
		_apply_pose()
	while _event_index < _leg.events.size() and float(_leg.events[_event_index][0]) <= _s + 0.0001:
		var fn: Callable = _leg.events[_event_index][1]
		_event_index += 1
		fn.call()
	if _abort and _leg_abortable and speed <= 0.001:
		_abort = false
		_leg = null
		speed = 0.0
		blocked_by = null
		_leg_finished.emit(true)
		return
	if _s >= length - 0.0005 and speed <= 0.03:
		_s = length
		_pos = _leg.end_pos()
		_yaw = _leg.end_yaw()
		speed = 0.0
		curvature = 0.0
		_leg = null
		blocked_by = null
		blocked_time = 0.0
		_apply_pose()
		_leg_finished.emit(false)


func _tick_pivot(dt: float) -> void:
	var diff: float = angle_difference(_yaw, _pivot_to)
	var step: float = clampf(diff, -pivot_rate * dt, pivot_rate * dt)
	_yaw += step
	if not _pivot_center.is_equal_approx(_pos):
		_pos = _pivot_center + (_pos - _pivot_center).rotated(-step)
	_apply_pose()
	if absf(diff) <= pivot_rate * dt:
		_yaw = _pivot_to
		_pivot_to = NAN
		_apply_pose()
		_action_done.emit()


## One line of state for logs and test failures.
func debug_state() -> String:
	return "%s pos (%.2f, %.2f) yaw %.0f v %.2f job %s leg %s %.1f/%.1f%s%s%s%s" % [
		label, _pos.x, _pos.y, rad_to_deg(_yaw), speed,
		CarryJob.Kind.keys()[job.kind] if job != null else "-",
		String(_leg.tag) if _leg != null else "-", _s, _leg.length() if _leg != null else 0.0,
		" blocked by %s %.1fs" % [blocked_by.get(&"label") if blocked_by != null and blocked_by.get(&"label") != null else (blocked_by.name if blocked_by != null else ""), blocked_time] if blocked_by != null else "",
		(" waiting-lock" if _waiting_lock else "") + (" homing" if _homing else "") + (" abort" if _abort else ""), " lane" if bay != null else "",
		" action" if _action.is_valid() else (" pivot" if not is_nan(_pivot_to) else "")]


func _forward() -> Vector3:
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


## Reads the pose back from the body (setup, or after it was moved while idle).
func _sync_pose() -> void:
	var p: Vector3 = body.global_position
	_pos = Vector2(p.x, p.z)
	_yaw = body.global_rotation.y
	_pitch = 0.0


## Puts the body at _pos / _yaw with height and pitch from the floor under
## the axles.
func _apply_pose() -> void:
	var pos: Vector3 = Vector3(_pos.x, 0.0, _pos.y)
	var back: Vector3 = -_forward()
	var y: float = 0.0
	if axle_rear > axle_front:
		var hf: float = grid.ground_height(pos + back * axle_front)
		var hr: float = grid.ground_height(pos + back * axle_rear)
		var base: float = axle_rear - axle_front
		_pitch = atan2(hf - hr, base)
		y = hf - axle_front * (hr - hf) / base
	else:
		_pitch = 0.0
		y = grid.ground_height(pos)
	body.global_position = Vector3(pos.x, y, pos.z)
	body.global_rotation = Vector3(_pitch, _yaw, 0.0)
	_after_pose()


## Where to put a pallet down for this slot: its parent and local transform.
func _slot_parent(slot: StorageSlot) -> Node3D:
	return slot.anchor if slot.is_trailer() and is_instance_valid(slot.anchor) else grid.cargo_root


func _slot_local(slot: StorageSlot) -> Transform3D:
	return slot.local if slot.is_trailer() and is_instance_valid(slot.anchor) else slot.pallet_transform()


## Hands the pallet to its slot without moving it (the forks or jack have
## lowered it onto the slot); the last millimetres are made exact.
func _set_down(node: Node3D, slot: StorageSlot) -> void:
	node.reparent(_slot_parent(slot), true)
	var target: Transform3D = _slot_local(slot)
	var off: float = node.transform.origin.distance_to(target.origin)
	if off < 0.05:
		node.transform = target
	else:
		push_warning("%s: %s set down %.2f m off its slot (%s vs %s, %s)" % [label, node.name, off, node.transform.origin, target.origin, debug_state()])


## The pallet's yaw relative to the holder, snapped to a quarter turn.
func _held_yaw(node: Node3D, holder: Node3D) -> float:
	var rel: Basis = holder.global_basis.orthonormalized().inverse() * node.global_basis.orthonormalized()
	var x: Vector3 = rel * Vector3.RIGHT
	return snappedf(atan2(-x.z, x.x), PI * 0.5)


static func _depth_for(held_yaw: float) -> float:
	return 1.2 if absf(sin(held_yaw)) > 0.5 else 0.8
