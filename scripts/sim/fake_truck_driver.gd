extends Node
## Stand-in for the 3D truck driver, used by ui_preview. Real-time delays.

@export var sim_path: NodePath
@export var arrive_delay: float = 2.0
@export var depart_delay: float = 2.0


func _ready() -> void:
	var sim: TerminalSim = get_node(sim_path) as TerminalSim
	sim.request_truck.connect(_on_request_truck)


func _on_request_truck(dock: Dock) -> void:
	await get_tree().create_timer(arrive_delay).timeout
	dock.truck_arrived()
	await dock.ready_to_depart
	await get_tree().create_timer(depart_delay).timeout
	dock.truck_departed()
