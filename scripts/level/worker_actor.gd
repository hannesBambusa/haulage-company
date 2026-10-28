class_name WorkerActor
extends Node3D
## Animated worker on a worker*.glb instance.
##
## Two modes:
## - Scenery (no DutyPlanner): plays Idle in place or walks a looping patrol
##   path (points are in the parent's space), idling at each stop. A
##   WorkerCarrier can borrow the worker for a carry job: begin_job() stops
##   the patrol, end_job() resumes it.
## - Staff (enable_duties() by the DutyPlanner): the planner drives the worker
##   through small motor commands (walk_to, turn_to, slide, hold / play_once
##   an action) and hands props between shelves, belt and hands. Walking
##   follows a PeopleNav route with smooth speed and turning, the walk cycle
##   plays at the walking speed (no foot sliding), actions crossfade, and the
##   worker keeps its distance from forklifts and other people (yielding, and
##   stepping aside when Traffic asks it to give way).

@export var idle_animation: StringName = &"Idle"
## Played while moving along the patrol (Carry for a worker with a box).
@export var walk_animation: StringName = &"Walk"
@export var patrol_points: PackedVector3Array = PackedVector3Array()
@export var walk_speed: float = 1.3
@export var pause_time: float = 1.5
## Turn rate in rad/s.
@export var turn_speed: float = 3.0
@export var accel: float = 1.2
## Ground speed of the walk / carry cycles in model units (1.408 m stride
## per 1.083 s cycle); the node scale is applied on top.
@export var anim_speed: float = 1.3
## False: stand still when not on a job (job workers rest at a spot).
@export var patrol_enabled: bool = true
## Start offset into the patrol, so several workers do not move in sync.
@export_range(0.0, 1.0) var phase: float = 0.0

enum Motor { RUNNING, DONE, FAILED }
enum Mode { STILL, WALK, TURN, SLIDE }

const GAITS: Array[StringName] = [&"Walk", &"Carry", &"PushJack"]
const LOOPS: Array[StringName] = [&"Idle", &"Walk", &"Carry", &"PushJack", &"Sweep", &"Mop", &"DrinkCoffee", &"Talk", &"Listen", &"SitIdle", &"Clipboard", &"ScanPallet", &"Inspect", &"PhoneCall", &"Wrench"]
## Root speed of the Sweep action in model units (m/s).
const SWEEP_SPEED: float = 0.2
## Prop offsets on the hand bones (prop origin = centre of the fist).
const HAND_R: Transform3D = Transform3D(Vector3(0.9998, 0, 0.0211), Vector3(0, 1, 0), Vector3(-0.0211, 0, 0.9998), Vector3(-0.0009, 0.04, 0.005))
const HAND_L: Transform3D = Transform3D(Vector3(0.9998, 0, -0.0211), Vector3(0, 1, 0), Vector3(0.0211, 0, 0.9998), Vector3(0.0009, 0.04, 0.005))
const PERSON_HALF: float = 0.28
## Keep-out from a forklift that stands still (it cannot run anyone over;
## routes keep a little more).
const PARKED_GAP: float = 1.7
## Metres of a forklift's coming path a worker walking round it keeps off.
const WALK_ROUND_AHEAD: float = 4.0
## Planned braking (onto a mark, for someone ahead) uses this share of accel,
## so the last step onto the mark stays within accel.
const PLAN_DECEL: float = 0.9
## Centre distance kept from people who stand still (and while stepping aside).
const STANDING_GAP: float = 0.92

## The traffic mover that stands for this worker (itself, or its carrier).
var mover: Node = null
var traffic: Traffic = null
var blocked_by: Node = null
var blocked_time: float = 0.0
## Current walking speed.
var speed: float = 0.0
## Total distance walked (for tests).
var odometer: float = 0.0

# --- staff mode -------------------------------------------------------------------
## The DutyPlanner driving this worker (null in scenery mode).
var planner: Node = null
var nav: PeopleNav = null
var staff_id: int = 0
var display_name: String = ""
## Duty in progress (a Duty), or null.
var duty: RefCounted = null
## Conversation group the worker belongs to (people in it may stand closer).
var group: RefCounted = null
## Needs, 0..1 (the planner raises and lowers them).
var tired: float = 0.0
var thirst: float = 0.0
var social: float = 0.0
## Props in the hands: &"R" / &"L" -> PropItem or null.
var hands: Dictionary = {&"R": null, &"L": null}
## Personal kit on the belt (scanner, clipboard, phone).
var kit: Dictionary = {}
## Props rolled along beside the worker (mop bucket).
var towed: Array[PropItem] = []
## Chair the worker sits on, or null.
var seat: Node3D = null
var motor: Motor = Motor.DONE
## True once after the worker had to step aside (the duty walks back).
var displaced: bool = false
## Forklift the worker is allowed to stand next to (servicing it). Cleared
## while still right next to it (a duty dropped at once), it stays set until
## the worker has walked clear (staff_step), so it never counts as too close.
var service_vehicle: Node = null:
	set(v):
		if v == null and service_vehicle != null and is_instance_valid(service_vehicle) and _service_close(service_vehicle):
			_service_clearing = true
			return
		_service_clearing = false
		service_vehicle = v
var _service_clearing: bool = false
## Distance walked per second in the last staff step (see _keep_pace).
var _pace: float = 0.0
var current_action: StringName = &"Idle"

var _anim: AnimationPlayer
var _skeleton: Skeleton3D
var _attach: Dictionary = {}  ## &"R", &"L", &"Hips" -> BoneAttachment3D
var _index: int = 0
var _wait: float = 0.0
var _home: Vector3
var _home_yaw: float = 0.0
var _on_job: bool = false
var _returning: bool = false
## Where the worker was put to rest (stepping aside stays near it).
var _rest: Vector2 = Vector2.ZERO

var _mode: Mode = Mode.STILL
var _base_anim: StringName = &"Idle"
var _once_left: float = 0.0
var _goal: Vector2 = Vector2.ZERO
var _goal_yaw: float = NAN
var _path: PackedVector2Array = PackedVector2Array()
var _path_i: int = 0
var _walk_anim: StringName = &"Walk"
var _turn_to: float = 0.0
var _slide_to: Vector2 = Vector2.ZERO
var _slide_speed: float = 0.0
var _slide_anim: StringName = &"Idle"
var _check_in: int = 0
var _blocked: Node = null
var _block_t: float = 0.0
var _total_block_t: float = 0.0
var _yielding: bool = false
## Standing to let another walker pass (_give_to).
var _giving_way: bool = false
var _steer: Vector2 = Vector2.ZERO
## Seconds the route has led hard into a parked forklift (see _vehicle_slide).
var _slide_t: float = 0.0
var _coast_dir: Vector2 = Vector2.ZERO
## Safety stops: the worker had to stop dead because someone (or a wall)
## was suddenly in the way of its next step. Counted for tests (the one
## place a worker brakes harder than accel), with the reasons.
var safety_stops: int = 0
static var hard_stops: Dictionary = {}


func _note_stop(reason: String, v: float) -> void:
	if v > accel * (1.0 / 60.0):
		safety_stops += 1
		hard_stops[reason] = int(hard_stops.get(reason, 0)) + 1
var _edge_t: float = 0.0
## Seconds stood still on the way somewhere, whatever stopped the worker
## (a person, a forklift's keep-out, both at once). Past STALL_TIME it
## decides (_unstall) instead of waiting on; _stalls counts the decisions
## since it last got going, so each one tries the next way out.
var _stall_t: float = 0.0
var _stalls: int = 0
const STALL_TIME: float = 1.5
var _people_replans: int = 0
var _people_cap: float = INF
var _people_by: Node = null
var _near_people: Array[Node] = []
var _give_to: Node = null
var _give_t: float = 0.0
var _yield_from: Node = null
var _yield_wait: float = 0.0
var _saved_goal: Variant = null
var _prop_moves: Array[Dictionary] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_home = position
	_home_yaw = rotation.y
	if mover == null:
		mover = self
	_anim = find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		for anim_name: StringName in LOOPS:
			if _anim.has_animation(anim_name):
				_anim.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
	if patrol_points.size() >= 2:
		_index = int(phase * patrol_points.size()) % patrol_points.size()
		var nxt: Vector3 = patrol_points[(_index + 1) % patrol_points.size()]
		position = patrol_points[_index].lerp(nxt, fmod(phase * patrol_points.size(), 1.0))
		_index = (_index + 1) % patrol_points.size()
		_face_now(patrol_points[_index])
		_play(walk_animation)
	else:
		_play(idle_animation)
	if _anim != null and _anim.current_animation != "":
		_anim.seek(phase * _anim.current_animation_length, true)


## True for workers that just stand or patrol empty-handed, so they can be
## given carry jobs. Workers posed with a box (Carry animations) are scenery.
func is_job_capable() -> bool:
	return walk_animation != &"Carry" and idle_animation != &"Carry"


func is_on_job() -> bool:
	return _on_job


func is_walking() -> bool:
	return speed > 0.02


func begin_job() -> void:
	_on_job = true
	_returning = false
	speed = 0.0
	if planner != null:
		planner.call(&"worker_taken", self)


func end_job() -> void:
	_on_job = false
	speed = 0.0
	_rest = Vector2(position.x, position.z)
	if planner != null:
		_mode = Mode.STILL
		motor = Motor.DONE
		hold(&"Idle")
		return
	if not patrol_enabled:
		_play(idle_animation)
	elif patrol_points.size() >= 2:
		_wait = 0.0
		_play(walk_animation)
	else:
		_returning = true
		_play(walk_animation)


## Marks where the worker stands idle now.
func set_rest_here() -> void:
	_rest = Vector2(position.x, position.z)
	_home = position


func play_animation(anim_name: StringName) -> void:
	_play(anim_name)


## Plays the walk cycle in step with `v` (m/s at 1x).
func set_walk_speed(v: float) -> void:
	if _anim == null:
		return
	var walking: bool = _anim.current_animation == String(walk_animation) or _anim.current_animation == "Walk" or _anim.current_animation == "Carry"
	var gs: float = float(GameState.speed) if not GameState.paused else 0.0
	# the cycle covers anim_speed m/s in model units; the node scale stretches it
	_anim.speed_scale = (clampf(v / (anim_speed * scale.x), 0.0, 2.0) if walking else 1.0) * gs


## Someone needs the way: walk back to the previous patrol point (or step
## away from them when standing).
func give_way(winner: Node) -> void:
	if _on_job:
		return
	if planner != null:
		if service_vehicle == null and _is_machine(winner):
			if not _walk_round(winner):
				clear_the_way(winner)
		else:
			_start_yield(winner)
		return
	if patrol_enabled and patrol_points.size() >= 2:
		_index = (_index - 1 + patrol_points.size()) % patrol_points.size()
		_wait = 0.0
	elif winner != null and is_instance_valid(winner) and not _returning:
		var theirs: Array = winner.call(&"traffic_footprints")
		if not theirs.is_empty():
			var away: Vector2 = Vector2(position.x, position.z) - (theirs[0] as FootprintBox).c
			if away.length() > 0.01:
				away = away.normalized() * 2.0
				var here: Vector2 = Vector2(position.x, position.z)
				for d: Vector2 in [away, away.orthogonal(), -away.orthogonal()]:
					var to: Vector2 = here + d
					if _rest.distance_to(to) > 3.0:
						continue  # do not wander off: stay near the rest spot
					var clear: bool = true
					for k: int in 5:
						if traffic != null and traffic.static_hit(traffic_footprints_at(here.lerp(to, (k + 1) / 5.0), 0.0), 0.15) >= 0:
							clear = false
							break
					if not clear:
						continue
					_home = Vector3(to.x, position.y, to.y)
					_returning = true
					break
	blocked_by = null
	blocked_time = 0.0


# --- traffic interface (scenery and staff workers stand for themselves) ------------

func traffic_kind() -> int:
	return Traffic.Kind.PERSON


func traffic_footprints() -> Array:
	return traffic_footprints_at(Vector2(global_position.x, global_position.z), global_rotation.y)


func traffic_footprints_at(p: Vector2, yaw: float) -> Array:
	return [FootprintBox.local_span(p, yaw, -PERSON_HALF, PERSON_HALF, PERSON_HALF)]


func traffic_active() -> bool:
	return is_visible_in_tree() and not _on_job


func traffic_moving() -> bool:
	return is_walking()


func traffic_working() -> bool:
	return false


## Below every forklift and jack, idle ones too (Traffic yield order).
func traffic_priority() -> int:
	return -90000


func traffic_give_way(winner: Node) -> bool:
	give_way(winner)
	return true


## Where the worker will be along its route in the next `ahead` metres
## (forklifts look at this to slow down early for people).
func future_footprints(ahead: float) -> Array:
	var out: Array = []
	if planner == null or _mode != Mode.WALK or _path_i >= _path.size():
		return out
	var p: Vector2 = pos2()
	var left: float = ahead
	var i: int = _path_i
	while left > 0.0 and i < _path.size():
		var seg: Vector2 = _path[i] - p
		var l: float = seg.length()
		var step: float = 0.5
		var s: float = step
		while s <= minf(l, left):
			out.append(traffic_footprints_at(p + seg / l * s, global_rotation.y))
			s += step
		left -= l
		p = _path[i]
		i += 1
	return out


# --- scenery walking ----------------------------------------------------------------

func _process(delta: float) -> void:
	if _on_job or GameState.paused or planner != null:
		return
	# small steps, so fast-forward walks (and stops) as smoothly as 1x
	var left: float = delta * float(GameState.speed)
	while left > 0.0:
		var dt: float = minf(left, 1.0 / 60.0)
		left -= dt
		_step(dt)


func _step(dt: float) -> void:
	if _returning:
		_walk_towards(_home, dt, true)
		set_walk_speed(speed)
		return
	if patrol_points.size() < 2 or not patrol_enabled:
		speed = 0.0
		set_walk_speed(0.0)
		return
	if _wait > 0.0:
		_wait -= dt
		if _wait <= 0.0:
			_play(walk_animation)
		set_walk_speed(0.0)
		return
	var goal: Vector3 = patrol_points[_index]
	if _walk_towards(goal, dt, false):
		_index = (_index + 1) % patrol_points.size()
		_wait = pause_time
		if _wait > 0.0:
			_play(idle_animation)
	set_walk_speed(speed)


## Walks towards goal with smooth speed and turning. Returns true on arrival.
func _walk_towards(goal: Vector3, dt: float, home: bool) -> bool:
	var to_goal: Vector3 = goal - position
	to_goal.y = 0.0
	var dist: float = to_goal.length()
	if dist < 0.02:
		position = Vector3(goal.x, position.y, goal.z)
		speed = 0.0
		if home:
			_returning = false
			_play(idle_animation)
		return true
	var want: float = atan2(-to_goal.x, -to_goal.z)  # model front is -Z (build_worker.py)
	var diff: float = angle_difference(rotation.y, want)
	rotation.y += clampf(diff, -turn_speed * dt, turn_speed * dt)
	var heading: Vector3 = Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	# speed: slow for sharp turns, brake for the stop, stop for traffic
	var cap: float = walk_speed * clampf(1.0 - absf(diff) / 1.2, 0.0, 1.0)
	cap = minf(cap, sqrt(2.0 * accel * dist))
	var blocker: Node = null
	if traffic != null:
		blocker = traffic.person_blocked(mover, Vector2(position.x, position.z), Vector2(heading.x, heading.z), 1.2 + speed)
	if blocker != null:
		cap = 0.0
		blocked_time += dt
		blocked_by = blocker
		if mover != self:
			mover.set(&"blocked_by", blocker)
			mover.set(&"blocked_time", blocked_time)
	else:
		blocked_time = 0.0
		blocked_by = null
		if mover != self:
			mover.set(&"blocked_by", null)
			mover.set(&"blocked_time", 0.0)
	if cap > speed:
		speed = minf(cap, speed + accel * dt)
	else:
		speed = maxf(cap, speed - accel * dt)
	var step: float = minf(speed * dt, dist)
	position += heading * step
	if home and dist - step < 0.02 and speed < 0.05:
		position = Vector3(goal.x, position.y, goal.z)
		_returning = false
		_play(idle_animation)
		return true
	return not home and dist - step < 0.03


func _face_now(goal: Vector3) -> void:
	var dir: Vector3 = goal - position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	rotation.y = atan2(-dir.x, -dir.z)


func _play(anim_name: StringName) -> void:
	if _anim != null and _anim.has_animation(anim_name):
		_anim.play(anim_name, 0.25)


# =====================================================================================
# Staff mode
# =====================================================================================

## Hands the worker to a DutyPlanner: hand and belt attachments, walking pace.
func enable_duties(p_planner: Node, p_nav: PeopleNav, id: int, seed_value: int) -> void:
	planner = p_planner
	nav = p_nav
	staff_id = id
	display_name = "Worker %d" % id
	patrol_enabled = false
	_returning = false
	_rng.seed = seed_value
	walk_speed = _rng.randf_range(DutyConfig.WALK_SPEED.x, DutyConfig.WALK_SPEED.y)
	accel = DutyConfig.ACCEL
	tired = _rng.randf() * DutyConfig.NEED_START_MAX
	thirst = _rng.randf() * DutyConfig.NEED_START_MAX
	social = _rng.randf() * DutyConfig.NEED_START_MAX
	_skeleton = find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton != null:
		for key: StringName in [&"R", &"L", &"Hips"]:
			var ba: BoneAttachment3D = BoneAttachment3D.new()
			ba.name = "Attach_" + String(key)
			ba.bone_name = "Hand_" + String(key) if key != &"Hips" else "Hips"
			_skeleton.add_child(ba)
			_attach[key] = ba
	_mode = Mode.STILL
	motor = Motor.DONE
	_base_anim = &""
	hold(&"Idle")


func pos2() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func yaw() -> float:
	return global_rotation.y


static func yaw_towards(from: Vector2, to: Vector2) -> float:
	var d: Vector2 = to - from
	return atan2(-d.x, -d.y)


## Unit vector the worker faces on the floor plane.
func forward2() -> Vector2:
	return Vector2(-sin(yaw()), -cos(yaw()))


func right2() -> Vector2:
	return Vector2(cos(yaw()), -sin(yaw()))


func is_busy_motor() -> bool:
	return motor == Motor.RUNNING


## Loop `anim` while standing (crossfades from whatever plays now).
func hold(anim: StringName) -> void:
	_base_anim = anim
	current_action = anim
	_once_left = 0.0
	if _mode == Mode.STILL:
		_crossfade(anim)


## Plays a one-shot action, then returns to the held loop. Returns its length.
func play_once(anim: StringName) -> float:
	if _anim == null or not _anim.has_animation(anim):
		return 0.0
	_crossfade(anim)
	current_action = anim
	_once_left = _anim.get_animation(anim).length
	return _once_left


## Walks to `p` (and turns to `face_yaw` when given) along a PeopleNav route.
func walk_to(p: Vector2, face_yaw: float = NAN) -> void:
	_stall_t = 0.0
	_stalls = 0
	_goal = p
	_goal_yaw = face_yaw
	_saved_goal = null
	_total_block_t = 0.0
	_giving_way = false
	if not _plan_path():
		var alt: Vector2 = nav.nearest_walkable(p, 1.5)
		_goal = alt
		if alt == p or not _plan_path():
			if OS.get_environment("DUTY_DEBUG") == "1":
				print("%s: no way from %s (%d) to %s (%d)" % [display_name, pos2(), nav.value_at(pos2()), p, nav.value_at(p)])
			motor = Motor.FAILED
			_mode = Mode.STILL
			return
	motor = Motor.RUNNING
	_mode = Mode.WALK
	_crossfade(_walk_anim)


func turn_to(target_yaw: float) -> void:
	_turn_to = target_yaw
	if absf(angle_difference(yaw(), target_yaw)) < 0.03:
		rotation.y = target_yaw
		motor = Motor.DONE
		return
	motor = Motor.RUNNING
	_mode = Mode.TURN


func face_point(p: Vector2) -> void:
	if p.distance_to(pos2()) < 0.05:
		motor = Motor.DONE
		return
	turn_to(yaw_towards(pos2(), p))


## Moves the root in a straight line at `v` m/s without turning, playing
## `anim` (Sweep: v matches its root speed; sitting down: a short shuffle).
func slide_to(p: Vector2, v: float, anim: StringName) -> void:
	_slide_to = p
	_slide_speed = v
	_slide_anim = anim
	motor = Motor.RUNNING
	_mode = Mode.SLIDE
	_crossfade(anim)


## Root speed of Sweep at this worker's scale.
func sweep_speed() -> float:
	return SWEEP_SPEED * scale.x


func stop_motor() -> void:
	_mode = Mode.STILL
	motor = Motor.DONE
	_crossfade(_base_anim)  # still moving: it coasts to a stop (staff_step)


# --- props ----------------------------------------------------------------------------

## Takes `prop` into a hand (&"R" / &"L"): it moves from where it is to the
## hand over PROP_MOVE_TIME (the hand is at it: the duty walked there).
func take(prop: PropItem, hand: StringName) -> void:
	var ba: Node3D = _attach.get(hand) as Node3D
	if ba == null or prop == null:
		return
	if prop.holder != null and prop.holder != self and prop.holder.has_method(&"drop_reference"):
		prop.holder.call(&"drop_reference", prop)
	_detach_ref(prop)
	hands[hand] = prop
	prop.holder = self
	prop.where = PropItem.Where.HELD
	if planner != null:
		planner.call(&"prop_lifted", prop)
	_move_prop(prop, ba, hand_xform(prop, hand))


## Belt kit: scanner on the right hip, clipboard on the left, phone at the back.
func add_kit(prop: PropItem) -> void:
	kit[prop.kind] = prop
	prop.holder = self
	prop.where = PropItem.Where.HELD
	var hips: Node3D = _attach.get(&"Hips") as Node3D
	if hips == null:
		add_child(prop)
		return
	hips.add_child(prop)
	prop.transform = belt_xform(prop.kind)


## Moves a held prop back onto the belt (kit) from the hand.
func stow(prop: PropItem) -> void:
	_detach_ref(prop)
	prop.holder = self
	_move_prop(prop, _attach[&"Hips"], belt_xform(prop.kind))


## Puts a held prop down at `xf` (global) under `parent`.
func put(prop: PropItem, parent: Node3D, xf: Transform3D, where: PropItem.Where) -> void:
	_detach_ref(prop)
	prop.holder = null
	prop.where = where
	var local: Transform3D = parent.global_transform.affine_inverse() * xf
	_move_prop(prop, parent, local)


## Rolls `prop` (a mop bucket) along beside the worker.
func tow(prop: PropItem) -> void:
	_detach_ref(prop)
	towed.append(prop)
	prop.holder = self
	prop.where = PropItem.Where.HELD
	if planner != null:
		planner.call(&"prop_lifted", prop)
	var inv: float = 1.0 / scale.x
	_move_prop(prop, self, Transform3D(Basis().scaled(Vector3.ONE * inv), Vector3(0.42, 0.0, 0.05) * inv))


func drop_reference(prop: PropItem) -> void:
	_detach_ref(prop)


func _detach_ref(prop: PropItem) -> void:
	for h: StringName in hands:
		if hands[h] == prop:
			hands[h] = null
	towed.erase(prop)


func held_props() -> Array[PropItem]:
	var out: Array[PropItem] = []
	for h: StringName in hands:
		if hands[h] != null:
			out.append(hands[h])
	out.append_array(towed)
	return out


func props_moving() -> bool:
	return not _prop_moves.is_empty()


## Prop transform on a hand bone. Floor props hang from the hand by their
## handle; their size stays real (undo the worker scale).
func hand_xform(prop: PropItem, hand: StringName) -> Transform3D:
	var base: Transform3D = HAND_R if hand == &"R" else HAND_L
	if not prop.floor_prop:
		return base
	var inv: float = 1.0 / scale.x
	var top: float = 0.27 if prop.kind == &"toolbox" else 0.6
	# hanging: prop up = hand -Y (the hand bone points down the arm)
	var b: Basis = Basis(Vector3.FORWARD, PI).scaled(Vector3.ONE * inv)
	return Transform3D(b, base.origin + Vector3(0.0, (top + 0.02) * inv, 0.0))


func belt_xform(kind: StringName) -> Transform3D:
	# model space wanted, then into the Hips bone's rest frame
	var want: Transform3D = Transform3D.IDENTITY
	match kind:
		&"scanner":
			want = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.235, 0.9, 0.03))
		&"clipboard":
			want = Transform3D(Basis.IDENTITY, Vector3(-0.29, 0.98, 0.0))
		&"phone":
			want = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.1, 0.93, 0.125))
	if _skeleton == null:
		return want
	var bone: int = _skeleton.find_bone("Hips")
	var rest: Transform3D = _skeleton.get_bone_global_rest(bone)
	return rest.affine_inverse() * want


func _move_prop(prop: PropItem, parent: Node3D, local: Transform3D) -> void:
	var g: Transform3D = prop.global_transform if prop.is_inside_tree() else Transform3D.IDENTITY
	if prop.get_parent() != parent:
		if prop.get_parent() != null:
			prop.get_parent().remove_child(prop)
		parent.add_child(prop)
	prop.global_transform = g
	for m: Dictionary in _prop_moves:
		if m.prop == prop:
			_prop_moves.erase(m)
			break
	_prop_moves.append({"prop": prop, "from": prop.transform, "to": local, "t": 0.0})


func _tick_props(dt: float) -> void:
	for i: int in range(_prop_moves.size() - 1, -1, -1):
		var m: Dictionary = _prop_moves[i]
		var p: PropItem = m.prop
		if not is_instance_valid(p):
			_prop_moves.remove_at(i)
			continue
		m.t = minf(1.0, float(m.t) + dt / DutyConfig.PROP_MOVE_TIME)
		var k: float = smoothstep(0.0, 1.0, float(m.t))
		p.transform = (m.from as Transform3D).interpolate_with(m.to as Transform3D, k)
		if float(m.t) >= 1.0:
			_prop_moves.remove_at(i)
			if p.holder == null and planner != null:
				planner.call(&"prop_placed", p)


# --- staff motor ------------------------------------------------------------------------

func _service_close(v: Node) -> bool:
	return FootprintBox.set_distance(traffic_footprints(), v.call(&"traffic_footprints")) < Traffic.HARD_VP + 0.1


## One simulation step (game seconds) in staff mode; the planner calls it.
func staff_step(dt: float) -> void:
	_tick_props(dt)
	if _service_clearing and (not is_instance_valid(service_vehicle) or not _service_close(service_vehicle)):
		_service_clearing = false
		service_vehicle = null
	if _on_job:
		_pace = 0.0
		return
	var before: Vector2 = pos2()
	var odo0: float = odometer
	var stops0: int = safety_stops
	_staff_motion(dt)
	_keep_pace(before, odo0, stops0, dt)
	_vehicle_guard(before, odo0)


## Last line of defence, whatever moved the worker this step: a step that
## ends inside a forklift's hard keep-out and closer than before is undone
## (a safety stop). The serviced forklift is the one exception.
func _vehicle_guard(before: Vector2, odo0: float) -> void:
	var after: Vector2 = pos2()
	if after.distance_to(before) < 0.00001 or not _near_vehicle(before, after):
		return
	if OS.get_environment("WORKER_DEBUG") == "1":
		print("WorkerActor: %s step towards a forklift undone (mode %d, duty %s)" % [name, _mode, duty.get(&"title") if duty != null else "-"])
	global_position = Vector3(before.x, global_position.y, before.y)
	odometer = odo0
	_note_stop("vehicle guard", speed)
	speed = 0.0
	_pace = 0.0


## Pace (distance per step) never changes faster than accel, whatever the
## motion code did in this step (an edge that ate part of the step, a mark
## reached mid-step, a route swapped): a step that fell short is made up
## along the way it went, a jump is cut back. Safety stops (noted) are the
## one exception.
func _keep_pace(before: Vector2, odo0: float, stops0: int, dt: float) -> void:
	if dt < 0.0001:
		return  # a float-remainder sliver of a step: keeps the pace
	var moved: float = odometer - odo0
	if safety_stops != stops0:
		_pace = moved / dt
		return
	var lo: float = maxf(_pace - accel * dt, 0.0) * dt
	var hi: float = (_pace + accel * dt) * dt
	var after: Vector2 = pos2()
	if moved > hi + 0.000001 and after.distance_to(before) > 0.000001:
		var p: Vector2 = before.move_toward(after, hi)
		global_position = Vector3(p.x, global_position.y, p.y)
		odometer = odo0 + p.distance_to(before)
	elif moved < lo - 0.000001:
		var dir: Vector2 = (after - before).normalized() if after.distance_to(before) > 0.0001 else (_coast_dir if _coast_dir != Vector2.ZERO else forward2())
		var q: Vector2 = after + dir * (lo - moved)
		if nav != null and nav.value_at(q) < PeopleNav.HARD and nav.push_out(q).distance_to(q) < 0.0001 \
				and not _too_close(after, q) and not _near_vehicle(after, q):
			global_position = Vector3(q.x, global_position.y, q.y)
			odometer += q.distance_to(after)
			speed = maxf(speed, (lo / dt))
		else:
			# cannot go on (someone or something right there): a safety stop
			_note_stop("pace", lo / dt)
			speed = minf(speed, moved / dt)
	_pace = (odometer - odo0) / dt


func _staff_motion(dt: float) -> void:
	if _once_left > 0.0:
		_once_left -= dt
		if _once_left <= 0.0 and _mode == Mode.STILL:
			_crossfade(_base_anim)
			current_action = _base_anim
	match _mode:
		Mode.WALK:
			_coast_dir = Vector2.ZERO
			_walk_step(dt)
			_stall_check(dt)
		Mode.TURN:
			_coast(dt)
			_turn_step(dt)
		Mode.SLIDE:
			_slide_step(dt)
		_:
			_coast(dt)
			if motor == Motor.RUNNING and not _yielding:
				motor = Motor.DONE  # a step aside that ended (or never began): the move is over
	_update_anim_speed()


## Stopped while still walking (a duty ended or switched): slow down at
## accel along the way it was going instead of stopping dead. Stops at once
## only when the next step would take it into a wall or someone's keep-out.
func _coast(dt: float) -> void:
	if speed <= 0.0:
		speed = 0.0
		_coast_dir = Vector2.ZERO
		return
	if _coast_dir == Vector2.ZERO:
		_coast_dir = forward2()
	speed = maxf(speed - accel * dt, 0.0)
	var here: Vector2 = pos2()
	var step: float = speed * dt
	var nxt: Vector2 = here + _coast_dir * step
	if nav != null:
		# walls and furniture: slide along their edge (the body stays off them)
		var q: Vector2 = nav.push_out(nxt)
		if q.distance_to(here) > step * 0.6 and nav.value_at(q) < PeopleNav.HARD:
			nxt = q
	if (nav != null and nav.value_at(nxt) >= PeopleNav.HARD and nav.value_at(nxt) > nav.value_at(here)) or _too_close(here, nxt) or _near_vehicle(here, nxt):
		var side: Vector2 = _side_step(here, _coast_dir, step) if nav != null else here
		if side == here:
			_note_stop("coast %s" % ("mover" if _too_close(here, nxt) or _near_vehicle(here, nxt) else "wall"), speed)
			speed = 0.0
			return
		nxt = side
	odometer += nxt.distance_to(here)
	global_position = Vector3(nxt.x, global_position.y, nxt.y)


func _update_anim_speed() -> void:
	if _anim == null:
		return
	var gs: float = float(GameState.speed) if not GameState.paused else 0.0
	var k: float = 1.0
	if _anim.current_animation == String(_walk_anim) or StringName(_anim.current_animation) in GAITS:
		if _mode == Mode.TURN:
			k = 0.45  # stepping round on the spot
		else:
			k = clampf(speed / (anim_speed * scale.x), 0.0, 2.0)
	_anim.speed_scale = k * gs


func _crossfade(anim: StringName) -> void:
	if _anim == null or anim == &"" or not _anim.has_animation(anim):
		return
	if StringName(_anim.current_animation) == anim:
		return
	_anim.play(anim, DutyConfig.BLEND)


func _plan_path(round_walkers: bool = false, extra: Array = []) -> bool:
	var avoid: Array = extra.duplicate()
	if traffic != null:
		for m: Node in traffic.movers:
			if m == self or not m.call(&"traffic_active"):
				continue
			if int(m.call(&"traffic_kind")) == Traffic.Kind.VEHICLE:
				if m == service_vehicle:
					# walk up to it, but round it, never through its forks
					avoid.append([m.call(&"traffic_footprints"), 0.1])
					continue
				if not bool(m.call(&"traffic_moving")):
					avoid.append([m.call(&"traffic_footprints"), PARKED_GAP + 0.15])
			elif (round_walkers or m.get(&"_mode") != Mode.WALK or bool(m.get(&"_giving_way"))) and (group == null or m.get(&"group") != group):
				# people standing (working, talking), or anyone close when stuck: walk round them
				var theirs: Array = m.call(&"traffic_footprints")
				var dist: float = (theirs[0] as FootprintBox).c.distance_to(pos2()) if not theirs.is_empty() else INF
				if dist < (5.0 if round_walkers else 12.0) and _goal.distance_to((theirs[0] as FootprintBox).c) > 1.0:
					avoid.append([theirs, 0.6])
	var t0: int = Time.get_ticks_usec()
	var path: PackedVector2Array = nav.find_path(pos2(), _goal, avoid)
	if path.is_empty() and (round_walkers or not extra.is_empty()):
		return false
	if path.is_empty() and not avoid.is_empty():
		path = nav.find_path(pos2(), _goal)
	if planner != null:
		var perf: Dictionary = planner.get(&"perf")
		perf["astar"] = int(perf.get("astar", 0)) + Time.get_ticks_usec() - t0
		perf["astar_n"] = int(perf.get("astar_n", 0)) + 1
	if path.is_empty():
		return false
	_path = path
	_path_i = 1
	return true


func _walk_step(dt: float) -> void:
	var here: Vector2 = pos2()
	if _path_i >= _path.size():
		_arrive()
		return
	# advance past reached waypoints
	while _path_i < _path.size() - 1 and here.distance_to(_path[_path_i]) < 0.35:
		_path_i += 1
	var final: Vector2 = _path[_path.size() - 1]
	var remaining: float = here.distance_to(_path[_path_i])
	for i: int in range(_path_i, _path.size() - 1):
		remaining += _path[i].distance_to(_path[i + 1])
	# brake on the straight distance to the end: it shrinks smoothly (the
	# route sum jumps when a corner waypoint is passed)
	remaining = minf(remaining, here.distance_to(final))
	if remaining < 0.006 and speed <= accel * dt:
		# creeping onto the mark: the last millimetres count as walked
		odometer += here.distance_to(final)
		global_position = Vector3(final.x, global_position.y, final.y)
		_arrive()
		return
	# pure pursuit on a point a little ahead along the route, bent round people
	var target: Vector2 = _lookahead(here, 0.5)
	var desired: Vector2 = (target - here).normalized() if target.distance_to(here) > 0.001 else forward2()
	_check_in -= 1
	if _check_in <= 0 or _check_in == 2:
		# people every 2 steps (they close in from both sides), forklifts every 4
		var t0: int = Time.get_ticks_usec()
		if _check_in <= 0:
			_check_in = 4
			_blocked = _find_blocker()
		_steer = _people_steer(here, desired, remaining)
		var perf: Dictionary = planner.get(&"perf")
		perf["block"] = int(perf.get("block", 0)) + Time.get_ticks_usec() - t0
	var dir: Vector2 = desired
	if _steer.length() > 0.001:
		var bent: Vector2 = (desired + _steer).normalized()
		if nav.walkable(here + bent * 0.45):
			dir = bent
	var squeezed: bool = false
	if not _near_people.is_empty() and not _dir_ok(here, dir):
		# someone in the way: slide round them (the smallest turn that keeps clear)
		var found: bool = false
		for a: float in [0.35, -0.35, 0.7, -0.7, 1.05, -1.05, 1.45, -1.45, 1.9, -1.9]:
			var c: Vector2 = dir.rotated(a)
			if _dir_ok(here, c):
				dir = c
				found = true
				break
		squeezed = true
		if not found:
			_people_cap = 0.0
	var slid: float = _vehicle_slide(here, dir)
	if absf(slid) > 0.0001:
		dir = dir.rotated(slid)
		if absf(slid) > 1.0:
			# the route runs into a parked forklift (it parked after the
			# plan): a new one round it before long
			_slide_t += dt
			if _slide_t > 0.8:
				_slide_t = 0.0
				_plan_path()
		else:
			_slide_t = 0.0
	else:
		_slide_t = 0.0
	var want: float = atan2(-dir.x, -dir.y)
	var diff: float = angle_difference(yaw(), want)
	var rate: float = DutyConfig.TURN_RATE * (0.6 + 0.4 * clampf(speed / walk_speed, 0.0, 1.0))
	rotation.y += clampf(diff, -rate * dt, rate * dt)
	var cap: float = walk_speed * clampf(1.0 - absf(diff) / 1.3, 0.0, 1.0)
	cap = minf(cap, sqrt(2.0 * accel * PLAN_DECEL * remaining) + 0.01)  # brake onto the mark
	cap = minf(cap, _people_cap)
	# furniture or a wall straight ahead: slow down in time (push_out would
	# otherwise stop the body dead against it)
	var ahead: Vector2 = forward2()
	var probe: float = 0.15
	var brake_d: float = speed * speed / (2.0 * accel) + 0.2
	while probe <= brake_d:
		var q: Vector2 = here + ahead * probe
		if nav.push_out(q).distance_to(q) > 0.005:
			cap = minf(cap, sqrt(2.0 * accel * PLAN_DECEL * maxf(probe - 0.15, 0.0)) + 0.05)
			break
		probe += 0.1
	if squeezed:
		cap = minf(cap, walk_speed * 0.55)
	if _giving_way:
		# letting someone pass: stand until they are by
		cap = 0.0
		_give_t += dt
		var other: Node3D = _give_to as Node3D
		var gone: bool = other == null or not is_instance_valid(other) or pos2().distance_to(Vector2(other.global_position.x, other.global_position.z)) > 1.8
		if gone or _give_t > 2.5:
			_giving_way = false
			if not gone:
				_start_yield(_give_to)
			_give_to = null
	elif _blocked != null:
		cap = 0.0
		_block_t += dt
		_total_block_t += dt
		_handle_block()
		if _mode != Mode.WALK or _path_i >= _path.size():
			return
	elif _people_cap < 0.05 and (squeezed or _people_by != null):
		_block_t += dt
		_total_block_t += dt
		_handle_people_block()
		if _mode != Mode.WALK or _path_i >= _path.size():
			return
	else:
		_block_t = 0.0
		_people_replans = 0
	if cap > speed:
		speed = minf(cap, speed + accel * dt)
	else:
		speed = maxf(cap, speed - accel * dt)
	var heading: Vector2 = forward2()
	# arriving: still fast (braked late) it walks on past the mark and
	# coasts off the rest at accel; slow, it steps onto the mark
	var arriving: bool = speed * dt >= remaining
	var step: float = speed * dt if arriving and speed > accel * dt else minf(speed * dt, remaining)
	var nxt: Vector2 = here + heading * step
	if step > 0.0 and (_too_close(here, nxt) or _near_vehicle(here, nxt)):
		# someone right there: keep the pace sideways round them when a
		# step that way is clear; stop dead only when none is
		var side: Vector2 = _side_step(here, heading, step)
		if side == here:
			_note_stop("walk too close" if _too_close(here, nxt) else "walk near forklift", speed)
			speed = 0.0
			return
		nxt = side
		arriving = false
	# keep the body off walls, racks and furniture: slide along their edges,
	# at the same pace (the step turned along the edge)
	var pushed: Vector2 = nav.push_out(nxt)
	if pushed.distance_to(nxt) > 0.0001 and step > 0.0005:
		var along: Vector2 = pushed - here
		if along.length() > 0.0001:
			var q: Vector2 = nav.push_out(here + along.normalized() * step)
			if q.distance_to(here) >= step * 0.95 and not _too_close(here, q) and not _near_vehicle(here, q):
				pushed = q
	nxt = pushed
	odometer += nxt.distance_to(here)
	if step > 0.0005 and nxt.distance_to(here) < step * 0.2:
		_note_stop("edge", speed)
		speed = maxf(minf(speed, 0.3), speed - accel * dt)  # slowing along the edge, at accel
		_edge_t += dt
		_total_block_t += dt
		if _total_block_t > 25.0:
			_fail()
			return
		if _edge_t > 1.0:
			_edge_t = 0.0
			if not _plan_path():
				_fail()
				return
	else:
		_edge_t = 0.0
	global_position = Vector3(nxt.x, global_position.y, nxt.y)
	if arriving:
		_arrive()


## Walking along a parked forklift: the smallest turn of `dir` (radians,
## 0 when none is needed) that keeps the next steps from closing in on it
## inside PARKED_GAP, so the worker curves along its side at pace instead
## of braking for it (the route round it is planned at PARKED_GAP + a bit;
## cutting a corner of it would otherwise stop the worker dead).
func _vehicle_slide(here: Vector2, dir: Vector2) -> float:
	if traffic == null:
		return 0.0
	var boxes: Array = []
	for m: Node in traffic.movers:
		if m is WorkerActor or m == service_vehicle or not m.call(&"traffic_active") or bool(m.call(&"traffic_moving")):
			continue
		var theirs: Array = m.call(&"traffic_footprints")
		if theirs.is_empty() or (theirs[0] as FootprintBox).c.distance_to(here) > 9.0:
			continue
		var now: float = FootprintBox.set_distance(traffic_footprints_at(here, yaw()), theirs)
		if now < PARKED_GAP + 0.6:
			boxes.append([theirs, now])
	if boxes.is_empty():
		return 0.0
	for a: float in [0.0, 0.2, -0.2, 0.4, -0.4, 0.65, -0.65, 0.9, -0.9, 1.2, -1.2, 1.57, -1.57]:
		var q: Vector2 = here + dir.rotated(a) * 0.6
		var ok: bool = true
		for b: Array in boxes:
			var d: float = FootprintBox.set_distance(traffic_footprints_at(q, yaw()), b[0])
			if d < PARKED_GAP and d < float(b[1]) - 0.01:
				ok = false
				break
		if ok:
			return a
	return 0.0


## The same-length step turned off `heading` (smallest turn first) that
## keeps clear of people and forklifts and off obstacles; `here` when none.
func _side_step(here: Vector2, heading: Vector2, step: float) -> Vector2:
	for a: float in [0.6, -0.6, 1.1, -1.1, 1.57, -1.57]:
		var q: Vector2 = here + heading.rotated(a) * step
		if nav.value_at(q) >= PeopleNav.HARD or nav.push_out(q).distance_to(q) > 0.0005:
			continue
		if _too_close(here, q) or _near_vehicle(here, q):
			continue
		return q
	return here


## Comfortable distance to another person (centre to centre): people slow
## down and bend round inside it.
func _person_gap(m: Node) -> float:
	if group != null and m.get(&"group") == group:
		return DutyConfig.GROUP_GAP
	return DutyConfig.PERSON_PERSON_GAP


## Never closer than this (centre to centre).
func _person_min(m: Node) -> float:
	if group != null and m.get(&"group") == group:
		return DutyConfig.GROUP_GAP
	return DutyConfig.PERSON_MIN


## A short step along `dir` stays walkable and comes no closer to anyone
## already near than their keep-out.
func _dir_ok(here: Vector2, dir: Vector2) -> bool:
	var nxt: Vector2 = here + dir * 0.3
	var probe: Vector2 = here + dir * minf(0.45, here.distance_to(_goal))
	var v: int = nav.value_at(probe)
	if v == PeopleNav.HARD or (v == PeopleNav.SOFT and nav.value_at(here) <= PeopleNav.AREA and probe.distance_to(_goal) > 0.8):
		return false
	for w: Node in _near_people:
		var o: Vector2 = (w as WorkerActor).pos2()
		var d0: float = here.distance_to(o)
		var d1: float = nxt.distance_to(o)
		var soft: float = _person_min(w)
		if d1 < soft and d1 < d0 - 0.005:
			return false
	return true


## Would stepping to `nxt` bring the worker closer to a forklift that is
## already within the keep-out (the serviced one: right up to it only)?
func _near_vehicle(here: Vector2, nxt: Vector2) -> bool:
	if traffic == null:
		return false
	for m: Node in traffic.movers:
		if m is WorkerActor or not m.call(&"traffic_active"):
			continue
		var theirs: Array = m.call(&"traffic_footprints")
		var gap: float = 0.15 if m == service_vehicle else Traffic.HARD_VP + 0.05
		var d1: float = FootprintBox.set_distance(traffic_footprints_at(nxt, yaw()), theirs)
		if d1 < gap and d1 < FootprintBox.set_distance(traffic_footprints_at(here, yaw()), theirs):
			return true
	return false


## Would stepping to `nxt` bring the worker inside someone's keep-out?
func _too_close(here: Vector2, nxt: Vector2) -> bool:
	for w: Node in _near_people:
		var o: Vector2 = (w as WorkerActor).pos2()
		var gap: float = _person_min(w)
		var d1: float = nxt.distance_to(o)
		if d1 < gap and d1 < here.distance_to(o):
			return true
	return false


## Side-step people ahead (pass on the right when head-on) and slow down
## for anyone right in the way. Sets _people_cap; returns the steering push.
func _people_steer(here: Vector2, desired: Vector2, remaining: float) -> Vector2:
	_near_people.clear()
	_people_cap = INF
	_people_by = null
	var push: Vector2 = Vector2.ZERO
	var right: Vector2 = Vector2(-desired.y, desired.x)  # right of the walking direction (floor x, z)
	for m: Node in traffic.movers:
		if m == self or not (m is WorkerActor) or not m.call(&"traffic_active"):
			continue
		var o: Vector2 = (m as WorkerActor).pos2()
		var r: Vector2 = o - here
		var dist: float = r.length()
		if dist > 3.0:
			continue
		_near_people.append(m)
		# closing in on them from any side: no faster than lets the worker
		# stop (at accel) outside their keep-out
		var their_v: Vector2 = (m as WorkerActor).forward2() * float((m as WorkerActor).speed)
		var rn: Vector2 = r / maxf(dist, 0.001)
		var closing: float = rn.dot(desired * maxf(speed, 0.3) - their_v)
		var toward: float = rn.dot(desired)
		# two people walking across each other's way: the lower staff id
		# keeps its pace, the other slows for it (both braking for each
		# other is how they used to end up stood face to face)
		var wa: WorkerActor = m as WorkerActor
		var mine: bool = staff_id < wa.staff_id and wa._mode == Mode.WALK and wa.speed > 0.2 and not wa._giving_way \
				and dist > _person_min(m) + 0.15 and (group == null or wa.group != group)
		if closing > 0.05 and toward > 0.05 and not mine:
			# they may keep coming while I brake: their approach eats room too.
			# Only the part of my pace that heads at them counts: walking
			# past someone (mostly sideways to them) keeps its pace, the
			# way people brush past each other in an aisle
			var u: float = maxf(0.0, -rn.dot(their_v))
			var a2: float = accel * PLAN_DECEL
			var room: float = maxf(dist - _person_min(m) - 0.1, 0.0)
			var stop_c: float = maxf(sqrt(u * u + 2.0 * a2 * room) - u, 0.0) / toward
			if stop_c < _people_cap:
				_people_cap = stop_c
				_people_by = m
		var ahead: float = r.dot(desired)
		if ahead <= 0.0 or ahead > remaining + 0.6:
			continue
		var lat: float = r.dot(right)
		var gap: float = _person_gap(m)
		if absf(lat) < gap + 0.2 and ahead < 4.0:
			# pass on the side away from them (right when straight ahead),
			# starting early so it is a slight curve, not a late swerve
			var side: float = -signf(lat) if absf(lat) > 0.08 else 1.0
			var k: float = (1.0 - absf(lat) / (gap + 0.2)) * (1.0 - ahead / 4.0)
			push += right * side * k * 2.2
		if absf(lat) < _person_min(m):
			# on course to bump into them: slow down (bending past at the
			# comfortable gap keeps the pace)
			var hard: float = _person_min(m)
			# no faster than lets the worker stop (at accel) short of them
			var c: float = minf(walk_speed, sqrt(2.0 * accel * PLAN_DECEL * maxf(dist - hard - 0.05, 0.0)))
			if dist > hard + 0.12:
				c = maxf(c, 0.25)
			if c < _people_cap:
				_people_cap = c
				_people_by = m
	return push


## Stopped by a person: queue when they stand on my goal (or have them
## shift over when they only wait there), else plan a way round everyone
## near; when there is none, the higher staff id steps aside.
func _handle_people_block() -> void:
	var b: WorkerActor = _people_by as WorkerActor
	if b == null or not is_instance_valid(b):
		return
	if _total_block_t > 25.0:
		_fail()
		return
	if _block_t < 0.6:
		return
	var walking: bool = b._mode == Mode.WALK and not b._yielding
	if _goal.distance_to(b.pos2()) < 1.0 and not walking:
		if _block_t > 2.0 and b.can_shift():
			_block_t = 0.0
			b.shift_for(self)
		return  # they stand where I am going: wait my turn
	if not walking and b.can_shift() and _block_t > 1.0:
		_block_t = 0.0
		b.shift_for(self)
		return
	if _block_t > (0.8 if not walking else 1.2):
		_block_t = 0.0
		_people_replans += 1
		# a way round them; failing that (or still stuck after one), the
		# higher id steps aside
		var found: bool = _people_replans <= 1 and _plan_path(true)
		if not found and staff_id > b.staff_id and not _yielding:
			_start_yield(b)
			if not _yielding:
				_retreat_from(b)
		elif not found and _people_replans > 3 and not _yielding:
			_start_yield(b)
			if not _yielding:
				_retreat_from(b)


## Face to face in a tight spot and no room to step aside by the usual
## rules: walk back a little (the most open walkable point 1 to 2.5 m away,
## away from them), wait there for them to pass, then go on.
func _retreat_from(b: WorkerActor) -> void:
	var here: Vector2 = pos2()
	var away: Vector2 = (here - b.pos2()).normalized() if here.distance_to(b.pos2()) > 0.01 else -forward2()
	var best: Vector2 = here
	var best_s: float = -INF
	for r: float in [1.0, 1.6, 2.5]:
		for k: int in 12:
			var dir: Vector2 = away.rotated((k - 6) * TAU / 12.0)
			var p: Vector2 = here + dir * r
			if not nav.walkable(p) or _by_parked_forklift(p) or nav.find_path(here, p).is_empty():
				continue
			var s: float = p.distance_to(b.pos2()) + dir.dot(away) * 0.5
			for w: Node in _near_people:
				if w != b:
					s = minf(s, (w as WorkerActor).pos2().distance_to(p) + 0.5)
			if s > best_s:
				best_s = s
				best = p
	if best == here:
		return
	_yield_from = b
	_yielding = true
	_yield_wait = 0.0
	_block_t = 0.0
	_total_block_t = 0.0
	if motor == Motor.RUNNING and _mode == Mode.WALK and _saved_goal == null:
		_saved_goal = [_goal, _goal_yaw]
	_goal = best
	_goal_yaw = NAN
	if not _plan_path():
		_yielding = false
		if _saved_goal != null:
			_goal = (_saved_goal as Array)[0]
			_goal_yaw = (_saved_goal as Array)[1]
			_saved_goal = null
		return
	_mode = Mode.WALK
	motor = Motor.RUNNING
	_crossfade(_walk_anim)
	displaced = true

## Standing at `p` would be inside a parked forklift's keep-out (a spot to
## step back to there only gets the worker stuck against it).
func _by_parked_forklift(p: Vector2) -> bool:
	if traffic == null:
		return false
	for m: Node in traffic.movers:
		if m is WorkerActor or m == service_vehicle or not m.call(&"traffic_active"):
			continue
		if int(m.call(&"traffic_kind")) != Traffic.Kind.VEHICLE:
			continue
		if FootprintBox.set_distance(traffic_footprints_at(p, 0.0), m.call(&"traffic_footprints")) < PARKED_GAP + 0.2:
			return true
	return false


## Only waiting about (not at work on a spot): may move aside for someone.
func can_shift() -> bool:
	if _on_job or seat != null or group != null:
		return false
	if _yielding or _giving_way or duty == null:
		return _mode != Mode.WALK or _giving_way
	var cur: Variant = duty.get(&"_cur")
	if _mode == Mode.STILL and cur != null and (cur as Object).has_meta(&"queued"):
		return true  # waiting for a one-at-a-time spot: may stand aside for whoever uses it
	return _mode == Mode.STILL and cur != null and (cur.get(&"spot") as Array).is_empty() and not bool(cur.get(&"walk"))


func shift_for(other: Node) -> void:
	_giving_way = false
	_yielding = false
	_start_yield(other)


func _lookahead(here: Vector2, dist: float) -> Vector2:
	var p: Vector2 = here
	var left: float = dist
	for i: int in range(_path_i, _path.size()):
		var seg: float = p.distance_to(_path[i])
		if seg >= left:
			return p.move_toward(_path[i], left)
		left -= seg
		p = _path[i]
	return _path[_path.size() - 1]


func _arrive() -> void:
	# any speed left is braked off at accel (staff_step coasts)
	if _yielding:
		_mode = Mode.STILL
		_crossfade(_base_anim)
		return  # waits in yield_tick
	if not is_nan(_goal_yaw):
		turn_to(_goal_yaw)
		if motor == Motor.DONE:
			_mode = Mode.STILL
			_crossfade(_base_anim)
		return
	_mode = Mode.STILL
	motor = Motor.DONE
	_crossfade(_base_anim)


func _fail() -> void:
	if OS.get_environment("DUTY_DEBUG") == "1":
		print("%s: walk failed at %s to %s (blocked %.0f s by %s / %s) path %s i=%d" % [display_name, pos2(), _goal, _total_block_t, _blocked.name if _blocked != null else "-", _people_by.name if _people_by != null else "-", _path, _path_i])
	_mode = Mode.STILL
	motor = Motor.FAILED
	_yielding = false
	_crossfade(_base_anim)


func _turn_step(dt: float) -> void:
	var diff: float = angle_difference(yaw(), _turn_to)
	if absf(diff) < 0.02:
		rotation.y = _turn_to
		_mode = Mode.STILL
		motor = Motor.DONE
		_crossfade(_base_anim)
		return
	# step round on the spot: a slow walk cycle while turning further than a little
	if absf(diff) > 0.5:
		_crossfade(_walk_anim)
	rotation.y += clampf(diff, -DutyConfig.TURN_IN_PLACE_RATE * dt, DutyConfig.TURN_IN_PLACE_RATE * dt)


func _slide_step(dt: float) -> void:
	var here: Vector2 = pos2()
	var d: float = here.distance_to(_slide_to)
	# speed up and slow down at accel like walking
	var cap: float = minf(_slide_speed, sqrt(2.0 * accel * d))
	if cap > speed:
		speed = minf(cap, speed + accel * dt)
	else:
		speed = maxf(cap, speed - accel * dt)
	if d <= maxf(speed * dt, 0.002):
		odometer += d
		global_position = Vector3(_slide_to.x, global_position.y, _slide_to.y)
		speed = 0.0
		_mode = Mode.STILL
		motor = Motor.DONE
		_crossfade(_base_anim)
		return
	var nxt: Vector2 = here.move_toward(_slide_to, maxf(speed, 0.02) * dt)
	# never into anyone's keep-out (sweeping along, sliding onto a seat)
	if traffic != null:
		for m: Node in traffic.movers:
			if m == self or not (m is WorkerActor) or not m.call(&"traffic_active"):
				continue
			var o: Vector2 = (m as WorkerActor).pos2()
			var d1: float = nxt.distance_to(o)
			if d1 < _person_min(m) and d1 < here.distance_to(o):
				speed = maxf(speed - accel * dt, 0.0)
				return
		if _near_vehicle(here, nxt):
			speed = maxf(speed - accel * dt, 0.0)
			return
	odometer += nxt.distance_to(here)
	global_position = Vector3(nxt.x, global_position.y, nxt.y)


# --- staff traffic --------------------------------------------------------------------

## Walking but standing still (blocked, squeezed, a side step refused on
## every side): after STALL_TIME the worker decides instead of waiting on
## the others, who are often waiting on it. Letting someone pass
## (_giving_way) is a decision already and has its own time-out.
func _stall_check(dt: float) -> void:
	if _mode != Mode.WALK or _giving_way or speed > 0.05:
		_stall_t = 0.0
		if speed > 0.3:
			_stalls = 0
		return
	_stall_t += dt
	if _stall_t > STALL_TIME:
		_stall_t = 0.0
		_unstall()


## The tie-break when people stand facing each other (or round a forklift)
## and nobody moves: the person in the way with the lower staff id walks
## on, the higher id makes way. Ways out, one per stall: a route round
## everyone near and the forklifts' keep-outs (as obstacles, so the group
## goes round on either side), then stepping back out of the other one's
## way (or out of the forklift's), waiting there and going on.
func _unstall() -> void:
	if planner == null or _on_job:
		return
	_stalls += 1
	var here: Vector2 = pos2()
	var person: WorkerActor = null
	var best: float = INF
	for w: Node in _near_people:
		var o: WorkerActor = w as WorkerActor
		var d: float = here.distance_to(o.pos2())
		if d < best and d < _person_gap(o) + 0.8:
			best = d
			person = o
	var extra: Array = []
	var vehicle: Node = null
	var v_best: float = INF
	if traffic != null:
		for m: Node in traffic.movers:
			if m is WorkerActor or not m.call(&"traffic_active") or m == service_vehicle:
				continue
			var theirs: Array = m.call(&"traffic_footprints")
			var dv: float = FootprintBox.set_distance(traffic_footprints(), theirs)
			if dv > 6.0:
				continue
			extra.append([theirs, Traffic.SAFE_VP + 0.2])
			if m.has_method(&"future_footprints") and bool(m.call(&"traffic_moving")):
				for fp: Array in m.call(&"future_footprints", WALK_ROUND_AHEAD):
					extra.append([fp, Traffic.HARD_VP])
			if dv < v_best:
				v_best = dv
				vehicle = m
	# the one with the right of way: walks on as soon as the other one moves
	var my_way: bool = person != null and staff_id < person.staff_id and person._mode == Mode.WALK and not person._giving_way
	if my_way and _stalls <= 2:
		if not _plan_path(true, extra):
			_plan_path(true)
		return
	if _stalls == 1 and (_plan_path(true, extra) or (extra.is_empty() and _plan_path(true))):
		_block_t = 0.0
		return
	if _yielding:
		if _stalls >= 2 and _saved_goal != null and not _is_machine(_yield_from):
			# the step back out of a person's way is itself stuck: give it
			# up and walk on to where it was going
			var g: Array = _saved_goal
			_saved_goal = null
			_yielding = false
			_yield_from = null
			_goal = g[0]
			_goal_yaw = g[1]
			if not _plan_path(true, extra):
				_plan_path()
			_stalls = 0
		return  # already on the way out of someone's way: the path above failed, wait for the next stall
	if person != null and (vehicle == null or best < v_best + 0.5):
		_retreat_from(person)
		if not _yielding:
			_start_yield(person)
	elif vehicle != null:
		_start_yield(vehicle)
	_block_t = 0.0


## Forklift that the next stretch of the route would bring within the
## keep-out distance (and closer than now), or null. A forklift coming
## across where the worker stands makes it step aside.
func _find_blocker() -> Node:
	if traffic == null:
		return null
	var here: Array = traffic_footprints()
	var me: Vector2 = pos2()
	var dir: Vector2 = forward2()
	var look: float = 0.5 + speed * 1.2
	for m: Node in traffic.movers:
		if m == self or m is WorkerActor or not m.call(&"traffic_active"):
			continue
		if int(m.call(&"traffic_kind")) != Traffic.Kind.VEHICLE:
			continue
		var theirs: Array = m.call(&"traffic_footprints")
		if theirs.is_empty() or (theirs[0] as FootprintBox).c.distance_to(me) > look + 8.0:
			continue
		var moving: bool = bool(m.call(&"traffic_moving"))
		# parked: _vehicle_slide curves the worker along it at PARKED_GAP;
		# it only blocks the worker when that fails, at the hard limit
		var gap: float = DutyConfig.PERSON_VEHICLE_GAP if moving else Traffic.HARD_VP + 0.08
		if m == service_vehicle and not moving:
			gap = 0.15  # servicing it: right up to it, never into it
		var coming: Array = []
		var mv: Variant = m.get(&"speed")
		if mv != null and float(mv) > 0.05 and m.has_method(&"future_footprints"):
			coming = m.call(&"future_footprints", minf(3.0, float(mv) * 1.8 + 0.5))
		var now: float = FootprintBox.set_distance(here, theirs)
		var s: float = 0.3
		while s <= look:
			var fp: Array = traffic_footprints_at(me + dir * s, yaw())
			var d: float = FootprintBox.set_distance(fp, theirs)
			for cfp: Array in coming:
				d = minf(d, FootprintBox.set_distance(fp, cfp))
			# no step that closes in on it, and never below the hard limit
			if d < gap and (d < now - 0.02 or (d < minf(Traffic.HARD_VP, gap) and d <= now + 0.005)):
				return m
			s += 0.3
		# a forklift about to cross where the worker stands now
		for cfp: Array in coming:
			var dc: float = FootprintBox.set_distance(here, cfp)
			if dc < gap - 0.2 and dc < now - 0.05:
				if not _walk_round(m):
					_start_yield(m)
				return null
	return null


func _handle_block() -> void:
	var b: Node = _blocked
	if b == null or not is_instance_valid(b):
		return
	if _total_block_t > 25.0:
		_fail()
		return
	if not bool(b.call(&"traffic_moving")) and _block_t > 1.0:
		# parked in the way: plan round it
		_block_t = 0.0
		_plan_path()
	elif _block_t > 1.0:
		# driving: go round it and the stretch it drives next, if there is a way
		_block_t = 0.0
		_walk_round(b)


## On the way somewhere and a forklift or jack is in the way: a new route
## to the same goal round it (its body at the yield distance, the next
## metres it drives a bit closer), so the worker walks on instead of
## turning back. False when there is none, or the worker is not walking.
func _walk_round(v: Node) -> bool:
	if planner == null or _on_job or v == null or not is_instance_valid(v):
		return false
	if _mode != Mode.WALK or motor != Motor.RUNNING or _yielding or _path_i >= _path.size():
		return false
	var extra: Array = [[v.call(&"traffic_footprints"), Traffic.SAFE_VP + 0.2]]
	if v.has_method(&"future_footprints"):
		for fp: Array in v.call(&"future_footprints", WALK_ROUND_AHEAD):
			extra.append([fp, Traffic.HARD_VP])
	var old: PackedVector2Array = _path
	var old_i: int = _path_i
	if not _plan_path(false, extra) or _path_length(_path, 1) > _path_length(old, old_i) * 2.5 + 8.0:
		_path = old
		_path_i = old_i
		return false
	blocked_by = null
	blocked_time = 0.0
	_block_t = 0.0
	return true


## Length of `path` from point i - 1 (where the worker is) to the end.
func _path_length(path: PackedVector2Array, i: int) -> float:
	var total: float = 0.0
	var p: Vector2 = pos2()
	for k: int in range(i, path.size()):
		total += p.distance_to(path[k])
		p = path[k]
	return total


func _start_yield(from: Node) -> void:
	if planner == null or _on_job or (_yielding and _yield_from == from):
		return
	if seat != null:
		return  # seated at the break table: far from any forklift path
	var danger: Array = []
	if from != null and is_instance_valid(from):
		danger.append(from.call(&"traffic_footprints"))
		if from.has_method(&"future_footprints"):
			danger.append_array(from.call(&"future_footprints", 8.0))
	var here: Vector2 = pos2()
	var best: Vector2 = here
	var best_score: float = INF
	# when nothing is fully clear (a narrow aisle): the most open spot within reach
	var fallback: Vector2 = here
	var fallback_clear: float = 0.0
	var is_vehicle: bool = _is_machine(from)
	var need: float = 2.2 if is_vehicle else 1.1
	var on_break: bool = duty != null and bool(duty.get(&"is_break"))
	for r: float in [1.2, 2.0, 3.0, 4.0, 5.5]:
		for k: int in 16:
			var p: Vector2 = here + Vector2.from_angle(k * TAU / 16.0) * r
			if not nav.walkable(p) or not bool(planner.call(&"clear_of_spots", p, 1.0)):
				continue
			var clear: float = INF
			for fp: Array in danger:
				clear = minf(clear, FootprintBox.set_distance(traffic_footprints_at(p, 0.0), fp))
			if clear > fallback_clear + 0.3 and (on_break or nav.idle_safe(p) or not nav.idle_safe(here)):
				fallback_clear = clear
				fallback = p
			if clear < need:
				continue
			if not on_break and not nav.idle_safe(p) and nav.idle_safe(here):
				continue  # stay out of the break corner and the forklift areas when possible
			var score: float = r + (0.0 if nav.idle_safe(p) else 2.0)
			if score < best_score:
				best_score = score
				best = p
	if best == here:
		best = fallback
	if best == here and not danger.is_empty():
		# nothing out of the way by the usual rules (a tight spot): any
		# walkable floor that is clearer than here will do, the forklift
		# must get by
		var now_clear: float = INF
		for fp: Array in danger:
			now_clear = minf(now_clear, FootprintBox.set_distance(traffic_footprints_at(here, 0.0), fp))
		var most: float = now_clear + 0.3
		for r: float in [1.0, 1.6, 2.4, 3.2, 4.2, 5.5, 7.0]:
			for k: int in 24:
				var p: Vector2 = here + Vector2.from_angle(k * TAU / 24.0) * r
				if not nav.walkable(p):
					continue
				var clear: float = INF
				for fp: Array in danger:
					clear = minf(clear, FootprintBox.set_distance(traffic_footprints_at(p, 0.0), fp))
				if clear > most:
					most = clear
					best = p
	if best == here:
		return
	_yield_from = from
	_yielding = true
	_yield_wait = 0.0
	_block_t = 0.0
	_total_block_t = 0.0
	if motor == Motor.RUNNING and _mode == Mode.WALK and _saved_goal == null:
		_saved_goal = [_goal, _goal_yaw]
	_goal = best
	_goal_yaw = NAN
	if not _plan_path():
		_yielding = false
		return
	_mode = Mode.WALK
	motor = Motor.RUNNING
	_crossfade(_walk_anim)
	displaced = true


## A forklift or a pallet jack (a carrier on a job): people make full way
## for it, not just a step aside.
static func _is_machine(n: Node) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	return int(n.call(&"traffic_kind")) == Traffic.Kind.VEHICLE or (n is CarryAgent and (n as CarryAgent).job != null)


## A forklift needs the way (it waits on this worker, or its fixed
## manoeuvre runs through where the worker stands): the duty is dropped at
## once (props put down) and the worker walks out of the forklift's way
## and the corridor round it, and does not walk back.
func clear_the_way(from: Node) -> void:
	if planner == null or _on_job or from == null or not is_instance_valid(from):
		return
	if _yielding and _yield_from == from and _mode == Mode.WALK:
		return
	if duty != null:
		planner.call(&"request_release", self, true)
	if seat != null:
		planner.call(&"leave_seat", self)
	_yielding = false
	_saved_goal = null
	_start_yield(from)
	_saved_goal = null


## While stepped aside: wait for the other one to pass, then report done
## (the duty sees `displaced` and walks back to its spot).
func yield_tick(dt: float) -> bool:
	if not _yielding:
		return false
	if _mode == Mode.WALK:
		return true
	_yield_wait += dt
	var gone: bool = true
	if _yield_from != null and is_instance_valid(_yield_from):
		var theirs: Array = _yield_from.call(&"traffic_footprints")
		gone = FootprintBox.set_distance(traffic_footprints(), theirs) > 3.0 or _yield_wait > 12.0
		if _yield_from is WorkerActor and not _is_machine(_yield_from):
			# a person: by once they stopped walking, or after a short wait
			gone = gone or (_yield_from as WorkerActor)._mode != Mode.WALK or _yield_wait > 4.0
		if _yield_wait < 1.5:
			gone = false
	if gone:
		_yielding = false
		_yield_from = null
		motor = Motor.DONE
		_mode = Mode.STILL
		if _saved_goal != null:
			var g: Array = _saved_goal
			_saved_goal = null
			walk_to(g[0], g[1])
		return false
	return true


func is_yielding() -> bool:
	return _yielding


func is_seated() -> bool:
	return seat != null


func activity_text() -> String:
	if _on_job:
		return "Carry job"
	if _yielding:
		return "Making way"
	return ""
