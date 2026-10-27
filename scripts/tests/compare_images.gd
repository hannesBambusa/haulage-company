extends SceneTree
## Builds a comparison PNG: reference | screenshot side by side, plus an
## optional 50% overlay. Optional crop region (in 1536x1024 space).
## Godot --headless --path . --script res://scripts/tests/compare_images.gd -- \
##   --ref=res://docs/reference/gameplay-target.png --shot=res://docs/previews/hud.png \
##   --out=res://docs/previews/compare_hud.png [--rect=x,y,w,h] [--stack] [--overlay]

func _initialize() -> void:
	var a: Dictionary = {}
	for arg: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var ref: Image = Image.load_from_file(ProjectSettings.globalize_path(a.ref))
	var shot: Image = Image.load_from_file(ProjectSettings.globalize_path(a.shot))
	for img: Image in [ref, shot]:
		img.convert(Image.FORMAT_RGBA8)
		if img.get_size() != Vector2i(1536, 1024):
			img.resize(1536, 1024, Image.INTERPOLATE_LANCZOS)
	var rect: Rect2i = Rect2i(0, 0, 1536, 1024)
	if a.has("rect"):
		var p: PackedStringArray = String(a.rect).split(",")
		rect = Rect2i(p[0].to_int(), p[1].to_int(), p[2].to_int(), p[3].to_int())
	var r: Image = ref.get_region(rect)
	var s: Image = shot.get_region(rect)
	var out: Image
	if a.has("overlay"):
		out = r.duplicate()
		for y: int in rect.size.y:
			for x: int in rect.size.x:
				out.set_pixel(x, y, r.get_pixel(x, y).lerp(s.get_pixel(x, y), 0.5))
	elif a.has("stack"):
		out = Image.create(rect.size.x, rect.size.y * 2 + 4, false, Image.FORMAT_RGBA8)
		out.fill(Color.MAGENTA)
		out.blit_rect(r, Rect2i(Vector2i.ZERO, rect.size), Vector2i(0, 0))
		out.blit_rect(s, Rect2i(Vector2i.ZERO, rect.size), Vector2i(0, rect.size.y + 4))
	else:
		out = Image.create(rect.size.x * 2 + 4, rect.size.y, false, Image.FORMAT_RGBA8)
		out.fill(Color.MAGENTA)
		out.blit_rect(r, Rect2i(Vector2i.ZERO, rect.size), Vector2i(0, 0))
		out.blit_rect(s, Rect2i(Vector2i.ZERO, rect.size), Vector2i(rect.size.x + 4, 0))
	out.save_png(ProjectSettings.globalize_path(a.out))
	print("wrote ", a.out, " ", out.get_size())
	quit()
