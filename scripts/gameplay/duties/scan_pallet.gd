class_name ScanPallet
extends Duty
## Checks a pallet that has sat in INBOUND or in a rack for a while: walk
## up to it, scan the label (scanner from the belt), look it over (Inspect,
## when close enough), note it on the clipboard. Adds "Scanned by Worker N"
## to the pallet's history without changing its state.

var slot: StorageSlot = null
var unit: CargoUnit = null
var spot: Array = []


func _init(p_slot: StorageSlot, p_spot: Array) -> void:
	slot = p_slot
	unit = p_slot.unit
	spot = p_spot
	kind = &"scan"
	title = "Scanning %s" % unit.code


func plan() -> bool:
	unit.set_meta(&"scan_claim", self)
	var target: Vector2 = Vector2(slot.position.x, slot.position.z)
	walk(spot[0], spot[1], "walking to %s" % unit.code)
	var scanner: PropItem = worker.kit.get(&"scanner")
	var board: PropItem = worker.kit.get(&"clipboard")
	if scanner != null:
		take(scanner, &"R", "taking the scanner")
	act(&"ScanPallet", 4.0, "scanning %s" % unit.code, spot)
	call_step(_stamp)
	if scanner != null:
		stow(scanner)
	if (spot[0] as Vector2).distance_to(target) < 1.5:
		act(&"Inspect", 3.0, "checking the wrapping", spot)
	if board != null:
		take(board, &"L", "")
	act(&"Clipboard", randf_range(3.0, 5.0), "noting %s" % unit.code, spot)
	if board != null:
		stow(board)
	call_step(func() -> void: worker.hold(&"Idle"))
	return true


func _stamp() -> void:
	if unit.slot != slot or unit.is_busy():
		return
	PalletLog.stamp(unit, unit.state, unit.location_code, "Scanned by %s" % worker.display_name)
	unit.set_meta(&"scanned_at", float(planner.get(&"clock")))
	planner.call(&"note_scan", unit, worker)


## Still worth doing: the pallet is where it was and nobody comes for it.
func still_valid() -> bool:
	return unit.slot == slot and not unit.is_busy()


func release() -> void:
	if unit != null and unit.has_meta(&"scan_claim") and unit.get_meta(&"scan_claim") == self:
		unit.remove_meta(&"scan_claim")
