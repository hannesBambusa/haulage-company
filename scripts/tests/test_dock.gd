extends SceneTree
## Headless test: Godot --headless --path . --script res://scripts/tests/test_dock.gd

const GameStateScript: GDScript = preload("res://scripts/autoload/game_state.gd")

var _failures: int = 0


func _initialize() -> void:
	# Nodes added here only get _ready() once the tree starts; run after that.
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var clock: Node = GameStateScript.new()
	clock.set_process(false)
	root.add_child(clock)

	var dock: Dock = Dock.new()
	dock.clock = clock
	dock.pallets_total = 8
	dock.minutes_per_pallet = 3.0
	root.add_child(dock)
	await process_frame

	var states: Array[int] = []
	var ready_count: Array[int] = [0]
	dock.state_changed.connect(func(s: Dock.State) -> void: states.append(s))
	dock.ready_to_depart.connect(func() -> void: ready_count[0] += 1)

	_check(dock.state == Dock.State.IDLE, "starts IDLE")
	_check(dock.assign_truck("LogiTrans", "General cargo"), "assign_truck accepted")
	_check(dock.state == Dock.State.ARRIVING, "ARRIVING after assign")
	_check(not dock.assign_truck("X", "Y"), "second assign rejected while busy")

	clock.advance(30.0)
	_check(dock.pallets_done == 0, "no unloading while ARRIVING")

	dock.truck_arrived()
	_check(dock.state == Dock.State.UNLOADING, "UNLOADING after truck_arrived")

	clock.advance(2.9)
	_check(dock.pallets_done == 0, "0 pallets after 2.9 min")
	clock.advance(0.2)
	_check(dock.pallets_done == 1, "1 pallet after 3.1 min")
	for i: int in 9:
		clock.advance(1.0)
	_check(dock.pallets_done == 4, "4 pallets after 12.1 min (got %d)" % dock.pallets_done)
	_check(dock.state == Dock.State.UNLOADING, "still UNLOADING at 4/8")
	clock.advance(12.0)
	_check(dock.pallets_done == 8, "8 pallets after 24.1 min")
	_check(dock.state == Dock.State.DEPARTING, "DEPARTING after last pallet")
	_check(ready_count[0] == 1, "ready_to_depart emitted once")
	clock.advance(30.0)
	_check(dock.pallets_done == 8, "no overrun past total")

	dock.truck_departed()
	_check(dock.state == Dock.State.IDLE, "IDLE after truck_departed")
	_check(dock.pallets_done == 0, "pallets reset")
	var expected: Array[int] = [Dock.State.ARRIVING, Dock.State.UNLOADING, Dock.State.DEPARTING, Dock.State.IDLE]
	_check(states == expected, "state sequence %s" % [states])

	# pickup: LOADING waits on the transfer gate, then loads and departs
	var gate_open: Array[bool] = [false]
	var loaded: Array[int] = [0]
	dock.transfer_gate = func(_d: Dock) -> bool: return gate_open[0]
	dock.load_completed.connect(func(_d: Dock) -> void: loaded[0] += 1)
	_check(dock.assign_truck("QuickShip", "Express goods", 4, true), "pickup assign accepted")
	dock.truck_arrived()
	_check(dock.state == Dock.State.LOADING, "LOADING after pickup truck_arrived")
	clock.advance(20.0)
	_check(dock.pallets_done == 0, "gate closed holds loading (got %d)" % dock.pallets_done)
	gate_open[0] = true
	clock.advance(0.1)
	_check(dock.pallets_done == 1, "gate open loads the held pallet at once (got %d)" % dock.pallets_done)
	clock.advance(9.0)
	_check(dock.pallets_done == 4, "4 pallets loaded")
	_check(dock.state == Dock.State.DEPARTING, "DEPARTING after loading")
	_check(loaded[0] == 1, "load_completed emitted once")
	dock.truck_departed()
	_check(dock.state == Dock.State.IDLE and not dock.loading, "IDLE and not loading after pickup")

	# physical mode: the clock moves nothing, report_pallet() counts and
	# finish_transfer() ends the visit once every pallet is in
	dock.transfer_gate = Callable()
	dock.physical_transfer = true
	var progress: Array[int] = []
	dock.progress_changed.connect(func(done: int, _t: int) -> void: progress.append(done))
	ready_count[0] = 0
	_check(dock.assign_truck("LogiTrans", "General cargo", 3), "physical assign accepted")
	dock.truck_arrived()
	clock.advance(60.0)
	_check(dock.pallets_done == 0, "physical: game time alone moves no pallet (got %d)" % dock.pallets_done)
	_check(not dock.finish_transfer(), "physical: finish refused at 0/3")
	dock.report_pallet()
	dock.report_pallet()
	_check(dock.pallets_done == 2 and dock.state == Dock.State.UNLOADING, "physical: 2 reported, still UNLOADING")
	dock.report_pallet()
	_check(dock.state == Dock.State.UNLOADING, "physical: stays UNLOADING at 3/3 until finish_transfer")
	_check(dock.finish_transfer() and dock.state == Dock.State.DEPARTING, "physical: finish_transfer -> DEPARTING")
	_check(ready_count[0] == 1, "physical: ready_to_depart once")
	_check(progress == [0, 1, 2, 3], "physical: progress 0,1,2,3 (got %s)" % [progress])
	dock.truck_departed()

	print("PASS" if _failures == 0 else "FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)
