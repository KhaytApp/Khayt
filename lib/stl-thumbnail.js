'use strict';
/**
 * Software STL thumbnail renderer — turns a triangle mesh into a small shaded
 * preview image, with NO 3D dependency (no WebGL / three.js). Orthographic 3/4
 * view, painter's algorithm for depth, flat Lambert shading. Runs on a plain 2D
 * canvas, so it works in the renderer and — via an injected canvas factory — under
 * node --test.
 *
 * Input triangles come from lib/stl-parse.js parseStl(buf,{keepTriangles:true}).
 * Big meshes are decimated (uniform stride) purely for the thumbnail so a
 * multi-million-triangle STL can't jank the UI.
 */
(function (global) {
  const DEFAULTS = {
    size: 512,           // square canvas, px
    padding: 0.08,       // fraction of size kept as margin
    background: '#0e1116',
    color: [120, 144, 168], // base RGB before shading
    ambient: 0.28,
    maxTriangles: 200000,
    quality: 0.82,
  };

  function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  function norm(a) { const L = Math.hypot(a[0], a[1], a[2]) || 1; return [a[0] / L, a[1] / L, a[2] / L]; }

  /**
   * @param {Array<[[x,y,z],[x,y,z],[x,y,z]]>} triangles
   * @param {object} [opts] incl. canvasFactory(size)=>canvasLike ({getContext, toDataURL, width, height})
   * @returns {{ ok:boolean, dataUrl?:string, canvas?:any, triangleCount?:number }}
   */
  function renderStlThumbnail(triangles, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    if (!Array.isArray(triangles) || !triangles.length) return { ok: false };

    const factory = o.canvasFactory
      || (typeof document !== 'undefined' ? (s) => { const c = document.createElement('canvas'); c.width = c.height = s; return c; } : null);
    if (!factory) return { ok: false };

    // Decimate for the thumbnail if the mesh is huge.
    // Optional per-triangle colours (true multicolour), flat [r,g,b] per triangle. Decimated
    // in lockstep with the mesh so colours stay aligned to faces.
    const tcRaw = o.triColors && o.triColors.length ? o.triColors : null;
    let tris = triangles, triCol = tcRaw;
    if (triangles.length > o.maxTriangles) {
      const stride = Math.ceil(triangles.length / o.maxTriangles);
      tris = []; const tc = tcRaw ? [] : null;
      for (let i = 0; i < triangles.length; i += stride) { tris.push(triangles[i]); if (tc) tc.push(tcRaw[i * 3], tcRaw[i * 3 + 1], tcRaw[i * 3 + 2]); }
      if (tc) triCol = tc;
    }

    // Camera: look from front-right-top (Z is up for print STLs). When yaw/pitch are
    // given (interactive viewer, lib/model-viewer via renderer), orbit the camera on a
    // sphere instead; omitting both keeps the exact fixed 3/4 thumbnail view.
    let camDir;
    if (o.yaw != null || o.pitch != null) {
      const yaw = o.yaw || 0;
      const pitch = Math.max(-1.45, Math.min(1.45, o.pitch || 0)); // clamp away from the poles
      const cp = Math.cos(pitch);
      camDir = norm([Math.cos(yaw) * cp, Math.sin(yaw) * cp, Math.sin(pitch)]);
    } else {
      camDir = norm([1, -1, 0.75]);            // object → camera (also the light)
    }
    const fwd = [-camDir[0], -camDir[1], -camDir[2]]; // into the scene
    let right = cross(fwd, [0, 0, 1]);
    if (Math.hypot(right[0], right[1], right[2]) < 1e-6) right = [1, 0, 0];
    right = norm(right);
    const up = norm(cross(right, fwd));

    // Optional colour ramp (multicolour "full spectrum" preview): a list of [r,g,b] the
    // model actually declares. We shade each triangle by its height through the ramp — a
    // faithful read for the common colour-by-layer / gradient print, and a clear "this is
    // multicolour, these are the colours" signal otherwise.
    const ramp = Array.isArray(o.colorRamp) && o.colorRamp.length ? o.colorRamp : null;
    const rampAt = (u) => {
      if (ramp.length === 1) return ramp[0];
      const x = Math.max(0, Math.min(1, u)) * (ramp.length - 1);
      const i = Math.floor(x), f = x - i, a = ramp[i], b = ramp[Math.min(ramp.length - 1, i + 1)];
      return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
    };

    // Project every vertex; track screen-space bounds (world-Z range for the ramp, and
    // world XY bounds + base Z so an optional build-plate can be laid under the model).
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    let zMin = Infinity, zMax = -Infinity;
    let wx0 = Infinity, wx1 = -Infinity, wy0 = Infinity, wy1 = -Infinity, wz0 = Infinity;
    const faces = new Array(tris.length);
    for (let i = 0; i < tris.length; i++) {
      const t = tris[i];
      const p = [t[0], t[1], t[2]].map((v) => [dot(v, right), dot(v, up), dot(v, fwd)]);
      let n = norm(cross(sub(t[1], t[0]), sub(t[2], t[0])));
      if (dot(n, camDir) < 0) n = [-n[0], -n[1], -n[2]]; // face the camera
      // Two-light shading: a key light from the camera + a soft top fill, so the form
      // reads better than a single flat lambert term.
      const key = Math.max(0, dot(n, camDir));
      const fill = Math.max(0, n[2]); // world-up fill
      const shade = Math.min(1, o.ambient + (1 - o.ambient) * (0.82 * key + 0.18 * fill));
      const depth = (p[0][2] + p[1][2] + p[2][2]) / 3;
      const wz = (t[0][2] + t[1][2] + t[2][2]) / 3; // world height, for the colour ramp
      if (wz < zMin) zMin = wz; if (wz > zMax) zMax = wz;
      faces[i] = { p, shade, depth, wz, ci: i };
      for (let vi = 0; vi < 3; vi++) {
        const q = p[vi], v = t[vi];
        if (q[0] < minX) minX = q[0]; if (q[0] > maxX) maxX = q[0];
        if (q[1] < minY) minY = q[1]; if (q[1] > maxY) maxY = q[1];
        if (v[0] < wx0) wx0 = v[0]; if (v[0] > wx1) wx1 = v[0];
        if (v[1] < wy0) wy0 = v[1]; if (v[1] > wy1) wy1 = v[1];
        if (v[2] < wz0) wz0 = v[2];
      }
    }
    const zSpan = (zMax - zMin) || 1;

    // Optional build-plate: a grid + outline on the model's base plane, sized to a target
    // printer bed and centred under the model — so you see scale/orientation/fit. Its
    // corners join the fit-bounds so the whole plate stays in frame.
    let bedDraw = null;
    if (o.bed && o.bed.x > 0 && o.bed.y > 0) {
      const cx = (wx0 + wx1) / 2, cy = (wy0 + wy1) / 2, hx = o.bed.x / 2, hy = o.bed.y / 2;
      const P = (x, y) => { const v = [x, y, wz0]; return [dot(v, right), dot(v, up), dot(v, fwd)]; };
      const mb = Math.max(o.bed.x, o.bed.y);
      const step = mb <= 120 ? 10 : mb <= 260 ? 20 : mb <= 420 ? 50 : 100;
      const segs = [];
      for (let gx = -hx; gx <= hx + 1e-6; gx += step) segs.push([P(cx + gx, cy - hy), P(cx + gx, cy + hy)]);
      for (let gy = -hy; gy <= hy + 1e-6; gy += step) segs.push([P(cx - hx, cy + gy), P(cx + hx, cy + gy)]);
      const outline = [P(cx - hx, cy - hy), P(cx + hx, cy - hy), P(cx + hx, cy + hy), P(cx - hx, cy + hy)];
      bedDraw = { segs, outline };
      for (const q of outline) { if (q[0] < minX) minX = q[0]; if (q[0] > maxX) maxX = q[0]; if (q[1] < minY) minY = q[1]; if (q[1] > maxY) maxY = q[1]; }
    }

    const S = o.size;
    const pad = S * o.padding;
    const spanX = (maxX - minX) || 1, spanY = (maxY - minY) || 1;
    // Fit-to-frame, then apply interactive zoom + pan (screen px, as a fraction of size).
    const zoom = o.zoom > 0 ? o.zoom : 1;
    const scale = Math.min((S - 2 * pad) / spanX, (S - 2 * pad) / spanY) * zoom;
    const offX = (S - spanX * scale) / 2 + (o.panX || 0) * S;
    const offY = (S - spanY * scale) / 2 - (o.panY || 0) * S;
    const sx = (x) => offX + (x - minX) * scale;
    const sy = (y) => S - (offY + (y - minY) * scale); // flip Y for canvas

    // Painter's algorithm: far faces first. `depth` = dot(centroid, fwd) where fwd points
    // from the eye INTO the scene, so LARGER depth = farther → draw descending so the
    // nearest faces paint last, on top. (The earlier ascending order drew back faces over
    // front ones — invisible with a single colour thanks to the normal-flip, but wrong once
    // faces carry their own paint colours.)
    faces.sort((a, b) => b.depth - a.depth);

    const canvas = factory(S);
    const ctx = canvas.getContext && canvas.getContext('2d');
    if (!ctx) return { ok: false };
    ctx.fillStyle = o.background;
    ctx.fillRect(0, 0, S, S);

    // Build-plate first (behind the model): grid, then a fit-coloured outline.
    if (bedDraw) {
      const lw = Math.max(1, S / 460);
      ctx.lineWidth = lw; ctx.strokeStyle = o.bedGrid || 'rgba(130,150,170,0.30)';
      ctx.beginPath();
      for (const s of bedDraw.segs) { ctx.moveTo(sx(s[0][0]), sy(s[0][1])); ctx.lineTo(sx(s[1][0]), sy(s[1][1])); }
      ctx.stroke();
      ctx.lineWidth = lw * 2; ctx.lineJoin = 'round';
      ctx.strokeStyle = o.bedFits === false ? (o.bedNoFit || '#e0533d') : (o.bedColor || 'rgba(120,140,160,0.75)');
      ctx.beginPath();
      const o4 = bedDraw.outline;
      ctx.moveTo(sx(o4[0][0]), sy(o4[0][1]));
      for (let i = 1; i < 4; i++) ctx.lineTo(sx(o4[i][0]), sy(o4[i][1]));
      ctx.closePath(); ctx.stroke();
    }

    const [r, g, b] = o.color;
    const wire = o.wireframe ? (o.wireColor || 'rgba(20,24,30,0.22)') : null;
    if (wire) { ctx.lineWidth = o.wireWidth || 1; ctx.lineJoin = 'round'; }
    for (const f of faces) {
      const c = f.shade;
      const base = triCol ? [triCol[f.ci * 3], triCol[f.ci * 3 + 1], triCol[f.ci * 3 + 2]]
        : ramp ? rampAt((f.wz - zMin) / zSpan) : [r, g, b];
      ctx.fillStyle = `rgb(${Math.round(base[0] * c)},${Math.round(base[1] * c)},${Math.round(base[2] * c)})`;
      ctx.beginPath();
      ctx.moveTo(sx(f.p[0][0]), sy(f.p[0][1]));
      ctx.lineTo(sx(f.p[1][0]), sy(f.p[1][1]));
      ctx.lineTo(sx(f.p[2][0]), sy(f.p[2][1]));
      ctx.closePath();
      ctx.fill();
      if (wire) { ctx.strokeStyle = wire; ctx.stroke(); }
    }

    const dataUrl = typeof canvas.toDataURL === 'function' ? canvas.toDataURL('image/jpeg', o.quality) : null;
    return { ok: true, dataUrl, canvas, triangleCount: tris.length };
  }

  const api = { renderStlThumbnail };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStlThumb = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
