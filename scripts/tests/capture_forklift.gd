extends SceneTree
## Captures one forklift unload cycle at dock 1 as 8 frames (needs a window,
## not headless) and stitches them into a 4x2 sheet:
## lined up at the ramp, climbing, inside the trailer, pallet lifted,
## reversing down the ramp, swinging round, driving to INBOUND, set down.
## Godot --path . --resolution 1536x1024 --script res://scripts/tests/capture_forklift.gd -- --out=res://docs/previews/forklift_sequence.png

const MAX_FRAMES: int = 40000
const SHOT_SIZE: Vector2i = Vector2i(1536, 1024)
const CAPTIONS: PackedStringArray = [
	"1 lined up at the ramp", "2 up the ramp, forks raised", "3 in the trailer, forks down", "4 pallet lifted",
	"5 reversing down the ramp", "6 swung round, lane free", "7 to INBOUND", "8 set down in INBOUND",
]

var _shots: Array[Image] = []
var _cam: Camera3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/forklift_sequence.png"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 4
	gs.minutes_per_second = 2.0
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	for node: Node in current_scene.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).hide()
	for rig: Node in get_nodes_in_group(&"camera_rig"):
		rig.set_process(false)
		rig.set_process_input(false)
		rig.set_process_unhandled_input(false)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	current_scene.add_child(_cam)
	_cam.make_current()
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var flow: Node = get_first_node_in_group(&"cargo_flow")
	var sim: Node = get_first_node_in_group(&"terminal_sim")
	var c: Contract = manager.make_contract(ContractCatalog.find("LogiTrans"), {"pallets": 8, "inbound_delay": 1.0})
	manager.add_available(c)
	manager.accept(c)
	var dock: Dock = sim.get_dock(1)
	var bay: Node = flow.bay_for(dock)
	_dock_view(bay)

	# wait for the first forklift to take the lane
	var lift: Node = null
	var frames: int = 0
	while frames < MAX_FRAMES:
		await process_frame
		frames += 1
		if bay.occupant != null:
			lift = bay.occupant
			break
	if lift == null:
		push_error("capture_forklift: no forklift entered the trailer")
		quit(1)
		return
	gs.speed = 2
	var unit: CargoUnit = lift.job.unit
	var step: int = 0
	var picked_frames: int = 0
	var placed_frames: int = 0
	while frames < MAX_FRAMES and step < 8:
		await process_frame
		frames += 1
		var p: Vector3 = lift.body.global_position
		var s: float = bay.along(p)
		var carried: bool = unit.is_carried()
		if carried:
			picked_frames += 1
		if unit.state == CargoUnit.State.INBOUND:
			placed_frames += 1
		var take: bool = false
		match step:
			0: take = absf(s + bay.stage_distance) < 0.1 and absf(bay.across(p) - bay.across(unit.slot.position if unit.slot != null else p)) < 0.2 and not carried
			1: take = s > bay.ramp_length() * 0.5 and not carried
			2: take = bay.in_trailer(p) and lift.call(&"forks_height") < 0.05 and not carried
			3: take = carried and picked_frames > 45
			4: take = carried and s < bay.ramp_length() * 0.55 and s > 0.5
			5: take = carried and bay.occupant != lift
			6: take = carried and p.distance_to(unit.job.to_slot.position) < 6.0 if unit.job != null and unit.job.to_slot != null else false
			7: take = placed_frames > 20
		if not take:
			continue
		if step == 5:
			_follow_view(lift.body.global_position, lift.body.global_position + Vector3(2.0, 0.0, -3.0))
		elif step == 6:
			_follow_view(lift.body.global_position, unit.job.to_slot.position if unit.job != null else p)
		elif step == 7:
			_follow_view(lift.body.global_position, unit.slot.position if unit.slot != null else p)
		await process_frame
		await RenderingServer.frame_post_draw
		_shots.append(root.get_texture().get_image())
		print("capture_forklift: shot %d (%s) at %s" % [step + 1, CAPTIONS[step], p])
		step += 1
	if _shots.size() < 8:
		push_error("capture_forklift: only %d of 8 shots" % _shots.size())
		quit(1)
		return
	var sheet: Image = _stitch()
	var err: Error = sheet.save_png(ProjectSettings.globalize_path(out))
	print("capture_forklift: saved %s %s err=%s" % [out, sheet.get_size(), error_string(err)])
	quit(0 if err == OK else 1)


## From inside the hall, looking out through dock 1 into the trailer.
func _dock_view(bay: Node) -> void:
	var look: Vector3 = bay.lane_point(bay.ramp_length() * 0.5, -0.6) + Vector3(0.0, 0.9, 0.0)
	var from: Vector3 = bay.lane_point(-8.0, 4.2) + Vector3(0.0, 4.4, 0.0)
	_cam.global_position = from
	_cam.look_at(look, Vector3.UP)


func _follow_view(at: Vector3, target: Vector3) -> void:
	var mid: Vector3 = at.lerp(target, 0.5)
	_cam.global_position = mid + Vector3(5.5, 6.0, 5.0)
	_cam.look_at(mid + Vector3(0.0, 0.6, 0.0), Vector3.UP)


func _stitch() -> Image:
	var cell: Vector2i = SHOT_SIZE / 2
	var sheet: Image = Image.create(cell.x * 4, cell.y * 2, false, Image.FORMAT_RGBA8)
	for i: int in _shots.size():
		var img: Image = _shots[i]
		img.convert(Image.FORMAT_RGBA8)
		img.resize(cell.x, cell.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i((i % 4) * cell.x, (i / 4) * cell.y))
	return sheet
