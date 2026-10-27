extends SceneTree
## Renders a scene from the CameraRig reference view and saves a PNG. Needs a
## window (headless cannot render):
## Godot --path . --resolution 1536x1024 --script res://scripts/tools/screenshot.gd -- \
##   --scene=res://scenes/main.tscn --out=res://docs/previews/scene_r1.png [--frames=60] [--no-hud]

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene_path: String = "res://scenes/main.tscn"
	var out: String = "res://docs/previews/scene_shot.png"
	var frames: int = 60
	var hide_hud: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			scene_path = arg.trim_prefix("--scene=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--frames="):
			frames = arg.trim_prefix("--frames=").to_int()
		elif arg == "--no-hud":
			hide_hud = true
	var err: Error = change_scene_to_file(scene_path)
	if err != OK:
		push_error("screenshot: cannot load %s (%s)" % [scene_path, error_string(err)])
		quit(1)
		return
	await process_frame
	await process_frame
	for rig: Node in get_nodes_in_group(&"camera_rig"):
		rig.call(&"snap_to_reference")
		rig.set_process(false)
	if hide_hud:
		for node: Node in current_scene.find_children("*", "CanvasLayer", true, false):
			(node as CanvasLayer).hide()
	for i: int in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	print("screenshot: captured ", img.get_size())
	err = img.save_png(ProjectSettings.globalize_path(out))
	print("screenshot: saved ", out, " err=", error_string(err))
	quit(0 if err == OK else 1)
