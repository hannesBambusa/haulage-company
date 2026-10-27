class_name PalletLog
extends RefCounted
## Stamps lifecycle transitions on CargoUnits with the current game time.
## Looks the GameState autoload up at runtime so test scripts that reference
## this class compile in --script mode.

static func stamp(unit: CargoUnit, state: CargoUnit.State, location: String, agent: String = "") -> void:
	var gs: Node = _game_state()
	var at: float = float(gs.call(&"now")) if gs != null else 0.0
	var day: int = int(gs.get(&"day")) if gs != null else 0
	var minutes: float = float(gs.get(&"minutes")) if gs != null else 0.0
	# history timestamps must increase even when two transitions share a frame
	if not unit.history.is_empty():
		var last: float = float(unit.history[unit.history.size() - 1].time)
		if at <= last:
			at = last + 0.001
	unit.record(state, location, agent, at, day, minutes)
	print("Pallet %s: %s @ %s%s" % [unit.code, unit.state_name(), location, (" by " + agent) if not agent.is_empty() else ""])


## "Day 3 09:41" for a history entry.
static func format_entry_time(entry: Dictionary) -> String:
	var whole: int = int(entry.get("minutes", 0.0))
	return "Day %d %02d:%02d" % [int(entry.get("day", 0)), whole / 60, whole % 60]


static func _game_state() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(^"GameState") if tree != null else null
