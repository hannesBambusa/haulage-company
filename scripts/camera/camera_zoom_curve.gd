class_name CameraZoomCurve
extends Resource
## Maps one zoom value z in [0, 1] to the camera framing used by CameraRig.
## z = 1 is the strategic view (max_distance, far pitch, far FOV). Going down,
## the distance shrinks on an exponential curve (wheel steps feel constant),
## and below the *_end values the pitch flattens toward pitch_near_deg, the FOV
## widens and the orbit target rises to eye height (tilt-zoom). At z = 0 the
## distance is 0: the camera sits at eye height on the focus point.
## Every blend is a smoothstep that is exactly 1 at or above its *_end, so any
## framing with z above those ends (the reference view) is untouched.

@export var max_distance: float = 95.0
## Steepness of the distance curve. Higher = more of the wheel range spent close.
@export var distance_curve: float = 4.5
## Pitch (downward tilt, degrees) at z >= pitch_end. CameraRig sets this from
## its reference_view.
@export var pitch_far_deg: float = 42.0
@export var pitch_near_deg: float = 3.0
@export var pitch_end: float = 0.8
## FOV (vertical, degrees) at z >= fov_end. CameraRig sets this from its
## reference_view.
@export var fov_far_deg: float = 30.0
@export var fov_near_deg: float = 70.0
@export var fov_end: float = 0.7
## Orbit target height blends from the ground to eye height below this z.
@export var eye_end: float = 0.6
@export var eye_height: float = 2.0
## Rendering (near plane, shadow distance, SSAO) blends toward its close-range
## values below this z.
@export var render_end: float = 0.75
@export var near_far: float = 0.5
@export var near_close: float = 0.05


## Unobstructed camera-to-target distance for z.
func distance(z: float) -> float:
	var zc: float = clampf(z, 0.0, 1.0)
	return max_distance * (exp(distance_curve * zc) - 1.0) / (exp(distance_curve) - 1.0)


## Inverse of distance(): the z that gives distance d.
func z_for_distance(d: float) -> float:
	var k: float = distance_curve
	var r: float = clampf(d / max_distance, 0.0, 1.0)
	return clampf(log(1.0 + r * (exp(k) - 1.0)) / k, 0.0, 1.0)


func pitch_deg(z: float) -> float:
	return lerpf(pitch_near_deg, pitch_far_deg, smoothstep(0.0, pitch_end, z))


func fov_deg(z: float) -> float:
	return lerpf(fov_near_deg, fov_far_deg, smoothstep(0.0, fov_end, z))


## 1 at z = 0 (target at eye height), 0 at z >= eye_end (target on the ground).
func eye_weight(z: float) -> float:
	return 1.0 - smoothstep(0.0, eye_end, z)


## 1 at z = 0 (close-range rendering), 0 at z >= render_end (unchanged).
func closeness(z: float) -> float:
	return 1.0 - smoothstep(0.0, render_end, z)


func near_plane(z: float) -> float:
	return lerpf(near_far, near_close, closeness(z))
