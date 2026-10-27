class_name CleanFloor
extends Duty
## Cleans one dirt spot. Dust: the broom from the cleaning corner, then
## slow sweeping passes over the spot (the Sweep cycle moves at its own root
## speed), back and forth, until the decal has faded. Spill: the mop, the
## bucket rolled along and the wet floor sign, which stands next to the
## spill while mopping. Every tool goes back to the corner afterwards.

## Broom head / mop head distance in front of the worker (m, at scale 1.2).
const BROOM_REACH: float = 0.74
const MOP_REACH: float = 0.78
const PASS_LENGTH: float = 1.3

var spot: DirtField.Spot = null
var _tool: PropItem = null
var _bucket: PropItem = null
var _sign: PropItem = null
var _passes: int = 0
var _dir: Vector2 = Vector2.RIGHT


func _init(p_spot: DirtField.Spot) -> void:
	spot = p_spot
	kind = &"clean"
	title = "Mopping a spill" if spot.spill else "Sweeping the floor"


func plan() -> bool:
	spot.claimed_by = self
	_tool = planner.call(&"claim_prop", &"mop" if spot.spill else &"broom", self)
	if _tool == null:
		return false
	if spot.spill:
		_bucket = planner.call(&"claim_prop", &"bucket", self)
		_sign = planner.call(&"claim_prop", &"sign", self)
	_dir = _sweep_dir()
	if _dir == Vector2.ZERO:
		return false
	_fetch(_tool, &"R")
	if _sign != null:
		_fetch(_sign, &"L")
	if _bucket != null:
		var b: Array = planner.call(&"prop_stand_spot", _bucket)
		use_spot("corner", b, "bucket")
		tow(_bucket)
		free_spot("corner")
	if spot.spill:
		_plan_mop()
	else:
		_plan_sweep_pass()
	return true


func _fetch(p: PropItem, hand: StringName) -> void:
	var s: Array = planner.call(&"prop_stand_spot", p)
	var at_corner: bool = p.where == PropItem.Where.HOME
	if at_corner:
		use_spot("corner", s, "tool rack")
	else:
		walk(s[0], s[1], "getting the %s" % p.kind)
	if p.floor_prop or p.where == PropItem.Where.LOOSE:
		_crouch_take(p, hand)
	else:
		take(p, hand)
	if at_corner:
		free_spot("corner")


func _crouch_take(p: PropItem, hand: StringName) -> void:
	custom("picking up the %s" % p.kind, func() -> void: worker.hold(&"Inspect"), func(st: Step, _dt: float) -> bool:
		if st.t >= 0.7 and p.holder != worker:
			p.claimed_by = null
			worker.take(p, hand)
			planner.call(&"prop_lifted", p)
		return st.t >= 1.3)
	call_step(func() -> void: worker.hold(&"Idle"))


## Sweeping direction with room for the passes on both sides of the spot.
func _sweep_dir() -> Vector2:
	var nav: PeopleNav = planner.get(&"nav")
	var reach: float = MOP_REACH if spot.spill else BROOM_REACH
	for a: float in [0.0, PI * 0.5, PI * 0.25, PI * 0.75, PI / 8.0, PI * 5.0 / 8.0]:
		var d: Vector2 = Vector2.from_angle(a)
		var ok: bool = true
		for p: Vector2 in [spot.pos - d * (PASS_LENGTH * 0.5 + reach), spot.pos + d * (PASS_LENGTH * 0.5 + reach), spot.pos - d * reach, spot.pos + d * reach]:
			if not nav.walkable(p):
				ok = false
				break
		if ok:
			return d if randf() < 0.5 else -d
	return Vector2.ZERO


func _plan_sweep_pass() -> void:
	# broom head runs from one side of the spot to the other; side offset per pass
	var d: Vector2 = _dir if _passes % 2 == 0 else -_dir
	var side: Vector2 = _dir.orthogonal() * (0.22 if (_passes / 2) % 2 == 0 else -0.22)
	var start: Vector2 = spot.pos + side - d * (PASS_LENGTH * 0.5 + BROOM_REACH)
	var end: Vector2 = spot.pos + side + d * (PASS_LENGTH * 0.5 - BROOM_REACH)
	var y: float = atan2(-d.x, -d.y)
	walk(start, y, "walking to the dirt")
	custom("sweeping", func() -> void:
		worker.hold(&"Sweep")
		worker.slide_to(end, worker.sweep_speed(), &"Sweep"),
		func(_s: Step, dt: float) -> bool:
			var dirt: DirtField = planner.get(&"dirt")
			if not spot.cleaned:
				dirt.clean(spot, DutyConfig.SWEEP_PASS_CLEAN * dt * worker.sweep_speed() / PASS_LENGTH)
			if worker.motor == WorkerActor.Motor.RUNNING:
				return false
			worker.hold(&"Idle")
			_passes += 1
			if not spot.cleaned and _passes < 8:
				_plan_sweep_pass()
			else:
				_finish_cleaning()
			return true, [start, y])


func _plan_mop() -> void:
	var nav: PeopleNav = planner.get(&"nav")
	# the sign goes up beside the spill first
	if _sign != null:
		var sp: Vector2 = spot.pos + _dir.orthogonal() * 1.0
		if not nav.walkable(sp):
			sp = spot.pos - _dir.orthogonal() * 1.0
		var stand: Vector2 = sp - _dir * 0.55
		walk(stand, WorkerActor.yaw_towards(stand, sp), "putting up the wet floor sign")
		custom("putting up the sign", func() -> void: worker.hold(&"Inspect"), func(st: Step, _dt: float) -> bool:
			if st.t >= 0.7 and _sign.holder == worker:
				var xf: Transform3D = Transform3D(Basis(Vector3.UP, randf() * TAU), Vector3(sp.x, 0.0, sp.y))
				worker.put(_sign, planner.get(&"dirt"), xf, PropItem.Where.PLACED)
			return st.t >= 1.3)
	for k: int in 2:
		var d: Vector2 = _dir if k == 0 else -_dir
		var stand: Vector2 = spot.pos - d * MOP_REACH
		var y: float = atan2(-d.x, -d.y)
		walk(stand, y, "walking to the spill")
		var t: float = 6.0
		custom("mopping", func() -> void: worker.hold(&"Mop"), func(st: Step, dt: float) -> bool:
			var dirt: DirtField = planner.get(&"dirt")
			if not spot.cleaned:
				dirt.clean(spot, DutyConfig.MOP_STROKE_CLEAN * dt * 0.5)
			return st.t >= t or spot.cleaned, [stand, y])
	custom("", func() -> void: pass, func(_s: Step, _dt: float) -> bool:
		if not spot.cleaned and _passes < 3:
			_passes += 1
			_plan_mop_more()
		else:
			_finish_cleaning()
		return true)


func _plan_mop_more() -> void:
	var d: Vector2 = _dir.orthogonal()
	var stand: Vector2 = spot.pos - d * MOP_REACH
	var nav: PeopleNav = planner.get(&"nav")
	if not nav.walkable(stand):
		d = -d
		stand = spot.pos - d * MOP_REACH
	var y: float = atan2(-d.x, -d.y)
	walk(stand, y, "walking to the spill")
	custom("mopping", func() -> void: worker.hold(&"Mop"), func(st: Step, dt: float) -> bool:
		var dirt: DirtField = planner.get(&"dirt")
		if not spot.cleaned:
			dirt.clean(spot, DutyConfig.MOP_STROKE_CLEAN * dt * 0.5)
		if st.t >= 6.0 or spot.cleaned:
			if not spot.cleaned:
				_plan_mop_more()
			else:
				_finish_cleaning()
			return true
		return false, [stand, y])


## Clean: pick the sign back up, then every tool goes home.
func _finish_cleaning() -> void:
	call_step(func() -> void: worker.hold(&"Idle"))
	if _sign != null and _sign.where == PropItem.Where.PLACED:
		var sp: Vector2 = Vector2(_sign.global_position.x, _sign.global_position.z)
		var stand: Vector2 = (planner.get(&"nav") as PeopleNav).nearest_walkable(sp + (worker.pos2() - sp).normalized() * 0.6, 1.0)
		walk(stand, WorkerActor.yaw_towards(stand, sp), "picking up the sign")
		_crouch_take(_sign, &"L")
	call_step(func() -> void: put_down_all(false))


func cleanup(urgent: bool) -> void:
	if not urgent and _sign != null and _sign.where == PropItem.Where.PLACED and _sign.holder == null:
		var sp: Vector2 = Vector2(_sign.global_position.x, _sign.global_position.z)
		var stand: Vector2 = (planner.get(&"nav") as PeopleNav).nearest_walkable(sp + (worker.pos2() - sp).normalized() * 0.6, 1.0)
		walk(stand, WorkerActor.yaw_towards(stand, sp), "picking up the sign")
		_crouch_take(_sign, &"L")
		call_step(func() -> void: put_down_all(false))
		return
	if urgent and _sign != null and _sign.where == PropItem.Where.PLACED:
		_sign.where = PropItem.Where.LOOSE
	put_down_all(urgent)


func release() -> void:
	if spot != null and spot.claimed_by == self:
		spot.claimed_by = null
	for p: PropItem in [_tool, _bucket, _sign]:
		if p != null and p.claimed_by == self:
			p.claimed_by = null
	if _sign != null and _sign.where == PropItem.Where.PLACED and _sign.holder == null:
		_sign.where = PropItem.Where.LOOSE  # someone tidies it away
