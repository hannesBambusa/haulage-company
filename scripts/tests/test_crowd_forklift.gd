extends SceneTree
## Headless scenario on main.tscn: three walking workers meet at a forklift.
## Forklift 1 stands parked at its spot by dock 1; three staff workers (their
## duties dropped, the others hidden) are sent from different sides to goals
## that take them past the forklift and past each other at the same time.
## Rounds: the same crowd three times, with the starts and goals swapped
## round, so each worker meets the others from another side.
## Pass:
## - every worker reaches its goal within GOAL_TIME game seconds;
## - no worker stands still with a goal for over MAX_STILL s (waiting off
##   the path of a forklift that is driving does not count);
## - forklift-person never below MIN_VP (edge to edge), person-person never
##   below MIN_PP (centre to centre).
## Godot --headless --path . --fixed-fps 60 -s scripts/tests/test_crowd_forklift.gd

const SPEED: int = 4
const GOAL_TIME: float = 40.0
const MAX_STILL: float = 3.0
const MIN_VP: float = 1.5
const MIN_PP: float = 0.8
## Bound for the whole run (frames): macOS has no `timeout`.
const FRAME_CAP: int = 6000
## Starts and goals round Forklift 1 parked at (-6, -12), facing +x.
const ROUTES: Array = [
	[Vector2(-10.6, -12.0), Vector2(-1.4, -12.2)],
	[Vector2(-1.4, -12.6), Vector2(-10.6, -12.4)],
	[Vector2(-6.0, -16.2), Vector2(-6.0, -8.4)],
]

## FootprintBox loaded at run time (the class needs the autoloads first).
var _fb: GDScript = null
var _failures: int = 0
var _planner: Node = null
var _fork: Node = null
var _frames: int = 0
var _min_vp: float = INF
var _min_pp: float = INF
var _worst_still: float = 0.0
var _worst_still_who: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gs: Node = root.get_node(^"GameState")
	gs.speed = SPEED
	gs.minutes_per_second = 1.0 / 60.0
	change_scene_to_file("res://scenes/main.tscn")
	for i: int in 4:
		await process_frame
	_fb = load("res://scripts/gameplay/footprint_box.gd")
	_planner = get_first_node_in_group(&"duty_planner")
	var board: Node = get_first_node_in_group(&"job_board")
	if _planner == null or board == null:
		_finish("missing nodes")
		return
	while not bool(_planner.get(&"ready_done")):
		await process_frame
	var flow: Node = get_first_node_in_group(&"cargo_flow")
	if flow != null:
		flow.set(&"auto_flow", false)
	for f: Node in board.forklifts():
		if String(f.name).ends_with("1"):
			_fork = f
	var workers: Array = _planner.get(&"workers")
	var crew: Array[Node] = []
	for w: Node in workers:
		_planner.call(&"request_release", w, true)
		if crew.size() < 3:
			crew.append(w)
		else:
			w.visible = false  # out of the scene: only the three meet here
	for rnd: int in 3:
		if not await _round(crew, rnd):
			break
	_finish("")


## One meeting: the crew placed at their starts, all sent off at once.
func _round(crew: Array[Node], rnd: int) -> bool:
	var goals: Array[Vector2] = []
	for i: int in crew.size():
		var w: Node = crew[i]
		var r: Array = ROUTES[(i + rnd) % ROUTES.size()]
		var start: Vector2 = w.nav.nearest_walkable(r[0], 1.0)
		w.stop_motor()
		w.speed = 0.0
		w.global_position = Vector3(start.x, w.global_position.y, start.y)
		w.rotation.y = atan2(-(r[1].x - start.x), -(r[1].y - start.y))
		goals.append(r[1])
	for i: int in 30:
		_hold_duties(crew)
		await process_frame
	for i: int in crew.size():
		crew[i].walk_to(goals[i])
	var still: Array[float] = [0.0, 0.0, 0.0]
	var t0: float = float(_planner.get(&"clock"))
	var last: float = t0
	while true:
		_hold_duties(crew)
		await process_frame
		_frames += 1
		var now: float = float(_planner.get(&"clock"))
		var dt: float = now - last
		last = now
		var done: int = 0
		for i: int in crew.size():
			var w: Node = crew[i]
			var at_goal: bool = w.pos2().distance_to(goals[i]) < 0.35
			var walking: bool = int(w.motor) == 0 or w.is_yielding()
			if not walking and not at_goal:
				if int(w.motor) == 2:
					_check(false, "round %d: %s gave up at %s (goal %s)" % [rnd, w.name, w.pos2(), goals[i]])
					return false
				w.walk_to(goals[i])  # a step aside ended short of the goal: on again, as a duty would
			if at_goal and not walking:
				done += 1
				still[i] = 0.0
				continue
			var waits_for_fork: bool = w.is_yielding() and _fork != null and bool(_fork.call(&"traffic_moving"))
			if float(w.speed) < 0.05 and not waits_for_fork:
				still[i] += dt
			else:
				still[i] = 0.0
			if still[i] > MAX_STILL and still[i] - dt <= MAX_STILL:
				print("  still: %s at %s mode %d blocked %s people_by %s giving_way %s yielding %s" % [w.name, w.pos2(), int(w.get(&"_mode")), w.get(&"_blocked"), w.get(&"_people_by"), w.get(&"_giving_way"), w.is_yielding()])
			if still[i] > _worst_still:
				_worst_still = still[i]
				_worst_still_who = "round %d %s at %s (%s)" % [rnd, w.name, w.pos2(), w.activity_text()]
		_measure(crew)
		if done == crew.size():
			print("  ..   round %d: all at their goals in %.1f s" % [rnd, now - t0])
			return true
		if now - t0 > GOAL_TIME or _frames > FRAME_CAP:
			for i: int in crew.size():
				print("  %s at %s goal %s motor %d speed %.2f %s" % [crew[i].name, crew[i].pos2(), goals[i], crew[i].motor, crew[i].speed, crew[i].activity_text()])
			_check(false, "round %d: all at their goals within %.0f s" % [rnd, GOAL_TIME])
			return false
	return false


## Keeps the planner from handing the crew new duties mid-test.
func _hold_duties(crew: Array[Node]) -> void:
	var think: Dictionary = _planner.get(&"_think")
	for w: Node in crew:
		if w.duty != null:
			_planner.call(&"request_release", w, true)
		think[w] = 1.0e9


func _measure(crew: Array[Node]) -> void:
	for i: int in crew.size():
		for j: int in range(i + 1, crew.size()):
			_min_pp = minf(_min_pp, crew[i].pos2().distance_to(crew[j].pos2()))
		if _fork != null:
			_min_vp = minf(_min_vp, _fb.set_distance(crew[i].traffic_footprints(), _fork.call(&"traffic_footprints")))


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


func _finish(error: String) -> void:
	_check(_worst_still <= MAX_STILL, "longest standing still with a goal %.1f s <= %.0f (%s)" % [_worst_still, MAX_STILL, _worst_still_who])
	_check(_min_vp >= MIN_VP, "min forklift-person %.2f m >= %.1f" % [_min_vp, MIN_VP])
	_check(_min_pp >= MIN_PP, "min person-person %.2f m >= %.1f" % [_min_pp, MIN_PP])
	if not error.is_empty():
		push_error("test_crowd_forklift: " + error)
		_failures += 1
	print("test_crowd_forklift: PASS" if _failures == 0 else "test_crowd_forklift: FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)
