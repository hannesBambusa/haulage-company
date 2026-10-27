class_name BreakArea
extends Node3D
## The staff break corner: coffee machine, water cooler, trash bin, a table
## with two chairs, a bench and a vending machine (their -colonly colliders
## become Traffic obstacles, the scene sits under the level), plus marker
## spots: where to stand at the machine, the cooler and the bin, and the
## middle of the standing conversation circle.

## Seat: {node, pos: Vector2, yaw: float, front: Vector2, taken_by}.
var seats: Array[Dictionary] = []
func _ready() -> void:
	add_to_group(&"break_area")
	for chair_name: String in ["ChairA", "ChairB"]:
		var c: Node3D = get_node_or_null(chair_name) as Node3D
		if c != null:
			_add_seat(c, Vector3.ZERO)
	# the bench by the vending machine is for show: the circle stands in front of it


func _add_seat(n: Node3D, local: Vector3) -> void:
	var g: Vector3 = n.global_transform * local
	var f: Vector3 = n.global_basis.z.normalized()
	var front: Vector2 = Vector2(f.x, f.z)
	seats.append({"node": n, "pos": Vector2(g.x, g.z), "front": front, "yaw": atan2(-front.x, -front.y), "taken_by": null})


static func flat(n: Node3D) -> Vector2:
	return Vector2(n.global_position.x, n.global_position.z)


## [position, yaw facing `toward`] for a marker.
func spot(marker: String, toward: String) -> Array:
	var m: Node3D = get_node(marker) as Node3D
	var t: Node3D = get_node(toward) as Node3D
	var p: Vector2 = flat(m)
	return [p, WorkerActor.yaw_towards(p, flat(t))]


## The floor of the break corner: people who are not on a break stay out.
func floor_rects() -> Array[Rect2]:
	return [Rect2(position.x - 2.5, position.z - 2.4, 5.0, 4.6), Rect2(position.x - 2.5, position.z + 2.2, 3.6, 6.6)]


func group_center() -> Vector2:
	return flat(get_node(^"GroupCenter") as Node3D)


## Where a fresh cup appears (under the machine's spout).
func cup_spawn() -> Transform3D:
	var m: Node3D = get_node(^"CoffeeMachine") as Node3D
	var f: Vector3 = m.global_basis.z.normalized()
	return Transform3D(Basis.looking_at(-f).scaled(Vector3.ONE * PropItem.HAND_SCALE), m.global_position + f * 0.12 + Vector3(-0.2, 0.98, 0.0))


## A point just inside the bin's opening.
func bin_mouth() -> Vector3:
	return (get_node(^"TrashBin") as Node3D).global_position + Vector3(0.0, 0.72, 0.0)


func free_seat(near: Vector2 = Vector2.INF) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = INF
	for s: Dictionary in seats:
		if s.taken_by != null:
			continue
		var d: float = 0.0 if near == Vector2.INF else (s.pos as Vector2).distance_to(near)
		if d < best_d:
			best_d = d
			best = s
	return best
