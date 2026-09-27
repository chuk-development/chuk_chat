"""Contact sheet from the rendered MP4: one tile per frame midpoint plus cut points."""
import subprocess, sys
from PIL import Image, ImageDraw, ImageFont
MP4 = "../renders/video.mp4"
OUT = "../renders/contact-sheet.jpg"
T = [(0.3, "01 hook"), (2.6, "01 typing"), (5.0, "01 send pop"), (7.6, "02 title"),
     (10.2, "03 headline"), (13.5, "03 answer"), (15.6, "03 ciphertext"), (17.4, "04 headline"),
     (19.4, "04 prompt"), (23.2, "04 page"), (24.6, "05 headline"), (29.4, "05 invoice"),
     (31.0, "05 email"), (32.3, "06 orbit"), (35.8, "06 steps"), (37.8, "06 plan"),
     (38.9, "07 headline"), (40.9, "07 model menu"), (43.6, "07 per message"), (45.2, "08 listening"),
     (46.9, "08 working"), (48.9, "08 done"), (50.1, "09 proof"), (54.9, "09 all chips"),
     (56.2, "10 logo"), (59.5, "10 end card")]
W, H = 480, 270
cols = 4
rows = (len(T) + cols - 1) // cols
sheet = Image.new("RGB", (cols * W, rows * (H + 28)), (24, 24, 22))
d = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 16)
except OSError:
    font = ImageFont.load_default()
for i, (t, label) in enumerate(T):
    png = f"sheet_{i:02d}.png"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(t), "-i", MP4, "-frames:v", "1",
                    "-vf", f"scale={W}:{H}", png], check=True)
    im = Image.open(png)
    x, y = (i % cols) * W, (i // cols) * (H + 28)
    sheet.paste(im, (x, y + 28))
    d.text((x + 8, y + 5), f"{t:.1f}s  {label}", fill=(240, 236, 226), font=font)
sheet.save(OUT, quality=88)
print(OUT)
