@tool
extends Node3D
## Dressing for a dock_door.glb instance: painted number on NumberAnchor,
## status light colour and how far the roller door is open.

const BOLD_FONT: FontFile = preload("res://ui/fonts/Inter-Bold.ttf")

@export var number: int = 1:
	set(value):
		number = value
		_refresh_if_ready()
@export_range(0.0, 1.0) var open_amount: float = 0.0:
	set(value):
		open_amount = value
		_refresh_if_ready()
@export var light_color: Color = Color(0.25, 1.0, 0.35):
	set(value):
		light_color = value
		_refresh_if_ready()
@export var light_energy: float = 3.0
## Extra lift above NumberAnchor. 0: the digit block (y 4.28..5.08) already clears the 3.99 m trailer.
@export var label_lift: float = 0.0
## Door scale at fully open. The Door origin is the top of the opening (y 4.0) and the
## mesh hangs below it, so scaling toward 0 rolls it up into the header above 4.0.
const DOOR_OPEN_SCALE: float = 0.02

var _label: Label3D
var _light_mat: StandardMaterial3D


func _ready() -> void:
	_refresh()


func _refresh_if_ready() -> void:
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	var anchor: Node3D = find_child("NumberAnchor", true, false) as Node3D
	if anchor != null:
		if _label == null:
			_label = Label3D.new()
			_label.font = BOLD_FONT
			_label.font_size = 128
			_label.pixel_size = 0.008  # digit cap height ~0.73 em * 128 px * 0.008 = ~0.75 m
			_label.outline_size = 10
			_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.45)
			_label.modulate = Color.WHITE
			_label.position = Vector3(0.0, label_lift, 0.02)
			anchor.add_child(_label)
		_label.text = str(number)
	var door: Node3D = find_child("Door", true, false) as Node3D
	if door != null:
		door.scale.y = lerpf(1.0, DOOR_OPEN_SCALE, open_amount)
	var light: MeshInstance3D = find_child("StatusLight", true, false) as MeshInstance3D
	if light != null:
		if _light_mat == null:
			_light_mat = StandardMaterial3D.new()
			light.material_override = _light_mat
		_light_mat.albedo_color = light_color
		_light_mat.emission_enabled = true
		_light_mat.emission = light_color
		_light_mat.emission_energy_multiplier = light_energy
