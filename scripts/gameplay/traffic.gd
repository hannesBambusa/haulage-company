class_name Traffic
extends Node
## Shared floor model for everything that moves in the hall: static obstacles
## (walls, racks, dock frames, loose decor, from the level's colliders and
## meshes), the movers (forklifts, workers with or without a pallet jack,
## scenery workers), region locks (one forklift at a time in front of the
## INBOUND zone, the OUTBOUND zone and each rack aisle; the dock lanes lock
## through TrailerBay; an agent waits for a lock where it is, before setting
## off, and frees it a few metres after leaving), drivable path planning for vehicles (a
## grid A* route around obstacles, smoothed into Dubins arcs + straights,
## with a reversing manoeuvre first when needed) and the yield / deadlock
## rules:
## - a mover slows and stops when its own path ahead would bring it within
##   the yield distance of another mover (SAFE_*), and never closes in below
##   the hard minimum (HARD_*: 2.5 m vehicle-vehicle, 1.5 m vehicle-person,
##   1.0 m person-person, plus a small margin), unless that move takes it away;
## - when two movers have waited on each other for DEADLOCK_TIME, the lower
##   priority one backs off (loaded > empty, lock holder first, then lower id;
##   people and idle vehicles always give way);
## - an agent waiting for a lock whose holder is idle or stuck makes the
##   holder leave the area (idle: drive to its parking spot), or waits at its
##   own parking spot when it stands in the holder's way. Nobody waits inside
##   a zone front, a dock lane, a rack aisle or a slot approach (in_keep_clear).

enum Kind { VEHICLE, PERSON }

## Yield distances: a mover stops before its path comes this close (edge to edge).
const SAFE_VV: float = 3.0
const SAFE_VP: float = 1.9
const SAFE_PP: float = 0.45
## Hard minimums: never closer, also for the agent with the right of way.
## The design limits are 2.5 / 1.5 m (people: 0.8 m centre to centre,
## about 0.25 m between shoulders, so two can walk past each other); the
## margin covers one check interval of motion.
const HARD_VV: float = 2.6
const HARD_VP: float = 1.6
const HARD_PP: float = 0.3
const DEADLOCK_TIME: float = 3.0
## Edge-to-edge gap between forklifts in the parking area (bays side by
## side); the hard minimum there is 0.2 m less.
const PARK_VV: float = 0.7
## Parked forklifts keep at least this far off the keep-clear areas.
const PARKING_MARGIN: float = 0.5
## Floor in front of a dock lane kept clear (stage point plus lining up).
const APRON_LENGTH: float = 6.0
const COOLDOWN_KEYS: Array[StringName] = [&"give_way_cooldown", &"reroute_cooldown"]
## A working agent that has not got anywhere for this long gets the right of
## way: the others clear its path, and it may pass at the hard minimum.
const STUCK_TOKEN_TIME: float = 15.0
## Idle or lock-waiting movers that block a working one this long move aside.
const IDLE_BLOCK_TIME: float = 1.5
## People with nothing to do (idle or on a duty) this close to the next
## MAKE_WAY_LOOK metres of a working forklift's or jack's leg move off at
## once, before it has to stop for them. Checked every MAKE_WAY_INTERVAL s.
const MAKE_WAY_LOOK: float = 8.0
const MAKE_WAY_MARGIN: float = 0.3
const MAKE_WAY_INTERVAL: float = 0.25
const STATIC_CLEARANCE: float = 0.12
const PALLET_CLEARANCE: float = 0.04
const CELL: float = 4.0
const SAMPLE_STRIDE: int = 4  ## path samples between checks (0.2 m)
## Route grid: cell size, extent and how far obstacles are grown.
const GRID_CELL: float = 0.5
const GRID_MIN: Vector2 = Vector2(-27.0, -29.0)
const GRID_SIZE: Vector2i = Vector2i(104, 64)
const GRID_GROW: float = 0.95

@export var level_path: NodePath
@export var storage_grid_path: NodePath
@export var job_board_path: NodePath
## The hall floor (inside the walls), as rects on the floor plane: parking
## and waiting spots must lie inside.
@export var hall_rects: Array[Rect2] = [Rect2(-24.0, -26.0, 30.9, 26.0), Rect2(6.9, -26.0, 15.1, 12.0), Rect2(6.9, -14.0, 12.1, 7.6)]

var grid: StorageGrid = null
var board: JobBoard = null
## JobBoard.parking_area (static: the distance helpers are static).
static var parking_area: Rect2 = Rect2()
## Static obstacles on the floor plane.
var statics: Array[Rect2] = []
var static_names: PackedStringArray = PackedStringArray()
## Movers: CarryAgents plus scenery WorkerActors.
var movers: Array[Node] = []

var _cells: Dictionary = {}  ## Vector2i -> PackedInt32Array of static indices
var _locks: Dictionary = {}  ## String -> ZoneLock
var _level: Node3D = null
var _blocked: PackedByteArray = PackedByteArray()  ## static route grid
## The agent that currently has the right of way (livelock breaker), or null.
var token_holder: Node = null
var _token_from: Vector2 = Vector2.ZERO
var _token_time: float = 0.0
var _zone_cache: Array[FootprintBox] = []
var _lane_cache: Array[FootprintBox] = []
## Game seconds since start (for rate-limited logs).
var _clock: float = 0.0
var _make_way_t: float = 0.0
## Startup checks plan on the empty hall.
var _ignore_movers: bool = false
## Every lock's region (zones, rack aisles, floor storage), built at startup.
var _keep_clear: Array[FootprintBox] = []
## The dock lane aprons alone (also in _keep_clear).
var _aprons: Array[FootprintBox] = []


class ZoneLock:
	extends RefCounted
	signal freed
	var key: String = ""
	var holder: Object = null
	## Floor the holder works on (zone or rack face plus its approach area):
	## others plan around it while it is held.
	var region: Rect2 = Rect2()
	var box: FootprintBox = null

	func try_acquire(who: Object) -> bool:
		if holder == null or holder == who:
			holder = who
			return true
		return false

	func release(who: Object) -> void:
		if holder == who:
			holder = null
			freed.emit()


func _ready() -> void:
	add_to_group(&"traffic")
	grid = get_node_or_null(storage_grid_path) as StorageGrid
	board = get_node_or_null(job_board_path) as JobBoard
	parking_area = board.parking_area if board != null else Rect2()
	_level = get_node_or_null(level_path) as Node3D
	if grid == null or _level == null:
		push_error("Traffic: storage_grid_path or level_path not set")
		return
	_collect.call_deferred()


func _collect() -> void:
	_collect_statics()
	movers.clear()
	if board != null:
		for a: CarryAgent in board.agents:
			movers.append(a)
			a.traffic = self
	for n: Node in _level.find_children("*", "Node3D", true, false):
		var w: WorkerActor = n as WorkerActor
		if w == null:
			continue
		w.traffic = self
		if w.mover == w or w.mover == null:
			movers.append(w)
	_mark_reachable()
	_build_keep_clear()
	_mark_drivable()
	_build_access()
	_choose_wait_spots()
	_choose_parking()
	print("Traffic: %d static obstacles, %d movers" % [statics.size(), movers.size()])


# --- statics ---------------------------------------------------------------------

func _collect_statics() -> void:
	statics.clear()
	static_names.clear()
	for node: Node in _level.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = node as CollisionShape3D
		var body: Node = cs.get_parent()
		if body == null or not (body is CollisionObject3D):
			continue
		if (body as CollisionObject3D).collision_layer == 1 << 15:
			continue  # the camera's picking proxies, not real obstacles
		var bn: String = String(body.name)
		if bn.begins_with("Leveler") or bn.begins_with("Fence") or not (cs as Node3D).is_visible_in_tree():
			continue
		if _under_dynamic(cs):
			continue
		var faces: PackedVector3Array = PackedVector3Array()
		if cs.shape is ConcavePolygonShape3D:
			faces = (cs.shape as ConcavePolygonShape3D).get_faces()
		elif cs.shape is BoxShape3D:
			var e: Vector3 = (cs.shape as BoxShape3D).size * 0.5
			faces = PackedVector3Array([-e, e])
		if faces.is_empty():
			continue
		var xf: Transform3D = cs.global_transform
		var box: AABB = AABB(xf * faces[0], Vector3.ZERO)
		for f: Vector3 in faces:
			box = box.expand(xf * f)
		_add_static(box, bn)
	# parked trucks placed in the level (not the ones the drivers bring in)
	for n: Node in _level.find_children("*", "Node3D", true, false):
		var rig: TruckRig = n as TruckRig
		if rig == null or rig.get_parent().has_signal(&"truck_spawned") or not rig.is_visible_in_tree():
			continue
		for part: Node3D in [rig.cab, rig.trailer]:
			if part != null:
				_add_static(_mesh_aabb(part), String(rig.name))
	# the building's walls (wall segments and corners have no colliders)
	for n: Node in _level.find_children("*", "Node3D", true, false):
		var w: Node3D = n as Node3D
		var file: String = w.scene_file_path.get_file()
		if (file.begins_with("wall_segment") or file.begins_with("wall_corner")) and w.is_visible_in_tree():
			var wb: AABB = _mesh_aabb(w)
			if wb.size != Vector3.ZERO:
				_add_static(wb, "wall " + String(w.name))
	# loose decor without colliders (empty pallet stacks, single boxes)
	for d: Node3D in grid.decor_nodes():
		if not d.is_visible_in_tree() or d.find_children("*", "CollisionShape3D", true, false).size() > 0:
			continue
		var box: AABB = _mesh_aabb(d)
		if box.size != Vector3.ZERO:
			_add_static(box, String(d.name))
	_build_grid()
	_cells.clear()
	for i: int in statics.size():
		var r: Rect2 = statics[i]
		for cx: int in range(floori(r.position.x / CELL), floori(r.end.x / CELL) + 1):
			for cz: int in range(floori(r.position.y / CELL), floori(r.end.y / CELL) + 1):
				var k: Vector2i = Vector2i(cx, cz)
				if not _cells.has(k):
					_cells[k] = PackedInt32Array()
				var arr: PackedInt32Array = _cells[k]
				arr.append(i)
				_cells[k] = arr


func _add_static(box: AABB, label: String) -> void:
	if box.position.y > 2.6 or box.end.y < 0.05:
		return
	statics.append(Rect2(box.position.x, box.position.z, box.size.x, box.size.z))
	static_names.append(label)


func _under_dynamic(n: Node) -> bool:
	var p: Node = n.get_parent()
	while p != null and p != _level:
		if p is CargoPallet or p is TruckRig or p.has_meta(&"rack_stock"):
			return true
		p = p.get_parent()
	return false


static func _mesh_aabb(root: Node3D) -> AABB:
	var box: AABB = AABB()
	var first: bool = true
	for m: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m as MeshInstance3D
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func statics_near(r: Rect2) -> PackedInt32Array:
	var seen: Dictionary = {}
	var out: PackedInt32Array = PackedInt32Array()
	for cx: int in range(floori(r.position.x / CELL), floori(r.end.x / CELL) + 1):
		for cz: int in range(floori(r.position.y / CELL), floori(r.end.y / CELL) + 1):
			var arr: Variant = _cells.get(Vector2i(cx, cz))
			if arr == null:
				continue
			for i: int in arr:
				if not seen.has(i):
					seen[i] = true
					out.append(i)
	return out


## Static obstacle the boxes overlap, or -1. `skip` rects (e.g. the target
## rack) are ignored.
func static_hit(boxes: Array, clearance: float, skip: Array = []) -> int:
	var bounds: Rect2 = Rect2()
	var first: bool = true
	for b: FootprintBox in boxes:
		bounds = b.bounds() if first else bounds.merge(b.bounds())
		first = false
	for i: int in statics_near(bounds.grow(clearance)):
		var r: Rect2 = statics[i]
		if r in skip:
			continue
		var ob: FootprintBox = FootprintBox.from_rect(r)
		for b: FootprintBox in boxes:
			if b.overlaps(ob, clearance):
				return i
	return -1


## Static rect containing the slot (its rack), for exemptions.
func rack_rect_for(slot: StorageSlot) -> Array:
	var out: Array = []
	if slot == null or slot.zone != StorageSlot.Zone.RACK:
		return out
	var p: Vector2 = Vector2(slot.position.x, slot.position.z)
	for i: int in statics_near(Rect2(p, Vector2.ZERO).grow(0.5)):
		if statics[i].grow(0.05).has_point(p):
			out.append(statics[i])
	return out


# --- slots: locks and approach geometry --------------------------------------------

func lock_for(slot: StorageSlot) -> ZoneLock:
	if slot == null or slot.is_trailer():
		return null
	var key: String = ""
	match slot.zone:
		StorageSlot.Zone.INBOUND:
			key = "INBOUND"
		StorageSlot.Zone.OUTBOUND:
			key = "OUTBOUND"
		StorageSlot.Zone.FLOOR:
			key = "FLOOR"
		_:
			# one forklift per rack aisle (all bays sharing a face line)
			var across: float = slot.position.dot(slot.out_dir)
			key = "RACK %s %.0f" % [str(slot.out_dir.snapped(Vector3.ONE)), snappedf(across, 1.0)]
	if not _locks.has(key):
		var l: ZoneLock = ZoneLock.new()
		l.key = key
		l.region = _lock_region(slot)
		l.box = FootprintBox.from_rect(l.region)
		_locks[key] = l
	return _locks[key]


## The zone's pallets, or the rack face line's racks, grown out by the
## approach and back-out room along the slots' open side.
func _lock_region(slot: StorageSlot) -> Rect2:
	var r: Rect2 = Rect2()
	var first: bool = true
	var key_slots: Array[StorageSlot] = []
	for sl: StorageSlot in grid.slots:
		if sl.zone != slot.zone:
			continue
		if sl.zone == StorageSlot.Zone.RACK and (not sl.out_dir.is_equal_approx(slot.out_dir) or absf(sl.position.dot(sl.out_dir) - slot.position.dot(slot.out_dir)) > 0.6):
			continue
		key_slots.append(sl)
	for sl: StorageSlot in key_slots:
		var pr: Rect2 = Rect2(sl.position.x - 0.6, sl.position.z - 0.6, 1.2, 1.2)
		r = pr if first else r.merge(pr)
		first = false
	var od: Vector2 = Vector2(slot.out_dir.x, slot.out_dir.z)
	var grow: float = 4.5
	return r.grow_individual(maxf(-od.x, 0.0) * grow + 0.3, maxf(-od.y, 0.0) * grow + 0.3, maxf(od.x, 0.0) * grow + 0.3, maxf(od.y, 0.0) * grow + 0.3)


## Regions of the locks other agents hold.
func _foreign_regions(agent: Object) -> Array[FootprintBox]:
	var out: Array[FootprintBox] = []
	for l: ZoneLock in _locks.values():
		# rack aisles only: the zones' fronts are the main corridor, where
		# yielding sorts out who goes first
		if not l.key.begins_with("RACK"):
			continue
		if l.holder != null and l.holder != agent and l.region.has_area():
			out.append(FootprintBox.from_rect(l.region))
	return out


## Length of the straight, square-on final approach to a grid slot: at least
## 2 m, and long enough to start clear of the zone's other pallets.
func approach_length(slot: StorageSlot, reach: float) -> float:
	var length: float = 2.0
	if slot.zone == StorageSlot.Zone.INBOUND or slot.zone == StorageSlot.Zone.OUTBOUND or slot.zone == StorageSlot.Zone.FLOOR:
		var front: float = -INF
		for s: StorageSlot in grid.slots:
			if s.zone == slot.zone:
				front = maxf(front, s.position.dot(slot.out_dir))
		var approach: float = slot.position.dot(slot.out_dir) + reach
		# origin far enough out that the forks (1.6 m ahead) clear the front row
		length = maxf(length, front + 0.6 + 1.75 - approach)
	return length


## Vehicle pose where the final straight starts: (position, yaw facing the slot).
func staging_pose(slot: StorageSlot, reach: float) -> Array:
	var approach: Vector3 = grid.approach_point(slot, reach)
	var p: Vector3 = approach + slot.out_dir * approach_length(slot, reach)
	var face: Vector3 = -slot.out_dir
	return [Vector2(p.x, p.z), atan2(-face.x, -face.z)]


## Marks storage slots a forklift cannot drive square onto (no room for the
## straight approach) as unreachable, so nobody stores there.
func _mark_reachable() -> void:
	var lift: CarryAgent = null
	if board != null:
		for a: CarryAgent in board.agents:
			if a is ForkliftCarrier:
				lift = a
				break
	if lift == null:
		return
	var bad: int = 0
	for s: StorageSlot in grid.slots:
		if s.house_stock:
			continue
		var reach: float = lift.reach_for(s)
		var pose: Array = staging_pose(s, reach)
		var approach: Vector3 = grid.approach_point(s, reach)
		var skip: Array = rack_rect_for(s)
		var ok: bool = true
		var a2: Vector2 = Vector2(approach.x, approach.z)
		var st: Vector2 = pose[0]
		for i: int in 9:
			var p: Vector2 = st.lerp(a2, i / 8.0)
			# body only: the forks and load go into the rack
			if static_hit(lift.body_boxes_at(p, pose[1]), 0.05, skip) >= 0:
				ok = false
				break
		if ok and static_hit(lift.footprints_at(st, pose[1], true), STATIC_CLEARANCE) >= 0:
			ok = false
		if ok and not s.is_storage():
			# zone slots: the whole straight with forks and load must clear statics
			for i: int in 9:
				if static_hit(lift.footprints_at(st.lerp(a2, i / 8.0), pose[1]), 0.05) >= 0:
					ok = false
					break
		s.reachable = ok
		if not ok:
			bad += 1
	if bad > 0:
		print("Traffic: %d storage slots have no room for a square forklift approach" % bad)
		grid.slots_changed.emit()


## A queue spot per dock lane: behind the ramp, beside the lane, clear of
## walls, decor, the zones and the lanes. Prefers the side away from INBOUND.
func _choose_wait_spots() -> void:
	var lift: CarryAgent = null
	for a: CarryAgent in board.agents:
		if a is ForkliftCarrier:
			lift = a
			break
	if lift == null:
		return
	var zones: Array[FootprintBox] = [FootprintBox.from_rect(grid.inbound_rect.grow(0.4)), FootprintBox.from_rect(grid.outbound_rect.grow(0.4))]
	for b: TrailerBay in grid.bays:
		var away: float = -1.0 if b.across(b.toward) >= 0.0 else 1.0
		var yaw: float = atan2(-b.axis.x, -b.axis.z)
		# first clear of every work area; failing that, of the zones and lanes
		for strict: bool in [true, false]:
			for side: float in [away, -away]:
				for s: float in [-9.5, -8.5, -7.5, -6.5, -5.5]:
					for lat: float in [4.4, 5.0, 5.6]:
						if not b.wait_spot.is_empty():
							break
						var p3: Vector3 = b.lane_point(s, side * lat)
						var p: Vector2 = Vector2(p3.x, p3.z)
						var fp: Array = lift.footprints_at(p, yaw)
						if static_hit(fp, 0.4) >= 0 or FootprintBox.set_overlaps(fp, zones, 0.0) or FootprintBox.set_overlaps(fp, _lane_boxes(), 0.6):
							continue
						if strict and in_keep_clear(fp):
							continue
						b.wait_spot = [p, yaw]
		print("Traffic: dock %d queue spot %s" % [b.dock.dock_id, b.wait_spot])


## Marks grid slots whose staging pose no drivable path reaches (on the
## empty hall, from open floor in front of the zones) as unreachable: a
## forklift never gets stuck in front of a slot it cannot turn into.
func _mark_drivable() -> void:
	var lift: CarryAgent = null
	if board != null and not board.forklifts().is_empty():
		lift = board.forklifts()[0]
	if lift == null:
		return
	var starts: Array = [[Vector2(-3.0, -12.0), PI * 0.5], [Vector2(-3.0, -12.0), -PI * 0.5], [Vector2(8.0, -12.0), 0.0]]
	var verdict: Dictionary = {}  ## staging position (snapped) -> bool
	var bad: int = 0
	_ignore_movers = true
	for s: StorageSlot in grid.slots:
		if s.is_trailer() or s.house_stock or not s.reachable:
			continue
		var pose: Array = staging_pose(s, lift.reach_for(s))
		var key: Vector3 = Vector3(snappedf(pose[0].x, 0.01), snappedf(pose[0].y, 0.01), snappedf(pose[1], 0.01))
		if not verdict.has(key):
			var ok: bool = false
			for st: Array in starts:
				if not plan_vehicle(lift, st[0], st[1], pose[0], pose[1], [s], false).is_empty():
					ok = true
					break
			verdict[key] = ok
		if not verdict[key]:
			s.reachable = false
			bad += 1
	_ignore_movers = false
	if bad > 0:
		print("Traffic: %d slots have no drivable way in (not used)" % bad)
		grid.slots_changed.emit()


## Keep-clear areas: every lock region (the zones and the floor storage
## with their approach and back-out room, each rack aisle). Dock lanes and
## the zone pallets come on top (in_keep_clear).
func _build_keep_clear() -> void:
	_keep_clear.clear()
	for s: StorageSlot in grid.slots:
		lock_for(s)
	for l: ZoneLock in _locks.values():
		if l.region.has_area():
			_keep_clear.append(l.box)
	# each dock lane's apron: the stage point and the room to line up for it
	_aprons.clear()
	for b: TrailerBay in grid.bays:
		var a: Vector2 = Vector2(b.axis.x, b.axis.z)
		var c0: Vector3 = b.lane_point(-APRON_LENGTH * 0.5, 0.0)
		_aprons.append(FootprintBox.make(Vector2(c0.x, c0.z), a, APRON_LENGTH * 0.5, 1.6))
	_keep_clear.append_array(_aprons)


## Each grid slot's access corridor: the straight a forklift drives (body
## width) from the slot's pallet out to the staging pose and its own length
## beyond. Records which pallets stand in which corridors, and which slots
## a pallet may never stand in (dock lanes and aprons, other areas'
## approach room). StorageGrid.placement_ok / obstructions use this.
func _build_access() -> void:
	var lift: ForkliftCarrier = null
	if board != null and not board.forklifts().is_empty():
		lift = board.forklifts()[0]
	if lift == null:
		return
	var grid_slots: Array[StorageSlot] = []
	var corridors: Dictionary = {}  ## StorageSlot -> FootprintBox
	var pallets: Dictionary = {}  ## StorageSlot -> FootprintBox
	for s: StorageSlot in grid.slots:
		if s.is_trailer():
			continue
		grid_slots.append(s)
		s.access_blockers.clear()
		s.blocks_access_of.clear()
		var reach: float = lift.reach_for(s)
		var od: Vector2 = Vector2(s.out_dir.x, s.out_dir.z).normalized()
		var p0: Vector2 = Vector2(s.position.x, s.position.z)
		var near: float = 0.65
		var far: float = reach + approach_length(s, reach) + ForkliftCarrier.BODY_Z.y
		corridors[s] = FootprintBox.make(p0 + od * (near + far) * 0.5, od, (far - near) * 0.5, ForkliftCarrier.BODY_HALF_W)
		var xf: Transform3D = s.pallet_transform()
		pallets[s] = FootprintBox.make(Vector2(xf.origin.x, xf.origin.z), Vector2(xf.basis.x.x, xf.basis.x.z), 0.6, 0.4)
	var hits: int = 0
	for p: StorageSlot in grid_slots:
		var pb: FootprintBox = pallets[p]
		if p.zone != StorageSlot.Zone.RACK:
			# rack pallets sit inside the rack: they block nobody's floor
			for s: StorageSlot in grid_slots:
				if s != p and (corridors[s] as FootprintBox).overlaps(pb, PALLET_CLEARANCE):
					s.access_blockers.append(p)
					p.blocks_access_of.append(s)
		var own: ZoneLock = lock_for(p)
		p.keep_clear_hit = false
		for l: ZoneLock in _locks.values():
			if l != own and l.box != null and l.box.overlaps(pb, 0.0) and not (p.zone == StorageSlot.Zone.RACK and l.key.begins_with("RACK")):
				p.keep_clear_hit = true
		if FootprintBox.set_overlaps([pb], _lane_boxes(), 0.0) or FootprintBox.set_overlaps([pb], _aprons, 0.0):
			p.keep_clear_hit = true
		if p.keep_clear_hit:
			hits += 1
	print("Traffic: slot access built, %d slots where no pallet may stand" % hits)


## True when the footprints stand in a zone front, a rack aisle, the floor
## storage approaches, a dock lane or its apron: nowhere to wait or park.
func in_keep_clear(boxes: Array) -> bool:
	if FootprintBox.set_overlaps(boxes, _keep_clear, 0.0):
		return true
	if FootprintBox.set_overlaps(boxes, _lane_boxes(), 0.3):
		return true
	return FootprintBox.set_overlaps(boxes, _zone_boxes(), 0.3)


## Every corner of the boxes on the hall floor (inside the walls).
func inside_hall(boxes: Array) -> bool:
	for b: FootprintBox in boxes:
		for c: Vector2 in b.corners():
			var inside: bool = false
			for r: Rect2 in hall_rects:
				if r.grow(-0.3).has_point(c):
					inside = true
					break
			if not inside:
				return false
	return true


## Why a parked forklift at this pose would be in the way, or "".
func parking_problem(agent: CarryAgent, p: Vector2, yaw: float, others: Array) -> String:
	var fp: Array = agent.footprints_at(p, yaw)
	if not inside_hall(fp):
		return "outside the hall"
	if static_hit(fp, 0.4) >= 0:
		return "static"
	if not open_floor(p):
		return "closed floor"
	# a little off the work areas, and off the lanes by more than a lane
	# driver's slack plus the vehicle distance
	if FootprintBox.set_distance(fp, _keep_clear) < PARKING_MARGIN or FootprintBox.set_distance(fp, _zone_boxes()) < PARKING_MARGIN:
		return "keep-clear area"
	# a lane user drives within 1 m of the lane centre line: keep the vehicle
	# distance from it
	if FootprintBox.set_distance(fp, _lane_boxes()) < HARD_VV - 0.6 or FootprintBox.set_distance(fp, _aprons) < HARD_VV - 0.6:
		return "dock lane"
	for o: Array in others:
		if FootprintBox.set_distance(fp, o) < SAFE_VV + 0.5:
			return "next to another parking or queue spot"
	if board != null:
		for r: Vector3 in board.rest_spots:
			if FootprintBox.set_distance(fp, [FootprintBox.make(Vector2(r.x, r.z), Vector2.RIGHT, 0.3, 0.3)]) < SAFE_VP + 0.5:
				return "next to a worker's rest spot"
	return ""


## Moves every forklift's parking spot out of the keep-clear areas (and
## apart from each other and the workers' rest spots): idle forklifts never
## stand in a zone front, a lane, an aisle or a slot approach.
func _choose_parking() -> void:
	if board == null:
		return
	# the dock queue spots do not count: only a lane user waits there, and
	# only while the other lane user is inside a lane (not parked)
	var taken: Array = []
	for f: ForkliftCarrier in board.forklifts():
		var home: Vector2 = f._home_pos
		var yaw: float = f._home_yaw
		# the bays of the parking area are spaced by design (PARK_VV)
		var bay: bool = parking_area.has_point(home)
		var why: String = parking_problem(f, home, yaw, [] if bay else taken)
		if not why.is_empty():
			var found: bool = false
			for r: float in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0]:
				for k: int in 24:
					var p: Vector2 = home + Vector2.from_angle(k * TAU / 24.0) * r
					for dy: float in [0.0, PI, PI * 0.5, -PI * 0.5]:
						if parking_problem(f, p, yaw + dy, taken).is_empty():
							print("Traffic: %s parking moved from %s (%s) to %s yaw %.0f" % [f.label, home, why, p, rad_to_deg(wrapf(yaw + dy, -PI, PI))])
							home = p
							yaw = wrapf(yaw + dy, -PI, PI)
							found = true
							break
					if found:
						break
				if found:
					break
			if not found:
				push_warning("Traffic: no parking spot clear of the work areas near %s for %s (%s)" % [home, f.label, why])
			elif f.job == null and f.speed == 0.0:
				f.move_home(home, yaw)
		taken.append(f.footprints_at(home, yaw))


# --- movers --------------------------------------------------------------------------

## Both in the forklift parking area (bays side by side): only PARK_VV.
static func both_parking(a: Node, b: Node) -> bool:
	if not parking_area.has_area():
		return false
	var ca: CarryAgent = a as CarryAgent
	var cb: CarryAgent = b as CarryAgent
	return ca != null and cb != null and parking_area.has_point(ca._pos) and parking_area.has_point(cb._pos)


static func safe_distance(a: Node, b: Node) -> float:
	var ka: int = a.call(&"traffic_kind")
	var kb: int = b.call(&"traffic_kind")
	if ka == Kind.VEHICLE and kb == Kind.VEHICLE:
		return PARK_VV if both_parking(a, b) else SAFE_VV
	if ka == Kind.PERSON and kb == Kind.PERSON:
		return SAFE_PP
	return SAFE_VP


## Hard floor below the yield distance: never closer than this.
static func hard_distance(a: Node, b: Node) -> float:
	var ka: int = a.call(&"traffic_kind")
	var kb: int = b.call(&"traffic_kind")
	if ka == Kind.VEHICLE and kb == Kind.VEHICLE:
		return PARK_VV - 0.2 if both_parking(a, b) else HARD_VV
	if ka == Kind.PERSON and kb == Kind.PERSON:
		return HARD_PP
	return HARD_VP


## Distance along `path` (from s0) to the first sample where `who` would come
## within the safety distance of another mover (and closer than it is now).
## Also returns that mover. [distance, mover]
## `react` is the time until the next check: both movers may close in that
## long, so the safety distance grows by their speeds times it.
func conflict_ahead(who: Node, path: MotionPath, s0: float, look: float, ignore: Object = null, react: float = 0.0) -> Array:
	var here: Array = who.call(&"traffic_footprints")
	var me: Vector2 = _center(here)
	var best: float = INF
	var by: Node = null
	var who_speed: float = float(who.get(&"speed"))
	var variant: float = float(who.call(&"footprint_variant")) if who.has_method(&"footprint_variant") else 0.0
	if path.fp_variant != variant:
		path.fp_cache.clear()
		path.fp_variant = variant
	var end: float = minf(s0 + look, path.length())
	for other: Node in movers:
		if other == who or not other.call(&"traffic_active"):
			continue
		var theirs: Array = other.call(&"traffic_footprints")
		if _center(theirs).distance_to(me) > look + 9.0:
			continue
		var hard: float = hard_distance(who, other)
		var other_speed: Variant = other.get(&"speed")
		var ov: float = float(other_speed) if other_speed != null else 0.0
		var safe: float = safe_distance(who, other) + minf((who_speed + ov) * react, 0.8)
		if other == ignore:
			# making way for it: no yielding, but never below the hard minimum
			safe = hard + minf((who_speed + ov) * react, 0.8)
		var now: float = FootprintBox.set_distance(here, theirs)
		# where a moving other is about to be (its next second or so of path)
		var coming: Array = _NO_BOXES
		if ov > 0.05 and other.has_method(&"future_footprints"):
			coming = other.call(&"future_footprints", minf(2.5, ov * 1.5 + 0.3))
		# samples on a fixed 0.25 m grid along the path (cached on the path),
		# starting with the current pose
		var s: float = s0
		var k: int = ceili(s0 / CONFLICT_STRIDE - 0.001)
		var first: bool = true
		while s <= end + 0.001:
			var fp: Array = here if first else _path_footprints(who, path, k - 1)
			first = false
			var d: float = FootprintBox.set_distance(fp, theirs)
			for cfp: Array in coming:
				d = minf(d, FootprintBox.set_distance(fp, cfp) + 0.2)
			# within the safety distance: no step that brings them closer, and
			# never below the hard minimum unless it opens the gap
			if d < safe and (d < now - 0.02 or (d < hard and d <= now + 0.01)):
				if s - s0 < best:
					best = s - s0
					by = other
				break
			s = k * CONFLICT_STRIDE
			k += 1
	return [best, by]


const CONFLICT_STRIDE: float = 0.25
const _NO_BOXES: Array = []


## Footprints of `who` at sample k (s = k * CONFLICT_STRIDE) of its path,
## computed once per path.
func _path_footprints(who: Node, path: MotionPath, k: int) -> Array:
	var cached: Variant = path.fp_cache.get(k)
	if cached != null:
		return cached
	var sk: float = minf(k * CONFLICT_STRIDE, path.length())
	var fp: Array = who.call(&"traffic_footprints_at", path.pos_at(sk), path.yaw_at(sk))
	path.fp_cache[k] = fp
	return fp


## For people walking straight along `dir`: blocked within `look` metres?
func person_blocked(who: Node, pos: Vector2, dir: Vector2, look: float) -> Node:
	var here: Array = who.call(&"traffic_footprints")
	for other: Node in movers:
		if other == who or not other.call(&"traffic_active"):
			continue
		var theirs: Array = other.call(&"traffic_footprints")
		if _center(theirs).distance_to(pos) > look + 6.0:
			continue
		var safe: float = safe_distance(who, other)
		var now: float = FootprintBox.set_distance(here, theirs)
		var s: float = 0.25
		while s <= look:
			var fp: Array = [FootprintBox.make(pos + dir * s, dir, 0.3, 0.3)]
			var d: float = FootprintBox.set_distance(fp, theirs)
			if d < safe and d < now - 0.02:
				return other
			s += 0.25
	return null


static func _center(boxes: Array) -> Vector2:
	if boxes.is_empty():
		return Vector2.ZERO
	return (boxes[0] as FootprintBox).c


## Priority for deadlock resolution: higher wins.
static func priority(m: Node) -> int:
	return int(m.call(&"traffic_priority"))


func _process(delta: float) -> void:
	if GameState.paused:
		return
	var dt: float = delta * float(GameState.speed)
	_clock += dt
	for m: Node in movers:
		for key: StringName in COOLDOWN_KEYS:
			if m.has_meta(key):
				var cd: float = float(m.get_meta(key))
				if cd > 0.0:
					m.set_meta(key, cd - dt)
	_update_token(dt)
	_make_way_t -= dt
	if _make_way_t <= 0.0:
		_make_way_t = MAKE_WAY_INTERVAL
		_make_way_ahead()
	_resolve_lock_waits(dt)
	# deadlocks and idle blockers
	for a: Node in movers:
		var by: Node = a.get(&"blocked_by")
		if by == null or not is_instance_valid(by):
			continue
		var waited: float = float(a.get(&"blocked_time"))
		var their_wait: float = float(by.get(&"blocked_time"))
		var idle: bool = not bool(by.call(&"traffic_working"))
		if a.has_method(&"committed") and bool(a.call(&"committed")) and waited > IDLE_BLOCK_TIME and by.has_method(&"traffic_reroute"):
			# `a` is on a fixed manoeuvre (lane, approach, back-out): `by` has to clear it
			_ask_give_way(by, a)
		elif idle and waited > IDLE_BLOCK_TIME:
			_ask_give_way(by, a)
		elif waited > DEADLOCK_TIME and (their_wait > DEADLOCK_TIME or not bool(by.call(&"traffic_moving"))):
			# waiting on each other (directly or down a chain): the one with
			# priority plans round the other; if it cannot (lane, approach),
			# the other makes way
			var loser: Node = a if priority(a) < priority(by) else by
			var winner: Node = by if loser == a else a
			# first the one with priority tries another way; if it already did
			# for this same blocker, the other one makes way (or else it)
			var tried: Object = winner.get_meta(&"rerouted_for") if winner.has_meta(&"rerouted_for") else null
			if tried != loser and _ask_reroute(winner):
				winner.set_meta(&"rerouted_for", loser)
			elif not _ask_give_way(loser, winner):
				_ask_give_way(winner, loser)
		if waited > DEADLOCK_TIME * 3.0:
			# still stuck: plan again round whatever is in the way
			_ask_reroute(a)


## People with nothing to do always make way for a working forklift or
## jack, and a jack always makes way for a working forklift: anyone lower
## in the yield order standing or walking where its current leg goes next
## is asked to move now, not after it has waited on them.
func _make_way_ahead() -> void:
	for v: Node in movers:
		var a: CarryAgent = v as CarryAgent
		if a == null or not a.traffic_working() or not a.traffic_active():
			continue
		var ahead: Array = a.future_footprints(MAKE_WAY_LOOK)
		if ahead.is_empty():
			continue
		var mine: int = priority(a)
		for m: Node in movers:
			if m == a or int(m.call(&"traffic_kind")) != Kind.PERSON or not m.call(&"traffic_active"):
				continue
			if (bool(m.call(&"traffic_working")) and not m is CarryAgent) or priority(m) >= mine:
				continue  # working jacks rank below forklifts, so they move too
			if float(m.get_meta(&"give_way_cooldown", 0.0)) > 0.0:
				continue
			var theirs: Array = m.call(&"traffic_footprints")
			var need: float = safe_distance(a, m) + MAKE_WAY_MARGIN
			for fp: Array in ahead:
				if FootprintBox.set_distance(fp, theirs) < need:
					_ask_give_way(m, a)
					break


## Agents waiting for a zone lock or a dock lane: when the holder is idle it
## leaves the area (drives to its parking spot); when it is stuck, the
## waiter clears out of its way (waits at its own parking spot) and the
## holder plans again.
func _resolve_lock_waits(dt: float) -> void:
	for m: Node in movers:
		var a: CarryAgent = m as CarryAgent
		if a == null:
			continue
		var h: CarryAgent = a.lock_holder_waited_for() as CarryAgent
		if h == null or h == a:
			a.lock_wait_time = 0.0
			continue
		a.lock_wait_time += dt
		if a.lock_wait_time < IDLE_BLOCK_TIME:
			continue
		if h.job == null:
			h.traffic_leave()
		elif float(h.get_meta(&"stuck_time", 0.0)) > DEADLOCK_TIME or h.blocked_time > DEADLOCK_TIME:
			if h.blocked_by == a or a.in_keep_clear():
				_ask_give_way(a, h)
			_ask_reroute(h)


static func _desc(m: Node) -> String:
	if m == null:
		return "null"
	return m.call(&"debug_state") if m.has_method(&"debug_state") else String(m.name)


## Gives the right of way to the agent stuck longest with work to do, and
## takes it back once it has moved on.
func _update_token(dt: float) -> void:
	var longest: Node = null
	var longest_t: float = STUCK_TOKEN_TIME
	for m: Node in movers:
		if not (m is CarryAgent):
			continue
		var a: CarryAgent = m
		var last: Vector2 = a.get_meta(&"progress_pos", a._pos)
		var stuck: float = float(a.get_meta(&"stuck_time", 0.0))
		if a.job == null or a._pos.distance_to(last) > 0.5:
			a.set_meta(&"progress_pos", a._pos)
			stuck = 0.0
		else:
			stuck += dt
		a.set_meta(&"stuck_time", stuck)
		if stuck > longest_t:
			longest_t = stuck
			longest = a
	if token_holder != null:
		_token_time += dt
		var h: CarryAgent = token_holder as CarryAgent
		if h == null or h.job == null or h._pos.distance_to(_token_from) > 4.0 or _token_time > 40.0:
			if OS.get_environment("TRAFFIC_DEBUG") == "1":
				print("Traffic: right of way back from %s" % _desc(token_holder))
			token_holder = null
	if token_holder == null and longest != null:
		token_holder = longest
		_token_from = (longest as CarryAgent)._pos
		_token_time = 0.0
		longest.set_meta(&"stuck_time", 0.0)
		print("Traffic: %s has been stuck for %.0f s, it gets the right of way" % [(longest as CarryAgent).label, longest_t])
	if token_holder != null:
		# everyone near its way makes room
		var h: CarryAgent = token_holder as CarryAgent
		var way: Array = h.future_footprints(8.0)  # cached: read only
		var at: Array = h.traffic_footprints()
		var mine: int = priority(h)
		for m: Node in movers:
			if m == token_holder or not m.call(&"traffic_active") or priority(m) > mine:
				continue  # a jack holding it does not move a working forklift
			var theirs: Array = m.call(&"traffic_footprints")
			var need: float = safe_distance(h, m) + 0.5
			var close: bool = FootprintBox.set_distance(at, theirs) < need
			if not close:
				for fp: Array in way:
					if FootprintBox.set_distance(fp, theirs) < need:
						close = true
						break
			if close:
				_ask_give_way(m, token_holder)


## Asks `who` to plan again (at most every 3 s). True when it will.
func _ask_reroute(who: Node) -> bool:
	if not who.has_method(&"traffic_reroute"):
		return false
	if float(who.get_meta(&"reroute_cooldown", 0.0)) > 0.0:
		return true
	if bool(who.call(&"traffic_reroute")):
		if OS.get_environment("TRAFFIC_DEBUG") == "1":
			var b: Node = who.get(&"blocked_by")
			print("Traffic: %s re-plans (blocked by %s)" % [_desc(who), _desc(b) if b != null and is_instance_valid(b) else "-"])
		who.set_meta(&"reroute_cooldown", 4.0)
		who.set(&"blocked_time", 0.0)
		return true
	return false


## Asks `who` to make way (at most every 3 s each). True when it will.
func _ask_give_way(who: Node, winner: Node) -> bool:
	if float(who.get_meta(&"give_way_cooldown", 0.0)) > 0.0:
		return true
	if bool(who.call(&"traffic_give_way", winner)):
		if winner.has_meta(&"rerouted_for"):
			winner.remove_meta(&"rerouted_for")
		if OS.get_environment("TRAFFIC_DEBUG") == "1":
			print("Traffic: %s gives way to %s" % [_desc(who), _desc(winner)])
		who.set_meta(&"give_way_cooldown", 3.0)
		who.set(&"blocked_time", 0.0)
		return true
	return false


# --- planning -------------------------------------------------------------------------

## Drivable legs for a vehicle from one pose to another. A grid route
## around the obstacles gives waypoints; consecutive poses are joined by
## Dubins paths (no arc tighter than the vehicle's radius), optionally after
## a reversing manoeuvre at the start (straight back or a reversing arc).
## Picks the cheapest that stays clear of walls, racks, pallets, dock ramps
## and parked movers; relaxes the mover clearance if nothing fits, and falls
## back to the least bad. `exempt` slots' pallets are ignored.
func plan_vehicle(agent: CarryAgent, from: Vector2, yaw0: float, to: Vector2, yaw1: float, exempt: Array = [], allow_fallback: bool = true, max_level: int = 2) -> Array:
	var r: float = agent.min_turn_radius
	var gdir: Vector2 = Vector2(-sin(yaw1), -cos(yaw1))
	# with or without lining up straight before the goal
	var routes: Array = []
	for lead: float in [1.5, 0.0, 3.5]:
		var wps: PackedVector2Array = route(from, to - gdir * lead, exempt, agent)
		if lead > 0.0:
			wps.append(to)
		routes.append(wps)
	var prefixes: Array = [[]]
	for spec: Array in [[0.0, 1.5], [PI * 0.5, 0.0], [-PI * 0.5, 0.0], [0.0, 3.0]]:
		var rev: MotionPath = MotionPath.from_pose(from, yaw0, true, &"manoeuvre")
		if spec[1] > 0.0:
			rev.straight(spec[1])
		if absf(spec[0]) > 0.0:
			rev.arc(spec[0], r * 1.1)
		prefixes.append([rev])
	var fallback: Array = []
	var fallback_hits: float = INF
	for level: int in max_level + 1:
		var best: Array = []
		var best_cost: float = INF
		for pre: Array in prefixes:
			var p0: Vector2 = from
			var y0: float = yaw0
			var cost: float = 0.0
			if not pre.is_empty():
				var rev: MotionPath = pre[0]
				if not path_clear(agent, rev, exempt, level):
					continue
				p0 = rev.end_pos()
				y0 = rev.end_yaw()
				cost = rev.length() * 1.5 + 3.0
			for waypoints: PackedVector2Array in routes:
				var wps: PackedVector2Array = waypoints.duplicate()
				wps[0] = p0
				var fwd: MotionPath = _chain(agent, p0, y0, wps, MotionPath.theta_of(yaw1), exempt, level)
				if fwd == null:
					continue
				var c: float = cost + fwd.length() + fwd.turning * r * 0.5
				if c >= best_cost:
					continue
				var legs: Array = pre.duplicate()
				legs.append(fwd)
				if path_clear(agent, fwd, exempt, level):
					best = legs
					best_cost = c
				elif level == 2:
					# least bad: the body never touches a wall or rack, nothing
					# touches a pallet or a dock lane; fewest fork contacts
					var hits: int = _count_hits(agent, fwd, exempt)
					if not pre.is_empty():
						hits += _count_hits(agent, pre[0], exempt)
					var score: float = hits * 1000.0 + c
					if hits < (1 << 20) and score < fallback_hits:
						fallback_hits = score
						fallback = legs
		if not best.is_empty():
			if level == 2:
				print("Traffic: %s planned ignoring parked movers" % agent.label)
				_clear_parked_for(agent, best)
			return best
	if not allow_fallback:
		return []
	if fallback.is_empty():
		_note_no_path(agent, from, to, "nothing drivable without touching an obstacle")
		return []
	_note_no_path(agent, from, to, "least bad way (%s)" % block_reason(agent, fallback[fallback.size() - 1], exempt))
	return fallback


## A plan that only fits by ignoring parked movers: every lower-priority
## one standing on it moves off (duty workers drop the duty and walk out of
## the corridor), so the two never wait on each other.
func _clear_parked_for(agent: CarryAgent, legs: Array) -> void:
	var mine: int = priority(agent)
	for m: Node in movers:
		if m == agent or not m.call(&"traffic_active") or m.call(&"traffic_moving") or priority(m) >= mine:
			continue
		var theirs: Array = m.call(&"traffic_footprints")
		var need: float = safe_distance(agent, m) + 0.6
		var hit: bool = false
		for leg: MotionPath in legs:
			for i: int in range(0, leg.pts.size(), SAMPLE_STRIDE):
				if FootprintBox.set_distance(agent.footprints_at(leg.pts[i], leg.yaws[i], false), theirs) < need:
					hit = true
					break
			if hit:
				break
		if hit:
			_ask_give_way(m, agent)


## Logs a planning failure at most every 10 game seconds per agent.
func _note_no_path(agent: CarryAgent, from: Vector2, to: Vector2, why: String) -> void:
	if _clock - float(agent.get_meta(&"no_path_logged", -INF)) < 10.0:
		return
	agent.set_meta(&"no_path_logged", _clock)
	print("Traffic: no clear path for %s from %s to %s: %s" % [agent.label, from, to, why])


## One forward leg through the waypoints (first = start, last = goal): each stretch is the shortest clear
## Dubins word without needless loops, trying the waypoint heading along the
## bend, then the incoming and outgoing directions.
func _chain(agent: CarryAgent, p0: Vector2, y0: float, pts: PackedVector2Array, goal_theta: float, exempt: Array, level: int) -> MotionPath:
	var r: float = agent.min_turn_radius
	var n: int = pts.size()
	var poses: Array = []  ## [pos, [theta options]]
	for i: int in range(1, n):
		var opts: Array = []
		if i == n - 1:
			opts.append(goal_theta)
		elif i == n - 2 and pts[n - 1].distance_to(pts[i]) < 1.6:
			opts.append(goal_theta)  # the lead-in point before the goal
		else:
			var din: Vector2 = (pts[i] - pts[i - 1]).normalized()
			var dout: Vector2 = (pts[i + 1] - pts[i]).normalized()
			var mid: Vector2 = din + dout
			if mid.length() > 0.01:
				opts.append(atan2(mid.y, mid.x))
			opts.append(atan2(dout.y, dout.x))
			opts.append(atan2(din.y, din.x))
		poses.append([pts[i], opts])
	var leg: MotionPath = null
	var at: Vector2 = p0
	var th: float = MotionPath.theta_of(y0)
	for k: int in poses.size():
		var target: Vector2 = poses[k][0]
		if target.distance_to(at) < 0.05:
			continue
		var found: MotionPath = null
		var found_th: float = 0.0
		var spare: MotionPath = null
		var spare_th: float = 0.0
		for th1: float in poses[k][1]:
			for d: MotionPath in MotionPath.dubins_all(at, th, target, th1, r, false, &"travel"):
				if spare == null or (spare.turning > PI * 1.3 and d.turning <= PI * 1.3):
					spare = d
					spare_th = th1
				if d.turning > PI * 1.3 and k < poses.size() - 1:
					continue  # needless loops between waypoints
				if path_clear(agent, d, exempt, level):
					found = d
					found_th = th1
					break
			if found != null:
				break
		if found == null:
			if spare == null:
				return null
			found = spare
			found_th = spare_th
		if leg == null:
			leg = found
		else:
			leg.append(found)
		at = target
		th = found_th
	return leg


# --- route grid ---------------------------------------------------------------------

func _build_grid() -> void:
	_blocked = PackedByteArray()
	_blocked.resize(GRID_SIZE.x * GRID_SIZE.y)
	for r: Rect2 in statics:
		_mark(r.grow(GRID_GROW), 1)
	for b: FootprintBox in _lane_boxes():
		_mark(b.bounds().grow(GRID_GROW * 0.5), 1)
	for b: FootprintBox in _zone_boxes():
		_mark(b.bounds().grow(GRID_GROW), 1)


func _mark(r: Rect2, v: int) -> void:
	var a: Vector2i = _cell(r.position)
	var b: Vector2i = _cell(r.end)
	for x: int in range(maxi(a.x, 0), mini(b.x, GRID_SIZE.x - 1) + 1):
		for y: int in range(maxi(a.y, 0), mini(b.y, GRID_SIZE.y - 1) + 1):
			_blocked[y * GRID_SIZE.x + x] = v


func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floori((p.x - GRID_MIN.x) / GRID_CELL), floori((p.y - GRID_MIN.y) / GRID_CELL))


func _cell_center(c: Vector2i) -> Vector2:
	return GRID_MIN + (Vector2(c) + Vector2(0.5, 0.5)) * GRID_CELL


## Waypoints from `from` to `to` around obstacles (A* on the route grid,
## then shortened by line of sight). Includes both ends.
func route(from: Vector2, to: Vector2, exempt: Array = [], agent: Node = null) -> PackedVector2Array:
	var blocked: PackedByteArray = _blocked.duplicate()
	for pb: FootprintBox in _pallet_boxes(exempt):
		var r: Rect2 = pb.bounds().grow(GRID_GROW)
		var a: Vector2i = _cell(r.position)
		var b: Vector2i = _cell(r.end)
		for x: int in range(maxi(a.x, 0), mini(b.x, GRID_SIZE.x - 1) + 1):
			for y: int in range(maxi(a.y, 0), mini(b.y, GRID_SIZE.y - 1) + 1):
				blocked[y * GRID_SIZE.x + x] = 1
	var static_only: PackedByteArray = blocked
	if agent != null and not _ignore_movers:
		blocked = static_only.duplicate()
		# go round movers that stand still (and fixed manoeuvres in progress)
		var keep: Array = []
		for m: Node in movers:
			if m == agent or not m.call(&"traffic_active"):
				continue
			if not bool(m.call(&"traffic_moving")):
				keep.append([m.call(&"traffic_footprints"), hard_distance(agent, m) + 0.3])
			if m.has_method(&"committed") and bool(m.call(&"committed")):
				for fp: Array in m.call(&"future_footprints", 8.0):
					keep.append([fp, 1.0])
		for k: Array in keep:
			for b: FootprintBox in k[0]:
				var r: Rect2 = b.bounds().grow(float(k[1]) + 0.65)
				var a0: Vector2i = _cell(r.position)
				var b0: Vector2i = _cell(r.end)
				for x: int in range(maxi(a0.x, 0), mini(b0.x, GRID_SIZE.x - 1) + 1):
					for y: int in range(maxi(a0.y, 0), mini(b0.y, GRID_SIZE.y - 1) + 1):
						blocked[y * GRID_SIZE.x + x] = 1
	var out: PackedVector2Array = _route_on(blocked, from, to)
	if out.is_empty() and blocked != static_only:
		# standing movers cut every way: route round the hall alone (the
		# drive itself still yields to them)
		out = _route_on(static_only, from, to)
	if out.is_empty():
		out = PackedVector2Array([from, to])
	return out


## A* on the given route grid from `from` to `to`, shortened by line of
## sight. Empty when there is no way.
func _route_on(blocked: PackedByteArray, from: Vector2, to: Vector2) -> PackedVector2Array:
	var s: Vector2i = _cell(from)
	var g: Vector2i = _cell(to)
	if not _in_grid(s) or not _in_grid(g) or _clear_line(blocked, from, to):
		return PackedVector2Array([from, to])
	# start and goal may sit in grown obstacles (staging next to a rack)
	var w: int = GRID_SIZE.x
	var n: int = GRID_SIZE.x * GRID_SIZE.y
	var open: Array[Vector2i] = [s]
	var g_cost: PackedFloat32Array = PackedFloat32Array()
	g_cost.resize(n)
	g_cost.fill(INF)
	var parent: PackedInt32Array = PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var closed: PackedByteArray = PackedByteArray()
	closed.resize(n)
	g_cost[s.y * w + s.x] = 0.0
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	var found: bool = false
	var guard: int = 0
	while not open.is_empty() and guard < 20000:
		guard += 1
		var bi: int = 0
		var best: float = INF
		for i: int in open.size():
			var c: Vector2i = open[i]
			var f: float = g_cost[c.y * w + c.x] + Vector2(c - g).length()
			if f < best:
				best = f
				bi = i
		var cur: Vector2i = open[bi]
		open.remove_at(bi)
		var ci: int = cur.y * w + cur.x
		if closed[ci] == 1:
			continue
		closed[ci] = 1
		if cur == g:
			found = true
			break
		for d: Vector2i in dirs:
			var nb: Vector2i = cur + d
			if not _in_grid(nb):
				continue
			var ni: int = nb.y * w + nb.x
			if closed[ni] == 1:
				continue
			# grown obstacles block, except right around the start and goal
			if blocked[ni] == 1 and Vector2(nb - s).length() > 3.0 and Vector2(nb - g).length() > 3.0:
				continue
			var cost: float = g_cost[ci] + (1.4142 if d.x != 0 and d.y != 0 else 1.0) + (2.0 if blocked[ni] == 1 else 0.0)
			if cost < g_cost[ni]:
				g_cost[ni] = cost
				parent[ni] = ci
				open.append(nb)
	if not found:
		return PackedVector2Array()
	var cells: Array[Vector2] = []
	var k: int = g.y * w + g.x
	while k != -1:
		cells.push_front(_cell_center(Vector2i(k % w, k / w)))
		k = parent[k]
	cells[0] = from
	cells[cells.size() - 1] = to
	# shortcut by line of sight
	var out: PackedVector2Array = PackedVector2Array([from])
	var i0: int = 0
	while i0 < cells.size() - 1:
		var j: int = cells.size() - 1
		while j > i0 + 1 and not _clear_line(blocked, cells[i0], cells[j]):
			j -= 1
		out.append(cells[j])
		i0 = j
	return out


## True when p is open floor on the route grid (not next to walls, racks,
## zones or ramps): somewhere a vehicle can be routed on from.
func open_floor(p: Vector2) -> bool:
	var c: Vector2i = _cell(p)
	return _in_grid(c) and _blocked[c.y * GRID_SIZE.x + c.x] == 0


func _in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GRID_SIZE.x and c.y < GRID_SIZE.y


func _clear_line(blocked: PackedByteArray, a: Vector2, b: Vector2) -> bool:
	var steps: int = maxi(1, ceili(a.distance_to(b) / (GRID_CELL * 0.5)))
	var sa: Vector2i = _cell(a)
	var sb: Vector2i = _cell(b)
	for i: int in steps + 1:
		var c: Vector2i = _cell(a.lerp(b, float(i) / steps))
		if not _in_grid(c):
			return false
		if blocked[c.y * GRID_SIZE.x + c.x] == 1 and Vector2(c - sa).length() > 3.0 and Vector2(c - sb).length() > 3.0:
			return false
	return true


## level 0: full clearance; 1: movers at 1 m; 2: movers ignored.
func path_clear(agent: CarryAgent, leg: MotionPath, exempt: Array, level: int = 0) -> bool:
	var pallets: Array[FootprintBox] = _pallet_boxes(exempt)
	# zones: routes go round them (route grid); legs may cut over empty
	# corners of a zone, but never through its pallets
	var lanes: Array[FootprintBox] = _lane_boxes()
	var regions: Array[FootprintBox] = []
	var parked: Array = []
	var committed: Array = []
	if level < 2 and not _ignore_movers:
		# keep out of where another agent holds a zone or rack aisle
		regions = _foreign_regions(agent)
		# and off the rest of anyone's fixed manoeuvre (lane, approach, back-out)
		for m: Node in movers:
			if m != agent and m.has_method(&"committed") and bool(m.call(&"committed")):
				committed.append_array(m.call(&"future_footprints", 8.0))
		for m: Node in movers:
			if m != agent and m.call(&"traffic_active") and not m.call(&"traffic_moving"):
				parked.append(m)
	var n: int = leg.pts.size()
	var idx: Array[int] = []
	for i: int in range(0, n, SAMPLE_STRIDE):
		idx.append(i)
	if idx[idx.size() - 1] != n - 1:
		idx.append(n - 1)
	# a start pose already too close to something may still drive away from it
	var start_hit: int = static_hit(agent.footprints_at(leg.pts[0], leg.yaws[0], false), STATIC_CLEARANCE)
	for i: int in idx:
		var fp: Array = agent.footprints_at(leg.pts[i], leg.yaws[i], false)
		var hit: int = static_hit(fp, STATIC_CLEARANCE)
		if hit >= 0 and not (hit == start_hit and i * MotionPath.STEP < 1.5 and static_hit(fp, 0.0) < 0):
			return false
		for pb: FootprintBox in pallets:
			if FootprintBox.set_overlaps(fp, [pb], PALLET_CLEARANCE):
				return false
		if FootprintBox.set_overlaps(fp, lanes, 0.05) or FootprintBox.set_overlaps(fp, regions, 0.05):
			return false
		for m: Node in parked:
			var need: float = safe_distance(agent, m) + 0.6 if level == 0 else hard_distance(agent, m) + 0.2
			if FootprintBox.set_distance(fp, m.call(&"traffic_footprints")) < need:
				return false
		if i > 0:
			for cfp: Array in committed:
				if FootprintBox.set_distance(fp, cfp) < (1.5 if level == 0 else 0.6):
					return false
	return true


## 0 when the leg touches nothing, 1 << 20 when the vehicle (body, forks or
## load) would touch a static obstacle, a pallet (other than the exempt
## slots') or a dock lane. A leg that starts touching something (stuck
## against it) may keep touching it for its first metre while it gets out.
func _count_hits(agent: CarryAgent, leg: MotionPath, exempt: Array = []) -> int:
	var pallets: Array[FootprintBox] = _pallet_boxes(exempt)
	var start_hit: int = static_hit(agent.footprints_at(leg.pts[0], leg.yaws[0], false), 0.0)
	for i: int in range(0, leg.pts.size(), SAMPLE_STRIDE):
		var fp: Array = agent.footprints_at(leg.pts[i], leg.yaws[i], false)
		if FootprintBox.set_overlaps(fp, pallets, 0.0) or FootprintBox.set_overlaps(fp, _lane_boxes(), 0.0):
			return 1 << 20
		var hit: int = static_hit(fp, 0.0)
		if hit >= 0 and not (hit == start_hit and i * MotionPath.STEP < 1.0):
			return 1 << 20
	return 0


## Why a leg is not clear at full clearance (debugging): the first check of
## path_clear it fails.
func block_reason(agent: CarryAgent, leg: MotionPath, exempt: Array) -> String:
	var pallets: Array[FootprintBox] = _pallet_boxes(exempt)
	var regions: Array[FootprintBox] = _foreign_regions(agent)
	for i: int in range(0, leg.pts.size(), SAMPLE_STRIDE):
		var fp: Array = agent.footprints_at(leg.pts[i], leg.yaws[i], false)
		var hit: int = static_hit(fp, STATIC_CLEARANCE)
		if hit >= 0:
			return "near static %s %s at %s" % [static_names[hit], statics[hit], leg.pts[i]]
		for pb: FootprintBox in pallets:
			if FootprintBox.set_overlaps(fp, [pb], PALLET_CLEARANCE):
				return "pallet at %s" % pb.c
		if FootprintBox.set_overlaps(fp, _lane_boxes(), 0.05):
			return "dock lane at %s" % leg.pts[i]
		if FootprintBox.set_overlaps(fp, regions, 0.05):
			return "area another agent holds at %s" % leg.pts[i]
	for i: int in range(0, leg.pts.size(), SAMPLE_STRIDE):
		var fp: Array = agent.footprints_at(leg.pts[i], leg.yaws[i], false)
		for m: Node in movers:
			if m != agent and m.call(&"traffic_active") and not m.call(&"traffic_moving"):
				var d: float = FootprintBox.set_distance(fp, m.call(&"traffic_footprints"))
				if d < safe_distance(agent, m) + 0.6:
					return "parked %s %.2f m at %s" % [m.get(&"label") if m.get(&"label") != null else m.name, d, leg.pts[i]]
	return "another agent's fixed manoeuvre"


func _pallet_boxes(exempt: Array) -> Array[FootprintBox]:
	var out: Array[FootprintBox] = []
	for s: StorageSlot in grid.slots:
		if s.unit == null or s in exempt:
			continue
		if s.zone == StorageSlot.Zone.RACK:
			continue  # inside the rack's own obstacle
		var xf: Transform3D = s.pallet_transform()
		var ax: Vector3 = xf.basis.x
		out.append(FootprintBox.make(Vector2(xf.origin.x, xf.origin.z), Vector2(ax.x, ax.z), 0.6, 0.4))
	return out


## INBOUND / OUTBOUND are only entered square-on along a slot's approach
## straight: travel keeps out of the area their pallets cover.
func _zone_boxes() -> Array[FootprintBox]:
	if not _zone_cache.is_empty():
		return _zone_cache
	for zone: StorageSlot.Zone in [StorageSlot.Zone.INBOUND, StorageSlot.Zone.OUTBOUND]:
		var r: Rect2 = Rect2()
		var first: bool = true
		for sl: StorageSlot in grid.slots:
			if sl.zone != zone:
				continue
			var ax: Vector3 = sl.pallet_transform().basis.x
			var hx: float = 0.6 if absf(ax.x) > 0.7 else 0.4
			var hz: float = 0.4 if absf(ax.x) > 0.7 else 0.6
			var pr: Rect2 = Rect2(sl.position.x - hx, sl.position.z - hz, hx * 2.0, hz * 2.0)
			r = pr if first else r.merge(pr)
			first = false
		if not first:
			_zone_cache.append(FootprintBox.from_rect(r))
	return _zone_cache


## The ramps and trailers are only entered through the lane legs.
func _lane_boxes() -> Array[FootprintBox]:
	if not _lane_cache.is_empty() and _lane_cache.size() == grid.bays.size():
		return _lane_cache
	_lane_cache.clear()
	for b: TrailerBay in grid.bays:
		var a: Vector2 = Vector2(b.axis.x, b.axis.z)
		var c0: Vector3 = b.lane_point(0.0, 0.0)
		_lane_cache.append(FootprintBox.make(Vector2(c0.x, c0.z) + a * 7.0, a, 7.0, 1.6))
	return _lane_cache
