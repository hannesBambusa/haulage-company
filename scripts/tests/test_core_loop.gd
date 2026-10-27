extends SceneTree
## Headless test of the core loop in main.tscn, through the same APIs the UI
## and click handler use, following every pallet's lifecycle:
## blocked accept -> accept -> inbound truck arrives loaded -> forklifts carry
## each pallet out of the trailer to INBOUND (dock counts on set-down) ->
## put-away orders (rack only, forklift) -> stored, storage fee accrues ->
## pickup scheduled -> picking to OUTBOUND -> the Loader forklift fills the
## pickup trailer -> completed and paid -> truck leaves -> every pallet
## DELIVERED. Three forklifts, one per role: Unloader, Rack, Loader.
## Asserts per pallet: the exact state sequence with nothing skipped, one
## history entry per transition with increasing timestamps, which role
## carried each leg, the trailer -> carrier -> INBOUND and OUTBOUND -> carrier -> trailer
## paths, dock progress only on set-down, and never two agents in one trailer.
## Godot --headless --path . --fixed-fps 60 --script res://scripts/tests/test_core_loop.gd

const SPEED: int = 30
const STEP_FRAMES: int = 6000
const PALLETS: int = 6

var _events: PackedStringArray = PackedStringArray()
var _failures: int = 0
var _contract: Contract = null
## Per-unit list of "kind:from_zone>to_zone:agent_class:holder_ok" legs.
var _legs: Dictionary = {}
var _progress_errors: PackedStringArray = PackedStringArray()
var _trailer_overlaps: int = 0
var _max_in_trailer: int = 0
var _outside: int = 0
var _board: Node = null
var _flow: Node = null


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# untyped nodes: these scripts use the GameState autoload, which --script
	# mode only registers after this test script has compiled
	var gs: Node = root.get_node(^"GameState")
	gs.speed = SPEED
	gs.minutes_per_second = 1.0 / 60.0  # real-time clock: 1 game second per real second at 1x
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var manager: Node = get_first_node_in_group(&"contract_manager")
	_flow = get_first_node_in_group(&"cargo_flow")
	var grid: Node = get_first_node_in_group(&"storage_grid")
	_board = get_first_node_in_group(&"job_board")
	var sim: Node = get_first_node_in_group(&"terminal_sim")
	if manager == null or _flow == null or grid == null or _board == null or sim == null:
		_finish("missing gameplay nodes")
		return
	manager.contract_state_changed.connect(func(c: Contract) -> void:
		if c == _contract:
			_event("contract %s" % c.state_name()))
	gs.notice_posted.connect(func(title: String, _body: String) -> void: _event("toast '%s'" % title))
	_board.job_started.connect(func(job: CarryJob) -> void:
		if job.unit.contract == _contract:
			_event("job start %s %s by %s -> %s" % [CarryJob.Kind.keys()[job.kind], job.unit.code, job.agent.label if job.agent != null else "?", job.to_slot.label]))
	_board.unit_picked.connect(_on_picked)
	_board.unit_placed.connect(_on_placed)
	for dock: Dock in sim.docks:
		dock.state_changed.connect(func(s: Dock.State) -> void:
			if dock.contract == _contract or s == Dock.State.IDLE:
				_event("dock %d %s" % [dock.dock_id, Dock.State.keys()[s]]))
		dock.progress_changed.connect(_on_progress.bind(dock))
	var forklifts: Array = _board.forklifts()
	_check(forklifts.size() == 3, "three forklifts (%d)" % forklifts.size())
	var roles: Array = forklifts.map(func(f: Node) -> String: return f.label)
	_check(roles == ["Forklift 1 (Unloader)", "Forklift 2 (Rack)", "Forklift 3 (Loader)"], "forklift roles %s" % [roles])
	var money_start: int = gs.money

	# 1. accept is blocked when one trailer cannot carry the contract
	var big: Contract = manager.make_contract(ContractCatalog.find("HomeStyle"), {"pallets": GameplayConfig.TRAILER_CAPACITY + 1})
	manager.add_available(big)
	var reason: String = manager.accept(big)
	_event("accept %d pallets: '%s'" % [big.pallets, reason])
	_check(not reason.is_empty(), "accept blocked for %d pallets" % big.pallets)
	_check(big.state == Contract.State.AVAILABLE and sim.pending_visits() == 0, "blocked contract stays AVAILABLE, no truck")

	# 2. accept a 6-pallet contract
	_contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": PALLETS, "storage_days": 1, "inbound_delay": 5.0})
	manager.add_available(_contract)
	var free: int = manager.free_capacity()
	reason = manager.accept(_contract)
	_check(reason.is_empty(), "accept succeeds (%s)" % reason)
	_check(sim.pending_visits() == 1, "inbound truck scheduled")
	_check(manager.free_capacity() == free - PALLETS, "6 spaces reserved (free capacity %d)" % manager.free_capacity())
	var units: Array[CargoUnit] = _contract.units.duplicate()
	var codes: Dictionary = {}
	for u: CargoUnit in units:
		codes[u.code] = true
		_check(u.code.begins_with("PL-") and u.code.length() == 9, "%s is a PL-###### id" % u.code)
	_check(codes.size() == PALLETS, "pallet ids unique")

	# 3. the truck arrives with the pallets visible on its trailer slots
	if not await _until(func() -> bool: return _contract.count_in(CargoUnit.State.IN_TRUCK) == PALLETS and units[0].slot != null, "pallets on the trailer"):
		return
	for u: CargoUnit in units:
		_check(u.slot.is_trailer() and u.node != null and u.node.get_parent() == u.slot.anchor, "%s on trailer slot %s, parented to the trailer" % [u.code, u.location_code])
	_check(units[0].location_code.begins_with("T-Dock"), "trailer location code %s" % units[0].location_code)

	# 4. forklifts unload into INBOUND
	if not await _until(func() -> bool: return _contract.count_in(CargoUnit.State.INBOUND) == PALLETS, "6 pallets in INBOUND"):
		return
	for u: CargoUnit in units:
		_check(u.slot != null and u.slot.zone == StorageSlot.Zone.INBOUND and u.location_code.begins_with("INBOUND-"), "%s in %s" % [u.code, u.location_code])

	# 5. put-away: racks only (one upper level), the floor is overflow
	var racks: Array[StorageSlot] = grid.store_targets()
	_check(not racks.is_empty() and racks.all(func(s: StorageSlot) -> bool: return s.zone == StorageSlot.Zone.RACK), "store targets are rack slots while racks have room")
	var floor_slot: StorageSlot = null
	for s: StorageSlot in grid.free_storage_slots():
		if s.zone == StorageSlot.Zone.FLOOR:
			floor_slot = s
			break
	if floor_slot != null:
		_check(not _flow.order_store(units[0], floor_slot).is_empty(), "floor slot rejected while racks have room")
	var targets: Array[StorageSlot] = _pick_targets(racks, PALLETS)
	_check(targets.size() == PALLETS, "found 6 rack slots")
	_check(not _flow.order_store(units[0], grid.first_free(StorageSlot.Zone.OUTBOUND)).is_empty(), "store order to an OUTBOUND slot is rejected")
	# pallet 1 goes through the click handler: raycast the pallet, then its slot
	var input: Node = get_first_node_in_group(&"cargo_input")
	var inspected: Array = [null]
	input.unit_inspected.connect(func(u: CargoUnit) -> void: inspected[0] = u)
	var camera: Camera3D = root.get_viewport().get_camera_3d()
	var hit: Object = input.pick_at(camera.unproject_position(units[0].node.global_position + Vector3(0.0, 0.5, 0.0)))
	_check(hit != null and hit.get(&"unit") == units[0], "raycast picks pallet 1 in INBOUND")
	if hit != null:
		input.click(hit)
	_check(input.selected == units[0] and inspected[0] == units[0], "click selects pallet 1 and opens its info")
	await physics_frame
	hit = input.pick_at(camera.unproject_position(targets[0].position + Vector3(0.0, 0.3, 0.0)))
	_check(hit != null and hit.get(&"slot") == targets[0], "raycast picks the highlighted slot %s" % targets[0].label)
	if hit != null:
		input.click(hit)
	_check(units[0].is_busy() and input.selected == units[1], "click on slot orders pallet 1 and selects pallet 2")
	input.select(null)
	for i: int in range(1, units.size()):
		reason = _flow.order_store(units[i], targets[i])
		_check(reason.is_empty(), "store order %s -> %s (%s)" % [units[i].code, targets[i].label, reason])
	if not await _until(func() -> bool: return _contract.state == Contract.State.STORED, "contract STORED"):
		return
	for i: int in units.size():
		_check(units[i].state == CargoUnit.State.STORED and units[i].slot == targets[i] and units[i].location_code == targets[i].label, "%s stored in %s" % [units[i].code, targets[i].label])
		var off: float = units[i].node.global_position.distance_to(targets[i].position)
		_check(off < 0.05, "%s 3D pallet at its slot (%.2f m off)" % [units[i].code, off])

	# 6. storage time passes, the client schedules the pickup
	if not await _until(func() -> bool: return _contract.state == Contract.State.PICKUP_SCHEDULED, "pickup scheduled"):
		return
	var min_storage: float = _contract.pallets * _contract.storage_fee * _contract.storage_days
	_check(_contract.storage_accrued >= min_storage - 0.5, "storage accrued %.1f >= %d" % [_contract.storage_accrued, int(min_storage)])

	# 7. picking to OUTBOUND, workers load the pickup truck, contract completes
	var queued: int = _flow.order_outbound(_contract)
	_check(queued == PALLETS, "6 pallets queued for picking (got %d)" % queued)
	if not await _until(func() -> bool: return _contract.state == Contract.State.COMPLETED, "contract COMPLETED", STEP_FRAMES * 2):
		return
	for u: CargoUnit in units:
		_check(u.state == CargoUnit.State.LOADED and u.slot != null and u.slot.is_trailer() and u.node != null and u.node.get_parent() == u.slot.anchor, "%s loaded on %s inside the trailer" % [u.code, u.location_code])
	var loaded_slots: Array[int] = []
	for u: CargoUnit in units:
		loaded_slots.append(u.slot.index)
	loaded_slots.sort()
	_check(loaded_slots == [0, 1, 2, 3, 4, 5], "trailer filled from Slot_01 (got %s)" % [loaded_slots])
	for s: StorageSlot in targets:
		_check(s.is_free(), "%s free again" % s.label)
	var storage: int = roundi(_contract.storage_accrued)
	var gained: int = gs.money - money_start
	_event("paid %d = handling %d + storage %d" % [_contract.payout, _contract.handling_fee, storage])
	_check(gained == _contract.handling_fee + storage and storage > 0, "money +%d == handling %d + storage %d" % [gained, _contract.handling_fee, storage])

	# 8. the truck leaves: delivered
	if not await _until(func() -> bool: return _contract.count_in(CargoUnit.State.DELIVERED) == PALLETS, "6 pallets DELIVERED"):
		return

	# 9. lifecycle per pallet
	var want_states: Array[int] = []
	for st: int in CargoUnit.State.values():
		want_states.append(st)
	for u: CargoUnit in units:
		var states: Array[int] = []
		var increasing: bool = true
		for i: int in u.history.size():
			if String(u.history[i].agent).begins_with("Scanned by"):
				continue  # staff scans note the pallet without a state change
			states.append(int(u.history[i].state))
			if i > 0 and float(u.history[i].time) <= float(u.history[i - 1].time):
				increasing = false
		_check(states == want_states, "%s states %s" % [u.code, ", ".join(states.map(func(s: int) -> String: return CargoUnit.name_of(s as CargoUnit.State)))])
		_check(increasing, "%s history timestamps increase" % u.code)
		var by_role: Dictionary = {
			CargoUnit.State.UNLOADING: "(Unloader)", CargoUnit.State.INBOUND: "(Unloader)",
			CargoUnit.State.PUTAWAY: "(Rack)", CargoUnit.State.STORED: "(Rack)",
			CargoUnit.State.PICKING: "(Rack)", CargoUnit.State.OUTBOUND: "(Rack)",
			CargoUnit.State.LOADING: "(Loader)", CargoUnit.State.LOADED: "(Loader)",
		}
		for st: int in by_role:
			var who: String = u.agent_for(st as CargoUnit.State)
			_check(who.begins_with("Forklift") and who.ends_with(by_role[st]), "%s %s by %s" % [u.code, CargoUnit.name_of(st as CargoUnit.State), who])
		var legs: Array = _legs.get(u, [])
		var want_legs: Array = [
			"UNLOAD:TRAILER>INBOUND:Forklift 1 (Unloader):held",
			"STORE:INBOUND>RACK:Forklift 2 (Rack):held",
			"TO_OUTBOUND:RACK>OUTBOUND:Forklift 2 (Rack):held",
			"LOAD:OUTBOUND>TRAILER:Forklift 3 (Loader):held",
		]
		_check(legs == want_legs, "%s legs %s" % [u.code, legs])
	_check(_progress_errors.is_empty(), "dock progress only on set-down %s" % [_progress_errors])
	_check(_outside == 0, "agents stay in the hall unless they hold a dock lane (%d frames outside)" % _outside)
	_check(_trailer_overlaps == 0, "never two agents in one trailer (max %d inside at once)" % _max_in_trailer)
	_finish("")


func _on_picked(job: CarryJob) -> void:
	if job.unit.contract != _contract:
		return
	var agent: Node = job.agent
	var held: bool = job.unit.node != null and agent.body.is_ancestor_of(job.unit.node)
	var leg: String = "%s:%s>?:%s:%s" % [CarryJob.Kind.keys()[job.kind], StorageSlot.Zone.keys()[job.from_slot.zone], agent.label, "held" if held else "not-held"]
	if not _legs.has(job.unit):
		_legs[job.unit] = []
	(_legs[job.unit] as Array).append(leg)
	_check(job.unit.is_carried() and job.unit.location_code == agent.label, "%s %s on %s" % [job.unit.code, job.unit.state_name(), agent.label])


func _on_placed(job: CarryJob) -> void:
	if job.unit.contract != _contract or not _legs.has(job.unit):
		return
	var legs: Array = _legs[job.unit]
	legs[legs.size() - 1] = (legs[legs.size() - 1] as String).replace(">?", ">" + StorageSlot.Zone.keys()[job.to_slot.zone])


func _on_progress(done: int, total: int, dock: Dock) -> void:
	if dock.contract != _contract or done == 0:
		return
	var inbound: int = _contract.count_in(CargoUnit.State.INBOUND) + _contract.count_in(CargoUnit.State.PUTAWAY) + _contract.count_in(CargoUnit.State.STORED)
	if dock.state == Dock.State.UNLOADING and inbound != done:
		_progress_errors.append("unload %d/%d with %d set down" % [done, total, inbound])
	if dock.state == Dock.State.LOADING and _contract.count_in(CargoUnit.State.LOADED) != done:
		_progress_errors.append("load %d/%d with %d loaded" % [done, total, _contract.count_in(CargoUnit.State.LOADED)])


## Called every frame while waiting.
func _monitor() -> void:
	for a: Node in _board.agents:
		# the hall's dock wall is at z = 0; only the lane holder may pass it
		if a.body.global_position.z > 0.9 and a.bay == null:
			_outside += 1
	for bay: Node in _flow.bays.values():
		var inside: int = 0
		for a: Node in _board.agents:
			if bay.in_trailer(a.body.global_position):
				inside += 1
		_max_in_trailer = maxi(_max_in_trailer, inside)
		if inside > 1:
			_trailer_overlaps += 1
			if _trailer_overlaps < 4:
				var who: PackedStringArray = PackedStringArray()
				for a: Node in _board.agents:
					if bay.in_trailer(a.body.global_position):
						who.append("%s@%s along %.2f" % [a.label, a.body.global_position, bay.along(a.body.global_position)])
				print("  overlap in bay %s: %s (occupant %s)" % [bay.name, ", ".join(who), bay.occupant.label if bay.occupant != null else "none"])


## One upper rack level, then other rack slots.
func _pick_targets(free: Array[StorageSlot], count: int) -> Array[StorageSlot]:
	var out: Array[StorageSlot] = []
	for s: StorageSlot in free:
		if s.needs_lift():
			out.append(s)
			break
	for s: StorageSlot in free:
		if out.size() >= count:
			break
		if not s in out:
			out.append(s)
	return out


func _until(cond: Callable, what: String, limit: int = STEP_FRAMES) -> bool:
	var frames: int = 0
	while not cond.call():
		if frames >= limit:
			for a: Node in _board.agents:
				print("  agent: ", a.debug_state())
			_check(false, "%s within %d frames" % [what, limit])
			_finish("timed out waiting for " + what)
			return false
		await process_frame
		_monitor()
		frames += 1
	_event("%s (%d frames)" % [what, frames])
	return true


func _event(text: String) -> void:
	var gs: Node = root.get_node(^"GameState")
	_events.append("[%s] %s" % [gs.format_clock(), text])


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


func _finish(error: String) -> void:
	print("test_core_loop: event sequence")
	for e: String in _events:
		print("  ", e)
	if not error.is_empty():
		push_error("test_core_loop: " + error)
		_failures += 1
	print("test_core_loop: PASS" if _failures == 0 else "test_core_loop: FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)
