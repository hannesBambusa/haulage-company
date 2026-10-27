extends SceneTree
## Godot --headless --path . --script res://tools/level_gen/unreach.gd
## Prints every unreachable storage slot.

func _initialize() -> void:
	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i: int in 30:
		await process_frame
	var grid: StorageGrid = get_first_node_in_group(&"storage_grid") as StorageGrid
	var traffic = null
	for n: Node in main.find_children("*", "", true, false):
		if n.get_script() != null and str(n.get_script().resource_path).ends_with("/traffic.gd"):
			traffic = n
	var lift = null
	if traffic != null and traffic.board != null:
		for a in traffic.board.agents:
			if str(a.get_script().resource_path).contains("forklift"):
				lift = a
				break
	var bad: int = 0
	for s: StorageSlot in grid.slots:
		if not s.reachable and not s.house_stock:
			bad += 1
			print("UNREACHABLE %s zone=%d pos=(%.2f, %.2f) out=(%.0f, %.0f) %s" % [s.label, s.zone, s.position.x, s.position.z, s.out_dir.x, s.out_dir.z, _why(traffic, lift, grid, s)])
	print("UNREACHABLE_TOTAL %d" % bad)
	quit()


## Names the first static obstacle that blocks the slot's approach.
func _why(traffic, lift, grid: StorageGrid, s: StorageSlot) -> String:
	if traffic == null or lift == null:
		return ""
	var reach: float = lift.reach_for(s)
	var pose: Array = traffic.staging_pose(s, reach)
	var a3: Vector3 = grid.approach_point(s, reach)
	var a2: Vector2 = Vector2(a3.x, a3.z)
	var st: Vector2 = pose[0]
	for i: int in 9:
		var p: Vector2 = st.lerp(a2, i / 8.0)
		var h: int = traffic.static_hit(lift.body_boxes_at(p, pose[1]), 0.05, traffic.rack_rect_for(s))
		if h >= 0:
			return "body hit %s" % traffic.static_names[h]
	var h2: int = traffic.static_hit(lift.footprints_at(st, pose[1], true), traffic.STATIC_CLEARANCE)
	if h2 >= 0:
		return "stage hit %s at %s" % [traffic.static_names[h2], st]
	return "?"
