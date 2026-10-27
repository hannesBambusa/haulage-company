extends SceneTree
## Headless test for CameraRig zoom and first person.
## Godot --headless --path . --script res://scripts/camera/test_camera_zoom.gd [-- --reference_state]
## Checks: reference framing unchanged; z sweep 1 -> 0 -> 1 has monotonic
## distance and pitch, eye height at z = 0, no NaN, camera never inside a
## collider or below 0.3 m; orbit cast near a wall; first-person walker blocked
## by a wall, climbs the dock 1 ramp (and walks into the trailer when one is
## parked there), and is pushed by a moving body instead of being entered.

const FOCUS: Vector3 = Vector3(-7.0, 0.0, -10.0)
const RAMP_START: Vector3 = Vector3(-4.35, 0.0, -5.2)

var _fails: int = 0
var _rig: CameraRig


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		_fails += 1
		print("FAIL ", what)


func _frames(n: int) -> void:
	for i: int in n:
		await physics_frame


func _run() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	_rig = get_first_node_in_group(&"camera_rig") as CameraRig
	if _rig == null:
		print("FAIL no CameraRig")
		quit(1)
		return
	_rig.set_process(false)  # the test drives the rig; no keyboard smoothing
	_test_reference()
	_rig.focus_on(FOCUS, 0.0, true)
	_rig.set_zoom(0.7, true)  # builds the collision proxies
	await _frames(3)
	print("proxies: ", _rig.get_collision_proxies().proxy_count())
	await _test_sweep()
	await _test_wall_cast()
	await _test_wall_walk()
	await _test_ramp()
	await _test_push()
	_rig.snap_to_reference()
	_test_reference()
	print("RESULT ", "OK" if _fails == 0 else "%d FAILED" % _fails)
	quit(0 if _fails == 0 else 1)


## The reference framing must come out exactly as the old orbit math gave it.
func _test_reference() -> void:
	_rig.snap_to_reference()
	var v: CameraView = _rig.reference_view
	var cam: Camera3D = _rig.get_node("Camera3D") as Camera3D
	var basis: Basis = Basis(Vector3.UP, deg_to_rad(v.yaw_deg)) * Basis(Vector3.RIGHT, -deg_to_rad(v.pitch_deg))
	var want: Transform3D = Transform3D(basis, v.target + basis.z * v.distance)
	var err: float = cam.global_transform.origin.distance_to(want.origin)
	var berr: float = (cam.global_transform.basis.z - want.basis.z).length()
	_check(err < 1e-3 and berr < 1e-5, "reference framing (origin err %.6f m, basis err %.7f)" % [err, berr])
	_check(is_equal_approx(cam.fov, v.fov_deg) and is_equal_approx(cam.near, 0.5), "reference fov %.2f near %.2f" % [cam.fov, cam.near])


func _cam() -> Camera3D:
	return _rig.get_node("Camera3D") as Camera3D


func _bad(v: Vector3) -> bool:
	return is_nan(v.x) or is_nan(v.y) or is_nan(v.z) or is_inf(v.x) or is_inf(v.y) or is_inf(v.z)


## Camera point overlaps nothing, has line of sight to `focus`, is above 0.3 m.
func _camera_ok(focus: Vector3, label: String) -> bool:
	var cam: Camera3D = _cam()
	var p: Vector3 = cam.global_position
	if _bad(p) or _bad(cam.global_transform.basis.z):
		print("  NaN at ", label)
		return false
	if p.y < 0.3:
		print("  below 0.3 m at ", label, " y=", p.y)
		return false
	var space: PhysicsDirectSpaceState3D = cam.get_world_3d().direct_space_state
	var q: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	var s: SphereShape3D = SphereShape3D.new()
	s.radius = 0.05
	q.shape = s
	q.transform = Transform3D(Basis.IDENTITY, p)
	q.collision_mask = _rig.collision_mask
	var hits: Array[Dictionary] = space.intersect_shape(q, 4)
	if not hits.is_empty():
		print("  inside ", (hits[0].collider as Node).get_path(), " at ", label)
		return false
	if focus.distance_to(p) > 0.05:
		# Start just above the floor: a focus on the ground touches the ground plane.
		var from: Vector3 = focus + Vector3.UP * 0.05
		var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, p, _rig.collision_mask)
		ray.hit_from_inside = false
		var hit: Dictionary = space.intersect_ray(ray)
		if not hit.is_empty():
			print("  no line of sight (", (hit.collider as Node).get_path(), ") at ", label)
			return false
	return true


func _focus_point() -> Vector3:
	var c: CameraZoomCurve = _rig.get_zoom_curve()
	var z: float = _rig.get_zoom()
	return Vector3(FOCUS.x, c.eye_height * c.eye_weight(z), FOCUS.z)


func _test_sweep() -> void:
	var curve: CameraZoomCurve = _rig.get_zoom_curve()
	var steps: int = 100
	var prev_d: float = INF
	var prev_p: float = INF
	var mono: bool = true
	var cams_ok: bool = true
	for i: int in steps + 1:
		var z: float = 1.0 - float(i) / steps
		_rig.set_zoom(z, true)
		var d: float = curve.distance(z)
		var p: float = curve.pitch_deg(z)
		if d > prev_d + 1e-6 or p > prev_p + 1e-6 or is_nan(d) or is_nan(p):
			mono = false
		prev_d = d
		prev_p = p
		if not _camera_ok(_focus_point(), "down z=%.2f" % z):
			cams_ok = false
	_check(mono, "distance and pitch fall monotonically as z goes 1 -> 0")
	_check(_rig.is_first_person(), "z = 0 is first person")
	var eye: float = _cam().global_position.y - _rig.get_first_person_body().global_position.y
	_check(absf(eye - 2.0) < 0.05, "eye height at z=0: %.3f m" % eye)
	_check(absf(_cam().global_position.y - 2.0) < 0.05, "camera y at z=0 on open floor: %.3f m" % _cam().global_position.y)
	_check(is_equal_approx(curve.distance(0.0), 0.0) and curve.distance(1.0) > 90.0, "distance 0 at z=0, %.1f at z=1" % curve.distance(1.0))
	_check(_cam().fov > 65.0 and _cam().near <= 0.051, "close range fov %.1f near %.3f" % [_cam().fov, _cam().near])
	for i: int in steps + 1:
		var z: float = float(i) / steps
		_rig.set_zoom(z, true)
		if not _camera_ok(_focus_point(), "up z=%.2f" % z):
			cams_ok = false
	_check(not _rig.is_first_person(), "zooming out leaves first person")
	_check(cams_ok, "camera never inside a collider, always above 0.3 m, sees its focus (202 samples)")


## Orbit at mid/low zoom with a wall between the ideal camera spot and focus.
func _test_wall_cast() -> void:
	var ok: bool = true
	var focus: Vector3 = Vector3(-12.0, 0.0, -1.8)  # just inside the front wall
	for yaw: float in [0.0, 30.0, -30.0]:  # camera out past the wall
		_rig.focus_on(focus, yaw, true)
		for z: float in [0.6, 0.5, 0.4, 0.3, 0.2, 0.1]:
			_rig.set_zoom(z, true)
			var fp: Vector3 = Vector3(focus.x, _rig.get_zoom_curve().eye_height * _rig.get_zoom_curve().eye_weight(z), focus.z)
			if not _camera_ok(fp, "wall yaw=%d z=%.1f" % [yaw, z]):
				ok = false
	_check(ok, "orbit cast keeps the camera on the focus side of a wall")


func _walk(dir: Vector3, start: Vector3, seconds: float, track: Callable) -> void:
	var yaw: float = rad_to_deg(atan2(-dir.x, -dir.z))
	_rig.set_zoom(0.0, true)
	_rig.focus_on(start, yaw, true)
	await _frames(2)
	_rig.scripted_move = Vector2(0.0, -1.0)  # forward
	var n: int = int(seconds * Engine.physics_ticks_per_second)
	for i: int in n:
		await physics_frame
		track.call(_rig.get_first_person_body().global_position)
	_rig.scripted_move = Vector2.ZERO
	await _frames(2)


func _test_wall_walk() -> void:
	var space: PhysicsDirectSpaceState3D = _cam().get_world_3d().direct_space_state
	var from: Vector3 = Vector3(-12.0, 1.0, -3.0)
	var dir: Vector3 = Vector3.BACK  # +Z, toward the front wall
	var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * 20.0, 1))
	if hit.is_empty():
		_check(false, "found a wall to walk into")
		return
	var wall: Vector3 = hit.position
	print("wall at ", wall, " (", (hit.collider as Node).get_path(), ")")
	var start: Vector3 = Vector3(wall.x, 0.0, wall.z) - dir * 1.5
	var deepest: Array[float] = [-INF]
	await _walk(dir, start, 3.0, func(p: Vector3) -> void: deepest[0] = maxf(deepest[0], (p - wall).dot(dir)))
	var body: FirstPersonBody = _rig.get_first_person_body()
	var gap: float = -deepest[0]
	_check(gap > body.radius - 0.05, "walker blocked by the wall (closest centre-to-wall %.3f m, radius %.2f)" % [gap, body.radius])


func _test_ramp() -> void:
	var top: Array[float] = [0.0]
	var far: Array[float] = [-INF]
	var track: Callable = func(p: Vector3) -> void:
		top[0] = maxf(top[0], p.y)
		far[0] = maxf(far[0], p.z)
	await _walk(Vector3.BACK, RAMP_START, 6.0, track)
	_check(top[0] > 0.9, "walker climbs the dock 1 ramp (max feet y %.2f m, reached z %.2f)" % [top[0], far[0]])
	var parked: bool = false
	for n: Node in current_scene.find_children("*", "TruckRig", true, false):
		var rig: TruckRig = n as TruckRig
		if rig.is_parked() and absf(rig.global_position.x - RAMP_START.x) < 2.0:
			parked = true
	if parked:
		_check(far[0] > 1.5 and top[0] > 1.0, "walker walks up the leveler into the parked trailer (z %.2f, y %.2f)" % [far[0], top[0]])
	else:
		print("SKIP trailer walk-in (no truck parked at dock 1; pass -- --reference_state)")


## A box sweeping through the walker at truck yard speed must push it, never
## end up overlapping it.
func _test_push() -> void:
	var start: Vector3 = Vector3(-8.0, 0.0, -14.0)
	_rig.set_zoom(0.0, true)
	_rig.focus_on(start, 0.0, true)
	await _frames(3)
	var body: FirstPersonBody = _rig.get_first_person_body()
	var feet0: Vector3 = body.global_position
	var mover: AnimatableBody3D = AnimatableBody3D.new()
	mover.sync_to_physics = false
	mover.collision_layer = _rig.proxy_layer
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(2.0, 2.4, 1.0)
	cs.shape = box
	mover.add_child(cs)
	current_scene.add_child(mover)
	var box_pos: Vector3 = feet0 + Vector3(-3.0, 1.2, 0.0)
	mover.global_position = box_pos
	await _frames(2)
	var worst: float = INF
	var n: int = int(1.6 * Engine.physics_ticks_per_second)
	for i: int in n:
		box_pos.x += 3.0 / Engine.physics_ticks_per_second
		mover.global_position = box_pos
		await physics_frame
		var p: Vector3 = body.global_position
		# Signed gap between capsule surface and the box's +X face (box moves +X).
		var gap: float = (p.x - body.radius) - (box_pos.x + box.size.x * 0.5)
		if absf(p.z - box_pos.z) < box.size.z * 0.5 + body.radius:
			worst = minf(worst, gap)
	mover.queue_free()
	var moved: float = body.global_position.x - feet0.x
	_check(worst > -0.08 and moved > 1.5, "moving body pushes the walker (moved %.2f m, worst overlap %.3f m)" % [moved, -worst])
