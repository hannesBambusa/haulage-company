class_name GameMenu
extends Control
## Esc menu: pauses the game and shows Resume, graphics quality
## (Low / Medium / High), Fullscreen / Window and Quit. Esc only opens it
## when nothing else used the key (a dialog, a selected pallet). The top
## bar's gear and menu buttons open it too.

var _was_paused: bool = false
var _quality: Array[Button] = []
var _display: Array[Button] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.08, 0.55)
	add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center: CenterContainer = CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	center.add_child(panel)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 16)
	panel.add_child(box)

	var title: Label = Label.new()
	title.theme_type_variation = &"HeaderLabel"
	title.text = "Menu"
	box.add_child(title)
	var resume: Button = _button("Resume")
	resume.pressed.connect(close)
	box.add_child(resume)
	box.add_child(HSeparator.new())

	box.add_child(_caption("Graphics"))
	var qrow: HBoxContainer = _row()
	box.add_child(qrow)
	for i: int in Settings.QUALITY_NAMES.size():
		var b: Button = _toggle(Settings.QUALITY_NAMES[i])
		b.pressed.connect(func() -> void: Settings.set_quality(i as Settings.Quality))
		qrow.add_child(b)
		_quality.append(b)

	box.add_child(_caption("Display"))
	var drow: HBoxContainer = _row()
	box.add_child(drow)
	for on: bool in [true, false]:
		var b: Button = _toggle("Fullscreen" if on else "Window")
		b.pressed.connect(func() -> void: Settings.set_fullscreen(on))
		drow.add_child(b)
		_display.append(b)
	box.add_child(HSeparator.new())

	var quit: Button = _button("Quit game")
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)

	Settings.changed.connect(_sync)
	Settings.menu_requested.connect(open)
	_sync()
	hide()


func open() -> void:
	if visible:
		return
	_was_paused = GameState.paused
	GameState.paused = true
	_sync()
	show()


func close() -> void:
	if not visible:
		return
	hide()
	GameState.paused = _was_paused


func toggle() -> void:
	if visible:
		close()
	else:
		open()


## Esc closes it here (first, it is drawn on top); opening comes from
## Settings.menu_requested, after the rest of the game had its turn.
func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _sync() -> void:
	for i: int in _quality.size():
		_quality[i].set_pressed_no_signal(i == Settings.quality)
	_display[0].set_pressed_no_signal(Settings.fullscreen)
	_display[1].set_pressed_no_signal(not Settings.fullscreen)


func _caption(text: String) -> Label:
	var l: Label = Label.new()
	l.theme_type_variation = &"MutedLabel"
	l.text = text
	return l


func _row() -> HBoxContainer:
	var r: HBoxContainer = HBoxContainer.new()
	r.add_theme_constant_override(&"separation", 10)
	return r


func _button(text: String) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 44)
	return b


func _toggle(text: String) -> Button:
	var b: Button = _button(text)
	b.toggle_mode = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b
