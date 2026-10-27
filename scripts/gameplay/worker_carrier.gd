class_name WorkerCarrier
extends CarryAgent
## A level worker (WorkerActor) borrowed for carry jobs: walks a pallet jack,
## pushing it from the handle end. The jack sits 1.05 m in front of the
## worker and the pallet rides on its forks. Loads pickup trucks: OUTBOUND ->
## up the dock ramp -> trailer slot, and pulls the jack back out. Ground-level
## slots only. Walks at 1.3 m/s with the walk cycle matched to the speed;
## with the jack the pair pivots slowly about the jack's load wheels.
## The jack and its load tilt with the ramp.

const JACK: PackedScene = preload("res://assets/models/pallet_jack.glb")
const JACK_Z: float = -1.05
## Pallet bottom above the floor on the raised jack.
const LOAD_Y: float = 0.09
## Jack length used to tilt it on the ramp (front wheels ahead of the worker).
const JACK_SPAN: float = 1.7
## Load wheels of the jack, ahead of the worker: the pivot when turning.
const LOAD_WHEELS_Z: float = -1.6
const PERSON_HALF: float = 0.28

var actor: WorkerActor = null
var _anchor: Node3D = null
var _jack: Node3D = null
var _loaded_jack: bool = false


func setup(p_actor: WorkerActor, p_grid: StorageGrid, rest_spot: Vector3) -> void:
	actor = p_actor
	body = p_actor
	grid = p_grid
	label = String(p_actor.name).replace("Worker", "Worker ")
	move_speed = 1.3
	lane_speed = 0.8
	turn_speed = 1.0
	reverse_speed = 0.7
	accel = 1.0
	min_turn_radius = 0.0
	pivot_rate = 1.6
	load_heel = 0.62
	p_actor.mover = self
	# job workers do not patrol: idle, they stand at their rest spot
	p_actor.patrol_enabled = false
	p_actor.position = Vector3(rest_spot.x, p_actor.position.y, rest_spot.z)
	_sync_pose()
	set_home_here()


func suits(p_job: CarryJob) -> bool:
	return p_job.wants_worker() and not p_job.needs_lift()


func traffic_kind() -> int:
	return Traffic.Kind.PERSON


func footprints_at(p: Vector2, yaw_at: float, bare: bool = false) -> Array:
	var out: Array = [FootprintBox.local_span(p, yaw_at, -PERSON_HALF, PERSON_HALF, PERSON_HALF)]
	if _jack != null and not bare:
		out.append(FootprintBox.local_span(p, yaw_at, -(load_heel + 1.25), -0.3, 0.42))
	return out


func _begin() -> void:
	actor.begin_job()
	_sync_pose()
	_anchor = Node3D.new()
	_anchor.name = "CarryAnchor"
	actor.add_child(_anchor)
	# undo the worker's scale so the jack and pallet keep their real size
	var s: Vector3 = actor.scale
	_anchor.scale = Vector3(1.0 / s.x, 1.0 / s.y, 1.0 / s.z)
	_jack = JACK.instantiate() as Node3D
	_jack.position = Vector3(0.0, 0.0, JACK_Z)
	_anchor.add_child(_jack)
	_loaded_jack = false


func _pivot_point() -> Vector2:
	if _jack == null:
		return _pos
	var f: Vector3 = _forward()
	return _pos + Vector2(f.x, f.z) * -LOAD_WHEELS_Z


func _hold(held_yaw: float) -> Transform3D:
	var depth: float = CarryAgent._depth_for(held_yaw)
	return Transform3D(Basis(Vector3.UP, held_yaw), Vector3(0.0, LOAD_Y, -(load_heel + depth * 0.5 + 0.03)))


func _pick(j: CarryJob) -> void:
	actor.play_animation(&"Idle")
	await _wait(handover_time)
	# pumping the handle raises the forks under the pallet
	var node: Node3D = j.unit.node
	node.reparent(_anchor, true)
	var start: Vector3 = node.position
	await _animate(0.6, func(t: float) -> void: node.position = start + Vector3(0.0, LOAD_Y * t, 0.0))
	_loaded_jack = true


func _attach_now(j: CarryJob) -> void:
	var held: float = _held_yaw(j.unit.node, _anchor)
	j.unit.node.reparent(_anchor, false)
	j.unit.node.transform = _hold(held)
	_loaded_jack = true


func hold_transform(held_yaw: float) -> Transform3D:
	return _hold(held_yaw)


func _place(j: CarryJob) -> void:
	actor.play_animation(&"Idle")
	var node: Node3D = j.unit.node
	var start: Vector3 = node.position
	await _animate(0.6, func(t: float) -> void: node.position = start - Vector3(0.0, LOAD_Y * t, 0.0))
	_set_down(node, j.to_slot)
	_loaded_jack = false
	await _wait(handover_time)


func _finish() -> void:
	if _anchor != null:
		_anchor.queue_free()
		_anchor = null
		_jack = null
	actor.position.y = 0.0
	actor.rotation.x = 0.0


func _go_home() -> void:
	actor.begin_job()
	await super._go_home()
	if job == null:
		actor.end_job()


func _after_pose() -> void:
	actor.set_walk_speed(speed)
	if _anchor == null:
		return
	# the worker stays upright; the jack and its load follow the ramp
	var pos: Vector3 = body.global_position
	var fwd: Vector3 = _forward()
	var h0: float = grid.ground_height(pos)
	var h1: float = grid.ground_height(pos + fwd * JACK_SPAN)
	_anchor.rotation = Vector3(atan2(h1 - h0, JACK_SPAN), 0.0, 0.0)


func _on_move(moving: bool) -> void:
	if not moving:
		actor.play_animation(&"Idle")
	elif _loaded_jack or _jack != null:
		actor.play_animation(&"Carry")
	else:
		actor.play_animation(&"Walk")
