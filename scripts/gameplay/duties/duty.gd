class_name Duty
extends RefCounted
## Something a worker does when not carrying pallets: a list of small steps
## (walk somewhere, turn, hold an action for a while, take or put a prop)
## run one after the other in game time. Subclasses build the steps in
## plan() and say how to leave cleanly in cleanup(): put the props back,
## or (urgent) put them down where the worker stands.
## Interruptible at any step: abort() swaps the remaining steps for the
## cleanup. A worker pushed off its spot (stepping aside for a forklift)
## walks back before the step goes on.

signal finished(duty: Duty)

## Short id ("clean", "coffee", ...) and the text the Staff panel shows.
var kind: StringName = &""
var title: String = ""
## Coffee, water and chat breaks (standing still there is fine).
var is_break: bool = false
var worker: WorkerActor = null
var planner: Node = null
## What the worker is doing right now ("walking to the broom rack").
var status: String = ""
var done: bool = false
var aborting: bool = false

var _steps: Array[Step] = []
var _cur: Step = null


class Step:
	extends RefCounted
	var label: String = ""
	var start: Callable = Callable()
	var update: Callable = Callable()
	## [Vector2 position, float yaw] the step must be done at, or empty.
	var spot: Array = []
	var walk: bool = false
	var t: float = 0.0
	var length: float = 0.0


func setup(p_worker: WorkerActor, p_planner: Node) -> void:
	worker = p_worker
	planner = p_planner


## Builds the steps. Returns false when the duty cannot start after all.
func plan() -> bool:
	return true


## Steps that leave the duty cleanly. `urgent`: no walking, put things down here.
func cleanup(urgent: bool) -> void:
	put_down_all(urgent)


## Called once when the duty ends (done or aborted): free claims.
func release() -> void:
	pass


func start() -> bool:
	if not plan():
		release()
		return false
	return true


func tick(dt: float) -> void:
	if done:
		return
	if worker.yield_tick(dt):
		status = "making way"
		return
	if worker.displaced:
		worker.displaced = false
		if _cur != null and not _cur.walk and not _cur.spot.is_empty():
			# pushed off the spot: walk back, then do the step again
			_cur.t = 0.0
			_steps.push_front(_cur)
			_steps.push_front(_walk_step(_cur.spot[0], _cur.spot[1], "back to work"))
			_cur = null
	var guard: int = 0
	while guard < 8:
		guard += 1
		if _cur == null:
			if _steps.is_empty():
				_finish()
				return
			_cur = _steps.pop_front()
			status = _cur.label
			set_meta(&"last_label", _cur.label)
			if _cur.start.is_valid():
				_cur.start.call()
		if _cur == null:
			continue  # start() aborted the duty
		_cur.t += dt
		if _cur.update.is_valid() and not bool(_cur.update.call(_cur, dt)):
			return
		_cur = null
		dt = 0.0


## Leaves the duty: the remaining steps become the cleanup.
func abort(urgent: bool = false) -> void:
	if done:
		return
	if aborting and not urgent:
		return
	if OS.get_environment("DUTY_DEBUG") == "2":
		print("  abort %s '%s' (%s) urgent=%s from %s" % [worker.display_name, title, status, urgent, get_stack().slice(1, 3).map(func(f: Dictionary) -> String: return "%s:%d" % [f.function, f.line])])
	aborting = true
	_steps.clear()
	_cur = null
	worker.stop_motor()
	if worker.seat != null:
		stand_up_now()
	cleanup(urgent)
	if urgent:
		_steps.clear()
		_finish()


func _finish() -> void:
	if done:
		return
	done = true
	status = ""
	if planner != null:
		(planner.get(&"spots") as SpotQueue).release_all(worker)
		planner.call(&"release_points", worker)
	_steps.clear()
	_cur = null
	release()
	finished.emit(self)


func add(step: Step) -> void:
	_steps.append(step)


func add_front(step: Step) -> void:
	_steps.push_front(step)


# --- step builders --------------------------------------------------------------------

func _walk_step(p: Vector2, face_yaw: float, label: String) -> Step:
	var s: Step = Step.new()
	s.label = label
	s.walk = true
	s.start = func() -> void: worker.walk_to(p, face_yaw)
	s.update = func(_s: Step, _dt: float) -> bool:
		if worker.motor == WorkerActor.Motor.RUNNING:
			return false
		if worker.motor == WorkerActor.Motor.FAILED:
			_on_walk_failed()
			return false
		return true
	return s


func walk(p: Vector2, face_yaw: float = NAN, label: String = "walking") -> void:
	add(_walk_step(p, face_yaw, label))


func face(p: Vector2, label: String = "") -> void:
	var s: Step = Step.new()
	s.label = label if not label.is_empty() else status
	s.start = func() -> void: worker.face_point(p)
	s.update = func(_s: Step, _dt: float) -> bool: return worker.motor != WorkerActor.Motor.RUNNING
	add(s)


func turn(y: float, label: String = "") -> void:
	var s: Step = Step.new()
	s.label = label
	s.start = func() -> void: worker.turn_to(y)
	s.update = func(_s: Step, _dt: float) -> bool: return worker.motor != WorkerActor.Motor.RUNNING
	add(s)


## Holds a looping action for `time` game seconds at `spot` ([pos, yaw] or []).
func act(anim: StringName, time: float, label: String, spot: Array = []) -> Step:
	var s: Step = Step.new()
	s.label = label
	s.spot = spot
	s.length = time
	s.start = func() -> void: worker.hold(anim)
	s.update = func(st: Step, _dt: float) -> bool: return st.t >= st.length
	add(s)
	return s


## Plays a one-shot action to its end.
func once(anim: StringName, label: String, spot: Array = []) -> void:
	var s: Step = Step.new()
	s.label = label
	s.spot = spot
	s.start = func() -> void: worker.play_once(anim)
	s.update = func(st: Step, _dt: float) -> bool: return st.t > 0.05 and worker._once_left <= 0.0
	add(s)


## Runs `fn` once (instant step).
func call_step(fn: Callable, label: String = "") -> void:
	var s: Step = Step.new()
	s.label = label
	s.start = fn
	add(s)


## Waits until `cond` is true (or `timeout`), holding `anim`.
func wait_until(cond: Callable, anim: StringName, timeout: float, label: String, spot: Array = []) -> void:
	var s: Step = Step.new()
	s.label = label
	s.spot = spot
	s.length = timeout
	s.start = func() -> void: worker.hold(anim)
	s.update = func(st: Step, _dt: float) -> bool: return bool(cond.call()) or st.t >= st.length
	add(s)


## A step with a custom per-tick function fn(step, dt) -> bool (true = done).
func custom(label: String, on_start: Callable, fn: Callable, spot: Array = []) -> void:
	var s: Step = Step.new()
	s.label = label
	s.spot = spot
	s.start = on_start
	s.update = fn
	add(s)


## Waits for a one-at-a-time spot (the break counter, the cleaning
## corner): stands aside nearby until it is free, then walks up. The spot is
## freed with free_spot() once done there.
func use_spot(key: String, spot: Array, label: String) -> void:
	var q: SpotQueue = planner.get(&"spots")
	var s: Step = Step.new()
	s.label = "walking to the %s" % label
	s.walk = true
	s.start = func() -> void: worker.walk_to(spot[0], spot[1])
	s.update = func(st: Step, _dt: float) -> bool:
		var mine: bool = q.holder(key) == worker
		var h: WorkerActor = q.holder(key) as WorkerActor
		if not mine and st.has_meta(&"queued") and st.t > 20.0 and h != null and h.pos2().distance_to(spot[0]) > 2.5 and not h.is_walking():
			q.taken.erase(key)  # the holder is stuck away from it: the spot is free again
		if not mine and (worker.pos2().distance_to(spot[0]) < 3.5 or st.has_meta(&"queued")):
			mine = q.reserve(key, worker, spot[0])
			if mine and st.has_meta(&"queued"):
				st.remove_meta(&"queued")
				planner.call(&"release_points", worker)
				status = "walking to the %s" % label
				worker.walk_to(spot[0], spot[1])
				return false
			if not mine and not st.has_meta(&"queued"):
				# busy: wait a little way off
				st.set_meta(&"queued", true)
				st.set_meta(&"queued_at", st.t)
				status = "waiting for the %s" % label
				var wait: Vector2 = planner.call(&"wait_point_near", spot[0], worker)
				worker.walk_to(wait, WorkerActor.yaw_towards(wait, spot[0]))
				return false
		if st.has_meta(&"queued"):
			if not aborting and st.t - float(st.get_meta(&"queued_at", st.t)) > DutyConfig.QUEUE_GIVE_UP:
				abort(false)  # waited too long for the spot: give the duty up
			return false
		if worker.motor == WorkerActor.Motor.FAILED:
			_on_walk_failed()
			return false
		return mine and worker.motor == WorkerActor.Motor.DONE
	add(s)


func free_spot(key: String) -> void:
	var q: SpotQueue = planner.get(&"spots")
	call_step(func() -> void: q.release(key, worker))


func take(prop: PropItem, hand: StringName, label: String = "") -> void:
	var s: Step = Step.new()
	s.label = label if not label.is_empty() else "taking the %s" % prop.kind
	s.start = func() -> void:
		prop.claimed_by = null
		worker.take(prop, hand)
	s.update = func(st: Step, _dt: float) -> bool: return st.t >= DutyConfig.PROP_MOVE_TIME
	add(s)


func put(prop: PropItem, parent: Node3D, xf: Transform3D, where: PropItem.Where, label: String = "") -> void:
	var s: Step = Step.new()
	s.label = label if not label.is_empty() else "putting the %s down" % prop.kind
	s.start = func() -> void:
		worker.put(prop, parent, xf, where)
	s.update = func(st: Step, _dt: float) -> bool: return st.t >= DutyConfig.PROP_MOVE_TIME
	add(s)


func tow(prop: PropItem) -> void:
	var s: Step = Step.new()
	s.label = "taking the bucket"
	s.start = func() -> void:
		prop.claimed_by = null
		worker.tow(prop)
		planner.call(&"prop_lifted", prop)
	s.update = func(st: Step, _dt: float) -> bool: return st.t >= DutyConfig.PROP_MOVE_TIME
	add(s)


func stow(prop: PropItem) -> void:
	var s: Step = Step.new()
	s.label = ""
	s.start = func() -> void: worker.stow(prop)
	s.update = func(st: Step, _dt: float) -> bool: return st.t >= DutyConfig.PROP_MOVE_TIME
	add(s)


## Gets up from the chair at once (abort while seated).
func stand_up_now() -> void:
	var front: Vector2 = worker.pos2() + worker.forward2() * 0.5
	var area: BreakArea = planner.get(&"break_area")
	if area != null:
		for s: Dictionary in area.seats:
			if s.node == worker.seat:
				front = planner.call(&"seat_approach", s)
	worker.global_position = Vector3(front.x, 0.0, front.y)
	planner.call(&"leave_seat", worker)
	worker.hold(&"Idle")


## Cleanup that returns every held prop: kit to the belt, tools home (or,
## urgent, put down right here and left for someone to tidy away).
func put_down_all(urgent: bool) -> void:
	for p: PropItem in worker.held_props():
		if worker.kit.has(p.kind) and worker.kit[p.kind] == p:
			if urgent:
				worker.stow(p)
			else:
				stow(p)
			continue
		if urgent:
			planner.call(&"drop_here", worker, p)
		else:
			planner.call(&"add_return_steps", self, p)


func _on_walk_failed() -> void:
	# no way there: give up; when already leaving, put things down here
	if aborting:
		_steps.clear()
		_cur = null
		for p: PropItem in worker.held_props():
			if worker.kit.get(p.kind) == p:
				worker.stow(p)
			else:
				planner.call(&"drop_here", worker, p)
		_finish()
	else:
		abort(false)
