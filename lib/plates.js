'use strict';
/**
 * One plate out of a multi-plate 3MF project, as a 3MF of its own.
 *
 * Ported from bedready.io (src/lib/plates.ts: peekPlates / extractPlate), and
 * stricter than the port's source in the places its history shows it learning
 * the hard way. Every fix there was the same rule found in a new file: an
 * extracted package must not reference a part it does not contain — not in a
 * relationship (`_rels/.rels` still naming dropped thumbnails), not in
 * model_settings (plate 6's `thumbnail_file`, an `<assemble>` listing all
 * eighteen objects — the one that made Orca say "the file does not contain any
 * geometry data"), not in the root model's own `Thumbnail_*` metadata. So here
 * the rule is checked once over the finished package (`checkPackage`) and a
 * file that fails it is refused, not shipped.
 *
 * WHAT IS A PLATE (Bambu Studio / Orca, the only slicers that write them):
 *
 *   Metadata/model_settings.config   <plate> blocks, each listing
 *                                    <model_instance> object_id = a ROOT object id
 *   3D/3dmodel.model                 root <object id=N> → <component p:path="/3D/Objects/object_M.model">
 *                                    plus <build><item objectid=N transform=…>
 *   3D/Objects/object_M.model        the geometry, usually one file per object, holding its parts
 *
 * The plate's object_id is the ROOT id, not the object_M.model number; conflating
 * the two silently mismaps plates (bedready.io's first pass measured half of an
 * 18-plate file at 0 MB that way). PrusaSlicer has no plates, so there is no
 * Prusa dialect to port — a Prusa project is one plate and is refused as such.
 *
 * WHAT IT COSTS: no geometry is inflated to list or to split. Part files are
 * copied across still compressed (zip-write's `raw` passthrough), so a 240 MB
 * plate out of a 1 GB poster costs a memcpy. What IS inflated is the root model,
 * the small config members, and — only for listing colours, and only under
 * PEEK_MESH_BYTES of declared geometry — the mesh, through the same reader and
 * the same caps (mf-mesh HARD_CAP / MAX_WALK_VISITS) the preview uses.
 *
 * RE-SEATING: a slicer lays plates out on one world grid, so plate 6 lifted out
 * as-is lands 300 mm off a single bed (bedready.io: "Y -287.5..-68.4 against a
 * printable Y of 1..271 — entirely behind the bed"). bedready.io re-centres by
 * scanning vertices. This subtracts the plate's own grid origin instead —
 * Bambu/Orca's PartPlateList::compute_origin, cols = ceil(sqrt(plates)), stride
 * = bed × 1.2 — which keeps every object exactly where the author placed it on
 * that plate and needs no geometry. When the arithmetic does not put the plate's
 * items on the bed it falls back to centring their translations, and says so.
 *
 * Pure string/JSON work over members; the zip ends are thin Node wrappers, the
 * same split as mf-convert's convertMembers, so a host with its own zip could
 * ask the same question.
 */
(function (global) {
  const req = (typeof require === 'function') ? require : null;
  const zipRead = req ? req('./zip-read') : global.KhaytZip;
  const zipWrite = req ? req('./zip-write') : global.KhaytZipWrite;
  let mfMesh = null;
  try { mfMesh = req ? req('./mf-mesh') : global.KhaytMfMesh; } catch (_) { mfMesh = null; }

  // Bambu/Orca LOGICAL_PART_PLATE_GAP: plates sit one fifth of a bed apart.
  const PLATE_GAP = 1 / 5;
  // Colours per plate come from the mesh only while the whole file's geometry is
  // at most this — above it the listing reads object/part filaments instead and
  // says the answer is approximate. The listing must stay cheap on the 1 GB files
  // it exists for.
  const PEEK_MESH_BYTES = 64 * 1024 * 1024;
  // Text members this module will inflate and rewrite. The root model of a
  // production-extension project is kilobytes; one with its meshes inline is not,
  // and past this it is refused rather than turned into a string V8 cannot hold.
  const TEXT_MAX = 256 * 1024 * 1024;
  const TEXT_BUDGET = 512 * 1024 * 1024;
  const THUMB_MAX = 2 * 1024 * 1024;

  const MODEL_SETTINGS = /^Metadata\/model_settings\.config$/i;
  const PROJECT_SETTINGS = /^Metadata\/project_settings\.config$/i;
  const SLICE_INFO = /^Metadata\/slice_info\.config$/i;
  const CUSTOM_GCODE = /^Metadata\/custom_gcode_per_layer\.xml$/i;
  const FILAMENT_SEQUENCE = /^Metadata\/filament_sequence\.json$/i;
  const CONTENT_TYPES = /^\[Content_Types\]\.xml$/i;
  // Members that name objects by their POSITION in the project (1-based, model
  // order) rather than by id — PrusaSlicer and Bambu both write these with a
  // running counter. Dropping objects shifts every later position, so these are
  // renumbered, never copied as they are.
  const POSITIONAL_LINES = /^Metadata\/(layer_heights_profile|brim_ear_points|Slic3r_PE_sla_support_points|Slic3r_PE_sla_drain_holes)\.txt$/i;
  const POSITIONAL_XML = /^Metadata\/(layer_config_ranges|cut_information|Prusa_Slicer_cut_information)\.xml$/i;
  // One plate's own files: plate_3.png, plate_3_small.png, plate_no_light_3.png,
  // top_3.png, pick_3.png, plate_3.json, plate_3.gcode(.md5).
  const PER_PLATE = /^Metadata\/(plate_no_light|plate|top|pick)_(\d+)((?:_small)?\.(?:png|json|gcode(?:\.md5)?))$/i;

  class PlateError extends Error {
    constructor(code, message) { super(message); this.code = code; }
  }
  const refuse = (code, message) => { throw new PlateError(code, message); };

  const norm = (p) => String(p || '').replace(/\\/g, '/').replace(/^\.?\/+/, '');
  const attr = (s, name) => (new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`).exec(s) || new RegExp(`\\b${name}\\s*=\\s*'([^']*)'`).exec(s) || [])[1];
  const meta = (block, key) => (new RegExp(`<metadata\\b[^>]*\\bkey="${key}"[^>]*\\bvalue="([^"]*)"`).exec(block) || [])[1];
  const toBuf = (d) => (Buffer.isBuffer(d) ? d : Buffer.from(d.buffer, d.byteOffset, d.byteLength));
  const toText = (d) => (d == null ? null : (typeof d === 'string' ? d : toBuf(d).toString('utf8')));
  const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  // ── reading ──────────────────────────────────────────────────────────────

  /**
   * Members of a 3MF without inflating any of them.
   *
   * Every `data` is a getter. Unlike mf-convert's readMembers there is no
   * cumulative budget that drops members, because nothing here reads a mesh it
   * is not asked to — the plates this exists for are the ones in files too big
   * to read whole. What IS read goes through `text()`, which holds its own
   * budget (see TEXT_MAX / TEXT_BUDGET), and zip-read caps every inflate.
   */
  function readMembers(buf) {
    let zip;
    try { zip = zipRead.openZip(buf); } catch (_) { return []; }
    if (!zip || !Array.isArray(zip.entries)) return [];
    return zip.entries.filter((e) => e && e.name && !e.name.endsWith('/')).map((e) => {
      const m = { name: e.name, size: e.size || 0, src: zip.rawOf(e) };
      let cached;
      Object.defineProperty(m, 'data', {
        enumerable: true, configurable: true,
        get() { if (cached === undefined) cached = zip.entryData(e) || null; return cached; },
      });
      return m;
    });
  }

  /** A bounded reader over members: names, lazy text, sizes. */
  function index(members) {
    const byName = new Map();
    for (const m of members || []) if (m && m.name) byName.set(norm(m.name), m);
    let spent = 0;
    const find = (re) => { for (const [n, m] of byName) if (re.test(n)) return m; return null; };
    const text = (m) => {
      if (!m) return null;
      const declared = Number.isFinite(m.size) && m.size > 0 ? m.size : 0;
      if (declared > TEXT_MAX) refuse('too-large', `${m.name} is too large to rewrite (${Math.round(declared / 1048576)} MB).`);
      const d = m.data;
      if (d == null) return null;
      if (d.length > TEXT_MAX) refuse('too-large', `${m.name} is too large to rewrite.`);
      spent += d.length;
      if (spent > TEXT_BUDGET) refuse('too-large', 'This project\'s settings are too large to split.');
      return toText(d);
    };
    return { byName, find, text, has: (n) => byName.has(norm(n)), get: (n) => byName.get(norm(n)) || null };
  }

  /** The root model's name: the StartPart in _rels/.rels, else 3D/3dmodel.model. */
  function rootName(ix) {
    const rels = ix.text(ix.get('_rels/.rels'));
    if (rels) {
      for (const m of rels.matchAll(/<Relationship\b[^>]*>/g)) {
        const type = attr(m[0], 'Type') || '';
        const target = attr(m[0], 'Target');
        if (target && /\/3dmodel$/i.test(type) && ix.has(target)) return norm(target);
      }
    }
    return ix.has('3D/3dmodel.model') ? '3D/3dmodel.model' : null;
  }

  // ── parsing ──────────────────────────────────────────────────────────────

  function parseRoot(xml) {
    const objects = new Map();
    for (const m of xml.matchAll(/<object\b([^>]*?)(?:\/>|>([\s\S]*?)<\/object>)/g)) {
      const id = attr(m[1], 'id');
      if (id == null) continue;
      const body = m[2] || '';
      const components = [];
      for (const c of body.matchAll(/<component\b([^>]*?)\/?>/g)) {
        components.push({ objectid: attr(c[1], 'objectid'), path: attr(c[1], 'p:path') || attr(c[1], 'path') || null });
      }
      objects.set(id, { id, start: m.index, end: m.index + m[0].length, components, hasMesh: /<mesh\b/.test(body) });
    }
    const buildM = /<build\b[^>]*>([\s\S]*?)<\/build>/.exec(xml);
    const items = [];
    if (buildM) {
      const at = buildM.index + buildM[0].indexOf(buildM[1]);
      for (const m of buildM[1].matchAll(/<item\b([^>]*?)(?:\/>|>[\s\S]*?<\/item>)/g)) {
        items.push({
          tag: m[0], start: at + m.index, end: at + m.index + m[0].length,
          objectid: attr(m[1], 'objectid'), path: attr(m[1], 'p:path') || attr(m[1], 'path') || null,
          transform: attr(m[1], 'transform') || null,
        });
      }
    }
    return { objects, items, hasBuild: !!buildM };
  }

  function parseSettings(xml) {
    const plates = [];
    for (const m of xml.matchAll(/<plate\b[^>]*>[\s\S]*?<\/plate>/g)) {
      const block = m[0];
      const instances = [];
      for (const mi of block.matchAll(/<model_instance\b[^>]*>([\s\S]*?)<\/model_instance>/g)) {
        const oid = meta(mi[1], 'object_id');
        if (oid != null) instances.push({ objectId: oid, instanceId: meta(mi[1], 'instance_id') });
      }
      const pid = parseInt(meta(block, 'plater_id'), 10);
      plates.push({
        block, start: m.index, end: m.index + block.length,
        platerId: Number.isFinite(pid) ? pid : plates.length + 1,
        name: meta(block, 'plater_name') || '',
        instances,
      });
    }
    const objects = new Map();
    const order = [];
    for (const m of xml.matchAll(/<object\b([^>]*)>([\s\S]*?)<\/object>/g)) {
      const id = attr(m[1], 'id');
      if (id == null) continue;
      const body = m[2];
      const parts = [];
      for (const p of body.matchAll(/<part\b([^>]*)>([\s\S]*?)<\/part>/g)) {
        parts.push({ id: attr(p[1], 'id'), subtype: attr(p[1], 'subtype') || 'normal_part', extruder: parseInt(meta(p[2], 'extruder'), 10) || 0 });
      }
      // The object's own filament is the first `extruder` outside any <part>.
      const own = body.replace(/<part\b[\s\S]*?<\/part>/g, '');
      objects.set(id, { id, name: meta(own, 'name') || '', extruder: parseInt(meta(own, 'extruder'), 10) || 0, parts });
      order.push(id);
    }
    return { plates, objects, order };
  }

  function tryJson(s) { try { return JSON.parse(s); } catch (_) { return null; } }

  /** Bed from project_settings printable_area: bounding box of the polygon. */
  function bedOf(cfg) {
    const area = cfg && Array.isArray(cfg.printable_area) ? cfg.printable_area : null;
    if (!area) return null;
    const pts = area.map((p) => String(p).split('x').map(Number)).filter((p) => p.length === 2 && p.every(Number.isFinite));
    if (!pts.length) return null;
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const b = { minX: Math.min(...xs), maxX: Math.max(...xs), minY: Math.min(...ys), maxY: Math.max(...ys) };
    b.w = b.maxX - b.minX; b.d = b.maxY - b.minY;
    return b.w > 0 && b.d > 0 ? b : null;
  }

  // ── the plate model: what each plate holds, and whether it can stand alone ──

  /**
   * Everything both listing and splitting need, worked out once.
   * Throws PlateError for a file with no plate structure to speak of.
   */
  function analyse(members) {
    const ix = index(members);
    const root = rootName(ix);
    if (!root) refuse('not-3mf', 'This is not a readable 3MF project.');
    const msMember = ix.find(MODEL_SETTINGS);
    const msText = msMember ? ix.text(msMember) : null;
    if (!msText) refuse('no-plates', 'This 3MF has no plate layout (only Bambu Studio and Orca projects have plates).');
    const settings = parseSettings(msText);
    if (!settings.plates.length) refuse('no-plates', 'This 3MF has no plate layout (only Bambu Studio and Orca projects have plates).');
    const rootText = ix.text(ix.get(root));
    if (rootText == null) refuse('not-3mf', 'The project\'s model could not be read.');
    const model = parseRoot(rootText);

    // Which plate(s) each object sits on, and how many copies each plate lists.
    const platesOf = new Map();
    settings.plates.forEach((pl, i) => {
      for (const inst of pl.instances) {
        if (!platesOf.has(inst.objectId)) platesOf.set(inst.objectId, new Set());
        platesOf.get(inst.objectId).add(i);
      }
    });
    const itemsOf = new Map();
    for (const it of model.items) {
      if (it.objectid == null) continue;
      if (!itemsOf.has(it.objectid)) itemsOf.set(it.objectid, []);
      itemsOf.get(it.objectid).push(it);
    }

    // Part files and root objects reachable from a root object.
    const reach = (id) => {
      const objs = new Set(), files = new Set();
      const stack = [String(id)];
      let visits = 0;
      while (stack.length) {
        const cur = stack.pop();
        if (objs.has(cur)) continue;
        if (++visits > 100000) refuse('unsupported', 'The project\'s object graph is too deep to split.');
        const o = model.objects.get(cur);
        if (!o) continue;
        objs.add(cur);
        for (const c of o.components) {
          const p = c.path ? norm(c.path) : null;
          if (p && p.toLowerCase() !== root.toLowerCase()) files.add(p);
          else if (c.objectid != null) stack.push(String(c.objectid));
        }
      }
      return { objs, files };
    };

    const plates = settings.plates.map((pl, i) => {
      const objectIds = [...new Set(pl.instances.map((x) => x.objectId))];
      const problems = [];
      const objs = new Set(), files = new Set();
      let parts = 0;
      for (const id of objectIds) {
        const others = [...(platesOf.get(id) || [])].filter((k) => k !== i);
        if (others.length) problems.push(['shared-object', `Object ${id} has copies on more than one plate, so this plate cannot be split out without splitting the object.`]);
        if (!model.objects.has(id)) { problems.push(['missing-object', `Plate lists object ${id}, which the model does not define.`]); continue; }
        const items = itemsOf.get(id) || [];
        if (!items.length) problems.push(['missing-object', `Object ${id} is on the plate but not in the model's build list.`]);
        if (items.some((it) => it.path)) problems.push(['unsupported', 'A build item points into another model file; that layout is not supported.']);
        const listed = pl.instances.filter((x) => x.objectId === id).length;
        if (items.length && items.length !== listed) {
          problems.push(['instances-mismatch', `Object ${id} has ${items.length} cop${items.length === 1 ? 'y' : 'ies'} in the model but the plate lists ${listed}.`]);
        }
        const r = reach(id);
        r.objs.forEach((o) => objs.add(o));
        r.files.forEach((f) => files.add(f));
        const so = settings.objects.get(id);
        parts += so && so.parts.length ? so.parts.filter((p) => p.subtype === 'normal_part').length || so.parts.length : 1;
      }
      if (!objectIds.length) problems.push(['empty-plate', 'This plate has nothing on it.']);
      for (const f of files) if (!ix.has(f)) problems.push(['missing-part', `The model refers to ${f}, which is not in the file.`]);
      // Nested part relationships (3D/Objects/_rels/x.model.rels) bring their targets along.
      for (const f of [...files]) {
        const relName = f.replace(/([^/]+)$/, '_rels/$1.rels');
        const rt = ix.has(relName) ? ix.text(ix.get(relName)) : null;
        if (!rt) continue;
        for (const rm of rt.matchAll(/<Relationship\b[^>]*>/g)) {
          const t = attr(rm[0], 'Target');
          if (t && /\.model$/i.test(t)) { files.add(norm(t)); if (!ix.has(t)) problems.push(['missing-part', `The model refers to ${norm(t)}, which is not in the file.`]); }
        }
      }
      let bytes = 0;
      for (const f of files) { const m = ix.get(f); if (m) bytes += Number.isFinite(m.size) && m.size > 0 ? m.size : 0; }
      return {
        index: i + 1, platerId: pl.platerId, name: pl.name, objectIds, objectCount: objectIds.length,
        instanceCount: pl.instances.length, partCount: parts,
        keepObjects: objs, keepFiles: files, bytes, problems,
      };
    });
    return { ix, root, rootText, model, settings, msMember, msText, plates, itemsOf };
  }

  // ── listing ──────────────────────────────────────────────────────────────

  function thumbnailOf(ix, platerId) {
    for (const n of [`Metadata/plate_${platerId}_small.png`, `Metadata/plate_${platerId}.png`]) {
      const m = ix.get(n);
      if (!m) continue;
      if (Number.isFinite(m.size) && m.size > THUMB_MAX) continue;
      const d = m.data;
      if (!d || d.length > THUMB_MAX || d.length < 8) continue;
      // PNG signature, or it is not shown: this goes straight into an <img>.
      if (d[0] !== 0x89 || d[1] !== 0x50 || d[2] !== 0x4e || d[3] !== 0x47) continue;
      return 'data:image/png;base64,' + toBuf(d).toString('base64');
    }
    return null;
  }

  function normHex(s) {
    const m = /#?([0-9a-fA-F]{6})/.exec(String(s || ''));
    return m ? '#' + m[1].toUpperCase() : null;
  }

  /**
   * List the plates of a project.
   *
   * @returns {{ok:true, plates:Array<{index, platerId, name, objectCount, instanceCount, partCount,
   *   bytes, thumbnail, colors, colorIndices, colorsApprox, splittable, problem}>}
   *   | {ok:false, code, error}}
   */
  function peekPlatesMembers(members, opts) {
    const o = opts || {};
    let a;
    try { a = analyse(members); } catch (e) { return fail(e); }
    const { ix, settings } = a;
    const psText = (() => { try { return ix.text(ix.find(PROJECT_SETTINGS)); } catch (_) { return null; } })();
    const palette = ((tryJson(psText || '') || {}).filament_colour || []).map(normHex);

    // Sliced projects carry each plate's exact filaments in slice_info.
    const sliced = new Map();
    try {
      const si = ix.text(ix.find(SLICE_INFO));
      if (si) {
        for (const m of si.matchAll(/<plate\b[^>]*>[\s\S]*?<\/plate>/g)) {
          const idx = parseInt(meta(m[0], 'index'), 10);
          const ids = [...m[0].matchAll(/<filament\b([^>]*?)\/?>/g)].map((f) => parseInt(attr(f[1], 'id'), 10)).filter((n) => n >= 1);
          if (Number.isFinite(idx) && ids.length) sliced.set(idx, ids.map((n) => n - 1));
        }
      }
    } catch (_) { /* unsliced, or unreadable — fall through */ }

    // Painted colours need the mesh. Read only while it is cheap, through the
    // preview's own reader and caps.
    let mesh = null;
    if (o.colors !== false && mfMesh && mfMesh.extractMeshFromMembers) {
      let geometry = 0;
      for (const m of ix.byName.values()) if (/\.model$/i.test(m.name)) geometry += Number.isFinite(m.size) ? m.size : 0;
      if (geometry > 0 && geometry <= PEEK_MESH_BYTES) {
        try { mesh = mfMesh.extractMeshFromMembers(members); } catch (_) { mesh = null; }
        if (mesh && (!Array.isArray(mesh.parts) || !mesh.faceState || mesh.skipped)) mesh = null;
      }
    }

    const plates = a.plates.map((p) => {
      let idx = null, approx = false;
      if (sliced.has(p.platerId)) idx = sliced.get(p.platerId);
      else if (mesh) {
        const used = new Set();
        const pal = mesh.palette || [];
        const want = new Set(p.objectIds.map(String));
        for (const part of mesh.parts) {
          if (!want.has(String(part.objectId))) continue;
          for (let f = part.start; f < part.end && f < mesh.faceState.length; f++) {
            const st = mesh.faceState[f];
            used.add(st >= 1 ? Math.min(st - 1, Math.max(0, pal.length - 1)) : 0);
          }
        }
        idx = [...used];
        approx = !!mesh.sampled;
      } else {
        // Object and part filaments only: paint is in the mesh we chose not to read.
        const used = new Set();
        for (const id of p.objectIds) {
          const so = settings.objects.get(id);
          if (!so) continue;
          if (so.extruder) used.add(so.extruder - 1);
          for (const part of so.parts) if (part.extruder) used.add(part.extruder - 1);
        }
        idx = [...used];
        approx = true;
      }
      idx = idx.filter((k) => k >= 0).sort((x, y) => x - y);
      const problem = p.problems[0] || null;
      return {
        index: p.index, platerId: p.platerId, name: p.name || null,
        objectCount: p.objectCount, instanceCount: p.instanceCount, partCount: p.partCount, bytes: p.bytes,
        thumbnail: o.thumbnails === false ? null : thumbnailOf(ix, p.platerId),
        colorIndices: idx, colors: idx.map((k) => palette[k]).filter(Boolean), colorsApprox: approx,
        splittable: a.plates.length > 1 && !problem,
        problem: problem ? { code: problem[0], error: problem[1] } : null,
      };
    });
    return { ok: true, plates };
  }

  function fail(e) {
    if (e instanceof PlateError) return { ok: false, code: e.code, error: e.message };
    return { ok: false, code: 'error', error: String((e && e.message) || e) };
  }

  // ── splitting ────────────────────────────────────────────────────────────

  const parseT = (t) => {
    const n = String(t || '').trim().split(/\s+/).map(Number);
    return n.length === 12 && n.every(Number.isFinite) ? n : [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];
  };
  const fmt = (v) => String(Number(v.toFixed(6)));
  /** The same transform with only its X/Y translation moved; every other token as written. */
  function moveTransform(t, dx, dy) {
    const tok = String(t || '').trim().split(/\s+/);
    if (tok.length !== 12 || !tok.every((x) => Number.isFinite(Number(x)))) {
      const id = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];
      id[9] = dx; id[10] = dy;
      return id.map(fmt).join(' ');
    }
    tok[9] = fmt(Number(tok[9]) + dx);
    tok[10] = fmt(Number(tok[10]) + dy);
    return tok.join(' ');
  }

  /**
   * How far to move the plate's items so the plate sits on one bed.
   * Grid origin first (exact, keeps the author's placement); centring the
   * items' translations when the grid does not explain where they are.
   */
  function seatShift(a, plate, bed) {
    const items = [];
    for (const id of plate.objectIds) for (const it of a.itemsOf.get(id) || []) items.push(it);
    const ts = items.map((it) => parseT(it.transform));
    const n = a.plates.length;
    if (!bed) {
      if (plate.index === 1) return { dx: 0, dy: 0, seat: 'unchanged' };
      refuse('no-bed', 'The project does not say how big its bed is, so the plate cannot be placed on it.');
    }
    const onBed = (dx, dy) => ts.every((t) => {
      const x = t[9] + dx, y = t[10] + dy, mx = bed.w * 0.05, my = bed.d * 0.05;
      return x >= bed.minX - mx && x <= bed.maxX + mx && y >= bed.minY - my && y <= bed.maxY + my;
    });
    const cols = Math.max(1, Math.ceil(Math.sqrt(n) - 1e-9));
    const i = plate.index - 1;
    const gx = (i % cols) * bed.w * (1 + PLATE_GAP), gy = -Math.floor(i / cols) * bed.d * (1 + PLATE_GAP);
    if (onBed(-gx, -gy)) return { dx: -gx, dy: -gy, seat: gx || gy ? 'grid' : 'unchanged' };
    if (!ts.length) return { dx: 0, dy: 0, seat: 'unchanged' };
    const cx = ts.reduce((s, t) => s + t[9], 0) / ts.length, cy = ts.reduce((s, t) => s + t[10], 0) / ts.length;
    return { dx: (bed.minX + bed.maxX) / 2 - cx, dy: (bed.minY + bed.maxY) / 2 - cy, seat: 'centred' };
  }

  /**
   * Apply non-overlapping edits ({start, end, text}; text null = remove), back to
   * front so every offset still points where it did. A removal takes its own
   * indentation and line break with it, so the file still reads as written.
   */
  function applyEdits(s, edits) {
    let out = s;
    for (const e of edits.slice().sort((x, y) => y.start - x.start)) {
      if (e.text != null) { out = out.slice(0, e.start) + e.text + out.slice(e.end); continue; }
      let st = e.start;
      while (st > 0 && (out[st - 1] === ' ' || out[st - 1] === '\t')) st--;
      if (st > 0 && out[st - 1] === '\n') st--;
      if (st > 0 && out[st - 1] === '\r') st--;
      out = out.slice(0, st) + out.slice(e.end);
    }
    return out;
  }

  /**
   * Build the members of a standalone project holding one plate.
   *
   * @param {Array} members  from readMembers (or a host's own, with lazy `data` and `src`)
   * @param {number} plateIndex  1-based, in the order the project lists its plates
   * @returns {{ok:true, members:Array<{name, data?, raw?}>, plate:object, report:object} | {ok:false, code, error}}
   */
  function extractPlateMembers(members, plateIndex) {
    try {
      return extractCore(members, plateIndex);
    } catch (e) { return fail(e); }
  }

  function extractCore(members, plateIndex) {
    const a = analyse(members);
    const { ix, root, settings } = a;
    if (a.plates.length < 2) refuse('single-plate', 'This project has only one plate — convert the whole file instead.');
    const plate = a.plates.find((p) => p.index === Number(plateIndex));
    if (!plate) refuse('no-such-plate', `There is no plate ${plateIndex} in this project.`);
    if (plate.problems.length) refuse(plate.problems[0][0], plate.problems[0][1]);
    const k = plate.platerId;
    const keepRoots = new Set(plate.objectIds);

    const ps = ix.find(PROJECT_SETTINGS);
    const bed = bedOf(tryJson(ps ? ix.text(ps) || '' : ''));
    const shift = seatShift(a, plate, bed);

    const out = new Map(); // name -> { name, data } | { name, raw, from }
    const keepAs = (m, name) => out.set(name || norm(m.name), { name: name || m.name, from: m });
    const write = (name, data) => out.set(norm(name), { name, data });

    // Per-plate files: this plate's renamed to plate 1, everyone else's dropped.
    const renamed = new Map(); // old normalised name -> new name
    for (const n of ix.byName.keys()) {
      const pm = PER_PLATE.exec(n);
      if (!pm) continue;
      if (parseInt(pm[2], 10) === k) renamed.set(n, `Metadata/${pm[1]}_1${pm[3]}`);
    }
    const perPlateName = (n) => PER_PLATE.test(norm(n));

    // ── root model: drop other plates' objects and items, move this plate's items
    let rootText = a.rootText;
    {
      const edits = [];
      for (const [id, o] of a.model.objects) if (!plate.keepObjects.has(id)) edits.push({ start: o.start, end: o.end, text: null });
      for (const it of a.model.items) {
        if (!keepRoots.has(String(it.objectid))) { edits.push({ start: it.start, end: it.end, text: null }); continue; }
        if (!shift.dx && !shift.dy) continue;
        const moved = moveTransform(it.transform, shift.dx, shift.dy);
        const tag = /\btransform\s*=\s*"[^"]*"/.test(it.tag)
          ? it.tag.replace(/\btransform\s*=\s*"[^"]*"/, `transform="${moved}"`)
          : it.tag.replace(/\s*(\/?>)/, ` transform="${moved}"$1`);
        edits.push({ start: it.start, end: it.end, text: tag });
      }
      rootText = applyEdits(rootText, edits);
    }

    // ── model_settings.config: this plate (as plate 1) and its objects only
    let ms = a.msText;
    {
      const pl = settings.plates[plate.index - 1];
      const block = renameRefs(pl.block.replace(/(<metadata\b[^>]*\bkey="plater_id"[^>]*\bvalue=")\d+(")/, '$11$2'), renamed);
      const edits = [{ start: pl.start, end: pl.end, text: block }];
      settings.plates.forEach((p, i) => { if (i !== plate.index - 1) edits.push({ start: p.start, end: p.end, text: null }); });
      for (const m of ms.matchAll(/<object\b([^>]*)>[\s\S]*?<\/object>/g)) {
        const id = attr(m[1], 'id');
        if (id != null && !keepRoots.has(id)) edits.push({ start: m.index, end: m.index + m[0].length, text: null });
      }
      ms = applyEdits(ms, edits);
      // <assemble> lists every object of the ORIGINAL project under a different tag and
      // attribute (assemble_item object_id) — the entry that made Orca report "no geometry"
      // for every plate bedready.io extracted until it was pruned too.
      ms = ms.replace(/[ \t]*<assemble_item\b[^>]*?(?:\/>|>[\s\S]*?<\/assemble_item>)\r?\n?/g, (m) =>
        (keepRoots.has(String(attr(m, 'object_id'))) ? m : ''));
      ms = ms.replace(/[ \t]*<assemble>\s*<\/assemble>\r?\n?/g, '');
    }

    // ── positional members: renumber to the kept objects' new positions
    const positional = [...ix.byName.keys()].filter((n) => POSITIONAL_LINES.test(n) || POSITIONAL_XML.test(n));
    let posMap = null;
    if (positional.length) {
      const order = settings.order;
      const buildOrder = [];
      for (const it of a.model.items) if (it.objectid != null && !buildOrder.includes(String(it.objectid))) buildOrder.push(String(it.objectid));
      if (order.join(',') !== buildOrder.join(',')) {
        refuse('positional-order', 'This project stores per-object settings by position, and its object order is ambiguous, so they cannot be carried over safely.');
      }
      posMap = new Map();
      let next = 1;
      order.forEach((id, i) => { if (keepRoots.has(id)) posMap.set(i + 1, next++); });
    }

    // ── assemble the package
    for (const [n, m] of ix.byName) {
      if (/\.model$/i.test(n)) {
        if (n.toLowerCase() === root.toLowerCase()) continue;
        if (plate.keepFiles.has(n)) keepAs(m);
        continue; // another plate's geometry
      }
      if (perPlateName(n)) { if (renamed.has(n)) keepAs(m, renamed.get(n)); continue; }
      if (MODEL_SETTINGS.test(n)) continue;
      if (SLICE_INFO.test(n)) {
        const s = ix.text(m);
        const next = s == null ? null : onePlate(s, (b) => parseInt(meta(b, 'index'), 10) === k,
          (b) => renameRefs(b.replace(/(<metadata\b[^>]*\bkey="index"[^>]*\bvalue=")\d+(")/, '$11$2'), renamed));
        if (next == null || next === s) keepAs(m); else write(m.name, next);
        continue;
      }
      if (CUSTOM_GCODE.test(n)) {
        const s = ix.text(m);
        if (s == null) continue;
        const next = onePlate(s, (b) => parseInt(attr((/<plate_info\b[^>]*>/.exec(b) || [''])[0], 'id'), 10) === k,
          (b) => b.replace(/(<plate_info\b[^>]*\bid=")\d+(")/, '$11$2'));
        if (!/<plate\b/.test(next)) continue; // no custom G-code for this plate
        if (next === s) keepAs(m); else write(m.name, next);
        continue;
      }
      if (FILAMENT_SEQUENCE.test(n)) {
        const s = ix.text(m);
        const j = tryJson(s || '');
        if (!j || typeof j !== 'object' || Array.isArray(j)) refuse('unsupported', 'The project\'s filament sequence could not be read, so it cannot be split safely.');
        const next = {};
        for (const key of Object.keys(j)) {
          const pm = /^plate_(\d+)$/.exec(key);
          if (!pm) next[key] = j[key];
          else if (parseInt(pm[1], 10) === k) next.plate_1 = j[key];
        }
        write(m.name, JSON.stringify(next));
        continue;
      }
      if (POSITIONAL_LINES.test(n)) {
        const s = ix.text(m) || '';
        const lines = s.split(/\r?\n/).filter((line) => {
          const lm = /^object_id=(\d+)\|/.exec(line);
          return !lm || posMap.has(parseInt(lm[1], 10));
        }).map((line) => line.replace(/^object_id=(\d+)\|/, (_, d) => `object_id=${posMap.get(parseInt(d, 10))}|`));
        const next = lines.join(s.includes('\r\n') ? '\r\n' : '\n');
        if (!/object_id=/.test(next)) continue;
        if (next === s) keepAs(m); else write(m.name, next);
        continue;
      }
      if (POSITIONAL_XML.test(n)) {
        const s = ix.text(m) || '';
        const next = s.replace(/[ \t]*<object\b([^>]*?)(?:\/>|>[\s\S]*?<\/object>)\r?\n?/g, (blk, at) => {
          const id = parseInt(attr(at, 'id'), 10);
          if (!posMap.has(id)) return '';
          return blk.replace(/(<object\b[^>]*?\bid=")\d+(")/, `$1${posMap.get(id)}$2`);
        });
        if (!/<object\b/.test(next)) continue;
        if (next === s) keepAs(m); else write(m.name, next);
        continue;
      }
      keepAs(m); // content types, rels, project settings, filament settings, auxiliaries…
    }
    write(a.ix.get(root).name, rootText);
    write(a.msMember.name, ms);

    // ── no reference to a part that is not here: relationships, content-type
    //    overrides, the root model's thumbnail metadata
    const present = new Set([...out.keys()].map((n) => n.toLowerCase()));
    const isPresent = (t) => present.has(norm(t).toLowerCase());
    for (const [n, e] of [...out]) {
      if (/\.rels$/i.test(n)) {
        const s = e.data != null ? toText(e.data) : ix.text(e.from);
        if (s == null) continue;
        const next = s.replace(/[ \t]*<Relationship\b[^>]*?(?:\/>|>[\s\S]*?<\/Relationship>)\r?\n?/g, (r) => {
          const t = attr(r, 'Target');
          return !t || isPresent(resolveTarget(n, t)) ? r : '';
        });
        if (next !== s) write(e.name, next);
      } else if (CONTENT_TYPES.test(n)) {
        const s = ix.text(e.from);
        if (s == null) continue;
        const next = s.replace(/[ \t]*<Override\b[^>]*?\/>\r?\n?/g, (r) => {
          const t = attr(r, 'PartName');
          return !t || isPresent(t) ? r : '';
        });
        if (next !== s) write(e.name, next);
      }
    }
    {
      const rn = norm(a.ix.get(root).name);
      const rt = toText(out.get(rn).data);
      const next = rt.replace(/[ \t]*<metadata\b[^>]*\bname="Thumbnail_[^"]*"[^>]*>([^<]*)<\/metadata>\r?\n?/g,
        (m, target) => (isPresent(target.trim()) ? m : ''));
      if (next !== rt) write(a.ix.get(root).name, next);
    }

    const list = [...out.values()].map((e) => (e.data != null ? { name: e.name, data: e.data } : passthrough(e)));
    const bad = checkPackage(list);
    if (bad.length) refuse('dangling-reference', `The split plate would reference parts it does not contain (${bad.slice(0, 3).join('; ')}).`);
    return {
      ok: true,
      members: list,
      plate: { index: plate.index, platerId: plate.platerId, name: plate.name || null, objectCount: plate.objectCount, partCount: plate.partCount },
      report: { seat: shift.seat, shift: [shift.dx, shift.dy], members: list.length, objects: plate.objectIds.length },
    };
  }

  function passthrough(e) {
    const m = e.from;
    const o = { name: e.name, raw: m.src || null };
    Object.defineProperty(o, 'data', { enumerable: true, configurable: true, get() { return m.data; } });
    return o;
  }

  /** Relationship targets resolve against the folder that holds the _rels folder. */
  function resolveTarget(relsName, target) {
    const t = String(target);
    if (t.startsWith('/')) return norm(t);
    const base = relsName.replace(/(^|\/)_rels\/[^/]+$/, '$1');
    const parts = (base + t).split('/');
    const outp = [];
    for (const p of parts) { if (p === '..') outp.pop(); else if (p && p !== '.') outp.push(p); }
    return outp.join('/');
  }

  /** Keep the one <plate> block `keep` accepts, rewritten by `edit`; drop the rest. */
  function onePlate(s, keep, edit) {
    return s.replace(/[ \t]*<plate\b[^>]*>[\s\S]*?<\/plate>\r?\n?/g, (b) => (keep(b) ? edit(b) : ''));
  }

  /** Per-plate file references inside a block: renamed when kept, removed when not. */
  function renameRefs(block, renamed) {
    return block.replace(/[ \t]*<metadata\b[^>]*\bvalue="\/?(Metadata\/[^"]+)"[^>]*\/>\r?\n?/g, (m, ref) => {
      const n = norm(ref);
      if (!PER_PLATE.test(n)) return m;
      if (renamed.has(n)) return m.replace(ref, renamed.get(n));
      return '';
    }).replace(/\b(value|file)="\/?(Metadata\/[^"]+)"/g, (m, k2, ref) => {
      const n = norm(ref);
      return PER_PLATE.test(n) && renamed.has(n) ? `${k2}="${renamed.get(n)}"` : m;
    });
  }

  /**
   * Every reference a package's metadata makes must resolve inside it.
   *
   * The rule bedready.io had to learn three times, asserted over the whole
   * package rather than one file at a time: relationship targets, content-type
   * overrides, part paths in the root model, Metadata/ and 3D/ paths named in any
   * config, and every object id model_settings mentions. Part files are not
   * scanned — they are geometry, and they are passed through untouched.
   *
   * @returns {string[]} what dangles (empty when the package is whole)
   */
  function checkPackage(members) {
    const names = new Set(members.map((m) => norm(m.name).toLowerCase()));
    const has = (p) => names.has(norm(p).toLowerCase());
    const bad = [];
    const textOf = (m) => { const d = m.data; return d == null ? '' : toText(d); };
    const rootM = members.find((m) => /^3D\/3dmodel\.model$/i.test(norm(m.name)));
    const rootIds = new Set();
    if (rootM) {
      const rt = textOf(rootM);
      for (const o of rt.matchAll(/<object\b([^>]*)>/g)) { const id = attr(o[1], 'id'); if (id != null) rootIds.add(id); }
      for (const c of rt.matchAll(/<component\b([^>]*?)\/?>/g)) {
        const p = attr(c[1], 'p:path');
        if (p && !has(p)) bad.push(`3D/3dmodel.model -> ${norm(p)}`);
      }
      for (const it of rt.matchAll(/<item\b([^>]*?)\/?>/g)) {
        const id = attr(it[1], 'objectid');
        if (id != null && !rootIds.has(id)) bad.push(`build item -> object ${id}`);
      }
    }
    for (const m of members) {
      const n = norm(m.name);
      if (/\.model$/i.test(n) && n.toLowerCase() !== '3d/3dmodel.model') continue;
      if (/\.(png|jpe?g|gcode|md5|stl|step|bin)$/i.test(n) || n.startsWith('Auxiliaries/')) continue;
      const s = textOf(m);
      if (/\.rels$/i.test(n)) {
        for (const r of s.matchAll(/<Relationship\b[^>]*>/g)) {
          const t = attr(r[0], 'Target');
          if (t && !has(resolveTarget(n, t))) bad.push(`${n} -> ${t}`);
        }
        continue;
      }
      if (CONTENT_TYPES.test(n)) {
        for (const r of s.matchAll(/<Override\b[^>]*>/g)) { const t = attr(r[0], 'PartName'); if (t && !has(t)) bad.push(`${n} -> ${t}`); }
        continue;
      }
      if (/^Metadata\//i.test(n) || n.toLowerCase() === '3d/3dmodel.model') {
        const scan = n.toLowerCase() === '3d/3dmodel.model' ? s.replace(/<resources\b[\s\S]*<\/resources>/, '') : s;
        for (const r of scan.matchAll(/["'>]\/?((?:Metadata|3D)\/[A-Za-z0-9_\-./]+\.(?:png|model|config|xml|json|gcode))(?=["'<])/g)) {
          if (!has(r[1])) bad.push(`${n} -> ${r[1]}`);
        }
      }
      if (MODEL_SETTINGS.test(n) && rootIds.size) {
        for (const r of s.matchAll(/<metadata\b[^>]*\bkey="object_id"[^>]*\bvalue="([^"]+)"/g)) if (!rootIds.has(r[1])) bad.push(`${n} -> object ${r[1]}`);
        for (const r of s.matchAll(/\bobject_id="([^"]+)"/g)) if (!rootIds.has(r[1])) bad.push(`${n} -> object ${r[1]}`);
      }
    }
    return bad;
  }

  // ── Node ends ────────────────────────────────────────────────────────────

  /** List the plates of a 3MF buffer. See peekPlatesMembers. */
  function peekPlates(buf, opts) {
    const members = readMembers(buf);
    if (!members.length) return { ok: false, code: 'not-3mf', error: 'Not a readable 3MF/ZIP file.' };
    return peekPlatesMembers(members, opts);
  }

  /**
   * One plate of a 3MF buffer as a 3MF buffer.
   * @returns {{ok:true, buffer:Buffer, plate, report} | {ok:false, code, error}}
   */
  function extractPlate(buf, plateIndex) {
    const members = readMembers(buf);
    if (!members.length) return { ok: false, code: 'not-3mf', error: 'Not a readable 3MF/ZIP file.' };
    const r = extractPlateMembers(members, plateIndex);
    if (!r.ok) return r;
    const buffer = zipWrite.writeZip(r.members);
    if (!buffer) return { ok: false, code: 'error', error: 'Could not write the plate\'s 3MF.' };
    return { ok: true, buffer, plate: r.plate, report: r.report };
  }

  /** A file name for plate N of `source.3mf`: `source-plate2.3mf`. */
  function plateFileName(sourceName, plateIndex) {
    const base = String(sourceName || 'model.3mf').split(/[\\/]/).pop().replace(/\.3mf$/i, '') || 'model';
    return `${base}-plate${Math.max(1, parseInt(plateIndex, 10) || 1)}.3mf`;
  }

  const api = { peekPlates, extractPlate, peekPlatesMembers, extractPlateMembers, checkPackage, readMembers, plateFileName, PEEK_MESH_BYTES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytPlates = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
