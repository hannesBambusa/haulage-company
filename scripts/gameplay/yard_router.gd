class_name YardRouter
extends RefCounted
## Straight-line routes on the warehouse floor that avoid rack footprints.
## Tries a direct line, then two L-shapes, then a detour along the main aisle
## in front of the racks. Good enough for Milestone 1; no navmesh.

const SAMPLE_STEP: float = 0.3

## Rack footprints on the XZ plane (x, z), already inflated.
var obstacles: Array[Rect2] = []
## Z of the open aisle in front of the racks.
var aisle_z: float = 0.0


## Waypoints from `from` to `to`, excluding `from`, all on the ground (y = 0).
func plan(from: Vector3, to: Vector3) -> PackedVector3Array:
	from.y = 0.0
	to.y = 0.0
	var candidates: Array[PackedVector3Array] = [
		PackedVector3Array([to]),
		PackedVector3Array([Vector3(from.x, 0.0, to.z), to]),
		PackedVector3Array([Vector3(to.x, 0.0, from.z), to]),
		PackedVector3Array([Vector3(from.x, 0.0, aisle_z), Vector3(to.x, 0.0, aisle_z), to]),
	]
	for c: PackedVector3Array in candidates:
		if is_clear(from, c):
			return c
	return candidates[candidates.size() - 1]


func is_clear(from: Vector3, points: PackedVector3Array) -> bool:
	var a: Vector3 = from
	for b: Vector3 in points:
		if _segment_blocked(a, b):
			return false
		a = b
	return true


func _segment_blocked(a: Vector3, b: Vector3) -> bool:
	var length: float = a.distance_to(b)
	var steps: int = maxi(1, ceili(length / SAMPLE_STEP))
	for i: int in steps + 1:
		var p: Vector3 = a.lerp(b, float(i) / steps)
		var q: Vector2 = Vector2(p.x, p.z)
		for r: Rect2 in obstacles:
			if r.has_point(q):
				return true
	return false
