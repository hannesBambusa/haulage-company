class_name FootprintBox
extends RefCounted
## Oriented rectangle on the floor plane (x, z): a vehicle body, its forks
## and load, a person, a pallet or an obstacle. Overlap by separating axes,
## distance by edge to edge.

var c: Vector2 = Vector2.ZERO
## Unit vector along the box length.
var ax: Vector2 = Vector2.RIGHT
var hl: float = 0.5
var hw: float = 0.5


static func make(center: Vector2, axis: Vector2, half_len: float, half_wid: float) -> FootprintBox:
	var b: FootprintBox = FootprintBox.new()
	b.c = center
	b.ax = axis.normalized() if axis.length() > 0.0001 else Vector2.RIGHT
	b.hl = half_len
	b.hw = half_wid
	return b


static func from_rect(r: Rect2) -> FootprintBox:
	return make(r.get_center(), Vector2.RIGHT, r.size.x * 0.5, r.size.y * 0.5)


## Box of a vehicle part: local z range [z0, z1] (front = -Z) and half width,
## for a body at pos with yaw.
static func local_span(pos: Vector2, yaw: float, z0: float, z1: float, half_wid: float) -> FootprintBox:
	# vehicle local +Z (backwards) on the floor plane
	var back: Vector2 = Vector2(sin(yaw), cos(yaw))
	var mid: float = (z0 + z1) * 0.5
	return make(pos + back * mid, back, absf(z1 - z0) * 0.5, half_wid)


func corners() -> PackedVector2Array:
	var px: Vector2 = Vector2(-ax.y, ax.x)
	var a: Vector2 = ax * hl
	var b: Vector2 = px * hw
	return PackedVector2Array([c + a + b, c + a - b, c - a - b, c - a + b])


func bounds() -> Rect2:
	var r: Rect2 = Rect2(c, Vector2.ZERO)
	for p: Vector2 in corners():
		r = r.expand(p)
	return r


func overlaps(o: FootprintBox, margin: float = 0.0) -> bool:
	var axes: Array[Vector2] = [ax, Vector2(-ax.y, ax.x), o.ax, Vector2(-o.ax.y, o.ax.x)]
	var d: Vector2 = o.c - c
	for n: Vector2 in axes:
		var r1: float = hl * absf(ax.dot(n)) + hw * absf(Vector2(-ax.y, ax.x).dot(n))
		var r2: float = o.hl * absf(o.ax.dot(n)) + o.hw * absf(Vector2(-o.ax.y, o.ax.x).dot(n))
		if absf(d.dot(n)) > r1 + r2 + margin:
			return false
	return true


func distance_to(o: FootprintBox) -> float:
	if overlaps(o):
		return 0.0
	var a: PackedVector2Array = corners()
	var b: PackedVector2Array = o.corners()
	var best: float = INF
	for i: int in 4:
		var a0: Vector2 = a[i]
		var a1: Vector2 = a[(i + 1) % 4]
		for j: int in 4:
			best = minf(best, _point_segment(b[j], a0, a1))
			best = minf(best, _point_segment(a[j], b[i], b[(i + 1) % 4]))
	return best


static func _point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Smallest distance between two sets of boxes.
static func set_distance(a: Array, b: Array) -> float:
	var best: float = INF
	for x: FootprintBox in a:
		for y: FootprintBox in b:
			best = minf(best, x.distance_to(y))
	return best


static func set_overlaps(a: Array, b: Array, margin: float) -> bool:
	for x: FootprintBox in a:
		for y: FootprintBox in b:
			if x.overlaps(y, margin):
				return true
	return false
