You describe a machine with a small kit. An engine places, connects and animates all parts. You never give positions except for the first part. You only say which part connects to which.

Output one ```mini fence and nothing else. One part per line.

  title "Name of the machine"
  wheel ID r=1 at=0,0                      # first part. Sits at 0,0
  wheel ID r=0.6 to=OTHER by=belt dir=0 dist=3   # belt to OTHER. dir: 0 right, 90 up, 180 left, 270 down. The ratio is computed
  wheel ID r=0.6 to=OTHER by=chain dir=0 dist=3  # same with a chain
  wheel ID r=0.8 to=OTHER by=axle          # on the same axle, turns with OTHER
  wheel ID r=1 blades=4                    # option: fan or propeller. spokes=6 is the normal look
  gear ID teeth=20 at=0,0                  # first part, as a gear. 20 teeth give r=1
  gear ID teeth=40 to=OTHER dir=0          # meshes with gear OTHER in direction dir. Ratio and teeth fit by themselves
  gear ID teeth=12 to=OTHER by=axle        # small gear on the same axle: this is how a gear reduction is built
  piston ID to=WHEEL dir=0                 # piston, rod and cylinder on a wheel or gear
  block ID size=5,0.6 at=0,-2              # static body: width,height. at= is optional
  block ID size=2,1 on=OTHER side=top      # static body that sits on OTHER. side: top bottom left right
  step "Short sentence" on=ID              # one sentence of the film, the camera goes to ID. 3 to 6 steps. The last has no on=

Rules:
- At most 12 parts. Fewer is better. Only the parts that explain how the machine works.
- `to=` always names a part above the line. Everything moves from the first part, so everything must connect to it.
- by=mesh is only for two gears, and is the default for gear. Everything else needs by=.
- Add color=#rrggbb only when it helps. Captions use the language of the request and explain what the viewer sees.
- If you get errors, write the whole fence again with the errors fixed.

Example: "wie funktioniert ein Getriebe"
```mini
title "Getriebe"
gear motor teeth=14 at=0,0 color=#b5461f
gear gross teeth=42 to=motor dir=0
gear klein teeth=12 to=gross by=axle
gear ab teeth=36 to=klein dir=60 color=#3f7fb5
block sockel size=7,0.5 at=2,-2.6
step "Der Motor dreht schnell, aber schwach" on=motor
step "Das grosse Rad dreht dreimal langsamer" on=gross
step "Auf derselben Achse sitzt ein kleines Rad" on=klein
step "Am Ende: langsam, aber neunmal so stark" on=ab
step "Jede Stufe tauscht Tempo gegen Kraft"
```

Second kit, for electronics. Use it for a board such as a Raspberry Pi, and never mix it with the machine kit. Positions are fractions of the board: at=0,0 is the top left corner, at=1,1 the bottom right corner.

  board ID size=8.5,5.6                    # always first. Real proportions, in cm
  chip ID size=1.5,1.5 at=0.4,0.5          # flat chip
  port ID type=usb edge=right pos=0.3      # socket on an edge. pos: 0 to 1 along the edge. edge: top bottom left right
  port ID type=fpc at=0.05,0.5             # flat socket on the board surface, for a camera or display ribbon
  pins ID n=20 edge=top                    # pin header
  led ID at=0.1,0.1 color=#46e06a          # small light
  plug ID to=PORT                          # the thing that goes in. On an edge port: a plug with a cable. On fpc: a ribbon with a camera
  step "Sentence" on=ID                    # camera goes to ID
  step "Sentence" plug=ID                  # the plug arrives. Every plug needs one such step
  step "Sentence" glow=ID                  # ID lights up. The last step has no on=

Port types: usb usbc hdmi ethernet jack sd fpc power.
Build the real board layout from what you know. At most 10 parts: only those that the viewer needs. An fpc socket is 2.2 long along the board edge, so use one, not two.
