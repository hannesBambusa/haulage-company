extends SceneTree
## Screenshot helper (needs a window, not headless):
## Godot --path . --script res://scripts/tests/capture_preview.gd --resolution 1536x1024 -- --out=res://docs/previews/hud.png [--wait=4] [--contracts]

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = "res://docs/previews/hud.png"
	var wait: float = 4.0
	var contracts: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--wait="):
			wait = arg.trim_prefix("--wait=").to_float()
		elif arg == "--contracts":
			contracts = true
	print("autoload GameState present: ", root.has_node(^"GameState"))
	change_scene_to_file("res://scenes/ui_preview.tscn")
	await create_timer(wait).timeout
	if contracts:
		var hud: Node = current_scene.get_node(^"HUD")
		hud.open_contracts()
		hud.show_alert("Storage space low", "Only 12 free pallet spaces left")
	await create_timer(0.5).timeout
	await process_frame
	await process_frame
	var img: Image = root.get_texture().get_image()
	print("captured ", img.get_size())
	if img.get_size() != Vector2i(1536, 1024):
		img.resize(1536, 1024, Image.INTERPOLATE_LANCZOS)
	var err: Error = img.save_png(ProjectSettings.globalize_path(out))
	print("saved ", out, " err=", err)
	quit()
