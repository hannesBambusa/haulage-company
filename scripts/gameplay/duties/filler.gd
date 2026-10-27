class_name Filler
extends Duty
## Short things between jobs, always somewhere out of the forklifts' way: a
## phone call (phone from the belt) or a stretch.

enum Kind { PHONE, STRETCH }

var mode: Kind = Kind.PHONE
var spot: Array = []


func _init(p_mode: Kind, p_spot: Array) -> void:
	mode = p_mode
	spot = p_spot
	kind = &"phone" if mode == Kind.PHONE else &"stretch"
	title = "On the phone" if mode == Kind.PHONE else "Stretching"


func plan() -> bool:
	planner.call(&"claim_points", [spot], worker)
	if (spot[0] as Vector2).distance_to(worker.pos2()) > 0.1:
		walk(spot[0], spot[1], "finding a quiet spot")
	if mode == Kind.PHONE:
		var phone: PropItem = worker.kit.get(&"phone")
		if phone != null:
			take(phone, &"R", "taking a call")
		act(&"PhoneCall", DutyConfig.rand_in(DutyConfig.PHONE_TIME), "on the phone", spot)
		if phone != null:
			stow(phone)
	else:
		for i: int in DutyConfig.STRETCH_REPEATS:
			once(&"Stretch", "stretching", spot)
	call_step(func() -> void: worker.hold(&"Idle"))
	return true


func release() -> void:
	planner.call(&"release_points", worker)
