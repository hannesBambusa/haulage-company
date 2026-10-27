class_name CameraRenderTuning
extends Node
## Adapts scene rendering to the camera zoom. closeness 0 restores every value
## found in the level exactly (the strategic and reference views are untouched);
## closeness 1 is eye level: a short sun shadow range for crisp shadows, and a
## smaller, softer SSAO/SSIL radius so ambient occlusion fits human scale.
## Finds the first shadowed DirectionalLight3D and the WorldEnvironment under
## `scene_root`. Runtime only; nothing is saved to the level.

@export var shadow_distance_close: float = 32.0
@export var ssao_radius_close: float = 0.9
@export var ssao_intensity_close: float = 2.2
@export var ssil_radius_close: float = 1.6
## Exponential fog density at eye level, as a multiple of the level's value.
@export var fog_density_scale_close: float = 1.0

var _sun: DirectionalLight3D
var _env: Environment
var _orig: Dictionary = {}
var _last: float = -1.0


## Looks up the sun and environment once. Call before apply().
func bind(scene_root: Node) -> void:
	if scene_root == null:
		return
	for node: Node in scene_root.find_children("*", "DirectionalLight3D", true, false):
		var light: DirectionalLight3D = node as DirectionalLight3D
		if light.shadow_enabled:
			_sun = light
			break
	var envs: Array[Node] = scene_root.find_children("*", "WorldEnvironment", true, false)
	if not envs.is_empty():
		_env = (envs[0] as WorldEnvironment).environment
	if _sun != null:
		_orig["shadow"] = _sun.directional_shadow_max_distance
	if _env != null:
		_orig["ssao_radius"] = _env.ssao_radius
		_orig["ssao_intensity"] = _env.ssao_intensity
		_orig["ssil_radius"] = _env.ssil_radius
		_orig["fog_density"] = _env.fog_density
	_last = -1.0


func apply(closeness: float) -> void:
	var c: float = clampf(closeness, 0.0, 1.0)
	if is_equal_approx(c, _last):
		return
	_last = c
	if _sun != null:
		_sun.directional_shadow_max_distance = lerpf(_orig.shadow, shadow_distance_close, c)
	if _env != null:
		_env.ssao_radius = lerpf(_orig.ssao_radius, ssao_radius_close, c)
		_env.ssao_intensity = lerpf(_orig.ssao_intensity, ssao_intensity_close, c)
		_env.ssil_radius = lerpf(_orig.ssil_radius, ssil_radius_close, c)
		_env.fog_density = _orig.fog_density * lerpf(1.0, fog_density_scale_close, c)


## Puts the level's own values back (rig leaving the tree).
func restore() -> void:
	apply(0.0)
