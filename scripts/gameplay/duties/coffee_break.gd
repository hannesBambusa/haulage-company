class_name CoffeeBreak
extends Duty
## A break in the break area. Coffee: a cup from the machine, then sitting
## at the table (SitIdle) or standing in the conversation circle; with others
## there they talk (Talk / Listen, a laugh now and then, a sip in between).
## Water: a cup at the cooler and a few sips. Chat: water, then join the
## people already talking. The cup goes in the bin before going back.

enum Kind { COFFEE, WATER, CHAT }

var mode: Kind = Kind.COFFEE
var _cup: PropItem = null
var _seat: Dictionary = {}
var _group: ConversationGroup = null
var _last_turn: int = -1
var _sip_in: float = 0.0


func _init(p_mode: Kind) -> void:
	mode = p_mode
	is_break = true
	match mode:
		Kind.COFFEE:
			kind = &"coffee"
			title = "Coffee break"
		Kind.WATER:
			kind = &"water"
			title = "Water break"
		Kind.CHAT:
			kind = &"chat"
			title = "Chatting"


func plan() -> bool:
	var area: BreakArea = planner.get(&"break_area")
	if area == null:
		return false
	if mode == Kind.COFFEE:
		var s: Array = area.spot("CoffeeSpot", "CoffeeMachine")
		use_spot("counter", s, "coffee machine")
		act(&"Idle", DutyConfig.COFFEE_BREW_TIME * 0.6, "making coffee", s)
		call_step(_new_cup)
		act(&"Idle", DutyConfig.COFFEE_BREW_TIME * 0.4, "making coffee", s)
		free_spot("counter")
	else:
		var s: Array = area.spot("WaterSpot", "WaterCooler")
		use_spot("counter", s, "water cooler")
		call_step(_new_cup)
		act(&"Idle", 1.5, "filling a cup", s)
		free_spot("counter")
	custom("", _choose, func(_s: Step, _dt: float) -> bool: return true)
	return true


func _new_cup() -> void:
	var area: BreakArea = planner.get(&"break_area")
	_cup = planner.call(&"new_cup", area.cup_spawn() if mode == Kind.COFFEE else _cooler_spout(area))
	worker.take(_cup, &"R")


func _cooler_spout(area: BreakArea) -> Transform3D:
	var c: Node3D = area.get_node(^"WaterCooler") as Node3D
	var f: Vector3 = c.global_basis.z.normalized()
	return Transform3D(Basis.looking_at(-f).scaled(Vector3.ONE * PropItem.HAND_SCALE), c.global_position + f * 0.2 + Vector3(0.0, 0.85, 0.0))


## After the cup: where to have it.
func _choose() -> void:
	var area: BreakArea = planner.get(&"break_area")
	var group: ConversationGroup = planner.call(&"break_group")
	var others: int = group.size()
	var talkers_coming: int = int(planner.call(&"breaks_heading", worker))
	if mode == Kind.WATER and others == 0:
		_drink_here()
		return
	var want_sit: bool = mode == Kind.COFFEE and others == 0 and talkers_coming == 0 and randf() < 0.55
	if want_sit:
		var seat: Dictionary = area.free_seat(worker.pos2())
		if not seat.is_empty():
			_sit(seat)
			return
	if group.is_full():
		_drink_here()
		return
	_join(group)


func _drink_here() -> void:
	var t: float = DutyConfig.WATER_TIME if mode == Kind.WATER else DutyConfig.rand_in(DutyConfig.COFFEE_TIME) * 0.5
	var s: Array = planner.call(&"drink_spot", worker)
	walk(s[0], s[1], "finding a place to stand")
	custom("having a drink", func() -> void: worker.hold(&"DrinkCoffee"), func(st: Step, dt: float) -> bool:
		_recover(dt, false)
		return st.t >= t, s)
	_bin_cup()


func _sit(seat: Dictionary) -> void:
	_seat = seat
	seat.taken_by = worker
	var pos: Vector2 = seat.pos
	var front: Vector2 = planner.call(&"seat_approach", seat)
	walk(front, seat.yaw, "going to sit down")
	custom("sitting down", func() -> void:
		worker.seat = seat.node
		worker.hold(&"SitIdle")
		worker.slide_to(pos, 0.9, &"SitIdle"),
		func(_s: Step, _dt: float) -> bool: return worker.motor != WorkerActor.Motor.RUNNING)
	var t: float = DutyConfig.rand_in(DutyConfig.COFFEE_TIME)
	custom("coffee at the table", func() -> void: worker.hold(&"SitIdle"), func(st: Step, dt: float) -> bool:
		_recover(dt, false)
		return st.t >= t)
	custom("getting up", func() -> void:
		worker.hold(&"Idle")
		worker.slide_to(front, 0.9, &"Idle"),
		func(_s: Step, _dt: float) -> bool:
			if worker.motor == WorkerActor.Motor.RUNNING:
				return false
			_free_seat()
			return true)
	_bin_cup()


func _join(group: ConversationGroup) -> void:
	var place: Array = group.join(worker)
	if place.is_empty():
		_drink_here()
		return
	_group = group
	walk(place[0], place[1], "joining the others")
	var t: float = DutyConfig.rand_in(DutyConfig.COFFEE_TIME)
	if mode != Kind.COFFEE:
		t *= 0.7
	custom("talking", func() -> void: worker.hold(&"DrinkCoffee"), _talk.bind(t), place)
	call_step(_leave_group)
	_bin_cup()


func _talk(st: Step, dt: float, t: float) -> bool:
	_recover(dt, true)
	var group: ConversationGroup = _group
	if group == null:
		return true
	if group.speaker == null:
		# alone (or the others still on their way): sip and wait
		if worker.current_action != &"DrinkCoffee" and worker._once_left <= 0.0:
			worker.hold(&"DrinkCoffee")
	elif group.speaker == worker:
		if worker.current_action != &"Talk" and worker._once_left <= 0.0:
			worker.hold(&"Talk")
	else:
		if group.turn != _last_turn:
			_last_turn = group.turn
			if randf() < DutyConfig.LAUGH_CHANCE and worker._once_left <= 0.0:
				worker.play_once(&"Laugh")
			# look at whoever talks now
			var sp: Vector2 = group.speaker.pos2()
			var want: float = WorkerActor.yaw_towards(worker.pos2(), sp)
			var centre_yaw: float = WorkerActor.yaw_towards(worker.pos2(), group.center)
			if absf(angle_difference(centre_yaw, want)) < 1.2 and not worker.is_busy_motor():
				worker.turn_to(want)
			_sip_in = randf_range(4.0, 9.0)
		_sip_in -= dt
		var anim: StringName = &"DrinkCoffee" if _sip_in < 0.0 and _sip_in > -4.0 else &"Listen"
		if worker.current_action != anim and worker._once_left <= 0.0:
			worker.hold(anim)
	# everyone else gone: finish the cup a little sooner
	return st.t >= t or (group.size() < 2 and st.t >= t * 0.5)


func _leave_group() -> void:
	if _group != null:
		_group.leave(worker)
		_group = null


func _free_seat() -> void:
	if not _seat.is_empty():
		if _seat.taken_by == worker:
			_seat.taken_by = null
		_seat = {}
	worker.seat = null


func _bin_cup() -> void:
	var area: BreakArea = planner.get(&"break_area")
	var s: Array = area.spot("TrashSpot", "TrashBin")
	use_spot("counter", s, "bin")
	custom("throwing the cup away", func() -> void:
		if _cup != null and _cup.holder == worker:
			worker.put(_cup, area, Transform3D(_cup.global_basis, area.bin_mouth()), PropItem.Where.BINNED),
		func(st: Step, _dt: float) -> bool:
			if st.t < DutyConfig.PROP_MOVE_TIME:
				return false
			if _cup != null:
				planner.call(&"bin_cup", _cup)
				_cup = null
			return true)
	free_spot("counter")


func _recover(dt: float, talking: bool) -> void:
	if mode == Kind.COFFEE:
		worker.tired = maxf(0.0, worker.tired - DutyConfig.COFFEE_RECOVER * dt)
	worker.thirst = maxf(0.0, worker.thirst - DutyConfig.WATER_RECOVER * dt * (0.3 if mode == Kind.COFFEE else 1.0))
	if talking and _group != null and _group.speaker != null:
		worker.social = maxf(0.0, worker.social - DutyConfig.TALK_RECOVER * dt)


func cleanup(urgent: bool) -> void:
	_leave_group()
	_free_seat()
	_cup = null  # the cup goes in the bin (or down here) with the rest
	put_down_all(urgent)


func release() -> void:
	_leave_group()
	_free_seat()
