class_name CargoPallet
extends StaticBody3D
## The 3D pallet of one CargoUnit: a pallet_boxes model, a contract-coloured
## tag on top, a click box on GameplayConfig.CARGO_LAYER and a selection ring.

const MODELS: Array[PackedScene] = [
	preload("res://assets/models/pallet_boxes_a.glb"),
	preload("res://assets/models/pallet_boxes_b.glb"),
	preload("res://assets/models/pallet_boxes_c.glb"),
]
const HEIGHTS: PackedFloat32Array = [0.908, 1.168, 1.008]
const RING_COLOR: Color = Color(1.0, 0.85, 0.2)

var unit: CargoUnit = null
var _ring: MeshInstance3D


static func create(p_unit: CargoUnit) -> CargoPallet:
	var pallet: CargoPallet = CargoPallet.new()
	pallet.setup(p_unit)
	return pallet


func setup(p_unit: CargoUnit) -> void:
	unit = p_unit
	name = "Cargo_%s_%d" % [unit.contract_id, unit.index + 1]
	collision_layer = GameplayConfig.CARGO_LAYER
	collision_mask = 0
	var variant: int = unit.id % MODELS.size()
	var height: float = HEIGHTS[variant]
	add_child(MODELS[variant].instantiate())

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(1.2, height, 0.8)
	shape.shape = box
	shape.position.y = height * 0.5
	add_child(shape)

	var tag: MeshInstance3D = MeshInstance3D.new()
	var tag_mesh: BoxMesh = BoxMesh.new()
	tag_mesh.size = Vector3(0.5, 0.03, 0.36)
	tag.mesh = tag_mesh
	tag.material_override = _flat_material(unit.contract.color if unit.contract != null else Color.WHITE, false)
	tag.position.y = height + 0.015
	tag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tag)

	_ring = MeshInstance3D.new()
	var ring_mesh: BoxMesh = BoxMesh.new()
	ring_mesh.size = Vector3(1.45, 0.04, 1.05)
	_ring.mesh = ring_mesh
	_ring.material_override = _flat_material(RING_COLOR, true)
	_ring.position.y = 0.02
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)


func set_selected(selected: bool) -> void:
	if _ring != null:
		_ring.visible = selected


static func _flat_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.75
	return mat
