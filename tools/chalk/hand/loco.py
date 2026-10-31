#!/usr/bin/env python3
"""Takes the GLM locomotive and replaces its running gear with one that really runs.

The boiler, cab, frames and tender stay. Wheels, rods, crossheads and valve gear are new.
"""
import math, re, sys
src = open(sys.argv[1]).read().split('\n')

AXLES = [-6.9, -4.65, -2.4]
R = 0.33
ROD = 2.85
Y0, YC = 1.0, 0.90            # axle height, cylinder line height
ZP, ZC, ZM = 1.08, 1.27, 1.42  # wheel face, coupling rod plane, main rod plane


def lines(a, b):
    return src[a - 1:b]


def f(*v):
    return ','.join(f'{x:.4f}'.rstrip('0').rstrip('.') for x in v)


wheel = lines(230, 245)               # the GLM wheel, indented by 12
out = src[:224]
w = lambda n, t: out.append(' ' * n + t)

w(4, 'group drivers_rods')
for i, x in enumerate(AXLES):
    w(6, f'group ws{i}')
    for side in (1, -1):
        w(8, f'group wh{i}{"LR"[side < 0]} at={f(x, Y0, side * 1.15)} rot={"0,180,0" if side < 0 else "0,0,0"}')
        for l in wheel:
            out.append('  ' * 1 + l.replace('at=-0.52,0,0.0', 'at=-0.52,0,0'))
    w(8, f'cyl axle{i} r=0.085 h=2.36 axis=z at={f(x, Y0, 0)} color=#9a9ea5 mat=brushed')
    # Crank pins. The left side leads by a quarter turn.
    for side, ang in ((1, 0), (-1, 90)):
        c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        px, py = x + R * c, Y0 + R * s
        zz = side * (ZM + 0.02) / 2 + side * ZP / 2
        w(8, f'cyl pin{i}{side + 1} r=0.075 h={f(ZM + 0.1 - ZP)} axis=z at={f(px, py, side * (ZM + 0.1 + ZP) / 2)} color=#d4d6da mat=chrome')
        w(8, f'cyl boss{i}{side + 1} r=0.2 h=0.1 axis=z at={f(px, py, side * ZP)} color=#b5231f mat=paint')
        w(8, f'cyl nut{i}{side + 1} r=0.095 h=0.04 axis=z at={f(px, py, side * (ZM + 0.11))} color=#8f939a mat=steel')

# Everything that does not turn stays in the old group.
w(6, 'group static_gear')
out += lines(297, 333)

for side, ang, name in ((1, 0, 'L'), (-1, 90, 'R')):
    c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    ox, oy = R * c, Y0 + R * s
    pinm = (AXLES[1] + ox, oy)
    wx = pinm[0] - math.sqrt(ROD ** 2 - (oy - YC) ** 2)
    z = side * ZM
    zc = side * ZC
    # Coupling rod over all three pins.
    w(4, f'group couple{name} at={f(AXLES[1] + ox, oy, zc)}')
    w(6, f'plate cr{name} pts=-2.32,0.11 -2.2,0.13 -2,0.075 -0.2,0.09 0,0.15 0.2,0.09 2,0.075 2.2,0.13 2.32,0.11 2.32,-0.11 2.2,-0.13 2,-0.075 0.2,-0.09 0,-0.15 -0.2,-0.09 -2,-0.075 -2.2,-0.13 -2.32,-0.11 h=0.05 color=#d8dade mat=brushed')
    for i in (-1, 0, 1):
        w(6, f'cyl crb{name}{i + 1} r=0.105 h=0.08 hole=0.075 axis=z at={f(i * 2.25, 0, 0)} color=#c9a44a mat=metal')
    # Main rod. Local x runs from the crosshead to the pin.
    ang2 = math.degrees(math.atan2(oy - YC, pinm[0] - wx))
    w(4, f'group main{name} at={f(wx, YC, z)} rot=0,0,{ang2:.4f}')
    w(6, f'plate mr{name} pts=0.1,0.07 {ROD - 0.25:.3f},0.1 {ROD - 0.1:.3f},0.17 {ROD + 0.12:.3f},0.17 {ROD + 0.12:.3f},-0.17 {ROD - 0.1:.3f},-0.17 {ROD - 0.25:.3f},-0.1 0.1,-0.07 h=0.05 color=#e0e2e6 mat=brushed')
    w(6, f'cyl mrb{name} r=0.11 hole=0.075 h=0.08 axis=z at={f(ROD, 0, 0)} color=#c9a44a mat=metal')
    w(6, f'cyl mrs{name} r=0.09 h=0.07 axis=z color=#c9a44a mat=metal')
    # Crosshead and piston rod.
    w(4, f'group xh{name} at={f(wx, YC, z)}')
    w(6, f'box xb{name} size=0.34,0.15,0.13 round=0.02 color=#d7d9dd mat=chrome')
    w(6, f'cyl xp{name} r=0.05 h=0.17 axis=z color=#9aa0a6 mat=brushed')
    w(6, f'cyl pr{name} r=0.04 h=1.1 axis=x at=-0.6,0,0 color=#eceef1 mat=chrome')
    w(6, f'box ul{name} size=0.06,0.1,0.03 at=0,-0.1,{side * 0.08:.3f} color=#c9c9c9 mat=brushed')
    # Slide bars.
    w(4, f'box bar{name}t size=1.06,0.05,0.14 at={f(-7.62, YC + 0.1, z)} color=#d9dbdf mat=chrome')
    w(4, f'box bar{name}b size=1.06,0.05,0.14 at={f(-7.62, YC - 0.1, z)} color=#d9dbdf mat=chrome')
    w(4, f'box brk{name} size=0.1,0.5,0.2 at={f(-7.08, YC, z)} color=#3a3d42 mat=cast')
    # Walschaerts gear: return crank, eccentric rod, link, radius rod, valve rod, combination lever.
    ecc_a = ang + 270 - 15
    ex, ey = AXLES[1] + 0.2 * math.cos(math.radians(ecc_a)), Y0 + 0.2 * math.sin(math.radians(ecc_a))
    lx, ly = -5.7, 1.56
    lb = (lx, ly - 0.28)
    lt = (lx, ly + 0.2)
    vx, vy = -7.72, 1.42
    w(4, f'group ecc{name}')
    w(6, f'tube er{name} pts={f(ex, ey, z + side * 0.06)} {f(lb[0], lb[1], z + side * 0.06)} r=0.024 color=#d0d3d8 mat=brushed')
    w(6, f'cyl eb{name} r=0.055 h=0.06 axis=z at={f(ex, ey, z + side * 0.06)} color=#c9a44a mat=metal')
    w(4, f'group link{name}')
    w(6, f'plate lk{name} pts={f(lx - 0.07, ly - 0.3)} {f(lx + 0.07, ly - 0.3)} {f(lx + 0.05, ly + 0.26)} {f(lx - 0.05, ly + 0.26)} h=0.05 at=0,0,{f(z)} color=#d5d7db mat=brushed')
    w(6, f'cyl lkp{name} r=0.04 h=0.09 axis=z at={f(lx, ly, z)} color=#9aa0a6 mat=chrome')
    w(4, f'box lkb{name} size=0.12,0.1,0.28 at={f(lx, ly, z - side * 0.2)} color=#3a3d42 mat=cast')
    w(4, f'group radius{name}')
    w(6, f'tube rr{name} pts={f(lt[0], lt[1], z)} {f(vx + 0.2, vy, z)} r=0.024 color=#dfe1e5 mat=brushed')
    w(4, f'group vrod{name}')
    w(6, f'tube vr{name} pts={f(vx + 0.2, vy, z)} {f(vx - 0.7, vy, z)} r=0.026 color=#eceef1 mat=chrome')
    w(6, f'sphere vb{name} r=0.04 at={f(vx + 0.2, vy, z)} color=#b5b8bd mat=chrome')
    w(4, f'group lever{name}')
    w(6, f'tube cl{name} pts={f(wx, YC - 0.1, z + side * 0.08)} {f(vx + 0.2, vy, z + side * 0.08)} r=0.022 color=#d6d8dc mat=brushed')

    joints = globals().setdefault('joints', [])
    joints += [
        f'couple couple{name} crank=ws1 pin={f(AXLES[1] + ox, oy, zc)}',
        f'piston xh{name} crank=ws1 pin={f(*pinm, z)} wrist={f(wx, YC, z)} dir=1,0,0',
        f'rod main{name} crank=ws1 pin={f(*pinm, z)} wrist=xh{name}',
        f'sway link{name} of=ws1 at={f(lx, ly, z)} axis=z deg=16 phase={ang + 90}',
        f'sway vrod{name} of=ws1 dir=1,0,0 by=0.11 phase={ang + 80}',
        f'bar ecc{name} a={f(ex, ey, z + side * 0.06)} b={f(lb[0], lb[1], z + side * 0.06)} ja=ws1 jb=link{name}',
        f'bar radius{name} a={f(lt[0], lt[1], z)} b={f(vx + 0.2, vy, z)} ja=link{name} jb=vrod{name}',
        f'bar lever{name} a={f(wx, YC - 0.1, z + side * 0.08)} b={f(vx + 0.2, vy, z + side * 0.08)} ja=xh{name} jb=vrod{name}',
    ]

# Cylinders stay, the old rods and links on them go.
out += lines(334, 356)
out += lines(385, 392)
rest = src[392:]
end = next(i for i, l in enumerate(rest) if l.strip() == 'anim')
out += rest[:end]

# Track on the top level, outside `whole`.
w(2, 'group line')
w(4, 'box ballast size=60,0.3,5.4 at=-3,-0.42,0 color=#4c4842 mat=matte')
for s in (1, -1):
    w(4, f'box rail{s + 1} size=60,0.12,0.09 at={f(-3, -0.06, s * 1.0)} color=#8a8d92 mat=brushed')
    w(4, f'box railf{s + 1} size=60,0.03,0.18 at={f(-3, -0.135, s * 1.0)} color=#5a5048 mat=metal')
w(4, 'group sleepers')
w(6, 'repeat 96 step=0.62,0,0 at=-33,-0.2,0')
w(8, 'box sl size=0.26,0.14,3 round=0.01 color=#3d3126 mat=wood')

w(2, 'mech')
w(4, f'rotor ws1 at={f(AXLES[1], Y0, 0)} axis=z')
for i in (0, 2):
    w(4, f'rotor ws{i} at={f(AXLES[i], Y0, 0)} axis=z of=ws1')
for x, in_, r in ((-11, 'leading_truck', 0.51), (-9, 'leading_truck', 0.51), (0.45, 'trailing_wheel', 0.67)):
    w(4, f'rotor w{x} at={f(x, r if r < 0.6 else 0.625, 0)} axis=z in={in_} claim={r} width=1.2 skip=shoe,spring,box,leaf,hanger,brake of=ws1 ratio={1 / (0.5 if r < 0.6 else 0.625):.4f}')
for j, x in enumerate((4.2, 5.7, 9.3, 10.8)):
    w(4, f'rotor t{j} at={f(x, 0.5, 0)} axis=z in=tender_bogies claim=0.54 width=1.2 skip=shoe,box,leaf,spring,hanger of=ws1 ratio=2')
for j in joints:
    w(4, j)
w(4, 'travel sleepers of=ws1 dir=1,0,0 r=1 wrap=0.62')
w(2, 'anim')
for text, sec, turns, cam in [
    ('Baureihe 01: alle Räder und Stangen hängen an einer Drehung', 4, 2.5, 'camera view=38,12 zoom=1'),
    ('Der Dampf drückt den Kolben, die Treibstange dreht das Rad', 5, 2.5, 'camera view=12,5 zoom=3.2 on=mainL'),
    ('Die Kuppelstange überträgt die Kraft auf alle drei Achsen', 4, 2, 'camera view=-6,4 zoom=2.6 on=ws1'),
    ('Heusinger-Steuerung: Schieber läuft gegenüber dem Kolben versetzt', 4, 1.5, 'camera view=24,8 zoom=4 on=linkL'),
    ('Volle Fahrt', 4, 4, 'camera view=38,12 zoom=1'),
]:
    w(4, f'step "{text}" {sec}')
    w(6, f'run turns={turns}')
    w(6, cam)
text = '\n'.join(out)
text = text.replace('model obj 1100 620 keep=1 tidy=1 view=35,14', 'model obj 1100 620 keep=1 tidy=1 view=38,12 fit=whole')
text = text.replace('group fit_16911 at=-1.1198,1.4921,0.0000', 'group fit_16911 at=-1.1198,0.86,0.0000')
print(text)
