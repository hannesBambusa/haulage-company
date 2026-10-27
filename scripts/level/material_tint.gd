@tool
extends Node3D
## Darkens chosen imported materials under this node (by material name) with
## surface overrides, so the shell can be tuned without touching the .glb.

@export var material_names: PackedStringArray = PackedStringArray(["wall_panel", "wall_rib"]):
	set(value):
		material_names = value
		_apply_if_ready()
@export var tint: Color = Color(0.82, 0.83, 0.85):
	set(value):
		tint = value
		_apply_if_ready()

var _cache: Dictionary = {}


func _ready() -> void:
	_apply()


func _apply_if_ready() -> void:
	if is_node_ready():
		_cache.clear()
		_apply()


func _apply() -> void:
	for node: Node in find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.mesh == null:
			continue
		for i: int in mi.mesh.get_surface_count():
			var src: BaseMaterial3D = mi.mesh.surface_get_material(i) as BaseMaterial3D
			if src == null or not material_names.has(src.resource_name):
				continue
			mi.set_surface_override_material(i, _tinted(src))


func _tinted(src: BaseMaterial3D) -> BaseMaterial3D:
	if not _cache.has(src):
		var mat: BaseMaterial3D = src.duplicate() as BaseMaterial3D
		mat.albedo_color = src.albedo_color * tint
		_cache[src] = mat
	return _cache[src]
