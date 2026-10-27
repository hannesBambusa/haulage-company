extends SceneTree
## Top-down orthographic sequence of the three forklifts working at once
## (needs a window, not headless): a stored contract is picked and loaded at
## one dock while an inbound one is unloaded at the other. Takes 8 frames a
## few game seconds apart while at least two forklifts move, stitched 4x2.
## Godot --path . --resolution 1536x1024 --script res://scripts/tests/capture_traffic.gd -- --out=res://docs/previews/traffic_sequence.png

const MAX_FRAMES: int = 60000
const SHOT_SIZE: Vector2i = Vector2i(1536, 1024)
## Game seconds between shots.
const GAP: float = 5.0

var _shots: Array[Image] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/traffic_sequence.png"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 4
	gs.minutes_per_second = 1.0
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
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 30.0
	current_scene.add_child(cam)
	cam.global_position = Vector3(0.0, 40.0, -12.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.make_current()
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var flow: Node = get_first_node_in_group(&"cargo_flow")
	var grid: Node = get_first_node_in_group(&"storage_grid")
	var board: Node = get_first_node_in_group(&"job_board")
	# a stored contract whose pickup is due, plus an inbound one
	var p: Contract = manager.make_contract(ContractCatalog.find("QuickShip"), {"pallets": 3, "storage_days": 1})
	manager.adopt(p, Contract.State.STORED)
	var racks: Array = grid.store_targets()
	for i: int in p.units.size():
		var u: CargoUnit = p.units[i]
		PalletLog.stamp(u, CargoUnit.State.IN_TRUCK, "T-Dock1-%02d" % (i + 1))
		PalletLog.stamp(u, CargoUnit.State.UNLOADING, "Forklift 1 (Unloader)", "Forklift 1 (Unloader)")
		PalletLog.stamp(u, CargoUnit.State.INBOUND, "INBOUND-%02d" % (i + 1), "Forklift 1 (Unloader)")
		PalletLog.stamp(u, CargoUnit.State.PUTAWAY, "Forklift 2 (Rack)", "Forklift 2 (Rack)")
		flow._put(u, racks[i * 3], CargoUnit.State.STORED, "Forklift 2 (Rack)")
	p.stored_minutes = p.storage_days * GameplayConfig.MINUTES_PER_CONTRACT_DAY
	var c1: Contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": 4, "storage_days": 1, "inbound_delay": 2.0})
	manager.add_available(c1)
	manager.accept(c1)
	var ordered: bool = false
	var frames: int = 0
	var since: float = GAP
	while frames < MAX_FRAMES and _shots.size() < 8:
		await process_frame
		frames += 1
		if p.state == Contract.State.PICKUP_SCHEDULED and not ordered:
			ordered = true
			flow.order_outbound(p)
		for u: CargoUnit in c1.units:
			if u.state == CargoUnit.State.INBOUND and not u.is_busy():
				var t: Array = grid.store_targets()
				if not t.is_empty():
					flow.order_store(u, t[0])
		var moving: int = 0
		for f: Node in board.forklifts():
			if f.speed > 0.1:
				moving += 1
		since += 1.0 / 60.0 * float(gs.speed)
		if moving >= 2 and since >= GAP:
			since = 0.0
			await RenderingServer.frame_post_draw
			_shots.append(root.get_texture().get_image())
			var where: PackedStringArray = PackedStringArray()
			for f: Node in board.forklifts():
				where.append(f.debug_state())
			print("capture_traffic: shot %d at frame %d: %s" % [_shots.size(), frames, " | ".join(where)])
	if _shots.size() < 8:
		push_error("capture_traffic: only %d of 8 shots" % _shots.size())
		quit(1)
		return
	var cell: Vector2i = SHOT_SIZE / 2
	var sheet: Image = Image.create(cell.x * 4, cell.y * 2, false, Image.FORMAT_RGBA8)
	for i: int in _shots.size():
		var img: Image = _shots[i]
		img.convert(Image.FORMAT_RGBA8)
		img.resize(cell.x, cell.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i((i % 4) * cell.x, (i / 4) * cell.y))
	var err: Error = sheet.save_png(ProjectSettings.globalize_path(out))
	print("capture_traffic: saved %s err=%s" % [out, error_string(err)])
	quit(0 if err == OK else 1)
