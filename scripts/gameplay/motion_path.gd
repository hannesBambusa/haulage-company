class_name MotionPath
extends RefCounted
## One drivable leg on the floor plane, sampled every STEP metres: positions
## (x, z), the vehicle's yaw (Godot convention, front = -Z), the path's signed
## curvature and a speed cap per sample. A leg is driven in one direction;
## `reverse` legs are driven backwards (the vehicle faces away from the
## direction of travel). Built from straights and circular arcs, so heading
## and position are continuous and arcs never get tighter than the radius
## they were built with. Dubins words (LSL, RSR, LSR, RSL, RLR, LRL) join two
## poses with the shortest forward path for a given turning radius.
##
## Headings: `theta` is the direction of travel in the (x, z) plane,
## (cos theta, sin theta). Vehicle yaw = yaw_of(theta), plus PI when reversing.

const STEP: float = 0.05

var pts: PackedVector2Array = PackedVector2Array()
var yaws: PackedFloat32Array = PackedFloat32Array()
var curv: PackedFloat32Array = PackedFloat32Array()
var vmax: PackedFloat32Array = PackedFloat32Array()
var reverse: bool = false
## Free-form label for debugging and tests ("travel", "lane", "approach"...).
var tag: StringName = &""
## Escape moves ignore the mover they make way for (they move away from it)
## but still yield to everyone else.
var ignore_mover: Object = null
## [s, Callable] pairs fired once when the vehicle passes s.
var events: Array = []
## Traffic: the driver's footprints at fixed samples along the path
## (sample index -> Array of FootprintBox), for the load it was cached with.
var fp_cache: Dictionary = {}
var fp_variant: float = NAN

## Total turning in radians (sum of arc angles).
var turning: float = 0.0
## Arc length between samples: about STEP while building, exact after
## profile() re-spaces the samples (so s is the true distance travelled).
var _ds: float = STEP
var _theta: float = 0.0
var _pos: Vector2 = Vector2.ZERO


static func yaw_of(theta: float) -> float:
	# direction (cos, sin) = (-sin yaw, -cos yaw)
	return atan2(-cos(theta), -sin(theta))


static func theta_of(yaw: float) -> float:
	return atan2(-cos(yaw), -sin(yaw))


static func flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


## Empty leg starting at `pos` travelling along `theta`.
static func begin(pos: Vector2, theta: float, p_reverse: bool, p_tag: StringName = &"") -> MotionPath:
	var m: MotionPath = MotionPath.new()
	m.reverse = p_reverse
	m.tag = p_tag
	m._pos = pos
	m._theta = theta
	m._push(0.0)
	return m


## Leg that starts at a vehicle pose (yaw) and drives forward or backward.
static func from_pose(pos: Vector2, yaw: float, p_reverse: bool, p_tag: StringName = &"") -> MotionPath:
	var theta: float = theta_of(yaw)
	if p_reverse:
		theta += PI
	return begin(pos, theta, p_reverse, p_tag)


func length() -> float:
	return maxf(float(pts.size() - 1) * _ds, 0.0)


func end_pos() -> Vector2:
	return pts[pts.size() - 1]


func end_yaw() -> float:
	return yaws[yaws.size() - 1]


func end_theta() -> float:
	return _theta


func straight(dist: float) -> MotionPath:
	var n: int = maxi(1, roundi(dist / STEP))
	var step: float = dist / n
	var d: Vector2 = Vector2(cos(_theta), sin(_theta))
	var start: Vector2 = _pos
	for i: int in n:
		_pos = start + d * step * (i + 1)
		_push(0.0)
	return self


## Arc of `angle` radians (positive = theta increasing) with radius r.
func arc(angle: float, r: float) -> MotionPath:
	turning += absf(angle)
	var dist: float = absf(angle) * r
	var n: int = maxi(1, roundi(dist / STEP))
	var dth: float = angle / n
	var k: float = signf(angle) / r
	var cx: Vector2 = _pos + Vector2(-sin(_theta), cos(_theta)) * r * signf(angle)
	var th0: float = _theta
	for i: int in n:
		_theta = th0 + dth * (i + 1)
		_pos = cx + Vector2(sin(_theta), -cos(_theta)) * r * signf(angle)
		_push(k)
	return self


## Straight to a point (the heading changes to point at it).
func line_to(p: Vector2) -> MotionPath:
	var d: Vector2 = p - _pos
	if d.length() < 0.001:
		return self
	_theta = atan2(d.y, d.x)
	if yaws.size() == 1:
		yaws[0] = _yaw_now()
	return straight(d.length())


## Appends the whole of another leg (same direction), continuing from here.
func append(other: MotionPath) -> MotionPath:
	for i: int in range(1, other.pts.size()):
		pts.append(other.pts[i])
		yaws.append(other.yaws[i])
		curv.append(other.curv[i])
		vmax.append(other.vmax[i])
	_pos = other._pos
	_theta = other._theta
	turning += other.turning
	return self


func cap_speed(v: float) -> MotionPath:
	for i: int in vmax.size():
		vmax[i] = minf(vmax[i], v)
	return self


## Speed caps: `v` on straights, `v_turn` on arcs; braking so the vehicle can
## stop at the end with deceleration `accel`.
func profile(v: float, v_turn: float, accel: float, stop_at_end: bool = true) -> MotionPath:
	_resample()
	for i: int in vmax.size():
		var cap: float = v if absf(curv[i]) < 0.001 else minf(v, v_turn)
		vmax[i] = minf(vmax[i], cap)
	# look ahead: slow down before arcs and before the end
	var last: int = vmax.size() - 1
	if stop_at_end:
		vmax[last] = 0.0
	for i: int in range(last - 1, -1, -1):
		vmax[i] = minf(vmax[i], sqrt(vmax[i + 1] * vmax[i + 1] + 2.0 * accel * _ds))
	return self


func add_event(s: float, fn: Callable) -> MotionPath:
	events.append([s, fn])
	return self


## Re-spaces the samples exactly STEP apart along the path, so arc length
## and sample index agree (short arcs and straights round their counts).
func _resample() -> void:
	var n: int = pts.size()
	if n < 2:
		return
	var cum: PackedFloat32Array = PackedFloat32Array([0.0])
	for i: int in range(1, n):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i]))
	var total: float = cum[n - 1]
	var m: int = maxi(1, roundi(total / STEP))
	var step: float = total / m
	var np: PackedVector2Array = PackedVector2Array()
	var ny: PackedFloat32Array = PackedFloat32Array()
	var nc: PackedFloat32Array = PackedFloat32Array()
	var nv: PackedFloat32Array = PackedFloat32Array()
	var j: int = 0
	for k: int in m + 1:
		var d: float = minf(k * step, total)
		while j < n - 2 and cum[j + 1] < d:
			j += 1
		var seg: float = cum[j + 1] - cum[j]
		var t: float = 0.0 if seg <= 0.0 else clampf((d - cum[j]) / seg, 0.0, 1.0)
		np.append(pts[j].lerp(pts[j + 1], t))
		ny.append(lerp_angle(yaws[j], yaws[j + 1], t))
		nc.append(curv[j + 1] if t > 0.5 else curv[j])
		nv.append(minf(vmax[j], vmax[j + 1]))
	pts = np
	yaws = ny
	curv = nc
	vmax = nv
	# s is now the true arc length: events keep theirs
	_ds = step


## Sample index at arc length s.
func index_at(s: float) -> int:
	return clampi(int(s / _ds), 0, pts.size() - 1)


func pos_at(s: float) -> Vector2:
	var f: float = clampf(s / _ds, 0.0, float(pts.size() - 1))
	var i: int = mini(int(f), pts.size() - 2)
	if i < 0:
		return pts[0]
	return pts[i].lerp(pts[i + 1], f - i)


func yaw_at(s: float) -> float:
	var f: float = clampf(s / _ds, 0.0, float(yaws.size() - 1))
	var i: int = mini(int(f), yaws.size() - 2)
	if i < 0:
		return yaws[0]
	return lerp_angle(yaws[i], yaws[i + 1], f - i)


func curv_at(s: float) -> float:
	return curv[index_at(s)]


## Speed cap at s. v^2 is interpolated linearly between samples: exact for
## braking at constant deceleration (v linear would brake twice as hard
## right before a stop).
func vmax_at(s: float) -> float:
	var f: float = clampf(s / _ds, 0.0, float(vmax.size() - 1))
	var i: int = mini(int(f), vmax.size() - 2)
	if i < 0:
		return vmax[0]
	var a: float = vmax[i]
	var b: float = vmax[i + 1]
	if is_inf(a) or is_inf(b):
		return lerpf(a, b, f - i)
	return sqrt(lerpf(a * a, b * b, f - i))


func _yaw_now() -> float:
	var y: float = yaw_of(_theta)
	return y + PI if reverse else y


## The first `dist` metres of this leg as a new leg (unprofiled).
func head(dist: float) -> MotionPath:
	var m: MotionPath = MotionPath.new()
	m.reverse = reverse
	m.tag = tag
	m._ds = _ds
	var n: int = mini(pts.size(), maxi(2, int(dist / _ds) + 1))
	m.pts = pts.slice(0, n)
	m.yaws = yaws.slice(0, n)
	m.curv = curv.slice(0, n)
	m.vmax = PackedFloat32Array()
	m.vmax.resize(n)
	m.vmax.fill(INF)
	m._pos = m.pts[n - 1]
	m._theta = theta_of(m.yaws[n - 1]) + (PI if reverse else 0.0)
	return m


func _push(k: float) -> void:
	pts.append(_pos)
	yaws.append(wrapf(_yaw_now(), -PI, PI))
	curv.append(k)
	vmax.append(INF)


# --- Dubins ----------------------------------------------------------------------

## Every Dubins word from (p0, theta0) to (p1, theta1) with radius r, as legs
## sorted shortest first. Only words whose end lands on the goal are kept.
static func dubins_all(p0: Vector2, th0: float, p1: Vector2, th1: float, r: float, p_reverse: bool, p_tag: StringName = &"") -> Array[MotionPath]:
	var out: Array[MotionPath] = []
	var dv: Vector2 = (p1 - p0) / r
	var d: float = dv.length()
	var theta: float = fposmod(atan2(dv.y, dv.x), TAU) if d > 0.0001 else 0.0
	var alpha: float = fposmod(th0 - theta, TAU)
	var beta: float = fposmod(th1 - theta, TAU)
	var words: Array = _words(alpha, beta, d)
	for w: Array in words:
		var m: MotionPath = begin(p0, th0, p_reverse, p_tag)
		var kinds: String = w[3]
		for i: int in 3:
			var seg: float = float(w[i])
			match kinds[i]:
				"L":
					if seg > 0.0001:
						m.arc(seg, r)
				"R":
					if seg > 0.0001:
						m.arc(-seg, r)
				"S":
					if seg * r > 0.001:
						m.straight(seg * r)
		if m.end_pos().distance_to(p1) < 0.03 and absf(angle_difference(m._theta, th1)) < 0.03:
			out.append(m)
	out.sort_custom(func(a: MotionPath, b: MotionPath) -> bool: return a.length() < b.length())
	return out


static func _words(alpha: float, beta: float, d: float) -> Array:
	var sa: float = sin(alpha)
	var sb: float = sin(beta)
	var ca: float = cos(alpha)
	var cb: float = cos(beta)
	var c_ab: float = cos(alpha - beta)
	var d_sq: float = d * d
	var out: Array = []
	# LSL
	var p_sq: float = 2.0 + d_sq - 2.0 * c_ab + 2.0 * d * (sa - sb)
	if p_sq >= 0.0:
		var t1: float = atan2(cb - ca, d + sa - sb)
		out.append([fposmod(t1 - alpha, TAU), sqrt(p_sq), fposmod(beta - t1, TAU), "LSL"])
	# RSR
	p_sq = 2.0 + d_sq - 2.0 * c_ab + 2.0 * d * (sb - sa)
	if p_sq >= 0.0:
		var t1: float = atan2(ca - cb, d - sa + sb)
		out.append([fposmod(alpha - t1, TAU), sqrt(p_sq), fposmod(t1 - beta, TAU), "RSR"])
	# LSR
	p_sq = -2.0 + d_sq + 2.0 * c_ab + 2.0 * d * (sa + sb)
	if p_sq >= 0.0:
		var p: float = sqrt(p_sq)
		var t0: float = atan2(-ca - cb, d + sa + sb) - atan2(-2.0, p)
		out.append([fposmod(t0 - alpha, TAU), p, fposmod(t0 - fposmod(beta, TAU), TAU), "LSR"])
	# RSL
	p_sq = -2.0 + d_sq + 2.0 * c_ab - 2.0 * d * (sa + sb)
	if p_sq >= 0.0:
		var p: float = sqrt(p_sq)
		var t0: float = atan2(ca + cb, d - sa - sb) - atan2(2.0, p)
		out.append([fposmod(alpha - t0, TAU), p, fposmod(beta - t0, TAU), "RSL"])
	# RLR
	var tmp: float = (6.0 - d_sq + 2.0 * c_ab + 2.0 * d * (sa - sb)) / 8.0
	if absf(tmp) <= 1.0:
		var phi: float = atan2(ca - cb, d - sa + sb)
		var p: float = fposmod(TAU - acos(tmp), TAU)
		var t: float = fposmod(alpha - phi + fposmod(p * 0.5, TAU), TAU)
		out.append([t, p, fposmod(alpha - beta - t + fposmod(p, TAU), TAU), "RLR"])
	# LRL
	tmp = (6.0 - d_sq + 2.0 * c_ab + 2.0 * d * (sb - sa)) / 8.0
	if absf(tmp) <= 1.0:
		var phi: float = atan2(ca - cb, d + sa - sb)
		var p: float = fposmod(TAU - acos(tmp), TAU)
		var t: float = fposmod(-alpha - phi + p * 0.5, TAU)
		out.append([t, p, fposmod(fposmod(beta, TAU) - alpha - t + fposmod(p, TAU), TAU), "LRL"])
	return out
