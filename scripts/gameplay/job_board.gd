class_name JobBoard
extends Node
## FIFO queue of carry jobs and the agents that run them. Finds its agents in
## the level at startup: every job-capable WorkerActor, plus every forklift.
## Roles: three forklifts, one per role (forklift_roles): the Unloader
## (trailer -> INBOUND), the Rack forklift (INBOUND -> rack, rack -> OUTBOUND)
## and the Loader (OUTBOUND -> pickup trailer). A job waits for its role's
## forklift; no other forklift takes it. Workers do no cargo moves: they
## stand at their rest spots.
## Dispatches when a job is added, an agent finishes or a slot frees up.
## Idle agents stand still at a rest spot off the traffic lanes (forklifts
## at their parking spot, workers at rest_spots); agent_idle fires when one
## gets there, and a new job preempts the rest at once (request_release).

signal job_queued(job: CarryJob)
signal job_started(job: CarryJob)
signal job_finished(job: CarryJob)
## Relayed from the agents: the pallet left its slot / reached its target.
signal unit_picked(job: CarryJob)
signal unit_placed(job: CarryJob)
## Relayed: a pallet in an agent's way was moved aside (RELOCATE).
signal unit_relocated(job: CarryJob)
## An agent finished its work and is free (standing at its rest spot).
signal agent_idle(agent: CarryAgent)
## A job wants a held agent (a worker is servicing it): the holder should
## step back and call release_hold().
signal hold_wanted(agent: CarryAgent)

@export var level_path: NodePath
@export var storage_grid_path: NodePath
## Scene file the forklift in the level is an instance of.
@export var forklift_scene_file: String = "forklift.glb"
## Where the level's workers stand, one each in scene order, off the
## traffic lanes. They start there. Empty = where the level puts them.
@export var rest_spots: PackedVector3Array = PackedVector3Array()
## Forklift parking spots (and headings in degrees), one each in number
## order. Forklifts start there and return there when idle.
@export var parking_spots: PackedVector3Array = PackedVector3Array()
@export var parking_yaws: PackedFloat32Array = PackedFloat32Array()
## Role of each forklift in number order: "Unloader", "Rack", "Loader".
@export var forklift_roles: PackedStringArray = PackedStringArray(["Unloader", "Rack", "Loader"])
## Workers with pallet jacks may take LOAD jobs (off: forklifts load).
@export var workers_carry: bool = false
## Level worker who is the Jack operator (hand pallet jack, put-away to
## ground-level slots). Empty = none.
@export var jack_worker: String = "Worker1"

var agents: Array[CarryAgent] = []
var pending: Array[CarryJob] = []
## Idle agents a worker is standing next to (servicing): agent -> holder.
## Jobs for them wait (the agent stays available) until the hold is released.
var holds: Dictionary = {}
var _hold_asked: Dictionary = {}

var _grid: StorageGrid


func _ready() -> void:
	add_to_group(&"job_board")
	_grid = get_node_or_null(storage_grid_path) as StorageGrid
	var level: Node = get_node_or_null(level_path)
	if _grid == null or level == null:
		push_error("JobBoard: storage_grid_path or level_path not set")
		return
	_gather_agents(level)
	_grid.slots_changed.connect(_on_slots_changed)


func has_lift() -> bool:
	for a: CarryAgent in agents:
		if a is ForkliftCarrier:
			return true
	return false


func is_idle(agent: CarryAgent) -> bool:
	return agent.is_idle()


## Frees an idle agent for other use right away (stops its walk to the rest
## spot). Returns false when it is busy with a job.
func request_release(agent: CarryAgent) -> bool:
	if not agent.is_idle():
		return false
	agent.interrupt_rest()
	return true


## A worker is next to the idle `agent` (servicing it). A job that wants it
## waits and hold_wanted fires; the holder steps back and releases.
func hold_agent(agent: CarryAgent, by: Object) -> void:
	if agent.is_idle():
		holds[agent] = by
		_hold_asked.erase(agent)


## `by` = null releases whoever holds it.
func release_hold(agent: CarryAgent, by: Object) -> void:
	if holds.has(agent) and (by == null or holds[agent] == by):
		holds.erase(agent)
		_hold_asked.erase(agent)
		if not pending.is_empty():
			dispatch.call_deferred()


func idle_count() -> int:
	var n: int = 0
	for a: CarryAgent in agents:
		if a.is_idle():
			n += 1
	return n


func add_job(job: CarryJob) -> void:
	job.unit.job = job
	if job.to_slot != null:
		_grid.reserve(job.to_slot, job.unit)
	pending.append(job)
	job_queued.emit(job)
	dispatch()


## Starts a job on a given agent at once, the pallet already on board at
## `at` (reference screenshot).
func start_now(job: CarryJob, agent: CarryAgent, at: Vector3, yaw: float) -> void:
	job.unit.job = job
	if job.to_slot != null:
		_grid.reserve(job.to_slot, job.unit)
	agent.start_carrying(job, at, yaw)
	job_started.emit(job)


func dispatch() -> void:
	for job: CarryJob in pending.duplicate():
		var target: StorageSlot = job.to_slot
		if target == null:
			target = _resolve_target(job)
			if target == null:
				continue  # zone full or no free trailer slot: wait
		var agent: CarryAgent = _pick_agent(job, target)
		if agent == null:
			continue
		if holds.has(agent):
			# a worker is next to it: ask them to step back first
			if not _hold_asked.has(agent):
				_hold_asked[agent] = true
				hold_wanted.emit(agent)
			continue
		if job.to_slot == null:
			job.to_slot = target
			_grid.reserve(target, job.unit)
		pending.erase(job)
		agent.start(job)
		job_started.emit(job)


func _resolve_target(job: CarryJob) -> StorageSlot:
	match job.kind:
		CarryJob.Kind.UNLOAD:
			return _grid.drop_slot(StorageSlot.Zone.INBOUND, job.unit)
		CarryJob.Kind.TO_OUTBOUND:
			return _grid.drop_slot(StorageSlot.Zone.OUTBOUND, job.unit)
		CarryJob.Kind.LOAD:
			return job.bay.next_free_slot() if job.bay != null else null
	return null


## Nearest idle agent whose role fits the job. When the level has no agent
## of that role at all, any agent that can reach the slots stands in.
func _pick_agent(job: CarryJob, target: StorageSlot) -> CarryAgent:
	var lift: bool = job.needs_lift() or target.needs_lift()
	var from: Vector3 = job.from_slot.position
	var role_exists: bool = false
	for a: CarryAgent in agents:
		if a.suits(job):
			role_exists = true
			break
	var best: CarryAgent = null
	var best_score: float = INF
	for a: CarryAgent in agents:
		if not a.is_idle() or not a.available:
			continue
		if lift and not (a is ForkliftCarrier):
			continue
		if role_exists and not a.suits(job):
			continue
		var score: float = a.body.global_position.distance_to(from)
		if score < best_score:
			best_score = score
			best = a
	return best


## The idle, available Jack operator, or null.
func free_jack() -> JackCarrier:
	for a: CarryAgent in agents:
		if a is JackCarrier and a.is_idle() and a.available:
			return a as JackCarrier
	return null


func jacks() -> Array[JackCarrier]:
	var out: Array[JackCarrier] = []
	for a: CarryAgent in agents:
		if a is JackCarrier:
			out.append(a as JackCarrier)
	return out


func forklifts() -> Array[ForkliftCarrier]:
	var out: Array[ForkliftCarrier] = []
	for a: CarryAgent in agents:
		if a is ForkliftCarrier:
			out.append(a as ForkliftCarrier)
	return out


func _gather_agents(level: Node) -> void:
	var lifts: Array[Node3D] = []
	var workers: int = 0
	for node: Node in level.find_children("*", "Node3D", true, false):
		var actor: WorkerActor = node as WorkerActor
		if actor != null:
			# idle people stand still (their duties come later), off the lanes
			actor.patrol_enabled = false
			if workers < rest_spots.size():
				actor.position = Vector3(rest_spots[workers].x, actor.position.y, rest_spots[workers].z)
			actor.set_rest_here()
			workers += 1
			if actor.is_job_capable() and not jack_worker.is_empty() and String(actor.name) == jack_worker:
				var jc: JackCarrier = JackCarrier.new()
				jc.name = "Carrier_" + String(actor.name)
				add_child(jc)
				jc.setup(actor, _grid, actor.position)
				_add_agent(jc)
			elif actor.is_job_capable():
				if workers_carry:
					var w: WorkerCarrier = WorkerCarrier.new()
					w.name = "Carrier_" + String(actor.name)
					add_child(w)
					w.setup(actor, _grid, actor.position)
					_add_agent(w)
		elif (node as Node3D).scene_file_path.get_file() == forklift_scene_file:
			lifts.append(node as Node3D)
	# "Forklift" before "Forklift2": numbers stay stable
	lifts.sort_custom(func(a: Node3D, b: Node3D) -> bool: return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	for i: int in lifts.size():
		var f: ForkliftCarrier = ForkliftCarrier.new()
		f.name = "Carrier_Forklift%d" % (i + 1)
		add_child(f)
		if i < parking_spots.size():
			lifts[i].global_position = parking_spots[i]
			lifts[i].global_rotation = Vector3(0.0, deg_to_rad(parking_yaws[i]) if i < parking_yaws.size() else 0.0, 0.0)
		var role_name: String = forklift_roles[i] if i < forklift_roles.size() else "Rack"
		var role: int = maxi(CarryJob.ROLE_NAMES.find(role_name), 0)
		f.setup(lifts[i], _grid, i + 1, role as CarryJob.Role)
		_add_agent(f)
	_grid.lift_available = has_lift()
	print("JobBoard: %d agents (%s)" % [agents.size(), ", ".join(agents.map(func(a: CarryAgent) -> String: return a.label))])


func _add_agent(agent: CarryAgent) -> void:
	agents.append(agent)
	agent.job_done.connect(_on_job_done)
	agent.unit_picked.connect(func(_a: CarryAgent, job: CarryJob) -> void: unit_picked.emit(job))
	agent.unit_placed.connect(func(_a: CarryAgent, job: CarryJob) -> void: unit_placed.emit(job))
	agent.unit_relocated.connect(func(_a: CarryAgent, job: CarryJob) -> void: unit_relocated.emit(job))
	agent.became_idle.connect(func(a: CarryAgent) -> void: agent_idle.emit(a))


func _on_job_done(_agent: CarryAgent, job: CarryJob) -> void:
	job_finished.emit(job)
	dispatch()


func _on_slots_changed() -> void:
	if not pending.is_empty():
		dispatch.call_deferred()
