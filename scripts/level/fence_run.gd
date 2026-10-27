@tool
class_name FenceRun
extends Node3D
## Chain-link fence along a polyline in local XZ, built from fence_segment.glb
## (3 m) with fence_post.glb at every joint.

const SEGMENT: PackedScene = preload("res://assets/models/fence_segment.glb")
const POST: PackedScene = preload("res://assets/models/fence_post.glb")
const SEGMENT_LENGTH: float = 3.0

@export var points: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3(9.0, 0.0, 0.0)]):
	set(value):
		points = value
		_rebuild_if_ready()


func _ready() -> void:
	_rebuild()


func _rebuild_if_ready() -> void:
	if is_node_ready():
		_rebuild()


func _rebuild() -> void:
	for c: Node in get_children():
		remove_child(c)
		c.queue_free()
	for i: int in range(points.size() - 1):
		var a: Vector3 = Vector3(points[i].x, 0.0, points[i].z)
		var b: Vector3 = Vector3(points[i + 1].x, 0.0, points[i + 1].z)
		var length: float = a.distance_to(b)
		var count: int = maxi(1, roundi(length / SEGMENT_LENGTH))
		var step: float = length / count
		var dir: Vector3 = (b - a).normalized()
		var yaw: float = atan2(-dir.z, dir.x)  # segment spans local X
		for k: int in count:
			var seg: Node3D = SEGMENT.instantiate() as Node3D
			seg.position = a + dir * (step * (k + 0.5))
			seg.rotation.y = yaw
			seg.scale.x = step / SEGMENT_LENGTH
			add_child(seg)
			_post(a + dir * (step * k), yaw)
	if points.size() >= 2:
		var last: Vector3 = points[points.size() - 1]
		_post(Vector3(last.x, 0.0, last.z), 0.0)


func _post(pos: Vector3, yaw: float) -> void:
	var post: Node3D = POST.instantiate() as Node3D
	post.position = pos
	post.rotation.y = yaw
	add_child(post)
