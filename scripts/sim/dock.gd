class_name Dock
extends Node
## One loading dock. Pure sim, no 3D. Whoever moves the 3D truck calls
## truck_arrived() / truck_departed().
## Timer mode (default): the dock moves one pallet every minutes_per_pallet.
## Physical mode (physical_transfer = true, set by CargoFlow): the dock only
## counts. Whoever carries the pallets calls report_pallet() as each one is set
## down, and finish_transfer() once the trailer is empty (unloading) or the
## last pallet is inside and the lane is clear (loading).
## Delivery: IDLE -> ARRIVING -> UNLOADING -> DEPARTING -> IDLE.
## Pickup:   IDLE -> ARRIVING -> LOADING   -> DEPARTING -> IDLE.

enum State { IDLE, ARRIVING, UNLOADING, DEPARTING, LOADING }

signal state_changed(state: State)
signal progress_changed(done: int, total: int)
signal ready_to_depart
signal unload_completed(dock: Dock)
signal load_completed(dock: Dock)

@export var dock_id: int = 1
@export var pallets_total: int = 8
## Game minutes needed to move one pallet (timer mode).
@export var minutes_per_pallet: float = 3.0
## Progress is driven from outside (report_pallet / finish_transfer).
@export var physical_transfer: bool = false

var pallets_done: int = 0
var truck_company: String = ""
var cargo_type: String = ""
var state: State = State.IDLE
## True for a pickup truck (loads instead of unloading).
var loading: bool = false
## Contract the current truck belongs to, if any.
var contract: Contract = null
## Optional check before each pallet: func(dock: Dock) -> bool. While it
## returns false the dock holds the next pallet (inbound full, or the pickup
## cargo has not reached the outbound zone yet).
var transfer_gate: Callable = Callable()

## Clock node that emits minutes_advanced(float). Defaults to the GameState
## autoload; tests can assign their own before the dock enters the tree.
var clock: Node = null

var _pallet_timer: float = 0.0


func _ready() -> void:
	add_to_group(&"docks")
	if clock == null:
		clock = get_node_or_null(^"/root/GameState")
	if clock != null and clock.has_signal(&"minutes_advanced"):
		clock.minutes_advanced.connect(advance_minutes)


func is_idle() -> bool:
	return state == State.IDLE


func is_transferring() -> bool:
	return state == State.UNLOADING or state == State.LOADING


## Books a truck for this dock. IDLE -> ARRIVING.
func assign_truck(company: String, cargo: String, pallets: int = -1, pickup: bool = false) -> bool:
	if state != State.IDLE:
		return false
	truck_company = company
	cargo_type = cargo
	loading = pickup
	if pallets > 0:
		pallets_total = pallets
	pallets_done = 0
	_pallet_timer = 0.0
	_set_state(State.ARRIVING)
	progress_changed.emit(pallets_done, pallets_total)
	return true


## Truck is parked at the dock. ARRIVING -> UNLOADING (or LOADING).
func truck_arrived() -> void:
	if state != State.ARRIVING:
		push_warning("Dock %d: truck_arrived() in state %s" % [dock_id, State.keys()[state]])
		return
	_pallet_timer = 0.0
	_set_state(State.LOADING if loading else State.UNLOADING)


## Truck has left the dock. DEPARTING -> IDLE.
func truck_departed() -> void:
	if state != State.DEPARTING:
		push_warning("Dock %d: truck_departed() in state %s" % [dock_id, State.keys()[state]])
		return
	truck_company = ""
	cargo_type = ""
	pallets_done = 0
	loading = false
	contract = null
	_set_state(State.IDLE)
	progress_changed.emit(pallets_done, pallets_total)


## Advances the transfer by game_minutes. Connected to the clock, public for tests.
func advance_minutes(game_minutes: float) -> void:
	if not is_transferring() or physical_transfer:
		return
	_pallet_timer += game_minutes
	while _pallet_timer >= minutes_per_pallet and pallets_done < pallets_total:
		if transfer_gate.is_valid() and not transfer_gate.call(self):
			_pallet_timer = minutes_per_pallet
			break
		_pallet_timer -= minutes_per_pallet
		pallets_done += 1
		progress_changed.emit(pallets_done, pallets_total)
	if pallets_done >= pallets_total:
		_complete()


## Physical mode: one pallet was set down (in INBOUND, or in the trailer).
func report_pallet() -> void:
	if not is_transferring() or pallets_done >= pallets_total:
		push_warning("Dock %d: report_pallet() in state %s at %d/%d" % [dock_id, State.keys()[state], pallets_done, pallets_total])
		return
	pallets_done += 1
	progress_changed.emit(pallets_done, pallets_total)


## Physical mode: ends the transfer once every pallet is reported.
## Returns true when the dock moved to DEPARTING.
func finish_transfer() -> bool:
	if not is_transferring() or pallets_done < pallets_total:
		return false
	_complete()
	return true


func _complete() -> void:
	var was_loading: bool = state == State.LOADING
	_set_state(State.DEPARTING)
	if was_loading:
		load_completed.emit(self)
	else:
		unload_completed.emit(self)
	ready_to_depart.emit()


func state_name() -> String:
	return String(State.keys()[state]).capitalize()


func _set_state(new_state: State) -> void:
	state = new_state
	state_changed.emit(state)
