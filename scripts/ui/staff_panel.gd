extends PanelContainer
## Staff tab: each worker with the duty they are on, what they are doing
## right now, and their needs (tiredness, thirst, wish for company) as
## small bars. Reads the DutyPlanner a few times a second. F2 toggles it.

const REFRESH: float = 0.25
const NEED_COLORS: Array[Color] = [Color(0.95, 0.62, 0.25), Color(0.35, 0.65, 1.0), Color(0.55, 0.85, 0.45)]

var _planner: Node = null
var _t: float = 0.0
var _rows: GridContainer = null


func _ready() -> void:
	_rows = %Rows
	hide()


func _unhandled_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F2:
		visible = not visible
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = REFRESH
	if _planner == null:
		_planner = get_tree().get_first_node_in_group(&"duty_planner")
		if _planner == null:
			return
	_rebuild(_planner.call(&"staff_rows"))


func _rebuild(rows: Array) -> void:
	for c: Node in _rows.get_children():
		c.queue_free()
	for h: String in ["Worker", "Duty", "Now", "Needs", ""]:
		_rows.add_child(_label(h, &"MutedLabel", 13))
	for r: Dictionary in rows:
		_rows.add_child(_label(String(r.name), &"", 15))
		var duty: Label = _label(String(r.duty), &"", 15)
		duty.custom_minimum_size = Vector2(170, 0)
		_rows.add_child(duty)
		var now: Label = _label(String(r.status), &"SubLabel", 13)
		now.custom_minimum_size = Vector2(170, 0)
		now.clip_text = true
		_rows.add_child(now)
		var bars: HBoxContainer = HBoxContainer.new()
		bars.add_theme_constant_override(&"separation", 3)
		var i: int = 0
		for k: String in ["tired", "thirst", "social"]:
			bars.add_child(_bar(float(r[k]), NEED_COLORS[i]))
			i += 1
		_rows.add_child(bars)
		_rows.add_child(_label("%d / %d / %d" % [int(float(r.tired) * 100), int(float(r.thirst) * 100), int(float(r.social) * 100)], &"MutedLabel", 12))


func _bar(v: float, c: Color) -> Control:
	var back: ColorRect = ColorRect.new()
	back.color = Color(1, 1, 1, 0.12)
	back.custom_minimum_size = Vector2(36, 10)
	back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill: ColorRect = ColorRect.new()
	fill.color = c
	fill.size = Vector2(36.0 * clampf(v, 0.0, 1.0), 10)
	back.add_child(fill)
	return back


func _label(text: String, variation: StringName, size: int) -> Label:
	var l: Label = Label.new()
	l.text = text
	if variation != &"":
		l.theme_type_variation = variation
	l.add_theme_font_size_override(&"font_size", size)
	return l
