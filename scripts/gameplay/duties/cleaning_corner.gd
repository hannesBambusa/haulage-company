class_name CleaningCorner
extends Node3D
## The cleaning corner: a wall rack for the broom and the mop, the mop
## bucket, the wet floor sign and the toolbox. Each has a home marker (where
## it stands) and a spot marker (where a worker stands to take it). The
## DutyPlanner puts the props there at startup.


func _ready() -> void:
	add_to_group(&"cleaning_corner")


## Home transform (global) of a prop kind.
func home_xform(kind: StringName) -> Transform3D:
	match kind:
		&"broom":
			return _upright(get_node(^"BroomHome") as Node3D, 0.12)
		&"mop":
			return _upright(get_node(^"MopHome") as Node3D, 0.1)
		&"bucket":
			return Transform3D(Basis(Vector3.UP, PI * 0.5), (get_node(^"BucketHome") as Node3D).global_position)
		&"sign":
			return Transform3D(Basis(Vector3.UP, PI * 0.5), (get_node(^"SignHome") as Node3D).global_position)
		&"toolbox":
			return Transform3D(Basis.IDENTITY, (get_node(^"ToolboxHome") as Node3D).global_position)
	return global_transform


## Where to stand to take or put back a prop: [position, yaw].
func stand_spot(kind: StringName) -> Array:
	var spot_name: String = "ToolSpot"
	var home_name: String = "BroomHome"
	match kind:
		&"bucket":
			spot_name = "BucketSpot"
			home_name = "BucketHome"
		&"sign":
			spot_name = "SignSpot"
			home_name = "SignHome"
		&"toolbox":
			spot_name = "ToolboxSpot"
			home_name = "ToolboxHome"
	var s: Node3D = get_node(spot_name) as Node3D
	var h: Node3D = get_node(home_name) as Node3D
	var p: Vector2 = Vector2(s.global_position.x, s.global_position.z)
	return [p, WorkerActor.yaw_towards(p, Vector2(h.global_position.x, h.global_position.z))]


## A hand tool hanging on the rack: grip up, head down, leaning on the wall.
func _upright(m: Node3D, lean: float) -> Transform3D:
	# tool -Z (grip axis, towards the head) points down; lean the top towards the wall (-X)
	var b: Basis = Basis(Vector3.RIGHT, -PI * 0.5)
	b = Basis(Vector3.BACK, lean) * b
	return Transform3D(b, m.global_position)
