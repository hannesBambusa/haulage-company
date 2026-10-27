extends Node3D
## Visual-only unloading shuttle: a worker pushing a pallet jack between a dock
## and the INBOUND zone while that dock is UNLOADING. Carries a pallet on the
## way in, returns empty, and parks at the home end when the dock is idle.
## Children: the pallet jack, a load (pallet on the forks) and a worker*.glb
## instance, all facing -Z. Route points are in the parent's space.
## While the dock is LOADING a pickup it shuttles from outbound_point to the
## dock instead (CargoFlow sets outbound_point at runtime).

@export var dock_id: int = 1
## Shuttle stop next to the parked trailer.
@export var dock_point: Vector3 = Vector3.ZERO
## Drop-off point in the INBOUND zone; also where it waits when idle.
@export var drop_point: Vector3 = Vector3(0.0, 0.0, -10.0)
## Optional bend so the route stays on the walkway.
@export var via_point: Vector3 = Vector3.INF
## Pick-up point in the OUTBOUND zone for pickups. INF = use drop_point.
@export var outbound_point: Vector3 = Vector3.INF
@export var speed: float = 1.4
@export var turn_speed: float = 6.0
@export var pause_time: float = 1.2
@export var load_path: NodePath
@export var worker_path: NodePath
@export var move_animation: StringName = &"Walk"
@export var idle_animation: StringName = &"Idle"

var _dock: Dock
var _active: bool = false
var _route: PackedVector3Array = PackedVector3Array()
var _index: int = 0
var _wait: float = 0.0
var _load: Node3D
var _anim: AnimationPlayer
## Where the shuttle picks a pallet up and where it puts it down this cycle.
var _load_at: Vector3 = Vector3.ZERO
var _unload_at: Vector3 = Vector3.ZERO


func _ready() -> void:
	add_to_group(&"unload_shuttles")
	_load = get_node_or_null(load_path) as Node3D
	var worker: Node = get_node_or_null(worker_path)
	if worker != null:
		_anim = worker.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		for anim_name: StringName in [move_animation, idle_animation]:
			if _anim.has_animation(anim_name):
				_anim.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
	position = drop_point
	_set_loaded(false)
	_play(idle_animation)
	_bind.call_deferred()


## The physical unload / load flow (forklifts and pallet-jack workers) took
## over; CargoFlow retires the shuttle so nothing fakes a transfer.
func retire() -> void:
	_route = PackedVector3Array()
	_dock = null
	visible = false
	set_process(false)


func _bind() -> void:
	for node: Node in get_tree().get_nodes_in_group(&"docks"):
		var dock: Dock = node as Dock
		if dock != null and dock.dock_id == dock_id:
			_dock = dock
	if _dock == null:
		push_warning("UnloadShuttle: no dock %d" % dock_id)
		return
	if not is_processing():
		return
	_dock.state_changed.connect(_on_dock_state_changed)
	_on_dock_state_changed(_dock.state)


func _on_dock_state_changed(state: Dock.State) -> void:
	if not is_processing():
		return
	var active: bool = state == Dock.State.UNLOADING or state == Dock.State.LOADING
	if active == _active:
		return
	_active = active
	_route = PackedVector3Array()
	if _active:
		# loop: zone -> dock -> zone, loaded on the leg towards _unload_at
		var zone: Vector3 = drop_point
		if state == Dock.State.LOADING and outbound_point != Vector3.INF:
			zone = outbound_point
		_load_at = dock_point if state == Dock.State.UNLOADING else zone
		_unload_at = zone if state == Dock.State.UNLOADING else dock_point
		_route.append(zone)
		if via_point != Vector3.INF:
			_route.append(via_point)
		_route.append(dock_point)
		if via_point != Vector3.INF:
			_route.append(via_point)
		_index = 1 if position.distance_to(zone) < 0.1 else 0
	else:
		_route.append(drop_point)
		_index = 0
	_wait = 0.0
	_play(move_animation)


func _process(delta: float) -> void:
	if _route.is_empty() or GameState.paused:
		return
	var dt: float = delta * float(GameState.speed)
	if _wait > 0.0:
		_wait -= dt
		if _wait <= 0.0:
			_play(move_animation)
		return
	var goal: Vector3 = _route[_index]
	var to_goal: Vector3 = goal - position
	to_goal.y = 0.0
	var step: float = speed * dt
	if to_goal.length() > step:
		position += to_goal.normalized() * step
		var want: float = atan2(-to_goal.x, -to_goal.z)
		rotation.y = lerp_angle(rotation.y, want, 1.0 - exp(-turn_speed * dt))
		return
	position = goal
	if not _active:
		_route = PackedVector3Array()
		_play(idle_animation)
		return
	if goal.is_equal_approx(_load_at):
		_set_loaded(true)
		_wait = pause_time
		_play(idle_animation)
	elif goal.is_equal_approx(_unload_at):
		_set_loaded(false)
		_wait = pause_time
		_play(idle_animation)
	_index = (_index + 1) % _route.size()


func _set_loaded(loaded: bool) -> void:
	if _load != null:
		_load.visible = loaded


func _play(anim_name: StringName) -> void:
	if _anim != null and _anim.has_animation(anim_name):
		_anim.play(anim_name, 0.25)
