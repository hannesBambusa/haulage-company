class_name SpotQueue
extends RefCounted
## One person at a time at a tight spot (the break counter with the coffee
## machine, the cooler and the bin; the cleaning corner's tool rack). A
## worker reserves it on the way up and waits a little way off while it is
## taken. A finished user keeps it until they have walked off (or for a few
## seconds), so the next one never meets them in the narrow space.

const LEAVE_DISTANCE: float = 1.6
const LEAVE_TIME: float = 6.0

## key -> {"w": WorkerActor, "pos": Vector2, "leaving": bool, "t": float}
var taken: Dictionary = {}


func holder(key: String) -> Node:
	var e: Variant = taken.get(key)
	return (e as Dictionary).w if e != null else null


func reserve(key: String, w: Node, pos: Vector2) -> bool:
	var e: Variant = taken.get(key)
	if e == null or (e as Dictionary).w == w or not is_instance_valid((e as Dictionary).w):
		taken[key] = {"w": w, "pos": pos, "leaving": false, "t": 0.0}
		return true
	return false


func release(key: String, w: Node) -> void:
	var e: Variant = taken.get(key)
	if e != null and (e as Dictionary).w == w:
		(e as Dictionary).leaving = true


func release_all(w: Node) -> void:
	for key: String in taken.keys():
		if (taken[key] as Dictionary).w == w:
			(taken[key] as Dictionary).leaving = true


func tick(dt: float) -> void:
	for key: String in taken.keys():
		var e: Dictionary = taken[key]
		var w: Node3D = e.w as Node3D
		if w == null or not is_instance_valid(w):
			taken.erase(key)
			continue
		if not e.leaving:
			continue
		e.t = float(e.t) + dt
		var p: Vector2 = Vector2(w.global_position.x, w.global_position.z)
		if p.distance_to(e.pos) > LEAVE_DISTANCE or float(e.t) > LEAVE_TIME:
			taken.erase(key)
