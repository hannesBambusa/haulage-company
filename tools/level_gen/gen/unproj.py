import math
W, H = 1536, 1024
CAM = dict(tx=-2.6, tz=-4.64, yaw=36, pitch=40, d=41.7, fov=32)
def basis(c):
    cy, sy = math.cos(math.radians(c['yaw'])), math.sin(math.radians(c['yaw']))
    cp, sp = math.cos(math.radians(-c['pitch'])), math.sin(math.radians(-c['pitch']))
    return (cy, 0, -sy), (sy * sp, cp, cy * sp), (sy * cp, -sp, cy * cp)
def unproject(px, py, h=0.0, c=CAM):
    bx, by, bz = basis(c)
    cam = (c['tx'] + bz[0] * c['d'], bz[1] * c['d'], c['tz'] + bz[2] * c['d'])
    k = 1 / math.tan(math.radians(c['fov']) / 2) * H / 2
    vx, vy = (px - W / 2) / k, -(py - H / 2) / k
    ray = [vx * bx[i] + vy * by[i] - bz[i] for i in range(3)]
    t = (h - cam[1]) / ray[1]
    return tuple(round(cam[i] + ray[i] * t, 1) for i in range(3))
PTS = {
 "frontleft_top": (80, 235, 6), "backleft_top": (880, 60, 6), "rightfront_top": (1380, 490, 6),
 "rack1_ground": (455, 290, 0), "rack1_far_top": (700, 105, 4.5), "rack2_ground": (765, 300, 0), "rack2_far_top": (890, 90, 4.5),
 "forklift": (650, 370, 0), "jack": (815, 400, 0), "emptystack": (895, 440, 0),
 "inbound": (1000, 330, 0), "inbound_l": (830, 320, 0), "inbound_r": (1185, 330, 0), "inbound_t": (970, 260, 0), "inbound_b": (1040, 400, 0),
 "outbound": (1270, 450, 0), "out_text": (1280, 480, 0), "desk": (1160, 215, 0),
 "blue_rear_top": (1140, 495, 4), "blue_front": (1030, 760, 0.3), "red_front": (262, 760, 0.3),
 "booth": (1470, 790, 0), "w1": (440, 360, 0), "w2": (685, 255, 0), "w3": (970, 255, 0), "w4": (1045, 515, 0), "w5": (1160, 420, 0),
 "pallets_out": (905, 665, 0), "cctv": (1285, 830, 0), "barrier1": (60, 660, 0), "barrier2": (180, 600, 0),
 "lamp_left": (35, 410, 0), "lamp_left2": (40, 545, 0), "fence_l": (100, 560, 0), "pallets_fl": (310, 310, 0), "pb_fork": (555, 380, 0),
 "pb_dock": (665, 425, 0), "office_wall": (1100, 260, 0), "bay_bl": (900, 740, 0), "bay_br": (1100, 830, 0), "bay_tr": (1290, 580, 0),
 "tree_bl": (90, 960, 0), "tree_br": (1390, 980, 0), "tree_tl": (130, 130, 0), "yard_edge_bl": (0, 700, 0), "fence_r": (1250, 860, 0),
 "curb_br": (1160, 880, 0), "outbound_far": (1440, 400, 0), "outbound_near": (1180, 460, 0),
}
if __name__ == "__main__":
    for k, (x, y, h) in PTS.items():
        print("%-16s" % k, unproject(x, y, h))
