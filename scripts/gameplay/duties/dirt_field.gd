class_name DirtField
extends Node3D
## Dirt and spills on the hall floor. Forklifts leave dust where they drive
## and where they set pallets down; now and then it is a spill. Each spot is
## a subtle floor decal that grows over time and fades as a worker sweeps or
## mops it. The DutyPlanner adds spots and hands them out to cleaners.

signal spot_added(spot: Spot)
signal spot_cleaned(spot: Spot)

var spots: Array[Spot] = []
var cleaned_count: int = 0
var _dust_tex: Texture2D = null
var _spill_tex: Texture2D = null


class Spot:
	extends RefCounted
	var pos: Vector2 = Vector2.ZERO
	var amount: float = 0.2
	var spill: bool = false
	var decal: Decal = null
	var claimed_by: Object = null
	var cleaned: bool = false
	var id: int = 0


func _ready() -> void:
	_dust_tex = _make_texture(Color(0.23, 0.2, 0.16), 11)
	_spill_tex = _make_texture(Color(0.12, 0.14, 0.16), 23)


## New spot at p (or more dirt on a spot already close by).
func add_dirt(p: Vector2, spill: bool, start: float = 0.2) -> Spot:
	for s: Spot in spots:
		if s.pos.distance_to(p) < 1.6 and s.spill == spill:
			s.amount = minf(1.0, s.amount + 0.2)
			_refresh(s)
			return s
	if spots.size() >= DutyConfig.DIRT_MAX_SPOTS:
		return null
	var s: Spot = Spot.new()
	s.pos = p
	s.spill = spill
	s.amount = start
	s.id = randi()
	var d: Decal = Decal.new()
	d.name = "Dirt"
	d.texture_albedo = _spill_tex if spill else _dust_tex
	d.cull_mask = 1
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	d.rotation.y = randf() * TAU
	d.position = Vector3(p.x, 0.0, p.y)
	add_child(d)
	s.decal = d
	spots.append(s)
	_refresh(s)
	spot_added.emit(s)
	return s


## Grows the dirt over time (game seconds).
func tick(dt: float) -> void:
	for s: Spot in spots:
		if s.claimed_by == null and s.amount < 1.0:
			s.amount = minf(1.0, s.amount + dt / DutyConfig.DIRT_GROW_TIME)
			_refresh(s)


func clean(s: Spot, by: float) -> void:
	s.amount = maxf(0.0, s.amount - by)
	_refresh(s)
	if s.amount <= 0.04 and not s.cleaned:
		s.cleaned = true
		cleaned_count += 1
		spots.erase(s)
		if s.decal != null:
			s.decal.queue_free()
			s.decal = null
		spot_cleaned.emit(s)


## Size of the spot on the floor (m).
func spot_size(s: Spot) -> float:
	return lerpf(0.55, 1.3, s.amount) * (1.15 if s.spill else 1.0)


func _refresh(s: Spot) -> void:
	if s.decal == null:
		return
	var size: float = spot_size(s)
	s.decal.size = Vector3(size, 0.4, size)
	s.decal.modulate = Color(1, 1, 1, clampf(0.15 + 0.55 * s.amount, 0.0, 0.7))


## A soft blob with a little grain, transparent at the edge.
static func _make_texture(c: Color, seed_value: int) -> Texture2D:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.09
	var n: int = 64
	var img: Image = Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y: int in n:
		for x: int in n:
			var d: float = Vector2(x - n * 0.5 + 0.5, y - n * 0.5 + 0.5).length() / (n * 0.5)
			var v: float = noise.get_noise_2d(x, y) * 0.5 + 0.5
			var a: float = clampf((1.0 - d) * 1.6 - 0.15 + (v - 0.5) * 0.9, 0.0, 1.0)
			img.set_pixel(x, y, Color(c.r * (0.8 + 0.4 * v), c.g * (0.8 + 0.4 * v), c.b * (0.8 + 0.4 * v), a))
	return ImageTexture.create_from_image(img)
