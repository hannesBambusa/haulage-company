extends SceneTree
## Headless test of one full 3D truck cycle on dock 1 in main.tscn. Trucks
## only come for contracts, so it accepts an 8-pallet contract through the
## ContractManager and follows its inbound truck:
## spawned -> parked (truck_arrived) -> unloading 1..8 (forklifts carry each
## pallet out of the trailer; the dock counts it when it is set down in
## INBOUND) -> cleared (truck_departed) -> despawned. Runs at 4x with a faster
## clock.
## Godot --headless --path . --fixed-fps 60 --script res://scripts/tests/test_truck_cycle.gd

const MAX_FRAMES: int = 24000

var _events: PackedStringArray = PackedStringArray()
var _arrived_at: int = 0
var _unloaded_at: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 4
	gs.minutes_per_second = 2.0
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var auto_flow_node: Node = get_first_node_in_group(&"cargo_flow")
	if auto_flow_node != null:
		auto_flow_node.set(&"auto_flow", false)  # no auto put-away: this test times the docks alone
	# untyped: these scripts use the GameState autoload, which --script mode
	# only registers after this test script has compiled
	var driver: Node = current_scene.find_child("TruckDriver1", true, false)
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var dock: Dock = null
	for node: Node in get_nodes_in_group(&"docks"):
		if (node as Dock).dock_id == 1:
			dock = node as Dock
	if driver == null or dock == null or manager == null:
		_fail("TruckDriver1, Dock 1 or ContractManager missing")
		return
	driver.truck_spawned.connect(func(_id: int) -> void: _events.append("spawned"))
	driver.truck_parked.connect(func(_id: int) -> void:
		_events.append("arrived")
		_arrived_at = Engine.get_process_frames())
	driver.truck_cleared.connect(func(_id: int) -> void: _events.append("departed"))
	driver.truck_despawned.connect(func(_id: int) -> void: _events.append("despawned"))
	dock.progress_changed.connect(func(done: int, _total: int) -> void:
		if dock.state == Dock.State.UNLOADING or done == dock.pallets_total:
			_events.append("unloading %d" % done)
		if done == dock.pallets_total and done > 0:
			_unloaded_at = Engine.get_process_frames())

	var template: Dictionary = ContractCatalog.find("LogiTrans")
	var contract: Contract = manager.make_contract(template, {"pallets": 8, "inbound_delay": 2.0})
	manager.add_available(contract)
	var reason: String = manager.accept(contract)
	if not reason.is_empty():
		_fail("accept blocked: " + reason)
		return

	var frames: int = 0
	while frames < MAX_FRAMES and not _events.has("despawned"):
		await process_frame
		frames += 1
	var want: PackedStringArray = PackedStringArray(["spawned", "arrived"])
	for i: int in range(1, 9):
		want.append("unloading %d" % i)
	want.append_array(["departed", "despawned"])
	print("test_truck_cycle: %d frames, events: %s" % [frames, ", ".join(_events)])
	# one Unloader forklift at realistic speeds (2 m/s open floor, 1.2 m/s on
	# the ramp and in the trailer, 1 m/s2, forks 0.35 m/s): 8 pallets take
	# about 7 real minutes at 1x (this run is 4x at 60 fps)
	var unload_seconds: float = float(_unloaded_at - _arrived_at) / 60.0 * float(gs.speed)
	print("test_truck_cycle: unloading took %.0f s at 1x" % unload_seconds)
	if unload_seconds < 120.0 or unload_seconds > 540.0:
		_fail("unloading 8 pallets took %.0f s at 1x, want 2-9 minutes" % unload_seconds)
		return
	if _events != want:
		_fail("expected %s" % ", ".join(want))
		return
	if contract.count_in(CargoUnit.State.INBOUND) != 8:
		_fail("expected 8 pallets in INBOUND, got %d" % contract.count_in(CargoUnit.State.INBOUND))
		return
	print("test_truck_cycle: PASS (8 pallets in INBOUND, contract %s, dock 1 door open %.2f)" % [contract.state_name(), dock_door_open()])
	quit(0)


func dock_door_open() -> float:
	var door: Node = current_scene.find_child("DockDoor1", true, false)
	return float(door.get(&"open_amount")) if door != null else -1.0


func _fail(msg: String) -> void:
	push_error("test_truck_cycle: FAIL " + msg)
	quit(1)
