'use strict';
/**
 * Every expensive thing the 3MF converter does, as plain Node with no Electron in it.
 *
 * These used to run inline in the main process, which is the only thread Electron has for
 * windows, menus and IPC. Converting a 229 MB poster took about eight seconds there, and
 * for those eight seconds the app was not slow — it was stopped: no repaint, no button,
 * no cancel, the OS offering to force-quit it.
 *
 * Nothing here knows about processes. `run(op, args)` reads its own input, writes its own
 * output where it is told, and returns something small enough to send back. lib/mf-worker.js
 * runs it in a utilityProcess; main.js can also call it directly when no child is available,
 * so the fallback path is the same code and not a second implementation of it.
 *
 * Two rules keep the security boundary in the parent where it belongs:
 *   - every path in `args` is already validated by the caller; nothing here consults an
 *     allow-list, and nothing here asks the user anything.
 *   - results that would be large (a converted 3MF, an STL) are written to a caller-chosen
 *     path and reported by name. A 228 MB buffer is not sent back over a pipe.
 */
const fs = require('fs');
const path = require('path');

const { extract: extractPrintThumb } = require('./thumbnail-extract');

function bboxOfPositions(pos) {
  let x0 = Infinity, y0 = Infinity, z0 = Infinity, x1 = -Infinity, y1 = -Infinity, z1 = -Infinity;
  for (let i = 0; i < pos.length; i += 3) {
    const x = pos[i], y = pos[i + 1], z = pos[i + 2];
    if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; if (z < z0) z0 = z; if (z > z1) z1 = z;
  }
  return Number.isFinite(x0) ? { x: x1 - x0, y: y1 - y0, z: z1 - z0 } : { x: 0, y: 0, z: 0 };
}
const _hx = (h) => { const m = /^#?([0-9a-f]{6})/i.exec(String(h || '')); return m ? [parseInt(m[1].slice(0, 2), 16), parseInt(m[1].slice(2, 4), 16), parseInt(m[1].slice(4, 6), 16)] : [180, 180, 185]; };

function meshFromBuffer(buf, ext) {
  if (ext === '3mf') {
    // Painted-mesh extraction ported from the bedready.io reference (lib/mf-mesh.js): flat world-
    // space positions + a correctly-decoded filament state per face + the real filament palette.
    const mfMesh = require('./mf-mesh');
    let mesh = null;
    try { mesh = mfMesh.extractMeshFromBuffer(buf); } catch (e) { try { console.warn('[mesh] extract failed', e && e.message); } catch (_) {} }
    if (!mesh || !mesh.positions || !mesh.positions.length) {
      // No renderable geometry — fall back to the slicer's own embedded thumbnail, with a
      // diagnostic (counts + part sizes) so any genuine failure is debuggable rather than opaque.
      let diag = '';
      try {
        const mf = require('./mf-convert');
        const models = mf.readMembers(buf).filter((m) => /\.model$/i.test(m.name));
        const cnt = (b, s) => { const nd = Buffer.from(s); let c = 0, i = 0; while ((i = b.indexOf(nd, i)) !== -1) { c++; i += nd.length; } return c; };
        let nO = 0, nV = 0, nT = 0;
        const sizes = models.map((m) => { nO += cnt(m.data, '<object'); nV += cnt(m.data, '<vertex'); nT += cnt(m.data, '<triangle'); return Math.round(m.data.length / 1048576) + 'MB'; });
        diag = ` (models:${models.length}[${sizes.join(',')}] objects:${nO} vertices:${nV} triangles:${nT}${mesh && mesh.skipped ? ' skipped:too-big' : ''})`;
      } catch (_) { /* best-effort */ }
      try { const th = extractPrintThumb({ ext, buf }); if (th && th.pngBase64) return { ok: false, error: 'no-geometry' + diag, thumb: 'data:image/png;base64,' + th.pngBase64 }; } catch (_) {}
      return { ok: false, error: 'no-geometry' + diag };
    }
    const verts = mesh.positions;
    const count = verts.length / 9 | 0;
    const palette = (mesh.palette && mesh.palette.length) ? mesh.palette.slice() : null;
    const faceState = mesh.faceState;
    // Per-face palette index (state − 1; state 0 → base filament 0) + baked colours for the first view.
    let triColors = null, triCode = null;
    if (palette && palette.length && faceState) {
      const n = palette.length, pal = palette.map(_hx);
      triColors = new Uint8Array(count * 3);
      triCode = new Uint16Array(count);
      for (let i = 0; i < count; i++) {
        const s = faceState[i];
        const idx = s >= 1 ? Math.min(s - 1, n - 1) : 0;
        triCode[i] = idx;
        const c = pal[idx] || pal[0];
        triColors[i * 3] = c[0]; triColors[i * 3 + 1] = c[1]; triColors[i * 3 + 2] = c[2];
      }
    }
    // Per-face part index + plate grouping so the preview can show one plate/part at a time.
    let triObj = null, plates = null;
    const parts = mesh.parts || [];
    if (parts.length > 1) {
      triObj = new Uint32Array(count);
      parts.forEach((p, pi) => { for (let f = p.start; f < p.end && f < count; f++) triObj[f] = pi; });
      const grp = (mesh.plates || []).map((pl) => ({ name: pl.name || '', objs: pl.partIndices.slice() })).filter((pl) => pl.objs.length);
      if (grp.length > 1) plates = grp;
    }
    // Solid volume only when the full mesh was rendered (a sampled surface isn't watertight).
    let volumeMm3 = null;
    if (!mesh.sampled) {
      let vol6 = 0;
      for (let i = 0; i < verts.length; i += 9) {
        const ax = verts[i], ay = verts[i + 1], az = verts[i + 2], bx = verts[i + 3], by = verts[i + 4], bz = verts[i + 5], cx = verts[i + 6], cy = verts[i + 7], cz = verts[i + 8];
        vol6 += ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx);
      }
      volumeMm3 = Math.abs(vol6) / 6;
    }
    return { ok: true, verts, count, bbox: bboxOfPositions(verts), colors: palette || [], volumeMm3, triColors, triObj, plates, triCode, palette };
  }

  // STL: full mesh (usually already low enough poly for a preview), decimated only if huge.
  const g = require('./stl-parse').parseStl(buf, { keepTriangles: true });
  let tris = g && g.triangles;
  if (!Array.isArray(tris) || !tris.length) return { ok: false, error: 'no-geometry' };
  let vol6 = 0;
  for (const t of tris) { const a = t[0], b = t[1], c = t[2]; if (!a || !b || !c) continue; vol6 += a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]); }
  const volumeMm3 = Math.abs(vol6) / 6;
  const MAX = 1500000;
  if (tris.length > MAX) { const s = Math.ceil(tris.length / MAX); const out = []; for (let i = 0; i < tris.length; i += s) out.push(tris[i]); tris = out; }
  const verts = new Float32Array(tris.length * 9);
  let k = 0;
  for (const t of tris) for (let j = 0; j < 3; j++) { const p = t[j]; verts[k++] = p[0]; verts[k++] = p[1]; verts[k++] = p[2]; }
  return { ok: true, verts, count: tris.length, bbox: bboxOfPositions(verts), colors: [], volumeMm3, triColors: null, triObj: null, plates: null, triCode: null, palette: null };
}

// ── jobs ────────────────────────────────────────────────────────────────────

/** Read a source the caller has already vetted, refusing anything past its size ceiling. */
async function readSource(src, maxBytes) {
  const buf = await fs.promises.readFile(path.resolve(String(src)));
  if (maxBytes && buf.length > maxBytes) { const e = new Error('too-large'); e.tooLarge = true; throw e; }
  return buf;
}

/** Write a produced file and describe it, so the parent can move it into place. */
async function emit(tmpOut, data, extra) {
  await fs.promises.writeFile(tmpOut, data);
  return Object.assign({ ok: true, tmpPath: tmpOut, size: data.length }, extra || {});
}

const OPS = {
  async analyze({ src, maxBytes }) {
    return require('./mf-convert').analyze(await readSource(src, maxBytes));
  },

  async mesh({ src, maxBytes }) {
    const buf = await readSource(src, maxBytes);
    return meshFromBuffer(buf, path.extname(path.resolve(String(src))).slice(1).toLowerCase());
  },

  async fsPlan({ src, maxBytes, opts }) {
    return require('./mf-convert').fsPreview(await readSource(src, maxBytes), opts || {});
  },

  async prusaPlan({ src, maxBytes, opts }) {
    return require('./mf-convert').prusaPreview(await readSource(src, maxBytes), opts || {});
  },

  async bands({ src, maxBytes, opts }) {
    return require('./mf-convert').analyzeColorBands(await readSource(src, maxBytes), opts || {});
  },

  async convert({ src, maxBytes, opts, tmpOut }) {
    const r = require('./mf-convert').convert(await readSource(src, maxBytes), opts || {});
    if (!r.ok) return r;
    return emit(tmpOut, r.buffer, { report: r.report });
  },

  async stlTo3mf({ src, maxBytes, tmpOut }) {
    const parsed = require('./stl-parse').parseStl(await readSource(src, maxBytes), { keepTriangles: true });
    if (!parsed || !parsed.triangleCount) return { ok: false, error: 'No mesh found in that STL.' };
    const out = require('./mf-write').meshTo3mf(parsed.triangles);
    if (!out) return { ok: false, error: 'Failed to build the 3MF.' };
    return emit(tmpOut, out, { report: { triangleCount: parsed.triangleCount, bbox: parsed.bbox } });
  },

  /**
   * Volume, bounding box and facet count for a 3MF, off the thread drawing the
   * app.
   *
   * A real poster is thirteen million facets and takes about nine seconds to
   * fold — small in memory now (mf-convert measureMesh streams it) but not
   * small in time, and nine seconds in the main process is nine seconds of
   * frozen app for every window. This is exactly what this process is for.
   */
  async measure({ src, maxBytes }) {
    const mf = require('./mf-convert');
    const members = mf.readMembers(await readSource(src, maxBytes));
    if (!members || !members.length) return { ok: false, error: 'Not a readable 3MF/ZIP file.' };
    const g = mf.measureMesh(members);
    if (!g) return { ok: true, geometry: null };
    return { ok: true, geometry: g };
  },

  async mfToStl({ src, maxBytes, tmpOut }) {
    const mf = require('./mf-convert');
    const tris = mf.extractTriangles(mf.readMembers(await readSource(src, maxBytes)));
    if (!tris || !tris.length) return { ok: false, error: 'No mesh geometry found in that 3MF.' };
    const stl = require('./mf-write').trianglesToStl(tris);
    if (!stl) return { ok: false, error: 'Failed to build the STL.' };
    return emit(tmpOut, stl, { triangleCount: tris.length });
  },
};

/**
 * Run one job. Never throws for an expected condition — an oversized file and a job name
 * nobody implements both come back as a result, because the caller of this is a pipe.
 */
async function run(op, args) {
  const fn = OPS[op];
  if (!fn) return { ok: false, error: 'Unknown job: ' + String(op) };
  try {
    return await fn(args || {});
  } catch (e) {
    if (e && e.tooLarge) return { ok: false, available: false, error: 'File is too large.' };
    return { ok: false, available: false, error: String((e && e.message) || e) };
  }
}

module.exports = { run, meshFromBuffer, bboxOfPositions, OPS: Object.keys(OPS) };
