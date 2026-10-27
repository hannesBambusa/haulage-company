extends PanelContainer
## Storage tab: free pallet spaces, what is selected, and one row per active
## contract with its pallets (ID, state, location; click one for the Pallet
## panel), the storage fee so far and a "Send to outbound" button once the
## client has scheduled the pickup. The filter shows pallets of one state.

signal closed

const STATE_COLORS: Dictionary = {
	Contract.State.ACCEPTED: Color(0.961, 0.725, 0.259),
	Contract.State.INBOUND: Color(0.353, 0.627, 1.0),
	Contract.State.STORED: Color(0.239, 0.863, 0.518),
	Contract.State.PICKUP_SCHEDULED: Color(1.0, 0.55, 0.3),
	Contract.State.OUTBOUND: Color(0.95, 0.75, 0.16),
}
const DEFAULT_HINT: String = "Click a pallet in INBOUND, then a lit rack slot: a forklift puts it away. Click any pallet for its history."
## Filter entry 0 shows every state; entry i + 1 shows CargoUnit.State i.
const FILTER_ALL: int = -1

var _manager: ContractManager
var _flow: CargoFlow
var _grid: StorageGrid
var _input: CargoInput
var _rows: Dictionary = {}  ## Contract -> Dictionary of row controls
var _hint_override: String = ""
var _filter: int = FILTER_ALL


func _ready() -> void:
	%Close.pressed.connect(func() -> void: closed.emit())
	var filter: OptionButton = %StateFilter
	filter.add_item("All states", 0)
	for i: int in CargoUnit.STATE_NAMES.size():
		filter.add_item(CargoUnit.STATE_NAMES[i], i + 1)
	filter.item_selected.connect(func(index: int) -> void:
		_filter = filter.get_item_id(index) - 1
		_refresh())
	var timer: Timer = Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	visibility_changed.connect(_refresh)
	_bind.call_deferred()


func _bind() -> void:
	_manager = get_tree().get_first_node_in_group(&"contract_manager") as ContractManager
	_flow = get_tree().get_first_node_in_group(&"cargo_flow") as CargoFlow
	_grid = get_tree().get_first_node_in_group(&"storage_grid") as StorageGrid
	_input = get_tree().get_first_node_in_group(&"cargo_input") as CargoInput
	if _manager != null:
		_manager.contract_state_changed.connect(func(_c: Contract) -> void: _rebuild())
	if _grid != null:
		_grid.slots_changed.connect(_refresh)
	if _input != null:
		_input.selection_changed.connect(func(_u: CargoUnit) -> void:
			_hint_override = ""
			_refresh())
		_input.order_rejected.connect(func(reason: String) -> void:
			_hint_override = reason
			_refresh())
	_rebuild()


func _rebuild() -> void:
	var list: VBoxContainer = %List
	for c: Contract in _rows:
		(_rows[c].panel as Control).queue_free()
	_rows.clear()
	if _manager != null:
		for c: Contract in _manager.active():
			_rows[c] = _make_row(c)
			list.add_child(_rows[c].panel)
	list.get_node(^"Empty").visible = _rows.is_empty()
	_refresh()


func _make_row(c: Contract) -> Dictionary:
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = &"InsetPanel"
	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 4)
	margin.add_child(box)

	var top: HBoxContainer = HBoxContainer.new()
	box.add_child(top)
	var swatch: ColorRect = ColorRect.new()
	swatch.color = c.color
	swatch.custom_minimum_size = Vector2(12, 12)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(swatch)
	var name_label: Label = Label.new()
	name_label.text = c.company
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	top.add_child(name_label)
	var state: Label = Label.new()
	state.add_theme_font_size_override(&"font_size", 17)
	top.add_child(state)

	var where: Label = _small_label(&"SubLabel")
	box.add_child(where)
	var money: Label = _small_label(&"MutedLabel")
	box.add_child(money)
	var pallets: VBoxContainer = VBoxContainer.new()
	pallets.add_theme_constant_override(&"separation", 0)
	box.add_child(pallets)

	var button: Button = Button.new()
	button.text = "Send to outbound"
	button.theme_type_variation = &"AcceptButton"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 38)
	button.pressed.connect(_on_send_pressed.bind(c))
	box.add_child(button)
	return {"panel": panel, "state": state, "where": where, "money": money, "button": button, "pallets": pallets, "sig": ""}


func _small_label(variation: StringName) -> Label:
	var l: Label = Label.new()
	l.theme_type_variation = variation
	l.add_theme_font_size_override(&"font_size", 16)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _refresh() -> void:
	if not is_visible_in_tree() or _grid == null:
		return
	var free: int = _grid.free_storage_count()
	var total: int = _grid.storage_total()
	%FreeLabel.text = "Free pallet spaces: %d / %d" % [free, total]
	%FreeLabel.add_theme_color_override(&"font_color", Color(0.94, 0.35, 0.3) if free < GameplayConfig.STORAGE_LOW_THRESHOLD else Color(0.239, 0.863, 0.518))
	%Capacity.max_value = maxi(total, 1)
	%Capacity.value = total - free
	var reserved: int = free - _manager.free_capacity() if _manager != null else 0
	%ReservedLabel.text = "Reserved for incoming: %d  ·  open: %d" % [reserved, free - reserved]
	%Hint.text = _hint_text()
	for c: Contract in _rows:
		_update_row(c, _rows[c])


func _hint_text() -> String:
	if not _hint_override.is_empty():
		return _hint_override
	if _input != null and _input.selected != null:
		var u: CargoUnit = _input.selected
		return "Selected %s (%s). Click a lit rack slot, right-click to cancel." % [u.code, u.contract.company]
	return DEFAULT_HINT


func _update_row(c: Contract, row: Dictionary) -> void:
	var state: Label = row.state
	state.text = c.state_name()
	state.add_theme_color_override(&"font_color", STATE_COLORS.get(c.state, Color.WHITE))
	var parts: PackedStringArray = PackedStringArray()
	for st: int in CargoUnit.State.values():
		var n: int = c.count_in(st as CargoUnit.State)
		if n > 0:
			parts.append("%s %d" % [CargoUnit.name_of(st as CargoUnit.State), n])
	(row.where as Label).text = "%s  ·  %d pallets: %s" % [c.id, c.pallets, ", ".join(parts)]
	var money: String = "Storage so far $ %s" % GameState.format_money(roundi(c.storage_accrued))
	match c.state:
		Contract.State.ACCEPTED:
			money = "Truck due %s  ·  handling $ %s" % [GameState.format_time_of(c.inbound_at), GameState.format_money(c.handling_fee)]
		Contract.State.STORED:
			money += "  ·  day %.1f of %d" % [c.stored_minutes / GameplayConfig.MINUTES_PER_CONTRACT_DAY, c.storage_days]
		Contract.State.PICKUP_SCHEDULED, Contract.State.OUTBOUND:
			money += "  ·  pickup %s" % GameState.format_time_of(c.pickup_at)
	(row.money as Label).text = money
	var button: Button = row.button
	button.visible = c.state == Contract.State.PICKUP_SCHEDULED or c.state == Contract.State.OUTBOUND
	button.disabled = _flow == null or not _flow.can_send_outbound(c)
	_update_pallets(c, row)


## One clickable line per pallet: ID, state, location. Rebuilt only when
## something in it changed.
func _update_pallets(c: Contract, row: Dictionary) -> void:
	var lines: Array[String] = []
	var shown: Array[CargoUnit] = []
	for u: CargoUnit in c.units:
		if _filter != FILTER_ALL and u.state != _filter:
			continue
		shown.append(u)
		lines.append("%s   %s   %s" % [u.code, u.state_name(), u.location_code])
	var sig: String = "|".join(lines)
	if sig == row.sig:
		return
	row.sig = sig
	var list: VBoxContainer = row.pallets
	for child: Node in list.get_children():
		child.queue_free()
	if shown.is_empty() and _filter != FILTER_ALL:
		list.add_child(_small_label(&"MutedLabel"))
		(list.get_child(list.get_child_count() - 1) as Label).text = "No pallets %s." % CargoUnit.STATE_NAMES[_filter].to_lower()
		return
	for i: int in shown.size():
		var b: Button = Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = lines[i]
		b.add_theme_font_size_override(&"font_size", 15)
		b.pressed.connect(_on_pallet_pressed.bind(shown[i]))
		list.add_child(b)


func _on_pallet_pressed(u: CargoUnit) -> void:
	if _input != null:
		_input.inspect(u)


func _on_send_pressed(c: Contract) -> void:
	if _flow == null:
		return
	var n: int = _flow.order_outbound(c)
	_hint_override = "Sending %d %s pallets to OUTBOUND." % [n, c.company] if n > 0 else "No %s pallets waiting in storage." % c.company
	_refresh()
