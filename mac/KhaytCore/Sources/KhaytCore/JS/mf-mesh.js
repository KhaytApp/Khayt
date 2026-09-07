'use strict';
/*
 * Painted-mesh extraction for the 3MF preview — a Node port of the bedready.io web extractor
 * (src/lib/paint.ts), which is the reference implementation this app's preview is modelled on.
 *
 * The important part is the paint codec: a 3MF `paint_color` / `mmu_segmentation` value is NOT a
 * filament index — it's a recursive triangle-subdivision bitstream (Orca/Bambu/Prusa
 * FacetsAnnotation::get_triangle_as_string). Each hex digit is 4 bits LSB-first and the digits are
 * PREPENDED, so the string reads right-to-left. dominantState() walks that stream and returns the
 * face's representative filament state (1-based; 0 = base). Colour = palette[state-1].
 *
 * Output is flat, non-indexed typed arrays (9 floats / face) so millions of triangles cost little
 * memory and hand straight to a GPU buffer. Handles the production-extension object graph
 * (build items → objects → cross-file components) with composed transforms, Bambu/Orca per-part
 * filament assignment, PrusaSlicer multi-volume colouring and Full-Spectrum palettes, build plates,
 * and stride-samples big models down to a preview budget (the full mesh still converts).
 */
(function (global) {
  const zipRead = (typeof require === 'function') ? require('./zip-read') : global.KhaytZip;

  const strFromU8 = (u8) => Buffer.isBuffer(u8) ? u8.toString('utf8') : Buffer.from(u8.buffer || u8, u8.byteOffset || 0, u8.byteLength).toString('utf8');
  const strToU8 = (s) => Buffer.from(String(s), 'utf8');

  function normalizeHex(h) {
    const s = (h || '').replace('#', '');
    return s.length >= 6 ? '#' + s.slice(0, 6).toUpperCase() : '#FFFFFF';
  }

  // ---------- paint codec ----------
  function hexToBits(h) {
    const bits = [];
    for (let j = h.length - 1; j >= 0; j--) {
      const d = parseInt(h[j], 16);
      if (!Number.isFinite(d)) continue;
      for (let b = 0; b < 4; b++) bits.push((d >> b) & 1);
    }
    return bits;
  }
  function bitsToHex(bits) {
    let h = '';
    for (let i = 0; i < bits.length; i += 4) {
      let nib = 0;
      for (let b = 0; b < 4 && i + b < bits.length; b++) nib |= bits[i + b] << b;
      h = nib.toString(16).toUpperCase() + h;
    }
    return h;
  }
  function encodeSolidPaint(state) {
    const bits = [0, 0];
    if (state >= 3) { bits.push(1, 1); for (let i = 0; i < 4; i++) bits.push((state - 3) >> i & 1); }
    else { bits.push(state & 1, (state >> 1) & 1); }
    return bitsToHex(bits);
  }
  // Real 3MF paint subdivision is only a few levels deep; cap recursion so an over-long / crafted
  // paint_color code from an untrusted file can't drive the decoder to a stack overflow.
  const PAINT_MAX_DEPTH = 64;
  // Representative (first-leaf) state of a paint code — the preview's per-face colour.
  function dominantState(hex) {
    const bits = hexToBits(hex);
    let p = 0;
    const rd = (k) => { let n = 0; for (let i = 0; i < k; i++) n |= (bits[p++] || 0) << i; return n; };
    let st = 0;
    (function tri(depth) {
      const ss = rd(2);
      if (ss && depth < PAINT_MAX_DEPTH) { rd(2); for (let c = 0; c < ss + 1; c++) tri(depth + 1); }
      else { const lo = rd(2); const s = lo === 3 ? rd(4) + 3 : lo; if (st === 0) st = s; }
    })(0);
    return st;
  }

  // PrusaSlicer "multi-volume" (per-colour triangle ranges) → synthesized paint_color per triangle.
  function applyPrusaVolumePaint(entries) {
    const cfgEntry = Object.entries(entries).find(([p]) => p.toLowerCase().endsWith('slic3r_pe_model.config'));
    if (!cfgEntry) return entries;
    const cfgXml = strFromU8(cfgEntry[1]);
    const objects = new Map();
    for (const om of cfgXml.matchAll(/<object id="(\d+)"[^>]*>([\s\S]*?)<\/object>/g)) {
      const oid = parseInt(om[1], 10);
      const body = om[2];
      const objExtruder = parseInt((body.match(/key="extruder" value="(\d+)"/) || [])[1] || '1', 10);
      const vols = [];
      for (const vm of body.matchAll(/<volume firstid="(\d+)" lastid="(\d+)"[^>]*>([\s\S]*?)<\/volume>/g)) {
        vols.push({ first: parseInt(vm[1], 10), last: parseInt(vm[2], 10), extruder: parseInt((vm[3].match(/key="extruder" value="(\d+)"/) || [])[1] || String(objExtruder), 10) });
      }
      objects.set(oid, { objExtruder, vols });
    }
    const withVols = [...objects.values()].filter((o) => o.vols.length);
    if (!withVols.length) return entries;
    const onlyObj = objects.size === 1 ? [...objects.values()][0] : null;
    const out = Object.assign({}, entries);
    for (const [path, data] of Object.entries(entries)) {
      if (!path.toLowerCase().endsWith('.model')) continue;
      let changed = false;
      const xml = strFromU8(data).replace(/<object id="(\d+)"([^>]*)>([\s\S]*?)<\/object>/g, (block, oidStr) => {
        const info = objects.get(parseInt(oidStr, 10)) || onlyObj;
        if (!info || !info.vols.length) return block;
        const extOf = (t) => { for (const v of info.vols) if (t >= v.first && t <= v.last) return v.extruder; return info.objExtruder; };
        let t = -1;
        return block.replace(/<triangle\b([^>]*?)\s*\/>/g, (tri, attrs) => {
          t++;
          if (/paint_color=|mmu_segmentation=/.test(attrs)) return tri;
          changed = true;
          return `<triangle${attrs} paint_color="${encodeSolidPaint(extOf(t))}"/>`;
        });
      });
      if (changed) out[path] = strToU8(xml);
    }
    return out;
  }

  function paletteFromFullSpectrum(entries) {
    const ent = Object.entries(entries).find(([p]) => /full_spectrum\.json$/i.test(p));
    if (!ent) return null;
    try {
      const o = JSON.parse(strFromU8(ent[1]));
      const all = [...(o.physical_extruders || []), ...(o.virtual_extruders || [])].filter((e) => e.id && e.color);
      if (!all.length) return null;
      const maxId = Math.max(...all.map((e) => e.id));
      const pal = new Array(maxId).fill('#FFFFFF');
      for (const e of all) pal[e.id - 1] = normalizeHex(e.color);
      return pal;
    } catch (_) { return null; }
  }

  // The exact mix recipe for each virtual (mixed) colour in a PrusaSlicer "Full Spectrum" (ColorMix) file:
  // state id → its component base extruders (1-based) + ratios. Lets the converter reproduce the author's
  // colours precisely instead of re-deriving an approximate mix. Returns null when the file isn't a
  // full-spectrum project or carries no virtual mixes. Ported from paint.ts recipesFromFullSpectrum.
  function recipesFromFullSpectrum(entries) {
    const ent = Object.entries(entries).find(([p]) => /full_spectrum\.json$/i.test(p));
    if (!ent) return null;
    try {
      const o = JSON.parse(strFromU8(ent[1]));
      const m = new Map();
      for (const v of o.virtual_extruders || []) {
        if (!v.id || !Array.isArray(v.components)) continue;
        const comps = v.components
          .filter((c) => c.extruder && c.ratio != null)
          .map((c) => ({ extruder: c.extruder, ratio: c.ratio }));
        if (comps.length) m.set(v.id, comps);
      }
      return m.size ? m : null;
    } catch (_) { return null; }
  }

  // Read a full-spectrum palette/recipes straight from members ([{name,data}]) — the shape the converter
  // engine (mf-convert.js) already has. Wraps the entries-map readers above.
  function fullSpectrumFromMembers(members) {
    const entries = Object.create(null);
    for (const m of members) entries[m.name] = m.data;
    return { palette: paletteFromFullSpectrum(entries), recipes: recipesFromFullSpectrum(entries) };
  }

  // ---------- geometry ----------
  // Render the full mesh for any normal model (a 2M-triangle detailed print renders fine on the GPU);
  // only genuinely enormous meshes get sampled, and only the truly impractical are skipped.
  const PREVIEW_BUDGET = 4_000_000;
  const HARD_CAP = 30_000_000;
  const TRI_RE = /<triangle[ />]/g;
  const IDENTITY4 = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  function transform12to16(t) {
    if (!t || t.length < 12) return IDENTITY4.slice();
    return [t[0], t[1], t[2], 0, t[3], t[4], t[5], 0, t[6], t[7], t[8], 0, t[9], t[10], t[11], 1];
  }
  function matMul(A, B) {
    const R = new Array(16);
    for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) { let s = 0; for (let k = 0; k < 4; k++) s += A[r * 4 + k] * B[k * 4 + c]; R[r * 4 + c] = s; }
    return R;
  }
  // \b so `id` cannot match the tail of `pid`/`pindex` — attribute order is arbitrary in
  // 3MF, and `<object pid="1" ... id="7">` returned "1", losing the entire mesh.
  const attr = (s, name) => (s.match(new RegExp(`\\b${name}\\s*=\\s*["\']([^"\']*)["\']`)) || [])[1];
  const stripSlash = (p) => p.replace(/^\//, '');

  // Same table as mf-convert.js:261, deliberately: two readers of one file must not disagree about
  // its scale. `micrometer` is not in the 3MF core spec; it is kept because mf-convert has always
  // accepted it and dropping it here would reintroduce the disagreement in the other direction.
  const UNIT_MM = { micron: 0.001, micrometer: 0.001, millimeter: 1, centimeter: 10, meter: 1000, inch: 25.4, foot: 304.8 };
  /** Millimetres per unit of the document's declared `unit`. Unknown or absent -> 1 (millimetre). */
  function unitScale(unit) { return UNIT_MM[String(unit == null ? '' : unit).trim().toLowerCase()] || 1; }

  // members: [{ name, data:Buffer }] from zip-read. Returns MeshData (flat typed arrays).
  function extractMeshFromMembers(members, maxFaces, hardCap) {
    maxFaces = maxFaces || PREVIEW_BUDGET; hardCap = hardCap || HARD_CAP;
    // Null-prototype map: member names come from an untrusted ZIP, so a "__proto__" entry name
    // must not reparent this object.
    const raw = Object.create(null);
    for (const m of members) raw[m.name] = m.data;
    const entries = applyPrusaVolumePaint(raw);

    let palette = [], prusaPalette = [], baseState = 1;
    const faceCountToExtr = new Map(), faceCountToName = new Map(), idToExtr = new Map();
    const plateDefs = [];
    const files = new Map();
    let buildPath = '';
    const buildItems = [];
    // A 3MF's <model> carries a `unit`, and it is not always millimetres — the core spec allows
    // micron, millimeter, centimeter, inch, foot and meter, and CAD exporters use them. This reader
    // did not look, so every vertex was taken as millimetres and everything derived from the
    // geometry inherited the error, in both directions: a 12x12x6 INCH box is 305x305x152 mm and
    // does not fit the U1's bed, and the preview said it did; a 200 mm part written in microns
    // measured 200000 and looked enormous.
    //
    // mf-convert.js:261 HAS read the unit all along (same table, plus a `micrometer` alias that is
    // not in the spec and is kept because tolerance costs nothing). So the two readers of the same
    // file disagreed about its scale — which is the exact failure the comment at the vertex loop
    // below already records about tag forms: "The two readers disagreeing meant a legal 3MF
    // converted wrongly with no warning." Same two readers, same file, second time.
    //
    // Normalising here fixes every consumer at once, because they are all downstream of this.
    // Ported from the bedready.io web reference (src/lib/paint.ts unitScale/mmPerUnit).
    let mmPerUnit = 1;

    for (const [path, data] of Object.entries(entries)) {
      const lower = path.toLowerCase();
      const base = lower.split('/').pop() || '';
      if (base === 'project_settings.config') {
        try { palette = (JSON.parse(strFromU8(data)).filament_colour || []).map(normalizeHex); } catch (_) { /* */ }
      } else if (base === 'slic3r_pe.config') {
        const text = strFromU8(data);
        const grab = (key) => { const m = text.match(new RegExp(`^;?\\s*${key}\\s*=\\s*(.+)$`, 'm')); return m ? m[1].trim().split(/[;,]/).map((s) => normalizeHex(s.trim())).filter(Boolean) : []; };
        const fc = grab('filament_colour'), ec = grab('extruder_colour');
        const distinct = (a) => new Set(a).size;
        prusaPalette = distinct(fc) >= 2 ? fc : distinct(ec) >= 2 ? ec : fc.length ? fc : ec;
      } else if (base === 'model_settings.config') {
        const xml = strFromU8(data);
        const first = xml.match(/key="extruder" value="(\d+)"/);
        if (first) baseState = parseInt(first[1], 10);
        for (const om of xml.matchAll(/<object\b[^>]*>([\s\S]*?)<\/object>/g)) {
          const body = om[1];
          const ex = parseInt((body.match(/key="extruder" value="(\d+)"/) || [])[1] || '0', 10);
          const fc = parseInt((body.match(/face_count="(\d+)"/) || [])[1] || '0', 10);
          const nm = (body.match(/key="name" value="([^"]*)"/) || [])[1];
          if (fc > 0) { if (ex > 0) faceCountToExtr.set(fc, ex); if (nm) faceCountToName.set(fc, nm); }
          for (const pm of body.matchAll(/<part\b([^>]*)>([\s\S]*?)<\/part>/g)) {
            const pid = parseInt(attr(pm[1], 'id') || '-1', 10);
            if (pid < 0) continue;
            const pe = parseInt((pm[2].match(/key="extruder" value="(\d+)"/) || [])[1] || '0', 10);
            idToExtr.set(pid, pe > 0 ? pe : ex > 0 ? ex : baseState);
          }
        }
        for (const pm of xml.matchAll(/<plate>([\s\S]*?)<\/plate>/g)) {
          const body = pm[1];
          const name = (body.match(/key="plater_name" value="([^"]*)"/) || [])[1] || '';
          const objectIds = [...body.matchAll(/key="object_id" value="(\d+)"/g)].map((m) => parseInt(m[1], 10));
          if (objectIds.length) plateDefs.push({ name, objectIds });
        }
      } else if (lower.endsWith('.model')) {
        const xml = strFromU8(data);
        const objs = new Map();
        for (const om of xml.matchAll(/<object\b([^>]*)>([\s\S]*?)<\/object>/g)) {
          const id = parseInt(attr(om[1], 'id') || '-1', 10);
          if (id < 0) continue;
          const body = om[2];
          const meshM = body.match(/<mesh>([\s\S]*?)<\/mesh>/);
          if (meshM) { objs.set(id, { mesh: meshM[1] }); }
          else {
            const comps = [];
            for (const cm of body.matchAll(/<component\b([^>]*?)\/?>/g)) {
              const oid = parseInt(attr(cm[1], 'objectid') || '-1', 10);
              if (oid < 0) continue;
              const cp = attr(cm[1], 'path'), tStr = attr(cm[1], 'transform');
              comps.push({ path: cp ? stripSlash(cp) : stripSlash(path), objectid: oid, transform: transform12to16(tStr ? tStr.trim().split(/\s+/).map(Number) : []) });
            }
            objs.set(id, { comps });
          }
        }
        files.set(stripSlash(path), objs);
        if (/<build[\s>]/.test(xml)) {
          buildPath = stripSlash(path);
          // The unit is a property of the DOCUMENT, read from the file that carries <build>.
          // Component files are part of the same document and share it; one claiming something else
          // must not silently rescale part of the model.
          mmPerUnit = unitScale((/<model\b[^>]*\bunit=["']?([A-Za-z]+)/i.exec(xml) || [])[1]);
          for (const im of xml.matchAll(/<item\b([^>]*?)\/?>/g)) {
            const oid = parseInt(attr(im[1], 'objectid') || '-1', 10);
            if (oid < 0) continue;
            const tStr = attr(im[1], 'transform');
            buildItems.push({ objectid: oid, transform: transform12to16(tStr ? tStr.trim().split(/\s+/).map(Number) : []) });
          }
        }
      }
    }

    const triCountOf = (node) => { if (node.triCount == null) node.triCount = node.mesh ? (node.mesh.match(TRI_RE) || []).length : 0; return node.triCount; };
    // `seen` tracks the CURRENT DESCENT PATH, not every node visited: a component may
    // legitimately appear twice as siblings, but must never appear inside its own ancestry.
    // subtree() above already breaks cycles with a memo sentinel, so on a cyclic graph the
    // counter stayed small while this emitter kept descending to the depth cap — writing far
    // more faces than the typed arrays were sized for (silently discarded) and advertising
    // `parts` ranges many times larger than the buffers, which any consumer slicing by
    // part.start/end would read past.
    const walk = (path, oid, M, depth, onLeaf, seen) => {
      if (depth > 64) return;
      const key = path + '\u0000' + oid;
      if (seen && seen.has(key)) return;                 // cycle — stop this branch
      const node = (files.get(path) || new Map()).get(oid);
      if (!node) return;
      if (node.mesh != null) { onLeaf(node, M, oid); return; }
      const next = new Set(seen || []);
      next.add(key);
      for (const c of node.comps || []) walk(c.path, c.objectid, matMul(c.transform, M), depth + 1, onLeaf, next);
    };

    if (palette.length === 0 && prusaPalette.length) palette = prusaPalette;
    const fsPal = paletteFromFullSpectrum(entries);
    if (fsPal && fsPal.length > palette.length) palette = fsPal;

    let roots = buildItems.map((it) => ({ path: buildPath, objectid: it.objectid, transform: it.transform }));
    if (roots.length === 0) { roots = []; for (const [path, objs] of files) for (const [id, node] of objs) if (node.mesh != null) roots.push({ path, objectid: id, transform: IDENTITY4.slice() }); }

    // Count each root's subtree with MEMOIZATION + a cycle sentinel, mirroring the
    // memoized resolver in mf-convert.js. A malicious 3MF whose components each
    // reference the same child twice would otherwise cost 2^depth walk() calls and
    // hang the main process. Memoization makes counting O(nodes); the instance total
    // (which also bounds the emit walk() below) trips the cap instead of exploding.
    const subMemo = new Map();
    const subtree = (path, oid, depth) => {
      if (depth > 64) return { tris: 0, insts: 0 };
      const key = path + '\u0000' + oid;
      const hit = subMemo.get(key);
      if (hit) return hit;
      subMemo.set(key, { tris: 0, insts: 0 }); // sentinel breaks reference cycles
      const node = (files.get(path) || new Map()).get(oid);
      if (!node) return { tris: 0, insts: 0 };
      let r;
      if (node.mesh != null) r = { tris: triCountOf(node), insts: 1 };
      else {
        let tris = 0, insts = 0;
        for (const c of node.comps || []) { const s = subtree(c.path, c.objectid, depth + 1); tris += s.tris; insts += s.insts; }
        r = { tris, insts };
      }
      subMemo.set(key, r);
      return r;
    };
    let triangleCount = 0, totalInstances = 0; const rootBase = [], rootName = [];
    for (const r of roots) {
      const s = subtree(r.path, r.objectid, 0);
      triangleCount += s.tris; totalInstances += s.insts;
      rootBase.push(faceCountToExtr.get(s.tris) != null ? faceCountToExtr.get(s.tris) : baseState);
      rootName.push(faceCountToName.get(s.tris) || '');
    }

    // `mmPerUnit` is on BOTH return shapes, not just the one with geometry.
    //
    // #784 added it to the full return and not to this one, so a 3MF that is
    // empty or over the triangle budget came back with `mmPerUnit: undefined`.
    // No geometry is scaled on this path, so nothing was numerically wrong yet —
    // but a consumer reading `mesh.mmPerUnit` to label a size or check a bed fit
    // gets undefined here and a number there, and `undefined * anything` is NaN.
    // That is the Salla `Number(undefined)` shape waiting to happen, and the
    // printer audits' question in a new place: WHICH RETURN IS THE FIELD ON.
    //
    // Caught by makerrun's engine-parity suite, which compares this extractor
    // against the web reference it was ported from and reported
    // `mmPerUnit differs (unit="millimeter" ×1): 1 !== undefined`.
    const emptyMesh = (skipped) => ({ positions: new Float32Array(0), faceState: new Uint8Array(0), palette, usage: palette.map(() => 0), statesPresent: [], baseState, triangleCount, skipped, sampled: false, parts: [], plates: [], mmPerUnit });
    if (triangleCount === 0) return emptyMesh(false);
    // Bail on a huge triangle budget OR a huge instance count — the latter bounds the
    // emit walk() below (which visits every leaf instance) against exponential blow-up.
    if (triangleCount > hardCap || totalInstances > 2_000_000) return emptyMesh(true);

    const stride = triangleCount > maxFaces ? Math.ceil(triangleCount / maxFaces) : 1;
    const cap = stride === 1 ? triangleCount : Math.ceil(triangleCount / stride);
    const positions = new Float32Array(cap * 9);
    const faceState = new Uint8Array(cap);
    let vc = 0, fc = 0, gtri = 0;

    const emit = (seg, M, baseExtr) => {
      const nv = (seg.match(/<vertex\b/g) || []).length;
      const vx = new Float32Array(nv * 3);
      let i = 0;
      // Tolerant forms, matching mf-convert.js:309 which reads the SAME data: self-closing
      // or paired tags, single or double quotes, attributes on following lines. The two
      // readers disagreeing meant a legal 3MF converted wrongly with no warning.
      for (const m of seg.matchAll(/<vertex\b([^>]*?)\/?>/g)) {
        const tag = m[0];
        const x = +((tag.match(/\bx=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/) || [])[1] || 0),
              y = +((tag.match(/\by=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/) || [])[1] || 0),
              z = +((tag.match(/\bz=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/) || [])[1] || 0);
        // x mmPerUnit last: the scale is uniform, so scaling world space is the same as folding
        // it into M, and it correctly scales the translation terms (an offset is in the same unit).
        vx[i++] = (x * M[0] + y * M[4] + z * M[8] + M[12]) * mmPerUnit;
        vx[i++] = (x * M[1] + y * M[5] + z * M[9] + M[13]) * mmPerUnit;
        vx[i++] = (x * M[2] + y * M[6] + z * M[10] + M[14]) * mmPerUnit;
      }
      for (const m of seg.matchAll(/<triangle\b([^>]*?)\/?>/g)) {
        if (gtri++ % stride !== 0) continue;
        const a = m[1];
        const v1 = +((a.match(/\bv1=["']?(\d+)/) || [])[1] || 0),
              v2 = +((a.match(/\bv2=["']?(\d+)/) || [])[1] || 0),
              v3 = +((a.match(/\bv3=["']?(\d+)/) || [])[1] || 0);
        const pc = a.match(/(?:paint_color|mmu_segmentation)=["']?([0-9A-Fa-f]+)/);
        faceState[fc++] = pc ? dominantState(pc[1]) : baseExtr;
        positions[vc++] = vx[v1 * 3]; positions[vc++] = vx[v1 * 3 + 1]; positions[vc++] = vx[v1 * 3 + 2];
        positions[vc++] = vx[v2 * 3]; positions[vc++] = vx[v2 * 3 + 1]; positions[vc++] = vx[v2 * 3 + 2];
        positions[vc++] = vx[v3 * 3]; positions[vc++] = vx[v3 * 3 + 1]; positions[vc++] = vx[v3 * 3 + 2];
      }
    };

    const partRanges = [];
    roots.forEach((r, ri) => {
      partRanges.push({ name: rootName[ri], objectId: r.objectid, start: fc });
      walk(r.path, r.objectid, r.transform, 0, (node, M, leafOid) => emit(node.mesh, M, idToExtr.get(leafOid) != null ? idToExtr.get(leafOid) : rootBase[ri]));
    });
    const parts = partRanges.map((pr, i) => {
      const end = i + 1 < partRanges.length ? partRanges[i + 1].start : fc;
      return { name: pr.name, objectId: pr.objectId, start: pr.start, end, triangleCount: end - pr.start };
    }).filter((p) => p.triangleCount > 0);

    const plates = plateDefs.map((pd) => ({
      name: pd.name,
      partIndices: parts.map((p, i) => (pd.objectIds.includes(p.objectId) ? i : -1)).filter((i) => i >= 0),
    })).filter((pl) => pl.partIndices.length > 0);

    // Per-state usage (faces per palette index, state-1) + the distinct non-zero states present. Base
    // (unpainted) faces already carry their resolved extruder in faceState (idToExtr / rootBase), so an
    // object-encoded multicolour file — coloured per <part>, with zero paint_color in the mesh — tallies
    // correctly here, where a raw paint_color scan would report zero. Drives the converter's Full-Spectrum
    // head selection and the band/swap analysis.
    const usage = palette.map(() => 0);
    const present = new Set();
    for (let f = 0; f < fc; f++) { const s = faceState[f]; if (s >= 1) { usage[s - 1] = (usage[s - 1] || 0) + 1; present.add(s); } }

    return {
      positions: vc === positions.length ? positions : positions.subarray(0, vc),
      faceState: fc === faceState.length ? faceState : faceState.subarray(0, fc),
      palette, usage, statesPresent: [...present].sort((a, b) => a - b),
      baseState, triangleCount, skipped: false, sampled: stride > 1, parts, plates, mmPerUnit,
    };
  }

  // Convenience: extract straight from a 3MF Buffer.
  function extractMeshFromBuffer(buf, maxFaces, hardCap) {
    let zip; try { zip = zipRead.openZip(buf); } catch (_) { zip = null; }
    const members = [];
    if (zip && zip.entries) for (const e of zip.entries) { const d = zip.file(e.name); if (d) members.push({ name: e.name, data: d }); }
    return extractMeshFromMembers(members, maxFaces, hardCap);
  }

  const api = { extractMeshFromMembers, extractMeshFromBuffer, dominantState, hexToBits, bitsToHex, encodeSolidPaint, normalizeHex, paletteFromFullSpectrum, recipesFromFullSpectrum, fullSpectrumFromMembers, unitScale, PREVIEW_BUDGET, HARD_CAP };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytMfMesh = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
