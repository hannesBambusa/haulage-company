extends SceneTree
## Builds a side-by-side (reference | shot, each 1536x1024) and a 50% blend.
## Godot --headless --path . --script res://scripts/tools/compare.gd -- \
##   --shot=res://docs/previews/scene_r1.png --round=1 \
##   [--ref=res://docs/reference/gameplay-target.png] [--dir=res://docs/previews]

const SIZE: Vector2i = Vector2i(1536, 1024)


func _initialize() -> void:
	var args: Dictionary = {
		"ref": "res://docs/reference/gameplay-target.png",
		"dir": "res://docs/previews",
		"round": "1",
	}
	for arg: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if not args.has("shot"):
		push_error("compare: --shot=<png> is required")
		quit(1)
		return
	var ref: Image = _load(args.ref)
	var shot: Image = _load(args.shot)
	if ref == null or shot == null:
		quit(1)
		return
	var side: Image = Image.create_empty(SIZE.x * 2, SIZE.y, false, Image.FORMAT_RGBA8)
	side.blit_rect(ref, Rect2i(Vector2i.ZERO, SIZE), Vector2i.ZERO)
	side.blit_rect(shot, Rect2i(Vector2i.ZERO, SIZE), Vector2i(SIZE.x, 0))
	var a: PackedByteArray = ref.get_data()
	var b: PackedByteArray = shot.get_data()
	var mix: PackedByteArray = PackedByteArray()
	mix.resize(a.size())
	for i: int in a.size():
		mix[i] = (a[i] + b[i]) >> 1
	var overlay: Image = Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8, mix)
	var dir: String = ProjectSettings.globalize_path(args.dir)
	var side_path: String = dir.path_join("scene_compare_r%s.png" % args.round)
	var over_path: String = dir.path_join("scene_overlay_r%s.png" % args.round)
	print("compare: ", side_path, " ", error_string(side.save_png(side_path)))
	print("compare: ", over_path, " ", error_string(overlay.save_png(over_path)))
	quit()


func _load(path: String) -> Image:
	var img: Image = Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		push_error("compare: cannot read " + path)
		return null
	img.convert(Image.FORMAT_RGBA8)
	if img.get_size() != SIZE:
		img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	return img
