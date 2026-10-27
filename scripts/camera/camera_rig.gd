@tool
class_name CameraRig
extends Node3D
## Terminal camera: one continuous zoom from the strategic view down to first
## person at a worker's eye height.
##
## Zoom: a single value z in [0, 1] (wheel, trackpad pinch, two-finger scroll),
## smoothed with exponential damping. CameraZoomCurve maps it to distance,
## pitch, FOV and target height (tilt-zoom: the view flattens and widens as you
## get close). z = 1 is the strategic view, z = 0 is first person.
##
## Orbit (z > 0): WASD/arrows or middle/right mouse drag pan (speed scales with
## distance), Q/E rotate, the target stays inside pan_bounds. A sphere cast
## keeps the camera out of walls, vehicles and the ground at every zoom.
##
## First person (zoom all the way in): WASD/arrows walk (Shift runs), Q/E turn,
## hold the right mouse button to look, F captures the mouse for look (Esc
## releases), wheel out to leave; the orbit view comes back centred on where
## you stand. F in the orbit view zooms straight into first person.
## Left click is never consumed, so pallet picking keeps working.

signal first_person_changed(active: bool)

@export var reference_view: CameraView:
	set(value):
		reference_view = value
		if is_node_ready():
			snap_to_reference()
## Zoom curve. Its far pitch and FOV are taken from reference_view.
@export var zoom_curve: CameraZoomCurve
@export var pan_speed: float = 0.6  ## Fraction of the distance per second.
## Pan and drag speeds never drop below what this distance would give.
@export var min_pan_distance: float = 3.0
@export var drag_speed: float = 1.0
@export var rotate_speed_deg: float = 90.0
@export var zoom_step: float = 0.03  ## z change per wheel notch.
@export var pinch_sensitivity: float = 0.8
@export var pan_gesture_sensitivity: float = 0.01
@export var smoothing: float = 10.0
## Pan limits for the target on the XZ plane.
@export var pan_bounds: Rect2 = Rect2(-45.0, -40.0, 80.0, 80.0)

@export_group("First person")
## The smoothed zoom has to be this close to 0 (with the goal at 0) to switch.
@export var fp_enter_z: float = 0.004
@export var look_sensitivity_deg: float = 0.12  ## Degrees per pixel.
@export var look_pitch_limit_deg: float = 80.0
## How far around the focus the walker may be placed to find free floor.
@export var spawn_search_radius: float = 3.0

@export_group("Collision")
## Layers the walker and the camera cast collide with: 1 (level -colonly
## colliders), 16 (camera proxies, see CameraCollisionProxies) and 20 (cargo).
@export_flags_3d_physics var collision_mask: int = 1 | (1 << 15) | (1 << 19)
@export_flags_3d_physics var proxy_layer: int = 1 << 15
@export var camera_radius: float = 0.2
@export var min_camera_height: float = 0.3
## Proxies are built and kept in sync below this zoom.
@export var proxy_zoom: float = 0.75
## Rate the camera eases back out after an obstacle stops blocking it.
@export var collision_recover: float = 6.0
## Below this zoom (about 19 m out) obstacles between the focus and the camera
## pull it in; above it only the camera position itself is kept free.
@export var line_of_sight_z: float = 0.65
@export var push_out_step: float = 0.5

## Overrides keyboard movement when non-zero (tests, tools). x right, y back.
var scripted_move: Vector2 = Vector2.ZERO

var _curve: CameraZoomCurve
var _z: float = 1.0
var _goal_z: float = 1.0
## Focus point: x/z on the ground, y = floor height under it.
var _target: Vector3
var _goal_target: Vector3
var _yaw: float
var _goal_yaw: float
var _base_y: float = 0.0  ## Ground height of the strategic target.
var _pitch_offset: float = 0.0  ## Leftover first-person look pitch, decays.
var _look_pitch: float = 0.0
var _fp: bool = false
var _dragging: bool = false
var _looking: bool = false
var _cam_d: float = -1.0
var _recovering: bool = false
var _cast_shape: SphereShape3D

@onready var _camera: Camera3D = $Camera3D
var _body: FirstPersonBody
var _proxies: CameraCollisionProxies
var _tuning: CameraRenderTuning


func _ready() -> void:
	add_to_group(&"camera_rig")
	_curve = zoom_curve.duplicate() as CameraZoomCurve if zoom_curve != null else CameraZoomCurve.new()
	if not Engine.is_editor_hint():
		_cast_shape = SphereShape3D.new()
		_cast_shape.radius = camera_radius
		_body = FirstPersonBody.new()
		_body.name = "FirstPersonBody"
		_body.collision_mask = collision_mask
		_body.eye_height = _curve.eye_height
		add_child(_body)
		_proxies = CameraCollisionProxies.new()
		_proxies.name = "CollisionProxies"
		_proxies.proxy_layer = proxy_layer
		add_child(_proxies)
		_tuning = CameraRenderTuning.new()
		_tuning.name = "RenderTuning"
		add_child(_tuning)
		_tuning.bind(get_parent())
	snap_to_reference()
	set_process_unhandled_input(not Engine.is_editor_hint())
	set_process_input(not Engine.is_editor_hint())


func _exit_tree() -> void:
	if _tuning != null:
		_tuning.restore()
	if _fp and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Jumps straight to reference_view with no smoothing.
func snap_to_reference() -> void:
	var v: CameraView = reference_view if reference_view != null else CameraView.new()
	if _curve == null:
		_curve = CameraZoomCurve.new()
	_curve.pitch_far_deg = v.pitch_deg
	_curve.fov_far_deg = v.fov_deg
	if _fp:
		_leave_first_person()
	_pitch_offset = 0.0
	_base_y = v.target.y
	_goal_target = v.target
	_target = _goal_target
	_goal_yaw = deg_to_rad(v.yaw_deg)
	_yaw = _goal_yaw
	_z = _curve.z_for_distance(v.distance)
	_goal_z = _z
	_cam_d = -1.0
	_apply(0.0)


# --- Public API (tools, tests) ------------------------------------------------

## Current smoothed zoom, 0 = first person, 1 = strategic.
func get_zoom() -> float:
	return _z


func get_zoom_curve() -> CameraZoomCurve:
	return _curve


## Sets the zoom goal; instant also jumps the smoothed value (and into or out
## of first person right away).
func set_zoom(z: float, instant: bool = false) -> void:
	_set_goal_zoom(z)
	if instant:
		_z = _goal_z
		_target = _goal_target
		_update_mode()
		_cam_d = -1.0
		_apply(0.0)


## Moves the focus to `point` (x/z; y is the floor height there) and optionally
## sets the yaw. Instant skips smoothing.
func focus_on(point: Vector3, yaw_deg: float = NAN, instant: bool = false) -> void:
	_goal_target = _clamp_to_bounds(point)
	if not is_nan(yaw_deg):
		_goal_yaw = deg_to_rad(yaw_deg)
	if instant:
		_target = _goal_target
		_yaw = _goal_yaw
		if _fp:
			_body.teleport(_goal_target)
		_cam_d = -1.0
		_apply(0.0)


## First-person look pitch, degrees down (negative looks up).
func set_look_pitch_deg(deg: float) -> void:
	var lim: float = deg_to_rad(look_pitch_limit_deg)
	_look_pitch = clampf(deg_to_rad(deg), -lim, lim)


func is_first_person() -> bool:
	return _fp


func get_first_person_body() -> FirstPersonBody:
	return _body


func get_collision_proxies() -> CameraCollisionProxies:
	return _proxies


## Camera-to-target distance after collision (0 in first person).
func get_camera_distance() -> float:
	return 0.0 if _fp else maxf(_cam_d, 0.0)


# --- Frame update -------------------------------------------------------------

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var move: Vector2 = _move_input()
	var turn: float = Input.get_axis(&"cam_rotate_left", &"cam_rotate_right")
	_goal_yaw += turn * deg_to_rad(rotate_speed_deg) * delta
	if not _fp and move != Vector2.ZERO:
		_pan_by(move * pan_speed * _pan_distance() * delta)
	var t: float = 1.0 - exp(-smoothing * delta)
	_z = lerpf(_z, _goal_z, t)
	if absf(_z - _goal_z) < 1e-4:
		_z = _goal_z
	_target = _target.lerp(_goal_target, t)
	_yaw = lerp_angle(_yaw, _goal_yaw, t)
	_pitch_offset = lerpf(_pitch_offset, 0.0, t)
	_update_mode()
	_apply(delta)


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not _fp:
		return
	var move: Vector2 = _move_input()
	var right: Vector3 = Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var back: Vector3 = Vector3(sin(_yaw), 0.0, cos(_yaw))
	_body.wish = (right * move.x + back * move.y).limit_length(1.0)
	_body.running = Input.is_action_pressed(&"cam_run")


func _move_input() -> Vector2:
	if scripted_move != Vector2.ZERO:
		return scripted_move
	return Input.get_vector(&"cam_pan_left", &"cam_pan_right", &"cam_pan_up", &"cam_pan_down")


## Switches into or out of first person, and builds/activates the proxies.
func _update_mode() -> void:
	if _proxies != null:
		var close: bool = _fp or minf(_z, _goal_z) < proxy_zoom
		if close and not _proxies.is_built():
			_proxies.build(get_tree().current_scene if get_tree().current_scene != null else get_parent())
		_proxies.active = close
	if not _fp and _goal_z <= 0.0 and _z <= fp_enter_z and _body != null:
		_enter_first_person()
	elif _fp and _goal_z > 0.0:
		_leave_first_person()
	if not _fp and _curve.eye_weight(_z) <= 0.0:
		_goal_target.y = _base_y  # floor height only matters close up


func _enter_first_person() -> void:
	_z = 0.0
	_fp = true
	_look_pitch = deg_to_rad(_curve.pitch_deg(0.0)) + _pitch_offset
	_pitch_offset = 0.0
	var feet: Vector3 = _find_free_feet(Vector3(_target.x, _target.y, _target.z))
	_body.teleport(feet)
	_body.active = true
	_dragging = false
	first_person_changed.emit(true)


func _leave_first_person() -> void:
	_fp = false
	_body.active = false
	_body.wish = Vector3.ZERO
	var feet: Vector3 = _body.global_position
	_goal_target = _clamp_to_bounds(feet)
	_goal_target.y = feet.y
	_target = _goal_target
	_pitch_offset = _look_pitch - deg_to_rad(_curve.pitch_deg(_z))
	_looking = false
	_cam_d = -1.0
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	first_person_changed.emit(false)


func _apply(delta: float) -> void:
	if _camera == null:
		return
	var pitch: float = _look_pitch if _fp else deg_to_rad(_curve.pitch_deg(_z)) + _pitch_offset
	var basis: Basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, -pitch)
	var origin: Vector3
	if _fp:
		origin = _body.eye_position()
	else:
		var w: float = _curve.eye_weight(_z)
		var focus: Vector3 = Vector3(_target.x, lerpf(_base_y, _target.y + _curve.eye_height, w), _target.z)
		var d: float = _collided_distance(focus, basis.z, _curve.distance(_z), delta)
		origin = focus + basis.z * d
		if not Engine.is_editor_hint():
			origin.y = maxf(origin.y, _base_y + min_camera_height)
	_camera.global_transform = Transform3D(basis, origin)
	_camera.fov = _curve.fov_deg(_z)
	_camera.near = _curve.near_plane(_z)
	if _tuning != null:
		_tuning.apply(_curve.closeness(_z))


## Distance along `dir` from `focus` the camera can sit at, eased back out
## after an obstacle clears so the view never pops.
func _collided_distance(focus: Vector3, dir: Vector3, desired: float, delta: float) -> float:
	var clear: float = _cast_clear(focus, dir, desired)
	if _cam_d < 0.0 or delta <= 0.0:
		_cam_d = clear
		_recovering = clear < desired
	elif clear < desired - 1e-3:
		_cam_d = clear if clear < _cam_d else lerpf(_cam_d, clear, 1.0 - exp(-collision_recover * delta))
		_recovering = true
	elif _recovering:
		_cam_d = lerpf(_cam_d, clear, 1.0 - exp(-collision_recover * delta))
		if absf(_cam_d - clear) < 0.01:
			_recovering = false
			_cam_d = clear
	else:
		_cam_d = clear
	return _cam_d


func _cast_clear(focus: Vector3, dir: Vector3, desired: float) -> float:
	if Engine.is_editor_hint() or _cast_shape == null or desired < 0.01 or not is_inside_tree():
		return desired
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var q: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	q.shape = _cast_shape
	q.collision_mask = _active_mask()
	# Zoomed out, things between the focus and the camera (trees, walls,
	# canopies, cargo) must not pull the view in: only keep the camera itself
	# out of geometry, stepping toward the focus until it is free.
	if _z >= line_of_sight_z:
		var d: float = desired
		while d > 0.0:
			q.transform = Transform3D(Basis.IDENTITY, focus + dir * d)
			if space.intersect_shape(q, 1).is_empty():
				return d
			d -= push_out_step
		return 0.0
	q.transform = Transform3D(Basis.IDENTITY, focus)
	# Whatever the focus itself sits in (the ground, a rack) does not block.
	var skip: Array[RID] = []
	for hit: Dictionary in space.intersect_shape(q, 16):
		skip.append(hit.rid)
	q.exclude = skip
	q.motion = dir * desired
	var frac: PackedFloat32Array = space.cast_motion(q)
	if frac.is_empty() or frac[0] >= 1.0:
		return desired
	return maxf(desired * frac[0] - 0.02, 0.0)


func _active_mask() -> int:
	if _proxies != null and _proxies.active:
		return collision_mask
	return collision_mask & ~proxy_layer


## Feet position for the walker near `focus`: on the floor below it, moved to
## the nearest spot where the capsule fits.
func _find_free_feet(focus: Vector3) -> Vector3:
	var mask: int = collision_mask
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var best: Vector3 = Vector3(focus.x, _base_y, focus.z)
	var rings: int = int(ceil(spawn_search_radius / 0.4))
	for ring: int in rings + 1:
		var r: float = ring * 0.4
		var steps: int = 1 if ring == 0 else 8 + ring * 4
		for i: int in steps:
			var a: float = TAU * i / steps
			var p: Vector3 = focus + Vector3(cos(a), 0.0, sin(a)) * r
			var from: Vector3 = Vector3(p.x, focus.y + _curve.eye_height, p.z)
			var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (_curve.eye_height + 3.0), mask)
			var hit: Dictionary = space.intersect_ray(ray)
			var feet: Vector3 = Vector3(p.x, (hit.position as Vector3).y if not hit.is_empty() else _base_y, p.z)
			if _body.is_free_at(feet, mask):
				return feet
	return best


# --- Input --------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Esc always frees a captured mouse; the event still reaches the HUD.
	if event.is_action_pressed(&"ui_cancel") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"cam_zoom_in"):
		_zoom_by(-zoom_step * _wheel_factor(event))
	elif event.is_action_pressed(&"cam_zoom_out"):
		_zoom_by(zoom_step * _wheel_factor(event))
	elif event.is_action_pressed(&"cam_fp_toggle"):
		_toggle_capture()
	var mg: InputEventMagnifyGesture = event as InputEventMagnifyGesture
	if mg != null and mg.factor > 0.0:
		_zoom_by(-log(mg.factor) * pinch_sensitivity)
	# Trackpad two-finger moves arrive as pan gestures, also during a
	# two-finger click-drag (right drag) and as inertia after the swipe. Only
	# a mostly vertical swipe with no button held zooms, capped per event.
	var pg: InputEventPanGesture = event as InputEventPanGesture
	if pg != null and not (_dragging or _looking) and Input.get_mouse_button_mask() == 0 \
			and absf(pg.delta.y) > absf(pg.delta.x) * 2.0:
		_zoom_by(clampf(pg.delta.y * pan_gesture_sensitivity, -zoom_step, zoom_step))
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null:
		if _fp:
			if mb.button_index == MOUSE_BUTTON_RIGHT:
				_looking = mb.pressed
		elif mb.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			_dragging = mb.pressed
	var mm: InputEventMouseMotion = event as InputEventMouseMotion
	if mm == null:
		return
	if _fp:
		if _looking or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_look_by(mm.relative)
	elif _dragging:
		var px_to_world: float = _pan_distance() * drag_speed / maxf(get_viewport().get_visible_rect().size.y, 1.0)
		_pan_by(-mm.relative * px_to_world)


func _wheel_factor(event: InputEvent) -> float:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.factor > 0.0:
		return mb.factor
	return 1.0


func _zoom_by(dz: float) -> void:
	_set_goal_zoom(_goal_z + dz)


func _set_goal_zoom(z: float) -> void:
	var was: float = _goal_z
	_goal_z = clampf(z, 0.0, 1.0)
	if _goal_z <= 0.0 and was > 0.0 and not _fp:
		_prepare_first_person_spot()


## Steers the focus to free floor before arriving in first person, so the
## walker does not pop sideways out of a rack at the last moment.
func _prepare_first_person_spot() -> void:
	if _body == null or not is_inside_tree():
		return
	if _proxies != null and not _proxies.is_built():
		_proxies.build(get_tree().current_scene if get_tree().current_scene != null else get_parent())
	var feet: Vector3 = _find_free_feet(Vector3(_goal_target.x, _goal_target.y, _goal_target.z))
	_goal_target = _clamp_to_bounds(feet)
	_goal_target.y = feet.y


func _toggle_capture() -> void:
	if not _fp:
		_set_goal_zoom(0.0)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _look_by(px: Vector2) -> void:
	var k: float = deg_to_rad(look_sensitivity_deg)
	_yaw -= px.x * k
	_goal_yaw = _yaw
	set_look_pitch_deg(rad_to_deg(_look_pitch + px.y * k))


func _pan_distance() -> float:
	return maxf(_curve.distance(_goal_z), min_pan_distance)


## Moves the goal target in screen-aligned ground directions (x right, y down).
func _pan_by(screen_delta: Vector2) -> void:
	var right: Vector3 = Vector3(cos(_goal_yaw), 0.0, -sin(_goal_yaw))
	var back: Vector3 = Vector3(sin(_goal_yaw), 0.0, cos(_goal_yaw))
	_goal_target = _clamp_to_bounds(_goal_target + right * screen_delta.x + back * screen_delta.y)


func _clamp_to_bounds(p: Vector3) -> Vector3:
	return Vector3(
		clampf(p.x, pan_bounds.position.x, pan_bounds.end.x),
		p.y,
		clampf(p.z, pan_bounds.position.y, pan_bounds.end.y))
