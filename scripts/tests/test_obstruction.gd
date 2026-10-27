extends SceneTree
## Headless test of the "never block, clear what blocks you" rule on
## main.tscn:
## - a pallet (B) is seeded where it blocks another one's way in: in front
##   of A in the same INBOUND column (INBOUND-05 in front of INBOUND-12);
## - A is sent to the rack: the Rack forklift finds B in its approach, moves
##   B to a slot where it blocks nobody (same lifecycle state, logged in B's
##   history as moved to clear the path), then stores A;
## - B is stored too and the contract runs to the end (pickup, loading,
##   delivery);
## - every frame: no forklift waits (blocked, or queuing for a lock) longer
##   than MAX_BLOCKED, and every pallet is somewhere: in a slot that holds
##   it, on a forklift's forks, or delivered.
## Godot --headless --path . --fixed-fps 60 --script res://scripts/tests/test_obstruction.gd

const SPEED: int = 30
const STEP_FRAMES: int = 9000
## Longest a forklift may wait on anyone (game seconds).
const MAX_BLOCKED: float = 60.0

var _failures: int = 0
var _board: Node = null
var _grid: Node = null
var _contract: Contract = null
var _worst_wait: float = 0.0
var _worst_wait_who: String = ""
var _lost: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gs: Node = root.get_node(^"GameState")
	gs.speed = SPEED
	gs.minutes_per_second = 1.0 / 60.0  # real-time clock: 1 game second per real second at 1x
	change_scene_to_file("res://scenes/main.tscn")
	for i: int in 4:
		await process_frame
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var flow: Node = get_first_node_in_group(&"cargo_flow")
	_grid = get_first_node_in_group(&"storage_grid")
	_board = get_first_node_in_group(&"job_board")
	if manager == null or flow == null or _grid == null or _board == null:
		_finish("missing gameplay nodes")
		return

	# seed: A deep in an INBOUND column, B in front of it
	_contract = manager.make_contract(ContractCatalog.find("QuickShip"), {"pallets": 2, "storage_days": 1})
	manager.adopt(_contract, Contract.State.INBOUND)
	var a: CargoUnit = _contract.units[0]
	var b: CargoUnit = _contract.units[1]
	var deep: StorageSlot = _slot("INBOUND-12")
	var front: StorageSlot = _slot("INBOUND-05")
	for u: CargoUnit in [a, b]:
		PalletLog.stamp(u, CargoUnit.State.IN_TRUCK, "T-Dock1-%02d" % (u.index + 1))
		PalletLog.stamp(u, CargoUnit.State.UNLOADING, "Forklift 1 (Unloader)", "Forklift 1 (Unloader)")
	flow._put(a, deep, CargoUnit.State.INBOUND, "Forklift 1 (Unloader)")
	flow._put(b, front, CargoUnit.State.INBOUND, "Forklift 1 (Unloader)")
	_check(front in _grid.obstructions(deep, a), "%s in front of %s blocks its way in" % [front.label, deep.label])

	# A to the rack: B has to be moved first
	var targets: Array[StorageSlot] = _grid.store_targets()
	_check(targets.size() >= 2, "two rack slots free (%d)" % targets.size())
	var reason: String = flow.order_store(a, targets[0])
	_check(reason.is_empty(), "store order %s -> %s (%s)" % [a.code, targets[0].label, reason])
	if not await _until(func() -> bool: return a.state == CargoUnit.State.STORED, "%s stored" % a.code):
		return
	var moved: Array = b.history.filter(func(e: Dictionary) -> bool: return String(e.agent).begins_with("Moved to clear path by Forklift"))
	_check(moved.size() == 1, "%s history has one 'moved to clear path' entry (%d)" % [b.code, moved.size()])
	if not moved.is_empty():
		var e: Dictionary = moved[0]
		print("  %s: %s @ %s by %s" % [b.code, CargoUnit.name_of(int(e.state) as CargoUnit.State), e.location, e.agent])
		_check(int(e.state) == CargoUnit.State.INBOUND, "the move kept %s INBOUND" % b.code)
	_check(b.state == CargoUnit.State.INBOUND and b.slot != null and b.slot != front and b.location_code == b.slot.label, "%s now in %s (%s)" % [b.code, b.location_code, b.state_name()])
	if b.slot != null:
		_check(b.node != null and b.node.global_position.distance_to(b.slot.position) < 0.05, "%s 3D pallet at its new slot" % b.code)
		_check(b.slot.zone == StorageSlot.Zone.INBOUND, "%s stayed in INBOUND (proper area for its state)" % b.code)
		_check(_grid.placement_ok(b.slot, b), "%s's new slot blocks nobody" % b.code)
	_check(a.slot == targets[0], "%s in %s" % [a.code, targets[0].label])

	# B to the rack too, then the contract runs to the end
	targets = _grid.store_targets()
	reason = flow.order_store(b, targets[0])
	_check(reason.is_empty(), "store order %s -> %s (%s)" % [b.code, targets[0].label, reason])
	if not await _until(func() -> bool: return _contract.state == Contract.State.PICKUP_SCHEDULED, "pickup scheduled"):
		return
	_check(flow.order_outbound(_contract) == 2, "both pallets sent to OUTBOUND")
	if not await _until(func() -> bool: return _contract.count_in(CargoUnit.State.DELIVERED) == 2, "both pallets DELIVERED"):
		return
	_check(_contract.state == Contract.State.COMPLETED, "contract completed")
	_finish("")


func _slot(label: String) -> StorageSlot:
	for s: StorageSlot in _grid.slots:
		if s.label == label:
			return s
	return null


## Every frame: forklift waits, and every pallet accounted for.
func _monitor() -> void:
	for f: Node in _board.forklifts():
		var waited: float = maxf(float(f.blocked_time), float(f.lock_wait_time))
		if waited > _worst_wait:
			_worst_wait = waited
			_worst_wait_who = f.debug_state()
	for u: CargoUnit in _contract.units:
		var ok: bool = false
		if u.state == CargoUnit.State.DELIVERED:
			ok = u.slot == null
		elif u.is_carried() or (u.job != null and (u.job as CarryJob).kind == CarryJob.Kind.RELOCATE and u.slot == null):
			ok = u.node != null and _on_a_forklift(u.node)
		else:
			ok = u.slot != null and u.slot.unit == u and u.node != null and u.location_code == u.slot.label
		if not ok and _lost.size() < 5:
			_lost.append("%s %s at %s (slot %s, node %s)" % [u.code, u.state_name(), u.location_code, u.slot.label if u.slot != null else "none", u.node.get_path() if u.node != null and u.node.is_inside_tree() else "none"])


func _on_a_forklift(node: Node) -> bool:
	for f: Node in _board.forklifts():
		if f.body.is_ancestor_of(node):
			return true
	return false


func _until(cond: Callable, what: String, limit: int = STEP_FRAMES) -> bool:
	var frames: int = 0
	while not cond.call():
		if frames >= limit:
			for f: Node in _board.agents:
				print("  agent: ", f.debug_state())
			_check(false, "%s within %d frames" % [what, limit])
			_finish("timed out waiting for " + what)
			return false
		await process_frame
		_monitor()
		frames += 1
	print("  ..   %s (%d frames)" % [what, frames])
	return true


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


func _finish(error: String) -> void:
	_check(_worst_wait <= MAX_BLOCKED, "no forklift waited over %.0f s (longest %.1f s: %s)" % [MAX_BLOCKED, _worst_wait, _worst_wait_who])
	_check(_lost.is_empty(), "every pallet always in a slot, on the forks or delivered %s" % [_lost])
	if not error.is_empty():
		push_error("test_obstruction: " + error)
		_failures += 1
	print("test_obstruction: PASS" if _failures == 0 else "test_obstruction: FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)
