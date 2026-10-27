extends SceneTree
# args: img1 img2 then rects x,y,w,h ...
func _initialize() -> void:
	var a: PackedStringArray = OS.get_cmdline_user_args()
	var imgs: Array[Image] = []
	for i in 2:
		var im: Image = Image.load_from_file(a[i]); im.convert(Image.FORMAT_RGBA8)
		if im.get_size() != Vector2i(1536, 1024): im.resize(1536, 1024)
		imgs.append(im)
	for k in range(2, a.size()):
		var p: PackedStringArray = a[k].split(",")
		var line: String = "%-22s" % a[k]
		for im in imgs:
			var c: Color = Color(0, 0, 0)
			var n: int = 0
			for y in range(p[1].to_int(), p[1].to_int() + p[3].to_int(), 2):
				for x in range(p[0].to_int(), p[0].to_int() + p[2].to_int(), 2):
					c += im.get_pixel(x, y); n += 1
			c /= n
			line += "  (%3d,%3d,%3d)" % [c.r * 255, c.g * 255, c.b * 255]
		print(line)
	quit()
