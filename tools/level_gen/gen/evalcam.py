import fit_cam as F, math, sys
args = [float(a) for a in sys.argv[1:]]
tx, tz, yaw, pitch, d, fov = args
cam = [tx, tz, yaw, pitch, d, fov]
ITEMS = [
 ("dock1 label", (-4.35, 4.22, 0.6), (537, 455)), ("dock2 label", (0.35, 4.22, 0.6), (733, 540)),
 ("red front", (-4.35, 0.3, 14.8), (262, 760)), ("blue front", (6.6, 0.3, 10.0), (1030, 760)),
 ("blue rear top", (6.6, 4.0, -4.0), (1140, 495)), ("frontleft top", (-17, 6, 0), (80, 235)),
 ("rackA near", (-13, 0, -11), (455, 290)), ("rackB near", (-8, 0, -11), (765, 300)),
 ("forklift", (-7, 0, -7.5), (650, 370)), ("jack", (-3, 0, -7.5), (815, 400)),
 ("inbound c", (-1, 0, -13), (1000, 330)), ("outbound c", (10, 0, -8.5), (1270, 450)),
 ("desk", (9, 0, -16.5), (1160, 215)), ("booth", (17, 0, 4), (1470, 790)),
 ("rightfront top", (14, 6, 0), (1380, 490)), ("pallets out", (3, 0, 1.8), (905, 665)),
 ("w4", (3, 0, -6), (1045, 515)), ("back-left top", (-17, 6, -18), (880, 60)),
]
for n, p, r in ITEMS:
    q = F.proj(p, cam)
    print("%-15s mine (%5d,%5d)  ref (%4d,%4d)  d=(%5d,%5d)" % (n, q[0], q[1], r[0], r[1], q[0] - r[0], q[1] - r[1]))
