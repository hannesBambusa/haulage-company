class_name TerminalSim
extends Node
## Owns the docks and the truck schedule. Trucks only come for contracts:
## schedule_visit() books a delivery or pickup at a game time, and when it is
## due the visit goes to the first idle dock. Emits request_truck(dock) so a
## driver (3D or fake) brings the truck in.

signal request_truck(dock: Dock)
## A scheduled visit got a dock.
signal visit_started(contract: Contract, dock: Dock)

@export var dock_count: int = 2


class Visit:
	var contract: Contract
	var pickup: bool = false
	var at: float = 0.0
	## Game time it was booked (start of the countdown).
	var since: float = 0.0


var docks: Array[Dock] = []
var _visits: Array[Visit] = []
var _clock: Node = null


func _ready() -> void:
	add_to_group(&"terminal_sim")
	for child: Node in get_children():
		if child is Dock:
			docks.append(child)
	while docks.size() < dock_count:
		var dock: Dock = Dock.new()
		dock.dock_id = docks.size() + 1
		dock.name = "Dock%d" % dock.dock_id
		add_child(dock)
		docks.append(dock)
	for dock: Dock in docks:
		dock.state_changed.connect(_on_dock_state_changed)
	_clock = get_node_or_null(^"/root/GameState")
	if _clock != null:
		_clock.minutes_advanced.connect(_on_minutes_advanced)


func get_dock(id: int) -> Dock:
	for dock: Dock in docks:
		if dock.dock_id == id:
			return dock
	return null


## Books a truck for the contract at absolute game time at_minutes
## (GameState.now()). It docks as soon as it is due and a dock is free.
func schedule_visit(contract: Contract, pickup: bool, at_minutes: float) -> void:
	var visit: Visit = Visit.new()
	visit.contract = contract
	visit.pickup = pickup
	visit.at = at_minutes
	visit.since = float(_clock.call(&"now")) if _clock != null else at_minutes
	_visits.append(visit)
	_dispatch()


## Sends the truck to the first idle dock right away. Returns the dock or null.
func book_now(contract: Contract, pickup: bool) -> Dock:
	var dock: Dock = _first_idle_dock()
	if dock == null:
		return null
	var visit: Visit = Visit.new()
	visit.contract = contract
	visit.pickup = pickup
	_start(visit, dock)
	return dock


func pending_visits() -> int:
	return _visits.size()


## The booked visit for `contract` that has no dock yet, or null.
func pending_visit_for(contract: Contract) -> Visit:
	for visit: Visit in _visits:
		if visit.contract == contract:
			return visit
	return null


func _on_minutes_advanced(_game_minutes: float) -> void:
	if not _visits.is_empty():
		_dispatch()


func _on_dock_state_changed(state: Dock.State) -> void:
	if state == Dock.State.IDLE and not _visits.is_empty():
		_dispatch.call_deferred()


func _dispatch() -> void:
	var now: float = float(_clock.call(&"now")) if _clock != null else INF
	for visit: Visit in _visits.duplicate():
		if visit.at > now:
			continue
		var dock: Dock = _first_idle_dock()
		if dock == null:
			return
		_visits.erase(visit)
		_start(visit, dock)


func _start(visit: Visit, dock: Dock) -> void:
	var c: Contract = visit.contract
	dock.contract = c
	dock.assign_truck(c.company, c.cargo, c.pallets, visit.pickup)
	visit_started.emit(c, dock)
	request_truck.emit(dock)


func _first_idle_dock() -> Dock:
	for dock: Dock in docks:
		if dock.is_idle():
			return dock
	return null
