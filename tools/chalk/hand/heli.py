#!/usr/bin/env python3
"""GLM H145 with a real rotor system. The film has a run-up, a lift-off and a transition."""
import sys
t = open(sys.argv[1]).read()
t = t[:t.index('\n  anim')] + '\n'
t = t.replace('model obj 1100 620 keep=1 tidy=1 view=35,18', 'model obj 1100 620 keep=1 tidy=1 view=-38,10 fit=whole')
# The fan duct lay along the boom. Its axis must cross the boom, through the fin.
t = t.replace('    group fit_74486 at=-1.6025,0.4253,0.0000 scale=1.2455,0.8224,0.9964\n', '    group fit_74486 at=6.5,2.2,0 rot=0,90,0 scale=0.86\n     group fen_inner at=-6.25,-2.3,0\n')
t = '\n'.join(l for l in t.split('\n') if ' tipcap ' not in l)
t += '''  group pad
    cyl padslab r=9 h=0.2 axis=y at=0,-0.1,0 color=#3c3f44 mat=matte
    cyl padring r=7 hole=6.7 h=0.21 axis=y at=0,-0.1,0 color=#e8e8e8 mat=matte
    box padh1 size=0.7,0.21,4.2 at=-1.4,-0.1,0 round=0 color=#e8e8e8 mat=matte
    box padh2 size=0.7,0.21,4.2 at=1.4,-0.1,0 round=0 color=#e8e8e8 mat=matte
    box padh3 size=2.2,0.21,0.7 at=0,-0.1,0 round=0 color=#e8e8e8 mat=matte
  mech
    rotor rotor_spin axis=y
    rotor fan_rot axis=z of=rotor_spin ratio=-5.5
  anim
    step "Triebwerke starten, der Hauptrotor läuft langsam an" 4
      run turns=1.5
      camera view=-38,10 zoom=1.1
    step "Über eine Welle dreht der Fenestron im festen Verhältnis mit" 3.5
      run turns=4
      camera view=62,8 zoom=2.6 on=fan_rot
    step "Volle Drehzahl: die Blätter verschwimmen zur Scheibe" 3.5
      run turns=8
      camera view=-30,20 zoom=1.3 on=rotor_spin
    step "Mehr Blattanstellung, die Maschine hebt ab" 3.5
      run turns=8
      move whole by=0,2.6,0
      camera view=-40,8 zoom=1
    step "Nase runter, der Schub zieht sie nach vorn" 3.5
      run turns=8
      swing whole deg=7 axis=z pivot=0.9,3,0
      move whole by=-7,0.9,0
      camera view=-52,8 zoom=0.9
'''
print(t, end='')
