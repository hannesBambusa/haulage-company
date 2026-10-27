extends PanelContainer
## Pallet info: ID, contract and company, cargo, lifecycle state, location
## code and the timestamped history of one pallet. Opens when a pallet is
## clicked in 3D (CargoInput.unit_inspected) or in the Storage tab, and
## follows the pallet live. Offers "Send to outbound" once its pickup is due.

signal closed

const STATE_COLORS: Dictionary = {
	CargoUnit.State.IN_TRUCK: Color(0.541, 0.604, 0.690),
	CargoUnit.State.UNLOADING: Color(0.961, 0.725, 0.259),
	CargoUnit.State.INBOUND: Color(0.353, 0.627, 1.0),
	CargoUnit.State.PUTAWAY: Color(0.961, 0.725, 0.259),
	CargoUnit.State.STORED: Color(0.239, 0.863, 0.518),
	CargoUnit.State.PICKING: Color(0.961, 0.725, 0.259),
	CargoUnit.State.OUTBOUND: Color(0.95, 0.75, 0.16),
	CargoUnit.State.LOADING: Color(0.961, 0.725, 0.259),
	CargoUnit.State.LOADED: Color(0.353, 0.627, 1.0),
	CargoUnit.State.DELIVERED: Color(0.541, 0.604, 0.690),
}

var unit: CargoUnit = null

var _flow: CargoFlow
var _input: CargoInput
var _history_size: int = -1


## Top-left corner, below the top bar.
@export var screen_position: Vector2 = Vector2(20.0, 84.0)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = screen_position
	%Close.pressed.connect(close)
	%SendOut.pressed.connect(_on_send_pressed)
	var timer: Timer = Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	hide()
	_bind.call_deferred()


func _bind() -> void:
	_flow = get_tree().get_first_node_in_group(&"cargo_flow") as CargoFlow
	_input = get_tree().get_first_node_in_group(&"cargo_input") as CargoInput
	if _flow != null:
		_flow.unit_changed.connect(func(u: CargoUnit) -> void:
			if u == unit:
				_refresh())
	if _input != null:
		_input.unit_inspected.connect(show_unit)


func show_unit(u: CargoUnit) -> void:
	unit = u
	_history_size = -1
	if unit == null:
		close()
		return
	show()
	_refresh()


func close() -> void:
	unit = null
	hide()
	closed.emit()


func _refresh() -> void:
	if unit == null or not visible:
		return
	var c: Contract = unit.contract
	%Title.text = "Pallet " + unit.code
	%Swatch.color = c.color if c != null else Color.WHITE
	%Company.text = "%s  ·  %s" % [c.company, c.id] if c != null else unit.contract_id
	%Cargo.text = "%s  ·  pallet %d of %d" % [c.cargo, unit.index + 1, c.pallets] if c != null else ""
	%State.text = unit.state_name()
	%State.add_theme_color_override(&"font_color", STATE_COLORS.get(unit.state, Color.WHITE))
	%Location.text = unit.location_code
	var can_send: bool = _flow != null and c != null and unit.state == CargoUnit.State.STORED and not unit.is_busy() \
			and (c.state == Contract.State.PICKUP_SCHEDULED or c.state == Contract.State.OUTBOUND)
	%SendOut.visible = can_send
	if unit.history.size() != _history_size:
		_history_size = unit.history.size()
		_rebuild_history()


func _rebuild_history() -> void:
	var list: VBoxContainer = %History
	for child: Node in list.get_children():
		child.queue_free()
	# newest first
	for i: int in range(unit.history.size() - 1, -1, -1):
		var e: Dictionary = unit.history[i]
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 10)
		var when: Label = _label(PalletLog.format_entry_time(e), &"MutedLabel", 15)
		when.custom_minimum_size = Vector2(108, 0)
		row.add_child(when)
		var state: Label = _label(CargoUnit.name_of(int(e.state) as CargoUnit.State), &"", 15)
		state.custom_minimum_size = Vector2(86, 0)
		state.add_theme_color_override(&"font_color", STATE_COLORS.get(int(e.state), Color.WHITE))
		row.add_child(state)
		var agent: String = String(e.agent)
		var where: String = String(e.location)
		if not agent.is_empty() and agent != where:
			where += "  ·  " + agent
		var loc: Label = _label(where, &"SubLabel", 15)
		loc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		loc.clip_text = true
		row.add_child(loc)
		list.add_child(row)


func _label(text: String, variation: StringName, size: int) -> Label:
	var l: Label = Label.new()
	l.text = text
	if variation != &"":
		l.theme_type_variation = variation
	l.add_theme_font_size_override(&"font_size", size)
	return l


func _on_send_pressed() -> void:
	if _flow == null or unit == null:
		return
	var reason: String = _flow.order_outbound_unit(unit)
	if not reason.is_empty() and _input != null:
		_input.order_rejected.emit(reason)
	_refresh()
