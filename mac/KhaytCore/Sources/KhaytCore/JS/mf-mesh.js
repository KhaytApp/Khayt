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

  // A member's data is a Buffer in Node and a STRING in the native Mac app, whose zip is Swift's and
  // which hands text across (KhaytEngine.convertMembers). JavaScriptCore has no `Buffer`, so the
  // string case is answered before it is touched: before, every mesh read there threw, and band-swap
  // and the per-plate palettes quietly reported "not available" on the Mac.
  const hasBuffer = typeof Buffer !== 'undefined';
  const strFromU8 = (u8) => (typeof u8 === 'string' ? u8
    : hasBuffer && Buffer.isBuffer(u8) ? u8.toString('utf8')
    : hasBuffer ? Buffer.from(u8.buffer || u8, u8.byteOffset || 0, u8.byteLength).toString('utf8')
    : new TextDecoder('utf-8').decode(u8));
  const strToU8 = (s) => (hasBuffer ? Buffer.from(String(s), 'utf8') : String(s));

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
  // EVERY leaf state of a paint code, not just the first: which filaments a painted face really
  // uses. A face split into a large base region and a small painted dot uses both, and the dominant
  // state alone dropped the dot's filament from "what this print is made of". 0 = the face's base.
  function leafStates(hex) {
    const bits = hexToBits(hex);
    let p = 0;
    const rd = (k) => { let n = 0; for (let i = 0; i < k; i++) n |= (bits[p++] || 0) << i; return n; };
    const out = new Set();
    (function tri(depth) {
      const ss = rd(2);
      if (ss && depth < PAINT_MAX_DEPTH) { rd(2); for (let c = 0; c < ss + 1; c++) tri(depth + 1); }
      else { const lo = rd(2); out.add(lo === 3 ? rd(4) + 3 : lo); }
    })(0);
    return out;
  }

  // PrusaSlicer "multi-volume" (per-colour triangle ranges) → synthesized paint_color per triangle.
  function applyPrusaVolumePaint(entries) {
    const cfgEntry = Object.entries(entries).find(([p]) => p.toLowerCase().endsWith('slic3r_pe_model.config'));
    if (!cfgEntry) return entries;
    const cfgXml = strFromU8(cfgEntry[1]);
    const objects = new Map();
    for (const ob of blocksOf(cfgXml, 'object', { accept: (a) => /^ id="\d+"/.test(a) })) {
      const oid = parseInt(/^ id="(\d+)"/.exec(ob.attrs)[1], 10);
      const body = ob.body;
      const objExtruder = parseInt((body.match(/key="extruder" value="(\d+)"/) || [])[1] || '1', 10);
      const vols = [];
      for (const vb of blocksOf(body, 'volume', { accept: (a) => /^ firstid="\d+" lastid="\d+"/.test(a) })) {
        const vm = /^ firstid="(\d+)" lastid="(\d+)"/.exec(vb.attrs);
        vols.push({ first: parseInt(vm[1], 10), last: parseInt(vm[2], 10), extruder: parseInt((vb.body.match(/key="extruder" value="(\d+)"/) || [])[1] || String(objExtruder), 10) });
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
      const src = strFromU8(data);
      const paintBlock = (block, oidStr) => {
        const info = objects.get(parseInt(oidStr, 10)) || onlyObj;
        if (!info || !info.vols.length) return block;
        const extOf = (t) => { for (const v of info.vols) if (t >= v.first && t <= v.last) return v.extruder; return info.objExtruder; };
        let t = -1;
        // Linear on purpose: `([^>]*?)\s*\/>` let both halves match whitespace, so a run of
        // spaces with no "/>" backtracked quadratically — bedready.io measured a 903-byte file
        // holding the thread for 15 s (its #38, 2026-10-02 security review). One greedy group
        // that cannot overlap anything after it, and the trailing spaces trimmed afterwards.
        // The match ends at the first ">" whatever precedes it: requiring "/>" there made every
        // `<triangle ` in a run with no "/>" scan to the end of the block, quadratic again
        // (1.4 KB, 12 s). A tag that is not self-closing is left as it is.
        return block.replace(/<triangle\b([^>]*)>/g, (tri, rawAttrs) => {
          if (!rawAttrs.endsWith('/')) return tri;
          const attrs = rawAttrs.slice(0, -1).trimEnd();
          t++;
          if (/paint_color=|mmu_segmentation=/.test(attrs)) return tri;
          changed = true;
          return `<triangle${attrs} paint_color="${encodeSolidPaint(extOf(t))}"/>`;
        });
      };
      let xml = '';
      let last = 0;
      for (const ob of blocksOf(src, 'object', { accept: (a) => /^ id="\d+"/.test(a) })) {
        xml += src.slice(last, ob.start) + paintBlock(src.slice(ob.start, ob.end), /^ id="(\d+)"/.exec(ob.attrs)[1]);
        last = ob.end;
      }
      xml += src.slice(last);
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
  // Component-graph nodes one extraction may visit, across every root and instance. See `walk`.
  // Real projects visit thousands; the emit pass legitimately visits every leaf instance, which
  // is itself capped at two million below, so this sits above that with room for the assemblies.
  const MAX_WALK_VISITS = 4_000_000;
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

  // ── Linear tag scanning (beta.40 security review, Nov 17) ──
  // `/<object\b[^>]*>([\s\S]*?)<\/object>/g` and its kin rescanned to the end of the text
  // from every opener with no ">" or no close, so a member of `<object id="1">` × n was
  // quadratic: 200 KB took 0.3–2 s per pattern, 10 MB about 13 minutes. These find the same
  // matches with indexOf: a tag's attributes run to its first ">", a block's body to the first
  // close after it, and the scan resumes after the match. A tag the caller does not want is
  // passed over to its ">" (a regex would also try an opener INSIDE its attributes, which is
  // not XML). `ci` matches the tag name in any ASCII case, compared in place: a lowercased
  // COPY is not the same length when it holds 'İ' (two characters lowercased), so its
  // indexes are not the text's, and on a huge member it is a second copy of it (re-review).
  const isNameChar = (c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
  function scanTags(s, name, opts) {
    const o = opts || {};
    const open = '<' + name;
    const close = '</' + name + '>';
    const lname = name.toLowerCase();
    // Where the next "<name" starts at or after i, case-folded in ASCII only when ci.
    const findOpen = (from) => {
      if (!o.ci) return s.indexOf(open, from);
      for (let k = s.indexOf('<', from); k >= 0; k = s.indexOf('<', k + 1)) {
        let ok = true;
        for (let c = 0; c < lname.length && ok; c++) {
          let ch = s.charCodeAt(k + 1 + c);
          if (ch >= 65 && ch <= 90) ch += 32;
          ok = ch === lname.charCodeAt(c);
        }
        if (ok) return k;
      }
      return -1;
    };
    const out = [];
    let i = 0;
    for (;;) {
      i = findOpen(i);
      if (i < 0) break;
      if (isNameChar(s.charCodeAt(i + open.length))) { i += open.length; continue; }
      const gt = s.indexOf('>', i + open.length);
      if (gt < 0) break;
      let attrs = s.slice(i + open.length, gt);
      if (o.selfClosing && attrs.endsWith('/')) attrs = attrs.slice(0, -1);
      if (o.accept && !o.accept(attrs)) { i = gt + 1; continue; }
      if (!o.block) { out.push({ attrs, start: i, end: gt + 1 }); i = gt + 1; if (o.first) break; continue; }
      const ce = s.indexOf(close, gt + 1);
      if (ce < 0) break; // no close after here, so none after any later opener either
      out.push({ attrs, body: s.slice(gt + 1, ce), start: i, end: ce + close.length });
      i = ce + close.length;
      if (o.first) break;
    }
    return out;
  }
  const tagsOf = (s, name, opts) => scanTags(s, name, Object.assign({ selfClosing: true }, opts));
  const blocksOf = (s, name, opts) => scanTags(s, name, Object.assign({ block: true }, opts));
  const firstBlock = (s, name, opts) => blocksOf(s, name, Object.assign({ first: true }, opts))[0] || null;
  // `<triangle` followed by a space, "/" or ">", counted without building a match array
  // (TRI_RE's rule; a painted mesh can hold millions).
  function countTris(mesh) {
    let n = 0;
    for (let i = mesh.indexOf('<triangle'); i >= 0; i = mesh.indexOf('<triangle', i + 9)) {
      const c = mesh.charCodeAt(i + 9);
      if (c === 32 || c === 47 || c === 62) n++;
    }
    return n;
  }
  const exactAttrs = (s) => s === '';

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
        // Line by line: `^;?\s*key\s*=\s*(.+)$` with /m re-ran its `\s*` over every blank line
        // from every line start, quadratic on whitespace (200 KB of it: 19 s).
        const grab = (key) => {
          for (const raw of text.split('\n')) {
            let l = raw.replace(/\r$/, '');
            if (l.startsWith(';')) l = l.slice(1);
            l = l.replace(/^\s+/, '');
            if (!l.startsWith(key)) continue;
            const rest = l.slice(key.length).replace(/^\s+/, '');
            if (!rest.startsWith('=')) continue;
            const v = rest.slice(1).replace(/^\s+/, '');
            if (!v) continue;
            return v.trim().split(/[;,]/).map((x) => normalizeHex(x.trim())).filter(Boolean);
          }
          return [];
        };
        const fc = grab('filament_colour'), ec = grab('extruder_colour');
        const distinct = (a) => new Set(a).size;
        prusaPalette = distinct(fc) >= 2 ? fc : distinct(ec) >= 2 ? ec : fc.length ? fc : ec;
      } else if (base === 'model_settings.config') {
        const xml = strFromU8(data);
        const first = xml.match(/key="extruder" value="(\d+)"/);
        if (first) baseState = parseInt(first[1], 10);
        for (const ob of blocksOf(xml, 'object')) {
          const body = ob.body;
          const ex = parseInt((body.match(/key="extruder" value="(\d+)"/) || [])[1] || '0', 10);
          const fc = parseInt((body.match(/face_count="(\d+)"/) || [])[1] || '0', 10);
          const nm = (body.match(/key="name" value="([^"]*)"/) || [])[1];
          if (fc > 0) { if (ex > 0) faceCountToExtr.set(fc, ex); if (nm) faceCountToName.set(fc, nm); }
          for (const pb of blocksOf(body, 'part')) {
            const pid = parseInt(attr(pb.attrs, 'id') || '-1', 10);
            if (pid < 0) continue;
            const pe = parseInt((pb.body.match(/key="extruder" value="(\d+)"/) || [])[1] || '0', 10);
            idToExtr.set(pid, pe > 0 ? pe : ex > 0 ? ex : baseState);
          }
        }
        for (const pb of blocksOf(xml, 'plate', { accept: exactAttrs })) {
          const body = pb.body;
          const name = (body.match(/key="plater_name" value="([^"]*)"/) || [])[1] || '';
          const objectIds = [...body.matchAll(/key="object_id" value="(\d+)"/g)].map((m) => parseInt(m[1], 10));
          if (objectIds.length) plateDefs.push({ name, objectIds });
        }
      } else if (lower.endsWith('.model')) {
        const xml = strFromU8(data);
        const objs = new Map();
        for (const ob of blocksOf(xml, 'object')) {
          const id = parseInt(attr(ob.attrs, 'id') || '-1', 10);
          if (id < 0) continue;
          const body = ob.body;
          const meshB = firstBlock(body, 'mesh', { accept: exactAttrs });
          if (meshB) { objs.set(id, { mesh: meshB.body }); }
          else {
            const comps = [];
            for (const ct of tagsOf(body, 'component')) {
              const oid = parseInt(attr(ct.attrs, 'objectid') || '-1', 10);
              if (oid < 0) continue;
              const cp = attr(ct.attrs, 'path'), tStr = attr(ct.attrs, 'transform');
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
          const unitTag = scanTags(xml, 'model', { ci: true, first: true, accept: (a) => /\bunit=["']?[A-Za-z]/i.test(a) })[0];
          mmPerUnit = unitScale(unitTag ? (/\bunit=["']?([A-Za-z]+)/i.exec(unitTag.attrs) || [])[1] : undefined);
          for (const it of tagsOf(xml, 'item')) {
            const oid = parseInt(attr(it.attrs, 'objectid') || '-1', 10);
            if (oid < 0) continue;
            const tStr = attr(it.attrs, 'transform');
            buildItems.push({ objectid: oid, transform: transform12to16(tStr ? tStr.trim().split(/\s+/).map(Number) : []) });
          }
        }
      }
    }

    const triCountOf = (node) => { if (node.triCount == null) node.triCount = node.mesh ? countTris(node.mesh) : 0; return node.triCount; };
    // `seen` tracks the CURRENT DESCENT PATH, not every node visited: a component may
    // legitimately appear twice as siblings, but must never appear inside its own ancestry.
    // subtree() above already breaks cycles with a memo sentinel, so on a cyclic graph the
    // counter stayed small while this emitter kept descending to the depth cap — writing far
    // more faces than the typed arrays were sized for (silently discarded) and advertising
    // `parts` ranges many times larger than the buffers, which any consumer slicing by
    // part.start/end would read past.
    //
    // A TOTAL visit budget as well as the depth cap. The depth cap stops cycles but not fan-out:
    // objects that each reference the next one twice double the work per level, and subtree()'s
    // instance cap only counts LEAVES — so a branch that doubles for thirty levels and ends in
    // nothing, beside one real mesh, passed every check and walked 2^30 empty nodes (24 levels
    // took six seconds here; bedready.io's #38 has 22 levels in 513 bytes at 41 s). Over the
    // budget, the walk stops and the extraction reports `skipped`, like any other too-large model.
    let visits = 0, overBudget = false;
    const walk = (path, oid, M, depth, onLeaf, seen) => {
      if (depth > 64 || overBudget) return;
      if (++visits > MAX_WALK_VISITS) { overBudget = true; return; }
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
    const emptyMesh = (skipped) => ({ positions: new Float32Array(0), faceState: new Uint8Array(0), palette, usage: palette.map(() => 0), statesPresent: [], baseState, triangleCount, skipped, sampled: false, parts: [], plates: [], mmPerUnit, slotsUsed: skipped ? null : [] });
    if (triangleCount === 0) return emptyMesh(false);
    // Bail on a huge triangle budget OR a huge instance count — the latter bounds the
    // emit walk() below (which visits every leaf instance) against exponential blow-up.
    if (triangleCount > hardCap || totalInstances > 2_000_000) return emptyMesh(true);

    const stride = triangleCount > maxFaces ? Math.ceil(triangleCount / maxFaces) : 1;
    const cap = stride === 1 ? triangleCount : Math.ceil(triangleCount / stride);
    const positions = new Float32Array(cap * 9);
    const faceState = new Uint8Array(cap);
    let vc = 0, fc = 0, gtri = 0;

    // The filament slots (1-based) each root really uses, over EVERY triangle — the preview below
    // keeps one face in `stride`, but a colour that covers few faces is still a colour the print
    // needs. A painted face's state 0 is its own part's filament (`baseExtr`), not slot 1.
    const rootSlots = roots.map(() => new Set());
    const leafCache = new Map();
    const emit = (seg, M, baseExtr, ri) => {
      const slots = rootSlots[ri];
      const base = baseExtr > 0 ? baseExtr : 1;
      const nv = (seg.match(/<vertex\b/g) || []).length;
      const vx = new Float32Array(nv * 3);
      let i = 0;
      // Tolerant forms, matching mf-convert.js:309 which reads the SAME data: self-closing
      // or paired tags, single or double quotes, attributes on following lines. The two
      // readers disagreeing meant a legal 3MF converted wrongly with no warning.
      for (const vt of tagsOf(seg, 'vertex')) {
        const tag = vt.attrs;
        const x = +((tag.match(/\bx=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/) || [])[1] || 0),
              y = +((tag.match(/\by=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/) || [])[1] || 0),
              z = +((tag.match(/\bz=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/) || [])[1] || 0);
        // x mmPerUnit last: the scale is uniform, so scaling world space is the same as folding
        // it into M, and it correctly scales the translation terms (an offset is in the same unit).
        vx[i++] = (x * M[0] + y * M[4] + z * M[8] + M[12]) * mmPerUnit;
        vx[i++] = (x * M[1] + y * M[5] + z * M[9] + M[13]) * mmPerUnit;
        vx[i++] = (x * M[2] + y * M[6] + z * M[10] + M[14]) * mmPerUnit;
      }
      for (const tt of tagsOf(seg, 'triangle')) {
        const m = [null, tt.attrs];
        const pcAll = /(?:paint_color|mmu_segmentation)=/.test(m[1]) ? m[1].match(/(?:paint_color|mmu_segmentation)=["']?([0-9A-Fa-f]+)/) : null;
        if (pcAll) {
          let ls = leafCache.get(pcAll[1]);
          if (!ls) { ls = leafStates(pcAll[1]); if (leafCache.size < 4096) leafCache.set(pcAll[1], ls); }
          for (const st of ls) slots.add(st > 0 ? st : base);
        } else slots.add(base);
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
      partRanges.push({ name: rootName[ri], objectId: r.objectid, start: fc, ri });
      walk(r.path, r.objectid, r.transform, 0, (node, M, leafOid) => emit(node.mesh, M, idToExtr.get(leafOid) != null ? idToExtr.get(leafOid) : rootBase[ri], ri));
    });
    if (overBudget) return emptyMesh(true);
    const parts = partRanges.map((pr, i) => {
      const end = i + 1 < partRanges.length ? partRanges[i + 1].start : fc;
      return { name: pr.name, objectId: pr.objectId, start: pr.start, end, triangleCount: end - pr.start,
        slots: [...rootSlots[pr.ri]].sort((a, b) => a - b) };
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
      slotsUsed: [...new Set(rootSlots.flatMap((x) => [...x]))].sort((a, b) => a - b),
    };
  }

  // ---------- the used slots, one member at a time ----------
  //
  // `extractMeshFromMembers` needs every `.model` member in memory together, and a host with a
  // memory budget (the Mac binds each as a string; a painted project can hold 1.5 GB of XML)
  // refuses the largest files. Which filament slots a print uses does not need the geometry: it
  // needs, per mesh object, how many triangles it has, which paint states appear on them and
  // whether any face is left to its part's own filament; and per file, which objects are built
  // from which. `digestModelMember` takes ONE member and keeps those few numbers;
  // `slotsUsedFromDigests` resolves them the way the extractor does. The answer must be the
  // extractor's `slotsUsed` for every file (test/mf-mesh-digests.test.js).
  //
  // Not for a PrusaSlicer multi-volume project (a `Slic3r_PE_model.config` member), whose paint
  // is synthesized across members first (`applyPrusaVolumePaint`): the caller keeps to the
  // extractor for those.
  function digestModelMember(path, data) {
    const xml = strFromU8(data);
    const objects = [];
    for (const ob of blocksOf(xml, 'object')) {
      const id = parseInt(attr(ob.attrs, 'id') || '-1', 10);
      if (id < 0) continue;
      const body = ob.body;
      const meshB = firstBlock(body, 'mesh', { accept: exactAttrs });
      if (meshB) {
        const mesh = meshB.body;
        const states = new Set();
        let usesBase = false;
        const leafCache = new Map();
        for (const tt of tagsOf(mesh, 'triangle')) {
          const pc = /(?:paint_color|mmu_segmentation)=/.test(tt.attrs) ? tt.attrs.match(/(?:paint_color|mmu_segmentation)=["']?([0-9A-Fa-f]+)/) : null;
          if (!pc) { usesBase = true; continue; }
          let ls = leafCache.get(pc[1]);
          if (!ls) { ls = leafStates(pc[1]); if (leafCache.size < 4096) leafCache.set(pc[1], ls); }
          for (const st of ls) { if (st > 0) states.add(st); else usesBase = true; }
        }
        objects.push({ id, tris: countTris(mesh), states: [...states].sort((a, b) => a - b), usesBase });
      } else {
        const comps = [];
        for (const ct of tagsOf(body, 'component')) {
          const oid = parseInt(attr(ct.attrs, 'objectid') || '-1', 10);
          if (oid < 0) continue;
          const cp = attr(ct.attrs, 'path');
          comps.push({ path: cp ? stripSlash(cp) : stripSlash(path), objectid: oid });
        }
        objects.push({ id, comps });
      }
    }
    let build = null;
    if (/<build[\s>]/.test(xml)) {
      build = [];
      for (const it of tagsOf(xml, 'item')) {
        const oid = parseInt(attr(it.attrs, 'objectid') || '-1', 10);
        if (oid >= 0) build.push(oid);
      }
    }
    return { path: stripSlash(path), objects, build };
  }

  // digests: one `digestModelMember` per `.model` member, IN THE ZIP'S ORDER (the last member
  // carrying a <build> is the build, as in the extractor). modelSettings: the text of
  // `model_settings.config`, or ''. Returns the sorted slots, [] for a file with no triangles,
  // or null where the extractor would report `skipped`.
  function slotsUsedFromDigests(digests, modelSettings, hardCap) {
    hardCap = hardCap || HARD_CAP;
    let baseState = 1;
    const faceCountToExtr = new Map(), idToExtr = new Map();
    const xml = String(modelSettings || '');
    if (xml) {
      const first = xml.match(/key="extruder" value="(\d+)"/);
      if (first) baseState = parseInt(first[1], 10);
      for (const ob of blocksOf(xml, 'object')) {
        const body = ob.body;
        const ex = parseInt((body.match(/key="extruder" value="(\d+)"/) || [])[1] || '0', 10);
        const fc = parseInt((body.match(/face_count="(\d+)"/) || [])[1] || '0', 10);
        if (fc > 0 && ex > 0) faceCountToExtr.set(fc, ex);
        for (const pb of blocksOf(body, 'part')) {
          const pid = parseInt(attr(pb.attrs, 'id') || '-1', 10);
          if (pid < 0) continue;
          const pe = parseInt((pb.body.match(/key="extruder" value="(\d+)"/) || [])[1] || '0', 10);
          idToExtr.set(pid, pe > 0 ? pe : ex > 0 ? ex : baseState);
        }
      }
    }
    const files = new Map();
    let buildPath = '', buildItems = [];
    for (const d of digests || []) {
      if (!d || !Array.isArray(d.objects)) continue;
      const objs = new Map();
      for (const o of d.objects) objs.set(o.id, o);
      files.set(d.path, objs);
      // Each member with a <build> ADDS its items and names the build path, as the extractor does.
      if (Array.isArray(d.build)) { buildPath = d.path; buildItems = buildItems.concat(d.build); }
    }
    const isMesh = (node) => !Array.isArray(node.comps);
    let roots = buildItems.map((oid) => ({ path: buildPath, objectid: oid }));
    if (roots.length === 0) for (const [path, objs] of files) for (const [id, node] of objs) if (isMesh(node)) roots.push({ path, objectid: id });

    const subMemo = new Map();
    const subtree = (path, oid, depth) => {
      if (depth > 64) return { tris: 0, insts: 0 };
      const key = path + '\u0000' + oid;
      const hit = subMemo.get(key);
      if (hit) return hit;
      subMemo.set(key, { tris: 0, insts: 0 });
      const node = (files.get(path) || new Map()).get(oid);
      if (!node) return { tris: 0, insts: 0 };
      let r;
      if (isMesh(node)) r = { tris: node.tris || 0, insts: 1 };
      else {
        let tris = 0, insts = 0;
        for (const c of node.comps) { const s = subtree(c.path, c.objectid, depth + 1); tris += s.tris; insts += s.insts; }
        r = { tris, insts };
      }
      subMemo.set(key, r);
      return r;
    };
    let triangleCount = 0, totalInstances = 0; const rootBase = [];
    for (const r of roots) {
      const s = subtree(r.path, r.objectid, 0);
      triangleCount += s.tris; totalInstances += s.insts;
      rootBase.push(faceCountToExtr.get(s.tris) != null ? faceCountToExtr.get(s.tris) : baseState);
    }
    if (triangleCount === 0) return [];
    if (triangleCount > hardCap || totalInstances > 2_000_000) return null;

    const out = new Set();
    let visits = 0, overBudget = false;
    const walk = (path, oid, depth, base, seen) => {
      if (depth > 64 || overBudget) return;
      if (++visits > MAX_WALK_VISITS) { overBudget = true; return; }
      const key = path + '\u0000' + oid;
      if (seen && seen.has(key)) return;
      const node = (files.get(path) || new Map()).get(oid);
      if (!node) return;
      if (isMesh(node)) {
        const own = idToExtr.get(oid) != null ? idToExtr.get(oid) : base;
        for (const st of node.states || []) out.add(st);
        if (node.usesBase) out.add(own > 0 ? own : 1);
        return;
      }
      const next = new Set(seen || []);
      next.add(key);
      for (const c of node.comps) walk(c.path, c.objectid, depth + 1, base, next);
    };
    roots.forEach((r, ri) => walk(r.path, r.objectid, 0, rootBase[ri], null));
    if (overBudget) return null;
    return [...out].sort((a, b) => a - b);
  }

  // Convenience: extract straight from a 3MF Buffer.
  function extractMeshFromBuffer(buf, maxFaces, hardCap) {
    let zip; try { zip = zipRead.openZip(buf); } catch (_) { zip = null; }
    const members = [];
    if (zip && zip.entries) for (const e of zip.entries) { const d = zip.file(e.name); if (d) members.push({ name: e.name, data: d }); }
    return extractMeshFromMembers(members, maxFaces, hardCap);
  }

  const api = { extractMeshFromMembers, extractMeshFromBuffer, digestModelMember, slotsUsedFromDigests, dominantState, leafStates, hexToBits, bitsToHex, encodeSolidPaint, normalizeHex, paletteFromFullSpectrum, recipesFromFullSpectrum, fullSpectrumFromMembers, unitScale, PREVIEW_BUDGET, HARD_CAP, MAX_WALK_VISITS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytMfMesh = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
