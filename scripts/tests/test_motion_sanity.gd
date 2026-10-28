extends SceneTree
## Headless motion and traffic sanity test on main.tscn with all three
## forklifts busy at once:
## - a stored contract (P) is picked to OUTBOUND and loaded onto a pickup
##   truck at dock 2 by the Loader, while
## - an inbound contract (C1) is unloaded at dock 1 by the Unloader, and a
##   second inbound contract (C2) follows on dock 2 once the pickup leaves;
##   both are put away, picked and loaded too (full loop, every pallet
##   DELIVERED).
## Every frame, for every mover: speed, acceleration, yaw rate, turning
## radius, position jumps, pairwise distances (vehicle bodies incl. forks and
## load), overlap with walls / racks / trucks, carried pallets level and on
## the forks. People walk their duties at the same time and are checked the
## same way (speed, acceleration, separation). Carried and loaded pallets are
## checked against the rendered geometry: the pallet's mesh bottom on the
## fork blades' mesh top, a loaded pallet's bottom on the trailer bed mesh.
## Prints the worst values, then PASS or FAIL.
## Godot --headless --path . --fixed-fps 60 --script res://scripts/tests/test_motion_sanity.gd

const SPEED: int = 30
const MAX_FRAMES: int = 24000
## Design limits, checked as they are (no tolerance factors).
const VEHICLE_MAX: float = 2.0
const PERSON_MAX: float = 1.6  ## DutyConfig.WALK_SPEED.y
const ACCEL_LIMIT: float = 1.0
const MIN_RADIUS: float = 1.8
const MIN_VV: float = 2.5
const MIN_VP: float = 1.5
## People, centre to centre. The one exception: members of one
## conversation group (DutyConfig.GROUP_GAP), only to each other.
const MIN_PP: float = 0.8
const MIN_GROUP: float = 0.72
## Float noise only (sampling a path at 1/60 s steps).
const EPS: float = 0.001
## Carried / resting pallets: rendered bottom within this of the surface under it.
const CONTACT_TOL: float = 0.03

var _failures: int = 0
var _worst: Dictionary = {}
var _violations: Dictionary = {}
var _examples: Dictionary = {}
var _prev: Dictionary = {}  ## mover -> [pos2, yaw, speed]
var _gs: Node = null
var _traffic: Node = null
var _board: Node = null
var _flow: Node = null
var _trucks: Array = []
var _overlap_three: float = 0.0
var _person_dist: Dictionary = {}  ## worker -> metres walked
var _blocked_long: float = 0.0
var _blocked_long_who: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_environment("MS_SEED") != "":
		seed(int(OS.get_environment("MS_SEED")))
	_gs = root.get_node(^"GameState")
	_gs.speed = SPEED
	_gs.minutes_per_second = 1.0 / 60.0  # real-time clock: 1 game second per real second at 1x
	change_scene_to_file("res://scenes/main.tscn")
	for i: int in 4:
		await process_frame
	var manager: Node = get_first_node_in_group(&"contract_manager")
	_flow = get_first_node_in_group(&"cargo_flow")
	var grid: Node = get_first_node_in_group(&"storage_grid")
	_board = get_first_node_in_group(&"job_board")
	_traffic = get_first_node_in_group(&"traffic")
	var sim: Node = get_first_node_in_group(&"terminal_sim")
	_check(_board.forklifts().size() == 3, "three forklifts")
	# workers are put on walkable floor during the planner's setup: start
	# measuring once that is done
	var planner: Node = get_first_node_in_group(&"duty_planner")
	while planner != null and not bool(planner.get(&"ready_done")):
		await process_frame
	await process_frame

	# P: already stored in the racks, pickup due soon
	print("test_motion_sanity: free storage %d" % manager.free_capacity())
	var p: Contract = manager.make_contract(ContractCatalog.find("QuickShip"), {"pallets": 3, "storage_days": 1})
	manager.adopt(p, Contract.State.STORED)
	var racks: Array = grid.store_targets()
	for i: int in p.units.size():
		var u: CargoUnit = p.units[i]
		var s: StorageSlot = racks[i * 3]
		PalletLog.stamp(u, CargoUnit.State.IN_TRUCK, "T-Dock1-%02d" % (i + 1))
		PalletLog.stamp(u, CargoUnit.State.UNLOADING, "Forklift 1 (Unloader)", "Forklift 1 (Unloader)")
		PalletLog.stamp(u, CargoUnit.State.INBOUND, "INBOUND-%02d" % (i + 1), "Forklift 1 (Unloader)")
		PalletLog.stamp(u, CargoUnit.State.PUTAWAY, "Forklift 2 (Rack)", "Forklift 2 (Rack)")
		_flow._put(u, s, CargoUnit.State.STORED, "Forklift 2 (Rack)")
	p.state = Contract.State.STORED
	p.stored_minutes = p.storage_days * GameplayConfig.MINUTES_PER_CONTRACT_DAY  # due now
	# C1 and C2 inbound together: dock 1 now, dock 2 after the pickup
	var c1: Contract = manager.make_contract(ContractCatalog.find("ElectroLogix"), {"pallets": 4, "storage_days": 1, "inbound_delay": 2.0})
	var c2: Contract = manager.make_contract(ContractCatalog.find("GreenFields"), {"pallets": 3, "storage_days": 1, "inbound_delay": 3.0})
	for c: Contract in [c1, c2]:
		manager.add_available(c)
		var reason: String = manager.accept(c)
		_check(reason.is_empty(), "accept %s (%s)" % [c.company, reason])
	var contracts: Array[Contract] = [p, c1, c2]
	var ordered: Dictionary = {}
	var frames: int = 0
	var three_busy: int = 0
	var unload_load: int = 0
	while frames < MAX_FRAMES:
		await process_frame
		frames += 1
		# the player: send stored cargo out once the pickup is scheduled, store inbound cargo
		for c: Contract in contracts:
			if c.state == Contract.State.PICKUP_SCHEDULED and not ordered.has(c):
				ordered[c] = true
				_flow.order_outbound(c)
			for u: CargoUnit in c.units:
				if u.state == CargoUnit.State.INBOUND and not u.is_busy():
					var t: Array = grid.store_targets()
					if not t.is_empty():
						_flow.order_store(u, t[0])
		_measure(1.0 / 60.0 * float(SPEED))
		_check_trailer_loads()
		if frames % 2000 == 0:
			print("test_motion_sanity: frame %d, violations so far %s" % [frames, _violations])
			if OS.get_environment("MS_EXAMPLES") == "1":
				print("    hard stops: ", (load("res://scripts/level/worker_actor.gd") as Script).get(&"hard_stops"))
				for k: String in _examples:
					print("    %s: %s" % [k, _examples[k]])
				if frames >= int(OS.get_environment("MS_FRAMES")):
					quit(1)
		for f: Node in _board.forklifts():
			var waited: float = maxf(float(f.blocked_time), float(f.lock_wait_time))
			if waited > _blocked_long:
				_blocked_long = waited
				_blocked_long_who = f.debug_state()
		var busy: int = 0
		for f: Node in _board.forklifts():
			if f.job != null and f.speed > 0.05:
				busy += 1
		if busy == 3:
			three_busy += 1
		var d1: Dock = sim.get_dock(1)
		var d2: Dock = sim.get_dock(2)
		if (d1.state == Dock.State.UNLOADING and d2.state == Dock.State.LOADING) or (d2.state == Dock.State.UNLOADING and d1.state == Dock.State.LOADING):
			unload_load += 1
		var done: bool = true
		for c: Contract in contracts:
			if c.count_in(CargoUnit.State.DELIVERED) < c.pallets:
				done = false
		if done:
			break
	print("test_motion_sanity: %d frames (%.0f game s), 3 forklifts moving at once in %d frames, unload + load at once in %d frames" % [frames, frames / 60.0 * SPEED, three_busy, unload_load])
	for c: Contract in contracts:
		_check(c.count_in(CargoUnit.State.DELIVERED) == c.pallets, "%s: all %d pallets delivered (no deadlock)" % [c.company, c.pallets])
	_check(three_busy > 0, "all three forklifts moved at the same time")
	_check(unload_load > 0, "unloading on one dock while loading on the other")
	for f: Node in _board.forklifts():
		_check(f.job == null, "%s finished its jobs" % f.label)
		print("  state: ", f.debug_state(), " home ", f._home_pos)
	print("test_motion_sanity: worst values")
	for k: String in _worst:
		print("  %-28s %.3f" % [k, _worst[k]])
	print("test_motion_sanity: limit violations")
	for k: String in _violations:
		print("  %-28s %d  e.g. %s" % [k, _violations[k], _examples.get(k, "")])
	_check(_violations.is_empty(), "no motion or separation limit violated")
	_check(float(_worst.get("min forklift-forklift m", INF)) >= MIN_VV, "min forklift-forklift distance %.2f >= %.1f" % [_worst.get("min forklift-forklift m", INF), MIN_VV])
	_check(float(_worst.get("min forklift-person m", INF)) >= MIN_VP, "min forklift-person distance %.2f >= %.1f" % [_worst.get("min forklift-person m", INF), MIN_VP])
	_check(float(_worst.get("min person-person m", INF)) >= MIN_PP, "min person-person distance %.2f >= %.1f (outside conversation groups)" % [_worst.get("min person-person m", INF), MIN_PP])
	var walked: float = 0.0
	var walkers: int = 0
	for w: Node in _person_dist:
		walked += float(_person_dist[w])
		if float(_person_dist[w]) > 10.0:
			walkers += 1
	print("test_motion_sanity: people walked %.0f m in total, %d of them over 10 m; longest forklift wait %.0f s (%s)" % [walked, walkers, _blocked_long, _blocked_long_who])
	_check(walkers >= 3 and walked > 100.0, "people moved during the run (%d walkers, %.0f m)" % [walkers, walked])
	# safety stops are rare: well under one per 100 m walked
	var stops: float = float(_worst.get("person safety stops", 0.0))
	_check(stops <= walked / 100.0, "worker safety stops rare (%d in %.0f m walked)" % [int(stops), walked])
	_check(int(_worst.get("carried load samples", 0.0)) > 100 and int(_worst.get("loaded pallet samples", 0.0)) > 10, "load checks ran (%d carried, %d loaded samples)" % [int(_worst.get("carried load samples", 0.0)), int(_worst.get("loaded pallet samples", 0.0))])
	print("test_motion_sanity: PASS" if _failures == 0 else "test_motion_sanity: FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)


func _measure(dt: float) -> void:
	var movers: Array = _traffic.movers
	if Engine.get_process_frames() % 15 == 0:
		_trucks = _truck_boxes()
	for m: Node in movers:
		var body: Node3D = m.get(&"body") if m.get(&"body") != null else m as Node3D
		var pos: Vector2 = Vector2(body.global_position.x, body.global_position.z)
		var yaw: float = body.global_rotation.y
		var vehicle: bool = int(m.call(&"traffic_kind")) == 0
		var vmax: float = VEHICLE_MAX if vehicle else PERSON_MAX
		var name: String = m.get(&"label") if m.get(&"label") != null else String(m.name)
		if m.has_method(&"debug_state"):
			name = m.call(&"debug_state")
		var odo: float = float(m.get(&"odometer")) if m.get(&"odometer") != null else 0.0
		if _prev.has(m):
			var pv: Array = _prev[m]
			var ds: float = pos.distance_to(pv[0])
			# speed along the way travelled (odometer), not the chord: on arcs
			# and turns the chord is shorter
			var driven: float = odo - float(pv[3]) if m.get(&"odometer") != null else ds
			var v: float = driven / dt
			var dyaw: float = absf(angle_difference(pv[1], yaw))
			_max("max speed " + ("vehicle" if vehicle else "person"), v)
			_limit("speed", v > vmax + EPS, "%s %.3f m/s" % [name, v])
			_limit("position jump", ds > vmax * dt + EPS, "%s %.3f m" % [name, ds])
			var a: float = absf(v - float(pv[2])) / dt if not is_nan(float(pv[2])) else 0.0
			# a worker's safety stop (someone stepped into its way): the one
			# case it brakes harder than accel; counted, and exempt for the
			# two frames it spans
			var stops: int = int(m.get(&"safety_stops")) if not vehicle and m.get(&"safety_stops") != null else 0
			if not vehicle and (stops != int(pv[4]) or int(pv[5]) > 0):
				_worst["person safety stops"] = float(_worst.get("person safety stops", 0.0)) + float(stops - int(pv[4]))
				pv[5] = 1 if stops != int(pv[4]) else 0
				pv[4] = stops
				a = 0.0
			_max("max accel " + ("vehicle" if vehicle else "person"), a)
			var extra: String = "" if vehicle else " mode %s speed %.2f duty %s motor %s" % [m.get(&"_mode"), float(m.get(&"speed")), m.get(&"duty").get(&"title") if m.get(&"duty") != null else "-", m.get(&"motor")]
			_limit("acceleration " + ("vehicle" if vehicle else "person"), a > ACCEL_LIMIT + EPS, "%s %.3f m/s2 (%.3f -> %.3f m/s)%s" % [name, a, float(pv[2]), v, extra])
			if not vehicle:
				_person_dist[m] = float(_person_dist.get(m, 0.0)) + ds
			if vehicle:
				_max("max yaw rate rad/s", dyaw / dt)
				_limit("rotating in place", dyaw > 0.01 and driven < 0.002, "%s turned %.3f rad without moving" % [name, dyaw])
				if dyaw > 0.004 and driven > 0.002:
					var r: float = driven / dyaw
					_min("min turning radius m", r)
					_limit("turning radius", r < MIN_RADIUS - EPS, "%s r %.3f m" % [name, r])
				var body_box: Array = m.call(&"body_boxes_at", pos, yaw)
				var hit: int = _traffic.static_hit(body_box, -0.03)
				_limit("inside wall/rack/obstacle", hit >= 0, "%s in %s" % [name, _traffic.static_names[hit] if hit >= 0 else ""])
				for tb: Array in _trucks:
					if m.get(&"bay") != null and tb[1] == m.get(&"bay"):
						continue  # its own trailer (and the cab coupled under its nose)
					var in_truck: bool = FootprintBox.set_overlaps(body_box, [tb[0]], -0.03)
					_limit("inside a truck", in_truck, "%s" % name)
				_check_load(m, name)
				_check_clearance(m, name, body)
			pv[1] = yaw
			pv[0] = pos
			pv[2] = v
			pv[3] = odo
		else:
			_prev[m] = [pos, yaw, NAN, odo, int(m.get(&"safety_stops")) if m.get(&"safety_stops") != null else 0, 0]  # no speed yet: the first step only sets it
	# separation
	for i: int in movers.size():
		for j: int in range(i + 1, movers.size()):
			var a: Node = movers[i]
			var b: Node = movers[j]
			var ka: int = a.call(&"traffic_kind")
			var kb: int = b.call(&"traffic_kind")
			if ka == 1 and kb == 1:
				# people: centre to centre; one conversation group may stand closer
				# the jack worker is a CarryAgent (a Node): its body is the 3D one
				var pa: Node3D = _body_of(a)
				var pb: Node3D = _body_of(b)
				var dc: float = Vector2(pa.global_position.x - pb.global_position.x, pa.global_position.z - pb.global_position.z).length()
				var grouped: bool = a.get(&"group") != null and a.get(&"group") == b.get(&"group")
				if grouped:
					_min("min person-person in a group m", dc)
					_limit("people in a group < 0.72 m", dc < MIN_GROUP - EPS, "%s / %s %.2f m" % [a.name, b.name, dc])
				else:
					_min("min person-person m", dc)
					_limit("person-person < 0.8 m", dc < MIN_PP, "%s (%s, %s, seat %s) / %s (%s, %s, seat %s) %.2f m" % [a.name, a.call(&"activity_text"), a.get(&"duty").get(&"title") if a.get(&"duty") != null else "-", a.get(&"seat"), b.name, b.call(&"activity_text"), b.get(&"duty").get(&"title") if b.get(&"duty") != null else "-", b.get(&"seat"), dc])
				continue
			var d: float = FootprintBox.set_distance(a.call(&"traffic_footprints"), b.call(&"traffic_footprints"))
			if ka == 0 and kb == 0:
				_min("min forklift-forklift m", d)
				_limit("forklift-forklift < 2.5 m", d < MIN_VV, "%s / %s %.2f m" % [a.debug_state(), b.debug_state(), d])
			else:
				var lift: Node = a if ka == 0 else b
				var person: Node = b if ka == 0 else a
				if _servicing(lift, person):
					continue  # the one exception: a worker servicing a parked, held forklift
				if d < MIN_VP and d < float(_worst.get("min forklift-person m", INF)) - 0.05:
					print("MS_FP frame %d d %.2f | %s | person %s (%s) pos (%.2f, %.2f) speed %s blocked_by %s" % [Engine.get_process_frames(), d, lift.debug_state(), person.name, (person.call(&"activity_text") if person.has_method(&"activity_text") else "-"), _body_of(person).global_position.x, _body_of(person).global_position.z, person.get(&"speed"), person.get(&"blocked_by")])
				_min("min forklift-person m", d)
				_limit("forklift-person < 1.5 m", d < MIN_VP, "%s / %s (%s) %.2f m" % [lift.debug_state(), person.name, (person.call(&"activity_text") if person.has_method(&"activity_text") else "-"), d])


## On the ramp, in the doorway or in a trailer: the forklift's top (overhead
## guard, mast and load) stays 0.1 m under the dock opening header and the
## trailer roof, and its body inside the trailer's inner width.
func _check_clearance(f: Node, name: String, body: Node3D) -> void:
	var top: float = _top_y(f, body)
	var p3: Vector3 = body.global_position
	for bay: Node in _flow.bays.values():
		var s: float = bay.along(p3)
		if s < -1.6 or absf(bay.across(p3)) > 2.0:
			continue
		var header: float = _header_y(bay)
		var door_s: float = bay.along(bay.door.global_position)
		if absf(s - door_s) < 1.8:
			_min("min header clearance m", header - top)
			_limit("forklift above header", top > header - 0.1, "%s top %.2f header %.2f" % [name, top, header])
		if bay.has_truck() and bay.in_trailer(p3):
			var entry: Transform3D = bay.rear_entry()
			var roof: float = entry.origin.y + 2.6
			_min("min trailer roof clearance m", roof - top)
			_limit("forklift above trailer roof", top > roof - 0.1, "%s top %.2f roof %.2f" % [name, top, roof])
			var centre: float = bay.across(entry.origin)
			var widest: float = 0.0
			for b: FootprintBox in f.call(&"body_boxes_at", Vector2(p3.x, p3.z), body.global_rotation.y):
				for c: Vector2 in b.corners():
					widest = maxf(widest, absf(bay.across(Vector3(c.x, 0.0, c.y)) - centre))
			_min("min trailer wall clearance m", 1.215 - widest)
			_limit("forklift outside trailer width", widest > 1.215, "%s %.2f m from the centre line" % [name, widest])


var _headers: Dictionary = {}
var _verts: Dictionary = {}  ## forklift -> PackedVector3Array of its high vertices (body space)


## Highest point of the forklift (overhead guard, mast) from its mesh
## vertices, and of the pallet it carries.
func _top_y(f: Node, body: Node3D) -> float:
	if not _verts.has(f):
		var pts: PackedVector3Array = PackedVector3Array()
		var inv: Transform3D = body.global_transform.affine_inverse()
		for mi: Node in body.find_children("*", "MeshInstance3D", true, false):
			if (mi as Node3D).get_parent() is CargoPallet or mi.get_parent().get_parent() is CargoPallet:
				continue
			var m: MeshInstance3D = mi as MeshInstance3D
			var local: Transform3D = inv * m.global_transform
			for si: int in m.mesh.get_surface_count():
				var arr: Array = m.mesh.surface_get_arrays(si)
				for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
					var q: Vector3 = local * v
					if q.y > 1.6:
						pts.append(q)
		_verts[f] = pts
	var top: float = -INF
	var xf: Transform3D = body.global_transform
	for q: Vector3 in _verts[f]:
		top = maxf(top, (xf * q).y)
	var job: Variant = f.get(&"job")
	if job != null and (job as CarryJob).unit.node != null and (job as CarryJob).unit.is_carried():
		top = maxf(top, (_traffic.call(&"_mesh_aabb", (job as CarryJob).unit.node) as AABB).end.y)
	return top


## Underside of the dock opening: the lowest point of the door frame's header.
func _header_y(bay: Node) -> float:
	if _headers.has(bay):
		return _headers[bay]
	var y: float = INF
	var top: Node = bay.door.find_child("DockDoorTop", true, false)
	if top != null:
		for cs: Node in top.find_children("*", "CollisionShape3D", true, false):
			var shape: Shape3D = (cs as CollisionShape3D).shape
			if shape is ConcavePolygonShape3D:
				var xf: Transform3D = (cs as CollisionShape3D).global_transform
				for v: Vector3 in (shape as ConcavePolygonShape3D).get_faces():
					y = minf(y, (xf * v).y)
	_headers[bay] = y
	return y


## A worker servicing this forklift (walking up to it, kneeling beside it,
## packing up) while it stands parked with no job: next to it by design.
## The JobBoard holds it while the worker kneels there, so it cannot move.
func _servicing(lift: Node, person: Node) -> bool:
	return person.get(&"service_vehicle") == lift and lift.get(&"job") == null and float(lift.get(&"speed")) < 0.001


## The carried pallet in world terms, from the rendered meshes: the fork
## blades' top (highest vertex of the Forks mesh ahead of the carriage) lies
## inside the pallet's base, above its bottom boards and below its deck top
## (the wooden pallet surface of the model), so the forks are in the pockets
## carrying it; its centre is over the blades and it is level with them.
## Independent of the hold transform the carrier uses.
func _check_load(f: Node, name: String) -> void:
	var job: Variant = f.get(&"job")
	if job == null:
		return
	var u: CargoUnit = (job as CarryJob).unit
	if not u.is_carried() or u.node == null or float(f.get(&"speed")) < 0.05:
		return  # handing over (forks moving at the slot) is fine
	var forks: Node3D = f.body.find_child("Forks", true, false) as Node3D
	if forks == null or not forks.is_ancestor_of(u.node):
		_limit("pallet not on the forks", true, "%s %s" % [name, u.code])
		return
	var blades: Array = _blade_top(forks)  # [top y, min z, max z, half width] in Forks space
	var base: Array = _pallet_base(u.node)
	var bottom: Vector3 = forks.global_transform.affine_inverse() * (u.node.global_transform * Vector3(0.0, float(base[0]), 0.0))
	var deck: float = float(base[1]) - float(base[0])
	var in_base: float = float(blades[0]) - bottom.y  # blade top above the pallet bottom
	_max("max blade top above pallet bottom m", in_base)
	_min("min blade top above pallet bottom m", in_base)
	_worst["carried load samples"] = float(_worst.get("carried load samples", 0.0)) + 1.0
	_limit("forks not in the pallet's pockets", in_base < 0.01 or in_base > deck, "%s %s blade top %.3f m above the pallet bottom (deck %.3f)" % [name, u.code, in_base, deck])
	var over: bool = absf(bottom.x) < float(blades[3]) and bottom.z > float(blades[1]) and bottom.z < float(blades[2])
	_limit("load centre not over the blades", not over, "%s %s at %s" % [name, u.code, bottom])
	var up: float = (u.node.global_basis.orthonormalized() * Vector3.UP).dot(forks.global_basis.orthonormalized() * Vector3.UP)
	_limit("load not level on the forks", up < 0.999, "%s %s up %.4f" % [name, u.code, up])


var _blade_cache: Dictionary = {}
var _bottom_cache: Dictionary = {}
var _bed_cache: Dictionary = {}  ## trailer node -> PackedVector3Array of triangles (trailer space)


## Fork blade top in Forks space from the meshes: the highest vertex of the
## part ahead of the carriage (z < -0.3).
func _blade_top(forks: Node3D) -> Array:
	if _blade_cache.has(forks):
		return _blade_cache[forks]
	var top: float = -INF
	var zmin: float = INF
	var zmax: float = -INF
	var half: float = 0.0
	var inv: Transform3D = forks.global_transform.affine_inverse()
	var meshes: Array = forks.find_children("*", "MeshInstance3D", true, false)
	if forks is MeshInstance3D:
		meshes.append(forks)
	for n: Node in meshes:
		if n.get_parent() is CargoPallet or n.find_parent("Cargo_*") != null:
			continue
		var mi: MeshInstance3D = n as MeshInstance3D
		var local: Transform3D = inv * mi.global_transform
		for si: int in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				var q: Vector3 = local * v
				if q.z < -0.3:
					top = maxf(top, q.y)
					zmin = minf(zmin, q.z)
					zmax = maxf(zmax, q.z)
					half = maxf(half, absf(q.x))
	_blade_cache[forks] = [top, zmin, maxf(zmax, -0.3) + 0.3, half]
	return _blade_cache[forks]


## Lowest vertex of the pallet model, in pallet space.
func _pallet_bottom(node: Node3D) -> float:
	return float(_pallet_base(node)[0])


## [bottom, deck top] of the pallet model in pallet space: the lowest vertex,
## and the top of the wooden pallet (the surfaces that stay below 0.25 m;
## the boxes on it reach higher).
func _pallet_base(node: Node3D) -> Array:
	if _bottom_cache.has(node):
		return _bottom_cache[node]
	var low: float = INF
	var deck: float = -INF
	var inv: Transform3D = node.global_transform.affine_inverse()
	var model: Node = node.get_child(0)
	var ranges: Array[Vector2] = []
	for n: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = n as MeshInstance3D
		var local: Transform3D = inv * mi.global_transform
		for si: int in mi.mesh.get_surface_count():
			var r: Vector2 = Vector2(INF, -INF)
			for v: Vector3 in mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				var y: float = (local * v).y
				r = Vector2(minf(r.x, y), maxf(r.y, y))
			ranges.append(r)
			low = minf(low, r.x)
	for r: Vector2 in ranges:
		if r.y < low + 0.25:
			deck = maxf(deck, r.y)
	if is_inf(deck):
		deck = low + 0.15
	_bottom_cache[node] = [low, deck]
	return _bottom_cache[node]


## Pallets on a trailer (loaded, or arriving in the truck): their rendered
## bottom rests on the trailer bed, found by casting down onto the trailer's
## own mesh triangles under the pallet centre.
func _check_trailer_loads() -> void:
	if Engine.get_process_frames() % 10 != 0:
		return
	for bay: Node in _flow.bays.values():
		var rig: Node3D = bay.call(&"find_rig")
		if rig == null or rig.get(&"trailer") == null:
			continue
		var trailer: Node3D = rig.get(&"trailer")
		for sl: StorageSlot in bay.get(&"slots"):
			var u: CargoUnit = sl.unit
			if u == null or u.node == null or not trailer.is_ancestor_of(u.node):
				continue
			var bottom: Vector3 = u.node.global_transform * Vector3(0.0, _pallet_bottom(u.node), 0.0)
			var bed: float = _bed_height(trailer, bottom)
			if is_inf(bed):
				_limit("no trailer bed under a loaded pallet", true, "%s at %s" % [u.code, bottom])
				continue
			_max("max |pallet bottom - trailer bed| m", absf(bottom.y - bed))
			_worst["loaded pallet samples"] = float(_worst.get("loaded pallet samples", 0.0)) + 1.0
			_limit("loaded pallet not on the trailer bed", absf(bottom.y - bed) > CONTACT_TOL, "%s bottom %.3f bed %.3f" % [u.code, bottom.y, bed])


## World height of the highest trailer surface under p (at most 0.3 m
## above it), or -INF.
func _bed_height(trailer: Node3D, p: Vector3) -> float:
	if not _bed_cache.has(trailer):
		var tris: PackedVector3Array = PackedVector3Array()
		var inv: Transform3D = trailer.global_transform.affine_inverse()
		for n: Node in trailer.find_children("*", "MeshInstance3D", true, false):
			if n.find_parent("Cargo_*") != null:
				continue
			var mi: MeshInstance3D = n as MeshInstance3D
			var local: Transform3D = inv * mi.global_transform
			for v: Vector3 in mi.mesh.get_faces():
				tris.append(local * v)
		_bed_cache[trailer] = tris
	var t: PackedVector3Array = _bed_cache[trailer]
	var xf: Transform3D = trailer.global_transform
	var inv2: Transform3D = xf.affine_inverse()
	var from: Vector3 = inv2 * (p + Vector3.UP * 0.3)
	var dir: Vector3 = (inv2.basis * Vector3.DOWN).normalized()
	var best: float = -INF
	for i: int in range(0, t.size(), 3):
		var hit: Variant = Geometry3D.ray_intersects_triangle(from, dir, t[i], t[i + 1], t[i + 2])
		if hit != null:
			best = maxf(best, (xf * (hit as Vector3)).y)
	return best


func _truck_boxes() -> Array:
	var out: Array = []
	var bays: Dictionary = _flow.bays
	for bay: Node in bays.values():
		var rig: Node3D = bay.call(&"find_rig")
		if rig == null:
			continue
		for part: Variant in [rig.get(&"cab"), rig.get(&"trailer")]:
			if part == null:
				continue
			var box: AABB = _traffic.call(&"_mesh_aabb", part)
			var r: Rect2 = Rect2(box.position.x, box.position.z, box.size.x, box.size.z)
			# the trailer only counts against agents that do not hold its lane
			out.append([FootprintBox.from_rect(r), bay])
	return out


func _max(k: String, v: float) -> void:
	_worst[k] = maxf(float(_worst.get(k, -INF)), v)


func _min(k: String, v: float) -> void:
	_worst[k] = minf(float(_worst.get(k, INF)), v)


func _limit(k: String, bad: bool, example: String) -> void:
	if not bad:
		return
	_violations[k] = int(_violations.get(k, 0)) + 1
	if not _examples.has(k):
		_examples[k] = "%s (frame %d)" % [example, Engine.get_process_frames()]
	elif OS.get_environment("MS_EXAMPLES") == "1" and _violations[k] <= 4:
		_examples[k] += "\n        %s (frame %d)" % [example, Engine.get_process_frames()]


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


## The 3D node a mover walks with: a worker itself, the jack worker's
## (a CarryAgent, a plain Node) body.
static func _body_of(m: Node) -> Node3D:
	return m as Node3D if m is Node3D else m.get(&"body") as Node3D
