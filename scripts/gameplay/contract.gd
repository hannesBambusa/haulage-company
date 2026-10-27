class_name Contract
extends RefCounted
## One client contract: an inbound delivery that is stored for a number of
## contract days and then collected. Pure data, driven by ContractManager and
## CargoFlow.

enum State { AVAILABLE, ACCEPTED, INBOUND, STORED, PICKUP_SCHEDULED, OUTBOUND, COMPLETED }

var id: String = ""
var company: String = ""
var cargo: String = ""
var pack: String = ""
var desc: String = ""
var tag: String = "Standard"
var logo: String = ""
var color: Color = Color.WHITE
var tons: int = 0
var pallets: int = 0
var handling_fee: int = 0
## Dollars per pallet per contract day while the pallet is in storage.
var storage_fee: int = 0
## Contract days the cargo stays in storage before the client collects it.
var storage_days: int = 1
## Game minutes from accepting to the inbound truck arriving.
var inbound_delay: float = 8.0

var state: State = State.AVAILABLE
var units: Array[CargoUnit] = []
## Storage revenue earned so far, paid out on completion.
var storage_accrued: float = 0.0
## Game minutes spent in STORED (counts towards storage_days).
var stored_minutes: float = 0.0
## Absolute game minutes (GameState.now()) of the scheduled trucks.
var inbound_at: float = -1.0
var pickup_at: float = -1.0
var offered_at: float = 0.0
var payout: int = 0


func state_name() -> String:
	return String(State.keys()[state]).capitalize().replace("Pickup Scheduled", "Pickup scheduled")


func is_active() -> bool:
	return state != State.AVAILABLE and state != State.COMPLETED


func count_in(state: CargoUnit.State) -> int:
	var n: int = 0
	for u: CargoUnit in units:
		if u.state == state:
			n += 1
	return n


## Pallets that will still need a storage slot (not stored, not on their way).
func pending_storage() -> int:
	if state != State.ACCEPTED and state != State.INBOUND:
		return 0
	var n: int = 0
	for u: CargoUnit in units:
		if u.state <= CargoUnit.State.INBOUND:
			var job: CarryJob = u.job as CarryJob
			if job == null or job.to_slot == null or not job.to_slot.is_storage():
				n += 1
	return n


func estimated_storage() -> int:
	return pallets * storage_fee * storage_days


func estimated_total() -> int:
	return handling_fee + estimated_storage()


func short_code() -> String:
	return id.get_slice("-", 0)
