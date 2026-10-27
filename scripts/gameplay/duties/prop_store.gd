class_name PropStore
extends RefCounted
## Every loose prop of the staff: the cleaning corner's tools (broom, mop,
## bucket, wet floor sign, toolbox with its wrench), each worker's belt kit
## (scanner, clipboard, phone) and the paper cups. Knows where each thing
## belongs and where to stand to take it or put it back; hands tools out one
## claim at a time; adds the steps that return a prop to its place.

const MODELS: Dictionary = {
	&"broom": "res://assets/models/prop_broom.glb",
	&"mop": "res://assets/models/prop_mop.glb",
	&"bucket": "res://assets/models/prop_bucket.glb",
	&"sign": "res://assets/models/wet_floor_sign.glb",
	&"toolbox": "res://assets/models/toolbox.glb",
	&"wrench": "res://assets/models/prop_wrench.glb",
	&"cup": "res://assets/models/prop_coffee_cup.glb",
	&"clipboard": "res://assets/models/prop_clipboard.glb",
	&"scanner": "res://assets/models/prop_scanner.glb",
	&"phone": "res://assets/models/prop_phone.glb",
}
const FLOOR_KINDS: Array[StringName] = [&"bucket", &"sign", &"toolbox", &"box"]
## The wrench lies in the toolbox tray (toolbox space).
static func wrench_in_box() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI * 0.5) * Basis.from_scale(Vector3.ONE * PropItem.HAND_SCALE), Vector3(0.0, 0.22, 0.0))

var planner: Node = null
var nav: PeopleNav = null
var corner: CleaningCorner = null
var area: BreakArea = null
var root: Node3D = null
var props: Array[PropItem] = []
var _scenes: Dictionary = {}


func _init(p_planner: Node, p_root: Node3D, p_nav: PeopleNav, p_corner: CleaningCorner, p_area: BreakArea) -> void:
	planner = p_planner
	root = p_root
	nav = p_nav
	corner = p_corner
	area = p_area


func make(kind: StringName) -> PropItem:
	if not _scenes.has(kind):
		_scenes[kind] = load(MODELS[kind])
	var p: PropItem = PropItem.make(kind, _scenes[kind], kind in FLOOR_KINDS)
	props.append(p)
	return p


## Tools in the cleaning corner, one of each.
func stock_corner() -> void:
	if corner == null:
		return
	for kind: StringName in [&"broom", &"mop", &"bucket", &"sign", &"toolbox"]:
		var p: PropItem = make(kind)
		p.set_home(root, corner.home_xform(kind))
		root.add_child(p)
		p.transform = p.home_xform
		p.where = PropItem.Where.HOME
		if p.floor_prop:
			placed(p)
	var box: PropItem = first(&"toolbox")
	var w: PropItem = make(&"wrench")
	box.add_child(w)
	w.transform = wrench_in_box()
	w.home_parent = box
	w.home_xform = wrench_in_box()
	w.where = PropItem.Where.HOME


## Belt kit for one worker.
func give_kit(w: WorkerActor) -> void:
	for kind: StringName in [&"scanner", &"clipboard", &"phone"]:
		var p: PropItem = make(kind)
		w.add_kit(p)


## The box a scenery worker carries in from the start: it gets a place by
## the back wall and the worker takes it there first.
func adopt_box(w: WorkerActor, box: Node3D, home: Transform3D) -> PropItem:
	var p: PropItem = PropItem.new()
	p.kind = &"box"
	p.name = "Prop_box"
	p.floor_prop = true
	var g: Transform3D = box.global_transform
	box.get_parent().remove_child(box)
	p.add_child(box)
	box.transform = Transform3D(g.basis, Vector3.ZERO)
	props.append(p)
	p.set_home(root, home)
	w.add_child(p)
	p.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, -0.32))
	box.transform = Transform3D(Basis.from_scale(Vector3.ONE * 0.83), Vector3.ZERO)
	w.towed.append(p)
	p.holder = w
	p.where = PropItem.Where.HELD
	return p


func first(kind: StringName) -> PropItem:
	for p: PropItem in props:
		if p.kind == kind:
			return p
	return null


## Free prop of a kind (home or lying about), claimed for `by`.
func claim(kind: StringName, by: Object) -> PropItem:
	for p: PropItem in props:
		if p.kind == kind and p.is_available() and p.where != PropItem.Where.PLACED:
			p.claimed_by = by
			return p
	return null


func available(kind: StringName) -> bool:
	for p: PropItem in props:
		if p.kind == kind and p.is_available() and p.where != PropItem.Where.PLACED:
			return true
	return false


func loose() -> Array[PropItem]:
	var out: Array[PropItem] = []
	for p: PropItem in props:
		if p.where == PropItem.Where.LOOSE and p.holder == null and p.claimed_by == null and is_instance_valid(p):
			out.append(p)
	return out


func wrench_for(_box: PropItem) -> PropItem:
	return first(&"wrench")


## Where to stand to take `p` from where it is now: [position, yaw].
func stand_spot(p: PropItem) -> Array:
	if p.where == PropItem.Where.HOME and corner != null and p.kind in [&"broom", &"mop", &"bucket", &"sign", &"toolbox"]:
		return corner.stand_spot(p.kind)
	if p.kind == &"box" and p.where != PropItem.Where.LOOSE:
		return box_spot(p)
	var at: Vector2 = Vector2(p.global_position.x, p.global_position.z)
	return spot_near(at, 0.55)


func box_spot(p: PropItem) -> Array:
	var at: Vector2 = Vector2(p.home_xform.origin.x, p.home_xform.origin.z)
	return spot_near(at, 0.6)


## A walkable place `r` from `at`, facing it.
func spot_near(at: Vector2, r: float) -> Array:
	var best: Vector2 = Vector2.INF
	for k: int in 16:
		var q: Vector2 = at + Vector2.from_angle(k * TAU / 16.0 + PI * 0.5) * r
		if nav.walkable(q):
			best = q
			if nav.idle_safe(q):
				break
	if best == Vector2.INF:
		best = nav.nearest_walkable(at, 1.5)
	return [best, WorkerActor.yaw_towards(best, at)]


## A prop now stands on the floor: people walk round it.
func placed(p: PropItem) -> void:
	if p.floor_prop and p.where != PropItem.Where.HELD:
		nav.set_extra(str(p.get_instance_id()), p.floor_rect())


func lifted(p: PropItem) -> void:
	nav.set_extra(str(p.get_instance_id()), null)


## Steps (on `duty`) that take a held prop back where it belongs.
func add_return_steps(duty: Duty, p: PropItem) -> void:
	var w: WorkerActor = duty.worker
	match p.kind:
		&"cup":
			var s: Array = area.spot("TrashSpot", "TrashBin")
			duty.use_spot("counter", s, "bin")
			duty.custom("throwing the cup away", func() -> void:
				if p.holder == w:
					w.put(p, area, Transform3D(p.global_basis, area.bin_mouth()), PropItem.Where.BINNED),
				func(st: Duty.Step, _dt: float) -> bool:
					if st.t < DutyConfig.PROP_MOVE_TIME:
						return false
					bin_cup(p)
					return true)
			duty.free_spot("counter")
		&"wrench":
			var box: PropItem = first(&"toolbox")
			var s: Array = stand_spot(box)
			duty.walk(s[0], s[1], "putting the wrench away")
			duty.put(p, box, box.global_transform * wrench_in_box(), PropItem.Where.HOME)
		_:
			var s: Array = box_spot(p) if p.kind == &"box" else (corner.stand_spot(p.kind) if corner != null else [w.pos2(), w.yaw()])
			var at_corner: bool = p.kind != &"box" and corner != null
			if at_corner:
				duty.use_spot("corner", s, "tool rack")
			else:
				duty.walk(s[0], s[1], "putting the %s back" % p.kind)
			if p.floor_prop:
				duty.custom("putting the %s down" % p.kind, func() -> void: w.hold(&"Inspect"), func(st: Duty.Step, _dt: float) -> bool:
					if st.t >= 0.7 and p.holder == w:
						w.put(p, p.home_parent, p.home_xform, PropItem.Where.HOME)
						if p.kind == &"box":
							w.set(&"_walk_anim", &"Walk")
					return st.t >= 1.3)
				duty.call_step(func() -> void: w.hold(&"Idle"))
			else:
				duty.put(p, p.home_parent, p.home_xform, PropItem.Where.HOME)
			if at_corner:
				duty.free_spot("corner")


## Urgent: put `p` down right where the worker stands; someone tidies it later.
func drop_here(w: WorkerActor, p: PropItem) -> void:
	var at: Vector2 = w.pos2() + w.right2() * 0.45
	if not nav.walkable(at):
		at = w.pos2() - w.right2() * 0.45
	var xf: Transform3D
	if p.floor_prop:
		xf = Transform3D(Basis(Vector3.UP, w.yaw()), Vector3(at.x, 0.0, at.y))
	elif p.kind == &"cup":
		xf = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5).scaled(Vector3.ONE * PropItem.HAND_SCALE), Vector3(at.x, 0.06, at.y))
	else:
		# a long tool lies flat along the worker's side
		xf = Transform3D(Basis(Vector3.UP, w.yaw()).scaled(Vector3.ONE * PropItem.HAND_SCALE), Vector3(at.x, 0.04, at.y))
	w.put(p, root, xf, PropItem.Where.LOOSE)
	if p.kind == &"box":
		w.set(&"_walk_anim", &"Walk")


func new_cup(xf: Transform3D) -> PropItem:
	var c: PropItem = make(&"cup")
	area.add_child(c)
	c.global_transform = xf
	return c


## The cup is in the bin: it stays there (out of sight).
func bin_cup(c: PropItem) -> void:
	props.erase(c)
	c.where = PropItem.Where.BINNED
	c.visible = false
	c.queue_free()
