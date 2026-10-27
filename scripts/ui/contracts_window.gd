extends Control
## Contracts window: Available / Active / Completed lists from the
## ContractManager plus a detail panel. Accepting is blocked with a message
## when there are not enough free pallet spaces.

signal closed
signal contract_accepted(contract: Contract)

enum Tab { AVAILABLE, ACTIVE, COMPLETED }

const ROW_SCENE: PackedScene = preload("res://ui/contract_row.tscn")
const BADGE_VARIATIONS: Dictionary = {
	"Standard": &"BadgePriority",
	"Priority": &"BadgePriority",
	"Urgent": &"BadgeUrgent",
}
const TABS_PATH: NodePath = ^"Main/Margin/VBox/Body/ListCol/TabsRow"

var _manager: ContractManager = null
var _tab: Tab = Tab.AVAILABLE
var _rows: Array[PanelContainer] = []
var _selected: Contract = null
var _message: String = ""


func _ready() -> void:
	%Close.pressed.connect(func() -> void: closed.emit())
	%AcceptContract.pressed.connect(func() -> void: _try_accept(_selected))
	var tabs: Node = get_node(TABS_PATH)
	(tabs.get_node(^"Available") as Button).pressed.connect(_set_tab.bind(Tab.AVAILABLE))
	(tabs.get_node(^"Active") as Button).pressed.connect(_set_tab.bind(Tab.ACTIVE))
	(tabs.get_node(^"Completed") as Button).pressed.connect(_set_tab.bind(Tab.COMPLETED))
	(tabs.get_node(^"History") as Button).disabled = true
	visibility_changed.connect(_rebuild)
	_bind.call_deferred()


func _bind() -> void:
	_manager = get_tree().get_first_node_in_group(&"contract_manager") as ContractManager
	if _manager == null:
		# standalone UI preview: offer generated contracts with no storage behind them
		_manager = ContractManager.new()
		_manager.name = "PreviewContracts"
		add_child(_manager)
	_manager.pool_changed.connect(_rebuild)
	_rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		closed.emit()
		get_viewport().set_input_as_handled()


func _set_tab(tab: Tab) -> void:
	_tab = tab
	_selected = null
	_message = ""
	_rebuild()


func _list() -> Array[Contract]:
	match _tab:
		Tab.ACTIVE:
			return _manager.active()
		Tab.COMPLETED:
			return _manager.completed()
	return _manager.available()


func _rebuild() -> void:
	if _manager == null:
		return
	var tabs: Node = get_node(TABS_PATH)
	(tabs.get_node(^"Active") as Button).text = "Active (%d)" % _manager.active().size()
	(tabs.get_node(^"Completed") as Button).text = "Completed (%d)" % _manager.completed().size()
	if not visible:
		return
	for r: PanelContainer in _rows:
		r.queue_free()
	_rows.clear()
	var keep: PanelContainer = null
	for c: Contract in _list():
		var row: PanelContainer = ROW_SCENE.instantiate()
		%RowList.add_child(row)
		row.setup(c)
		row.selected.connect(_on_row_selected)
		row.accept_requested.connect(_try_accept)
		_rows.append(row)
		if c == _selected:
			keep = row
	if keep == null and not _rows.is_empty():
		keep = _rows[0]
	if keep != null:
		_on_row_selected(keep)
	else:
		_selected = null
		%AcceptContract.disabled = true


func _on_row_selected(row: PanelContainer) -> void:
	for r: PanelContainer in _rows:
		r.set_selected(r == row)
	if row.contract != _selected:
		_message = ""
	_show_detail(row.contract)


func _try_accept(c: Contract) -> void:
	if c == null or _manager == null:
		return
	_selected = c
	var reason: String = _manager.accept(c)
	if not reason.is_empty():
		_message = reason
		GameState.notify("Cannot accept contract", reason)
		_show_detail(c)
		return
	_message = ""
	contract_accepted.emit(c)


func _show_detail(c: Contract) -> void:
	_selected = c
	var free: int = _manager.free_capacity()
	%DetailLogo.texture = load(c.logo)
	%DetailCompany.text = c.company
	%DetailNumber.text = "Contract #" + c.id
	%DetailBadgeLabel.text = c.tag
	%DetailBadge.theme_type_variation = BADGE_VARIATIONS.get(c.tag, &"BadgePriority")
	%DescTitle.text = c.cargo
	%DescBody.text = c.desc
	%StatValue0.text = "%d pallets" % c.pallets
	%StatSub0.text = "Approx. %d tons" % c.tons
	%StatValue1.text = "%d storage day%s" % [c.storage_days, "" if c.storage_days == 1 else "s"]
	%StatSub1.text = "$ %d per pallet per day" % c.storage_fee
	%StatValue2.text = "Inbound truck"
	%StatSub2.text = ("Due %s" % GameState.format_time_of(c.inbound_at)) if c.inbound_at >= 0.0 else "~%d min after accepting" % roundi(c.inbound_delay)
	%StatValue3.text = "Pickup"
	%StatSub3.text = ("At %s" % GameState.format_time_of(c.pickup_at)) if c.pickup_at >= 0.0 else "After %d storage day%s" % [c.storage_days, "" if c.storage_days == 1 else "s"]
	var storage: int = roundi(c.storage_accrued) if c.state != Contract.State.AVAILABLE else c.estimated_storage()
	%PayTotal.text = "$ " + GameState.format_money(c.payout if c.state == Contract.State.COMPLETED else c.handling_fee + storage)
	%PayHandlingValue.text = "$ " + GameState.format_money(c.handling_fee)
	%PayStorageValue.text = "$ " + GameState.format_money(storage)
	%TimeLine0.text = "Unload: ~%d min" % roundi(c.pallets * 3.0)
	%TimeLine1.text = "Required docks: 1"
	%TimeLine2.text = "Storage space: %d pallet spaces" % c.pallets
	var open: bool = c.state == Contract.State.AVAILABLE
	%Warning.visible = open
	if not _message.is_empty():
		%WarnBody.text = _message
	elif free < c.pallets:
		%WarnBody.text = "Not enough storage: you need %d free pallet spaces, %d are free." % [c.pallets, maxi(free, 0)]
	else:
		%WarnBody.text = "You need %d free pallet spaces to accept this contract (%d free)." % [c.pallets, free]
	%AcceptContract.disabled = not open
	%AcceptContract.text = "Accept Contract" if open else c.state_name()
