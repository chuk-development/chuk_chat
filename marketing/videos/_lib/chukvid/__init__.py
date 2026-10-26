"""Shared generator for the Chuk Chat video series (look of chuk-08-what-we-see).

    import sys; sys.path.insert(0, "<repo>/marketing/videos/_lib")
    from chukvid import core, ui, scenes, cipher, beats, fidelity
"""
from . import beats, cipher, core, scenes, ui  # noqa: F401
from .core import FORMATS, LANDSCAPE, VERTICAL, Episode, Format  # noqa: F401
