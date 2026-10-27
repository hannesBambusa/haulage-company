class_name StorageSlot
extends RefCounted
## One pallet position: a rack beam level, a floor spot, a spot in the
## INBOUND / OUTBOUND zones, or a cargo slot inside a parked trailer.
## Grid slots are built by StorageGrid from the level at runtime; trailer slots
## belong to a TrailerBay and ride on the trailer (`anchor`), so their world
## position follows the truck.

enum Zone { INBOUND, OUTBOUND, RACK, FLOOR, TRAILER }

var id: int = 0
var zone: Zone = Zone.FLOOR
## World position of the pallet's bottom centre.
var position: Vector3 = Vector3.ZERO:
	get:
		if anchor != null and is_instance_valid(anchor):
			return anchor.global_transform * local.origin
		return position
## Pallet yaw. The pallet model is 1.2 m along its local X.
var yaw: float = 0.0
## Unit vector on the ground pointing from the pallet to where an agent stands.
var out_dir: Vector3 = Vector3.BACK
## Rack beam level (0 = ground). Always 0 for floor and zone slots.
var level: int = 0
## False when a forklift has no room to drive square onto it (set by Traffic).
var reachable: bool = true
## Taken by decorative "house stock" from the level; never free.
var house_stock: bool = false
var unit: CargoUnit = null
## Unit on its way here.
var reserved_by: CargoUnit = null
## Location code, e.g. "INBOUND-05", "A1-L2-1", "FLOOR-07", "T-Dock1-03".
var label: String = ""
## Trailer slots: the trailer node and the slot's transform in its space.
var anchor: Node3D = null
var local: Transform3D = Transform3D.IDENTITY
## Trailer slots: the TrailerBay (dock lane) they belong to.
var bay: Node = null
## Trailer slots: 0-based index, 0 = Slot_01 at the nose.
var index: int = 0
## Access geometry (set by Traffic at startup, grid slots only):
## slots whose pallet stands in this slot's approach straight, and slots
## whose approach this slot's pallet would stand in.
var access_blockers: Array[StorageSlot] = []
var blocks_access_of: Array[StorageSlot] = []
## A pallet here would stand in a dock lane, a lane apron or another
## area's approach room: never set one down here.
var keep_clear_hit: bool = false


func is_free() -> bool:
	return not house_stock and unit == null and reserved_by == null


func is_storage() -> bool:
	return zone == Zone.RACK or zone == Zone.FLOOR


func is_trailer() -> bool:
	return zone == Zone.TRAILER


## Above-ground rack levels need the forklift.
func needs_lift() -> bool:
	return zone == Zone.RACK and level > 0


func pallet_transform() -> Transform3D:
	if anchor != null and is_instance_valid(anchor):
		return anchor.global_transform * local
	return Transform3D(Basis(Vector3.UP, yaw), position)
