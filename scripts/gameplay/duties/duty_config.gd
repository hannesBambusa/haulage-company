class_name DutyConfig
extends RefCounted
## Tuning for the staff duty system, in one place. Every time below is in
## game seconds: the simulation time that motion and animations run on
## (real seconds x GameState.speed). Needs run 0..1 and rise per game second.
## Retuning the clock means changing values here only.

# --- needs -----------------------------------------------------------------------
## Tiredness: a coffee break is due at about 0.7 (from 0 after ~20 min).
const TIRED_RATE: float = 1.0 / 1700.0
## Thirst: a trip to the water cooler is due at about 0.7 (~35 min).
const THIRST_RATE: float = 1.0 / 3000.0
## Wish for company: rises steadily, drops in a conversation.
const SOCIAL_RATE: float = 1.0 / 1500.0
## Need level at which the matching break starts to win over work.
const NEED_URGENT: float = 0.7
## Need recovery while on the matching break, per game second.
const COFFEE_RECOVER: float = 1.0 / 25.0
const WATER_RECOVER: float = 1.0 / 6.0
const TALK_RECOVER: float = 1.0 / 30.0
## Start values are spread per worker so breaks do not all fall together.
const NEED_START_MAX: float = 0.55

# --- break area --------------------------------------------------------------------
## Time at the coffee machine before the cup is in the hand.
const COFFEE_BREW_TIME: float = 4.0
## Time on the break with a cup (sitting or standing), before tidying up.
const COFFEE_TIME: Vector2 = Vector2(40.0, 70.0)
## How long to stay with a conversation group (alternating Talk / Listen).
const TALK_TURN: Vector2 = Vector2(3.0, 6.0)
const LAUGH_CHANCE: float = 0.18
## Glass of water at the cooler.
const WATER_TIME: float = 6.0

# --- dirt ----------------------------------------------------------------------------
## A forklift drops a dirt spot about this often while driving on the hall floor.
const DIRT_DRIVE_INTERVAL: float = 55.0
## Chance a pallet set-down leaves a dirt spot by the slot.
const DIRT_SETDOWN_CHANCE: float = 0.35
## Chance a new spot is a spill (mop, bucket and sign) instead of dust (broom).
const SPILL_CHANCE: float = 0.25
## Dirt grows from 0.2 to 1 in this time (size and opacity follow).
const DIRT_GROW_TIME: float = 240.0
## Dirt below this level is not worth a trip yet.
const DIRT_WORTH: float = 0.25
const DIRT_MAX_SPOTS: int = 10
## Dirt removed per sweeping / mopping pass.
const SWEEP_PASS_CLEAN: float = 0.45
const MOP_STROKE_CLEAN: float = 0.2

# --- work duties ---------------------------------------------------------------------
## Pallets in INBOUND or STORED this long without a scan get one.
const SCAN_AFTER: float = 90.0
## A scanned pallet is not scanned again for this long.
const RESCAN_AFTER: float = 900.0
## Rack inspection round: one per rack aisle this often.
const RACK_ROUND_EVERY: float = 420.0
const RACK_CHECK_TIME: float = 6.0
## Forklift service: a parked forklift asks for one this often.
const SERVICE_EVERY: float = 360.0
const SERVICE_TIME: Vector2 = Vector2(25.0, 40.0)
## Truck greeting: clipboard time while the truck is unloading.
const GREET_CLIPBOARD_TIME: Vector2 = Vector2(30.0, 50.0)
## Short fillers.
const PHONE_TIME: Vector2 = Vector2(12.0, 22.0)
const STRETCH_REPEATS: int = 2
## A worker repeats the same filler only after this long.
const FILLER_COOLDOWN: float = 90.0

# --- motion and safety ----------------------------------------------------------------
## Walking speed range (m/s); each worker gets one value in it.
const WALK_SPEED: Vector2 = Vector2(1.3, 1.6)
## Speeding up and slowing down (m/s^2): the same limit as the forklifts.
const ACCEL: float = 1.0
## Turn rate while walking and while turning on the spot (rad/s).
const TURN_RATE: float = 4.0
const TURN_IN_PLACE_RATE: float = 3.0
## Crossfade between animations.
const BLEND: float = 0.25
## Prop hand-over (shelf to hand and back).
const PROP_MOVE_TIME: float = 0.3
## Keep-out distances for people: from a moving forklift (edge to edge,
## m; the hard limit is 1.5 m, the rest is reaction margin), and from
## people (centre to centre).
const PERSON_VEHICLE_GAP: float = 1.8
const PERSON_PERSON_GAP: float = 1.25  ## centre to centre while both walk
## The one exception to the 1.0 m person-person limit: members of one
## conversation group (talking at the break table or standing together)
## stand this close to each other, and only to each other.
const GROUP_GAP: float = 0.72
## Closest two people outside a group ever come (centre to centre): passing
## someone, queueing behind someone. The limit is 1.0 m.
const PERSON_MIN: float = 1.05
## A worker on a work spot inside a forklift area leaves when a forklift
## working there comes this close (m, centre to centre), or when the area's
## lock is taken.
const WORK_AREA_ALERT: float = 7.0
## Distance a worker steps back from a forklift it was servicing.
const SERVICE_STEP_BACK: float = 2.0
## Planner re-scores an idle worker at most this often.
const THINK_INTERVAL: float = 0.5


static func rand_in(r: Vector2) -> float:
	return randf_range(r.x, r.y)
## Waiting in a spot queue (bin, tool rack) longer than this gives the duty up.
const QUEUE_GIVE_UP: float = 20.0
