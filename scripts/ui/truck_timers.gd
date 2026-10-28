class_name TruckTimers
extends PanelContainer
## "Next trucks" panel (top left): one row per contract waiting for a truck,
## with a ring that fills up until the truck arrives and the time left.
## - Inbound: from accepting the contract to the delivery truck.
## - Pickup: from the last pallet stored, through the storage days and the
##   pickup lead, to the pickup truck.
## A truck that is due but has no free dock shows a full ring.

const RING_SIZE: float = 44.0
const RING_WIDTH: float = 5.0
const INBOUND_COLOR: Color = Color(0.38, 0.78, 1.0)
const PICKUP_COLOR: Color = Color(1.0, 0.62, 0.25)
const TRACK_COLOR: Color = Color(1.0, 1.0, 1.0, 0.14)


## Countdown ring: `progress` 0..1 drawn clockwise from the top.
class Ring:
	extends Control

	var progress: float = 0.0
	var color: Color = Color.WHITE

	func _init() -> void:
		custom_minimum_size = Vector2.ONE * RING_SIZE
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var r: float = minf(size.x, size.y) * 0.5 - RING_WIDTH * 0.5
		draw_arc(c, r, 0.0, TAU, 48, TRACK_COLOR, RING_WIDTH, true)
		if progress > 0.0:
			var a0: float = -PI * 0.5
			draw_arc(c, r, a0, a0 + TAU * clampf(progress, 0.0, 1.0), 48, color, RING_WIDTH, true)


var _manager: ContractManager = null
var _sim: TerminalSim = null
var _list: VBoxContainer = null
## Contract -> [row, ring, title label, time label]
var _rows: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 10)
	add_child(box)
	var title: Label = Label.new()
	title.theme_type_variation = &"HeaderLabel"
	title.text = "Next trucks"
	box.add_child(title)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 8)
	box.add_child(_list)
	hide()
	_bind.call_deferred()


func _bind() -> void:
	_manager = get_tree().get_first_node_in_group(&"contract_manager") as ContractManager
	_sim = get_tree().get_first_node_in_group(&"terminal_sim") as TerminalSim


func _process(_delta: float) -> void:
	if _manager == null or _sim == null:
		return
	var now: float = GameState.now()
	var seen: Dictionary = {}
	for c: Contract in _manager.active():
		var t: Array = _timer_for(c, now)
		if t.is_empty():
			continue
		seen[c] = true
		var row: Array = _rows.get(c, [])
		if row.is_empty():
			row = _make_row()
			_rows[c] = row
		var pickup: bool = t[0]
		var start: float = t[1]
		var end: float = t[2]
		var ring: Ring = row[1]
		ring.color = PICKUP_COLOR if pickup else INBOUND_COLOR
		ring.progress = 1.0 if end <= start else clampf((now - start) / (end - start), 0.0, 1.0)
		ring.queue_redraw()
		(row[2] as Label).text = "%s  ·  %s" % [c.company, "Pickup" if pickup else "Inbound"]
		(row[3] as Label).text = "Waiting for a free dock" if now >= end else "Arrives in %s" % _format_left(end - now)
	for c: Contract in _rows.keys():
		if not seen.has(c):
			(_rows[c][0] as Node).queue_free()
			_rows.erase(c)
	visible = not _rows.is_empty()


## [pickup, start, end] in game minutes, or [] when no truck is on its way.
func _timer_for(c: Contract, now: float) -> Array:
	var storage: float = c.storage_days * GameplayConfig.MINUTES_PER_CONTRACT_DAY
	var visit: TerminalSim.Visit = _sim.pending_visit_for(c)
	if visit != null:
		var start: float = visit.since
		if visit.pickup and c.stored_minutes > 0.0:
			start = visit.at - GameplayConfig.PICKUP_LEAD_MINUTES - storage
		return [visit.pickup, start, visit.at]
	if c.state == Contract.State.STORED:
		var start: float = now - c.stored_minutes
		return [true, start, start + storage + GameplayConfig.PICKUP_LEAD_MINUTES]
	return []


func _make_row() -> Array:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	var ring: Ring = Ring.new()
	ring.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(ring)
	var text: VBoxContainer = VBoxContainer.new()
	text.add_theme_constant_override(&"separation", 0)
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(text)
	var title: Label = Label.new()
	title.add_theme_font_size_override(&"font_size", 19)
	text.add_child(title)
	var left: Label = Label.new()
	left.theme_type_variation = &"SubLabel"
	left.add_theme_font_size_override(&"font_size", 17)
	text.add_child(left)
	_list.add_child(row)
	return [row, ring, title, left]


## Game minutes left as "1 h 05 min", "12:30" (min:s) or "45 s".
static func _format_left(minutes: float) -> String:
	var s: int = ceili(minutes * 60.0)
	if s >= 3600:
		return "%d h %02d min" % [s / 3600, (s % 3600) / 60]
	if s >= 60:
		return "%d:%02d" % [s / 60, s % 60]
	return "%d s" % s
