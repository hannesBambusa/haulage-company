class_name CargoUnit
extends RefCounted
## One pallet of a contract. Pure data; the 3D pallet is `node` (a CargoPallet).
## Tracks the pallet's whole lifecycle: `state` (see State), a readable
## `location_code` ("T-Dock1-03", "INBOUND-05", "A1-L2-1", "Forklift 1") and a
## timestamped `history` with one entry per state transition.

## Lifecycle, in order. Every pallet walks through all of them.
enum State { IN_TRUCK, UNLOADING, INBOUND, PUTAWAY, STORED, PICKING, OUTBOUND, LOADING, LOADED, DELIVERED }

const STATE_NAMES: PackedStringArray = [
	"In truck", "Unloading", "Inbound", "Put-away", "Stored", "Picking", "Outbound", "Loading", "Loaded", "Delivered",
]

var id: int = 0
## Unique pallet ID shown to the player, e.g. "PL-000123".
var code: String = ""
var contract_id: String = ""
var contract: Contract = null
## Index within its contract, 0-based.
var index: int = 0
var state: State = State.IN_TRUCK
## Where the pallet is now, as a location code.
var location_code: String = "En route"
## One Dictionary per transition: {time, day, minutes, state, location, agent}.
## `time` is GameState.now() (absolute game minutes).
var history: Array[Dictionary] = []
## Slot the unit sits in (a trailer, zone, rack or floor slot); null while carried.
var slot: StorageSlot = null
## Carry job currently moving or queued for this unit.
var job: RefCounted = null
var node: Node3D = null


func is_busy() -> bool:
	return job != null


func is_carried() -> bool:
	return state == State.UNLOADING or state == State.PUTAWAY or state == State.PICKING or state == State.LOADING


func state_name() -> String:
	return STATE_NAMES[state]


static func name_of(s: State) -> String:
	return STATE_NAMES[s]


## Moves the unit to a new lifecycle state and logs it in the history.
## `at` is absolute game minutes; `agent` who moved it ("" for none).
func record(new_state: State, location: String, agent: String, at: float, day: int, minutes: float) -> void:
	state = new_state
	location_code = location
	history.append({
		"time": at,
		"day": day,
		"minutes": minutes,
		"state": new_state,
		"location": location,
		"agent": agent,
	})


## Updates where the unit is without a state change (no history entry).
func relocate(location: String) -> void:
	location_code = location


## Agent that performed the transition into `s`, or "" when there was none.
func agent_for(s: State) -> String:
	for e: Dictionary in history:
		if int(e.state) == s:
			return String(e.agent)
	return ""
