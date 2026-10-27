class_name PropItem
extends Node3D
## A prop a worker can pick up: hand tools (broom, mop, cup, clipboard,
## scanner, phone, wrench) and floor props (bucket, wet floor sign, toolbox).
## Knows where it belongs (home parent and transform), who holds it and
## whether it lies somewhere it should not (loose: dropped on an interrupt,
## waiting for someone to tidy it away). Hand tools are sized for the 1.2
## scale workers wherever they are; floor props keep their real size.

enum Where { HOME, HELD, PLACED, LOOSE, BINNED }

## Model scale of hand tools, so the size does not jump between hand and shelf.
const HAND_SCALE: float = 1.2

var kind: StringName = &""
var floor_prop: bool = false
var where: Where = Where.HOME
var holder: Node3D = null
var home_parent: Node3D = null
var home_xform: Transform3D = Transform3D.IDENTITY
## Rect on the floor while the prop stands on it (for walking round it).
var footprint: Rect2 = Rect2()
## Someone is on the way to fetch it (one claim at a time).
var claimed_by: Object = null
var model: Node3D = null


static func make(p_kind: StringName, scene: PackedScene, is_floor: bool) -> PropItem:
	var p: PropItem = PropItem.new()
	p.kind = p_kind
	p.name = "Prop_" + String(p_kind)
	p.floor_prop = is_floor
	p.model = scene.instantiate() as Node3D
	p.add_child(p.model)
	# physics colliders of floor props are not needed while they move about
	for body: Node in p.model.find_children("*", "CollisionObject3D", true, false):
		(body as CollisionObject3D).collision_layer = 0
		(body as CollisionObject3D).collision_mask = 0
	return p


## Scale this prop has in the world (not in a hand).
func world_scale() -> float:
	return 1.0 if floor_prop else HAND_SCALE


func set_home(parent: Node3D, xf: Transform3D) -> void:
	home_parent = parent
	home_xform = xf.orthonormalized().scaled_local(Vector3.ONE * world_scale())


func is_available() -> bool:
	return claimed_by == null and (where == Where.HOME or where == Where.LOOSE or where == Where.PLACED) and holder == null


## Rect it covers on the floor at its current place (x, z).
func floor_rect() -> Rect2:
	var box: AABB = AABB()
	var first: bool = true
	for m: Node in find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m as MeshInstance3D
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return Rect2(box.position.x, box.position.z, box.size.x, box.size.z)
