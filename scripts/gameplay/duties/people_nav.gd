class_name PeopleNav
extends RefCounted
## Walkable floor for people: a fine grid over the hall built from the
## Traffic statics (walls, racks, furniture, decor), the INBOUND / OUTBOUND
## pallet areas and the dock lanes (people never walk onto ramps). Forklift
## areas (rack aisles, zone fronts, the floor storage block) are walkable but
## cost more, so routes keep to the open floor. Parked forklifts are kept at
## a distance. A* with a binary heap, then line-of-sight shortcuts.

const CELL: float = 0.25
const GRID_MIN: Vector2 = Vector2(-27.0, -29.0)
const GRID_SIZE: Vector2i = Vector2i(208, 128)
## Person half width plus a little room: routes keep the centre this far from statics.
const BODY: float = 0.4
## The centre never comes closer than this to a static (the body stays clear).
const CORE: float = 0.2
## Extra cost per cell in forklift work areas.
const AREA_COST: float = 3.0

enum { FREE = 0, AREA = 1, SOFT = 2, HARD = 3 }

var traffic: Traffic = null
## Per cell: FREE, AREA (walkable, costly), SOFT (too close to an obstacle),
## HARD (inside an obstacle).
var cells: PackedByteArray = PackedByteArray()
## Rects people must not stand in while idle: forklift areas, lanes, zones.
var no_idle: Array[Rect2] = []
var _base: PackedByteArray = PackedByteArray()
## Cells connected to the hall floor (1), from mark_reachable().
var _reach: PackedByteArray = PackedByteArray()
var _extra: Dictionary = {}  ## key -> Rect2 (props put down on the floor)
var _astar: AStarGrid2D = null
## Floor people may use (the hall); everything outside is off limits.
var hall: Array[Rect2] = []
## Zones and dock lanes as rects (people never step onto them).
var _fixed_rects: Array[Rect2] = []


func _init(p_traffic: Traffic, p_hall: Array[Rect2] = []) -> void:
	traffic = p_traffic
	hall = p_hall
	rebuild()


func rebuild() -> void:
	_base = PackedByteArray()
	_base.resize(GRID_SIZE.x * GRID_SIZE.y)
	no_idle.clear()
	# forklift areas first (they are only costly), obstacles on top
	for s: StorageSlot in traffic.grid.slots:
		var l: Traffic.ZoneLock = traffic.lock_for(s)
		if l != null and l.region.has_area() and not no_idle.has(l.region):
			_mark(l.region, AREA)
			no_idle.append(l.region)
	_fixed_rects.clear()
	for b: FootprintBox in traffic._lane_boxes():
		var r: Rect2 = b.bounds()
		_fixed_rects.append(r)
		_mark(r.grow(BODY), SOFT)
		_mark(r, HARD)
		no_idle.append(r.grow(1.0))
	for b: FootprintBox in traffic._zone_boxes():
		_fixed_rects.append(b.bounds())
		_mark(b.bounds().grow(BODY), SOFT)
		_mark(b.bounds().grow(0.05), HARD)
		no_idle.append(b.bounds().grow(0.6))
	for r: Rect2 in traffic.statics:
		_mark(r.grow(BODY), SOFT)
		_mark(r.grow(CORE), HARD)
	if not hall.is_empty():
		for y: int in GRID_SIZE.y:
			for x: int in GRID_SIZE.x:
				var p: Vector2 = center_of(Vector2i(x, y))
				var inside: bool = false
				for h: Rect2 in hall:
					if h.has_point(p):
						inside = true
						break
				if not inside:
					_base[y * GRID_SIZE.x + x] = HARD
	cells = _base.duplicate()
	for r: Rect2 in _extra.values():
		_mark_into(cells, r.grow(BODY), SOFT)
		_mark_into(cells, r.grow(CORE), HARD)
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(Vector2i.ZERO, GRID_SIZE)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	_sync(Vector2i.ZERO, GRID_SIZE - Vector2i.ONE)


## A prop put down on the floor (sign, bucket, toolbox): people walk round it.
func set_extra(key: String, r: Variant) -> void:
	var touched: Array[Rect2] = []
	if _extra.has(key):
		touched.append(_extra[key])
	if r == null:
		_extra.erase(key)
	else:
		_extra[key] = r
		touched.append(r)
	cells = _base.duplicate()
	for e: Rect2 in _extra.values():
		_mark_into(cells, e.grow(BODY), SOFT)
		_mark_into(cells, e.grow(CORE), HARD)
	for t: Rect2 in touched:
		var g: Rect2 = t.grow(BODY + CELL)
		_sync(cell_of(g.position), cell_of(g.end))


## Copies cell values into the A* grid (solid: SOFT and HARD; AREA costs more).
func _sync(a: Vector2i, b: Vector2i) -> void:
	for x: int in range(maxi(a.x, 0), mini(b.x, GRID_SIZE.x - 1) + 1):
		for y: int in range(maxi(a.y, 0), mini(b.y, GRID_SIZE.y - 1) + 1):
			var v: int = cells[y * GRID_SIZE.x + x]
			var c: Vector2i = Vector2i(x, y)
			_astar.set_point_solid(c, v >= SOFT)
			_astar.set_point_weight_scale(c, 1.0 + AREA_COST if v == AREA else 1.0)


func _mark(r: Rect2, v: int) -> void:
	_mark_into(_base, r, v)


func _mark_into(arr: PackedByteArray, r: Rect2, v: int) -> void:
	var a: Vector2i = cell_of(r.position)
	var b: Vector2i = cell_of(r.end)
	for x: int in range(maxi(a.x, 0), mini(b.x, GRID_SIZE.x - 1) + 1):
		for y: int in range(maxi(a.y, 0), mini(b.y, GRID_SIZE.y - 1) + 1):
			var i: int = y * GRID_SIZE.x + x
			if arr[i] < v:
				arr[i] = v


func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori((p.x - GRID_MIN.x) / CELL), floori((p.y - GRID_MIN.y) / CELL))


func center_of(c: Vector2i) -> Vector2:
	return GRID_MIN + (Vector2(c) + Vector2(0.5, 0.5)) * CELL


func in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GRID_SIZE.x and c.y < GRID_SIZE.y


func value_at(p: Vector2) -> int:
	var c: Vector2i = cell_of(p)
	return cells[c.y * GRID_SIZE.x + c.x] if in_grid(c) else HARD


## A person can stand here (clear of every obstacle by BODY).
func walkable(p: Vector2) -> bool:
	return value_at(p) <= AREA and reachable(p)


## Fine to stand around here: walkable and outside every forklift area,
## lane and zone.
func idle_safe(p: Vector2) -> bool:
	if value_at(p) != FREE or not reachable(p):
		return false
	for r: Rect2 in no_idle:
		if r.has_point(p):
			return false
	return true


func in_forklift_area(p: Vector2) -> bool:
	for r: Rect2 in no_idle:
		if r.has_point(p):
			return true
	return false


## Flood fill from a point on the hall floor: everything people can get to
## (the yard outside the walls is not).
func mark_reachable(from: Vector2) -> void:
	_reach = PackedByteArray()
	_reach.resize(GRID_SIZE.x * GRID_SIZE.y)
	var s: Vector2i = cell_of(from)
	if not in_grid(s):
		return
	var stack: PackedInt32Array = PackedInt32Array([s.y * GRID_SIZE.x + s.x])
	_reach[stack[0]] = 1
	while stack.size() > 0:
		var i: int = stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var x: int = i % GRID_SIZE.x
		var y: int = i / GRID_SIZE.x
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var ny: int = y + d.y
			if nx < 0 or ny < 0 or nx >= GRID_SIZE.x or ny >= GRID_SIZE.y:
				continue
			var ni: int = ny * GRID_SIZE.x + nx
			if _reach[ni] == 0 and _base[ni] <= AREA:
				_reach[ni] = 1
				stack.append(ni)


func reachable(p: Vector2) -> bool:
	if _reach.is_empty():
		return true
	var c: Vector2i = cell_of(p)
	return in_grid(c) and _reach[c.y * GRID_SIZE.x + c.x] == 1


## Moves p out of every obstacle grown by CORE (statics, zones, lanes, props
## on the floor): the body never overlaps one; moving along an edge slides.
func push_out(p: Vector2) -> Vector2:
	var q: Vector2 = p
	for pass_i: int in 2:
		var moved: bool = false
		for r: Rect2 in _rects_near(q):
			var g: Rect2 = r.grow(CORE + 0.01)
			if not g.has_point(q):
				continue
			var dl: float = q.x - g.position.x
			var dr: float = g.end.x - q.x
			var dt: float = q.y - g.position.y
			var db: float = g.end.y - q.y
			var m: float = minf(minf(dl, dr), minf(dt, db))
			if m == dl:
				q.x = g.position.x - 0.001
			elif m == dr:
				q.x = g.end.x + 0.001
			elif m == dt:
				q.y = g.position.y - 0.001
			else:
				q.y = g.end.y + 0.001
			moved = true
		if not moved:
			break
	return q


func _rects_near(p: Vector2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var probe: Rect2 = Rect2(p, Vector2.ZERO).grow(0.8)
	for i: int in traffic.statics_near(probe):
		out.append(traffic.statics[i])
	for r: Rect2 in _fixed_rects:
		if r.grow(0.5).has_point(p):
			out.append(r)
	for r: Rect2 in _extra.values():
		if r.grow(0.5).has_point(p):
			out.append(r)
	return out


## Nearest walkable point to p (within `radius`), or p itself when none.
func nearest_walkable(p: Vector2, radius: float = 2.0, idle: bool = false) -> Vector2:
	if (idle_safe(p) if idle else walkable(p)):
		return p
	var best: Vector2 = p
	var best_d: float = INF
	var c0: Vector2i = cell_of(p)
	var r: int = ceili(radius / CELL)
	for dx: int in range(-r, r + 1):
		for dy: int in range(-r, r + 1):
			var c: Vector2i = c0 + Vector2i(dx, dy)
			if not in_grid(c):
				continue
			var q: Vector2 = center_of(c)
			var d: float = q.distance_squared_to(p)
			if d < best_d and (idle_safe(q) if idle else walkable(q)):
				best_d = d
				best = q
	return best


## Waypoints from `from` to `to` (both included). `avoid` are extra
## FootprintBox sets [boxes, gap] to keep away from (parked forklifts,
## people standing). Starts and goals right next to an obstacle (a chair,
## a shelf) are fine: the route joins the open floor nearby. Empty when
## there is no way.
func find_path(from: Vector2, to: Vector2, avoid: Array = []) -> PackedVector2Array:
	if value_at(from) == HARD and value_at(to) == HARD:
		return PackedVector2Array()
	var s: Vector2i = _open_cell(from)
	var g: Vector2i = _open_cell(to)
	if s == Vector2i(-1, -1) or g == Vector2i(-1, -1):
		return PackedVector2Array()
	# temporary obstacles, kept off the start and goal cells
	var marked: Array[Vector2i] = []
	for a: Array in avoid:
		for b: FootprintBox in a[0]:
			var r: Rect2 = b.bounds().grow(float(a[1]))
			var c0: Vector2i = cell_of(r.position)
			var c1: Vector2i = cell_of(r.end)
			for x: int in range(maxi(c0.x, 0), mini(c1.x, GRID_SIZE.x - 1) + 1):
				for y: int in range(maxi(c0.y, 0), mini(c1.y, GRID_SIZE.y - 1) + 1):
					var c: Vector2i = Vector2i(x, y)
					if (c - s).length_squared() <= 4 or (c - g).length_squared() <= 4 or _astar.is_point_solid(c):
						continue
					_astar.set_point_solid(c, true)
					marked.append(c)
	var out: PackedVector2Array = PackedVector2Array()
	if s == g or _line_ok(from, to):
		out = PackedVector2Array([from, to])
	else:
		var ids: Array[Vector2i] = _astar.get_id_path(s, g)
		if not ids.is_empty():
			out = _smooth(from, to, ids)
	for c: Vector2i in marked:
		_astar.set_point_solid(c, false)
	return out


## Nearest open (not solid) cell to p, within a metre; (-1, -1) when none.
func _open_cell(p: Vector2) -> Vector2i:
	var c0: Vector2i = cell_of(p)
	if in_grid(c0) and not _astar.is_point_solid(c0):
		return c0
	var best: Vector2i = Vector2i(-1, -1)
	var best_d: float = INF
	for dx: int in range(-4, 5):
		for dy: int in range(-4, 5):
			var c: Vector2i = c0 + Vector2i(dx, dy)
			if not in_grid(c) or _astar.is_point_solid(c):
				continue
			var d: float = center_of(c).distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = c
	return best


## Cell path to waypoints: straight runs merged, then shortcuts by line of sight.
func _smooth(from: Vector2, to: Vector2, ids: Array[Vector2i]) -> PackedVector2Array:
	var pts: Array[Vector2] = [from]
	for i: int in range(1, ids.size() - 1):
		var d0: Vector2i = ids[i] - ids[i - 1]
		var d1: Vector2i = ids[i + 1] - ids[i]
		if d0 != d1:
			pts.append(center_of(ids[i]))
	if ids.size() > 1:
		pts.append(center_of(ids[ids.size() - 1]))
	pts.append(to)
	var out: PackedVector2Array = PackedVector2Array([from])
	var i0: int = 0
	while i0 < pts.size() - 1:
		var j: int = i0 + 1
		while j + 1 < pts.size() and _line_ok(pts[i0], pts[j + 1]):
			j += 1
		out.append(pts[j])
		i0 = j
	return out


## Straight line over open cells (the first and last metre may graze an obstacle's margin).
func _line_ok(a: Vector2, b: Vector2) -> bool:
	var steps: int = maxi(1, ceili(a.distance_to(b) / (CELL * 0.5)))
	var total: float = a.distance_to(b)
	for i: int in steps + 1:
		var t: float = float(i) / steps
		var c: Vector2i = cell_of(a.lerp(b, t))
		if not in_grid(c):
			return false
		var v: int = cells[c.y * GRID_SIZE.x + c.x]
		if v == HARD:
			return false
		if _astar.is_point_solid(c) and t * total > 0.6 and (1.0 - t) * total > 0.6:
			return false
	return true
