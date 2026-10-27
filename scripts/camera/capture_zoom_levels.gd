extends SceneTree
## Captures the CameraRig at five zoom levels from one focus inside the
## warehouse and stitches them into one 3x2 sheet. Needs a window:
## Godot --path . --resolution 1536x1024 --script res://scripts/camera/capture_zoom_levels.gd -- \
##   --reference_state [--out=res://docs/previews/zoom_levels.png] [--frames-dir=/abs/dir]
## --frames-dir also saves each full-size frame there.

const FOCUS: Vector3 = Vector3(-8.5, 0.0, -11.0)
const LEVELS: Array[Dictionary] = [
	{"name": "strategic", "z": 1.0},
	{"name": "mid", "z": 0.72},
	{"name": "low tilt", "z": 0.42},
	{"name": "near ground", "z": 0.16},
	{"name": "first person", "z": 0.0},
]
const CELL: Vector2i = Vector2i(768, 512)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/zoom_levels.png"
	var frames_dir: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--frames-dir="):
			frames_dir = arg.trim_prefix("--frames-dir=")
	change_scene_to_file("res://scenes/main.tscn")
	for i: int in 30:
		await process_frame
	var rig: CameraRig = get_first_node_in_group(&"camera_rig") as CameraRig
	if rig == null:
		push_error("capture_zoom_levels: no CameraRig")
		quit(1)
		return
	var yaw: float = rig.reference_view.yaw_deg if rig.reference_view != null else 36.0
	var sheet: Image = Image.create_empty(CELL.x * 3, CELL.y * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.08, 0.09, 0.11))
	for i: int in LEVELS.size():
		var level: Dictionary = LEVELS[i]
		rig.focus_on(FOCUS, yaw, true)
		rig.set_zoom(level.z, true)
		rig.set_look_pitch_deg(6.0)
		for f: int in 45:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		var cam: Camera3D = root.get_camera_3d()
		print("capture_zoom_levels: %s z=%.2f fp=%s cam=%s fov=%.1f near=%.3f" % [
			level.name, level.z, rig.is_first_person(), cam.global_position.snappedf(0.01), cam.fov, cam.near])
		if frames_dir != "":
			img.save_png(frames_dir.path_join("zoom_%d.png" % i))
		img.convert(Image.FORMAT_RGBA8)
		img.resize(CELL.x, CELL.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, CELL), Vector2i((i % 3) * CELL.x, (i / 3) * CELL.y))
	var err: Error = sheet.save_png(ProjectSettings.globalize_path(out))
	print("capture_zoom_levels: saved ", out, " err=", error_string(err))
	quit(0 if err == OK else 1)
