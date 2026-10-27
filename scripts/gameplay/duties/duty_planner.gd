class_name DutyPlanner
extends Node
## Gives every worker something to do when they are not carrying pallets.
## Utility AI: each worker without a duty scores what could be done now
## from its needs (tiredness -> coffee, thirst -> water, company -> a chat)
## and from the world (dirt on the floor, pallets waiting for a scan, a
## truck reversing in, a parked forklift due for a check, a rack aisle due
## for an inspection round), picks the best and runs it as a Duty.
## Also owns the people's floor model (PeopleNav), the dirt (DirtField),
## the props (PropStore) and the break area's conversation circle.
## Runs on game time in small fixed steps, so fast-forward takes the same
## path through every duty as 1x.

signal duty_started(worker: WorkerActor, duty: Duty)
signal duty_ended(worker: WorkerActor, duty: Duty)

const STEP: float = 1.0 / 60.0
## Edge-to-edge room people keep from a forklift's fixed manoeuvre (its body
## and the next metres of its leg).
const WAY_CORRIDOR: float = 1.6

@export var level_path: NodePath
@export var storage_grid_path: NodePath
@export var job_board_path: NodePath
@export var traffic_path: NodePath
@export var break_area_path: NodePath
@export var cleaning_corner_path: NodePath
## Where the box a scenery worker carries in is put down (by the back wall).
@export var box_home: Vector3 = Vector3(-11.3, 0.0, -25.35)
## Dirt on the floor at the start (a working hall is never spotless).
@export var start_dirt: int = 3
@export var random_seed: int = 7
## Floor nobody hangs about on (the office behind its narrow way in).
@export var quiet_exclude_rects: Array[Rect2] = [Rect2(3.6, -26.0, 7.2, 4.6)]
## The hall floor people use (x, z rects); outside is the yard.
@export var hall_rects: Array[Rect2] = [Rect2(-24.0, -26.0, 30.9, 26.0), Rect2(6.9, -26.0, 15.1, 12.0)]

var clock: float = 0.0
var workers: Array[WorkerActor] = []
var nav: PeopleNav = null
var store: PropStore = null
var dirt: DirtField = null
var break_area: BreakArea = null
var corner: CleaningCorner = null
var traffic: Traffic = null
var grid: StorageGrid = null
var board: JobBoard = null
var group: ConversationGroup = null
## One-at-a-time spots (break counter, cleaning corner).
var spots: SpotQueue = SpotQueue.new()
var ready_done: bool = false
## Per kind: number of duties started (for the Staff panel and the test).
var started_counts: Dictionary = {}
## Scans written to pallet histories.
var scans: int = 0

var _level: Node3D = null
var _think: Dictionary = {}  ## worker -> seconds until it thinks again
var _last_kind: Dictionary = {}  ## worker -> StringName
var _filler_at: Dictionary = {}  ## "id:kind" -> clock
var _odometer: Dictionary = {}  ## forklift -> metres since the last dirt
var _service_due: Dictionary = {}  ## forklift -> clock
var _round_due: Dictionary = {}  ## lock key -> clock
var _seen: Dictionary = {}  ## CargoUnit -> [state, since]
var _safety_points: Array = []
var _greet_wanted: Dictionary = {}  ## TrailerBay -> clock
var _keep_clear: Array[Vector2] = []
var _think_fail: Dictionary = {}
var _failed: Dictionary = {}  ## "id:kind" -> clock until the kind is tried again
var _guard_t: float = 0.0
var _slow_t: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Microseconds spent per part (debugging the cost of the staff).
var perf: Dictionary = {}


func _ready() -> void:
	add_to_group(&"duty_planner")
	_rng.seed = random_seed
	_setup.call_deferred()


func _setup() -> void:
	# Traffic collects its obstacles deferred too: wait until it has
	await get_tree().process_frame
	_level = get_node_or_null(level_path) as Node3D
	grid = get_node_or_null(storage_grid_path) as StorageGrid
	board = get_node_or_null(job_board_path) as JobBoard
	traffic = get_node_or_null(traffic_path) as Traffic
	break_area = get_node_or_null(break_area_path) as BreakArea
	corner = get_node_or_null(cleaning_corner_path) as CleaningCorner
	if _level == null or grid == null or board == null or traffic == null:
		push_error("DutyPlanner: level, grid, job board or traffic path not set")
		return
	nav = PeopleNav.new(traffic, hall_rects)
	for r: Rect2 in quiet_exclude_rects:
		nav.no_idle.append(r)
	# forklifts turn round where they park: nobody hangs about there
	for i: int in board.parking_spots.size():
		var ps: Vector3 = board.parking_spots[i]
		nav.no_idle.append(Rect2(ps.x - 2.8, ps.z - 2.8, 5.6, 5.6))
	var seed_cell: Vector2 = grid.inbound_rect.get_center() + Vector2(0.0, -grid.inbound_rect.size.y * 0.5 - 1.0)
	nav.mark_reachable(nav.nearest_walkable(seed_cell, 3.0))
	dirt = DirtField.new()
	dirt.name = "Dirt"
	add_child(dirt)
	store = PropStore.new(self, dirt, nav, corner, break_area)
	store.stock_corner()
	if break_area != null:
		group = ConversationGroup.new(break_area.group_center(), PI)
		for r: Rect2 in break_area.floor_rects():
			nav.no_idle.append(r)
	_check_furniture()
	var found: Array[WorkerActor] = []
	for n: Node in _level.find_children("*", "Node3D", true, false):
		var w: WorkerActor = n as WorkerActor
		# the Jack operator does no duties: it waits at the jack spot
		if w != null and w.is_visible_in_tree() and not (w.mover is JackCarrier):
			found.append(w)
	found.sort_custom(func(a: WorkerActor, b: WorkerActor) -> bool: return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	for i: int in found.size():
		var w: WorkerActor = found[i]
		var id: int = String(w.name).to_int() if String(w.name).to_int() > 0 else i + 1
		w.enable_duties(self, nav, id, random_seed * 100 + id)
		store.give_kit(w)
		workers.append(w)
		_think[w] = _rng.randf_range(0.0, 1.5)
		var box: Node3D = w.get_node_or_null(^"CarryBox") as Node3D
		if box != null and w.walk_animation == &"Carry":
			w._walk_anim = &"Carry"
			w.hold(&"Idle")
			var p: PropItem = store.adopt_box(w, box, Transform3D(Basis.IDENTITY, box_home))
			_begin(w, TidyUp.new(p))
		elif not nav.walkable(w.pos2()):
			var to: Vector2 = nav.nearest_walkable(w.pos2(), 2.0)
			w.global_position = Vector3(to.x, w.global_position.y, to.y)
	for f: ForkliftCarrier in board.forklifts():
		_odometer[f] = f.odometer
		_service_due[f] = _rng.randf_range(60.0, DutyConfig.SERVICE_EVERY)
	board.hold_wanted.connect(_on_hold_wanted)
	board.unit_placed.connect(_on_unit_placed)
	for n: Node in _level.find_children("*", "", true, false):
		if n.has_signal(&"reverse_started"):
			n.connect(&"reverse_started", _on_reverse_started)
	_safety_points = _find_safety_points()
	for i: int in start_dirt:
		var p: Vector2 = _random_floor_point()
		if p != Vector2.INF:
			dirt.add_dirt(p, i == start_dirt - 1, _rng.randf_range(0.35, 0.6))
	ready_done = true
	print("DutyPlanner: %d workers, %d props, %d safety checkpoints" % [workers.size(), store.props.size(), _safety_points.size()])


## Warns when the break area or the cleaning corner overlaps the level
## (the level layout may change under them).
func _check_furniture() -> void:
	for root: Node3D in [break_area, corner]:
		if root == null:
			continue
		for cs: Node in root.find_children("*", "CollisionShape3D", true, false):
			var body: Node3D = cs.get_parent() as Node3D
			var c: Vector2 = Vector2(body.global_position.x, body.global_position.z)
			for i: int in traffic.statics.size():
				var r: Rect2 = traffic.statics[i]
				# furniture stands against the hall walls on purpose
				if traffic.static_names[i].begins_with("wall "):
					continue
				if r.has_point(c) and not traffic.static_names[i] in [String(body.name)]:
					var mine: bool = false
					for cs2: Node in root.find_children("*", "CollisionShape3D", true, false):
						if String(cs2.get_parent().name) == traffic.static_names[i]:
							mine = true
					if not mine:
						push_warning("DutyPlanner: %s overlaps %s" % [body.name, traffic.static_names[i]])


# --- main loop ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not ready_done or GameState.paused:
		return
	var t0: int = Time.get_ticks_usec()
	var left: float = delta * float(GameState.speed)
	while left > 0.0:
		var dt: float = minf(left, STEP)
		left -= dt
		_step(dt)
	perf["step"] = int(perf.get("step", 0)) + Time.get_ticks_usec() - t0


func _step(dt: float) -> void:
	clock += dt
	_slow_t -= dt
	if _slow_t <= 0.0:
		_slow_t = 0.25
		dirt.tick(0.25)
		_forklift_dirt()
		_track_pallets()
	if group != null:
		group.tick(dt)
	spots.tick(dt)
	_guard_t -= dt
	var guard: bool = _guard_t <= 0.0
	if guard:
		_guard_t = 0.25
	for w: WorkerActor in workers:
		if w.is_on_job():
			continue
		w.staff_step(dt)
		w.tired = minf(1.0, w.tired + DutyConfig.TIRED_RATE * dt)
		w.thirst = minf(1.0, w.thirst + DutyConfig.THIRST_RATE * dt)
		w.social = minf(1.0, w.social + DutyConfig.SOCIAL_RATE * dt)
		var d: Duty = w.duty as Duty
		if guard:
			_way_guard(w)
			d = w.duty as Duty
		if d != null:
			d.tick(dt)
			if guard and not d.done:
				_guard(w, d)
				_watchdog(w, d)
			if d.done:
				_end(w, d)
		elif w.yield_tick(dt):
			pass  # making way for a forklift (duty dropped): no new duty until clear
		else:
			_think[w] = float(_think.get(w, 0.0)) - dt
			if float(_think[w]) <= 0.0:
				_think[w] = DutyConfig.THINK_INTERVAL
				var t1: int = Time.get_ticks_usec()
				_choose(w)
				perf["choose"] = int(perf.get("choose", 0)) + Time.get_ticks_usec() - t1


func _begin(w: WorkerActor, d: Duty) -> bool:
	d.setup(w, self)
	if not d.start():
		return false
	w.duty = d
	d.set_meta(&"began", clock)
	started_counts[d.kind] = int(started_counts.get(d.kind, 0)) + 1
	_last_kind[w] = d.kind
	duty_started.emit(w, d)
	return true


func _end(w: WorkerActor, d: Duty) -> void:
	if OS.get_environment("DUTY_DEBUG") == "2" and clock - float(d.get_meta(&"began", clock)) < 3.0:
		print("DutyPlanner: %s ended '%s' after %.1f s at %s (aborting %s, last step '%s')" % [w.display_name, d.title, clock - float(d.get_meta(&"began", clock)), w.pos2(), d.aborting, d.get_meta(&"last_label", "")])
	if w.duty == d:
		w.duty = null
	_think[w] = 0.0
	if d.aborting and not d.has_meta(&"released") and clock - float(d.get_meta(&"began", clock)) < 5.0:
		# gave up straight away: not this again for a while
		_failed["%d:%s" % [w.staff_id, d.kind]] = clock + 30.0
		_think[w] = 1.0
	w.hold(&"Idle")
	duty_ended.emit(w, d)


## A worker inside a forklift area leaves when a forklift claims the area.
func _guard(w: WorkerActor, d: Duty) -> void:
	if d.aborting or d.is_break or w.is_yielding():
		return
	if d is ScanPallet and not (d as ScanPallet).still_valid():
		d.abort(false)
		return
	if not d.kind in [&"scan", &"clean", &"rack_round"]:
		return
	# the place the duty works at (or is heading for) is a forklift's now
	var cur: Duty.Step = d.get(&"_cur")
	var at: Vector2 = w.pos2()
	if cur != null and cur.walk:
		at = w._goal
	elif cur != null and not cur.spot.is_empty():
		at = cur.spot[0]
	if area_busy(at):
		d.abort(false)


## People never stand in a forklift's way: a worker who is not walking
## (working a spot, waiting, talking) within the corridor round a
## forklift's body or the next metres of its leg, while that leg is a fixed
## manoeuvre (approach, back-out, lane) or the forklift waits on the worker,
## drops the duty and walks clear.
func _way_guard(w: WorkerActor) -> void:
	if w.is_yielding() or w.is_on_job() or w.service_vehicle != null or traffic == null or traffic.board == null:
		return  # (servicing a parked forklift: next to it by design, off every path)
	if w._mode == WorkerActor.Mode.WALK and w.speed > 0.2:
		return  # walking: its own look-ahead keeps it off forklifts
	var here: Array = w.traffic_footprints()
	for f: Node in traffic.board.forklifts():
		if f == w.service_vehicle or not f.call(&"traffic_active"):
			continue
		var waits_on_me: bool = f.get(&"blocked_by") == w
		if not waits_on_me and not bool(f.call(&"committed")):
			continue
		var near: bool = FootprintBox.set_distance(here, f.call(&"traffic_footprints")) < WAY_CORRIDOR
		if not near:
			for fp: Array in f.call(&"future_footprints", 12.0):
				if FootprintBox.set_distance(here, fp) < WAY_CORRIDOR:
					near = true
					break
		if near:
			w.clear_the_way(f)
			return


## Asks a worker to leave its duty (puts the props back first; urgent: puts
## them down where it stands). Returns false when it had none.
func request_release(w: WorkerActor, urgent: bool = false) -> bool:
	var d: Duty = w.duty as Duty
	if d == null or d.done:
		return false
	d.set_meta(&"released", true)
	d.abort(urgent)
	if d.done:
		_end(w, d)
	return true


## A duty that has not moved on (same step, same place) for long is given
## up: first cleanly, then (still stuck while leaving) at once.
func _watchdog(w: WorkerActor, d: Duty) -> void:
	var key: String = "%s|%s|%s" % [d.status, (w.pos2() * 2.0).round(), d.get(&"_cur")]
	if d.get_meta(&"wd_key", "") != key:
		d.set_meta(&"wd_key", key)
		d.set_meta(&"wd_since", clock)
		return
	var cur: Duty.Step = d.get(&"_cur")
	var limit: float = 40.0
	if cur != null and not cur.walk and cur.length > 0.0:
		limit = cur.length + 40.0  # a long action is fine
	if d.is_break and cur != null and not cur.walk:
		limit = maxf(limit, 140.0)
	if clock - float(d.get_meta(&"wd_since")) < limit:
		return
	d.set_meta(&"wd_since", clock)
	if OS.get_environment("DUTY_DEBUG") == "1":
		print("DutyPlanner: %s stuck on '%s' (%s) at %s, giving up%s" % [w.display_name, d.title, d.status, w.pos2(), " now" if d.aborting else ""])
	d.abort(d.aborting)
	if d.done:
		_end(w, d)


## JobBoard borrowed the worker for a carry job: leave the duty at once.
func worker_taken(w: WorkerActor) -> void:
	var d: Duty = w.duty as Duty
	if d != null:
		d.abort(true)
		_end(w, d)


# --- choosing -------------------------------------------------------------------------------

func _choose(w: WorkerActor) -> void:
	var options: Array = _options(w)
	options.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	var tried: int = 0
	for i: int in options.size():
		if tried >= 4:
			break
		var d: Duty = (options[i][1] as Callable).call()
		if d != null and float(_failed.get("%d:%s" % [w.staff_id, d.kind], -1.0)) > clock:
			continue
		tried += 1
		if d != null and not _begin(w, d):
			if OS.get_environment("DUTY_DEBUG") == "2":
				print("DutyPlanner: %s could not start '%s' at %s" % [w.display_name, d.title, w.pos2()])
			# could not even start (no tools, no room): not again for a while
			_failed["%d:%s" % [w.staff_id, d.kind]] = clock + 20.0
			continue
		if d != null:
			return
	# nothing else would start: a call or a stretch right here, never idle
	if clock - float(_think_fail.get(w, -10.0)) > 2.0:
		_think_fail[w] = clock
		return
	var f: Duty = Filler.new(Filler.Kind.PHONE if _rng.randf() < 0.5 else Filler.Kind.STRETCH, [w.pos2(), w.yaw()])
	_begin(w, f)


## [score, maker] pairs; makers build the duty (or null when it no longer fits).
func _options(w: WorkerActor) -> Array:
	var out: Array = []
	var here: Vector2 = w.pos2()
	var last: StringName = _last_kind.get(w, &"")
	var on_break: int = _count_breaks()
	var noise: float = _rng.randf() * 0.06
	# a truck reversing in: meet it
	for bay: TrailerBay in _greet_wanted.keys():
		if bay.has_meta(&"greeter"):
			continue
		var spot: Array = _greet_spot(bay)
		if not spot.is_empty():
			out.append([1.2 - here.distance_to(spot[0]) * 0.01, func() -> Duty:
				if bay.has_meta(&"greeter") or not _greet_wanted.has(bay):
					return null
				_greet_wanted.erase(bay)  # one greeting per truck
				return GreetTruck.new(bay, spot)])
	# things left lying about
	for p: PropItem in store.loose():
		out.append([0.8 - here.distance_to(Vector2(p.global_position.x, p.global_position.z)) * 0.01, func() -> Duty: return TidyUp.new(p) if p.is_available() else null])
	# needs
	if break_area != null and on_break < 2:
		if w.tired >= DutyConfig.NEED_URGENT:
			out.append([0.6 + w.tired * 0.5, func() -> Duty: return CoffeeBreak.new(CoffeeBreak.Kind.COFFEE)])
		elif w.tired > 0.45 and group.size() > 0 and w.social > 0.4:
			out.append([0.55 + w.social * 0.3, func() -> Duty: return CoffeeBreak.new(CoffeeBreak.Kind.COFFEE)])
		if w.thirst >= DutyConfig.NEED_URGENT:
			out.append([0.55 + w.thirst * 0.4, func() -> Duty: return CoffeeBreak.new(CoffeeBreak.Kind.WATER)])
		if w.social > 0.65 and group.size() > 0 and not group.is_full():
			out.append([0.5 + w.social * 0.4, func() -> Duty: return CoffeeBreak.new(CoffeeBreak.Kind.CHAT)])
	# dirt
	var best_spot: DirtField.Spot = null
	var best_s: float = -INF
	for s: DirtField.Spot in dirt.spots:
		if s.claimed_by != null or s.amount < DutyConfig.DIRT_WORTH or area_busy(s.pos):
			continue
		if not store.available(&"mop" if s.spill else &"broom"):
			continue
		var sc: float = 0.45 + s.amount * 0.35 - here.distance_to(s.pos) * 0.008
		if sc > best_s:
			best_s = sc
			best_spot = s
	if best_spot != null:
		var sp: DirtField.Spot = best_spot
		out.append([best_s + noise, func() -> Duty: return CleanFloor.new(sp) if sp.claimed_by == null and not sp.cleaned else null])
	# pallets waiting for a scan
	var scan: Array = _scan_candidate(here)
	if not scan.is_empty():
		var sl: StorageSlot = scan[1]
		var sspot: Array = scan[2]
		out.append([float(scan[0]) + noise, func() -> Duty: return ScanPallet.new(sl, sspot) if sl.unit != null and not sl.unit.has_meta(&"scan_claim") else null])
	# a parked forklift due for a check
	for f: ForkliftCarrier in _service_due.keys():
		if clock < float(_service_due[f]) or f.has_meta(&"serviced_by") or not _parked(f) or not store.available(&"toolbox"):
			continue
		out.append([0.5 + noise - here.distance_to(f._pos) * 0.005, func() -> Duty:
			if f.has_meta(&"serviced_by") or not _parked(f):
				return null
			_service_due[f] = clock + DutyConfig.SERVICE_EVERY
			return ServiceForklift.new(f)])
	# a rack aisle due for an inspection round
	var round: Array = _rack_round(here)
	if not round.is_empty():
		out.append([0.4 + noise, round[0]])
	# always possible: a safety round, a call, a stretch
	if _safety_points.size() >= 2:
		out.append([0.2 + _rng.randf() * 0.08 - (0.1 if last == &"safety_round" else 0.0), func() -> Duty: return _make_safety_round(w)])
	var quiet: Array = _quiet_spot(w)
	if not point_free(quiet[0], w):
		quiet = [w.pos2(), w.yaw()]
	if clock - float(_filler_at.get("%d:phone" % w.staff_id, -1e9)) > DutyConfig.FILLER_COOLDOWN and last != &"phone":
		out.append([0.24 + _rng.randf() * 0.08, func() -> Duty:
			_filler_at["%d:phone" % w.staff_id] = clock
			return Filler.new(Filler.Kind.PHONE, quiet)])
	if clock - float(_filler_at.get("%d:stretch" % w.staff_id, -1e9)) > DutyConfig.FILLER_COOLDOWN and last != &"stretch":
		out.append([0.2 + _rng.randf() * 0.08, func() -> Duty:
			_filler_at["%d:stretch" % w.staff_id] = clock
			return Filler.new(Filler.Kind.STRETCH, quiet)])
	return out


func _count_breaks() -> int:
	var n: int = 0
	for w: WorkerActor in workers:
		if w.duty != null and (w.duty as Duty).is_break:
			n += 1
	return n


## Others on their way to a break (not at the break area yet).
func breaks_heading(me: WorkerActor) -> int:
	var n: int = 0
	for w: WorkerActor in workers:
		if w != me and w.duty != null and (w.duty as Duty).is_break and w.group == null and w.seat == null:
			n += 1
	return n


func break_group() -> ConversationGroup:
	return group


func _parked(f: ForkliftCarrier) -> bool:
	return f.is_idle() and f.speed < 0.02 and not f._homing and f._pos.distance_to(f._home_pos) < 0.5 and f.available


## True when a forklift holds the lock of a work area that contains p.
func area_busy(p: Vector2) -> bool:
	for l: Traffic.ZoneLock in traffic._locks.values():
		if l.holder != null and l.region.has_point(p):
			return true
	return false


# --- pallets -------------------------------------------------------------------------------

func _track_pallets() -> void:
	for s: StorageSlot in grid.slots:
		var u: CargoUnit = s.unit
		if u == null:
			continue
		var rec: Variant = _seen.get(u)
		if rec == null or int(rec[0]) != u.state:
			_seen[u] = [u.state, clock]


func _scan_candidate(here: Vector2) -> Array:
	var best: Array = []
	var best_s: float = -INF
	for s: StorageSlot in grid.slots:
		var u: CargoUnit = s.unit
		if u == null or u.is_busy() or u.has_meta(&"scan_claim"):
			continue
		if u.state != CargoUnit.State.INBOUND and u.state != CargoUnit.State.STORED:
			continue
		var rec: Variant = _seen.get(u)
		if rec == null:
			continue
		var age: float = clock - float(rec[1])
		if age < DutyConfig.SCAN_AFTER:
			continue
		if u.has_meta(&"scanned_at") and clock - float(u.get_meta(&"scanned_at")) < DutyConfig.RESCAN_AFTER:
			continue
		var spot: Array = scan_spot(s)
		if spot.is_empty() or area_busy(spot[0]):
			continue
		var sc: float = 0.5 + minf(age / 600.0, 0.2) - here.distance_to(spot[0]) * 0.008
		if sc > best_s:
			best_s = sc
			best = [sc, s, spot]
	return best


## Where to stand to scan the pallet in `s`: [position, yaw] or [].
func scan_spot(s: StorageSlot) -> Array:
	var target: Vector2 = Vector2(s.position.x, s.position.z)
	var od: Vector2 = Vector2(s.out_dir.x, s.out_dir.z).normalized()
	var p: Vector2
	if s.zone == StorageSlot.Zone.INBOUND or s.zone == StorageSlot.Zone.OUTBOUND:
		# from the zone's closed side (the forklifts come in from the open side)
		var r: Rect2 = grid.inbound_rect if s.zone == StorageSlot.Zone.INBOUND else grid.outbound_rect
		var edge: float = INF
		for c: Vector2 in [r.position, r.end, Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.position.y)]:
			edge = minf(edge, c.dot(od))
		p = target - od * (target.dot(od) - edge + 0.6)
	else:
		p = target + od * 1.25
	if not nav.walkable(p):
		p = nav.nearest_walkable(p, 0.8)
		if not nav.walkable(p):
			return []
	return [p, WorkerActor.yaw_towards(p, target)]


func note_scan(_u: CargoUnit, _w: WorkerActor) -> void:
	scans += 1


# --- rounds ---------------------------------------------------------------------------------

func _rack_round(_here: Vector2) -> Array:
	var faces: Dictionary = {}
	for s: StorageSlot in grid.slots:
		if s.zone != StorageSlot.Zone.RACK or s.level != 0:
			continue
		var l: Traffic.ZoneLock = traffic.lock_for(s)
		if l == null:
			continue
		if not faces.has(l):
			faces[l] = []
		(faces[l] as Array).append(s)
	for l: Traffic.ZoneLock in faces.keys():
		if l.holder != null or l.has_meta(&"inspected_by"):
			continue
		if not _round_due.has(l.key):
			_round_due[l.key] = clock + _rng.randf_range(30.0, 200.0)
		if clock < float(_round_due[l.key]):
			continue
		var slots: Array = faces[l]
		var pts: Array = []
		var step: int = maxi(1, slots.size() / 3)
		for i: int in range(0, slots.size(), step):
			var spot: Array = scan_spot(slots[i])
			if not spot.is_empty():
				pts.append(spot)
			if pts.size() >= 3:
				break
		if pts.size() < 2:
			continue
		var key: String = l.key
		var lock: Traffic.ZoneLock = l
		return [func() -> Duty:
			if lock.holder != null:
				return null
			_round_due[key] = clock + DutyConfig.RACK_ROUND_EVERY
			return InspectionRound.new(pts, lock, "Rack inspection")]
	return []


func _make_safety_round(w: WorkerActor) -> Duty:
	var pts: Array = []
	var pool: Array = _safety_points.filter(func(p: Array) -> bool: return point_free(p[0], w))
	pool.shuffle()
	# two checkpoints, not too far from here and not next to each other
	pool.sort_custom(func(a: Array, b: Array) -> bool: return (a[0] as Vector2).distance_to(w.pos2()) < (b[0] as Vector2).distance_to(w.pos2()))
	var near: Array = pool.slice(0, 8).filter(func(p: Array) -> bool: return (p[0] as Vector2).distance_to(w.pos2()) < 16.0)
	near.shuffle()
	for p: Array in near:
		if pts.size() >= 2:
			break
		if pts.is_empty() or (pts[0][0] as Vector2).distance_to(p[0]) > 5.0:
			if (p[0] as Vector2).distance_to(w.pos2()) > 1.5:
				pts.append(p)
	if pts.size() < 2:
		return null
	return InspectionRound.new(pts, null, "Safety round")


## Checkpoints people are heading for or standing at: one person each.
var claimed_points: Dictionary = {}  ## Vector2 -> WorkerActor


func point_free(p: Vector2, me: WorkerActor) -> bool:
	for q: Vector2 in claimed_points.keys():
		if claimed_points[q] != me and is_instance_valid(claimed_points[q]) and q.distance_to(p) < 1.6:
			return false
	for o: WorkerActor in workers:
		if o != me and o.pos2().distance_to(p) < 1.3:
			return false
	return true


func claim_points(pts: Array, me: WorkerActor) -> void:
	for p: Array in pts:
		claimed_points[p[0]] = me


func release_points(me: WorkerActor) -> void:
	for q: Vector2 in claimed_points.keys():
		if claimed_points[q] == me:
			claimed_points.erase(q)


## Spots along walls and racks, outside every forklift area: [position, yaw].
func _find_safety_points() -> Array:
	var out: Array = []
	var c: Vector2 = Vector2.ZERO
	for x: float in range(-26, 24, 2):
		for z: float in range(-28, 2, 2):
			var p: Vector2 = Vector2(x + 0.5, z + 0.5)
			if not nav.idle_safe(p) or not nav.reachable(p):
				continue
			# near an obstacle (wall, rack, decor): something to check
			var near: Vector2 = Vector2.INF
			for i: int in traffic.statics_near(Rect2(p, Vector2.ZERO).grow(1.4)):
				var r: Rect2 = traffic.statics[i]
				var q: Vector2 = Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
				if q.distance_to(p) < 1.4 and (near == Vector2.INF or q.distance_to(p) < near.distance_to(p)):
					near = q
			if near == Vector2.INF:
				continue
			if break_area != null and p.distance_to(break_area.group_center()) < 4.0:
				continue
			if not clear_of_spots(p, 1.5):
				continue
			out.append([p, WorkerActor.yaw_towards(p, near)])
	return out


## Somewhere out of the way near the worker for a call or a stretch.
func _quiet_spot(w: WorkerActor) -> Array:
	var here: Vector2 = w.pos2()
	if nav.idle_safe(here) and clear_of_spots(here, 1.3) and _alone(here, w):
		return [here, w.yaw()]
	for r: float in [1.0, 2.0, 3.0, 4.5, 6.0]:
		for k: int in 12:
			var q: Vector2 = here + Vector2.from_angle(k * TAU / 12.0) * r
			if nav.idle_safe(q) and clear_of_spots(q, 1.3) and _alone(q, w):
				return [q, w.yaw()]
	return [nav.nearest_walkable(here, 6.0, true), w.yaw()]


func _alone(q: Vector2, me: WorkerActor) -> bool:
	for o: WorkerActor in workers:
		if o != me and o.pos2().distance_to(q) < 1.3:
			return false
	return true


func _random_floor_point() -> Vector2:
	for i: int in 40:
		var p: Vector2 = Vector2(_rng.randf_range(-22.0, 18.0), _rng.randf_range(-25.0, -2.0))
		if nav.walkable(p) and nav.reachable(p) and nav.walkable(p + Vector2(1.5, 0.0)) and nav.walkable(p - Vector2(1.5, 0.0)):
			return p
	return Vector2.INF


# --- world events ---------------------------------------------------------------------------

func _forklift_dirt() -> void:
	for f: ForkliftCarrier in _odometer.keys():
		var d: float = f.odometer - float(_odometer[f])
		if d < DutyConfig.DIRT_DRIVE_INTERVAL * 1.2:
			continue
		_odometer[f] = f.odometer
		if _rng.randf() < 0.6 and nav.walkable(f._pos) and nav.reachable(f._pos):
			dirt.add_dirt(f._pos, _rng.randf() < DutyConfig.SPILL_CHANCE)


func _on_unit_placed(job: CarryJob) -> void:
	var s: StorageSlot = job.to_slot
	if s == null or s.is_trailer() or _rng.randf() > DutyConfig.DIRT_SETDOWN_CHANCE:
		return
	var p3: Vector3 = s.position + s.out_dir * 1.6
	var p: Vector2 = Vector2(p3.x, p3.z)
	if nav.walkable(p) and nav.reachable(p):
		dirt.add_dirt(p, _rng.randf() < DutyConfig.SPILL_CHANCE * 0.5)


func _on_reverse_started(dock_id: int) -> void:
	for b: TrailerBay in grid.bays:
		if b.dock != null and b.dock.dock_id == dock_id:
			_greet_wanted[b] = clock
			# a bound method, not a lambda capturing the bay: the dock may
			# outlive the bay on teardown
			var cb: Callable = _on_greet_dock_state.bind(b)
			if not b.dock.state_changed.is_connected(cb):
				b.dock.state_changed.connect(cb)


func _on_greet_dock_state(st: Dock.State, b: Variant) -> void:
	if st != Dock.State.IDLE:
		return
	_greet_wanted.erase(b)
	if is_instance_valid(b):
		var bay: TrailerBay = b as TrailerBay
		var cb: Callable = _on_greet_dock_state.bind(b)
		if bay.dock != null and bay.dock.state_changed.is_connected(cb):
			bay.dock.state_changed.disconnect(cb)


## Beside the dock door inside the hall, clear of the lane and the truck.
func _greet_spot(bay: TrailerBay) -> Array:
	if bay.has_meta(&"greet_spot"):
		return bay.get_meta(&"greet_spot")
	var door: Vector3 = bay.lane_point(5.0, 0.0)
	for s: float in [2.2, 1.7, 1.2]:
		for off: float in [3.0, -3.0, 3.5, -3.5, 4.0, -4.0]:
			var p3: Vector3 = bay.lane_point(s, off)
			var p: Vector2 = Vector2(p3.x, p3.z)
			if not nav.walkable(p) or not nav.reachable(p):
				continue
			var clear: bool = true
			for lb: FootprintBox in traffic._lane_boxes():
				if FootprintBox.set_distance([lb], [FootprintBox.make(p, Vector2.RIGHT, 0.3, 0.3)]) < 1.1:
					clear = false
			if not clear:
				continue
			var spot: Array = [p, WorkerActor.yaw_towards(p, Vector2(door.x, door.z))]
			bay.set_meta(&"greet_spot", spot)
			return spot
	return []


func _on_hold_wanted(agent: CarryAgent) -> void:
	for w: WorkerActor in workers:
		var d: ServiceForklift = w.duty as ServiceForklift
		if d != null and d.lift == agent:
			d.on_hold_wanted()
			return
	# nobody is there (any more): let it go
	board.release_hold(agent, null)


# --- props (called by duties and workers) -------------------------------------------------

func claim_prop(kind: StringName, by: Object) -> PropItem:
	return store.claim(kind, by)


func wrench_for(box: PropItem) -> PropItem:
	return store.wrench_for(box)


func prop_stand_spot(p: PropItem) -> Array:
	return store.stand_spot(p)


func prop_placed(p: PropItem) -> void:
	store.placed(p)


func prop_lifted(p: PropItem) -> void:
	store.lifted(p)


func add_return_steps(d: Duty, p: PropItem) -> void:
	store.add_return_steps(d, p)


func drop_here(w: WorkerActor, p: PropItem) -> void:
	store.drop_here(w, p)


func new_cup(xf: Transform3D) -> PropItem:
	return store.new_cup(xf)


func bin_cup(c: PropItem) -> void:
	store.bin_cup(c)


## Spots people walk up to (machine, bin, seats, circle, tool rack): nobody
## waits or steps aside on them.
func keep_clear_points() -> Array[Vector2]:
	if not _keep_clear.is_empty():
		return _keep_clear
	if break_area != null:
		for m: String in ["CoffeeSpot", "WaterSpot", "TrashSpot"]:
			_keep_clear.append(BreakArea.flat(break_area.get_node(m) as Node3D))
		for s: Dictionary in break_area.seats:
			_keep_clear.append(seat_approach(s))
		for i: int in group.slots.size():
			_keep_clear.append(group.place(i)[0])
	if corner != null:
		for k: StringName in [&"broom", &"bucket", &"sign", &"toolbox"]:
			_keep_clear.append(corner.stand_spot(k)[0])
	return _keep_clear


func in_break_area(q: Vector2) -> bool:
	if break_area == null:
		return false
	for r: Rect2 in break_area.floor_rects():
		if r.has_point(q):
			return true
	return false


func clear_of_spots(q: Vector2, r: float) -> bool:
	for c: Vector2 in keep_clear_points():
		if c.distance_to(q) < r:
			return false
	return true


## A place to wait near `p` (a busy spot): one of the break area's queue
## spots when one is free, else somewhere walkable, out of the way, clear
## of others.
func wait_point_near(p: Vector2, me: WorkerActor) -> Vector2:
	if break_area != null and in_break_area(p) and p.distance_to(break_area.group_center()) < 6.0:
		var best_q: Vector2 = Vector2.INF
		for m: String in ["Queue1", "Queue2"]:
			var n: Node3D = break_area.get_node_or_null(m) as Node3D
			if n == null:
				continue
			var q: Vector2 = BreakArea.flat(n)
			if not _alone(q, me) or not point_free(q, me):
				continue
			if best_q == Vector2.INF or q.distance_to(me.pos2()) < best_q.distance_to(me.pos2()):
				best_q = q
		if best_q != Vector2.INF:
			claim_points([[best_q]], me)
			return best_q
	var best: Vector2 = me.pos2()
	var best_s: float = INF
	for r: float in [1.5, 1.9, 2.4, 3.0]:
		for k: int in 12:
			var q: Vector2 = p + Vector2.from_angle(k * TAU / 12.0) * r
			if not nav.walkable(q) or not clear_of_spots(q, 1.2):
				continue
			var clear: bool = true
			for w: WorkerActor in workers:
				if w != me and w.pos2().distance_to(q) < 1.1:
					clear = false
					break
			if not clear:
				continue
			var sc: float = r + (0.0 if nav.idle_safe(q) or in_break_area(q) else 1.5) + q.distance_to(me.pos2()) * 0.05
			if sc < best_s:
				best_s = sc
				best = q
	return best


## Somewhere in the break area to stand with a drink, clear of the others.
func drink_spot(me: WorkerActor) -> Array:
	var c: Vector2 = break_area.group_center() if break_area != null else me.pos2()
	var p: Vector2 = wait_point_near(c, me)
	return [p, WorkerActor.yaw_towards(p, c)]


## Where to stand before sitting down: beside the chair, on the open side.
func seat_approach(seat: Dictionary) -> Vector2:
	var pos: Vector2 = seat.pos
	var side: Vector2 = (seat.front as Vector2).orthogonal()
	for p: Vector2 in [pos + side * 0.6, pos - side * 0.6, pos + (seat.front as Vector2) * 0.55]:
		if nav.walkable(p):
			return p
	return pos + side * 0.6


func leave_seat(w: WorkerActor) -> void:
	if break_area != null:
		for s: Dictionary in break_area.seats:
			if s.taken_by == w:
				s.taken_by = null
	w.seat = null


# --- for the Staff panel and tests --------------------------------------------------------

## One row per worker: name, duty, what they do now, needs.
func staff_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for w: WorkerActor in workers:
		var d: Duty = w.duty as Duty
		var duty_text: String = "Carry job" if w.is_on_job() else (d.title if d != null else "Choosing")
		var status: String = w.activity_text()
		if status.is_empty() and d != null:
			status = d.status
		out.append({"name": w.display_name, "duty": duty_text, "status": status, "tired": w.tired, "thirst": w.thirst, "social": w.social})
	if board != null:
		for jc: JackCarrier in board.jacks():
			out.append({"name": jc.worker_name, "duty": JackCarrier.ROLE_TITLE, "status": jc.status_text(), "tired": 0.0, "thirst": 0.0, "social": 0.0})
	return out
