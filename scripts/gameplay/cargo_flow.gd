class_name CargoFlow
extends Node
## Runs the core loop between the contracts, the docks, the storage grid and
## the job board, and owns every pallet's lifecycle (CargoUnit.State):
##   IN_TRUCK   pallets ride in the inbound trailer (visible, on its slots)
##   UNLOADING  a forklift drives up the dock ramp and carries one out
##   INBOUND    set down in the INBOUND zone (the dock counts it here)
##   PUTAWAY    the player sends it to a rack slot; a forklift carries it
##   STORED     in the pallet rack (floor slots only as overflow)
##   PICKING    pickup scheduled, the player sends it out; a forklift carries it
##   OUTBOUND   set down in the OUTBOUND zone
##   LOADING    a worker walks it on a pallet jack up the ramp into the trailer
##   LOADED     set down on a trailer slot, from the nose (Slot_01) back
##   DELIVERED  the pickup truck has left
## Docks run in physical mode: unloading ends when the trailer is empty,
## loading once every pallet is inside and the worker is out of the trailer.
## order_store() / order_outbound() are the player actions (click handler and
## Storage panel call them; so does test_core_loop).

signal unit_changed(unit: CargoUnit)

const REFERENCE_FLAG: String = "--reference_state"

@export var contract_manager_path: NodePath
@export var storage_grid_path: NodePath
@export var job_board_path: NodePath
@export var level_path: NodePath = ^"../../Level1"

var bays: Dictionary = {}  ## Dock -> TrailerBay

var _manager: ContractManager
var _grid: StorageGrid
var _board: JobBoard
var _sim: TerminalSim
var _moved: Dictionary = {}  ## Dock -> pallets this flow has reported for its truck
var _shipped: Dictionary = {}  ## Dock -> Contract loaded onto its departing truck
var _storage_low: bool = false
var _quiet: bool = false
var _reference: bool = false
var _reference_carry: Dock = null


func _ready() -> void:
	add_to_group(&"cargo_flow")
	_manager = get_node_or_null(contract_manager_path) as ContractManager
	_grid = get_node_or_null(storage_grid_path) as StorageGrid
	_board = get_node_or_null(job_board_path) as JobBoard
	_sim = get_tree().get_first_node_in_group(&"terminal_sim") as TerminalSim
	if _manager == null or _grid == null or _board == null or _sim == null:
		push_error("CargoFlow: missing ContractManager, StorageGrid, JobBoard or TerminalSim")
		return
	_reference = REFERENCE_FLAG in OS.get_cmdline_user_args()
	var level: Node = get_node_or_null(level_path)
	for dock: Dock in _sim.docks:
		dock.physical_transfer = true
		dock.progress_changed.connect(_on_dock_progress.bind(dock))
		dock.state_changed.connect(_on_dock_state.bind(dock))
		dock.load_completed.connect(_on_load_completed)
		_make_bay(dock, level)
	# keep the dock aprons clear of loose decor pallets so nothing drives through them
	var c: Vector2 = _grid.inbound_rect.get_center()
	var inbound: Vector3 = Vector3(c.x, 0.0, c.y)
	for b: TrailerBay in bays.values():
		b.toward = inbound
	# and the main corridor between the docks and the zones
	var corridor: Rect2 = Rect2(Vector2(_grid.inbound_rect.position.x - 4.0, _grid.inbound_rect.end.y), Vector2.ZERO)
	corridor = corridor.expand(Vector2(_grid.outbound_rect.end.x, -2.0))
	# and the aisle between the zones that OUTBOUND is driven into from
	var between: Rect2 = Rect2(Vector2(_grid.inbound_rect.end.x, _grid.outbound_rect.position.y - 1.0), Vector2.ZERO)
	between = between.expand(Vector2(_grid.outbound_rect.position.x, _grid.outbound_rect.end.y))
	_grid.hide_decor(func(p: Vector3) -> bool:
		if corridor.has_point(Vector2(p.x, p.z)) or between.has_point(Vector2(p.x, p.z)):
			return true
		for b: TrailerBay in bays.values():
			if b.on_apron(p):
				return true
		return false)
	_sim.visit_started.connect(_on_visit_started)
	_manager.contract_accepted.connect(_on_contract_accepted)
	_board.unit_picked.connect(_on_unit_picked)
	_board.unit_placed.connect(_on_unit_placed)
	_board.unit_relocated.connect(func(job: CarryJob) -> void: unit_changed.emit(job.unit))
	_grid.slots_changed.connect(_check_storage_low)
	GameState.minutes_advanced.connect(_on_minutes_advanced)
	# the old decorative shuttle is replaced by the physical flow
	for shuttle: Node in get_tree().get_nodes_in_group(&"unload_shuttles"):
		shuttle.call(&"retire")
	if _reference:
		_setup_reference_state()
	_check_storage_low.call_deferred()


func bay_for(dock: Dock) -> TrailerBay:
	return bays.get(dock) as TrailerBay


func _make_bay(dock: Dock, level: Node) -> void:
	var driver: Node3D = null
	if level != null:
		for n: Node in level.find_children("*", "Node3D", true, false):
			if n.has_signal(&"truck_spawned") and int(n.get(&"dock_id")) == dock.dock_id:
				driver = n as Node3D
				break
	var door: Node3D = null
	if driver != null:
		var path: Variant = driver.get(&"dock_visual_path")
		if path is NodePath and not (path as NodePath).is_empty():
			door = driver.get_node_or_null(path) as Node3D
		driver.connect(&"truck_spawned", _on_truck_spawned)
	else:
		push_warning("CargoFlow: no TruckDriver for dock %d" % dock.dock_id)
	var bay: TrailerBay = TrailerBay.new()
	add_child(bay)
	bay.setup(dock, driver, door)
	bay.freed.connect(_on_bay_freed.bind(dock))
	bay.doors_changed.connect(func(_open: bool) -> void: _pump(dock))
	bays[dock] = bay
	_grid.bays.append(bay)


# --- player actions --------------------------------------------------------------

## Slots the unit may be sent to: free rack slots (floor only as overflow).
func valid_store_slots(unit: CargoUnit) -> Array[StorageSlot]:
	if unit == null or unit.state != CargoUnit.State.INBOUND or unit.is_busy():
		return []
	return _grid.store_targets()


## Queues a put-away job from INBOUND to the slot. "" on success, else the reason.
func order_store(unit: CargoUnit, slot: StorageSlot) -> String:
	if unit == null or slot == null:
		return "Nothing selected."
	if unit.state != CargoUnit.State.INBOUND:
		return "Only pallets in the Inbound zone can be stored."
	if unit.is_busy():
		return "That pallet is already on its way."
	if not slot.is_storage() or not slot.is_free():
		return "That slot is not free."
	if not _grid.placement_ok(slot, unit) or not _grid.column_clear(slot):
		return "A pallet there would block another pallet's way in."
	if not slot in _grid.store_targets():
		return "Use the pallet rack first; floor slots are overflow only."
	if slot.needs_lift() and not _board.has_lift():
		return "Upper rack levels need a forklift."
	_board.add_job(CarryJob.new(CarryJob.Kind.STORE, unit, slot))
	_log("store order: %s -> %s" % [unit.code, slot.label])
	unit_changed.emit(unit)
	return ""


func can_send_outbound(contract: Contract) -> bool:
	if contract.state != Contract.State.PICKUP_SCHEDULED and contract.state != Contract.State.OUTBOUND:
		return false
	for u: CargoUnit in contract.units:
		if u.state == CargoUnit.State.STORED and not u.is_busy():
			return true
	return false


## Queues every stored pallet of the contract for picking to OUTBOUND.
## Returns how many were queued. Only after the client has scheduled the pickup.
func order_outbound(contract: Contract) -> int:
	if not can_send_outbound(contract):
		return 0
	var n: int = 0
	for u: CargoUnit in contract.units:
		if order_outbound_unit(u).is_empty():
			n += 1
	return n


func order_outbound_unit(unit: CargoUnit) -> String:
	var c: Contract = unit.contract
	if c.state != Contract.State.PICKUP_SCHEDULED and c.state != Contract.State.OUTBOUND:
		return "%s has no pickup scheduled yet." % c.company
	if unit.state != CargoUnit.State.STORED or unit.is_busy():
		return "That pallet is not waiting in storage."
	_board.add_job(CarryJob.new(CarryJob.Kind.TO_OUTBOUND, unit))
	_manager.set_state(c, Contract.State.OUTBOUND)
	unit_changed.emit(unit)
	return ""


func units_in(state: CargoUnit.State) -> Array[CargoUnit]:
	var out: Array[CargoUnit] = []
	for c: Contract in _manager.active():
		for u: CargoUnit in c.units:
			if u.state == state:
				out.append(u)
	return out


# --- trucks ---------------------------------------------------------------------

func _on_contract_accepted(c: Contract) -> void:
	c.inbound_at = GameState.now() + c.inbound_delay
	_sim.schedule_visit(c, false, c.inbound_at)
	_notify("Contract accepted", "%s: %d pallets arrive around %s." % [c.company, c.pallets, GameState.format_time_of(c.inbound_at)])


func _on_visit_started(c: Contract, dock: Dock) -> void:
	_moved[dock] = 0
	if dock.loading:
		_notify("Pickup truck", "%s truck heading to Dock %d for %d pallets." % [c.company, dock.dock_id, c.pallets])
	else:
		_manager.set_state(c, Contract.State.INBOUND)
		_notify("Inbound truck", "%s truck heading to Dock %d with %d pallets." % [c.company, dock.dock_id, c.pallets])


func _on_truck_spawned(dock_id: int) -> void:
	var dock: Dock = _sim.get_dock(dock_id)
	var bay: TrailerBay = bay_for(dock)
	if bay == null:
		return
	bay.bind_rig(bay.find_rig(), false)
	_fill_trailer(dock)


## Delivery trucks arrive loaded: the contract's pallets on the trailer slots
## from the nose back, parented to the trailer so they ride with it.
func _fill_trailer(dock: Dock) -> void:
	var bay: TrailerBay = bay_for(dock)
	var c: Contract = dock.contract
	if c == null or dock.loading or not bay.has_truck():
		return
	var i: int = 0
	for u: CargoUnit in c.units:
		if u.state != CargoUnit.State.IN_TRUCK or u.slot != null:
			continue
		if i >= bay.slots.size():
			push_warning("CargoFlow: %s has more pallets than trailer slots" % c.id)
			break
		var slot: StorageSlot = bay.slots[i]
		i += 1
		if u.node == null:
			u.node = CargoPallet.create(u)
		if u.node.get_parent() != null:
			u.node.reparent(bay.trailer, false)
		else:
			bay.trailer.add_child(u.node)
		u.node.transform = slot.local
		_grid.occupy(slot, u)
		PalletLog.stamp(u, CargoUnit.State.IN_TRUCK, slot.label)
		unit_changed.emit(u)


func _on_dock_state(state: Dock.State, dock: Dock) -> void:
	var bay: TrailerBay = bay_for(dock)
	match state:
		Dock.State.UNLOADING, Dock.State.LOADING:
			if not bay.has_truck():
				bay.bind_rig(bay.find_rig(), true)
			if state == Dock.State.UNLOADING:
				_fill_trailer(dock)
			_pump.call_deferred(dock)
		Dock.State.IDLE:
			_deliver_shipped(dock)
			bay.unbind_rig()


## Queues the next carry jobs for a dock whose trailer is open:
## UNLOADING - one per pallet still in the trailer, rearmost first.
## LOADING   - the front pallet of each OUTBOUND column of the pickup contract.
func _pump(dock: Dock) -> void:
	var bay: TrailerBay = bay_for(dock)
	if dock.contract == null or not bay.has_truck() or not bay.doors_open:
		return
	if dock.state == Dock.State.UNLOADING:
		for slot: StorageSlot in bay.slots_rear_first():
			var u: CargoUnit = slot.unit
			if u == null or u.is_busy() or u.state != CargoUnit.State.IN_TRUCK:
				continue
			if _reference_carry == dock:
				_reference_carry = null
				_start_reference_carry(dock, u)
				continue
			_board.add_job(CarryJob.new(CarryJob.Kind.UNLOAD, u))
	elif dock.state == Dock.State.LOADING:
		var ready: Array[CargoUnit] = []
		for u: CargoUnit in dock.contract.units:
			if u.state == CargoUnit.State.OUTBOUND and not u.is_busy() and u.slot != null and _grid.column_clear(u.slot):
				ready.append(u)
		ready.sort_custom(func(a: CargoUnit, b: CargoUnit) -> bool: return a.slot.position.dot(a.slot.out_dir) > b.slot.position.dot(b.slot.out_dir))
		for u: CargoUnit in ready:
			var job: CarryJob = CarryJob.new(CarryJob.Kind.LOAD, u)
			job.bay = bay
			_board.add_job(job)


func _on_dock_progress(done: int, _total: int, dock: Dock) -> void:
	if done == 0:
		_moved[dock] = 0
		return
	var moved: int = int(_moved.get(dock, 0))
	if done <= moved or dock.contract == null or dock.loading:
		return
	# progress set from outside (reference snapshot): those pallets are
	# already in INBOUND
	var bay: TrailerBay = bay_for(dock)
	for slot: StorageSlot in bay.slots_rear_first():
		if moved >= done:
			break
		var u: CargoUnit = slot.unit
		if u == null or u.state != CargoUnit.State.IN_TRUCK:
			continue
		# only once there is room for it: a pallet never leaves the trailer
		# without a slot to go to
		var target: StorageSlot = _grid.drop_slot(StorageSlot.Zone.INBOUND, u)
		if target == null:
			push_warning("CargoFlow: INBOUND is full, %s stays in the trailer" % u.code)
			break
		_grid.release(slot)
		PalletLog.stamp(u, CargoUnit.State.UNLOADING, "Forklift 1", "Forklift 1")
		_put(u, target, CargoUnit.State.INBOUND, "Forklift 1")
		moved += 1
	_moved[dock] = moved
	if _reference:
		_reference_carry = dock


func _on_unit_picked(job: CarryJob) -> void:
	unit_changed.emit(job.unit)
	if job.kind == CarryJob.Kind.LOAD and job.bay != null:
		_pump(job.bay.dock)


func _on_unit_placed(job: CarryJob) -> void:
	var u: CargoUnit = job.unit
	var c: Contract = u.contract
	unit_changed.emit(u)
	_log("%s placed in %s by %s" % [u.code, job.to_slot.label, (job.agent as CarryAgent).label if job.agent != null else "?"])
	match job.kind:
		CarryJob.Kind.UNLOAD:
			var dock: Dock = (job.from_slot.bay as TrailerBay).dock
			_count_pallet(dock)
			dock.finish_transfer()
		CarryJob.Kind.STORE:
			if c.state == Contract.State.INBOUND and c.count_in(CargoUnit.State.STORED) == c.pallets:
				c.stored_minutes = 0.0
				_manager.set_state(c, Contract.State.STORED)
				_notify("Cargo stored", "%s: all %d pallets stored. Pickup in %d day%s." % [
					c.company, c.pallets, c.storage_days, "" if c.storage_days == 1 else "s"])
		CarryJob.Kind.TO_OUTBOUND:
			for dock: Dock in _sim.docks:
				if dock.contract == c and dock.state == Dock.State.LOADING:
					_pump(dock)
		CarryJob.Kind.LOAD:
			_count_pallet(job.bay.dock)


func _count_pallet(dock: Dock) -> void:
	_moved[dock] = int(_moved.get(dock, 0)) + 1
	dock.report_pallet()


## The lane is clear: a pickup truck with every pallet inside may go.
func _on_bay_freed(dock: Dock) -> void:
	if dock.state != Dock.State.LOADING or dock.contract == null:
		return
	if dock.contract.count_in(CargoUnit.State.LOADED) >= dock.contract.pallets:
		dock.finish_transfer()


func _on_load_completed(dock: Dock) -> void:
	var c: Contract = dock.contract
	if c == null:
		return
	_shipped[dock] = c
	var storage: int = roundi(c.storage_accrued)
	var payout: int = c.handling_fee + storage
	GameState.add_money(payout)
	_manager.complete(c, payout)
	_notify("Contract completed", "%s paid $ %s (handling $ %s + storage $ %s)." % [
		c.company, GameState.format_money(payout), GameState.format_money(c.handling_fee), GameState.format_money(storage)])


## The pickup truck left with the pallets: they are delivered. Their 3D
## pallets ride away inside the trailer and go with it.
func _deliver_shipped(dock: Dock) -> void:
	var c: Contract = _shipped.get(dock) as Contract
	_shipped.erase(dock)
	if c == null:
		return
	var bay: TrailerBay = bay_for(dock)
	for u: CargoUnit in c.units:
		if u.state != CargoUnit.State.LOADED:
			if u.state != CargoUnit.State.DELIVERED:
				# not on the truck: it stays where it is, with its state and slot
				push_warning("CargoFlow: %s was not loaded (%s at %s); it stays in the terminal" % [u.code, u.state_name(), u.location_code])
			continue
		if u.slot != null:
			_grid.release(u.slot)
		# the 3D pallet rides away inside the trailer; one left outside it
		# (it never should be) goes too, never stays behind without a unit
		if u.node != null and is_instance_valid(u.node):
			var trailer: Node3D = bay.trailer if bay != null else null
			if trailer == null or not is_instance_valid(trailer) or not trailer.is_ancestor_of(u.node):
				u.node.queue_free()
		u.node = null
		PalletLog.stamp(u, CargoUnit.State.DELIVERED, "Delivered (%s)" % c.company)
		unit_changed.emit(u)


# --- storage --------------------------------------------------------------------

func _on_minutes_advanced(game_minutes: float) -> void:
	for c: Contract in _manager.active():
		var stored: int = c.count_in(CargoUnit.State.STORED)
		if stored > 0:
			c.storage_accrued += stored * c.storage_fee * game_minutes / GameplayConfig.MINUTES_PER_CONTRACT_DAY
		if c.state == Contract.State.STORED:
			c.stored_minutes += game_minutes
			if c.stored_minutes >= c.storage_days * GameplayConfig.MINUTES_PER_CONTRACT_DAY:
				_schedule_pickup(c)


func _schedule_pickup(c: Contract) -> void:
	c.pickup_at = GameState.now() + GameplayConfig.PICKUP_LEAD_MINUTES
	_sim.schedule_visit(c, true, c.pickup_at)
	_manager.set_state(c, Contract.State.PICKUP_SCHEDULED)
	_notify("Pickup scheduled", "%s collects %d pallets at %s. Send them to Outbound (Storage tab)." % [
		c.company, c.pallets, GameState.format_time_of(c.pickup_at)])


func _check_storage_low() -> void:
	var free: int = _grid.free_storage_count()
	if free < GameplayConfig.STORAGE_LOW_THRESHOLD:
		if not _storage_low:
			_storage_low = true
			_notify("Storage space low", "Only %d free pallet spaces left" % free)
	else:
		_storage_low = false


# --- helpers --------------------------------------------------------------------

## Places a unit straight into a grid slot (reference state) and stamps it.
## With no slot given, any free floor or storage slot takes it, so a unit is
## never left without a place. False only when the terminal is full.
func _put(unit: CargoUnit, slot: StorageSlot, state: CargoUnit.State, agent: String) -> bool:
	if slot == null:
		slot = _grid.first_free(StorageSlot.Zone.FLOOR)
		if slot == null:
			var free: Array[StorageSlot] = _grid.free_storage_slots()
			slot = free[0] if not free.is_empty() else null
		if slot == null:
			push_error("CargoFlow: no free slot anywhere for %s; it stays %s at %s" % [unit.code, unit.state_name(), unit.location_code])
			return false
		push_warning("CargoFlow: no slot of the right kind for %s, put it in %s" % [unit.code, slot.label])
	if unit.node == null:
		unit.node = CargoPallet.create(unit)
	if unit.node.get_parent() != null:
		unit.node.reparent(_grid.cargo_root, false)
	else:
		_grid.cargo_root.add_child(unit.node)
	unit.node.global_transform = slot.pallet_transform()
	_grid.occupy(slot, unit)
	PalletLog.stamp(unit, state, slot.label, agent)
	unit_changed.emit(unit)
	return true


func _notify(title: String, body: String) -> void:
	if not _quiet:
		GameState.notify(title, body)


func _log(msg: String) -> void:
	print("CargoFlow: " + msg)


## Reference screenshot: Dock 1 unloading LogiTrans general cargo. TruckDriver1
## snaps the truck in at 4 / 8: four pallets go straight to INBOUND, a forklift
## is half way to INBOUND with the fifth and three wait in the trailer. Plus
## another contract waiting in INBOUND and one waiting in OUTBOUND. No toasts.
func _setup_reference_state() -> void:
	_quiet = true
	var lt: Contract = _manager.make_contract(ContractCatalog.find("LogiTrans"), {"pallets": 8, "storage_days": 2, "inbound_delay": 0.0})
	_manager.add_available(lt)
	var reason: String = _manager.accept(lt)
	if not reason.is_empty():
		push_warning("CargoFlow: reference contract blocked: " + reason)
	var gf: Contract = _manager.make_contract(ContractCatalog.find("GreenFields"), {"pallets": 4})
	_manager.adopt(gf, Contract.State.INBOUND)
	for u: CargoUnit in gf.units:
		PalletLog.stamp(u, CargoUnit.State.IN_TRUCK, "T-Dock2-%02d" % (u.index + 1))
		PalletLog.stamp(u, CargoUnit.State.UNLOADING, "Forklift 2", "Forklift 2")
		_put(u, _grid.drop_slot(StorageSlot.Zone.INBOUND), CargoUnit.State.INBOUND, "Forklift 2")
	var nb: Contract = _manager.make_contract(ContractCatalog.find("Nordic Build"), {"pallets": 6})
	_manager.adopt(nb, Contract.State.OUTBOUND)
	var racks: Array[StorageSlot] = _grid.store_targets()
	for u: CargoUnit in nb.units:
		var rack: String = racks[u.index].label if u.index < racks.size() else "A1-L1-1"
		PalletLog.stamp(u, CargoUnit.State.IN_TRUCK, "T-Dock1-%02d" % (u.index + 1))
		PalletLog.stamp(u, CargoUnit.State.UNLOADING, "Forklift 1", "Forklift 1")
		PalletLog.stamp(u, CargoUnit.State.INBOUND, "INBOUND-%02d" % (u.index + 1), "Forklift 1")
		PalletLog.stamp(u, CargoUnit.State.PUTAWAY, "Forklift 1", "Forklift 1")
		PalletLog.stamp(u, CargoUnit.State.STORED, rack, "Forklift 1")
		PalletLog.stamp(u, CargoUnit.State.PICKING, "Forklift 2", "Forklift 2")
		_put(u, _grid.drop_slot(StorageSlot.Zone.OUTBOUND), CargoUnit.State.OUTBOUND, "Forklift 2")
	nb.pickup_at = GameState.now() + GameplayConfig.PICKUP_LEAD_MINUTES
	_sim.schedule_visit(nb, true, nb.pickup_at)
	# the reference screenshot shows no toasts: stay quiet in this mode
	_storage_low = true


## Puts the nearest forklift half way between the dock and INBOUND with `u`
## on its forks, heading for a free INBOUND slot.
func _start_reference_carry(dock: Dock, u: CargoUnit) -> void:
	var target: StorageSlot = _grid.drop_slot(StorageSlot.Zone.INBOUND)
	var lifts: Array[ForkliftCarrier] = _board.forklifts()
	if target == null or lifts.is_empty():
		_board.add_job(CarryJob.new(CarryJob.Kind.UNLOAD, u))
		return
	var bay: TrailerBay = bay_for(dock)
	var job: CarryJob = CarryJob.new(CarryJob.Kind.UNLOAD, u, target)
	var from: Vector3 = bay.stage_point(u.slot) - bay.axis * 1.5
	var to: Vector3 = _grid.entry_point(target, lifts[0].reach_for(target))
	var at: Vector3 = from.lerp(to, 0.5)
	var dir: Vector3 = to - at
	_board.start_now(job, lifts[0], at, atan2(-dir.x, -dir.z))
