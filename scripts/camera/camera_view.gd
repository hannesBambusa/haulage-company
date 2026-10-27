class_name CameraView
extends Resource
## One saved camera framing for CameraRig: orbit target, angles, distance, FOV.

@export var target: Vector3 = Vector3.ZERO
## Rotation around Y in degrees. 0 looks toward -Z.
@export var yaw_deg: float = 36.0
## Downward tilt in degrees.
@export_range(5.0, 89.0) var pitch_deg: float = 40.0
@export var distance: float = 45.0
@export_range(10.0, 90.0) var fov_deg: float = 32.0
