class_name CameraCollisionProxies
extends Node3D
## Collision for the camera only. Most level models carry -colonly colliders,
## but vehicles, trailers, furniture, trees and the ground do not. This node
## gives every visible, colliderless MeshInstance3D under `scan_root` a proxy
## body on `proxy_layer` (nothing else reads that layer) and adds a ground
## plane. Proxies follow their source mesh every physics frame, so trucks and
## forklifts push the first-person body instead of passing through it.
## Big hollow meshes (trailer bodies) get trimesh shapes so you can walk inside;
## everything else gets a convex hull, which is solid and pushes out cleanly.
## Built lazily by CameraRig on the first close zoom. Rescans for spawned
## vehicles every `rescan_interval` seconds while active.

@export_flags_3d_physics var proxy_layer: int = 1 << 15
@export var ground_height: float = 0.0
## Meshes shorter than this (markings, decals, slot pads) get no proxy.
@export var min_height: float = 0.05
## Meshes whose AABB volume is above this get a trimesh (hollow) shape.
@export var trimesh_volume: float = 30.0
@export var rescan_interval: float = 1.0

var scan_root: Node
var active: bool = false:
	set(value):
		if value and not active:
			_sync_all(true)
		active = value

var _entries: Dictionary = {}  ## source instance id -> Entry
var _rescan_t: float = 0.0
var _ground: StaticBody3D
static var _shape_cache: Dictionary = {}  ## "mesh id:mode" -> Shape3D


class Entry:
	var source: MeshInstance3D
	var body: AnimatableBody3D
	var last: Transform3D
	var visible: bool = true


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	process_physics_priority = -100


## Builds the ground plane and the first set of proxies. Safe to call again.
func build(root: Node) -> void:
	scan_root = root
	if _ground == null:
		_ground = StaticBody3D.new()
		_ground.name = "GroundPlane"
		_ground.collision_layer = proxy_layer
		_ground.collision_mask = 0
		var shape: CollisionShape3D = CollisionShape3D.new()
		var plane: WorldBoundaryShape3D = WorldBoundaryShape3D.new()
		plane.plane = Plane(Vector3.UP, ground_height)
		shape.shape = plane
		_ground.add_child(shape)
		add_child(_ground)
	rescan()


func is_built() -> bool:
	return _ground != null


func proxy_count() -> int:
	return _entries.size()


## Adds proxies for new meshes and drops those whose source is gone.
func rescan() -> void:
	for id: int in _entries.keys():
		var e: Entry = _entries[id]
		if not is_instance_valid(e.source) or not e.source.is_inside_tree():
			if is_instance_valid(e.body):
				e.body.queue_free()
			_entries.erase(id)
	if scan_root == null:
		return
	for node: Node in scan_root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		if _entries.has(mi.get_instance_id()) or not _needs_proxy(mi):
			continue
		_add_proxy(mi)


func _physics_process(delta: float) -> void:
	if not active or scan_root == null:
		return
	_rescan_t += delta
	if _rescan_t >= rescan_interval:
		_rescan_t = 0.0
		rescan()
	_sync_all(false)


func _sync_all(force: bool) -> void:
	for e: Entry in _entries.values():
		if not is_instance_valid(e.source) or not is_instance_valid(e.body):
			continue
		var xf: Transform3D = e.source.global_transform
		if force or xf != e.last:
			e.last = xf
			e.body.global_transform = xf
		var vis: bool = e.source.is_visible_in_tree()
		if vis != e.visible:
			e.visible = vis
			e.body.collision_layer = proxy_layer if vis else 0


func _needs_proxy(mi: MeshInstance3D) -> bool:
	if mi.mesh == null or mi.get_parent() is Skeleton3D or mi.skin != null:
		return false  # no mesh, or an animated character
	if mi.get_parent() is CollisionObject3D:
		return false
	for child: Node in mi.get_children():
		if child is CollisionObject3D:
			return false  # has its own -colonly collider
	for sibling: Node in mi.get_parent().get_children():
		var co: CollisionObject3D = sibling as CollisionObject3D
		if co != null and co.collision_layer & 1 == 0:
			return false  # gameplay pick body (slot marker, cargo)
	var box: AABB = mi.global_transform * mi.get_aabb()
	if box.size.y < min_height or box.end.y < ground_height + min_height:
		return false  # flat decal or a floor slab under the ground plane
	return true


func _add_proxy(mi: MeshInstance3D) -> void:
	var box: AABB = mi.get_aabb()
	var scale_v: Vector3 = mi.global_transform.basis.get_scale()
	var volume: float = box.size.x * box.size.y * box.size.z * absf(scale_v.x * scale_v.y * scale_v.z)
	var hollow: bool = volume > trimesh_volume
	var shape: Shape3D = _shape_for(mi.mesh, hollow)
	if shape == null:
		return
	var body: AnimatableBody3D = AnimatableBody3D.new()
	body.name = "Proxy_%s" % mi.name
	body.sync_to_physics = false
	body.collision_layer = proxy_layer
	body.collision_mask = 0
	var cs: CollisionShape3D = CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body, true)
	body.set_meta(&"source", mi.get_path())
	body.global_transform = mi.global_transform
	var e: Entry = Entry.new()
	e.source = mi
	e.body = body
	e.last = mi.global_transform
	_entries[mi.get_instance_id()] = e


static func _shape_for(mesh: Mesh, hollow: bool) -> Shape3D:
	var key: String = "%d:%s" % [mesh.get_instance_id(), "tri" if hollow else "hull"]
	if _shape_cache.has(key):
		return _shape_cache[key]
	var shape: Shape3D = mesh.create_trimesh_shape() if hollow else mesh.create_convex_shape(true, false)
	_shape_cache[key] = shape
	return shape
