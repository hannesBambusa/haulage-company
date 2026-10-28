class_name JackCarrier
extends WorkerCarrier
## The Jack operator: one worker with the orange hand pallet jack who puts
## INBOUND pallets away to ground-level slots only (rack level 1 or floor),
## since a jack cannot lift. The jack stays parked at the jack spot (the
## worker's rest spot, off the lanes) while idle; for a job the worker takes
## its handle, pushes the forks into the pallet, pumps it up slightly,
## pushes it to the slot, lowers it and pulls the jack out, then brings the
## jack back to the jack spot and lets go of it. 1.0 m/s, accel 1 m/s^2.
## Does no staff duties (the DutyPlanner leaves it out); the Staff panel
## lists it as "Jack operator".

const ROLE_TITLE: String = "Jack operator"

var worker_name: String = ""
var _parked_jack: bool = false


func setup(p_actor: WorkerActor, p_grid: StorageGrid, rest_spot: Vector3) -> void:
	super.setup(p_actor, p_grid, rest_spot)
	worker_name = String(p_actor.name).replace("Worker", "Worker ")
	label = worker_name + " (pallet jack)"
	move_speed = 1.0
	lane_speed = 0.7
	turn_speed = 0.8
	reverse_speed = 0.6
	accel = 1.0
	_make_jack()
	_park_jack()


## Put-away jobs the Rack forklift does not get: to ground level, on the jack.
func suits(p_job: CarryJob) -> bool:
	return p_job.kind == CarryJob.Kind.STORE and p_job.wants_worker() and not p_job.needs_lift()


func status_text() -> String:
	if job == null:
		return "Waiting at the jack spot" if _parked_jack else "Taking the jack back"
	var j: CarryJob = job as CarryJob
	return "Putting %s away to %s" % [j.unit.code, j.to_slot.label if j.to_slot != null else "?"]


func _make_jack() -> void:
	_anchor = Node3D.new()
	_anchor.name = "CarryAnchor"
	actor.add_child(_anchor)
	var s: Vector3 = actor.scale
	_anchor.scale = Vector3(1.0 / s.x, 1.0 / s.y, 1.0 / s.z)
	_jack = JACK.instantiate() as Node3D
	_jack.name = "PalletJack"
	_jack.position = Vector3(0.0, 0.0, JACK_Z)
	_anchor.add_child(_jack)


## Lets go of the jack: it stays where it stands (the jack spot).
func _park_jack() -> void:
	if _jack == null or _parked_jack:
		return
	var parent: Node = actor.get_parent()
	_jack.reparent(parent if parent != null else actor, true)
	_parked_jack = true


## Takes the jack's handle again (the worker stands at it).
func _take_jack() -> void:
	if _jack == null or not _parked_jack:
		return
	_jack.reparent(_anchor, false)
	_jack.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, JACK_Z))
	_parked_jack = false


func _begin() -> void:
	actor.begin_job()
	_sync_pose()
	if _anchor == null:
		_make_jack()
	_anchor.rotation = Vector3.ZERO
	_take_jack()
	_loaded_jack = false


func _finish() -> void:
	# the jack stays in hand until the jack spot
	if _anchor != null:
		_anchor.rotation = Vector3.ZERO
	actor.position.y = 0.0
	actor.rotation.x = 0.0


func _go_home() -> void:
	await super._go_home()
	if job == null and _pos.distance_to(_home_pos) < 0.5:
		_park_jack()
		actor.play_animation(&"Idle")


## Loaded, before pushing in: a rack L1 slot sits on the bottom beam, so the
## pallet is pumped up to just over it first (a floor slot needs nothing).
func _prepare_approach(slot: StorageSlot, loaded: bool) -> void:
	if not loaded or job == null or (job as CarryJob).unit.node == null:
		return
	var node: Node3D = (job as CarryJob).unit.node
	var want: float = slot.position.y + 0.03
	var start: float = node.global_position.y
	if want <= start + 0.005:
		return
	actor.play_animation(&"Idle")
	await _animate(maxf(0.4, (want - start) * 6.0), func(t: float) -> void:
		node.global_position.y = lerpf(start, want, t))


## At the slot: lower the pallet onto it (floor or beam), then let go.
func _place(j: CarryJob) -> void:
	actor.play_animation(&"Idle")
	var node: Node3D = j.unit.node
	var start: float = node.global_position.y
	var want: float = j.to_slot.position.y
	await _animate(0.6, func(t: float) -> void: node.global_position.y = lerpf(start, want, t))
	_set_down(node, j.to_slot)
	_loaded_jack = false
	await _wait(handover_time)


func _settled(j: CarryJob) -> void:
	var first: bool = not j.has_meta(&"settled")
	super._settled(j)
	if first and j.kind == CarryJob.Kind.STORE and not j.unit.history.is_empty():
		j.unit.history[j.unit.history.size() - 1]["agent"] = "Put away by " + label


func _on_move(moving: bool) -> void:
	if not moving:
		actor.play_animation(&"Idle")
	else:
		actor.play_animation(&"PushJack")
