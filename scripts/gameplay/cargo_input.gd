class_name CargoInput
extends Node
## Mouse picking for the core loop. Left-click any pallet (in a trailer, a
## zone, a rack or on a carrier) to inspect it: the Pallet panel opens.
## A pallet in INBOUND is also selected: the free rack slots light up (floor
## slots only when the racks are full). Left-click a lit slot to send a
## forklift with it; the next inbound pallet of the same contract is selected
## so a delivery can be stored click by click. Stored pallets go to OUTBOUND
## from the Pallet panel or the Storage tab. Right-click or Esc clears.

signal selection_changed(unit: CargoUnit)
## A pallet was clicked: show its info (null = close).
signal unit_inspected(unit: CargoUnit)
## Something the player tried did not work, with the reason.
signal order_rejected(reason: String)

@export var cargo_flow_path: NodePath
@export var storage_grid_path: NodePath
@export var ray_length: float = 400.0

var selected: CargoUnit = null

var _flow: CargoFlow
var _grid: StorageGrid


func _ready() -> void:
	add_to_group(&"cargo_input")
	_flow = get_node_or_null(cargo_flow_path) as CargoFlow
	_grid = get_node_or_null(storage_grid_path) as StorageGrid
	if _flow != null:
		_flow.unit_changed.connect(_on_unit_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and selected != null:
		select(null)
		get_viewport().set_input_as_handled()
		return
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and selected != null:
		select(null)
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var hit: Object = pick_at(mb.position)
	if hit != null:
		click(hit)
		get_viewport().set_input_as_handled()
	elif selected != null:
		select(null)


## Handles a click on a CargoPallet or SlotMarker (public for tests).
func click(hit: Object) -> void:
	if hit is SlotMarker:
		_click_slot((hit as SlotMarker).slot)
	elif hit is CargoPallet:
		_click_unit((hit as CargoPallet).unit)


## Opens the Pallet panel for a unit (Storage tab rows call this too).
func inspect(unit: CargoUnit) -> void:
	unit_inspected.emit(unit)


func select(unit: CargoUnit) -> void:
	if selected != null and selected.node is CargoPallet:
		(selected.node as CargoPallet).set_selected(false)
	selected = unit
	if selected != null and selected.node is CargoPallet:
		(selected.node as CargoPallet).set_selected(true)
	if _grid != null:
		if selected != null:
			_grid.show_markers(_flow.valid_store_slots(selected))
		else:
			_grid.hide_markers()
	selection_changed.emit(selected)


func _click_unit(unit: CargoUnit) -> void:
	unit_inspected.emit(unit)
	if unit.state == CargoUnit.State.INBOUND and not unit.is_busy():
		select(null if unit == selected else unit)
	elif selected != null:
		select(null)


func _click_slot(slot: StorageSlot) -> void:
	if selected == null:
		return
	var unit: CargoUnit = selected
	var reason: String = _flow.order_store(unit, slot)
	if not reason.is_empty():
		order_rejected.emit(reason)
		return
	select(_next_inbound(unit.contract))


func _next_inbound(contract: Contract) -> CargoUnit:
	for u: CargoUnit in contract.units:
		if u.state == CargoUnit.State.INBOUND and not u.is_busy():
			return u
	return null


func _on_unit_changed(unit: CargoUnit) -> void:
	if unit == selected and (unit.state != CargoUnit.State.INBOUND or unit.is_busy()):
		select(null)
	elif selected != null and _grid != null:
		_grid.show_markers(_flow.valid_store_slots(selected))


## The CargoPallet or highlighted SlotMarker under a screen position, or null.
func pick_at(screen_pos: Vector2) -> Object:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return null
	var from: Vector3 = camera.project_ray_origin(screen_pos)
	var to: Vector3 = from + camera.project_ray_normal(screen_pos) * ray_length
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, GameplayConfig.CARGO_LAYER | GameplayConfig.SLOT_LAYER)
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.get("collider") as Object if not hit.is_empty() else null
