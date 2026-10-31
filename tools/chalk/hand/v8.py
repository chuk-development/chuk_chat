#!/usr/bin/env python3
"""Cross-plane pushrod V8, built by hand to prove the kinematics. Writes Chalk to stdout.

Crank along x. Cylinder banks in the yz plane at +45 and -45 degrees.
"""
import math

R, ROD, PITCH, OFFS = 0.43, 1.55, 1.2, 0.12
BORE = 0.46
BANK = {'A': 45.0, 'B': -45.0}
THROW_X = [-1.8, -0.6, 0.6, 1.8]
THROW_DEG = [0.0, 90.0, 270.0, 180.0]
CAM_Y = 1.1
DECK = 2.36


def pol(deg, r):
    """Point in the yz plane. Angle runs from +y to +z."""
    a = math.radians(deg)
    return r * math.cos(a), r * math.sin(a)


def f(*v):
    return ','.join(f'{x:.4f}'.rstrip('0').rstrip('.') if abs(x) > 1e-9 else '0' for x in v)


out = []
def w(n, line):
    out.append('  ' * n + line)


def arc(a0, a1, r, n=9):
    return [(r * math.sin(math.radians(a0 + (a1 - a0) * i / n)), r * math.cos(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def web(id_, x, deg):
    """Crank web with counterweight. Local y points to the pin."""
    pts = arc(-58, 58, 0.75)[::-1]
    pts = [(u, -v) for u, v in pts]
    top = [(0.22 * math.cos(math.radians(a)), R + 0.22 * math.sin(math.radians(a))) for a in range(0, 181, 20)]
    pts = pts[-1:] + [(0.3, -0.12), (0.24, R * 0.5)] + top + [(-0.24, R * 0.5), (-0.3, -0.12)] + pts[:-1]
    txt = ' '.join(f(u, v) for u, v in pts)
    w(3, f'group {id_} at={f(x, 0, 0)} rot={f(deg, 0, 0)}')
    w(4, f'plate {id_}p pts={txt} h=0.12 rot=0,90,0 color=#6f7277 mat=cast')
    w(4, f'cyl {id_}c r=0.05 h=0.13 axis=x at=0,-0.52,0.3 color=#2a2c30 mat=metal')
    w(4, f'cyl {id_}d r=0.05 h=0.13 axis=x at=0,-0.52,-0.3 color=#2a2c30 mat=metal')


def crank():
    w(2, 'group crank')
    w(3, f'cyl nose r=0.2 h=1.1 axis=x at={f(-2.95, 0, 0)} color=#a9adb4 mat=chrome')
    w(3, f'cyl tail r=0.24 h=0.5 axis=x at={f(2.75, 0, 0)} color=#a9adb4 mat=chrome')
    for i in range(5):
        w(3, f'cyl main{i} r=0.24 h=0.3 axis=x at={f(-2.4 + 1.2 * i, 0, 0)} color=#c9ccd2 mat=chrome')
    for i, (x, deg) in enumerate(zip(THROW_X, THROW_DEG)):
        y, z = pol(deg, R)
        w(3, f'cyl pin{i} r=0.17 h=0.5 axis=x at={f(x, y, z)} color=#d6d9de mat=chrome')
        web(f'web{i}a', x - 0.31, deg)
        web(f'web{i}b', x + 0.31, deg)
    # Pulley, damper and flywheel turn with the crank.
    w(3, 'lathe pulley pts=0,0.2 0,0.62 0.06,0.66 0.1,0.6 0.14,0.66 0.18,0.6 0.22,0.66 0.26,0.6 0.3,0.66 0.36,0.62 0.36,0.2 axis=x at=-3.5,0,0 color=#2c2e33 mat=cast')
    w(3, 'cyl pulleybolt r=0.09 h=0.1 axis=x at=-3.52,0,0 color=#c4c7cc mat=chrome')
    w(3, f'gear gear_crank teeth=24 r=0.3667 h=0.14 axis=x at=-2.72,0,0 color=#b9b090 mat=brushed')
    w(3, 'group flywheel at=3.1,0,0')
    w(4, 'cyl fw r=1.18 h=0.16 axis=x color=#6c6f75 mat=cast')
    w(4, 'gear ring teeth=96 r=1.27 h=0.1 axis=x color=#8d9096 mat=metal')
    w(4, 'ring 8 r=0.4 axis=x at=0.1,0,0')
    w(5, 'cyl fwb r=0.05 h=0.06 axis=x color=#d0d3d8 mat=chrome')
    w(4, 'ring 6 r=0.82 axis=x')
    w(5, 'cyl fwh r=0.12 h=0.17 axis=x color=#3a3c41 mat=cast')


def bank_axes(b):
    a = BANK[b]
    d = pol(a, 1)
    e = pol(a + 90, 1)
    return a, d, e


def cylinder(b, i):
    """Rest pose wrist. Returns everything joints need."""
    a, d, e = bank_axes(b)
    side = -1 if b == 'A' else 1
    x = THROW_X[i] + side * OFFS
    al = THROW_DEG[i]
    py, pz = pol(al, R)
    delta = math.radians(al - a)
    s0 = R * math.cos(delta) + math.sqrt(ROD ** 2 - (R * math.sin(delta)) ** 2)
    wy, wz = d[0] * s0, d[1] * s0
    tdc = (a - al) % 360
    return dict(b=b, i=i, x=x, py=py, pz=pz, wy=wy, wz=wz, a=a, d=d, e=e, tdc=tdc, s0=s0)


def piston(c):
    pid = f"piston_{c['b']}{c['i']}"
    w(2, f"group {pid} at={f(c['x'], c['wy'], c['wz'])} rot={f(c['a'], 0, 0)}")
    w(3, f'lathe {pid}b pts=-0.3,0.42 -0.3,0.445 -0.05,0.452 0.1,0.452 0.1,0.44 0.12,0.44 0.12,0.452 0.16,0.452 0.16,0.44 0.18,0.44 0.18,0.452 0.22,0.452 0.22,0.44 0.24,0.44 0.24,0.452 0.33,0.452 0.345,0.44 0.345,0.3 0.33,0.2 0.33,0 axis=y color=#c7cbd1 mat=brushed')
    for k, y in enumerate((0.13, 0.17, 0.23)):
        w(3, f'cyl {pid}r{k} r=0.456 h=0.018 axis=y at=0,{y},0 color=#35373c mat=metal')
    w(3, f'cyl {pid}w r=0.1 h=0.74 axis=x color=#e2e4e8 mat=chrome')
    w(3, f'cyl {pid}c r=0.2 h=0.14 axis=x at=-0.27,0,0 color=#aeb2b8 mat=brushed')
    w(3, f'cyl {pid}e r=0.2 h=0.14 axis=x at=0.27,0,0 color=#aeb2b8 mat=brushed')


def rod(c):
    rid = f"rod_{c['b']}{c['i']}"
    uy, uz = c['wy'] - c['py'], c['wz'] - c['pz']
    a = math.degrees(math.atan2(uz, uy))
    L = ROD
    w(2, f"group {rid} at={f(c['x'], c['py'], c['pz'])} rot={f(a, 0, 0)}")
    out_pts = [(0.075, L - 0.13), (0.13, 0.26), (0.26, 0.12), (0.26, -0.02), (-0.26, -0.02), (-0.26, 0.12), (-0.13, 0.26), (-0.075, L - 0.13)]
    w(3, f"plate {rid}s pts={' '.join(f(u, v) for u, v in out_pts)} h=0.12 rot=0,90,0 color=#8d9198 mat=cast")
    w(3, f'plate {rid}i pts=0.04,{L - 0.2:.3f} 0.08,0.32 -0.08,0.32 -0.04,{L - 0.2:.3f} h=0.2 rot=0,90,0 color=#7a7e85 mat=cast')
    w(3, f'cyl {rid}big r=0.27 hole=0.17 h=0.2 axis=x color=#969aa1 mat=cast')
    w(3, f'cyl {rid}brg r=0.178 hole=0.165 h=0.21 axis=x color=#c8873f mat=metal')
    w(3, f'cyl {rid}cap r=0.05 h=0.12 at=0,-0.3,0 axis=z color=#8d9198 mat=cast')
    w(3, f'cyl {rid}small r=0.15 hole=0.1 h=0.2 axis=x at=0,{L},0 color=#969aa1 mat=cast')
    for s in (-1, 1):
        w(3, f'cyl {rid}b{s + 1} r=0.035 h=0.42 at=0,-0.1,{s * 0.235} color=#ddd mat=chrome')


def shell_block():
    """Hollow block of closed solids, so the cut shows real walls and open bores."""
    w(2, 'group block shell=1 color=#5d6b78 mat=cast')
    for b in 'AB':
        a, d, e = bank_axes(b)
        for i in range(4):
            c = cylinder(b, i)
            s = 1.62
            y, z = d[0] * s, d[1] * s
            w(3, f"group liner_{b}{i} at={f(c['x'], y, z)} rot={f(a, 0, 0)}")
            w(4, f'cyl liner_{b}{i}c r=0.53 hole=0.462 h=1.48 axis=y color=#9b9ea3 mat=brushed shell=1')
            w(4, f'cyl jacket_{b}{i}a r=0.6 hole=0.53 h=0.06 axis=y at=0,0.71,0 color=#5d6b78 mat=cast shell=1')
        side = -1 if b == 'A' else 1
        mid = sum(THROW_X) / 4 + side * OFFS
        for t, v in ((-0.66, 'o'), (0.66, 'i')):
            cy, cz = d[0] * 1.62 + e[0] * t, d[1] * 1.62 + e[1] * t
            w(3, f'box wall_{b}{v} size=5.2,1.5,0.12 at={f(mid, cy, cz)} rot={f(a, 0, 0)} round=0 shell=1')
        dy, dz = d[0] * DECK, d[1] * DECK
        for i in range(5):
            x = -2.4 + 1.2 * i + side * OFFS
            w(3, f'box deck_{b}{i} size=0.16,0.1,1.42 at={f(x, dy, dz)} rot={f(a, 0, 0)} round=0 shell=1')
        for t in (-1, 1):
            cy, cz = d[0] * DECK + e[0] * t * 0.66, d[1] * DECK + e[1] * t * 0.66
            w(3, f'box lip_{b}{t + 1} size=5.2,0.1,0.14 at={f(mid, cy, cz)} rot={f(a, 0, 0)} round=0 shell=1')
    # Crankcase: side walls, front and rear plates and bearing webs.
    for s, n in ((1, 'p'), (-1, 'm')):
        w(3, f"plate case{n} pts=-2.7,0 -2.7,0.18 2.7,0.18 2.7,0 h=0 rot=0,0,0 color=#5d6b78" if False else f'box case{n} size=5.5,1.0,0.12 at={f(0, -0.25, s * 1.27)} round=0 shell=1')
        w(3, f'box case{n}b size=5.5,0.12,0.42 at={f(0, 0.34, s * 1.34)} rot={f(s * 45, 0, 0)} round=0 shell=1')
    for i in range(5):
        x = -2.4 + 1.2 * i
        pts = ' '.join(f(u, v) for u, v in [(-1.3, -0.74), (-0.3, -0.74), (-0.3, -0.26), (-0.27, 0.1), (-0.1, 0.27), (0.1, 0.27), (0.27, 0.1), (0.3, -0.26), (0.3, -0.74), (1.3, -0.74), (1.3, -0.62), (0.42, -0.62), (0.42, 0.42), (-0.42, 0.42), (-0.42, -0.62), (-1.3, -0.62)])
        w(3, f'plate bulk{i} pts={pts} h=0.1 rot=0,90,0 at={f(x, 0, 0)} shell=1')
    w(2, 'group pan shell=1 color=#2e3136 mat=paint')
    w(3, 'box panfloor size=5.5,0.08,2.3 at=0,-1.42,0 round=0 shell=1')
    for s in (-1, 1):
        w(3, f'box panside{s + 1} size=5.5,0.72,0.08 at={f(0, -1.08, s * 1.15)} round=0 shell=1')
    for s in (-1, 1):
        w(3, f'box panend{s + 1} size=0.08,0.72,2.3 at={f(s * 2.75, -1.08, 0)} round=0 shell=1')


def head(b):
    a, d, e = bank_axes(b)
    side = -1 if b == 'A' else 1
    mid = sum(THROW_X) / 4 + side * OFFS
    H = DECK + 0.28
    y, z = d[0] * H, d[1] * H
    w(2, f'group head_{b} at={f(mid, y, z)} rot={f(a, 0, 0)} shell=1 color=#6b7a88 mat=cast')
    w(3, f'box head_{b}o size=5.2,0.42,0.1 at=0,0,0.76 round=0 shell=1')
    w(3, f'box head_{b}i size=5.2,0.42,0.1 at=0,0,-0.76 round=0 shell=1')
    w(3, f'box head_{b}t size=5.2,0.1,1.62 at=0,-0.18,0 round=0 shell=1' if False else f'box head_{b}p size=5.2,0.08,0.3 at=0,0.2,0.66 round=0 shell=1')
    w(3, f'box head_{b}q size=5.2,0.08,0.3 at=0,0.2,-0.66 round=0 shell=1')
    w(2, f"group cover_{b} at={f(mid, d[0] * (H + 0.62), d[1] * (H + 0.62))} rot={f(a, 0, 0)} shell=1 color=#b5461f mat=paint")
    w(3, f'box cover_{b}o size=5.2,0.92,0.08 at=0,0,0.78 round=0 shell=1')
    w(3, f'box cover_{b}i size=5.2,0.92,0.08 at=0,0,-0.78 round=0 shell=1')
    w(3, f'box cover_{b}t size=5.2,0.08,1.64 at=0,0.46,0 round=0 shell=1')


def valvetrain(c, joints):
    """One intake and one exhaust valve, with lifter, pushrod and rocker."""
    b, i = c['b'], c['i']
    a, d, e = c['a'], c['d'], c['e']
    inward = -1 if b == 'A' else 1  # e points away from the V for bank A
    # Firing: this cylinder burns at crank angle `fire` in the 720 degree cycle.
    fire = c['fire']
    for kind, dx, peak, col in (('in', -0.2, fire - 250, '#d7dade'), ('ex', 0.2, fire + 250, '#b78f6c')):
        name = f'{kind}_{b}{i}'
        vx = c['x'] + dx
        seat = DECK + 0.02
        head_y, head_z = d[0] * seat, d[1] * seat
        w(2, f'group valve_{name} at={f(vx, head_y, head_z)} rot={f(a, 0, 0)}')
        w(3, f'lathe valve_{name}h pts=-0.05,0.2 -0.03,0.2 0,0.12 0.08,0.04 0.1,0.03 axis=y color={col} mat=brushed')
        w(3, f'cyl valve_{name}s r=0.03 h=0.84 at=0,0.5,0 axis=y color={col} mat=chrome')
        w(3, f'cyl valve_{name}k r=0.07 h=0.05 at=0,0.82,0 axis=y color=#555 mat=metal')
        w(3, f'spring valve_{name}p r=0.1 wire=0.016 turns=6 h=0.36 at=0,0.62,0 axis=y color=#2f6bd6 mat=metal')
        joints.append(f'lift valve_{name} of=cam dir={f(0, -d[0], -d[1])} by=0.16 at={f(peak / 2 % 360)} width=125')
        # Rocker pivots above the head and presses the valve down.
        t = DECK + 0.98
        px, py, pz = vx, d[0] * t + inward * e[0] * 0.3, d[1] * t + inward * e[1] * 0.3
        tip = (d[0] * (DECK + 0.87), d[1] * (DECK + 0.87))
        cup = (d[0] * (DECK + 0.87) + inward * e[0] * 0.6, d[1] * (DECK + 0.87) + inward * e[1] * 0.6)
        w(2, f'group rocker_{name}')
        w(3, f'tube rocker_{name}a pts={f(vx, *tip)} {f(px, py, pz)} {f(vx, *cup)} r=0.05 color=#c5c8cd mat=brushed')
        w(3, f'cyl rocker_{name}b r=0.08 h=0.16 axis=x at={f(px, py, pz)} color=#8e9298 mat=chrome')
        joints.append(f'rocker rocker_{name} of=valve_{name} at={f(px, py, pz)} axis=x deg={f((1 if b == "A" else -1) * -8.2)}')
        # Pushrod from the cam to the rocker cup.
        cam = (0, CAM_Y)
        u = (cup[0] - cam[0], cup[1] - cam[1])
        l = math.hypot(*u)
        u = (u[0] / l, u[1] / l)
        low = (cam[0] + u[0] * 0.28, cam[1] + u[1] * 0.28)
        w(2, f'group push_{name}')
        w(3, f'tube push_{name}r pts={f(vx, *low)} {f(vx, *cup)} r=0.028 color=#d9dce0 mat=chrome')
        w(3, f'cyl push_{name}l r=0.075 h=0.28 at={f(vx, cam[0] + u[0] * 0.3, cam[1] + u[1] * 0.3)} rot={f(math.degrees(math.atan2(u[1], u[0])), 0, 0)} axis=y color=#73777d mat=metal')
        joints.append(f'lift push_{name} of=cam dir={f(0, *u)} by=0.105 at={f(peak / 2 % 360)} width=125')
        # Lobe on the cam points to the follower at this cam angle.
        c.setdefault('lobes', []).append((vx, u, peak / 2 % 360, name))


def camshaft(cyls):
    w(2, f'group cam at={f(0, CAM_Y, 0)}')
    w(3, 'cyl camcore r=0.075 h=5.4 axis=x color=#b8bcc2 mat=brushed')
    for i in range(5):
        w(3, f'cyl camj{i} r=0.14 h=0.16 axis=x at={f(-2.4 + 1.2 * i, 0, 0)} color=#d4d7dc mat=chrome')
    for c in cyls:
        for vx, u, peak, name in c['lobes']:
            # The lobe must point along u when the cam has turned by `peak` degrees (the cam runs backwards).
            rest = math.degrees(math.atan2(u[1], u[0])) + peak
            w(3, f'group lobe_{name} at={f(vx, 0, 0)} rot={f(rest, 0, 0)}')
            w(4, f'plate lobe_{name}p pts=0.13,0 0.09,0.1 0.04,0.19 0,0.21 -0.04,0.19 -0.09,0.1 -0.13,0 -0.09,-0.09 0,-0.13 0.09,-0.09 h=0.1 rot=0,90,0 color=#a7abb1 mat=metal')
    w(3, 'group cam_gear_g at=-2.72,0,0')
    w(4, 'gear gear_cam teeth=48 r=0.7333 h=0.14 axis=x phase=0.0655 color=#9c8e5b mat=brushed')
    w(4, 'cyl camdisk r=0.3 h=0.17 axis=x color=#6f7277 mat=cast')
    w(4, 'ring 6 r=0.5 axis=x')
    w(5, 'cyl camhole r=0.1 h=0.18 axis=x color=#24262a mat=cast')


def dress():
    """Everything around the core: intake, exhaust, belt drive, covers."""
    for b, sign in (('A', 1), ('B', -1)):
        a, d, e = bank_axes(b)
        side = -1 if b == 'A' else 1
        mid = sum(THROW_X) / 4 + side * OFFS
        T = DECK + 1.36
        y, z = d[0] * T, d[1] * T
        w(2, f'group trim_{b} at={f(mid, y, z)} rot={f(a, 0, 0)} shell=1')
        for k in range(9):
            w(3, f'box rib_{b}{k} size=0.05,0.05,1.5 at={f(-2.4 + 0.6 * k, 0.04, 0)} round=0.015 color=#d4633a mat=paint shell=1')
        for k in range(10):
            for s in (-1, 1):
                w(3, f'cyl cb_{b}{k}{s + 1} r=0.035 h=0.05 axis=y at={f(-2.5 + 0.555 * k, 0.03, s * 0.79)} color=#d8dade mat=chrome shell=1')
        w(3, f'cyl cap_{b} r=0.17 h=0.12 axis=y at=1.7,0.1,0.3 color=#16171a mat=rubber shell=1')
    # Exhaust headers on the closed bank: four pipes into one collector.
    a, d, e = bank_axes('B')
    for i in range(4):
        c = cylinder('B', i)
        p0 = (c['x'] + 0.2, d[0] * (DECK + 0.14) - e[0] * 0.82, d[1] * (DECK + 0.14) - e[1] * 0.82)
        p1 = (c['x'] + 0.2, p0[1] - e[0] * 0.5, p0[2] - e[1] * 0.5)
        p2 = (c['x'] * 0.8 + 0.3, 0.3, -2.75)
        p3 = (2.5, -1.1, -2.2)
        w(2, f'tube header{i} pts={f(*p0)} {f(*p1)} {f(*p2)} {f(*p3)} r=0.11 color=#7d6a58 mat=brushed')
        w(2, f'box flange{i} size=0.42,0.08,0.34 at={f(*p0)} rot={f(a + 90, 0, 0)} round=0 color=#6e6256 mat=cast')
    w(2, 'tube collector pts=2.4,-1.1,-2.2 3.0,-1.25,-2.2 4.3,-1.3,-2.2 r=0.2 color=#8a7866 mat=brushed')
    # Intake on top of the V.
    w(2, 'group intake color=#a8acb2 mat=cast')
    w(3, f'loft plenum sections=-2.2,0.5,0.5 -1,0.7,0.62 1,0.7,0.62 2.2,0.5,0.5 axis=x at=0,3.25,0')
    for b in 'AB':
        for i in range(4):
            c = cylinder(b, i)
            d = c['d']
            port = (c['x'] - 0.2, d[0] * (DECK + 0.18) + (0.6 * (1 if b == 'A' else 1)) * 0.7, d[1] * (DECK + 0.18) - (0.42 if b == 'A' else -0.42))
            w(3, f'tube runner_{b}{i} pts={f(c["x"] * 0.9, 3.25, 0)} {f(c["x"] * 0.95, 3.1, port[2] * 0.5)} {f(*port)} r=0.1')
    w(3, 'cyl carb r=0.32 h=0.42 axis=y at=0,3.68,0 color=#c6a24c mat=brushed')
    w(3, 'cyl filter r=0.95 r2=0.95 h=0.3 axis=y at=0,4.04,0 color=#17181b mat=paint')
    w(3, 'cyl filterel r=0.86 h=0.31 axis=y at=0,4.04,0 color=#d8d0ba mat=fabric')
    w(3, 'cyl filtertop r=0.97 h=0.05 axis=y at=0,4.21,0 color=#17181b mat=paint')
    w(3, 'cyl wing r=0.09 h=0.1 axis=y at=0,4.27,0 color=#d0d3d8 mat=chrome')
    # Front: timing cover stays open, belt drive in front of it.
    w(2, 'group waterpump at=-3.5,1.05,0')
    w(3, 'cyl wp r=0.42 h=0.12 axis=x color=#3b3e44 mat=cast')
    w(3, 'cyl wpg r=0.46 hole=0.36 h=0.06 axis=x color=#4a4e55 mat=cast')
    w(3, 'ring 5 r=0.2 axis=x')
    w(4, 'cyl wph r=0.07 h=0.13 axis=x color=#17181b mat=cast')
    w(2, 'group altern at=-3.5,1.25,-1.45')
    w(3, 'cyl alp r=0.26 h=0.12 axis=x color=#3b3e44 mat=cast')
    w(3, 'box alm size=0.46,0.05,0.05 color=#d8dade mat=chrome')
    w(2, 'cyl albody r=0.5 h=0.8 axis=x at=-3.0,1.25,-1.45 color=#c2c4c8 mat=cast')
    pts = [(-1.0, -0.62), (0.0, -0.66), (1.35, -0.72), (1.72, -1.15), (1.25, -1.72), (0.62, -1.0)]
    belt = ' '.join(f(-3.5, 0.62 * math.cos(math.radians(t)), 0.62 * math.sin(math.radians(t))) for t in (130, 180, 230))
    w(2, f'tube belt pts=-3.5,1.5,0.1 -3.5,1.49,-0.1 -3.5,1.5,-1.45 -3.5,1.2,-1.72 -3.5,0.98,-1.5 -3.5,0.6,-0.6 -3.5,0.05,-0.66 -3.5,-0.64,-0.1 -3.5,-0.45,0.48 -3.5,0.3,0.55 -3.5,1.05,0.47 -3.5,1.5,0.1 r=0.06 flat=4 color=#141517 mat=rubber')
    w(2, 'cyl oilfilter r=0.3 h=0.7 axis=z at=-1.6,-0.6,-1.66 color=#d8a21c mat=paint')
    w(2, 'cyl starter r=0.34 h=1.0 axis=x at=2.2,-0.75,-1.5 color=#25272b mat=cast')


def build():
    cyls = [cylinder(b, i) for b in 'AB' for i in range(4)]
    # Eight power strokes in 720 degrees, one each 90 degrees.
    by_tdc = {}
    for c in cyls:
        by_tdc.setdefault(round(c['tdc']), []).append(c)
    for tdc, group in by_tdc.items():
        for k, c in enumerate(group):
            c['fire'] = tdc + 360 * k
    w(0, 'canvas dark')
    w(0, 'title "Quermotor nein, V8: 90 Grad, Querebene, untenliegende Nockenwelle"' if False else 'title "V8 Cross-Plane, 90 Grad"')
    w(0, 'model v8 1100 620 keep=1 view=26,12 cut=0,-0.7071,0.7071,0.001 cap=#a8321f')
    w(1, 'group engine')
    crank()
    for c in cyls:
        piston(c)
        rod(c)
    shell_block()
    head('A'); head('B')
    joints = []
    for c in cyls:
        valvetrain(c, joints)
    camshaft(cyls)
    dress()
    # Flames.
    for c in cyls:
        n = f"{c['b']}{c['i']}"
        y, z = c['d'][0] * (c['s0'] + 0.5), c['d'][1] * (c['s0'] + 0.5)
        w(2, f"sphere flame_{n} r=0.4 scale=1,0.32,1 rot={f(c['a'], 0, 0)} at={f(c['x'], y, z)} color=#ff8a24 mat=light")
    w(1, 'mech')
    w(2, 'rotor crank at=0,0,0 axis=x')
    w(2, f'rotor cam at={f(0, CAM_Y, 0)} axis=x of=crank ratio=-0.5')
    w(2, 'rotor waterpump at=-3.5,1.05,0 axis=x of=crank ratio=1.45')
    w(2, 'rotor altern at=-3.5,1.25,-1.45 axis=x of=crank ratio=2.4')
    for c in cyls:
        n = f"{c['b']}{c['i']}"
        pin = f(THROW_X[c['i']], c['py'], c['pz'])
        pin2 = f(c['x'], c['py'], c['pz'])
        w(2, f"piston piston_{n} crank=crank pin={pin2} wrist={f(c['x'], c['wy'], c['wz'])}")
        w(2, f'rod rod_{n} crank=crank pin={pin2} wrist=piston_{n}')
        y, z = c['d'][0] * (c['s0'] + 0.5), c['d'][1] * (c['s0'] + 0.5)
        w(2, f"fire flame_{n} of=crank at={f(c['x'], y, z)} piston=piston_{n} phase={f(c['fire'] + 18)} width=100 cycle=720")
    for j in joints:
        w(2, j)
    w(1, 'anim')
    steps = [
        ('Eine einzige Welle treibt alles: Kolben, Pleuel, Nocken und Ventile', 3.0, 3, 'camera view=26,12 zoom=1.25'),
        ('Acht Kolben, 90 Grad versetzt: alle 90 Grad zündet ein Zylinder', 3.5, 4, 'camera view=20,6 zoom=1.9 on=piston_A1'),
        ('Pleuel wandeln das Auf und Ab in die Drehung der Kurbelwelle', 4.0, 2.5, 'camera view=8,-6 zoom=2.2 on=crank'),
        ('Die Nockenwelle läuft halb so schnell und öffnet die Ventile', 4.0, 2.5, 'camera view=34,22 zoom=2.3 on=head_A'),
        ('Gesamter Motor unter Last', 3.0, 5, 'camera view=26,12 zoom=1.25'),
    ]
    for text, sec, turns, cam in steps:
        w(2, f'step "{text}" {sec}')
        w(3, f'run turns={turns}')
        w(3, cam)
    return '\n'.join(out) + '\n'


print(build(), end='')
