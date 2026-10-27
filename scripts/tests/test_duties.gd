extends SceneTree
## Headless test of the staff duty system in main.tscn over about two game
## hours (game seconds at the coming real-time clock: GameState runs at
## 1/60 game minute per second here). A contract brings a truck in, so the
## workers see a reversing truck, pallets in INBOUND and forklifts at work.
## Checks:
## - every worker is on a duty (or walking to one) >= 90% of the time, and
##   never stands about without a purpose for over 30 s outside breaks;
## - at least 4 duty types; a coffee break where >= 2 talk; a dirt spot cleaned;
## - never within 1.2 m of a moving forklift, never within 0.8 m of another
##   worker (0.7 m inside a conversation group), never inside a collider;
## - duties cut short (request_release, every few minutes) leave every prop
##   in a valid place; pallet scans show in the pallet history.
## Godot --headless --path . --fixed-fps 60 --script res://scripts/tests/test_duties.gd

const SPEED: int = 24
const GAME_SECONDS: float = 7200.0
const AIMLESS_LIMIT: float = 30.0

var _failures: int = 0
var _gs: Node = null
var _planner: Node = null
var _board: Node = null
var _traffic: Node = null
var _t: float = 0.0
var _duty_time: Dictionary = {}
var _total_time: float = 0.0
var _still: Dictionary = {}
var _worst_still: float = 0.0
var _worst_still_who: String = ""
var _min_fork: float = INF
var _min_fork_at: String = ""
var _min_person: float = INF
var _min_person_at: String = ""
var _min_group: float = INF
var _inside: int = 0
var _inside_at: String = ""
var _talk_seen: bool = false
var _talk_size: int = 0
var _released: int = 0
var _prop_errors: PackedStringArray = PackedStringArray()
var _kinds_seen: Dictionary = {}
var _next_release: float = 300.0
var _pending_checks: Array[float] = []
var _grouped: Dictionary = {}
var _idle_at: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_gs = root.get_node(^"GameState")
	_gs.speed = SPEED
	_gs.minutes_per_second = 1.0 / 60.0
	change_scene_to_file("res://scenes/main.tscn")
	for i: int in 4:
		await process_frame
	_planner = get_first_node_in_group(&"duty_planner")
	_board = get_first_node_in_group(&"job_board")
	_traffic = get_first_node_in_group(&"traffic")
	var manager: Node = get_first_node_in_group(&"contract_manager")
	if _planner == null or _board == null or _traffic == null or manager == null:
		_finish("missing nodes")
		return
	while not bool(_planner.get(&"ready_done")):
		await process_frame
	_planner.duty_started.connect(func(_w: Node, d: RefCounted) -> void: _kinds_seen[d.get(&"kind")] = true)
	_planner.duty_ended.connect(_on_duty_ended)
	var c: Contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": 6, "storage_days": 1, "inbound_delay": 5.0})
	manager.add_available(c)
	var reason: String = manager.accept(c)
	_check(reason.is_empty(), "contract accepted (%s)" % reason)
	var start_clock: float = float(_planner.get(&"clock"))
	var last_report: float = 0.0
	while float(_planner.get(&"clock")) - start_clock < GAME_SECONDS:
		await process_frame
		var now: float = float(_planner.get(&"clock")) - start_clock
		var dt: float = now - _t
		_t = now
		if dt <= 0.0:
			continue
		_measure(dt)
		while not _pending_checks.is_empty() and _pending_checks[0] <= _t:
			_pending_checks.remove_at(0)
			_prop_errors.append_array(_props_valid_now())
		if now >= _next_release:
			_next_release += 240.0
			_release_someone()
		if now - last_report >= 600.0:
			last_report = now
			_report(now)
	_report(_t)
	var workers: Array = _planner.get(&"workers")
	for w in workers:
		var share: float = float(_duty_time.get(w, 0.0)) / maxf(_total_time, 0.001)
		_check(share >= 0.9, "%s on a duty %.1f%% of the time" % [w.display_name, share * 100.0])
	var idle_keys: Array = _idle_at.keys()
	idle_keys.sort_custom(func(a: String, b: String) -> bool: return float(_idle_at[a]) > float(_idle_at[b]))
	for k: String in idle_keys.slice(0, 6):
		print("  no duty: %s %.0f s" % [k, float(_idle_at[k])])
	_check(_worst_still <= AIMLESS_LIMIT, "longest aimless standing %.1f s (%s)" % [_worst_still, _worst_still_who])
	var counts: Dictionary = _planner.get(&"started_counts")
	print("duties started: %s" % [counts])
	_check(counts.size() >= 4, "%d duty types" % counts.size())
	_check(_talk_seen, "a coffee break with >= 2 talking (largest group %d)" % _talk_size)
	var dirt = _planner.get(&"dirt")
	_check(dirt.cleaned_count >= 1, "%d dirt spots cleaned" % dirt.cleaned_count)
	_check(_min_fork >= 1.2, "closest to a moving forklift %.2f m (%s)" % [_min_fork, _min_fork_at])
	_check(_min_person >= 0.8, "closest two workers outside a group %.2f m (%s)" % [_min_person, _min_person_at])
	_check(_min_group >= 0.7, "closest two in a conversation group %.2f m" % _min_group)
	_check(_inside == 0, "workers inside a collider: %d samples (%s)" % [_inside, _inside_at])
	_check(_released >= 3, "%d duties cut short" % _released)
	_check(_prop_errors.is_empty(), "props in a valid place after interrupts %s" % [_prop_errors])
	_check(_props_valid_now().is_empty(), "props valid at the end %s" % [_props_valid_now()])
	var scanned: int = 0
	for u: CargoUnit in c.units:
		for e: Dictionary in u.history:
			if String(e.agent).begins_with("Scanned by"):
				scanned += 1
				print("  history %s: %s %s %s" % [u.code, PalletLog.format_entry_time(e), CargoUnit.name_of(int(e.state)), e.agent])
	_check(scanned >= 1, "%d scans in pallet histories" % scanned)
	_finish("")


func _measure(dt: float) -> void:
	_total_time += dt
	var workers: Array = _planner.get(&"workers")
	var lifts: Array = _board.call(&"forklifts")
	var group = _planner.get(&"group")
	for w in workers:
		var d = w.duty
		if d != null or w.is_on_job():
			_duty_time[w] = float(_duty_time.get(w, 0.0)) + dt
		else:
			var k: String = "%s %s" % [w.display_name, (w.pos2()).round()]
			_idle_at[k] = float(_idle_at.get(k, 0.0)) + dt
		# standing without a purpose: no duty, or a work duty showing only Idle
		var aimless: bool = d == null or (not d.is_break and not w.is_walking() and w.current_action == &"Idle" and not w.is_busy_motor())
		if w.is_on_job() or w.is_yielding():
			aimless = false
		_still[w] = (float(_still.get(w, 0.0)) + dt) if aimless else 0.0
		if float(_still[w]) > _worst_still:
			_worst_still = float(_still[w])
			var cur = d.get(&"_cur") if d != null else null
			_worst_still_who = "%s at %s, duty %s / %s (mode %d motor %d step t %.1f, yielding %s, t=%.0f)" % [w.display_name, w.pos2(), d.title if d != null else "-", d.status if d != null else "-", w._mode, w.motor, cur.t if cur != null else -1.0, w.is_yielding(), _t]
		if w.is_on_job():
			continue
		var mine: Array = w.traffic_footprints()
		for f in lifts:
			if f.speed > 0.05:
				var dd: float = FootprintBox.set_distance(mine, f.traffic_footprints())
				if dd < _min_fork:
					_min_fork = dd
					_min_fork_at = "%s and %s at %s, t=%.0f" % [w.display_name, f.label, w.pos2(), _t]
		for o in workers:
			if o == w or o.staff_id < w.staff_id or o.is_on_job():
				continue
			var cd: float = w.pos2().distance_to(o.pos2())
			var pair: String = "%d-%d" % [w.staff_id, o.staff_id]
			if w.group != null and w.group == o.group:
				_grouped[pair] = _t
			if float(_grouped.get(pair, -100.0)) > _t - 8.0:
				# in one conversation group (or just breaking up)
				_min_group = minf(_min_group, cd)
			elif cd < _min_person:
				_min_person = cd
				_min_person_at = "%s (%s) and %s (%s) at %s, t=%.0f" % [w.display_name, w.duty.get(&"status") if w.duty != null else "-", o.display_name, o.duty.get(&"status") if o.duty != null else "-", w.pos2(), _t]
		var skip: Array = []
		if w.seat != null:
			# the chair the worker sits on (and its back)
			var sp: Vector2 = Vector2(w.seat.global_position.x, w.seat.global_position.z)
			for i: int in _traffic.statics_near(Rect2(sp, Vector2.ZERO).grow(1.0)):
				if _traffic.statics[i].grow(0.35).has_point(sp):
					skip.append(_traffic.statics[i])
		var hit: int = _overlap(w, skip)
		if hit >= 0:
			_inside += 1
			if _inside_at.is_empty():
				_inside_at = "%s in %s at %s (%s), t=%.0f" % [w.display_name, _traffic.static_names[hit], w.pos2(), w.duty.get(&"status") if w.duty != null else "-", _t]
	if group != null:
		var here: Array = group.present()
		if here.size() >= 2:
			_talk_size = maxi(_talk_size, here.size())
			for w in here:
				if w.current_action == &"Talk":
					_talk_seen = true


## Static the worker's body overlaps by more than a few cm, or -1.
func _overlap(w, skip: Array) -> int:
	var me: FootprintBox = FootprintBox.make(w.pos2(), Vector2.RIGHT, 0.2, 0.2)
	for i: int in _traffic.statics_near(me.bounds().grow(0.5)):
		var r: Rect2 = _traffic.statics[i]
		if r in skip:
			continue
		if me.overlaps(FootprintBox.from_rect(r), 0.0):
			return i
	return -1


func _release_someone() -> void:
	var workers: Array = _planner.get(&"workers")
	var busy: Array = workers.filter(func(w) -> bool: return w.duty != null and not w.duty.aborting and not w.held_props().is_empty())
	if busy.is_empty():
		busy = workers.filter(func(w) -> bool: return w.duty != null and not w.duty.aborting)
	if busy.is_empty():
		return
	var w = busy[randi() % busy.size()]
	var urgent: bool = _released % 2 == 1
	print("  t=%.0f release %s from %s (%s)%s" % [_t, w.display_name, w.duty.title, w.duty.status, " urgent" if urgent else ""])
	w.duty.set_meta(&"released", true)
	if _planner.call(&"request_release", w, urgent):
		_released += 1


func _on_duty_ended(w, d) -> void:
	if not d.has_meta(&"released"):
		return
	# hands empty but for the belt kit, and every prop somewhere sensible
	# (once the last prop has settled)
	for p: PropItem in w.held_props():
		if w.kit.get(p.kind) != p:
			_prop_errors.append("%s still holds the %s after %s" % [w.display_name, p.kind, d.title])
	_pending_checks.append(_t + 2.0)


func _props_valid_now() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var store = _planner.get(&"store")
	for p: PropItem in store.props:
		if not is_instance_valid(p) or not p.is_inside_tree():
			out.append("a %s left the scene" % p.kind if is_instance_valid(p) else "a freed prop")
			continue
		if not p.visible and p.where != PropItem.Where.BINNED:
			out.append("%s hidden" % p.kind)
		match p.where:
			PropItem.Where.HELD:
				if p.holder == null:
					out.append("%s held by nobody" % p.kind)
			PropItem.Where.HOME:
				if p.get_parent() != p.home_parent and p.kind != &"wrench":
					out.append("%s home but not on its shelf" % p.kind)
			PropItem.Where.LOOSE, PropItem.Where.PLACED:
				if p.global_position.y > 0.3 or p.global_position.y < -0.05:
					out.append("%s floating at %.2f m" % [p.kind, p.global_position.y])
	return out


func _report(now: float) -> void:
	var rows: Array = _planner.call(&"staff_rows")
	print("[t=%5.0f] %s" % [now, " | ".join(rows.map(func(r: Dictionary) -> String: return "%s: %s" % [String(r.name).replace("Worker ", "W"), r.duty]))])


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   " + what)
	else:
		_failures += 1
		print("  FAIL " + what)


func _finish(error: String) -> void:
	if not error.is_empty():
		_failures += 1
		push_error("test_duties: " + error)
	print("test_duties: %s (%d)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)
