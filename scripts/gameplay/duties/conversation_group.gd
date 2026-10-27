class_name ConversationGroup
extends RefCounted
## People standing together at the break area: up to three places on a
## small circle, everyone facing the middle. One talks at a time (Talk), the
## others listen (Listen, a sip of coffee now and then) and may laugh when
## the word passes on. Members may stand closer than the usual 1 m (the one
## exception to it); someone who leaves stays a member until they are the
## usual distance from everyone else in it.

const RADIUS: float = 0.55
const SLOT_ORDER: Array[int] = [0, 1, 2]

var center: Vector2 = Vector2.ZERO
var base_angle: float = 0.0
## slot index -> WorkerActor (or null)
var slots: Array = [null, null, null]
var speaker: WorkerActor = null
## Counts up each time the word passes (listeners react to the change).
var turn: int = 0
var _left: float = 0.0
## Members on their way out: still in the group until they are clear.
var _leaving: Array[WorkerActor] = []


func _init(p_center: Vector2, angle: float) -> void:
	center = p_center
	base_angle = angle


func members() -> Array[WorkerActor]:
	var out: Array[WorkerActor] = []
	for w: Variant in slots:
		if w != null:
			out.append(w)
	return out


func size() -> int:
	return members().size()


func is_full() -> bool:
	return size() >= slots.size()


## Takes the next free place; returns [position, yaw facing the middle] or [].
func join(w: WorkerActor) -> Array:
	for i: int in SLOT_ORDER:
		if slots[i] == w:
			return place(i)
	for i: int in SLOT_ORDER:
		if slots[i] == null:
			slots[i] = w
			w.group = self
			return place(i)
	return []


func leave(w: WorkerActor) -> void:
	for i: int in slots.size():
		if slots[i] == w:
			slots[i] = null
	if w.group == self and not _leaving.has(w):
		_leaving.append(w)  # w.group stays until they have walked clear
	if speaker == w:
		speaker = null
		_left = 0.0


## Lets go of members who have left and stand clear of everyone in the group.
func _release_leavers() -> void:
	for w: WorkerActor in _leaving.duplicate():
		if not is_instance_valid(w) or w.group != self:
			_leaving.erase(w)
			continue
		if members().has(w):
			_leaving.erase(w)  # joined again
			continue
		var clear: bool = true
		for o: WorkerActor in members() + _leaving:
			if o != w and is_instance_valid(o) and o.pos2().distance_to(w.pos2()) < DutyConfig.PERSON_MIN:
				clear = false
				break
		if clear:
			w.group = null
			_leaving.erase(w)


func place(i: int) -> Array:
	var p: Vector2 = center + Vector2.from_angle(base_angle + i * TAU / 3.0) * RADIUS
	return [p, WorkerActor.yaw_towards(p, center)]


## Members standing at their place (not still walking up).
func present() -> Array[WorkerActor]:
	var out: Array[WorkerActor] = []
	for i: int in slots.size():
		var w: WorkerActor = slots[i]
		if w != null and w.pos2().distance_to(place(i)[0]) < 0.3 and not w.is_busy_motor():
			out.append(w)
	return out


## Passes the word around (game seconds).
func tick(dt: float) -> void:
	_release_leavers()
	var here: Array[WorkerActor] = present()
	if here.size() < 2:
		speaker = null
		return
	_left -= dt
	if speaker == null or not here.has(speaker) or _left <= 0.0:
		var others: Array[WorkerActor] = here.filter(func(w: WorkerActor) -> bool: return w != speaker)
		speaker = others[randi() % others.size()]
		_left = DutyConfig.rand_in(DutyConfig.TALK_TURN)
		turn += 1
