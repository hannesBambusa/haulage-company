class_name TidyUp
extends Duty
## Puts away something left lying about (a tool or cup put down when a
## duty was cut short, or the box a worker carried in): walk there, pick it
## up, take it where it belongs.

var prop: PropItem = null


func _init(p_prop: PropItem) -> void:
	prop = p_prop
	kind = &"tidy"
	title = "Tidying up the %s" % p_prop.kind


func plan() -> bool:
	prop.claimed_by = self
	var s: Array = planner.call(&"prop_stand_spot", prop)
	walk(s[0], s[1], "walking to the %s" % prop.kind)
	var hand: StringName = &"L" if prop.floor_prop else &"R"
	custom("picking up the %s" % prop.kind, func() -> void: worker.hold(&"Inspect"), func(st: Step, _dt: float) -> bool:
		if st.t >= 0.7 and prop.holder != worker:
			prop.claimed_by = null
			worker.take(prop, hand)
			planner.call(&"prop_lifted", prop)
		return st.t >= 1.3)
	call_step(func() -> void:
		worker.hold(&"Idle")
		put_down_all(false))
	return true


func release() -> void:
	if prop != null and prop.claimed_by == self:
		prop.claimed_by = null
