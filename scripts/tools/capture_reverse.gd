extends SceneTree
## Captures a truck reversing onto a dock from the CameraRig reference view and
## stitches 8 frames (7 spread evenly over the trailer's reverse path + the
## parked truck with doors open) into a 4x2 contact sheet. Needs a window (headless cannot render):
## Godot --path . --resolution 1536x1024 --script res://scripts/tools/capture_reverse.gd -- \
##   [--dock=1] [--out=res://docs/previews/reverse_sequence.png] [--frames_dir=/abs/dir]
##   [--top]  (orthographic top view instead of the reference camera)

const COLS: int = 4
const ROWS: int = 2
const THUMB: Vector2i = Vector2i(768, 512)
const EVERY: int = 4


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var dock_id: int = 1
	var out: String = "res://docs/previews/reverse_sequence.png"
	var frames_dir: String = ""
	var top: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--dock="):
			dock_id = arg.trim_prefix("--dock=").to_int()
		elif arg.begins_with("--frames_dir="):
			frames_dir = arg.trim_prefix("--frames_dir=")
		elif arg == "--top":
			top = true
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 4
	gs.minutes_per_second = 0.0
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	for rig: Node in get_nodes_in_group(&"camera_rig"):
		rig.call(&"snap_to_reference")
		rig.set_process(false)
	if top:
		var cam: Camera3D = Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 34.0
		current_scene.add_child(cam)
		cam.global_transform = Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3(2.0, 60.0, 10.0))
		cam.current = true
	for node: Node in current_scene.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).hide()
	var sim: TerminalSim = get_first_node_in_group(&"terminal_sim") as TerminalSim
	var driver: Node = current_scene.find_child("TruckDriver%d" % dock_id, true, false)
	var dock: Dock = sim.get_dock(dock_id)
	var state: Dictionary = {"reversing": false, "parked": false}
	driver.reverse_started.connect(func(_d: int) -> void: state.reversing = true)
	driver.truck_parked.connect(func(_d: int) -> void: state.parked = true)
	dock.assign_truck("LogiTrans", "General cargo", 8)
	sim.request_truck.emit(dock)
	var shots: Array[Image] = []
	var travelled: PackedFloat32Array = PackedFloat32Array()
	var last_pos: Vector2 = Vector2.INF
	var dist: float = 0.0
	var frame: int = 0
	while not state.parked and frame < 6000:
		await process_frame
		frame += 1
		if not state.reversing:
			continue
		var rig: TruckRig = driver.get_rig() as TruckRig
		var pos: Vector2 = rig.trailer_axle_2d()
		if last_pos != Vector2.INF:
			dist += pos.distance_to(last_pos)
		last_pos = pos
		if frame % EVERY == 0:
			await RenderingServer.frame_post_draw
			shots.append(_thumb())
			travelled.append(dist)
	for i: int in 20:
		await process_frame
	await RenderingServer.frame_post_draw
	var parked: Image = _thumb()
	if shots.is_empty():
		push_error("capture_reverse: no reverse frames")
		quit(1)
		return
	var sheet: Image = Image.create(THUMB.x * COLS, THUMB.y * ROWS, false, Image.FORMAT_RGB8)
	var count: int = COLS * ROWS
	for k: int in count:
		var img: Image = parked
		if k < count - 1:
			img = shots[_at_distance(travelled, dist * float(k) / (count - 1))]
		if not frames_dir.is_empty():
			img.save_png(frames_dir.path_join("reverse_%d.png" % k))
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, THUMB), Vector2i((k % COLS) * THUMB.x, (k / COLS) * THUMB.y))
	var err: Error = sheet.save_png(ProjectSettings.globalize_path(out))
	print("capture_reverse: %d reverse frames, saved %s (%s)" % [shots.size(), out, error_string(err)])
	quit(0 if err == OK else 1)


## Index of the first shot taken after the trailer axle covered `d` metres.
func _at_distance(travelled: PackedFloat32Array, d: float) -> int:
	for i: int in travelled.size():
		if travelled[i] >= d:
			return i
	return travelled.size() - 1


func _thumb() -> Image:
	var img: Image = root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_BILINEAR)
	return img
