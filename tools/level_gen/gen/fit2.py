import fit_cam as F, math, sys
F.CORR = F.CORR[:4]
res = {}
for pitch in [38, 40, 42, 44]:
    for yaw in [33, 36, 39]:
        for fov in [32]:
            f = lambda c: F.err([c[0], c[1], yaw, pitch, c[2]], fov)
            b = F.nm(f, [0, -3, 40], [3, 3, 8], 2000)
            print(pitch, yaw, fov, ["%.2f" % v for v in b], "rms %.1f" % math.sqrt(f(b) / 4))
