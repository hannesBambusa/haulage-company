extends SceneTree
## Dev helper: prints node tree, AABB and animations of every glb in assets/models.
## Godot --headless --path . --script res://scripts/tools/dump_models.gd

func _initialize() -> void:
	var dir: DirAccess = DirAccess.open("res://assets/models")
	for f: String in dir.get_files():
		if not f.ends_with(".glb"):
			continue
		var ps: PackedScene = load("res://assets/models/" + f)
		var n: Node3D = ps.instantiate()
		root.add_child(n)
		var box: AABB = _aabb(n, Transform3D.IDENTITY, true)
		print("== ", f, " aabb pos=", box.position, " size=", box.size)
		_tree(n, "  ", Transform3D.IDENTITY)
		var ap: AnimationPlayer = n.find_child("AnimationPlayer", true, false)
		if ap:
			print("  anims: ", ap.get_animation_list())
		n.queue_free()
	quit()

func _tree(n: Node, ind: String, xf: Transform3D) -> void:
	var extra: String = ""
	var t: Transform3D = xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
		extra = " pos=" + str(t.origin.snapped(Vector3.ONE * 0.01))
	if n is MeshInstance3D:
		extra += " mats=" + str((n as MeshInstance3D).mesh.get_surface_count())
	if ind.length() < 10:
		print(ind, n.name, " [", n.get_class(), "]", extra)
	for c: Node in n.get_children():
		_tree(c, ind + "  ", t)

func _aabb(n: Node, xf: Transform3D, first: bool) -> AABB:
	var box: AABB = AABB()
	var t: Transform3D = xf
	if n is Node3D and not first:
		t = xf * (n as Node3D).transform
	var has: bool = false
	if n is MeshInstance3D and not String(n.name).ends_with("-colonly"):
		box = t * (n as MeshInstance3D).get_aabb()
		has = true
	for c: Node in n.get_children():
		var b: AABB = _aabb(c, t, false)
		if b.size != Vector3.ZERO:
			box = b if not has else box.merge(b)
			has = true
	return box
