---
name: web-images
description: Find, check and hand over images from the web, for example as one ZIP. Product photos, official pictures, variants or colours. Checks that each image shows the asked product and variant, skips icons and thumbnails, names the source page and price.
metadata:
  version: "1.3"
---

# Web images: the right pictures, checked, in few rounds

The user wants the pictures, not the search. Each picture must show the
asked product in the asked variant. Each picture has a named source page.

Each round sends the whole conversation again, so the number of rounds is
the cost. Follow this plan. It needs about 7 rounds. Do not add rounds for
work that a step below already does.

## Round 1: check the name, find the pages (in parallel)

- Write down the product and each variant or colour that the user asks for.
- Check that the product, the series and each variant really exist under
  that name. Read the first search results for it. The user can mix up
  names: the Starbucks city mugs for Berlin or Hamburg are the "You Are
  Here" series, not "Been There". When the name is wrong, say so in the
  answer in one sentence and collect the right product. When a variant does
  not exist at all, say so; do not search for it for many rounds.
- Call 2 or 3 `web_search` in the SAME round: the maker's product page, and
  the product in shops (for example "Raspberry Pi 5 Case SC1159 SC1160 shop").
  Use the maker's part numbers (SKU) when you know them or see them; shops
  list them.
- Pick the maker's page and 3 to 5 shop pages. Good shops have one page per
  product with all variants (The Pi Hut, Pimoroni, BerryBase, Adafruit,
  SparkFun, Kiwi Electronics, reichelt, Botland and similar).

## Round 2: read every page (in parallel, one call per page)

- A Shopify shop (the URL has `/products/<name>`): read its JSON. It names
  each variant with its SKU, price and its own pictures:
  `web_fetch("https://shop/products/<name>.json", fields=["product.title","product.variants.id","product.variants.title","product.variants.sku","product.variants.price","product.images.src","product.images.variant_ids"])`
  An image belongs to the variant whose `id` is in its `variant_ids`.
- Any other page: `web_fetch(url, extract="images")`. You get the images
  (url, alt, size; logos and icons moved out) and `product` (name, SKU,
  price, currency, stock) in one result.
- A result with `hint` (a bot check): skip that page when the other sources
  give enough images. Use the browser only for a source you really need
  (the maker's page for "official" pictures), in round 3.
- Prefer shops whose pages give the images without a browser (Shopify JSON,
  `extract="images"`). Marketplaces (eBay, Etsy, Amazon) block scripts and
  hide their variants in scripts: use them last, only for a variant that no
  shop has, one listing per variant.

## Round 3 (only when needed): a page behind a bot check

Budget: at most 3 browser steps per site. When the function below does not
give the images, leave that site and take the next source. Do not write new
JavaScript to dig into a page's scripts.

Call `mcp__playwright__browser_navigate` directly (no `search_tools`). Then
call `mcp__playwright__browser_evaluate` ONCE with this function. Never use
`browser_snapshot` or screenshots to find images.

```js
() => {
  const big = s => (s || '').split(',').map(x => x.trim().split(/\s+/)).sort((a, b) => parseFloat(b[1] || 0) - parseFloat(a[1] || 0))[0]?.[0];
  const rows = [];
  const og = document.querySelector('meta[property="og:image"]')?.content;
  if (og) rows.push({u: og, a: 'og:image'});
  document.querySelectorAll('img').forEach(i => rows.push({u: big(i.srcset) || i.currentSrc || i.src, w: i.naturalWidth, a: (i.alt || '').slice(0, 80)}));
  document.querySelectorAll('picture source').forEach(s => rows.push({u: big(s.srcset), a: 'source'}));
  const seen = new Set();
  const images = rows.filter(r => r.u && !r.u.startsWith('data:') && !seen.has(r.u) && seen.add(r.u) && !(r.w > 0 && r.w < 300) && !/logo|icon|sprite|placeholder/i.test(r.u)).slice(0, 30);
  const ld = [...document.querySelectorAll('script[type="application/ld+json"]')].map(s => s.textContent).join(' ');
  const price = (ld.match(/"price"\s*:\s*"?([0-9.,]+)/) || [])[1] || document.querySelector('[itemprop=price]')?.getAttribute('content');
  return {images, price: price && parseFloat(price.replace(',', '.')) > 0 ? price : null};
}
```

## Pick the images (no tool call)

- Each variant from at least TWO sources, with 2 to 4 different views each
  (front, back, side, open, detail) when the sources have them. Aim for 8 to
  14 images in total for a product with two variants.
- The alt text, the file name, the SKU or the Shopify `variant_ids` must
  name the product AND the variant. Pictures of other products on the same
  page (accessories, "customers also bought") are wrong.
- Skip logos, icons, banners with text, thumbnails and placeholders.
- Take the full-size original: the biggest `srcset` entry, and the URL
  without size parameters (`width=300`, `_300x`, `-150x150`) when the page
  has that larger version.
- The same picture from two shops counts once (the script finds it too).

## Round 4: download, check and pack (ONE command for all)

Never download with curl by hand. Never `cd` before this command; run it
from the workspace root exactly like this:

```bash
python3 /workspace/skills/web-images/pack_images.py --zip downloads/<name>.zip --keep tmp/images <<'EOF'
[{"url": "https://.../case-red-front.jpg", "name": "1-rot-weiss-vorne-pihut", "page": "https://thepihut.com/products/raspberry-pi-5-case"},
 {"url": "https://.../case-black.jpg", "name": "5-schwarz-vorne-berrybase", "page": "https://www.berrybase.de/..."}]
EOF
```

- Name each file after the variant, the view and the source.
- The script converts WebP and AVIF to JPG or PNG, skips small files and
  duplicates, and prints the main colours of each picture. Compare them with
  the variant. A red/white case must show red; "(greyscale)" on it means a
  black-and-white photo or the wrong variant, so drop it. For a black, grey
  or white variant "(greyscale)" is right.
- Lines with `SKIP` tell you why. Run the script once more only for
  replacements, with the next candidates.

## Round 5 (only when needed): look at doubtful pictures

When the colours, the alt text and the source do not prove the variant, call
`read_document` for each doubtful file in the SAME round:

```text
read_document("tmp/images/1-rot-weiss-vorne-pihut.jpg", instruction="Which product and which colour variant does this photo show? Product photo, drawing or logo? One line.")
```

Replace a wrong picture (round 4 again, only for it).

## Never end with nothing

When the runtime says that only a few steps are left, stop searching. Pack
what you have (round 4), send it and answer: what you found, what is
missing and why.

## Round 6: hand over

In ONE round: `send_file_to_user("downloads/<name>.zip")` and
`run_command("rm -rf tmp/images")`. Then answer, grouped by variant, one
line per image: file name, what it shows, source page as a link, and the
shop's price with currency and stock. A source without a usable price: say
"kein Preis angegeben" (in the user's language). Never write 0.00 as a price.
