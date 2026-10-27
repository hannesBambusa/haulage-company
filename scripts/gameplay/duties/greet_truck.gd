class_name GreetTruck
extends Duty
## A truck is reversing onto a dock: a worker goes to a spot beside the dock
## door, inside the hall and clear of the dock lane, waves at the driver, then
## checks the paperwork on the clipboard while the truck is worked.

var bay: TrailerBay = null
var spot: Array = []


func _init(p_bay: TrailerBay, p_spot: Array) -> void:
	bay = p_bay
	spot = p_spot
	kind = &"greet"
	title = "Meeting the truck at Dock %d" % p_bay.dock.dock_id


func plan() -> bool:
	bay.set_meta(&"greeter", self)
	walk(spot[0], spot[1], "walking to Dock %d" % bay.dock.dock_id)
	once(&"Wave", "waving at the driver", spot)
	once(&"Wave", "waving at the driver", spot)
	var board: PropItem = worker.kit.get(&"clipboard")
	if board != null:
		take(board, &"L", "")
	var t: float = DutyConfig.rand_in(DutyConfig.GREET_CLIPBOARD_TIME)
	custom("checking the delivery papers", func() -> void: worker.hold(&"Clipboard"), func(st: Step, _dt: float) -> bool:
		return st.t >= t or (st.t > 8.0 and bay.dock.state == Dock.State.IDLE), spot)
	if board != null:
		stow(board)
	call_step(func() -> void: worker.hold(&"Idle"))
	return true


func release() -> void:
	if bay != null and bay.has_meta(&"greeter") and bay.get_meta(&"greeter") == self:
		bay.remove_meta(&"greeter")
