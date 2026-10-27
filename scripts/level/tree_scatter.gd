@tool
class_name TreeScatter
extends Node3D
## Deterministic scatter of low-poly trees along a polyline in local XZ, in a
## band of depth metres to the left of the walking direction.

@export var tree_scenes: Array[PackedScene] = []:
	set(value):
		tree_scenes = value
		_rebuild_if_ready()
@export var points: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3(20.0, 0.0, 0.0)]):
	set(value):
		points = value
		_rebuild_if_ready()
@export var spacing: float = 4.0:
	set(value):
		spacing = value
		_rebuild_if_ready()
@export var depth: float = 4.0:
	set(value):
		depth = value
		_rebuild_if_ready()
@export var jitter: float = 1.2:
	set(value):
		jitter = value
		_rebuild_if_ready()
@export var scale_range: Vector2 = Vector2(0.8, 1.15):
	set(value):
		scale_range = value
		_rebuild_if_ready()
@export var random_seed: int = 1:
	set(value):
		random_seed = value
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
	if tree_scenes.is_empty() or spacing <= 0.0:
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = random_seed
	for i: int in range(points.size() - 1):
		var a: Vector3 = Vector3(points[i].x, 0.0, points[i].z)
		var b: Vector3 = Vector3(points[i + 1].x, 0.0, points[i + 1].z)
		var length: float = a.distance_to(b)
		var dir: Vector3 = (b - a).normalized()
		var left: Vector3 = Vector3(dir.z, 0.0, -dir.x)
		var t: float = rng.randf() * spacing * 0.5
		while t < length:
			var scene: PackedScene = tree_scenes[rng.randi() % tree_scenes.size()]
			if scene != null:
				var tree: Node3D = scene.instantiate() as Node3D
				var along: float = t + rng.randf_range(-jitter, jitter)
				tree.position = a + dir * along + left * rng.randf_range(0.0, depth)
				tree.rotation.y = rng.randf() * TAU
				tree.scale = Vector3.ONE * rng.randf_range(scale_range.x, scale_range.y)
				add_child(tree)
			t += spacing
