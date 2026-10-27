extends SceneTree
## Headless test of the articulated reverse onto dock 1 and dock 2 in
## main.tscn. For each dock it books a truck, follows it in and checks:
## - the coupling bends during the reverse (max articulation > 10 deg),
## - the kingpin stays on the fifth wheel every frame (< 0.05 m),
## - the parked trailer rear is within 0.15 m of the stop line and of the bay
##   centre, square to the dock within 2 deg, cab straight within 2 deg,
## - the RearEntry sill is on the bumper face and the leveler lip is out.
## Godot --headless --path . --fixed-fps 60 --script res://scripts/tests/test_truck_articulation.gd

const MAX_FRAMES: int = 3000
const MIN_BEND_DEG: float = 10.0
const MAX_COUPLING: float = 0.05
const MAX_POS_ERR: float = 0.15
const MAX_ANGLE_DEG: float = 2.0

var _failed: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 4
	gs.minutes_per_second = 0.0  # freeze unloading so parked trucks stay put
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var sim: TerminalSim = get_first_node_in_group(&"terminal_sim") as TerminalSim
	if sim == null:
		_fail("no TerminalSim")
		return
	for id: int in [1, 2]:
		await _check_dock(sim, id)
		if _failed:
			return
	print("test_truck_articulation: PASS")
	quit(0)


func _check_dock(sim: TerminalSim, id: int) -> void:
	# untyped: TruckDriver uses the GameState autoload (see test_truck_cycle)
	var driver: Node = current_scene.find_child("TruckDriver%d" % id, true, false)
	var dock: Dock = sim.get_dock(id)
	if driver == null or dock == null:
		_fail("TruckDriver%d or Dock %d missing" % [id, id])
		return
	var state: Dictionary = {"reversing": false, "parked": false}
	driver.reverse_started.connect(func(_d: int) -> void: state.reversing = true)
	driver.truck_parked.connect(func(_d: int) -> void: state.parked = true)
	if not dock.assign_truck("TestHaul", "General cargo", 8):
		_fail("dock %d not idle" % id)
		return
	sim.request_truck.emit(dock)
	var max_bend: float = 0.0
	var max_coupling: float = 0.0
	var frames: int = 0
	var reverse_frames: int = 0
	while not state.parked and frames < MAX_FRAMES:
		await process_frame
		frames += 1
		var rig: TruckRig = driver.get_rig() as TruckRig
		if rig == null:
			continue
		max_coupling = maxf(max_coupling, rig.coupling_error())
		if state.reversing:
			reverse_frames += 1
			max_bend = maxf(max_bend, absf(rig.articulation()))
	if not state.parked:
		_fail("dock %d: truck never parked in %d frames" % [id, MAX_FRAMES])
		return
	var rig: TruckRig = driver.get_rig() as TruckRig
	var n: Vector2 = driver.dock_normal()
	var off: Vector2 = rig.trailer_rear_2d() - driver.dock_stop()
	var along: float = off.dot(n)
	var lateral: float = off.cross(n)
	var yaw_err: float = rad_to_deg(absf(wrapf(rig.trailer_yaw() - TruckRig.dir_yaw(n), -PI, PI)))
	var cab_err: float = rad_to_deg(absf(rig.articulation()))
	# the sill (RearEntry) must sit on the dock's bumper face
	var door: Node3D = current_scene.find_child("DockDoor%d" % id, true, false) as Node3D
	var bumper: Vector3 = door.global_transform * Vector3(0.0, 0.0, float(driver.bumper_face_z))
	var sill: Vector3 = rig.get_rear_entry().origin
	var sill_gap: float = Vector2(sill.x - bumper.x, sill.z - bumper.z).dot(n)
	var lip: Node3D = door.find_child("LevelerLip", true, false) as Node3D
	var lip_deg: float = rad_to_deg(lip.rotation.x) if lip != null else 0.0
	print("test_truck_articulation: dock %d: sill %.3f m from bumper face, leveler lip %.1f deg" % [id, sill_gap, lip_deg])
	if absf(sill_gap) > MAX_POS_ERR:
		_fail("dock %d: sill %.3f m off the bumper face" % [id, sill_gap])
		return
	if absf(lip_deg) > 1.0:
		_fail("dock %d: leveler lip not unfolded (%.1f deg)" % [id, lip_deg])
		return
	print("test_truck_articulation: dock %d: %d frames (%d reversing), max bend %.1f deg, max coupling %.4f m, rear %.3f m / %.3f m off, trailer %.2f deg, cab %.2f deg, doors_open %s" % [
		id, frames, reverse_frames, rad_to_deg(max_bend), max_coupling, along, lateral, yaw_err, cab_err, rig.are_doors_open()])
	if rad_to_deg(max_bend) <= MIN_BEND_DEG:
		_fail("dock %d: max articulation %.1f deg <= %.1f" % [id, rad_to_deg(max_bend), MIN_BEND_DEG])
	elif max_coupling >= MAX_COUPLING:
		_fail("dock %d: kingpin left the fifth wheel by %.3f m" % [id, max_coupling])
	elif absf(along) > MAX_POS_ERR or absf(lateral) > MAX_POS_ERR:
		_fail("dock %d: rear off by %.3f m along, %.3f m across" % [id, along, lateral])
	elif yaw_err > MAX_ANGLE_DEG or cab_err > MAX_ANGLE_DEG:
		_fail("dock %d: trailer %.2f deg off square, cab %.2f deg bent" % [id, yaw_err, cab_err])
	elif not rig.is_parked():
		_fail("dock %d: rig.is_parked() false after truck_parked" % id)


func _fail(msg: String) -> void:
	_failed = true
	push_error("test_truck_articulation: FAIL " + msg)
	quit(1)
