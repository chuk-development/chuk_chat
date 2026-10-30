import sys,asyncio
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome',headless=True)
    pg=b.new_page(device_scale_factor=1)
    for s in sys.argv[1:]:
        pg.goto('file://'+s); pg.wait_for_timeout(150)
        box=pg.evaluate("(()=>{const r=document.documentElement.getBBox?document.documentElement.getAttribute('width'):0;return [+document.documentElement.getAttribute('width'),+document.documentElement.getAttribute('height')]})()")
        pg.set_viewport_size({'width':int(box[0]),'height':int(box[1])})
        pg.screenshot(path=s.replace('.svg','.png'))
    b.close()
