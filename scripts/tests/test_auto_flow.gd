extends SceneTree
## Headless test of the auto fallbacks in main.tscn: accept a contract and
## never give a manual order. Every pallet must still pass
## INBOUND -> PUTAWAY -> STORED (at least one by the Jack operator on a rack
## L1 or floor slot) -> PICKING -> OUTBOUND -> LOADED -> DELIVERED, and the
## contract must complete. Also checks the Jack operator is in the Staff rows.
## Godot --headless --path . --fixed-fps 60 -s res://scripts/tests/test_auto_flow.gd

const SPEED: int = 30
const STEP_FRAMES: int = 9000
const PALLETS: int = 6

var _failures: int = 0
var _contract: Contract = null
var _board: Node = null
var _jack_moves: PackedStringArray = PackedStringArray()
var _jack_speed_max: float = 0.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gs: Node = root.get_node(^"GameState")
	gs.speed = SPEED
	gs.minutes_per_second = 1.0 / 60.0
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var flow: Node = get_first_node_in_group(&"cargo_flow")
	_board = get_first_node_in_group(&"job_board")
	if manager == null or flow == null or _board == null:
		_finish("missing gameplay nodes")
		return
	_check(flow.auto_flow, "auto flow on by default")
	var jacks: Array = _board.jacks()
	_check(jacks.size() == 1, "one Jack operator (%d)" % jacks.size())
	_board.unit_placed.connect(func(job: CarryJob) -> void:
		if job.unit.contract == _contract and job.kind == CarryJob.Kind.STORE and job.agent != null and String(job.agent.label).ends_with("(pallet jack)"):
			_jack_moves.append("%s->%s" % [job.unit.code, job.to_slot.label])
			_check(not job.to_slot.needs_lift(), "jack slot %s is ground level" % job.to_slot.label))
	gs.notice_posted.connect(func(title: String, body: String) -> void: print("  toast: %s - %s" % [title, body]))

	_contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": PALLETS, "storage_days": 1, "inbound_delay": 2.0})
	manager.add_available(_contract)
	var reason: String = manager.accept(_contract)
	_check(reason.is_empty(), "accept succeeds (%s)" % reason)
	var units: Array[CargoUnit] = _contract.units.duplicate()

	if not await _until(func() -> bool: return _contract.state == Contract.State.STORED, "contract STORED (no manual orders)"):
		return
	var planner: Node = get_first_node_in_group(&"duty_planner")
	if planner != null:
		var rows: Array = planner.call(&"staff_rows")
		var found: bool = rows.any(func(r: Dictionary) -> bool: return String(r.duty) == "Jack operator")
		_check(found, "Staff rows list the Jack operator")
	if not await _until(func() -> bool: return _contract.state == Contract.State.COMPLETED, "contract COMPLETED (auto outbound)", STEP_FRAMES * 2):
		return
	if not await _until(func() -> bool: return _contract.count_in(CargoUnit.State.DELIVERED) == PALLETS, "all DELIVERED"):
		return

	var want: Array[int] = []
	for st: int in CargoUnit.State.values():
		want.append(st)
	var by_jack: int = 0
	for u: CargoUnit in units:
		var states: Array[int] = []
		for e: Dictionary in u.history:
			if String(e.agent).begins_with("Scanned by") or String(e.agent).begins_with("Moved to clear path"):
				continue
			states.append(int(e.state))
		_check(states == want, "%s states %s" % [u.code, ", ".join(states.map(func(s: int) -> String: return CargoUnit.name_of(s as CargoUnit.State)))])
		var who: String = u.agent_for(CargoUnit.State.STORED)
		if who == "Put away by Worker 1 (pallet jack)":
			by_jack += 1
		else:
			_check(who.begins_with("Forklift 2"), "%s stored by %s" % [u.code, who])
	_check(by_jack >= 1, "at least one pallet put away by the jack (%d: %s)" % [by_jack, ", ".join(_jack_moves)])
	_check(_jack_speed_max <= 1.05, "jack worker speed max %.2f m/s" % _jack_speed_max)
	_finish("")


func _until(cond: Callable, what: String, limit: int = STEP_FRAMES) -> bool:
	var frames: int = 0
	while not cond.call():
		if frames >= limit:
			for a: Node in _board.agents:
				print("  agent: ", a.debug_state())
			_finish("timed out waiting for " + what)
			return false
		await process_frame
		for j: Node in _board.jacks():
			_jack_speed_max = maxf(_jack_speed_max, float(j.speed))
		frames += 1
	print("  ok   %s (%d frames)" % [what, frames])
	return true


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


func _finish(error: String) -> void:
	if not error.is_empty():
		push_error("test_auto_flow: " + error)
		_failures += 1
	print("test_auto_flow: PASS" if _failures == 0 else "test_auto_flow: FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)
