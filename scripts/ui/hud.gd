extends CanvasLayer
## Game HUD: top bar bound to GameState, dock info panel bound to a Dock,
## bottom tab strip. Contracts tab opens the contracts window, Storage tab the
## storage panel. GameState.notify() notices show as toasts, stacked below
## the dock panel (never over it), newest at the bottom. The dock panel
## follows whichever dock has a truck (watched_dock_id first).

@export var watched_dock_id: int = 1
@export var pause_icon: Texture2D = preload("res://ui/icons/pause.svg")
@export var play_icon: Texture2D = preload("res://ui/icons/play.svg")
## Real seconds a toast stays up.
@export var toast_seconds: float = 5.0
## Most toasts shown at once; the oldest goes first.
@export var max_toasts: int = 3
## Gap between the dock panel and the toasts, and between toasts.
@export var toast_gap: float = 10.0

const COLOR_IDLE: Color = Color(0.541, 0.604, 0.690)
const COLOR_ARRIVING: Color = Color(0.961, 0.725, 0.259)
const COLOR_UNLOADING: Color = Color(0.239, 0.863, 0.518)
const COLOR_DEPARTING: Color = Color(0.353, 0.627, 1.0)
const COLOR_LOADING: Color = Color(0.95, 0.75, 0.16)

@onready var _money: Label = %Money
@onready var _day: Label = %DayLabel
@onready var _pause_button: Button = %PauseButton
@onready var _speed_button: Button = %SpeedButton
@onready var _dock_panel: PanelContainer = %DockPanel
@onready var _dock_title: Label = %DockTitle
@onready var _status_dot: Panel = %StatusDot
@onready var _status_label: Label = %StatusLabel
@onready var _progress: ProgressBar = %Progress
@onready var _pallets_label: Label = %PalletsLabel
@onready var _truck_company: Label = %TruckCompany
@onready var _truck_cargo: Label = %TruckCargo
@onready var _alert_toast: PanelContainer = %AlertToast
@onready var _alert_title: Label = %AlertTitle
@onready var _alert_body: Label = %AlertBody
@onready var _contracts_window: Control = %ContractsWindow
@onready var _tabs: HBoxContainer = %Tabs
@onready var _tab_strip: PanelContainer = %TabStrip
@onready var _storage_panel: Control = %StoragePanel
@onready var _truck_header: Label = $Root/DockPanel/VBox/CurrentTruck

var _dock: Dock = null
var _docks: Array[Dock] = []
var _staff_panel: Control = null
var _dot_style: StyleBoxFlat
var _toast_stack: VBoxContainer


func _ready() -> void:
	_dot_style = (_status_dot.get_theme_stylebox(&"panel") as StyleBoxFlat).duplicate()
	_status_dot.add_theme_stylebox_override(&"panel", _dot_style)

	GameState.money_changed.connect(_on_money_changed)
	GameState.time_changed.connect(_on_time_changed)
	GameState.speed_changed.connect(_on_speed_changed)
	GameState.paused_changed.connect(_on_paused_changed)
	_on_money_changed(GameState.money)
	_on_time_changed(GameState.day, GameState.minutes)
	_on_speed_changed(GameState.speed)
	_on_paused_changed(GameState.paused)

	_pause_button.pressed.connect(GameState.toggle_pause)
	_speed_button.pressed.connect(GameState.cycle_speed)

	(_tabs.get_node(^"Contracts") as Button).pressed.connect(open_contracts)
	(_tabs.get_node(^"Storage") as Button).pressed.connect(toggle_storage)
	_staff_panel = (load("res://ui/staff_panel.tscn") as PackedScene).instantiate() as Control
	$Root.add_child(_staff_panel)
	(_tabs.get_node(^"Staff") as Button).pressed.connect(func() -> void: _staff_panel.visible = not _staff_panel.visible)
	_contracts_window.closed.connect(close_contracts)
	_storage_panel.closed.connect(close_storage)

	# AlertToast is the template; live toasts are copies in a stack
	_alert_toast.hide()
	_toast_stack = VBoxContainer.new()
	_toast_stack.name = "ToastStack"
	_toast_stack.add_theme_constant_override(&"separation", int(toast_gap))
	_toast_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_alert_toast.get_parent().add_child(_toast_stack)
	_toast_stack.anchor_left = 1.0
	_toast_stack.anchor_right = 1.0
	_toast_stack.offset_left = _alert_toast.offset_left
	_toast_stack.offset_right = _alert_toast.offset_right
	_toast_stack.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	GameState.notice_posted.connect(_on_notice)

	_show_dock_state(Dock.State.IDLE)
	_on_progress_changed(0, 8)
	_find_dock.call_deferred()


## Binds the dock info panel to a dock. Called automatically for watched_dock_id.
func bind_dock(dock: Dock) -> void:
	if _dock != null:
		_dock.state_changed.disconnect(_on_dock_state_changed)
		_dock.progress_changed.disconnect(_on_progress_changed)
	_dock = dock
	if _dock == null:
		return
	_dock.state_changed.connect(_on_dock_state_changed)
	_dock.progress_changed.connect(_on_progress_changed)
	_dock_title.text = "Dock %d" % _dock.dock_id
	_on_dock_state_changed(_dock.state)
	_on_progress_changed(_dock.pallets_done, _dock.pallets_total)


func open_contracts() -> void:
	close_storage()
	_contracts_window.show()
	_dock_panel.hide()
	_tab_strip.hide()


func close_contracts() -> void:
	_contracts_window.hide()
	_dock_panel.show()
	_tab_strip.show()


func open_storage() -> void:
	_storage_panel.show()
	(_tabs.get_node(^"Storage") as Button).button_pressed = true


func close_storage() -> void:
	_storage_panel.hide()


func toggle_storage() -> void:
	if _storage_panel.visible:
		close_storage()
	else:
		open_storage()


## Shows a toast below the dock panel (and below any toast already up).
## auto_hide_seconds <= 0 keeps it up until hide_alert().
func show_alert(title: String, body: String, auto_hide_seconds: float = 0.0) -> void:
	while _toast_stack.get_child_count() >= max_toasts:
		var oldest: Node = _toast_stack.get_child(0)
		_toast_stack.remove_child(oldest)
		oldest.queue_free()
	var toast: PanelContainer = _alert_toast.duplicate() as PanelContainer
	toast.unique_name_in_owner = false
	toast.layout_mode = 2
	(toast.find_child("AlertTitle", true, false) as Label).text = title
	(toast.find_child("AlertBody", true, false) as Label).text = body
	_toast_stack.add_child(toast)
	toast.show()
	_place_toasts()
	if auto_hide_seconds > 0.0:
		# a weak reference: the toast may be freed first (pushed out by newer ones)
		var ref: WeakRef = weakref(toast)
		get_tree().create_timer(auto_hide_seconds).timeout.connect(func() -> void:
			var t: Node = ref.get_ref() as Node
			if t != null:
				t.queue_free())


## Removes every toast.
func hide_alert() -> void:
	for t: Node in _toast_stack.get_children():
		t.queue_free()


func toast_count() -> int:
	var n: int = 0
	for t: Node in _toast_stack.get_children():
		if not t.is_queued_for_deletion():
			n += 1
	return n


## Keeps the toasts under the dock panel, and beside the Storage panel when
## that is open (the Storage panel itself sits under the dock panel).
func _place_toasts() -> void:
	var top: float = _alert_toast.offset_top
	var below_dock: float = _dock_panel.position.y + _dock_panel.size.y + toast_gap
	if _dock_panel.visible:
		top = maxf(top, below_dock)
	_toast_stack.offset_top = top
	_toast_stack.offset_bottom = top
	var right: float = _alert_toast.offset_right
	if _storage_panel.visible:
		right = _storage_panel.offset_left - toast_gap
	_toast_stack.offset_right = right
	_toast_stack.offset_left = right - (_alert_toast.offset_right - _alert_toast.offset_left)


func _process(_delta: float) -> void:
	if _storage_panel.visible and _dock_panel.visible:
		var below_dock: float = _dock_panel.position.y + _dock_panel.size.y + toast_gap
		if absf(_storage_panel.offset_top - below_dock) > 0.5:
			var h: float = _storage_panel.offset_bottom - _storage_panel.offset_top
			_storage_panel.offset_top = below_dock
			_storage_panel.offset_bottom = maxf(below_dock + 200.0, minf(below_dock + h, get_viewport().get_visible_rect().size.y - 110.0))
	if _toast_stack.get_child_count() > 0:
		_place_toasts()


func _find_dock() -> void:
	var watched: Dock = null
	for node: Node in get_tree().get_nodes_in_group(&"docks"):
		var dock: Dock = node as Dock
		if dock == null:
			continue
		_docks.append(dock)
		dock.state_changed.connect(_on_any_dock_state.bind(dock))
		if dock.dock_id == watched_dock_id:
			watched = dock
	if watched != null:
		bind_dock(watched)


## Show a dock that just got a truck, and leave a dock that went idle for
## one that is still busy.
func _on_any_dock_state(state: Dock.State, dock: Dock) -> void:
	if dock == _dock:
		if state == Dock.State.IDLE:
			for other: Dock in _docks:
				if not other.is_idle():
					bind_dock(other)
					return
		return
	if state == Dock.State.ARRIVING and (_dock == null or _dock.is_idle()):
		bind_dock(dock)


func _on_notice(title: String, body: String) -> void:
	show_alert(title, body, toast_seconds)


func _on_money_changed(money: int) -> void:
	_money.text = "$ " + GameState.format_money(money)


func _on_time_changed(_d: int, _m: float) -> void:
	_day.text = GameState.format_clock()


func _on_speed_changed(speed: int) -> void:
	_speed_button.text = "%dx" % speed


func _on_paused_changed(paused: bool) -> void:
	_pause_button.icon = play_icon if paused else pause_icon
	_speed_button.modulate.a = 0.5 if paused else 1.0


func _on_dock_state_changed(state: Dock.State) -> void:
	_show_dock_state(state)


func _show_dock_state(state: Dock.State) -> void:
	var color: Color = COLOR_IDLE
	var text: String = "Idle"
	match state:
		Dock.State.ARRIVING:
			color = COLOR_ARRIVING
			text = "Arriving"
		Dock.State.UNLOADING:
			color = COLOR_UNLOADING
			text = "Unloading"
		Dock.State.DEPARTING:
			color = COLOR_DEPARTING
			text = "Departing"
		Dock.State.LOADING:
			color = COLOR_LOADING
			text = "Loading"
	_status_label.text = text
	_status_label.add_theme_color_override(&"font_color", color)
	_dot_style.bg_color = color
	var has_truck: bool = state != Dock.State.IDLE and _dock != null
	_truck_company.text = _dock.truck_company if has_truck else "None"
	_truck_cargo.text = _dock.cargo_type if has_truck else "Waiting for booking"
	var pickup: bool = has_truck and _dock.loading
	_truck_header.text = "Pickup truck" if pickup else "Current truck"
	var c: Contract = _dock.contract if has_truck else null
	_truck_company.tooltip_text = "Contract %s · %d pallets" % [c.id, c.pallets] if c != null else ""


func _on_progress_changed(done: int, total: int) -> void:
	_progress.max_value = maxi(total, 1)
	_progress.value = done
	_pallets_label.text = "%d / %d pallets" % [done, total]
