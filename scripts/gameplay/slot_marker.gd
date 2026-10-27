class_name SlotMarker
extends StaticBody3D
## Clickable highlight for a free StorageSlot. Hidden markers have no
## collision layer, so the click raycast only sees highlighted slots.

const COLOR: Color = Color(0.24, 1.0, 0.45, 0.5)
const LIFT_COLOR: Color = Color(0.35, 0.75, 1.0, 0.5)

var slot: StorageSlot = null


## materials: shared cache (Color -> material) owned by the caller.
static func create(p_slot: StorageSlot, materials: Dictionary) -> SlotMarker:
	var marker: SlotMarker = SlotMarker.new()
	marker.slot = p_slot
	marker.name = "Slot_%d" % p_slot.id
	marker.collision_mask = 0
	marker.transform = p_slot.pallet_transform()

	var plate: MeshInstance3D = MeshInstance3D.new()
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(1.2, 0.06, 0.8)
	plate.mesh = mesh
	plate.position.y = 0.04
	plate.material_override = _material(LIFT_COLOR if p_slot.needs_lift() else COLOR, materials)
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.add_child(plate)

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(1.2, 1.0, 0.8)
	shape.shape = box
	shape.position.y = 0.5
	marker.add_child(shape)
	marker.set_shown(false)
	return marker


func set_shown(shown: bool) -> void:
	visible = shown
	collision_layer = GameplayConfig.SLOT_LAYER if shown else 0


static func _material(color: Color, materials: Dictionary) -> StandardMaterial3D:
	if materials.has(color):
		return materials[color]
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.no_depth_test = false
	materials[color] = mat
	return mat
