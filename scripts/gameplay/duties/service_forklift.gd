class_name ServiceForklift
extends Duty
## A parked, idle forklift is due for a check: fetch the toolbox, set it
## down beside the forklift, kneel with the wrench. The forklift stays
## available: JobBoard holds a job for it only while the worker is next to
## it. When a job comes (hold_wanted), the worker puts the wrench away,
## picks up the toolbox and steps back first; then the hold is released and
## the forklift sets off (it still keeps its distance by the usual rules).

var lift: ForkliftCarrier = null
var _toolbox: PropItem = null
var _wrench: PropItem = null
var _held: bool = false
var _kneel: Array = []
var _box_at: Vector3 = Vector3.ZERO


func _init(p_lift: ForkliftCarrier) -> void:
	lift = p_lift
	kind = &"service"
	title = "Servicing %s" % p_lift.label


func plan() -> bool:
	lift.set_meta(&"serviced_by", self)
	_toolbox = planner.call(&"claim_prop", &"toolbox", self)
	if _toolbox == null:
		return false
	_wrench = planner.call(&"wrench_for", _toolbox)
	_kneel = _service_spot()
	if _kneel.is_empty():
		return false
	var s: Array = planner.call(&"prop_stand_spot", _toolbox)
	if _toolbox.where == PropItem.Where.HOME:
		use_spot("corner", s, "toolbox")
	else:
		walk(s[0], s[1], "getting the toolbox")
	_crouch(func() -> void:
		_toolbox.claimed_by = null
		worker.take(_toolbox, &"L")
		planner.call(&"prop_lifted", _toolbox), "picking up the toolbox")
	free_spot("corner")
	call_step(func() -> void: worker.service_vehicle = lift)
	walk(_kneel[0], _kneel[1], "walking to %s" % lift.label)
	call_step(_check_still_parked)
	_crouch(func() -> void:
		worker.put(_toolbox, planner.get(&"dirt"), Transform3D(Basis(Vector3.UP, worker.yaw() + PI * 0.5), _box_at), PropItem.Where.PLACED)
		planner.get(&"board").call(&"hold_agent", lift, self)
		_held = true, "putting the toolbox down")
	call_step(func() -> void:
		if _wrench != null:
			worker.take(_wrench, &"R"))
	var t: float = DutyConfig.rand_in(DutyConfig.SERVICE_TIME)
	act(&"Wrench", t, "tightening bolts", _kneel)
	call_step(func() -> void: lift.set_meta(&"serviced_at", float(planner.get(&"clock"))))
	_pack_up()
	call_step(_return_home)
	return true


func _crouch(fn: Callable, label: String) -> void:
	custom(label, func() -> void: worker.hold(&"Inspect"), func(st: Step, _dt: float) -> bool:
		if st.t >= 0.7 and not st.has_meta(&"did"):
			st.set_meta(&"did", true)
			fn.call()
		return st.t >= 1.3)
	call_step(func() -> void: worker.hold(&"Idle"))


func _check_still_parked() -> void:
	if not lift.is_idle() or lift.speed > 0.02:
		abort(false)


## Kneeling spot beside the forklift body, facing it, with room for the
## toolbox on the worker's right.
func _service_spot() -> Array:
	var nav: PeopleNav = planner.get(&"nav")
	var body: FootprintBox = lift.body_boxes_at(lift._pos, lift._yaw)[0]
	var side: Vector2 = body.ax.orthogonal()
	for sgn: float in [1.0, -1.0]:
		var n: Vector2 = side * sgn
		var p: Vector2 = body.c + n * (body.hw + 0.5)
		var y: float = WorkerActor.yaw_towards(p, p - n)
		var right: Vector2 = Vector2(cos(y), -sin(y))
		var box: Vector2 = p + right * 0.5 - n * 0.05
		if nav.walkable(p) and nav.walkable(box) and nav.walkable(p + n * 1.6):
			_box_at = Vector3(box.x, 0.0, box.y)
			return [p, y]
	return []


## Wrench back in the toolbox, toolbox in hand: ready to walk.
func _pack_up() -> void:
	call_step(func() -> void:
		worker.hold(&"Idle")
		_stash_wrench())
	_crouch(func() -> void:
		if _toolbox.holder != worker:
			worker.take(_toolbox, &"L")
			planner.call(&"prop_lifted", _toolbox), "picking up the toolbox")


func _stash_wrench() -> void:
	if _wrench != null and _wrench.holder == worker:
		worker.put(_wrench, _toolbox, _toolbox.global_transform * PropStore.wrench_in_box(), PropItem.Where.HOME)


## Steps clear of the forklift, then lets JobBoard send it off.
func _step_back() -> void:
	var nav: PeopleNav = planner.get(&"nav")
	var body: FootprintBox = lift.body_boxes_at(lift._pos, lift._yaw)[0]
	var n: Vector2 = (worker.pos2() - body.c)
	n = n.normalized() if n.length() > 0.01 else Vector2.RIGHT
	var to: Vector2 = nav.nearest_walkable(worker.pos2() + n * DutyConfig.SERVICE_STEP_BACK, 1.5)
	walk(to, WorkerActor.yaw_towards(to, body.c), "stepping back from %s" % lift.label)
	call_step(_release_hold)


func _return_home() -> void:
	_step_back()
	call_step(func() -> void:
		worker.service_vehicle = null
		put_down_all(false))


func _release_hold() -> void:
	worker.service_vehicle = null
	if _held:
		_held = false
		planner.get(&"board").call(&"release_hold", lift, self)


## The forklift is wanted: pack up and step back now.
func on_hold_wanted() -> void:
	if aborting or done:
		return
	aborting = true
	_steps.clear()
	_cur = null
	worker.stop_motor()
	_pack_up()
	_return_home()


func cleanup(urgent: bool) -> void:
	if urgent:
		_release_hold()
		_stash_wrench()
		if _toolbox != null and _toolbox.where == PropItem.Where.PLACED:
			_toolbox.where = PropItem.Where.LOOSE
		put_down_all(true)
		return
	if _toolbox != null and (_toolbox.where == PropItem.Where.PLACED or (_wrench != null and _wrench.holder == worker)):
		_pack_up()
		_return_home()
		return
	_release_hold()
	call_step(func() -> void:
		worker.service_vehicle = null
		put_down_all(false))


func release() -> void:
	_release_hold()
	worker.service_vehicle = null
	if lift != null and lift.has_meta(&"serviced_by") and lift.get_meta(&"serviced_by") == self:
		lift.remove_meta(&"serviced_by")
	if _toolbox != null and _toolbox.claimed_by == self:
		_toolbox.claimed_by = null
	if _toolbox != null and _toolbox.where == PropItem.Where.PLACED and _toolbox.holder == null:
		_toolbox.where = PropItem.Where.LOOSE
