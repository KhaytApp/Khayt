(function (global) {
  'use strict';
  /*
   * ── A MODEL WITH NO SETTINGS, SLICED BY AN ORCA FORK, AS A PROJECT ─────────
   *
   * Snapmaker Orca 2.4.1's command line segfaults whenever presets are handed
   * to it by flag: `--load-settings` alone, or with `--load-filaments`, its own
   * bundled presets included. Reproduced on Nov 27 2026 on a U1 STL (network
   * denied, copied --datadir): exit 139 in under a second, no G-code, every
   * time. The same three presets inside a project 3MF's
   * `Metadata/project_settings.config`, sliced with the plain `--slice 0`,
   * gave 4 MB of G-code in two seconds. A loose STL given beside a
   * settings-only 3MF is refused (exit 250), so the model has to go INSIDE.
   *
   * So a model that needs presets (lib/slicer-presets.js needsPresets) is
   * never sliced with preset flags. It becomes a project:
   *   - an STL: a new 3MF holding its mesh, standing on the printer's bed,
   *     plus the settings;
   *   - a 3MF with no project settings: the same file with
   *     `Metadata/project_settings.config` ADDED, every other member kept
   *     byte for byte (the creator's objects, plates and per-object settings);
   *   - anything else (OBJ, STEP…): no project can be made here, so the
   *     caller says so rather than crash the slicer.
   *
   * Pure and JavaScriptCore-safe. The caller reads and writes files and does
   * the zipping (Node's zlib on the desktop, ZipWrite on the Mac). The Mac
   * writes the mesh XML itself, streaming, so a 300 MB STL never crosses into
   * JavaScript; Parity tests hold its output to `modelXml` here.
   */

  const CONFIG_MEMBER = 'Metadata/project_settings.config';
  const MODEL_MEMBER = '3D/3dmodel.model';

  const CONTENT_TYPES = '<?xml version="1.0" encoding="UTF-8"?>'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>'
    + '</Types>';
  const RELS = '<?xml version="1.0" encoding="UTF-8"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>'
    + '</Relationships>';
  const MODEL_HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
    + '<resources>\n<object id="1" type="model">\n<mesh>\n';
  const MODEL_TAIL = '</mesh>\n</object>\n</resources>\n<build>\n<item objectid="1"/>\n</build>\n</model>\n';

  /**
   * What to slice instead of `modelPath`: 'stl' (build a project), 'add-config'
   * (a 3MF with no project settings: add them), 'as-is' (a project that has
   * its own settings), or 'unsupported' (no project can be made from it).
   */
  function plan(modelPath, entries) {
    const p = String(modelPath || '').toLowerCase();
    if (/\.stl$/.test(p)) return 'stl';
    if (/\.3mf$/.test(p)) {
      const has = Array.isArray(entries) && entries.some((n) => /(^|\/)metadata\/project_settings\.config$/i.test(String(n)));
      return has ? 'as-is' : 'add-config';
    }
    return 'unsupported';
  }

  /** The centre of the printer's printable area, from the machine preset; [x, y] mm. */
  function bedCentre(machine) {
    const area = machine && Array.isArray(machine.printable_area) ? machine.printable_area : [];
    const pts = area.map((s) => String(s).split('x').map(Number)).filter((p) => p.length === 2 && p.every(Number.isFinite));
    if (!pts.length) return [128, 128];
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    return [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2];
  }

  /** A coordinate as the model XML writes it: at most 4 decimals, no trailing zeros, no "-0". */
  function num(v) {
    let s = (Math.round(v * 10000) / 10000).toFixed(4).replace(/\.?0+$/, '');
    if (s === '-0') s = '0';
    return s;
  }

  /**
   * How far to move a mesh so its footprint is centred on `centre` and its
   * lowest point is on the bed, from its bounding box ({min:[x,y,z], max:[x,y,z]},
   * as lib/stl-parse.js measures it without keeping triangles).
   */
  function offsetFor(bbox, centre) {
    const min = bbox && Array.isArray(bbox.min) ? bbox.min : [0, 0, 0];
    const max = bbox && Array.isArray(bbox.max) ? bbox.max : [0, 0, 0];
    const c = Array.isArray(centre) ? centre : [0, 0];
    return [c[0] - (min[0] + max[0]) / 2, c[1] - (min[1] + max[1]) / 2, -min[2]];
  }

  /**
   * A mesh writer fed one triangle at a time, so a binary STL can be STREAMED
   * (measure it first for `offset`, then feed it) rather than held as a list.
   * Shared vertices are written once (exact match after rounding); a triangle
   * that collapses to a line or a point after rounding is dropped, and adds no
   * vertex. `xml()` is the whole model member.
   */
  function meshWriter(offset) {
    const d = Array.isArray(offset) ? offset : [0, 0, 0];
    const index = new Map(); const verts = [];
    // Faces as one growing Int32Array, three indices each: a million-triangle
    // mesh is 12 MB here, not a million small arrays.
    let faces = new Int32Array(3 * 1024); let nf = 0;
    function key(x, y, z) { return num(x + d[0]) + ' ' + num(y + d[1]) + ' ' + num(z + d[2]); }
    return {
      add(ax, ay, az, bx, by, bz, cx, cy, cz) {
        const k = [key(ax, ay, az), key(bx, by, bz), key(cx, cy, cz)];
        if (k[0] === k[1] || k[1] === k[2] || k[0] === k[2]) return false;
        if (nf * 3 + 3 > faces.length) { const g = new Int32Array(faces.length * 2); g.set(faces); faces = g; }
        for (let j = 0; j < 3; j++) {
          let i = index.get(k[j]);
          if (i === undefined) { i = verts.length; index.set(k[j], i); verts.push(k[j]); }
          faces[nf * 3 + j] = i;
        }
        nf++;
        return true;
      },
      counts() { return { vertices: verts.length, triangles: nf }; },
      /**
       * The model member in pieces of about `size` lines each, in order, so a
       * million-triangle mesh is never one string: `emit(text)` writes each
       * piece to a file or a zip stream. The pieces joined are exactly `xml()`.
       */
      xmlChunks(emit, size) {
        const n = Number.isInteger(size) && size > 0 ? size : 4096;
        emit(MODEL_HEAD + '<vertices>\n');
        let buf = [];
        const flush = () => { if (buf.length) { emit(buf.join('')); buf = []; } };
        for (const s of verts) {
          const p = s.split(' ');
          buf.push('<vertex x="' + p[0] + '" y="' + p[1] + '" z="' + p[2] + '"/>\n');
          if (buf.length >= n) flush();
        }
        flush();
        emit('</vertices>\n<triangles>\n');
        for (let t = 0; t < nf; t++) {
          buf.push('<triangle v1="' + faces[3 * t] + '" v2="' + faces[3 * t + 1] + '" v3="' + faces[3 * t + 2] + '"/>\n');
          if (buf.length >= n) flush();
        }
        flush();
        emit('</triangles>\n' + MODEL_TAIL);
      },
      xml() {
        const out = [];
        this.xmlChunks((s) => out.push(s));
        return out.join('');
      },
    };
  }

  /** The model XML for a triangle list ([[a, b, c], …], each [x, y, z]), measured and centred here. Small meshes and tests. */
  function modelXml(triangles, centre) {
    const tris = Array.isArray(triangles) ? triangles : [];
    const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
    for (const t of tris) for (const v of t) for (let a = 0; a < 3; a++) { if (v[a] < min[a]) min[a] = v[a]; if (v[a] > max[a]) max[a] = v[a]; }
    const w = meshWriter(tris.length ? offsetFor({ min, max }, centre) : [0, 0, 0]);
    for (const t of tris) w.add(t[0][0], t[0][1], t[0][2], t[1][0], t[1][1], t[1][2], t[2][0], t[2][1], t[2][2]);
    return w.xml();
  }

  /** The member that turns a plain 3MF into a project, given projectSettingsJson's text. */
  function configMember(settingsJson) {
    if (typeof settingsJson !== 'string' || !settingsJson.trim().startsWith('{')) throw new Error('configMember: settings JSON required');
    return { name: CONFIG_MEMBER, text: settingsJson };
  }

  /** Every member of a project built from a mesh, except the model XML's text (the caller's). */
  function stlProjectMembers(settingsJson) {
    return [
      { name: '[Content_Types].xml', text: CONTENT_TYPES },
      { name: '_rels/.rels', text: RELS },
      { name: MODEL_MEMBER, text: null },
      configMember(settingsJson),
    ];
  }

  const api = { plan, bedCentre, offsetFor, meshWriter, modelXml, num, configMember, stlProjectMembers, CONFIG_MEMBER, MODEL_MEMBER, MODEL_HEAD, MODEL_TAIL };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSlicerProject = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
