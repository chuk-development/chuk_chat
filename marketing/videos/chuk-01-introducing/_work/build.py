"""Build every frame composition: python3 _work/build.py"""
import frames_a, frames_b, frames_c
for f in (frames_a.f01, frames_a.f02, frames_a.f03, frames_b.f04, frames_b.f05, frames_b.f06,
          frames_c.f07, frames_c.f08, frames_c.f09, frames_c.f10):
    print(f())
