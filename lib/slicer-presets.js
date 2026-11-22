'use strict';
/**
 * The printer, process and filament an Orca/Bambu-family slicer needs to slice a BARE model.
 *
 * ── WHY ───────────────────────────────────────────────────────────────────
 *
 * A project 3MF carries its own settings and slices with `--slice 0`. A bare
 * model — an STL, an OBJ, a 3MF with only a mesh in it — does not, and the
 * forks then fall back to built-in defaults that fail their own validation
 * ("Relative extruder addressing requires resetting the extruder position at
 * each layer… Add G92 E0 to layer_gcode", Snapmaker Orca, exit 205). Bambu
 * Studio slices it but weighs it at 0.00 g. So a customer's STL could not be
 * quoted from a slicer at all (#1778, after #1737).
 *
 * The answer the shop would give is "the printer I last used in that slicer".
 * Every fork records it in its app config (`presets.machine`); Bambu Studio
 * also records the process and the filaments. What a fork does not record,
 * the machine preset names (`default_print_profile`, `default_filament_profile`)
 * — but those names are not always real files (Snapmaker's U1 names
 * "0.20 Standard @…" where the file is "0.20mm Standard @…"), and the CLI
 * refuses a process whose `compatible_printers` does not list the machine
 * ("process not compatible with printer"). So a candidate is accepted on the
 * same test the slicer applies, and the declared default only breaks ties.
 *
 * Presets are flattened along `inherits` (child wins) and handed to the CLI as
 * `--load-settings "machine.json;process.json" --load-filaments "filament.json"`.
 *
 * ── SHAPE ─────────────────────────────────────────────────────────────────
 *
 * Pure: the filesystem arrives as `io` ({ readText(p), listDir(p), isFile(p),
 * join(...parts) }), so the Mac app can drive the same rules with its own
 * file access, and tests can hand it a tree in memory.
 */
(function (global) {
  const KINDS = ['machine', 'process', 'filament'];
  const MAX_INHERITS = 12;
  const PROTO = new Set(['__proto__', 'constructor', 'prototype']);

  /** A preset name is a bare file stem: no separators, no traversal. */
  function isSafeName(name) {
    const s = String(name || '');
    return !!s && s.length <= 200 && !/[\\/]/.test(s) && s.indexOf('..') < 0 && !/[\0]/.test(s);
  }

  /** An Orca/Bambu app config: JSON, sometimes followed by a "# MD5 checksum …" line. */
  function parseAppConfig(text) {
    const s = String(text || '');
    const a = s.indexOf('{');
    const b = s.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try { return JSON.parse(s.slice(a, b + 1)); } catch (_) { return null; }
  }

  /** What the slicer last used: { machine, process, filaments[] } (any may be empty). */
  function lastUsed(conf) {
    const p = (conf && conf.presets) || {};
    let fil = p.filaments;
    if (typeof fil === 'string') { try { fil = JSON.parse(fil); } catch (_) { fil = [fil]; } }
    return {
      machine: typeof p.machine === 'string' ? p.machine : '',
      process: typeof p.process === 'string' ? p.process : (typeof p.print === 'string' ? p.print : ''),
      filaments: Array.isArray(fil) ? fil.filter((x) => typeof x === 'string' && x) : [],
    };
  }

  /**
   * Every directory a preset of `kind` can sit in, most specific first: the
   * shop's own (user/<id>/<kind>), the slicer's synced copy (system/<Vendor>/<kind>),
   * then the app's bundled profiles (<Vendor>/<kind>).
   */
  function presetDirs(io, roots, kind) {
    const out = [];
    const sub = (dir) => { try { return io.listDir(dir) || []; } catch (_) { return []; } };
    if (roots.user) for (const id of sub(roots.user)) out.push(io.join(roots.user, id, kind));
    for (const base of [roots.system, roots.bundled]) {
      if (!base) continue;
      for (const vendor of sub(base)) out.push(io.join(base, vendor, kind));
    }
    return out;
  }

  function readPreset(io, file) {
    try {
      const j = JSON.parse(io.readText(file));
      return j && typeof j === 'object' && !Array.isArray(j) ? j : null;
    } catch (_) { return null; }
  }

  /** A preset by name, flattened along `inherits`; null when it or a parent is missing. */
  function resolve(io, roots, kind, name, seen) {
    seen = seen || new Set();
    if (!isSafeName(name) || seen.has(name) || seen.size >= MAX_INHERITS) return null;
    seen.add(name);
    let own = null;
    for (const dir of presetDirs(io, roots, kind)) {
      const f = io.join(dir, name + '.json');
      if (io.isFile(f)) { own = readPreset(io, f); if (own) break; }
    }
    if (!own) return null;
    const parent = own.inherits ? resolve(io, roots, kind, String(own.inherits), seen) : {};
    if (parent === null) return null;
    const out = Object.assign({}, parent);
    for (const k of Object.keys(own)) if (!PROTO.has(k)) out[k] = own[k];
    delete out.inherits;
    out.name = name;
    return out;
  }

  /** Names of every preset of `kind` this slicer can see, without reading them. */
  function listNames(io, roots, kind) {
    const names = new Set();
    for (const dir of presetDirs(io, roots, kind)) {
      let files = [];
      try { files = io.listDir(dir) || []; } catch (_) { continue; }
      for (const f of files) if (/\.json$/i.test(f)) names.add(f.replace(/\.json$/i, ''));
    }
    return [...names];
  }

  const asList = (v) => (Array.isArray(v) ? v : (typeof v === 'string' && v ? v.split(';') : []))
    .map((x) => String(x).trim()).filter(Boolean);

  /** The slicer's own compatibility test: an empty list means "any printer". */
  function compatibleWith(preset, machineName) {
    const list = asList(preset && preset.compatible_printers);
    return !list.length || list.indexOf(machineName) >= 0;
  }

  /**
   * The first preset of `kind` the machine accepts, trying `wanted` names in order and then
   * every preset whose name carries the machine's "@tag" (or the machine name). `prefer` ranks
   * the fallback candidates. Never reads the whole tree: a fork ships thousands of presets.
   */
  function pick(io, roots, kind, machineName, wanted, tag, prefer) {
    for (const n of wanted) {
      const p = n ? resolve(io, roots, kind, n) : null;
      if (p && compatibleWith(p, machineName)) return p;
    }
    const usable = listNames(io, roots, kind)
      .filter((n) => !/^fdm_|_old\b|template|\bbase$/i.test(n))
      .sort((a, b) => prefer(b) - prefer(a) || a.localeCompare(b));
    const ok = (n) => {
      const p = resolve(io, roots, kind, n);
      return p && compatibleWith(p, machineName) && p.instantiation !== 'false' ? p : null;
    };
    // Named for this machine first ("… @BBL H2D", "… @MyKlipper")…
    const scoped = usable.filter((n) => (tag && n.indexOf(tag) >= 0) || n.indexOf(machineName) >= 0);
    for (const n of scoped.slice(0, 40)) { const p = ok(n); if (p) return p; }
    // …then anything that lists it. Vendors do not always tag by the machine's own name:
    // Snapmaker's U1 filaments are "Generic PLA @U1". Bounded — a fork ships thousands.
    for (const n of usable.slice(0, 300)) { if (scoped.indexOf(n) >= 0) continue; const p = ok(n); if (p) return p; }
    return null;
  }

  /**
   * Machine, process and filament for a bare-model slice, or why not.
   *
   * @param {object} io        see SHAPE
   * @param {{ conf?:string, user?:string, system?:string, bundled?:string }} roots
   *        conf — the app config file's text; user/system/bundled — preset roots (any may be missing)
   * @param {{ machine?:string, process?:string, filament?:string }} [want] explicit names win
   * @returns {{ ok:true, machine:object, process:object, filament:object } | { ok:false, code:string, error:string }}
   */
  function choosePresets(rawIo, roots, want) {
    // Listings and file tests CACHED for this one choice. Every name resolved
    // re-listed every vendor folder: about 10,000 file-system calls per
    // customer upload against a real Snapmaker Orca install (alpha.61
    // review), each a crossing into Swift on the Mac. The tree does not change
    // in the time a choice takes.
    const io = cachedIo(rawIo);
    const w = want || {};
    const used = lastUsed(parseAppConfig(roots.conf));
    const machineName = w.machine || used.machine;
    if (!machineName) {
      return { ok: false, code: 'no-printer', error: 'This slicer has no printer chosen yet. Open it once and pick your printer.' };
    }
    const machine = resolve(io, roots, 'machine', machineName);
    if (!machine) {
      return { ok: false, code: 'printer-missing', error: `The slicer's printer "${machineName}" could not be found in its profiles.` };
    }
    const dp = asList(machine.default_print_profile)[0] || '';
    const at = dp.indexOf('@');
    const tag = at >= 0 ? dp.slice(at) : '';
    const process = pick(io, roots, 'process', machineName, [w.process, used.process, dp], tag,
      (n) => (/\b0\.20\s*mm?\b|0\.20mm/i.test(n) ? 2 : 0) + (/standard/i.test(n) ? 1 : 0));
    if (!process) {
      return { ok: false, code: 'process-missing', error: `No print profile in the slicer fits "${machineName}".` };
    }
    const df = asList(machine.default_filament_profile);
    const filament = pick(io, roots, 'filament', machineName, [w.filament].concat(used.filaments, df), tag,
      (n) => (/\bpla\b/i.test(n) ? 2 : 0) + (/generic|basic/i.test(n) ? 1 : 0));
    if (!filament) {
      return { ok: false, code: 'filament-missing', error: `No filament profile in the slicer fits "${machineName}".` };
    }
    return { ok: true, machine, process, filament };
  }

  /** `io` with listDir and isFile remembered (a throw is remembered too). */
  function cachedIo(io) {
    const lists = new Map();
    const files = new Map();
    const sets = new Map();
    const cached = {
      readText: (p) => io.readText(p),
      join: io.join,
      listDir: (p) => {
        if (!lists.has(p)) {
          try { lists.set(p, { v: io.listDir(p) }); } catch (e) { lists.set(p, { e }); }
        }
        const r = lists.get(p);
        if (r.e) throw r.e;
        return r.v;
      },
      // Answered from the folder's (cached) listing first: a name that is
      // not in it is not a file, with no call at all. Only a name that IS
      // listed is asked — it could be a folder called "x.json".
      isFile: (p) => {
        if (files.has(p)) return files.get(p);
        const cut = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
        let listed = true;
        if (cut > 0) {
          const dir = p.slice(0, cut);
          const base = p.slice(cut + 1);
          if (!sets.has(dir)) {
            let names = null;
            try { names = new Set(cached.listDir(dir) || []); } catch (_) { names = new Set(); }
            sets.set(dir, names);
          }
          listed = sets.get(dir).has(base);
        }
        const yes = listed && !!io.isFile(p);
        files.set(p, yes);
        return yes;
      },
    };
    return cached;
  }

  /** The file a preset is handed to the CLI as: flattened, typed, and complete in itself. */
  function presetFileJson(kind, preset) {
    if (KINDS.indexOf(kind) < 0) throw new Error('unknown preset kind');
    // "system", not "User": Bambu Studio's CLI judges a User process against the printer it
    // INHERITS from — gone once flattened — and refused every one ("run 3002: process not
    // compatible with printer"). A flattened preset is complete, which is what system means.
    const out = Object.assign({}, preset, { type: kind, from: 'system' });
    delete out.inherits;
    return JSON.stringify(out);
  }

  /**
   * Where an Orca/Bambu fork keeps its presets, from its executable path. Pure: the caller
   * passes platform, home and env, and checks which of the returned paths exist.
   *
   * The app-config folder is named after the app key, which on macOS is the executable's own
   * name (Contents/MacOS/OrcaSlicer, BambuStudio, Snapmaker_Orca, QIDIStudio…). On Windows and
   * Linux the executable is lower-case-dashed (orca-slicer, bambu-studio), so the key comes from
   * the family token instead. `configNames` lists every candidate; the caller takes the first
   * that exists.
   */
  function presetRoots(slicerPath, opts) {
    const o = opts || {};
    const plat = o.platform || 'darwin';
    const home = o.home || '';
    const env = o.env || {};
    const sep = plat === 'win32' ? '\\' : '/';
    const parts = String(slicerPath || '').split(/[\\/]/);
    const exe = (parts[parts.length - 1] || '').replace(/\.(exe|appimage)$/i, '');
    const join = (...xs) => xs.filter(Boolean).join(sep);
    const KEYS = [[/orca\s*slicer|orca-slicer/i, 'OrcaSlicer'], [/bambu/i, 'BambuStudio'], [/snapmaker/i, 'Snapmaker_Orca'],
      [/qidi/i, 'QIDIStudio'], [/elegoo/i, 'ElegooSlicer'], [/creality/i, 'CrealityPrint'], [/anycubic/i, 'AnycubicSlicerNext'],
      [/anker/i, 'AnkerMake Studio'], [/sovol/i, 'SovolSlicer']];
    const configNames = [];
    if (plat === 'darwin' && exe) configNames.push(exe);
    for (const [re, key] of KEYS) if (re.test(exe) && configNames.indexOf(key) < 0) configNames.push(key);
    const base = plat === 'darwin' ? join(home, 'Library', 'Application Support')
      : plat === 'win32' ? (env.APPDATA || join(home, 'AppData', 'Roaming'))
      : (env.XDG_CONFIG_HOME || join(home, '.config'));
    let bundled = '';
    const appAt = parts.findIndex((x) => /\.app$/i.test(x));
    if (plat === 'darwin' && appAt >= 0) bundled = parts.slice(0, appAt + 1).concat(['Contents', 'Resources', 'profiles']).join('/');
    else if (parts.length > 1) bundled = join(parts.slice(0, -1).join(sep), 'resources', 'profiles');
    return configNames.map((name) => {
      const dir = join(base, name);
      return { name, dir, confFile: join(dir, name + '.conf'), user: join(dir, 'user'), system: join(dir, 'system'), bundled };
    });
  }

  /**
   * Does this model need presets handed to it? Only a project that carries its own settings
   * slices without them. `entries` is the 3MF's member list (names), or null for other files.
   */
  function needsPresets(modelPath, entries) {
    if (!/\.3mf$/i.test(String(modelPath || ''))) return true;
    return !(Array.isArray(entries) && entries.some((n) => /(^|\/)Metadata\/project_settings\.config$/i.test(String(n))));
  }

  const api = { presetRoots, needsPresets, parseAppConfig, lastUsed, resolve, compatibleWith, choosePresets, presetFileJson, isSafeName };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSlicerPresets = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
