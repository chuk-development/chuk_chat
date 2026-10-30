
# Master examples

These are excellent results. Study the amount of detail, the use of on=, and how real features are built. Do not copy them for other subjects.

## Farm tractor

```chalk
canvas paper
title "Farm tractor"
model tractor 900 470 view=-34,20
  body chassis top=-2.2,1.05 -2.0,1.22 -1.2,1.32 0.0,1.32 1.5,1.36 bottom=-2.2,0.55 -2.0,0.5 -1.2,0.5 0.0,0.5 1.5,0.5 width=-2.2,0.52 -2.0,0.78 -1.2,0.84 0.0,0.86 1.5,1.0 square=1 color=green label="Hood"
  box grille size=0.1,0.45,0.66 at=-2.24,0.8,0 color=dark
  repeat 3 step=0,0.14,0 at=-2.3,0.66,0
    box slat size=0.03,0.05,0.6 color=steel
  mirror z
    sphere lamp r=0.1 scale=0.5,1,1 at=-2.2,1.02,0.28 color=yellow
    box pillar size=0.09,1.05,0.09 at=0.28,2.02,0.58 color=green
    box pillar2 size=0.09,1.05,0.09 at=1.36,2.02,0.58 color=green
    rimwheel fw r=0.45 w=0.28 at=-1.6,0.45,0.72 rim=yellow
    rimwheel rw r=0.8 w=0.55 at=0.9,0.8,0.95 rim=yellow
    plate fender pts=0.007,0.475 0.007,1.125 0.425,1.623 1.065,1.736 1.628,1.411 1.85,0.8 1.77,0.8 1.566,1.359 1.051,1.657 0.465,1.553 0.083,1.098 0.083,0.502 h=0.6 at=0,0,0.95 color=green
    tube lowerlink pts=1.5,0.78,0.5 2.1,0.48,0.5 r=0.05 color=darkmetal
    box step size=0.3,0.05,0.22 at=0.1,0.75,0.62 color=darkmetal
  cyl stack r=0.055 h=0.9 at=-1.5,1.75,0.3 color=darkmetal label="Exhaust"
  cyl stacktop r=0.075 h=0.09 at=-1.5,2.22,0.3 color=black
  cyl aircleaner r=0.1 h=0.55 at=-1.95,1.62,-0.3 color=black
  box cabbase size=1.3,0.2,1.25 at=0.82,1.44,0 color=green
  box cabglass size=1.15,1.0,1.15 at=0.82,2.02,0 color=sky mat=glass label="Cab"
  box roof size=1.38,0.13,1.32 at=0.82,2.6,0 round=0.05 color=green
  cyl beacon r=0.06 h=0.12 at=0.3,2.72,0 color=orange
  box frontaxle size=0.14,0.14,1.5 at=-1.6,0.5,0 color=darkmetal
  tube toplink pts=1.45,1.25,0 2.0,0.95,0 r=0.05 color=darkmetal
  box drawbar size=0.55,0.1,0.26 at=1.78,0.55,0 color=darkmetal label="Hitch"
  cyl pto r=0.08 h=0.22 axis=x at=1.6,0.72,0 color=steel
note "Big rear wheels give the grip; the hitch pulls the plough." color=yellow
```

## Excavator

```chalk
canvas paper
title "Excavator"
model exc 900 540 view=-40,16
  mirror z
    tracks trk len=5.6 h=1.0 w=0.8 wheels=6 at=0,0,1.05 color=dark label="Tracks"
  body carbody top=-1.5,0.55 -1.3,0.95 1.3,0.95 1.5,0.55 bottom=-1.5,0.3 1.5,0.3 width=-1.5,0.7 1.5,0.7 square=1 color=darkmetal
  cyl slew r=0.85 h=0.22 at=0,1.0,0 color=darkmetal
  body house top=-2.5,1.5 -2.45,2.2 -2.1,2.55 0.5,2.55 1.2,2.35 1.45,1.7 bottom=-2.5,1.2 1.45,1.2 width=-2.5,1.0 -2.2,1.15 0.5,1.15 1.45,1.0 square=1 color=yellow label="House"
  box skirt size=3.9,0.14,2.2 at=-0.55,1.28,0 color=dark
  box hoodvent size=0.9,0.06,1.5 at=-1.9,2.56,0 color=dark
  cyl exhaust r=0.1 h=0.5 at=-1.9,2.6,0.55 color=darkmetal
  group cab at=0.75,1.95,0.55 label="Cab"
    box glass size=1.25,1.3,1.0 round=0.08 color=sky mat=glass
    box roof size=1.32,0.1,1.06 at=0,0.66,0 color=dark
    box floor size=1.32,0.12,1.06 at=0,-0.66,0 color=dark
    box pillar size=0.1,1.3,0.1 at=0.6,0,0.48 color=dark
    box pillar2 size=0.1,1.3,0.1 at=-0.6,0,0.48 color=dark
  cyl boompin r=0.28 h=0.95 axis=z at=1.3,1.5,0 color=darkmetal
  plate boom pts=0,-0.5 0.55,0.3 1.15,1.1 1.75,1.75 2.15,2.1 2.35,2.4 2.0,2.6 1.5,2.2 0.9,1.4 0.35,0.65 0,0.5 h=0.55 at=1.3,1.5,0 color=yellow label="Boom"
  plate stick pts=0,0.42 1.0,-1.0 1.5,-1.65 1.65,-1.95 1.3,-2.1 0.8,-1.45 0.2,-0.45 0,-0.42 h=0.42 at=3.5,3.85,0 color=yellow label="Stick"
  plate bucket pts=0.1,0.1 0.9,-0.2 1.15,-0.9 0.7,-1.5 -0.1,-1.6 -0.45,-1.1 -0.4,-0.45 h=1.25 at=5.0,1.85,0 color=darkmetal label="Bucket"
  repeat 5 step=0,0,0.28 at=4.7,0.55,-0.56
    cone tooth r=0.09 h=0.35 rot=0,0,160 color=steel
  tube bc1 pts=1.0,1.4,0.42 2.3,2.55,0.42 r=0.13 color=steel
  tube bc2 pts=1.0,1.4,-0.42 2.3,2.55,-0.42 r=0.13 color=steel
  tube sc1 pts=2.4,3.45,0.28 3.85,4.1,0.28 r=0.11 color=steel
  tube sc2 pts=2.4,3.45,-0.28 3.85,4.1,-0.28 r=0.11 color=steel
  tube kc1 pts=4.2,3.2,0.25 4.95,2.15,0.25 r=0.1 color=steel
  tube kc2 pts=4.2,3.2,-0.25 4.95,2.15,-0.25 r=0.1 color=steel
```

## Steam locomotive

```chalk
canvas paper
title "Steam locomotive"
model loco 980 460 view=-32,16
  box frame size=10.4,0.3,1.3 at=-1.2,1.55,0 color=darkmetal
  box runboard size=8.2,0.09,2.3 at=-2.4,1.74,0 color=dark
  cyl boiler r=0.85 h=5.2 axis=x at=-2.0,2.45,0 color=green label="Boiler"
  cyl smokebox r=0.9 h=1.5 axis=x at=-5.35,2.45,0 color=black label="Smokebox"
  cyl frontcap r=0.92 h=0.16 axis=x at=-6.12,2.45,0 color=darkmetal
  lathe chimney pts=0,0.55 0.35,0.5 0.55,0.32 1.3,0.3 1.5,0.46 axis=y at=-5.35,3.3,0 color=black label="Chimney"
  sphere dome r=0.42 at=-1.2,3.18,0 scale=1,1.25,1 color=brass label="Steam dome"
  sphere sand r=0.34 at=-3.3,3.12,0 scale=1,1.1,1 color=green
  cyl whistle r=0.09 h=0.5 at=-2.2,3.6,0 color=brass
  box firebox size=1.6,1.7,1.9 at=1.4,2.45,0 round=0.2 color=green
  box cab size=2.0,2.0,2.1 at=2.6,2.6,0 round=0.15 color=green label="Cab"
  box roof size=2.35,0.14,2.4 at=2.6,3.66,0 round=0.05 color=dark
  mirror z
    box cabwin size=0.9,0.55,0.06 at=2.6,3.05,1.06 color=sky
    box handrail size=0.05,0.05,0.05 at=0,0,0 color=brass
    tube rail pts=-6.0,2.95,0.88 -3.5,2.95,0.88 -0.6,2.95,0.88 r=0.045 color=brass
    cyl steamcyl r=0.36 h=1.35 axis=x at=-4.35,1.35,1.02 color=darkmetal label="Cylinder"
    box pistonrod size=1.5,0.1,0.1 at=-3.4,1.35,1.02 color=steel
    box mainrod size=2.7,0.13,0.1 at=-2.55,1.05,1.14 color=steel
    box couplingrod size=3.5,0.14,0.1 at=-1.65,0.85,1.16 color=steel
    rimwheel d1 r=0.85 w=0.26 at=-3.3,0.85,0.95 rim=red spokes=12
    rimwheel d2 r=0.85 w=0.26 at=-1.65,0.85,0.95 rim=red spokes=12
    rimwheel d3 r=0.85 w=0.26 at=0.0,0.85,0.95 rim=red spokes=12
    rimwheel l1 r=0.45 w=0.2 at=-5.45,0.45,0.95 rim=red spokes=8
    rimwheel l2 r=0.45 w=0.2 at=-4.6,0.45,0.95 rim=red spokes=8
    rimwheel t1 r=0.5 w=0.22 at=1.5,0.5,0.95 rim=red spokes=8
  plate cowcatcher pts=-6.95,0.1 -6.2,0.1 -6.2,1.45 h=2.0 color=darkmetal label="Cowcatcher"
  box buffer size=0.22,0.55,2.2 at=-6.45,1.0,0 round=0.05 color=red
  box lamp size=0.35,0.4,0.35 at=-5.3,3.75,0 round=0.06 color=brass
  box tender size=4.6,1.9,2.2 at=6.6,1.85,0 round=0.15 color=green label="Tender"
  box coal size=3.4,0.55,1.8 at=6.3,2.85,0 round=0.1 color=black
  box tenderbeam size=0.2,0.5,2.2 at=8.9,1.0,0 round=0.05 color=red
  box coupling size=0.7,0.16,0.16 at=4.1,1.35,0 color=darkmetal
  mirror z
    rimwheel tw1 r=0.5 w=0.22 at=5.0,0.5,0.95 rim=red spokes=8
    rimwheel tw2 r=0.5 w=0.22 at=6.6,0.5,0.95 rim=red spokes=8
    rimwheel tw3 r=0.5 w=0.22 at=8.2,0.5,0.95 rim=red spokes=8
```

## Pelican on a bicycle

```chalk
canvas paper
title "A pelican rides a bicycle"
model pel 900 540 view=-32,16
  group bike label="Bicycle"
    rimwheel rw r=0.34 w=0.05 at=-0.52,0.34,0 rim=dark spokes=8
    rimwheel fw r=0.34 w=0.05 at=0.52,0.34,0 rim=dark spokes=8
    tube downtube pts=0,0.28,0 0.40,0.60,0 r=0.024 color=red
    tube toptube pts=-0.10,0.82,0 0.42,0.78,0 r=0.022 color=red
    tube seattube pts=0,0.28,0 -0.10,0.82,0 r=0.022 color=red
    tube headtube pts=0.40,0.60,0 0.42,0.78,0 r=0.026 color=red
    mirror z
      tube chainstay pts=0,0.28,0.03 -0.52,0.34,0.05 r=0.014 color=red
      tube seatstay pts=-0.10,0.82,0.03 -0.52,0.34,0.05 r=0.013 color=red
      tube fork pts=0.40,0.60,0.03 0.52,0.34,0.05 r=0.016 color=red
    tube stem pts=0.42,0.78,0 0.45,0.90,0 r=0.018 color=dark
    cyl bar r=0.018 h=0.46 axis=z at=0.45,0.90,0 color=dark label="Handlebars"
    box saddle size=0.26,0.05,0.13 at=-0.12,0.86,0 round=0.02 color=black
    gear ring teeth=32 r=0.10 h=0.012 axis=z at=0,0.28,0.05 color=steel
    cyl crank r=0.02 h=0.18 axis=z at=0,0.28,0 color=steel
    box pedal1 size=0.09,0.02,0.06 at=0.10,0.20,0.10 color=dark
    box pedal2 size=0.09,0.02,0.06 at=-0.10,0.36,-0.10 color=dark
  group pelican label="Pelican"
    blob body k=0.5 color=white
      limb trunk pts=-0.38,1.02,0,0.14 -0.15,1.05,0,0.19 0.10,1.10,0,0.20 0.22,1.18,0,0.14
      limb neck pts=0.20,1.20,0,0.10 0.26,1.42,0,0.075 0.24,1.56,0,0.07
      limb skull pts=0.24,1.58,0,0.085 0.34,1.58,0,0.065
      limb tail pts=-0.42,1.02,0,0.09 -0.58,0.98,0,0.04
      mirror z
        limb wing pts=0.06,1.16,0.14,0.10 0.24,1.02,0.20,0.07 0.42,0.92,0.20,0.045
      limb legA pts=-0.02,0.98,0.10,0.05 0.02,0.60,0.11,0.035 0.10,0.24,0.10,0.03
      limb legB pts=-0.02,0.98,-0.10,0.05 -0.06,0.62,-0.11,0.035 -0.10,0.38,-0.10,0.03
    limb billtop pts=0.32,1.60,0,0.055 0.52,1.54,0,0.035 0.72,1.46,0,0.018 color=orange
    limb pouch pts=0.34,1.52,0,0.06 0.50,1.44,0,0.055 0.66,1.40,0,0.025 color=orange label="Throat pouch"
    mirror z
      sphere eye r=0.022 at=0.30,1.62,0.06 color=black
      limb wingtip pts=0.36,0.96,0.20,0.045 0.44,0.90,0.20,0.03 color=black
      limb foot pts=0.10,0.24,0.10,0.03 0.16,0.22,0.12,0.02 color=dark
```
