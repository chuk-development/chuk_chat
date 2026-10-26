#!/usr/bin/env python3
"""Episode 11 assets: the fidelity references. This episode has no generated media.

1. flutter test .../fidelity_test/real_sidebar_test.dart renders the REAL SidebarDesktop and
   SidebarMobile (Clawed dark theme, the episode's fictional chats, idle / field open /
   "landlord" typed) and dumps the theme tokens -> _work/fidelity/real-*.png, real-tokens.json.
   Its own flutter_test_config.dart keeps .env unread (EnvLoader.skipFileForTests).
2. fidelity.py renders sidebar.py at the same size and writes the sheets.
Run once from anywhere:  python3 _work/make_assets.py
"""
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
subprocess.run(["flutter", "test", str((HERE / "fidelity_test/real_sidebar_test.dart").relative_to(REPO))],
               cwd=REPO, check=True)
subprocess.run([sys.executable, str(HERE / "fidelity.py")], check=True)
