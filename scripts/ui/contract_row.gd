extends PanelContainer
## One row in the contracts list, filled from a Contract.

signal selected(row: PanelContainer)
signal accept_requested(contract: Contract)

const BADGE_VARIATIONS: Dictionary = {
	"Standard": &"BadgeStandard",
	"Priority": &"BadgePriority",
	"Urgent": &"BadgeUrgent",
}

var contract: Contract = null


func _ready() -> void:
	%Accept.pressed.connect(func() -> void: accept_requested.emit(contract))


func setup(c: Contract) -> void:
	contract = c
	%LogoIcon.texture = load(c.logo)
	%Company.text = c.company
	%Cargo.text = c.cargo
	%Pack.text = c.pack
	%Pallets.text = "%d pallets" % c.pallets
	%Tons.text = "%d t" % c.tons
	%Days.text = "%d day%s" % [c.storage_days, "" if c.storage_days == 1 else "s"]
	%Scope.text = "Handling + storage"
	%Price.text = "$ " + GameState.format_money(c.payout if c.state == Contract.State.COMPLETED else c.estimated_total())
	%BadgeLabel.text = c.tag
	%Badge.theme_type_variation = BADGE_VARIATIONS.get(c.tag, &"BadgeStandard")
	var open: bool = c.state == Contract.State.AVAILABLE
	%Accept.text = "Accept" if open else c.state_name()
	%Accept.disabled = not open


func set_selected(value: bool) -> void:
	theme_type_variation = &"ContractRowSelected" if value else &"ContractRow"


func _gui_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		selected.emit(self)
