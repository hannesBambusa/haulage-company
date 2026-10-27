extends SceneTree
## Eight mid-zoom shots of the staff duties (needs a window): the coffee
## group, someone sweeping, someone scanning, stitched 4x2.
## Godot --path . --resolution 1536x1024 --script res://scripts/tests/capture_duties.gd -- --out=res://docs/previews/duties_sequence.png

const SHOT_SIZE: Vector2i = Vector2i(1536, 1024)
const MAX_FRAMES: int = 40000

var _shots: Array[Image] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/duties_sequence.png"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 8
	gs.minutes_per_second = 1.0 / 60.0
	change_scene_to_file("res://scenes/main.tscn")
	for i: int in 4:
		await process_frame
	for node: Node in current_scene.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).hide()
	for rig: Node in get_nodes_in_group(&"camera_rig"):
		rig.set_process(false)
		rig.set_process_input(false)
		rig.set_process_unhandled_input(false)
	var cam: Camera3D = Camera3D.new()
	cam.fov = 40.0
	current_scene.add_child(cam)
	cam.make_current()
	var planner: Node = get_first_node_in_group(&"duty_planner")
	while not bool(planner.get(&"ready_done")):
		await process_frame
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var c: Contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": 6, "storage_days": 1, "inbound_delay": 2.0})
	manager.add_available(c)
	manager.accept(c)
	var workers: Array = planner.get(&"workers")
	for i: int in 3:
		workers[i].tired = 1.0
		workers[i].social = 1.0
	planner.get(&"dirt").call(&"add_dirt", Vector2(-6.0, -12.0), false, 0.9)
	var wanted: Array[StringName] = [&"Talk", &"Talk", &"Talk", &"Sweep", &"Sweep", &"ScanPallet", &"Inspect", &"Clipboard"]
	var frames: int = 0
	var next_ok: int = 0
	while frames < MAX_FRAMES and _shots.size() < 8:
		await process_frame
		frames += 1
		if frames < next_ok:
			continue
		var want: StringName = wanted[_shots.size()]
		for w: Node in workers:
			var act: StringName = w.get(&"current_action")
			var d: Variant = w.get(&"duty")
			if act != want or d == null:
				continue
			if want == &"Clipboard" and d.get(&"kind") != &"scan":
				continue
			var p: Vector3 = (w as Node3D).global_position
			var look: Vector3 = p + Vector3(0.0, 0.8, 0.0)
			if want == &"Talk":
				var g: Vector2 = planner.get(&"group").center
				look = Vector3(g.x, 0.8, g.y)
			cam.global_position = look + Vector3(3.2, 3.6, 4.2)
			cam.look_at(look)
			await RenderingServer.frame_post_draw
			_shots.append(root.get_texture().get_image())
			print("capture_duties: shot %d %s %s" % [_shots.size(), want, w.get(&"display_name")])
			next_ok = frames + 90
			break
	if _shots.size() < 8:
		push_error("capture_duties: only %d of 8 shots" % _shots.size())
	var cell: Vector2i = SHOT_SIZE / 2
	var sheet: Image = Image.create(cell.x * 4, cell.y * 2, false, Image.FORMAT_RGBA8)
	for i: int in _shots.size():
		var img: Image = _shots[i]
		img.convert(Image.FORMAT_RGBA8)
		img.resize(cell.x, cell.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i((i % 4) * cell.x, (i / 4) * cell.y))
	var err: Error = sheet.save_png(ProjectSettings.globalize_path(out))
	print("capture_duties: saved %s err=%s" % [out, error_string(err)])
	quit(0 if err == OK and _shots.size() == 8 else 1)
