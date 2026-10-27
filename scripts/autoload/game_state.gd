extends Node
## Global game state: money, clock, pause and speed.
## Real-time clock: at 1x one real second is one game second
## (minutes_per_second = 1/60). Motion, duties and the clock all run on the
## same game time: real seconds x speed.

signal money_changed(money: int)
signal time_changed(day: int, minutes: float)
signal speed_changed(speed: int)
signal paused_changed(paused: bool)
## Emitted every frame the clock moves, with the game minutes that passed.
## Sim nodes connect to this instead of reading delta themselves.
signal minutes_advanced(game_minutes: float)
## A gameplay event worth a toast (the HUD shows it).
signal notice_posted(title: String, body: String)

const SPEEDS: Array[int] = [1, 2, 5, 10, 30]
const MINUTES_PER_DAY: float = 24.0 * 60.0

@export var minutes_per_second: float = 1.0 / 60.0

var money: int = 12450:
	set(value):
		money = value
		money_changed.emit(money)
var day: int = 3
var minutes: float = 9.0 * 60.0 + 40.0
var paused: bool = false:
	set(value):
		if paused == value:
			return
		paused = value
		paused_changed.emit(paused)
var speed: int = 1:
	set(value):
		if speed == value:
			return
		speed = value
		speed_changed.emit(speed)

var _last_whole_minute: int = -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_whole_minute = int(minutes)


func _process(delta: float) -> void:
	if paused:
		return
	advance(delta * float(speed) * minutes_per_second)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_pause"):
		toggle_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("speed_cycle"):
		cycle_speed()
		get_viewport().set_input_as_handled()


## Moves the clock forward by game_minutes. Public so tests can drive time.
func advance(game_minutes: float) -> void:
	if game_minutes <= 0.0:
		return
	minutes += game_minutes
	while minutes >= MINUTES_PER_DAY:
		minutes -= MINUTES_PER_DAY
		day += 1
		_last_whole_minute = -1
	minutes_advanced.emit(game_minutes)
	var whole: int = int(minutes)
	if whole != _last_whole_minute:
		_last_whole_minute = whole
		time_changed.emit(day, minutes)


## Absolute game time in minutes since day 0, for scheduling.
func now() -> float:
	return float(day) * MINUTES_PER_DAY + minutes


func notify(title: String, body: String) -> void:
	print("Notice: %s - %s" % [title, body])
	notice_posted.emit(title, body)


func add_money(amount: int) -> void:
	money += amount


func toggle_pause() -> void:
	paused = not paused


func cycle_speed() -> void:
	var idx: int = SPEEDS.find(speed)
	speed = SPEEDS[(idx + 1) % SPEEDS.size()]


func format_money(value: int) -> String:
	var digits: String = str(absi(value))
	var out: String = ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out


func format_clock() -> String:
	var whole: int = int(minutes)
	return "Day %d · %02d:%02d" % [day, whole / 60, whole % 60]


## "14:05", with "Day N " in front when it is not today. Takes now()-style minutes.
func format_time_of(total_minutes: float) -> String:
	var d: int = floori(total_minutes / MINUTES_PER_DAY)
	var whole: int = int(total_minutes - d * MINUTES_PER_DAY)
	var clock: String = "%02d:%02d" % [whole / 60, whole % 60]
	return clock if d == day else "Day %d %s" % [d, clock]
