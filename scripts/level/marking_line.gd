@tool
class_name MarkingLine
extends MeshInstance3D
## Painted ground line along a polyline in local XZ (Y is ignored), solid or
## dashed. Builds a flat mesh slightly above this node's origin.

@export var points: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3(4.0, 0.0, 0.0)]):
	set(value):
		points = value
		_rebuild_if_ready()
@export var closed: bool = false:
	set(value):
		closed = value
		_rebuild_if_ready()
@export var width: float = 0.15:
	set(value):
		width = value
		_rebuild_if_ready()
## 0 = solid line.
@export var dash_length: float = 0.0:
	set(value):
		dash_length = value
		_rebuild_if_ready()
@export var gap_length: float = 1.0:
	set(value):
		gap_length = value
		_rebuild_if_ready()
@export var color: Color = Color(0.93, 0.74, 0.16):
	set(value):
		color = value
		_rebuild_if_ready()
@export var height: float = 0.012


func _ready() -> void:
	_rebuild()


func _rebuild_if_ready() -> void:
	if is_node_ready():
		_rebuild()


func _rebuild() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pts: PackedVector3Array = points.duplicate()
	if closed and pts.size() > 2:
		pts.append(pts[0])
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var any: bool = false
	for i: int in range(pts.size() - 1):
		var a: Vector3 = Vector3(pts[i].x, height, pts[i].z)
		var b: Vector3 = Vector3(pts[i + 1].x, height, pts[i + 1].z)
		var seg_len: float = a.distance_to(b)
		if seg_len < 0.001:
			continue
		var dir: Vector3 = (b - a) / seg_len
		# Solid outlines extend by half a width so corners close cleanly.
		var ext: float = width * 0.5 if dash_length <= 0.0 else 0.0
		if dash_length <= 0.0:
			_quad(st, a - dir * ext, b + dir * ext, dir)
		else:
			var t: float = 0.0
			while t < seg_len:
				var t1: float = minf(t + dash_length, seg_len)
				_quad(st, a + dir * t, a + dir * t1, dir)
				t = t1 + gap_length
		any = true
	if not any:
		mesh = null
		return
	mesh = st.commit()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	material_override = mat


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, dir: Vector3) -> void:
	var side: Vector3 = Vector3(-dir.z, 0.0, dir.x) * (width * 0.5)
	var v0: Vector3 = a - side
	var v1: Vector3 = a + side
	var v2: Vector3 = b + side
	var v3: Vector3 = b - side
	for v: Vector3 in [v0, v2, v1, v0, v3, v2]:
		st.set_uv(Vector2(v.x, v.z))
		st.add_vertex(v)
