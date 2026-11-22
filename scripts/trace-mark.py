#!/usr/bin/env python3
"""Trace a flat black master into real SVG paths.

No potrace on this machine, so: marching squares for the contours, then
Douglas-Peucker to shed the pixel staircase, then Catmull-Rom through the
survivors to put the curve back. At the sizes this mark is actually used —
a 16px favicon, a 192px PWA tile, a printed invoice header — the result is
indistinguishable from a hand-drawn curve, and unlike an embedded bitmap it
stays sharp at any of them.

Holes matter here: the خ encloses a loop, and a tracer that only follows outer
boundaries fills it in and turns the letter into a blob.
"""
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def contours(mask):
    """Every closed boundary in a binary mask, outer and hole alike.

    Pads by one pixel so a shape touching the edge still closes, and walks the
    marching-squares case table. Returns integer point lists in image space.
    """
    g = np.pad(mask.astype(np.uint8), 1)
    h, w = g.shape
    # Each cell's 4 corners -> a case number; the table gives the edge crossings.
    seen = set()
    out = []
    # Edge midpoints of cell (y,x): 0 top, 1 right, 2 bottom, 3 left
    step = {0: (-1, 0), 1: (0, 1), 2: (1, 0), 3: (0, -1)}
    entry_from = {0: 2, 1: 3, 2: 0, 3: 1}

    def case_at(y, x):
        return (g[y, x] << 3) | (g[y, x + 1] << 2) | (g[y + 1, x + 1] << 1) | g[y + 1, x]

    # Exit edge for each case, given the edge we came in on.
    table = {1: {2: 3, 3: 2}, 2: {1: 2, 2: 1}, 3: {1: 3, 3: 1}, 4: {0: 1, 1: 0},
             6: {0: 2, 2: 0}, 7: {0: 3, 3: 0}, 8: {0: 3, 3: 0}, 9: {0: 2, 2: 0},
             11: {0: 1, 1: 0}, 12: {1: 3, 3: 1}, 13: {1: 2, 2: 1}, 14: {2: 3, 3: 2}}
    # Ambiguous saddles: pick one consistent resolution.
    table[5] = {0: 1, 1: 0, 2: 3, 3: 2}
    table[10] = {0: 3, 3: 0, 1: 2, 2: 1}

    mid = {0: (0.0, 0.5), 1: (0.5, 1.0), 2: (1.0, 0.5), 3: (0.5, 0.0)}

    for sy in range(h - 1):
        for sx in range(w - 1):
            c = case_at(sy, sx)
            if c in (0, 15):
                continue
            for start_edge in list(table[c]):
                if (sy, sx, start_edge) in seen:
                    continue
                pts, y, x, e = [], sy, sx, start_edge
                ok = True
                while True:
                    cc = case_at(y, x)
                    if cc in (0, 15) or cc not in table or e not in table[cc]:
                        ok = False
                        break
                    if (y, x, e) in seen:
                        break
                    seen.add((y, x, e))
                    ex = table[cc][e]
                    dy, dx = mid[ex]
                    pts.append((x + dx - 1, y + dy - 1))
                    ny, nx = y + step[ex][0], x + step[ex][1]
                    if not (0 <= ny < h - 1 and 0 <= nx < w - 1):
                        ok = False
                        break
                    y, x, e = ny, nx, entry_from[ex]
                    if (y, x, e) == (sy, sx, start_edge):
                        break
                if ok and len(pts) > 8:
                    out.append(np.array(pts, float))

    # A boundary walked clockwise and anticlockwise is the same boundary. The
    # `seen` set cannot catch it — the two walks visit different (cell, entry
    # edge) triples — but they visit the same midpoints, so dedupe on those.
    # Left in, the pair renders as a hairline sliver under fill-rule evenodd
    # and doubles the path data for nothing.
    unique, sigs = [], []
    for c in out:
        sig = frozenset(map(tuple, np.round(c, 1)))
        if any(len(sig & s) > 0.9 * min(len(sig), len(s)) for s in sigs):
            continue
        sigs.append(sig)
        unique.append(c)
    return unique


def rdp(pts, eps):
    """Douglas-Peucker, iterative so a long contour cannot blow the stack."""
    n = len(pts)
    keep = np.zeros(n, bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        a, b = pts[i], pts[j]
        ab = b - a
        L = np.hypot(*ab)
        seg = pts[i + 1:j]
        if L < 1e-9:
            d = np.hypot(*(seg - a).T)
        else:
            d = np.abs(np.cross(np.tile(ab, (len(seg), 1)), seg - a)) / L
        k = int(np.argmax(d))
        if d[k] > eps:
            m = i + 1 + k
            keep[m] = True
            stack += [(i, m), (m, j)]
    return pts[keep]


def to_path(pts, scale, tension=0.30):
    """Catmull-Rom through the simplified points, emitted as cubic beziers."""
    p = pts * scale
    n = len(p)
    if n < 3:
        return ''
    d = [f'M{p[0][0]:.2f},{p[0][1]:.2f}']
    for i in range(n):
        p0, p1, p2, p3 = p[(i - 1) % n], p[i], p[(i + 1) % n], p[(i + 2) % n]
        c1 = p1 + (p2 - p0) * tension / 3 * 2
        c2 = p2 - (p3 - p1) * tension / 3 * 2
        d.append(f'C{c1[0]:.2f},{c1[1]:.2f} {c2[0]:.2f},{c2[1]:.2f} {p2[0]:.2f},{p2[1]:.2f}')
    return ' '.join(d) + 'Z'


def trace(png, size=192, eps=1.1, downsample=4):
    im = Image.open(png).convert('RGBA')
    a = np.asarray(im.getchannel('A'))
    mask = a > 128
    # Trim to the art, then work at a coarser grid: the staircase we are trying
    # to lose is a pixel artefact, so tracing at full 1024 only adds points.
    ys, xs = np.where(mask)
    mask = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    small = np.array(Image.fromarray(mask.astype(np.uint8) * 255).resize(
        (mask.shape[1] // downsample, mask.shape[0] // downsample), Image.LANCZOS)) > 128
    small = ndimage.binary_closing(small, np.ones((3, 3)))

    h, w = small.shape
    side = max(h, w)
    s = size / side
    ox, oy = (side - w) / 2, (side - h) / 2

    paths = []
    for c in contours(small):
        c = rdp(c, eps)
        if len(c) < 4:
            continue
        c = c + np.array([ox, oy])
        paths.append(to_path(c, s))
    return paths, size


if __name__ == '__main__':
    src = sys.argv[1] if len(sys.argv) > 1 else 'masters/mono.png'
    paths, size = trace(src)
    print(f'{len(paths)} contours, {sum(p.count("C") for p in paths)} curves')
    body = '\n    '.join(f'<path d="{p}"/>' for p in paths)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
           f'fill="currentColor" fill-rule="evenodd">\n    {body}\n</svg>\n')
    open('traced.svg', 'w').write(svg)
    print('wrote traced.svg', len(svg), 'bytes')
