extends SceneTree
## Captures the Jack operator pushing a pallet on the hand pallet jack
## (needs a window, not headless). Accepts a contract, lets auto put-away
## hand a pallet to the jack, and shoots once the pallet is on the jack and
## moving, the camera looking down at the worker from behind and above.
## Godot --path . --resolution 1536x1024 --script res://scripts/tests/capture_jack.gd -- --out=res://docs/previews/pallet_jack.png

const MAX_FRAMES: int = 60000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/pallet_jack.png"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 30
	gs.minutes_per_second = 1.0 / 60.0
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	for node: Node in current_scene.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).hide()
	for rig: Node in get_nodes_in_group(&"camera_rig"):
		rig.set_process(false)
		rig.set_process_input(false)
		rig.set_process_unhandled_input(false)
	var cam: Camera3D = Camera3D.new()
	cam.fov = 50.0
	current_scene.add_child(cam)
	cam.make_current()
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var board: Node = get_first_node_in_group(&"job_board")
	var c: Contract = manager.make_contract(ContractCatalog.find("LogiTrans"), {"pallets": 6, "inbound_delay": 1.0})
	manager.add_available(c)
	manager.accept(c)
	var jack: Node = board.jacks()[0]
	var frames: int = 0
	var moving: int = 0
	while frames < MAX_FRAMES:
		await process_frame
		frames += 1
		var j: Object = jack.job
		if j != null and j.unit.is_carried() and float(jack.speed) > 0.5:
			moving += 1
			gs.speed = 1
		else:
			moving = 0
		var p: Vector3 = jack.body.global_position
		var f: Vector3 = -jack.body.global_basis.z
		cam.look_at_from_position(p - f * 4.5 + Vector3(2.5, 3.8, 0.0), p + f * 1.0, Vector3.UP)
		if moving > 20:
			break
	await RenderingServer.frame_post_draw
	var img: Image = root.get_viewport().get_texture().get_image()
	var err: Error = img.save_png(ProjectSettings.globalize_path(out))
	print("capture_jack: %s (%s) after %d frames" % [out, error_string(err), frames])
	quit(0 if err == OK and moving > 20 else 1)
