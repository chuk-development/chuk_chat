#!/usr/bin/env python3
"""User marks a picture, the model edits it. stroke.py <run_dir> <round> <request> <cx> <cy>"""
import base64, json, subprocess, sys, time, urllib.request
from pathlib import Path
HERE = Path(__file__).parent
KEY = (HERE.parent.parent / '_scratch/rtgfx/.melious_key').read_text().strip()
d, rnd, ask, cx, cy = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
said = subprocess.run(['node', str(HERE / 'mark.mjs'), str(d), str(rnd), cx, cy], capture_output=True, text=True).stdout.strip()
scene = (d / f'r{rnd}.chalk').read_text()
img = base64.b64encode((d / f'r{rnd}.mark.png').read_bytes()).decode()
msgs = [{'role': 'system', 'content': (HERE / 'PROMPT.md').read_text()},
        {'role': 'user', 'content': 'Scene:\n```chalk\n' + scene + '```'},
        {'role': 'user', 'content': [{'type': 'text', 'text': f'{said}\nThe mark is the red line in the image.\nRequest: {ask}\nAnswer with edits only.'},
                                     {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + img}}]}]
t = time.time()
r = urllib.request.Request('https://api.melious.ai/v1/chat/completions', json.dumps({'model': 'glm-5.3-flash', 'messages': msgs, 'max_tokens': 8000, 'reasoning_effort': 'high', 'temperature': 0.3}).encode(),
                           {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'})
o = json.load(urllib.request.urlopen(r, timeout=200))
text = o['choices'][0]['message']['content']
print(said, '|', round(time.time() - t, 1), 's |', o['usage']['completion_tokens'], 'tokens')
print(text)
import re
m = re.search(r'```(?:chalk)?\s*\n(.*?)```', text, re.S)
(d / f'r{rnd + 1}.chalk').write_text(m.group(1) if m else text)
print(subprocess.run(['node', str(HERE / 'loop.mjs'), str(d), str(rnd + 1)], capture_output=True, text=True).stdout[-300:])
subprocess.run(['python3', str(HERE / 'shot.py'), str((d / f'r{rnd + 1}.svg').resolve())])
