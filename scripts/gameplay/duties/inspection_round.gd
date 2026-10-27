class_name InspectionRound
extends Duty
## A round of checks with the clipboard: along one rack aisle (beam locks,
## uprights, labels) while no forklift works it, or a safety round past the
## fire point, the dock doors and the walkways.

## Checkpoints: [position, yaw facing what is checked].
var points: Array = []
var aisle: Traffic.ZoneLock = null


func _init(p_points: Array, p_aisle: Traffic.ZoneLock, p_title: String) -> void:
	points = p_points
	aisle = p_aisle
	kind = &"rack_round" if p_aisle != null else &"safety_round"
	title = p_title


func plan() -> bool:
	if aisle != null:
		aisle.set_meta(&"inspected_by", self)
	planner.call(&"claim_points", points, worker)
	var board: PropItem = worker.kit.get(&"clipboard")
	var first: bool = true
	for pt: Array in points:
		walk(pt[0], pt[1], "walking to the next check")
		if first and board != null:
			take(board, &"L", "")
			first = false
		act(&"Clipboard", DutyConfig.RACK_CHECK_TIME * randf_range(0.8, 1.2), "checking %s" % ("the rack" if aisle != null else "the area"), pt)
		if randf() < 0.3:
			act(&"Inspect", 2.5, "looking closer", pt)
	if board != null:
		stow(board)
	call_step(func() -> void: worker.hold(&"Idle"))
	return true


func release() -> void:
	planner.call(&"release_points", worker)
	if aisle != null and aisle.has_meta(&"inspected_by") and aisle.get_meta(&"inspected_by") == self:
		aisle.remove_meta(&"inspected_by")
