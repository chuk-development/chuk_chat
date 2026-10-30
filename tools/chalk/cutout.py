#!/usr/bin/env python3
"""Cuts the main object out of a picture and writes a PNG with alpha.
cutout.py <in> <out.png>. Plain backgrounds use a flood fill from the border."""
import sys
from collections import deque
from PIL import Image
import numpy as np


def largest(keep):
    """Keeps the biggest connected piece, so page decoration falls away."""
    from scipy import ndimage
    labels, n = ndimage.label(keep)
    if n < 2:
        return keep
    sizes = ndimage.sum(keep, labels, range(1, n + 1))
    main = labels == (int(np.argmax(sizes)) + 1)
    return ndimage.binary_fill_holes(main)


def cut(src, dst, tol=26, force_model=False):
    im = Image.open(src).convert('RGB')
    if max(im.size) > 1100:
        im.thumbnail((1100, 1100))
    a = np.asarray(im).astype(np.int16)
    h, w, _ = a.shape
    border = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])
    bg = np.median(border, axis=0)
    spread = np.abs(border - bg).max(axis=1)
    plain = (spread < 30).mean()
    seen = np.zeros((h, w), bool)
    q = deque()
    for x in range(w):
        q.extend([(0, x), (h - 1, x)])
    for y in range(h):
        q.extend([(y, 0), (y, w - 1)])
    near = np.abs(a - bg).max(axis=2) < tol
    while q:
        y, x = q.popleft()
        if y < 0 or x < 0 or y >= h or x >= w or seen[y, x] or not near[y, x]:
            continue
        seen[y, x] = True
        q.extend([(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)])
    keep = ~seen
    # A busy background needs a real segmentation model. With a tight box from the
    # model (screenshots), the object fills the crop: the plain fill goes first, and
    # a result that keeps too little is thrown away.
    flood = largest(keep) if keep.any() else keep
    if force_model:
        keep = flood
        if keep.mean() < 0.3:
            from rembg import remove
            keep = largest(np.asarray(remove(im))[:, :, 3] > 128)
        if keep.mean() < 0.3:
            keep = np.ones((h, w), bool)
    elif plain < 0.75 or keep.mean() > 0.92 or keep.mean() < 0.02:
        from rembg import remove
        keep = np.asarray(remove(im))[:, :, 3] > 128
    if not keep.any():
        keep[:] = True
    keep = largest(keep)
    ys, xs = np.where(keep)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    rgba = np.dstack([a.astype(np.uint8), (keep * 255).astype(np.uint8)])[y0:y1, x0:x1]
    Image.fromarray(rgba, 'RGBA').save(dst)
    return plain, keep.mean()


if __name__ == '__main__':
    print(cut(sys.argv[1], sys.argv[2]))
