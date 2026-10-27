class_name CarryJob
extends RefCounted
## Move one pallet from one slot to another. Queued on the JobBoard and run by
## a CarryAgent. Each kind is one leg of the pallet lifecycle:
##   UNLOAD       trailer slot -> INBOUND     (Unloader forklift)
##   STORE        INBOUND -> rack / floor      (Rack forklift, "put-away")
##   TO_OUTBOUND  rack / floor -> OUTBOUND     (Rack forklift, "picking")
##   LOAD         OUTBOUND -> trailer slot     (Loader forklift)
##   RELOCATE     a pallet standing in a forklift's way -> a slot where it
##                blocks nobody; run inline by the blocked forklift, the
##                pallet keeps its lifecycle state (never queued)
## to_slot may be null: the board picks the target when an agent takes the
## job (a free INBOUND / OUTBOUND slot, or the next trailer slot from the nose).

enum Kind { STORE, TO_OUTBOUND, UNLOAD, LOAD, RELOCATE }
## Forklift roles; each job kind belongs to one.
enum Role { UNLOADER, RACK, LOADER }

const ROLE_NAMES: PackedStringArray = ["Unloader", "Rack", "Loader"]

var kind: Kind = Kind.STORE
var unit: CargoUnit = null
var from_slot: StorageSlot = null
var to_slot: StorageSlot = null
var agent: Node = null
## LOAD jobs: the dock lane whose trailer takes the pallet.
var bay: TrailerBay = null
## STORE jobs to a ground-level slot (rack L1 or floor) given to the Jack
## operator (a worker with a hand pallet jack) instead of the Rack forklift.
var by_jack: bool = false


func _init(p_kind: Kind, p_unit: CargoUnit, p_to: StorageSlot = null) -> void:
	kind = p_kind
	unit = p_unit
	from_slot = p_unit.slot
	to_slot = p_to


func needs_lift() -> bool:
	return (from_slot != null and from_slot.needs_lift()) or (to_slot != null and to_slot.needs_lift())


## Lifecycle state while the pallet is on the carrier.
func carried_state() -> CargoUnit.State:
	match kind:
		Kind.RELOCATE:
			return unit.state
		Kind.UNLOAD:
			return CargoUnit.State.UNLOADING
		Kind.STORE:
			return CargoUnit.State.PUTAWAY
		Kind.TO_OUTBOUND:
			return CargoUnit.State.PICKING
	return CargoUnit.State.LOADING


## Lifecycle state once the pallet is set down at to_slot.
func placed_state() -> CargoUnit.State:
	match kind:
		Kind.RELOCATE:
			return unit.state
		Kind.UNLOAD:
			return CargoUnit.State.INBOUND
		Kind.STORE:
			return CargoUnit.State.STORED
		Kind.TO_OUTBOUND:
			return CargoUnit.State.OUTBOUND
	return CargoUnit.State.LOADED


## The forklift role that does this job.
func role() -> Role:
	match kind:
		Kind.UNLOAD:
			return Role.UNLOADER
		Kind.LOAD:
			return Role.LOADER
	return Role.RACK


## Pallet-jack jobs for workers: put-away to ground level by the Jack operator.
func wants_worker() -> bool:
	return by_jack


func touches_trailer() -> bool:
	return kind == Kind.UNLOAD or kind == Kind.LOAD
