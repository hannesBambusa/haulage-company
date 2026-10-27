class_name FirstPersonBody
extends CharacterBody3D
## The walker CameraRig rides in first person. A capsule on the ground plane:
## walks at walk_speed (run_speed while running), climbs slopes up to
## floor_max_angle and steps up to step_height, and is pushed out of anything
## that moves into it (trucks, forklifts) so it never ends up inside them.
## Origin = feet. Collision layer 0: nothing else ever hits it.
## CameraRig sets `wish` (world XZ direction, length <= 1) and `running`.

@export var walk_speed: float = 1.6
@export var run_speed: float = 4.0
@export var acceleration: float = 12.0
@export var gravity: float = 9.8
@export var radius: float = 0.3
@export var height: float = 2.1
@export var eye_height: float = 2.0
@export var step_height: float = 0.3
## Walkable slope. The dock ramp is 20 deg; the limit sits higher so the
## 39 deg bevel at the ramp foot and curb chamfers do not stop you.
@export_range(0.0, 60.0) var max_slope_deg: float = 42.0
@export var head_bob_enabled: bool = false
@export var head_bob_amplitude: float = 0.03
@export var head_bob_stride: float = 1.4  ## metres per bob cycle

var active: bool = false:
	set(value):
		active = value
		velocity = Vector3.ZERO
		_bob_phase = 0.0
var wish: Vector3 = Vector3.ZERO
var running: bool = false

var _prev_feet: Vector3
var _cur_feet: Vector3
var _bob_phase: float = 0.0


func _ready() -> void:
	collision_layer = 0
	top_level = true
	floor_max_angle = deg_to_rad(max_slope_deg)
	floor_snap_length = step_height + 0.05
	floor_stop_on_slope = true
	floor_block_on_wall = true
	safe_margin = 0.01
	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height
	var cs: CollisionShape3D = CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0.0, height * 0.5, 0.0)
	add_child(cs)
	_prev_feet = global_position
	_cur_feet = global_position


## Puts the feet at `feet` with no motion history.
func teleport(feet: Vector3) -> void:
	global_position = feet
	velocity = Vector3.ZERO
	_prev_feet = feet
	_cur_feet = feet


## Eye position between the last two physics steps (smooth at any frame rate).
func eye_position() -> Vector3:
	var f: float = Engine.get_physics_interpolation_fraction()
	var feet: Vector3 = _prev_feet.lerp(_cur_feet, f)
	var bob: float = 0.0
	if head_bob_enabled:
		bob = sin(_bob_phase * TAU) * head_bob_amplitude
	return feet + Vector3(0.0, eye_height + bob, 0.0)


## True when a capsule with its feet at `feet` overlaps nothing in `mask`.
func is_free_at(feet: Vector3, mask: int) -> bool:
	var q: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, feet + Vector3(0.0, height * 0.5 + 0.02, 0.0))
	q.collision_mask = mask
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _physics_process(delta: float) -> void:
	_prev_feet = _cur_feet
	if not active:
		_cur_feet = global_position
		return
	_depenetrate()
	var target_speed: float = run_speed if running else walk_speed
	var want: Vector3 = wish.limit_length(1.0) * target_speed
	var horiz: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	horiz = horiz.move_toward(want, acceleration * target_speed * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	var start: Vector3 = global_position
	var planned: Vector3 = Vector3(velocity.x, 0.0, velocity.z) * delta
	var was_on_floor: bool = is_on_floor()
	move_and_slide()
	if was_on_floor and planned.length() > 1e-4:
		_try_step(start, planned)
	_depenetrate()
	if head_bob_enabled and is_on_floor():
		_bob_phase = fmod(_bob_phase + Vector3(velocity.x, 0.0, velocity.z).length() * delta / head_bob_stride, 1.0)
	_cur_feet = global_position


## Climbs a ledge up to step_height when move_and_slide fell short of `planned`.
func _try_step(start: Vector3, planned: Vector3) -> void:
	var done: Vector3 = global_position - start
	done.y = 0.0
	var dir: Vector3 = planned.normalized()
	var remaining: float = planned.length() - done.dot(dir)
	if remaining < planned.length() * 0.3:
		return
	var saved: Transform3D = global_transform
	move_and_collide(Vector3.UP * step_height)  # a ceiling may limit the lift
	var lifted: float = global_position.y - saved.origin.y
	if lifted < 0.05:
		global_transform = saved
		return
	var fwd: KinematicCollision3D = move_and_collide(dir * maxf(remaining, radius * 0.5))
	var moved: float = Vector3(global_position.x - saved.origin.x, 0.0, global_position.z - saved.origin.z).length()
	var down: KinematicCollision3D = move_and_collide(Vector3.DOWN * (lifted + 0.05))
	var landed: bool = down != null and down.get_normal().angle_to(Vector3.UP) <= floor_max_angle
	var blocked: bool = fwd != null and moved < radius * 0.25
	if blocked or not landed or global_position.y <= saved.origin.y + 0.01:
		global_transform = saved


## Pushes the capsule out of anything overlapping it (a truck moving into it).
func _depenetrate() -> void:
	for i: int in 4:
		var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
		params.from = global_transform
		params.motion = Vector3.ZERO
		params.margin = safe_margin
		params.recovery_as_collision = true
		var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
		if not PhysicsServer3D.body_test_motion(get_rid(), params, result):
			return
		var push: Vector3 = result.get_travel()
		if push.length() < 1e-4:
			return
		global_position += push
