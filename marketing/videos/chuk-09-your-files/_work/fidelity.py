#!/usr/bin/env python3
"""Fidelity sheets for the UI pieces 08 does not have.

Reference halves (real app): flutter test marketing/videos/chuk-09-your-files/_work/
fidelity_test/real_widgets_test.dart renders the real AttachmentPreviewBar, the real
MessageBubble (user, with an image) and the drop overlay block of chat_ui_desktop.dart
in the Clawed dark theme at 2 px per app px -> _work/fidelity/real-*.png.
Video halves: the same library pieces, laid out like the test, at the same 2 px per
app px (the 16:9 video draws the composer and the chat at zoom 2.0).
Storage has no app widget: its sheet sets the rebuilt Supabase Storage list next to
08's approved Supabase table editor, so both server shots read as one product.

Run:  python3 _work/fidelity.py [<16:9 frame with the storage list> <08 table frame>]
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from PIL import Image  # noqa: E402

from chukvid import fidelity, ui  # noqa: E402
from episode import IMG, JPG_SIZE, PROMPT  # noqa: E402

F = HERE / "fidelity"
P = HERE.parent

# attachment card: Container(padding 20) > SizedBox(300) > Padding(bottom 14, left 2, right 52)
# > AttachmentPreviewBar (Align centerLeft, vertical padding 2) => card at (22, 27)
fidelity.harness(P, f'<div style="position:absolute;left:22px;top:27px">{ui.attach_card("c", IMG, JPG_SIZE)}</div>',
                 (340, 140), F / "vid-attachment.png")
fidelity.sheet(F / "real-attachment.png", F / "vid-attachment.png", F / "attachment.jpg",
               "AttachmentPreviewBar: 72 px card, gradient frame, size badge, remove chip")

# user turn: column 728 at the right, image top 49.5 (bubble group padding measured on the real render)
fidelity.harness(P, f'<div class="a-col" style="right:20px;top:49.5px;width:728px">{ui.user_message("u", PROMPT, image=IMG, img_size=262)}</div>',
                 (768, 420), F / "vid-user-image.png")
fidelity.sheet(F / "real-user-image.png", F / "vid-user-image.png", F / "user-image.jpg",
               "MessageBubble (user): image square 262, radius 12, gap 12, coral bubble")

# drop overlay: fills the area, card centred
fidelity.harness(P, f'<div class="fill">{ui.drop_overlay("d")}</div>', (640, 240), F / "vid-drop.png")
fidelity.sheet(F / "real-drop.png", F / "vid-drop.png", F / "drop.jpg",
               "drag-and-drop overlay (chat_ui_desktop.dart _isDraggingFiles)")

if len(sys.argv) == 3:
    ours, ref = Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")
    ref.crop((90, 280, 1830, 800)).save(F / "ref-08-table.png")
    ours.crop((100, 230, 1840, 830)).save(F / "vid-storage.png")
    fidelity.sheet(F / "ref-08-table.png", F / "vid-storage.png", F / "storage.jpg",
                   "Supabase table editor (08, approved)", ref_label="REFERENCE: 08",
                   vid_label="09: Supabase Storage list, same card, type scale and colours")
