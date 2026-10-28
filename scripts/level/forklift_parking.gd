class_name ForkliftParking
extends Node3D
## Painted forklift parking: one open-ended bay per JobBoard parking spot
## inside JobBoard.parking_area (back line and sides, open where the
## forklift drives in), a "P" with the bay number at the open end, and the
## level's loose decor cleared off the area.

@export var job_board_path: NodePath
@export var storage_grid_path: NodePath
## Bay size: across the forklift and along it (forks to counterweight).
@export var bay_width: float = 2.5
@export var bay_depth: float = 5.2
## The bay centre is this far from the spot towards the open end (room
## for the label in front of the counterweight).
@export var spot_offset: float = 0.4
@export var line_color: Color = Color(0.95, 0.95, 0.92)
@export var font: Font


func _ready() -> void:
	_build.call_deferred()


func _build() -> void:
	var board: JobBoard = get_node_or_null(job_board_path) as JobBoard
	if board == null or not board.parking_area.has_area():
		return
	var n: int = 0
	for i: int in board.parking_spots.size():
		var p: Vector3 = board.parking_spots[i]
		if not board.parking_area.has_point(Vector2(p.x, p.z)):
			continue
		n += 1
		var yaw: float = deg_to_rad(board.parking_yaws[i]) if i < board.parking_yaws.size() else 0.0
		_paint_bay(p, yaw, n)
	var grid: StorageGrid = get_node_or_null(storage_grid_path) as StorageGrid
	if grid != null:
		var area: Rect2 = board.parking_area
		grid.hide_decor(func(q: Vector3) -> bool: return area.has_point(Vector2(q.x, q.z)))


func _paint_bay(spot: Vector3, yaw: float, number: int) -> void:
	# forks point forward (-Z of the forklift): the back line is there
	var fwd: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var side: Vector3 = Vector3(fwd.z, 0.0, -fwd.x)
	var c: Vector3 = Vector3(spot.x, 0.0, spot.z) - fwd * spot_offset
	var back: Vector3 = c + fwd * bay_depth * 0.5
	var front: Vector3 = c - fwd * bay_depth * 0.5
	var hw: float = bay_width * 0.5
	var line: MarkingLine = MarkingLine.new()
	line.name = "Bay%d" % number
	line.color = line_color
	line.width = 0.12
	line.points = PackedVector3Array([front + side * hw, back + side * hw, back - side * hw, front - side * hw])
	add_child(line)
	var label: Label3D = Label3D.new()
	label.name = "Bay%dLabel" % number
	label.text = "P%d" % number
	label.font = font
	label.font_size = 96
	label.pixel_size = 0.006
	label.shaded = true
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	label.modulate = Color(line_color, 0.9)
	label.outline_size = 0
	add_child(label)
	# flat on the floor near the open end, readable from the drive-in side
	var at: Vector3 = front + fwd * 0.75
	label.global_transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -PI * 0.5), at + Vector3.UP * 0.016)
