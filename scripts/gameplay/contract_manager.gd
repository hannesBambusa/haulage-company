class_name ContractManager
extends Node
## Owns every contract: the pool on offer (generated from ContractCatalog and
## refreshed on game time), the accepted ones and the completed ones.
## Accepting checks free storage first. CargoFlow drives the later states.

signal pool_changed
signal contract_accepted(contract: Contract)
signal contract_state_changed(contract: Contract)
signal contract_completed(contract: Contract, payout: int)

@export var storage_grid_path: NodePath
@export var random_seed: int = 2610
@export var pool_size: int = GameplayConfig.POOL_SIZE
@export var refresh_minutes: float = GameplayConfig.POOL_REFRESH_MINUTES
## Inbound truck arrives this many game minutes after accepting ([min, max]).
@export var inbound_delay_range: Vector2 = GameplayConfig.INBOUND_DELAY_RANGE

var contracts: Array[Contract] = []

var _grid: StorageGrid
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _serial: int = 0
var _unit_serial: int = 0
var _refresh_timer: float = 0.0


func _ready() -> void:
	add_to_group(&"contract_manager")
	_grid = get_node_or_null(storage_grid_path) as StorageGrid
	_rng.seed = random_seed
	fill_pool()
	GameState.minutes_advanced.connect(_on_minutes_advanced)


## Contracts and their units point at each other; break the cycles so the
## RefCounted data is freed with the scene.
func _exit_tree() -> void:
	for c: Contract in contracts:
		for u: CargoUnit in c.units:
			u.contract = null
			u.job = null
			u.slot = null
		c.units.clear()


# --- queries -----------------------------------------------------------------

func available() -> Array[Contract]:
	return _with_state([Contract.State.AVAILABLE])


func active() -> Array[Contract]:
	var out: Array[Contract] = []
	for c: Contract in contracts:
		if c.is_active():
			out.append(c)
	return out


func completed() -> Array[Contract]:
	return _with_state([Contract.State.COMPLETED])


func get_contract(id: String) -> Contract:
	for c: Contract in contracts:
		if c.id == id:
			return c
	return null


## Storage slots not yet promised to accepted contracts.
func free_capacity() -> int:
	var free: int = _grid.free_storage_count() if _grid != null else 0
	for c: Contract in contracts:
		free -= c.pending_storage()
	return free


## Empty string when the contract can be accepted, else the reason.
func accept_block_reason(contract: Contract) -> String:
	if contract.state != Contract.State.AVAILABLE:
		return "This contract is already %s." % contract.state_name().to_lower()
	if contract.pallets > GameplayConfig.TRAILER_CAPACITY:
		return "Too many pallets: one trailer carries at most %d." % GameplayConfig.TRAILER_CAPACITY
	var free: int = free_capacity()
	if free < contract.pallets:
		return "Not enough storage: %d pallets need %d free pallet spaces, only %d free." % [contract.pallets, contract.pallets, maxi(free, 0)]
	return ""


# --- actions -------------------------------------------------------------------

## Accepts the contract. Returns "" on success, else why it was blocked.
func accept(contract: Contract) -> String:
	var reason: String = accept_block_reason(contract)
	if not reason.is_empty():
		print("Contract %s: accept blocked: %s" % [contract.id, reason])
		return reason
	_create_units(contract)
	set_state(contract, Contract.State.ACCEPTED)
	contract_accepted.emit(contract)
	fill_pool()
	return ""


## Registers a contract that is already under way (reference state, tests),
## without scheduling anything. CargoFlow places its units.
func adopt(contract: Contract, state: Contract.State) -> void:
	if not contracts.has(contract):
		contracts.append(contract)
	_create_units(contract)
	set_state(contract, state)


func _create_units(contract: Contract) -> void:
	contract.units.clear()
	for i: int in contract.pallets:
		var u: CargoUnit = CargoUnit.new()
		_unit_serial += 1
		u.id = _unit_serial
		u.code = "PL-%06d" % _unit_serial
		u.contract = contract
		u.contract_id = contract.id
		u.index = i
		contract.units.append(u)


func set_state(contract: Contract, state: Contract.State) -> void:
	if contract.state == state:
		return
	contract.state = state
	print("Contract %s (%s): %s" % [contract.id, contract.company, contract.state_name()])
	contract_state_changed.emit(contract)
	pool_changed.emit()


func complete(contract: Contract, payout: int) -> void:
	contract.payout = payout
	set_state(contract, Contract.State.COMPLETED)
	contract_completed.emit(contract, payout)


## New contract from a catalog template. Overrides set fields by name
## (pallets, storage_days, inbound_delay, ...). Not added to the pool.
func make_contract(template: Dictionary, overrides: Dictionary = {}) -> Contract:
	var c: Contract = Contract.new()
	_serial += 1
	c.id = "%s-%02d10-%02d" % [template.prefix, GameState.day, _serial]
	c.company = template.company
	c.cargo = template.cargo
	c.pack = template.pack
	c.desc = template.desc
	c.tag = template.tag
	c.logo = template.logo
	c.color = template.color
	c.pallets = _rng.randi_range(template.pallets[0], template.pallets[1])
	c.storage_days = _rng.randi_range(template.days[0], template.days[1])
	c.storage_fee = template.storage_fee
	c.inbound_delay = roundf(_rng.randf_range(inbound_delay_range.x, inbound_delay_range.y))
	for key: String in overrides:
		c.set(key, overrides[key])
	c.handling_fee = int(overrides.get("handling_fee", c.pallets * int(template.handling_per_pallet)))
	c.tons = int(overrides.get("tons", roundi(c.pallets * float(template.tons_per_pallet))))
	c.offered_at = GameState.now()
	return c


## Puts a contract on offer.
func add_available(contract: Contract) -> void:
	contract.state = Contract.State.AVAILABLE
	contracts.append(contract)
	pool_changed.emit()


## Tops the Available list up to pool_size.
func fill_pool() -> void:
	var added: bool = false
	while available().size() < pool_size:
		contracts.append(make_contract(_pick_template()))
		added = true
	if added:
		pool_changed.emit()


func _pick_template() -> Dictionary:
	var offered: Array[String] = []
	for c: Contract in available():
		offered.append(c.company)
	var choices: Array[Dictionary] = []
	for t: Dictionary in ContractCatalog.TEMPLATES:
		if not offered.has(t.company):
			choices.append(t)
	if choices.is_empty():
		choices = ContractCatalog.TEMPLATES.duplicate()
	return choices[_rng.randi_range(0, choices.size() - 1)]


## Every refresh_minutes the oldest offer is withdrawn and a new one added.
func _on_minutes_advanced(game_minutes: float) -> void:
	_refresh_timer += game_minutes
	if _refresh_timer < refresh_minutes:
		return
	_refresh_timer = 0.0
	var pool: Array[Contract] = available()
	if pool.is_empty():
		return
	var oldest: Contract = pool[0]
	for c: Contract in pool:
		if c.offered_at < oldest.offered_at:
			oldest = c
	contracts.erase(oldest)
	fill_pool()


func _with_state(states: Array) -> Array[Contract]:
	var out: Array[Contract] = []
	for c: Contract in contracts:
		if c.state in states:
			out.append(c)
	return out
