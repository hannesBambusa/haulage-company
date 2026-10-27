import math, sys
W, H = 1536, 1024
def proj(p, cam):
    tx, tz, yaw, pitch, d, fov = cam
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(-pitch)), math.sin(math.radians(-pitch))
    # B = Ry * Rx ; columns
    bx = (cy, 0, -sy)
    by = (sy * sp, cp, cy * sp)
    bz = (sy * cp, -sp, cy * cp)
    cam_p = (tx + bz[0] * d, bz[1] * d, tz + bz[2] * d)
    r = [p[i] - cam_p[i] for i in range(3)]
    vx = sum(r[i] * bx[i] for i in range(3)); vy = sum(r[i] * by[i] for i in range(3)); vz = sum(r[i] * bz[i] for i in range(3))
    k = 1 / math.tan(math.radians(fov) / 2) * H / 2
    return (W / 2 + vx / -vz * k, H / 2 - vy / -vz * k)
CORR = [((-4.35, 4.22, 0.6), (537, 455)), ((0.35, 4.22, 0.6), (733, 540)),
        ((-1.65, 0.2, 0.7), (665, 680)), ((2.35, 0.2, 0.7), (812, 712)),
        ((-4.35, 0.5, 14.8), (262, 745))]
def err(c, fov_fixed=None):
    if fov_fixed: c = list(c[:5]) + [fov_fixed]
    e = 0
    for p, s in CORR:
        q = proj(p, c); e += (q[0] - s[0]) ** 2 + (q[1] - s[1]) ** 2
    return e
def nm(f, x0, steps, it=4000):
    n = len(x0); pts = [list(x0)]
    for i in range(n):
        x = list(x0); x[i] += steps[i]; pts.append(x)
    for _ in range(it):
        pts.sort(key=f)
        c = [sum(p[i] for p in pts[:-1]) / n for i in range(n)]
        w = pts[-1]
        r = [c[i] + (c[i] - w[i]) for i in range(n)]
        if f(r) < f(pts[0]):
            e = [c[i] + 2 * (c[i] - w[i]) for i in range(n)]
            pts[-1] = e if f(e) < f(r) else r
        elif f(r) < f(pts[-2]):
            pts[-1] = r
        else:
            k = [c[i] + 0.5 * (w[i] - c[i]) for i in range(n)]
            if f(k) < f(w): pts[-1] = k
            else:
                pts = [pts[0]] + [[pts[0][i] + 0.5 * (p[i] - pts[0][i]) for i in range(n)] for p in pts[1:]]
    pts.sort(key=f); return pts[0]
for fov in [float(a) for a in sys.argv[1:]] or [30, 32, 35, 40]:
    best = nm(lambda c: err(c, fov), [0, -3, 36, 41, 45], [3, 3, 5, 5, 8])
    print("fov", fov, ["%.2f" % v for v in best], "rms", math.sqrt(err(best, fov) / len(CORR)))
    print("   ", [tuple(round(v) for v in proj(p, best + [fov])) for p, s in CORR])
