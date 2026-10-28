extends Node
## Player settings: graphics quality (Low / Medium / High) and fullscreen or
## window. Saved to user://settings.cfg and applied at start and on change.
## Scripted runs (tests, captures: -s / --script) ignore the saved file and
## keep their window, so they render the same on every machine.

signal changed
## Esc that nothing else used (autoloads come first in the tree, so they
## get unhandled input last). The Esc menu opens on it.
signal menu_requested

enum Quality { LOW, MEDIUM, HIGH }

const PATH: String = "user://settings.cfg"
const QUALITY_NAMES: PackedStringArray = ["Low", "Medium", "High"]

var quality: Quality = Quality.HIGH
var fullscreen: bool = true
var _scripted: bool = false


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	_scripted = "-s" in args or "--script" in args
	if not _scripted:
		var cfg: ConfigFile = ConfigFile.new()
		if cfg.load(PATH) == OK:
			quality = clampi(int(cfg.get_value("graphics", "quality", quality)), 0, 2) as Quality
			fullscreen = bool(cfg.get_value("display", "fullscreen", fullscreen))
		_apply_window()
	get_tree().node_added.connect(_on_node_added)
	_apply_quality.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		menu_requested.emit()
		get_viewport().set_input_as_handled()


func set_quality(q: Quality) -> void:
	quality = q
	_apply_quality()
	_save()
	changed.emit()


func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_window()
	_save()
	changed.emit()


func _save() -> void:
	if _scripted:
		return
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("graphics", "quality", int(quality))
	cfg.set_value("display", "fullscreen", fullscreen)
	cfg.save(PATH)


func _apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var win: Window = get_window()
	win.mode = Window.MODE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED
	if not fullscreen:
		# a sensible window on the current screen, not the full screen size
		var screen: Rect2i = DisplayServer.screen_get_usable_rect(win.current_screen)
		var size: Vector2i = Vector2i(screen.size * 0.8)
		win.size = size
		win.position = screen.position + (screen.size - size) / 2


## Scenes loaded later (the level) get the current quality too.
func _on_node_added(n: Node) -> void:
	if n is WorldEnvironment or n is DirectionalLight3D:
		_apply_quality.call_deferred()


func _apply_quality() -> void:
	var vp: Viewport = get_viewport()
	var q: int = quality
	vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_2X][q]
	vp.screen_space_aa = [Viewport.SCREEN_SPACE_AA_FXAA, Viewport.SCREEN_SPACE_AA_DISABLED, Viewport.SCREEN_SPACE_AA_DISABLED][q]
	vp.scaling_3d_scale = [0.75, 1.0, 1.0][q]
	vp.positional_shadow_atlas_size = [1024, 2048, 4096][q]
	RenderingServer.directional_shadow_atlas_set_size([2048, 4096, 8192][q], true)
	RenderingServer.directional_soft_shadow_filter_set_quality([
		RenderingServer.SHADOW_QUALITY_HARD,
		RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_ULTRA][q])
	RenderingServer.environment_set_ssao_quality([
		RenderingServer.ENV_SSAO_QUALITY_VERY_LOW,
		RenderingServer.ENV_SSAO_QUALITY_MEDIUM,
		RenderingServer.ENV_SSAO_QUALITY_HIGH][q], true, 0.5, 2, 50.0, 300.0)
	for n: Node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var env: Environment = (n as WorldEnvironment).environment
		if env == null:
			continue
		env.ssao_enabled = q >= Quality.MEDIUM
		env.ssil_enabled = q >= Quality.HIGH
		env.glow_enabled = q >= Quality.MEDIUM
	for n: Node in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		var sun: DirectionalLight3D = n as DirectionalLight3D
		if not sun.has_meta(&"shadow_max_full"):
			sun.set_meta(&"shadow_max_full", sun.directional_shadow_max_distance)
			sun.set_meta(&"shadow_mode_full", sun.directional_shadow_mode)
		var full: float = float(sun.get_meta(&"shadow_max_full"))
		sun.directional_shadow_max_distance = [full * 0.6, full * 0.8, full][q]
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if q == Quality.LOW else int(sun.get_meta(&"shadow_mode_full"))
