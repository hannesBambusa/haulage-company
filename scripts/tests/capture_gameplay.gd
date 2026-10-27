extends SceneTree
## Screenshot of the core loop mid-way (needs a window, not headless): accepts
## a contract, waits for its pallets in INBOUND, orders most of them into
## storage (one to an upper rack level for the forklift), selects a remaining
## one so the free slots light up, opens the Storage panel and captures while
## pallets are being carried.
## Godot --path . --resolution 1536x1024 --script res://scripts/tests/capture_gameplay.gd -- --out=res://docs/previews/gameplay_loop.png

const MAX_FRAMES: int = 6000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/gameplay_loop.png"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var gs: Node = root.get_node(^"GameState")
	gs.speed = 4
	gs.minutes_per_second = 2.0
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var manager: Node = get_first_node_in_group(&"contract_manager")
	var flow: Node = get_first_node_in_group(&"cargo_flow")
	var grid: Node = get_first_node_in_group(&"storage_grid")
	var input: Node = get_first_node_in_group(&"cargo_input")
	var hud: Node = current_scene.get_node(^"HUD")
	var c: Contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": 8, "inbound_delay": 1.0})
	manager.add_available(c)
	manager.accept(c)
	var frames: int = 0
	while c.count_in(CargoUnit.State.INBOUND) < c.pallets and frames < MAX_FRAMES:
		await process_frame
		frames += 1
	var free: Array[StorageSlot] = grid.store_targets()
	var targets: Array[StorageSlot] = []
	for s: StorageSlot in free:
		if s.needs_lift():
			targets.append(s)
			break
	for s: StorageSlot in free:
		if targets.size() >= 6:
			break
		if not s.needs_lift():
			targets.append(s)
	for i: int in targets.size():
		flow.order_store(c.units[i], targets[i])
	hud.open_storage()
	# wait until the pallets are on the move, then show the slot highlights
	frames = 0
	while (c.count_in(CargoUnit.State.PUTAWAY)) < 3 and frames < MAX_FRAMES:
		await process_frame
		frames += 1
	for i: int in 40:
		await process_frame
	input.select(c.units[c.pallets - 1])
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img.get_size() != Vector2i(1536, 1024):
		img.resize(1536, 1024, Image.INTERPOLATE_LANCZOS)
	var err: Error = img.save_png(ProjectSettings.globalize_path(out))
	print("capture_gameplay: %d moving, saved %s err=%s" % [(c.count_in(CargoUnit.State.PUTAWAY)), out, error_string(err)])
	quit(0 if err == OK else 1)
