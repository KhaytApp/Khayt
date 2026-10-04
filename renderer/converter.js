'use strict';
/*
 * 3MF Converter UI (3.1 / 3.2) — retarget a 3MF to a different printer (re-profile +
 * optional colour→slot remap) or normalize it to a clean generic 3MF. Entry points:
 *   • a "Convert" action on a print-file library card (renderer/printfiles.js),
 *   • a standalone "Converter" tab (single file, batch, and a custom-printer manager).
 *
 * 3.2 additions: a rich pre-convert summary (source printer / bed / nozzle / material /
 * print time / model footprint) with a live "what changes" diff and a bed-fit check;
 * user-defined printers (settings.customPrinters[]) offered everywhere; and batch
 * conversion of many files to one target in a single run.
 *
 * The heavy lifting is in the main process (hub:mf-analyze / hub:mf-convert over
 * lib/mf-convert.js); this module is the picker + options + result. Geometry is never
 * touched by the engine, so a conversion is safe by construction.
 */
(function (global) {
  const hub = () => (typeof window !== 'undefined' && window.hubAPI) || null;
  const profiles = () => global.KhaytPrinterProfiles;
  // Bed Ready keeps headings plain (no leading emoji) to match its monoline chrome.
  const _bdr = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready');
  const _titleIco = _bdr ? '' : '🔄 ';
  // Toolbar/label emoji clash with Bed Ready's drafting chrome — strip them there, keep for Khayt.
  const _emo = (e) => _bdr ? '' : e + ' ';
  // Where a marker carries meaning (fit/over warnings, file/status glyphs), swap to a bespoke icon.
  /* Flavour set, then the shared line icons, then the emoji — the order every
   * other module uses now. This one asked Bed Ready or gave up. */
  const _emoI = (name, emoji, size) => {
    if (_bdr && window.BedReadyIcons) return `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>`;
    const svg = (typeof window !== 'undefined' && window.KhaytIcons) ? window.KhaytIcons.icon(name, size || 15) : '';
    if (svg) return `<span class="pf-ico" aria-hidden="true">${svg}</span>`;
    return emoji ? emoji + ' ' : '';
  };

  function customPrinters() {
    return (typeof settings !== 'undefined' && Array.isArray(settings.customPrinters)) ? settings.customPrinters : [];
  }
  // Printers from the maker's installed slicer catalogue (Snapmaker Orca + OrcaSlicer). Names loaded
  // once when the converter opens; each printer's full profile (bed, slots, native machine) is resolved
  // lazily the first time it's selected and cached under its "orca:<name>" id.
  let _orcaPrinters = null;      // [{ name, vendor }] or null until loaded
  const _orcaProfileCache = {};  // machineName → normalized profile
  function orcaIdFor(name) { return 'orca:' + name; }
  function isOrcaId(id) { return typeof id === 'string' && id.indexOf('orca:') === 0; }
  function orcaNameFromId(id) { return isOrcaId(id) ? id.slice(5) : null; }

  // All selectable targets: user printers first, then the built-in registry, then Generic.
  function getProfileById(id) {
    if (isOrcaId(id)) return _orcaProfileCache[orcaNameFromId(id)] || null;
    const c = customPrinters().find((p) => p.id === id);
    if (c) return c;
    const P = profiles();
    return P ? P.getProfile(id) : null;
  }
  function firstTargetId() {
    const c = customPrinters();
    if (c.length) return c[0].id;
    const P = profiles();
    return P ? (P.listProfiles()[0] || {}).id : '';
  }
  function isCustomId(id) { return customPrinters().some((p) => p.id === id); }

  function swatch(hex, size) {
    const s = size || 16;
    return `<span class="cs-swatch" style="background:${safeCssColor(hex, '#888')};width:${s}px;height:${s}px;"></span>`;
  }
  function fmtBed(b) { return b ? `${b.x}×${b.y} mm` : null; }
  function fmtVol(b) { return b ? `${b.x}×${b.y}×${b.z} mm` : null; }
  function fmtTime(min) { if (!min) return null; const h = Math.floor(min / 60), m = Math.round(min % 60); return h ? `${h}h ${m}m` : `${m}m`; }

  // A retarget only makes sense within one slicer config family. When we know the source
  // flavour, offer only compatible printers (+ Generic) so an incoherent cross-ecosystem
  // conversion can't be picked; for an unknown source, only Generic is meaningful.
  function compatibleWith(sourceFlavour, p) {
    const P = profiles();
    if (!p || !P || !P.configFamily) return true;
    if (P.configFamily(p.flavour) === 'generic') return true; // Generic normalize is always valid
    if (!sourceFlavour || sourceFlavour === 'generic') return true;
    if (isPrusaProject(sourceFlavour, p)) return true; // Bambu/Orca → a real PrusaSlicer project
    return P.configFamily(p.flavour) === P.configFamily(sourceFlavour);
  }
  // ── BAMBU/ORCA → PRUSASLICER PROJECT ──────────────────────────────────────────────────────
  // A Bambu/Orca file aimed at a Prusa whose exact PrusaSlicer preset is known becomes a PrusaSlicer
  // project (lib/prusa-project.js, ported from bedready.io) instead of a Generic 3MF. Mirrors
  // `applies` in lib/prusa-project.js; `p` is a profile or a target id.
  function isPrusaProject(sourceFlavour, p) {
    const P = profiles();
    const prof = typeof p === 'string' ? getProfileById(p) : p;
    return !!(prof && P && P.configFamily && P.configFamily(sourceFlavour) === 'bbl'
      && P.configFamily(prof.flavour) === 'prusa' && prof.printerSettingsId && prof.bed && prof.bed.x);
  }
  // What the project will hold, from the main process's plan (hub:prusa-plan): the tools to load,
  // where each source colour prints (a tool or a ColorMix blend), and the warnings — or why not.
  function prusaPlanHtml(plan) {
    if (!plan) return `<div class="conv-fs-loading">${escapeHtml(t('conv.prusa_planning') || 'Working out the tools…')}</div>`;
    if (!plan.ok) {
      return `<p class="conv-note" role="alert">${_emoI('alert', '⚠', 12)}${escapeHtml((t('conv.prusa_cannot') || 'This file can’t become a PrusaSlicer project for {t}:').replace('{t}', plan.targetName || ''))} ${escapeHtml(plan.error || '')}</p>`;
    }
    const toolName = (k) => (t('conv.tool') || 'Tool') + ' ' + k;
    const tools = plan.colours.map((hex, i) => {
      const used = plan.toolsUsed.includes(i + 1);
      return `<div class="conv-fs-head">${swatch(hex, 18)}<span>${escapeHtml(toolName(i + 1))} · ${used ? escapeHtml(`${hex} ${plan.types[i] || ''}`) : escapeHtml(t('conv.prusa_unused') || 'not used')}</span></div>`;
    }).join('');
    const blendText = (b) => b.components.map((c) => `${Math.round(c.ratio * 100)}% ${swatch(plan.colours[c.tool - 1], 12)} ${escapeHtml(toolName(c.tool))}`).join(' + ');
    const rows = (plan.srcColours || []).map((hex, i) => {
      const to = plan.map[i];
      const dest = to < plan.tools
        ? `${swatch(plan.colours[to], 14)} ${escapeHtml(toolName(to + 1))}`
        : `${escapeHtml(t('conv.prusa_blend') || 'ColorMix blend')} ${swatch(plan.blends[to - plan.tools].hex, 14)}: ${blendText(plan.blends[to - plan.tools])}`;
      return `<div class="conv-fs-mix">${swatch(hex, 16)} → ${dest}</div>`;
    }).join('');
    const mixed = plan.blends.length
      ? `<div class="conv-fs-mix">${escapeHtml((t('conv.prusa_blends_n') || 'Colours mixed from the loaded tools: {n}').replace('{n}', plan.map.filter((m) => m >= plan.tools).length))}</div>` : '';
    const warns = (plan.warnings || []).map((w) => `<div class="conv-fs-mix">${_emoI('alert', '⚠', 12)}${escapeHtml(w)}</div>`).join('');
    return `<div class="conv-fs-plan">
        <div class="conv-fs-sub">${escapeHtml(t('conv.prusa_tools') || 'Load these on the tools:')}</div>
        <div class="conv-fs-heads">${tools}</div>
        <div class="conv-fs-sub">${escapeHtml(t('conv.prusa_colours') || 'Where each colour prints:')}</div>
        <div class="conv-fs-mixes">${rows}${mixed}${warns}</div>
      </div>`;
  }
  // A printer from a *different* slicer ecosystem than the source. We still let you pick it,
  // but the output is written as a clean Generic 3MF (geometry + colours kept, vendor config
  // stripped) — a coherent Prusa→Bambu config port isn't possible, so normalize instead of
  // producing a broken file. The user opens the Generic 3MF in that printer's own slicer.
  function isCrossEcosystem(sourceFlavour, id) {
    const P = profiles();
    const p = getProfileById(id);
    if (!p || !P || !P.configFamily) return false;
    if (P.configFamily(p.flavour) === 'generic') return false;
    return !compatibleWith(sourceFlavour, p);
  }

  /* ---------------- Conversion presets ---------------- */
  function convPresets() { return (typeof settings !== 'undefined' && Array.isArray(settings.convPresets)) ? settings.convPresets : []; }
  function savePreset(name, tId, slotMap) {
    if (typeof settings === 'undefined') return;
    if (!Array.isArray(settings.convPresets)) settings.convPresets = [];
    settings.convPresets.push({
      id: typeof uid === 'function' ? uid('cvp') : ('cvp' + Date.now().toString(36)),
      name: String(name).slice(0, 40), targetId: tId, slotMap: Array.isArray(slotMap) ? slotMap : null,
    });
    if (typeof saveAll === 'function') saveAll();
  }
  function removePreset(id) {
    if (typeof settings === 'undefined' || !Array.isArray(settings.convPresets)) return;
    settings.convPresets = settings.convPresets.filter((p) => p.id !== id);
    if (typeof saveAll === 'function') saveAll();
    renderConverter();
  }
  function presetOptions(sourceFlavour) {
    return convPresets().filter((p) => compatibleWith(sourceFlavour, getProfileById(p.targetId)))
      .map((p) => `<option value="${escapeHtml(p.id)}">${escapeHtml(p.name)}</option>`).join('');
  }
  function firstCompatibleId(sourceFlavour) {
    const P = profiles();
    const all = [...customPrinters(), ...(P ? P.listProfiles() : [])];
    const hit = all.find((p) => compatibleWith(sourceFlavour, p));
    return hit ? hit.id : (P ? P.GENERIC.id : '');
  }

  function targetOptions(selectedId, sourceFlavour) {
    const P = profiles();
    if (!P) return '';
    const opt = (p) => `<option value="${escapeHtml(p.id)}"${p.id === selectedId ? ' selected' : ''}>${escapeHtml(p.name)}${p.system ? ' · ' + escapeHtml(p.system) : ''}</option>`;
    let html = '';
    const custom = customPrinters().filter((p) => compatibleWith(sourceFlavour, p));
    if (custom.length) html += `<optgroup label="${escapeHtml(t('conv.my_printers') || 'My printers')}">${custom.map(opt).join('')}</optgroup>`;
    const byVendor = {};
    for (const p of P.listProfiles()) { if (compatibleWith(sourceFlavour, p)) (byVendor[p.vendor] = byVendor[p.vendor] || []).push(p); }
    html += Object.keys(byVendor).map((vendor) =>
      `<optgroup label="${escapeHtml(vendor)}">${byVendor[vendor].map(opt).join('')}</optgroup>`).join('');
    // Full installed-slicer catalogue (thousands of printers, grouped by vendor). Selecting one builds a
    // native config from that printer's own profile. Shown only once the catalogue has loaded.
    if (Array.isArray(_orcaPrinters) && _orcaPrinters.length) {
      const byV = {};
      for (const p of _orcaPrinters) (byV[p.vendor] = byV[p.vendor] || []).push(p);
      const catOpt = (p) => `<option value="${escapeHtml(orcaIdFor(p.name))}"${orcaIdFor(p.name) === selectedId ? ' selected' : ''}>${escapeHtml(p.name)}</option>`;
      html += `<optgroup label="${escapeHtml(t('conv.slicer_catalogue') || '— Installed-slicer printers —')}"></optgroup>`;
      html += Object.keys(byV).sort().map((vendor) =>
        `<optgroup label="${escapeHtml(vendor)}">${byV[vendor].map(catOpt).join('')}</optgroup>`).join('');
    }
    const g = P.GENERIC;
    html += `<optgroup label="${escapeHtml(t('conv.other') || 'Other')}"><option value="${escapeHtml(g.id)}"${g.id === selectedId ? ' selected' : ''}>${escapeHtml(t('conv.normalize_opt') || 'Generic 3MF (strip vendor lock)')}</option></optgroup>`;
    // Printers from other ecosystems: still selectable, but produced as a Generic 3MF you open
    // in that printer's slicer. Vendor-prefixed so a bare model name isn't ambiguous.
    const optCross = (p) => { const nm = (p.vendor && !String(p.name || '').startsWith(p.vendor)) ? p.vendor + ' · ' + p.name : p.name; return `<option value="${escapeHtml(p.id)}"${p.id === selectedId ? ' selected' : ''}>${escapeHtml(nm)}</option>`; };
    const cross = [...customPrinters(), ...P.listProfiles()].filter((p) => isCrossEcosystem(sourceFlavour, p.id));
    if (cross.length) html += `<optgroup label="${escapeHtml(t('conv.other_eco') || 'Other ecosystems · saved as Generic 3MF')}">${cross.map(optCross).join('')}</optgroup>`;
    return html;
  }

  // Nearest filament you actually have in stock for a target colour (helps you know which
  // spool to load into each slot). Uses the shared colour-maths + inventory colour matcher.
  function nearestStock(hex) {
    const stock = (typeof inventory !== 'undefined' ? inventory : []).filter((i) => i && i.color && (i.weight || 0) > 0);
    if (!stock.length || typeof KhaytColor === 'undefined' || !KhaytColor.nearest) return null;
    return KhaytColor.nearest(hex, stock)[0] || null;
  }
  function stockHintHtml(hex) {
    const n = nearestStock(hex);
    if (!n) return '';
    const label = ((n.material || '') + (n.colourVariant ? ' · ' + n.colourVariant : '')).trim() || (t('conv.near_generic') || 'in stock');
    return `<span class="conv-near" title="${escapeHtml(t('conv.near_stock') || 'Nearest filament you have in stock')}">≈ ${escapeHtml(label)} <span class="conv-de">ΔE ${Math.round(n.deltaE)}</span></span>`;
  }

  // Full Spectrum applies only to a target that supports colour mixing in hardware (Snapmaker U1) when
  // the file uses MORE colours than it has slots — keep N filaments physical, reproduce the rest as
  // dithered mixes. Gate on supportsMixedFilament, NOT flavour==='orca' (single-extruder Orca-family
  // printers can't mix), and require ≥2 physical heads to mix between.
  function fsCapable(sourceFlavour, targetId, usedColours) {
    const p = getProfileById(targetId);
    return !!(p && p.supportsMixedFilament && p.maxColors >= 2 && usedColours > p.maxColors && !isCrossEcosystem(sourceFlavour, targetId));
  }

  // "65% [◼] #FFFFFF (head 1) + 35% [◼] #FF0000 (head 2)" — carries the head hex + slot as TEXT so the
  // recipe isn't colour-only (screen-reader + colourblind accessible), matching the swatch to a label.
  function fsRecipeText(mix, heads) {
    const nameOf = (id) => {
      const hd = heads[id - 1];
      if (!hd) return `<span class="conv-fs-head-ref">#${id}</span>`;
      return `${swatch(hd.hex, 12)}<span class="conv-fs-head-ref">${escapeHtml(hd.hex)} <span class="conv-fs-head-slot">(${(t('conv.fs_head') || 'head {n}').replace('{n}', id)})</span></span>`;
    };
    if (!mix.weights || mix.weights.length <= 1) return nameOf(mix.ids ? mix.ids[0] : 1);
    return mix.ids.map((id, i) => `${mix.weights[i]}% ${nameOf(id)}`).join(' + ');
  }

  // Remap table: one row per source colour → a target-slot number select (identity default).
  function remapTableHtml(filaments, maxColors) {
    if (!filaments || !filaments.length) return `<p class="conv-note">${escapeHtml(t('conv.no_colours') || 'No colours detected — geometry and settings are retargeted as-is.')}</p>`;
    const slots = Math.max(maxColors || filaments.length, filaments.length);
    const rows = filaments.map((f, i) => `
      <div class="conv-remap-row">
        ${swatch(f.color, 20)} <span class="conv-hex">${escapeHtml(String(f.color).toUpperCase())}</span>
        ${f.grams != null ? `<span class="conv-grams">${escapeHtml(String(f.grams))} g</span>` : ''}
        <span class="conv-arrow">→</span>
        <select class="conv-slot" data-i="${i}">
          ${Array.from({ length: slots }, (_, s) => `<option value="${s}"${s === i ? ' selected' : ''}>${t('conv.slot') || 'Slot'} ${s + 1}</option>`).join('')}
        </select>
        ${stockHintHtml(f.color)}
      </div>`).join('');
    return `<div class="conv-remap"><div class="conv-remap-head">${escapeHtml(t('conv.remap_hint') || 'Map each source colour to a slot on the target printer:')}</div>${rows}</div>`;
  }

  // Rich source summary from an analyze() result.
  function metaCardHtml(src, a) {
    const m = a.meta || {};
    const chip = (label, val) => val ? `<div class="conv-stat"><span class="cs-k">${escapeHtml(label)}</span><span class="cs-v">${escapeHtml(String(val))}</span></div>` : '';
    const stats = [
      chip(t('conv.src_printer') || 'Printer', m.printerModel),
      chip(t('conv.src_size') || 'Model size', fmtVol(a.bounds)),
      chip(t('conv.src_material') || 'Material', m.totalGrams ? m.totalGrams + ' g' : null),
      chip(t('conv.src_time') || 'Print time', fmtTime(m.printMinutes)),
      chip(t('conv.src_nozzle') || 'Nozzle', m.nozzle ? m.nozzle + ' mm' : null),
      chip(t('conv.src_layer') || 'Layer', m.layerHeight ? m.layerHeight + ' mm' : null),
    ].join('');
    const cols = (a.filaments || []).length
      ? `<div class="conv-src-cols">${a.filaments.map((f) => swatch(f.color, 18)).join('')}<span class="conv-src-coln">${a.filaments.length} ${escapeHtml(t('conv.colours') || 'colours')}</span></div>`
      : '';
    // filament_colour is file-wide, so the strip above is every colour in the PROJECT. On a
    // multi-plate file the plates are often different designs using different subsets — one
    // may need two spools where the file declares six. Show that rather than let the maker
    // load four colours a plate never touches.
    const platesCols = platePaletteSummaryHtml(a);
    return `
      <div class="conv-src">
        <div class="conv-src-name">${_emoI('cube', '📦')}${escapeHtml(src.name || 'model.3mf')}</div>
        <div class="conv-src-meta">${escapeHtml((t('conv.detected') || 'Detected') + ': ' + a.flavour)}</div>
        ${platesCols}
        ${stats ? `<div class="conv-stats">${stats}</div>` : ''}
        ${cols}
      </div>`;
  }

  // Live "what changes" diff for the currently-selected target.
    /**
   * A string with its fallback, for keys no locale has yet.
   *
   * `t()` returns the KEY when a string is missing, and a key is truthy — so the
   * `t('x') || 'fallback'` idiom used throughout this file silently renders
   * "CONV.PLATE_COLOURS" at the maker instead of the English. Only safe for keys that
   * exist everywhere; new ones need this.
   */
  function tf(key, fallback, params) {
    try {
      const s = (typeof t === 'function') ? t(key, params) : '';
      return (s && s !== key && !/\{[a-z_]+\}/i.test(s)) ? s : fallback;
    } catch (_) { return fallback; }
  }

  /**
   * Per-plate colour usage, when the plates genuinely differ.
   *
   * Silent for a single-plate file, and silent when every plate uses the same colours —
   * there is nothing to tell a maker who is looking at the strip already.
   */
  function platePaletteSummaryHtml(a) {
    const pp = (a && Array.isArray(a.platePalettes)) ? a.platePalettes.filter((p) => p.colors.length) : [];
    if (pp.length < 2) return '';
    const key = (p) => p.colors.join(',');
    if (new Set(pp.map(key)).size < 2) return '';   // all the same; the file-wide strip says it
    const rows = pp.map((p) => `<div class="conv-plate-row"><span class="conv-plate-n">${escapeHtml(p.name || (tf('conv.plate', 'Plate') + ' ' + (p.index + 1)))}</span>`
      + p.colors.map((c) => swatch(c, 13)).join('')
      + `<span class="conv-plate-c">${p.colors.length}</span></div>`).join('');
    const sampled = pp.some((p) => p.sampled)
      ? `<div class="conv-plate-note">${escapeHtml(tf('conv.plate_sampled',
          'Read from a thinned mesh — a colour covering very few faces may be missed.'))}</div>`
      : '';
    return `<details class="conv-plates"><summary>${escapeHtml(
      tf('conv.plate_colours', '{n} plates, each using its own colours').replace('{n}', pp.length))}</summary>${rows}${sampled}</details>`;
  }

  function changesHtml(a, targetId) {
    const P = profiles();
    const target = getProfileById(targetId) || (P && P.GENERIC);
    if (!target) return '';
    const isGeneric = P && targetId === P.GENERIC.id;
    if (isGeneric) return `<div class="conv-changes"><div class="conv-changes-h">${escapeHtml(t('conv.changes') || 'What changes')}</div><p class="conv-note">${escapeHtml(t('conv.normalize_note') || 'Vendor-locked slicer settings are stripped; geometry and colours are kept. Opens cleanly in any slicer.')}</p></div>`;
    if (isCrossEcosystem(a.flavour, targetId)) {
      const note = (t('conv.cross_note') || 'Different ecosystem — we save a clean Generic 3MF (geometry + colours kept). Open it in {t}’s slicer and pick {t}.').replace(/\{t\}/g, target.name || '');
      return `<div class="conv-changes"><div class="conv-changes-h">${escapeHtml(t('conv.changes') || 'What changes')}</div><p class="conv-note">${escapeHtml(note)}</p></div>`;
    }
    const m = a.meta || {};
    const row = (k, from, to, badge) => `<div class="conv-chg-row"><span class="conv-chg-k">${escapeHtml(k)}</span><span class="conv-chg-from">${escapeHtml(from || '—')}</span><span class="conv-arrow">→</span><span class="conv-chg-to">${escapeHtml(to || '—')}</span>${badge || ''}</div>`;
    // Bed-fit badge from the model footprint vs the target bed.
    let bedBadge = '';
    if (a.bounds && target.bed) {
      const b = target.bed, bb = a.bounds;
      const noFit = bb.x > b.x + 1 || bb.y > b.y + 1 || (b.z && bb.z > b.z + 1);
      bedBadge = noFit
        ? `<span class="conv-fit no">${_emoI('alert', '⚠', 12)}${escapeHtml(t('conv.fit_no') || 'May not fit')}</span>`
        : `<span class="conv-fit ok">✓ ${escapeHtml(t('conv.fit_ok') || 'Fits')}</span>`;
    }
    const used = (a.filaments || []).length;
    let colBadge = '';
    if (target.maxColors && used > target.maxColors) {
      // The count that matters is per PLATE. A six-colour project whose plates each use
      // three prints outright, one plate at a time; calling it "2 over" sends the maker to
      // Full Spectrum to mix colours the machine could simply have loaded.
      const pp = Array.isArray(a.platePalettes) ? a.platePalettes.filter((p) => p.colors.length) : [];
      const overPlates = pp.filter((p) => p.colors.length > target.maxColors);
      if (pp.length > 1 && !overPlates.length) {
        colBadge = `<span class="conv-fit ok">✓ ${escapeHtml(tf('conv.per_plate_fits', 'every plate fits {n}').replace('{n}', target.maxColors))}</span>`;
      } else if (pp.length > 1) {
        // Some fit, some do not. "2 over" is true of the FILE and unhelpful when 17 of 18
        // plates print as they are — it is the plate count that tells the maker what to do.
        colBadge = `<span class="conv-fit no">${_emoI('alert', '⚠', 12)}${escapeHtml(
          tf('conv.plates_over', '{k} of {n} plates over').replace('{k}', overPlates.length).replace('{n}', pp.length))}</span>`;
      } else {
        colBadge = `<span class="conv-fit no">${_emoI('alert', '⚠', 12)}${escapeHtml(tf('conv.over_slots', '{n} over').replace('{n}', used - target.maxColors))}</span>`;
      }
    }
    const rows = [
      row(t('conv.chg_printer') || 'Printer', m.printerModel, target.name),
      row(t('conv.chg_bed') || 'Bed', fmtBed(m.bed), fmtBed(target.bed), bedBadge),
      row(t('conv.chg_nozzle') || 'Nozzle', m.nozzle ? m.nozzle + ' mm' : null, target.nozzle ? target.nozzle + ' mm' : null),
      row(t('conv.chg_colours') || 'Colours', used ? String(used) : null, (t('conv.chg_slots') || '{n} slots').replace('{n}', target.maxColors || '—'), colBadge),
    ].join('');
    const prusaNote = isPrusaProject(a.flavour, target)
      ? `<p class="conv-note">${escapeHtml((t('conv.prusa_note') || 'Saved as a PrusaSlicer project for {t}: every colour goes to the tool shown below, and PrusaSlicer fills in the {t} profile. Open it with File → Open, as a project — imported as geometry, the tool colours are dropped.').replace(/\{t\}/g, target.name || ''))}</p>` : '';
    return `<div class="conv-changes"><div class="conv-changes-h">${escapeHtml(t('conv.changes') || 'What changes')}</div>${rows}${prusaNote}</div>`;
  }

  // Under a mounted 3D preview: a plate picker (multi-plate files) and a live colour strip
  // (painted files) so the maker can flip plates and see colour changes reflected instantly.
  function buildPreviewExtras(panel, ctl, mesh) {
    if (!panel || !ctl || panel.querySelector('.conv-preview-extras')) return;
    const rows = [];
    // Plate picker.
    if (Array.isArray(mesh.plates) && mesh.plates.length > 1) {
      // Default to the first plate (like a slicer) — "All plates" lays every plate's objects out
      // at their real bed positions, which looks tiny and scattered.
      const opts = mesh.plates.map((p, i) => `<option value="${i}"${i === 0 ? ' selected' : ''}>${escapeHtml(p.name || ('Plate ' + (i + 1)))}</option>`)
        .concat(`<option value="-1">${escapeHtml(t('conv.all_plates') || 'All plates')}</option>`).join('');
      rows.push(`<label class="conv-pv-plate"><span>${escapeHtml(t('conv.plate') || 'Plate')}</span><select class="conv-pv-plate-sel">${opts}</select></label>`);
    }
    // Live colour swatches (only meaningful when the model carries per-facet paint + a palette).
    const pal = ctl.hasLiveColor && ctl.hasLiveColor() ? ctl.palette() : null;
    if (pal && pal.length) {
      const sw = pal.map((hex, i) => `<input type="color" class="conv-pv-col" data-i="${i}" value="${safeCssColor(hex, '#cccccc')}" title="${escapeHtml((t('conv.filament') || 'Filament') + ' ' + (i + 1))}">`).join('');
      rows.push(`<div class="conv-pv-cols"><span class="conv-pv-cols-h">${escapeHtml(t('conv.colours') || 'colours')}</span>${sw}</div>`);
    }
    if (!rows.length) return;
    const box = document.createElement('div');
    box.className = 'conv-preview-extras';
    box.innerHTML = rows.join('');
    panel.appendChild(box);
    const sel = box.querySelector('.conv-pv-plate-sel');
    if (sel) {
      sel.addEventListener('change', () => { const i = parseInt(sel.value, 10); ctl.setPlate(i >= 0 && mesh.plates[i] ? mesh.plates[i].objs : null); });
      if (mesh.plates && mesh.plates[0]) ctl.setPlate(mesh.plates[0].objs); // start on plate 1
    }
    const cols = box.querySelectorAll('.conv-pv-col');
    if (cols.length) cols.forEach((inp) => inp.addEventListener('input', () => {
      const next = ctl.palette() || [];
      cols.forEach((c) => { next[+c.dataset.i] = c.value; });
      ctl.recolor(next);
    }));
  }

  // Decide what to show in a preview panel from a convertMesh() result:
  //   3D mesh  → interactive viewer
  //   no mesh but an embedded slicer thumbnail → show that 2D image (always-load fallback)
  //   nothing  → a small "unavailable" note (never blocks converting)
  function renderPreviewInto(panel, canvasEl, mesh, fallbackColors) {
    if (!panel) return;
    const hint = panel.querySelector('.conv-preview-hint');
    if (mesh && mesh.ok && mesh.verts && mesh.count) {
      const cols = (mesh.colors && mesh.colors.length) ? mesh.colors : (fallbackColors || []);
      const ctl = mountMeshViewer(canvasEl, { verts: mesh.verts, count: mesh.count, colors: cols, triColors: mesh.triColors, triObj: mesh.triObj, triCode: mesh.triCode, palette: mesh.palette });
      if (hint) hint.textContent = t('conv.preview_hint2') || 'Drag · scroll to zoom';
      // Plate picker (multi-plate Bambu/Orca files) + live colour swatches (painted files).
      buildPreviewExtras(panel, ctl, mesh);
      // Control bar: preset angles, spin, reset, and expand to the big viewer.
      if (!panel.querySelector('.conv-preview-ctrls')) {
        const bar = document.createElement('div');
        bar.className = 'conv-preview-ctrls';
        const b = (act, lbl, cls) => `<button type="button" class="btn ghost small${cls || ''}" data-pv="${act}">${escapeHtml(lbl)}</button>`;
        bar.innerHTML = b('iso', t('view3d.iso') || 'Iso') + b('front', t('view3d.front') || 'Front') + b('top', t('view3d.top') || 'Top') + b('side', t('view3d.side') || 'Side')
          // Wireframe only exists on the software mesh path; the GPU (depth-buffered) viewer doesn't offer
          // it, so hide the button there instead of showing a dead control.
          + `<span class="conv-preview-sp"></span>` + (ctl._webgl ? '' : b('wire', '▦', ' pv-icon')) + b('spin', '↻', ' pv-icon') + b('reset', '⤾', ' pv-icon') + b('expand', '⤢', ' pv-icon');
        panel.appendChild(bar);
        bar.querySelectorAll('[data-pv]').forEach((btn) => btn.addEventListener('click', () => {
          const a = btn.dataset.pv;
          if (a === 'spin') btn.classList.toggle('on', ctl.toggleSpin());
          else if (a === 'wire') btn.classList.toggle('on', ctl.toggleWire());
          else if (a === 'reset') { ctl.reset(); const s = bar.querySelector('[data-pv="spin"]'); if (s) s.classList.remove('on'); }
          else if (a === 'expand') { if (typeof openModelViewer === 'function') openModelViewer({ verts: mesh.verts, count: mesh.count, colors: cols, triColors: mesh.triColors, triObj: mesh.triObj, triCode: mesh.triCode, palette: mesh.palette, plates: mesh.plates, bbox: mesh.bbox, volumeMm3: mesh.volumeMm3, name: '' }); }
          else { ctl.setView(a); const s = bar.querySelector('[data-pv="spin"]'); if (s) s.classList.remove('on'); }
        }));
      }
      return ctl;
    }
    if (canvasEl) canvasEl.style.display = 'none';
    if (mesh && mesh.thumb) {
      const img = document.createElement('img');
      img.className = 'conv-preview-canvas conv-preview-img';
      img.alt = 'preview'; img.src = mesh.thumb;
      if (canvasEl && canvasEl.parentNode) canvasEl.parentNode.insertBefore(img, canvasEl);
      // Be honest about why there's no rotate/zoom here: we couldn't read this file's geometry,
      // so we're showing the slicer's own baked-in picture instead of the interactive model.
      if (hint) hint.textContent = t('conv.preview_thumb') || 'Couldn’t read 3D geometry — showing the slicer’s own preview image (no rotate/zoom).';
      try { console.warn('[converter] 3D geometry unavailable, using embedded thumbnail:', mesh && mesh.error); } catch (_) {}
      return;
    }
    if (mesh && mesh.error) try { console.warn('[converter] preview mesh unavailable:', mesh.error); } catch (_) {}
    if (hint) hint.textContent = t('conv.preview_none') || 'Preview unavailable — you can still convert.';
  }

  // A lightweight "see what you're converting" step for the one-click STL↔3MF actions:
  // shows a live 3D preview of the picked file, then runs onConfirm when the user proceeds.
  function previewConfirm({ path, name, title, confirmLabel, note, onConfirm }) {
    const h = hub();
    const canPreview = typeof mountMeshViewer === 'function' && h && !!h.convertMesh;
    const body = `
      <div class="conv-src"><div class="conv-src-name">${_emoI('cube', '📦')}${escapeHtml(name || 'model')}</div>${note ? `<div class="conv-src-meta">${escapeHtml(note)}</div>` : ''}</div>
      ${canPreview ? `
      <div id="pcPreview" class="conv-preview">
        <canvas id="pcPreviewCanvas" width="320" height="320" class="conv-preview-canvas" aria-label="3D preview"></canvas>
        <div class="conv-preview-hint">${escapeHtml(t('conv.preview_loading') || 'Loading 3D preview…')}</div>
      </div>` : `<p class="conv-note">${escapeHtml(t('conv.preview_none') || 'Preview unavailable — you can still convert.')}</p>`}`;
    openFormModal({
      title, bodyHtml: body, saveLabel: confirmLabel,
      onMount(modal) {
        const c = modal.querySelector('#pcPreviewCanvas');
        if (c && h.convertMesh) {
          h.convertMesh({ path })
            .then((m) => renderPreviewInto(modal.querySelector('#pcPreview'), c, m))
            .catch((e) => renderPreviewInto(modal.querySelector('#pcPreview'), c, { error: String((e && e.message) || e) }));
        }
      },
      onSave() { Promise.resolve().then(onConfirm); return true; },
    });
  }

  /* ---------------- One plate of a multi-plate project (lib/plates.js) ----------------
   * A Bambu/Orca project with several plates gets a picker: each plate's thumbnail, name,
   * object count and colours, with "Convert this plate" (split it out, then run this same
   * converter on the split file) and "Save this plate as a 3MF". The whole-file conversion
   * below it is unchanged. Splitting happens in the main process; this only asks.
   */
  function platesOf(src) {
    const h = hub();
    if (!h || !h.mfPlates || src.fromPlate) return Promise.resolve(null);
    return h.mfPlates(src.path)
      .then((r) => (r && r.ok && Array.isArray(r.plates) && r.plates.length > 1 ? r.plates : null))
      .catch(() => null);
  }

  function plateLabel(p) {
    const n = tf('conv.plate_n', 'Plate {n}').replace('{n}', p.index);
    return p.name ? `${n} · ${p.name}` : n;
  }

  function platePickerHtml(plates) {
    const cards = plates.map((p) => {
      const thumb = p.thumbnail && /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(p.thumbnail)
        ? `<img class="conv-pp-thumb" alt="" src="${p.thumbnail}">`
        : `<div class="conv-pp-thumb conv-pp-nothumb">${_emoI('cube', '📦', 22)}</div>`;
      const cols = (p.colors || []).map((c) => swatch(c, 12)).join('');
      const approx = p.colorsApprox && cols
        ? `<span class="conv-pp-approx" title="${escapeHtml(tf('conv.plate_colours_approx', 'Read from object settings — painted colours may be missing.'))}">≈</span>` : '';
      const why = p.problem
        ? `<div class="conv-pp-why">${escapeHtml(p.problem.code === 'shared-object'
          ? tf('conv.plate_shared', 'This plate shares an object with another plate, so it can’t be split out on its own.')
          : tf('conv.plate_cannot', 'This plate can’t be split out on its own.'))}</div>` : '';
      const dis = p.splittable ? '' : ' disabled';
      return `<div class="conv-pp-card" data-plate="${p.index}">
        ${thumb}
        <div class="conv-pp-body">
          <div class="conv-pp-name">${escapeHtml(plateLabel(p))}</div>
          <div class="conv-pp-meta">${escapeHtml(tf('conv.plate_objects', 'Objects: {n}').replace('{n}', p.objectCount))}<span class="conv-pp-cols">${cols}${approx}</span></div>
          ${why}
          <div class="conv-pp-act">
            <button type="button" class="btn small" data-pp="convert" data-plate="${p.index}"${dis}>${escapeHtml(tf('conv.plate_convert', 'Convert this plate'))}</button>
            <button type="button" class="btn small ghost" data-pp="save" data-plate="${p.index}"${dis}>${escapeHtml(tf('conv.plate_save', 'Save this plate as a 3MF'))}</button>
          </div>
        </div>
      </div>`;
    }).join('');
    return `<div class="conv-pp">
      <div class="conv-pp-head">${escapeHtml(tf('conv.plates_title', '{n} plates — convert or save one on its own').replace('{n}', plates.length))}</div>
      <p class="conv-pp-hint">${escapeHtml(tf('conv.plates_hint', 'Each plate becomes a 3MF of its own, with just its objects and the project’s colours.'))}</p>
      <div class="conv-pp-grid">${cards}</div>
    </div>`;
  }

  /** Wire a rendered picker. `leave()` closes whatever modal it sits in before the next one opens. */
  function wirePlatePicker(root, src, plates, leave) {
    if (!root) return;
    const reset = () => root.querySelectorAll('[data-pp]').forEach((b) => {
      const q = plates.find((x) => x.index === parseInt(b.dataset.plate, 10));
      b.disabled = !(q && q.splittable);
    });
    const fail = (r) => {
      toast(r && r.code === 'shared-object'
        ? tf('conv.plate_shared', 'This plate shares an object with another plate, so it can’t be split out on its own.')
        : tf('conv.plate_cannot', 'This plate can’t be split out on its own.'), 'error', 5600);
      if (r && r.error) try { console.warn('[converter] plate split refused:', r.code, r.error); } catch (_) {}
    };
    root.querySelectorAll('[data-pp]').forEach((btn) => btn.addEventListener('click', async () => {
      const index = parseInt(btn.dataset.plate, 10);
      if (!plates.some((x) => x.index === index)) return;
      const h = hub();
      root.querySelectorAll('[data-pp]').forEach((b) => { b.disabled = true; });
      toast(tf('conv.plate_extracting', 'Splitting out plate {n}…').replace('{n}', index), 'info', 1600);
      try {
        if (btn.dataset.pp === 'save') {
          const r = await h.mfPlateSave(src.path, index);
          if (r && r.ok) toast(tf('conv.plate_saved', 'Plate {n} saved as its own 3MF.').replace('{n}', index), 'success', 3200);
          else if (!(r && r.canceled)) fail(r);
        } else {
          const r = await h.mfPlateExtract(src.path, index);
          if (r && r.ok) {
            if (typeof leave === 'function') leave();
            openConverter({ path: r.path, name: r.name, recordId: src.recordId, fromPlate: index });
            return;
          }
          fail(r);
        }
      } catch (e) { toast(String((e && e.message) || e), 'error'); }
      reset();
    }));
  }

  /** The file could not be analysed whole, but it has plates: offer those on their own. */
  function openPlatePicker(src, plates, note) {
    openFormModal({
      title: `${_titleIco}${tf('conv.plate_pick_title', 'Pick a plate')}`,
      bodyHtml: `<div class="conv-src"><div class="conv-src-name">${_emoI('cube', '📦')}${escapeHtml(src.name || 'model.3mf')}</div>${note ? `<div class="conv-pp-note">${escapeHtml(note)}</div>` : ''}</div>${platePickerHtml(plates)}`,
      noSave: true,
      onMount(modal) {
        const leave = () => { const c = modal.querySelector('[data-act="cancel"]'); if (c) c.click(); };
        wirePlatePicker(modal, src, plates, leave);
      },
    });
  }

  /** A refusal from the engine, in the maker's language where we have it. */
  function convertErrorText(r) {
    if (r && r.code === 'too_large') return tf('conv.plate_too_large', 'This file is too large to convert in one piece. If it has several plates, pick one in the plate list to convert or save it on its own.');
    return (r && r.error) || (t('conv.failed') || 'Conversion failed.');
  }
  /* ---------------- end one plate ---------------- */

  async function openConverter(src) {
    const h = hub();
    if (!h || !h.mfAnalyze) { toast(t('conv.desktop_only') || 'The converter is available in the desktop app.', 'error'); return; }
    toast(t('conv.analyzing') || 'Analyzing 3MF…', 'info', 1400);
    const platesP = platesOf(src);
    let a;
    try { a = await h.mfAnalyze(src.path); } catch (e) { toast(String((e && e.message) || e), 'error'); return; }
    if (!a || !a.ok) {
      const plates = await platesP;
      if (plates) { openPlatePicker(src, plates, (a && a.error) || ''); return; }
      toast((a && a.error) || (t('conv.analyze_failed') || 'Could not read that 3MF.'), 'error');
      return;
    }

    const P = profiles();
    const filaments = a.filaments || [];
    let targetId = firstCompatibleId(a.flavour);

    function currentMax(id) { const p = getProfileById(id); return p ? p.maxColors : filaments.length; }

    const crossNote = (a.flavour && a.flavour !== 'generic')
      ? `<p class="conv-tip">${escapeHtml((t('conv.family_note') || 'Same-ecosystem printers keep their slicer settings. Printers from other ecosystems are listed too — pick one and it’s saved as a Generic 3MF you open in that printer’s slicer.').replace('{f}', a.flavour))}</p>`
      : '';

    const canPreview = typeof mountMeshViewer === 'function' && !!h.convertMesh;
    const body = `
      ${metaCardHtml(src, a)}
      <div id="convPlatesWrap"></div>
      ${canPreview ? `
      <div id="convPreview" class="conv-preview">
        <canvas id="convPreviewCanvas" width="300" height="300" class="conv-preview-canvas" aria-label="3D preview"></canvas>
        <div class="conv-preview-hint">${escapeHtml(t('conv.preview_loading') || 'Loading 3D preview…')}</div>
      </div>` : ''}
      <label class="conv-label">${escapeHtml(t('conv.target') || 'Target printer')}</label>
      <select id="convTarget" class="conv-target">${targetOptions(targetId, a.flavour)}</select>
      ${crossNote}
      <div class="conv-presets">
        <select id="convPresetApply" class="conv-target"><option value="">${escapeHtml(t('conv.preset_apply') || 'Apply a preset…')}</option>${presetOptions(a.flavour)}</select>
        <input id="convPresetName" class="conv-preset-name" type="text" maxlength="40" placeholder="${escapeHtml(t('conv.preset_name') || 'Preset name')}">
        <button type="button" class="btn small ghost" id="convPresetSave">★ ${escapeHtml(t('conv.preset_save') || 'Save')}</button>
      </div>
      <div id="convChanges">${changesHtml(a, targetId)}</div>
      <div id="convBandWrap"></div>
      <div id="convFsWrap"></div>
      <div id="convPrusaWrap"></div>
      <div id="convFilamentWrap"></div>
      <div id="convRemapWrap">${remapTableHtml(filaments, currentMax(targetId))}</div>
      <div class="conv-dest">
        <div class="conv-dest-q">${escapeHtml(t('conv.dest_q') || 'Where should the converted file go?')}</div>
        <label class="conv-dest-opt"><input type="radio" name="convDest" value="library" checked> ${escapeHtml(src.recordId ? (t('conv.dest_this') || 'Keep it with this print file') : (t('conv.dest_new') || 'Add it to my Print-File library'))}</label>
        <label class="conv-dest-opt"><input type="radio" name="convDest" value="folder"> ${escapeHtml(t('conv.dest_folder') || 'Save to a folder…')}</label>
      </div>`;

    openFormModal({
      title: `${_titleIco}${t('conv.title') || 'Convert 3MF'}`,
      bodyHtml: body,
      saveLabel: t('conv.convert') || 'Convert & save…',
      onMount(modal) {
        // Multi-plate project: the plate picker sits above the whole-file options.
        platesP.then((plates) => {
          const box = plates && modal.isConnected ? modal.querySelector('#convPlatesWrap') : null;
          if (!box) return;
          box.innerHTML = platePickerHtml(plates);
          wirePlatePicker(box, src, plates, () => { const c = modal.querySelector('[data-act="cancel"]'); if (c) c.click(); });
        });
        const sel = modal.querySelector('#convTarget');
        const wrap = modal.querySelector('#convRemapWrap');
        const chg = modal.querySelector('#convChanges');
        const fsWrap = modal.querySelector('#convFsWrap');
        const bandWrap = modal.querySelector('#convBandWrap');
        const filWrap = modal.querySelector('#convFilamentWrap');
        let fsEnabled = false, fsPlanData = null;
        // Band-swap: an exact-colour alternative to Full Spectrum, offered only when the source model is
        // detected as cleanly vertically colour-banded. bandData is a property of the MODEL (not the target),
        // so it's fetched once per file; paintBand() re-checks target eligibility.
        let bandEnabled = false, bandData = null;

        // Filament + process presets from the maker's installed Snapmaker Orca (loaded once, lazily).
        let orcaFilaments = null, orcaProcesses = [], procPick = null, orcaLoaded = false, filPicks = {};
        async function ensureOrcaFilaments() {
          if (orcaLoaded) return;
          orcaLoaded = true;
          try {
            const r = await hub().orcaFilaments();
            orcaFilaments = (r && r.available && r.filaments) ? r.filaments : [];
            orcaProcesses = (r && r.available && r.processes) ? r.processes : [];
            procPick = (r && r.defaultProcess) || null;
          } catch (_) { orcaFilaments = []; orcaProcesses = []; }
          paintFilaments();
        }

        // For an Orca (U1-class) target, let the maker say which real filament sits in each slot so the
        // converted file references presets their slicer knows (no "customized preset" warning) and
        // carries the right material. Falls back silently when no slicer DB is found.
        function paintFilaments() {
          if (!filWrap) return;
          const p = getProfileById(targetId);
          // The curated filament list + print-quality presets are the Snapmaker U1's; other catalogue
          // printers still convert natively (their default process + Generic filaments), just without this
          // picker. Gate to the built-in U1 so we never show U1 filament names for a different printer.
          const isOrca = p && p.id === 'snapmaker-u1' && !isCrossEcosystem(a.flavour, targetId);
          if (!isOrca) { filWrap.innerHTML = ''; return; }
          if (orcaFilaments == null) { ensureOrcaFilaments(); filWrap.innerHTML = `<div class="conv-fs-loading">${escapeHtml(t('conv.fil_loading') || 'Reading your slicer’s filament list…')}</div>`; return; }
          // Slots = the physical heads (FS) or the mapped colours, capped at the target's slot count.
          const slotCount = fsEnabled && fsPlanData ? fsPlanData.heads.length : Math.min(filaments.length, p.maxColors || filaments.length);
          const slotHex = (i) => (fsEnabled && fsPlanData) ? fsPlanData.heads[i].hex : ((filaments[i] && filaments[i].color) || '#CCCCCC');
          if (!slotCount) { filWrap.innerHTML = ''; return; }
          // Group DB presets by material type for tidy <optgroup>s.
          const groups = {};
          (orcaFilaments || []).forEach((f) => { (groups[f.type] = groups[f.type] || []).push(f); });
          const optionsFor = (sel) => {
            const gen = `<option value=""${!sel ? ' selected' : ''}>${escapeHtml(t('conv.fil_generic') || 'Generic (auto)')}</option>`;
            const body = Object.keys(groups).sort().map((type) =>
              `<optgroup label="${escapeHtml(type)}">${groups[type].map((f) =>
                `<option value="${escapeHtml(f.name)}" data-type="${escapeHtml(f.type)}"${sel === f.name ? ' selected' : ''}>${escapeHtml(f.name)}</option>`).join('')}</optgroup>`).join('');
            return gen + body;
          };
          const dbNote = (orcaFilaments && orcaFilaments.length)
            ? (t('conv.fil_hint') || 'Pick the filament loaded in each slot (from your Snapmaker Orca library):')
            : (t('conv.fil_none') || 'Install Snapmaker Orca to pick specific filaments; slots default to Generic.');
          const rows = Array.from({ length: slotCount }, (_, i) =>
            `<label class="conv-fil-row"><span class="conv-fil-slot">${swatch(slotHex(i), 16)} ${escapeHtml((t('conv.slot') || 'Slot') + ' ' + (i + 1))}</span>
              <select class="conv-fil-sel" data-slot="${i}"${(orcaFilaments && orcaFilaments.length) ? '' : ' disabled'}>${optionsFor(filPicks[i] && filPicks[i].name)}</select></label>`).join('');
          // Print-quality (process) preset — its layer height etc. become the file's U1-native settings.
          const procRow = (orcaProcesses && orcaProcesses.length) ? `
            <label class="conv-fil-row"><span class="conv-fil-slot">${escapeHtml(t('conv.print_quality') || 'Print quality')}</span>
              <select class="conv-proc-sel">${orcaProcesses.map((p) =>
                `<option value="${escapeHtml(p.name)}"${procPick === p.name ? ' selected' : ''}>${escapeHtml(p.name.replace(/ @Snapmaker U1.*/i, ''))}${p.layer ? ` (${escapeHtml(p.layer)} mm)` : ''}</option>`).join('')}</select></label>` : '';
          filWrap.innerHTML = `<div class="conv-fil"><div class="conv-fil-head">${escapeHtml(dbNote)}</div>${rows}${procRow}</div>`;
          Array.from(filWrap.querySelectorAll('.conv-fil-sel')).forEach((sel) => {
            sel.onchange = () => {
              const i = parseInt(sel.dataset.slot, 10);
              const opt = sel.options[sel.selectedIndex];
              filPicks[i] = sel.value ? { name: sel.value, type: opt.dataset.type || 'PLA' } : null;
            };
          });
          const procSel = filWrap.querySelector('.conv-proc-sel');
          if (procSel) procSel.onchange = () => { procPick = procSel.value || null; };
        }
        modal._filPicks = () => filPicks;
        modal._procPick = () => procPick;

        // Ask the main process to plan the physical heads + mixes for the current target.
        async function loadFsPlan() {
          fsPlanData = null;
          const reqTarget = targetId; // guard against the user switching target mid-flight
          try {
            const r = await hub().fsPlan({ path: src.path, targetId, targetProfile: isCustomId(targetId) ? getProfileById(targetId) : null });
            if (targetId !== reqTarget) return; // a newer target won — drop this stale plan
            if (r && r.available) fsPlanData = r;
          } catch (_) { /* best-effort */ }
          if (targetId !== reqTarget) return;
          paintFs();
          paintFilaments();
        }

        function paintFs() {
          if (!fsWrap) return;
          const usedColours = filaments.length;
          if (!fsCapable(a.flavour, targetId, usedColours)) { fsWrap.innerHTML = ''; fsEnabled = false; if (wrap) wrap.style.display = ''; return; }
          const p = getProfileById(targetId);
          const extra = usedColours - p.maxColors;
          const label = (t('conv.fs_toggle') || 'Use Full Spectrum — reproduce {n} extra colour(s) by mixing').replace('{n}', extra);
          let planHtml = '';
          if (fsEnabled) {
            if (!fsPlanData) planHtml = `<div class="conv-fs-loading">${escapeHtml(t('conv.fs_planning') || 'Planning colour mixes…')}</div>`;
            else {
              const heads = fsPlanData.heads.map((hd) => `<div class="conv-fs-head">${swatch(hd.hex, 20)}<span>${escapeHtml(hd.hex)}</span></div>`).join('');
              const mixes = fsPlanData.mixes.length
                ? fsPlanData.mixes.map((mx) => `<div class="conv-fs-mix">${swatch(mx.srcHex, 16)} → ${fsRecipeText(mx, fsPlanData.heads)} <span class="conv-fs-de">ΔE ${mx.deltaE}</span></div>`).join('')
                : `<div class="conv-fs-mix">${escapeHtml(t('conv.fs_no_mix') || 'All colours fit as pure filaments.')}</div>`;
              planHtml = `<div class="conv-fs-plan">
                  <div class="conv-fs-sub">${escapeHtml(t('conv.fs_load') || 'Load these filaments:')}</div>
                  <div class="conv-fs-heads">${heads}</div>
                  <div class="conv-fs-sub">${escapeHtml(t('conv.fs_mixes') || 'Printed by mixing:')}</div>
                  <div class="conv-fs-mixes">${mixes}</div>
                </div>`;
            }
          }
          fsWrap.innerHTML = `<label class="conv-fs-toggle"><input type="checkbox" id="convFsOn"${fsEnabled ? ' checked' : ''}> ${escapeHtml(label)}</label>${planHtml}`;
          const cb = fsWrap.querySelector('#convFsOn');
          if (cb) cb.onchange = () => {
            fsEnabled = cb.checked;
            if (fsEnabled) { bandEnabled = false; paintBand(); } // mutually exclusive with band-swap
            if (fsEnabled && !fsPlanData) { paintFs(); loadFsPlan(); } else paintFs();
            paintFilaments();
          };
          // Full Spectrum owns the colour mapping — hide the manual remap table while it's on.
          if (wrap) wrap.style.display = fsEnabled ? 'none' : '';
        }
        // Expose current FS state to onSave.
        modal._fsState = () => ({ enabled: fsEnabled, plan: fsPlanData });

        // Ask the main process (once) whether this model is cleanly vertically colour-banded.
        async function loadBandPlan() {
          if (bandData || !hub().mfBands) return;
          try { bandData = await hub().mfBands(src.path); } catch (_) { bandData = { available: false }; }
          paintBand();
        }

        // Offer band-swap when the model is banded AND the target is a swap-capable printer (U1) carrying
        // more colours than heads — the same situation where Full Spectrum would otherwise mix. Band-swap
        // keeps every colour EXACT via M600 pauses; it's mutually exclusive with Full Spectrum.
        function paintBand() {
          if (!bandWrap) return;
          const p = getProfileById(targetId);
          const usedColours = filaments.length;
          const eligible = bandData && bandData.available && bandData.banded
            && p && p.supportsMixedFilament && p.maxColors >= 2 && usedColours > p.maxColors
            && !isCrossEcosystem(a.flavour, targetId);
          if (!eligible) { bandWrap.innerHTML = ''; if (bandEnabled) { bandEnabled = false; } return; }
          const swaps = bandData.manualSwaps || 0;
          const label = (t('conv.band_toggle') || 'Colour-banded model — print all {n} colours exactly with {s} filament swap(s), no mixing')
            .replace('{n}', usedColours).replace('{s}', swaps);
          let detail = '';
          if (bandEnabled) {
            const rows = (bandData.instructions || []).length
              ? bandData.instructions.map((s) => `<div class="conv-fs-mix">${swatch(s.toColour || '#CCCCCC', 16)} <span>${escapeHtml((t('conv.band_swap_at') || 'Swap on head {h} at {z} mm').replace('{h}', s.toolhead).replace('{z}', Math.round(s.z * 10) / 10))}</span></div>`).join('')
              : `<div class="conv-fs-mix">${escapeHtml(t('conv.band_no_swap') || 'No manual swap needed — every colour fits a head.')}</div>`;
            detail = `<div class="conv-fs-plan">
                <div class="conv-fs-sub">${escapeHtml(t('conv.band_pauses') || 'The app adds an M600 pause at each swap height:')}</div>
                <div class="conv-fs-mixes">${rows}</div>
              </div>`;
          }
          bandWrap.innerHTML = `<label class="conv-fs-toggle"><input type="checkbox" id="convBandOn"${bandEnabled ? ' checked' : ''}> ${escapeHtml(label)}</label>${detail}`;
          const cb = bandWrap.querySelector('#convBandOn');
          if (cb) cb.onchange = () => {
            bandEnabled = cb.checked;
            if (bandEnabled) { fsEnabled = false; } // mutually exclusive with Full Spectrum
            paintBand();
            if (fsWrap) fsWrap.style.display = bandEnabled ? 'none' : '';
            paintFs();
            if (wrap) wrap.style.display = (bandEnabled || fsEnabled) ? 'none' : '';
            paintFilaments();
          };
          // Band-swap owns the colour mapping — hide the manual remap + FS panels while it's on.
          if (fsWrap) fsWrap.style.display = bandEnabled ? 'none' : '';
          if (wrap) wrap.style.display = (bandEnabled || fsEnabled) ? 'none' : '';
        }
        // Expose current band-swap state to onSave.
        modal._bandState = () => ({ enabled: bandEnabled, plan: bandData });

        // Bambu/Orca → PrusaSlicer project: the plan the convert will run, re-asked whenever the target,
        // the slot map or ColorMix changes. With more colours than tools the colours are merged (and,
        // on a ColorMix printer, optionally blended), so the manual slot table steps aside.
        const prusaWrap = modal.querySelector('#convPrusaWrap');
        let prusaMix = false, prusaPlanData = null, prusaSeq = 0;
        const prusaMerges = () => { const p = getProfileById(targetId); return !!p && filaments.length > (p.maxColors || 1); };
        async function loadPrusaPlan() {
          const seq = ++prusaSeq;
          prusaPlanData = null;
          paintPrusa();
          let slotMap = null;
          if (!prusaMerges()) {
            slotMap = Array.from(modal.querySelectorAll('.conv-slot')).map((s) => parseInt(s.value, 10) || 0);
            if (slotMap.every((v, i) => v === i)) slotMap = null;
          }
          let r = null;
          try {
            r = await hub().prusaPlan({ path: src.path, targetId, targetProfile: isCustomId(targetId) ? getProfileById(targetId) : null, slotMap, colorMix: prusaMix });
          } catch (e) { r = { available: true, ok: false, error: String((e && e.message) || e) }; }
          if (seq !== prusaSeq) return; // a newer target / map won
          prusaPlanData = r && r.available ? r : null;
          paintPrusa();
        }
        function paintPrusa() {
          if (!prusaWrap) return;
          const p = getProfileById(targetId);
          if (!isPrusaProject(a.flavour, targetId) || !hub().prusaPlan) { prusaWrap.innerHTML = ''; prusaMix = false; return; }
          const offerMix = !!(p && p.prusaColorMix) && prusaMerges();
          if (!offerMix) prusaMix = false;
          const mix = offerMix
            ? `<label class="conv-fs-toggle"><input type="checkbox" id="convPrusaMix"${prusaMix ? ' checked' : ''}> <span>${escapeHtml(t('conv.prusa_colormix') || 'Mix colours no tool holds (ColorMix)')}<br><small class="muted">${escapeHtml(t('conv.prusa_colormix_hint') || 'A colour with no close tool prints as a blend of two or three loaded tools, alternated layer by layer, in PrusaSlicer’s own FullSpectrum format. More tool changes.')}</small></span></label>` : '';
          prusaWrap.innerHTML = mix + prusaPlanHtml(prusaPlanData);
          const cb = prusaWrap.querySelector('#convPrusaMix');
          if (cb) cb.onchange = () => { prusaMix = cb.checked; loadPrusaPlan(); };
          if (wrap) wrap.style.display = prusaMerges() ? 'none' : '';
        }
        if (wrap) wrap.addEventListener('change', (e) => { if (e.target && e.target.classList && e.target.classList.contains('conv-slot') && isPrusaProject(a.flavour, targetId)) loadPrusaPlan(); });
        modal._prusaState = () => ({ on: isPrusaProject(a.flavour, targetId), colorMix: prusaMix, merges: prusaMerges() });

        // 3D preview of the source model — "know what you're converting". Best-effort:
        // if the mesh can't be read, quietly drop the panel rather than block the convert.
        const pvCanvas = modal.querySelector('#convPreviewCanvas');
        let previewCtl = null, previewBbox = null;
        // Bed Ready signature: a drafting "redline" overlay on the preview when the model overruns the
        // target bed — a red dashed frame + an OUT OF BED tag with the overage per axis. No-op in Khayt
        // (which keeps the reddened bed grid + the "May not fit" badge from changesHtml).
        const paintRedline = (host, on, overX, overY) => {
          if (!host) return;
          let el = host.querySelector('.conv-redline');
          if (!on || !_bdr) { if (el) el.remove(); return; }
          if (!el) { el = document.createElement('div'); el.className = 'conv-redline'; host.appendChild(el); }
          const parts = [];
          if (overX > 1) parts.push('X +' + Math.ceil(overX));
          if (overY > 1) parts.push('Y +' + Math.ceil(overY));
          el.innerHTML = `<span class="conv-redline-tag">${_emoI('alert', '⚠', 12)}OUT OF BED</span>`
            + (parts.length ? `<span class="conv-redline-dim">${escapeHtml(parts.join(' · ') + ' mm')}</span>` : '');
        };
        // Lay the TARGET printer's bed under the model so you see scale, orientation and fit.
        const applyBed = () => {
          if (!previewCtl || !previewBbox) return;
          const host = modal.querySelector('#convPreview');
          const p = getProfileById(targetId);
          if (!p || !p.bed || !p.bed.x) { previewCtl.setBed(null); paintRedline(host, false); return; }
          const overX = previewBbox.x - p.bed.x, overY = previewBbox.y - p.bed.y;
          const fits = !(overX > 1 || overY > 1);
          previewCtl.setBed({ x: p.bed.x, y: p.bed.y, fits });
          paintRedline(host, !fits, overX, overY);
        };
        if (pvCanvas && h.convertMesh) {
          h.convertMesh({ path: src.path })
            .then((mesh) => { previewBbox = mesh && mesh.bbox; previewCtl = renderPreviewInto(modal.querySelector('#convPreview'), pvCanvas, mesh, filaments.map((f) => f.color).filter(Boolean)); applyBed(); })
            .catch((e) => renderPreviewInto(modal.querySelector('#convPreview'), pvCanvas, { error: String((e && e.message) || e) }));
        }
        const renderForTarget = () => {
          const asGeneric = (P && targetId === P.GENERIC.id) || isCrossEcosystem(a.flavour, targetId);
          if (chg) chg.innerHTML = changesHtml(a, targetId);
          wrap.innerHTML = asGeneric
            ? `<p class="conv-note">${escapeHtml(t('conv.normalize_note') || 'Vendor-locked slicer settings are stripped; geometry and colours are kept. Opens cleanly in any slicer.')}</p>`
            : remapTableHtml(filaments, currentMax(targetId));
          // Target changed → drop any stale Full Spectrum plan and re-evaluate for the new printer.
          fsEnabled = false; fsPlanData = null; filPicks = {}; bandEnabled = false;
          paintFs();
          paintBand();
          paintFilaments();
          prusaMix = false;
          if (isPrusaProject(a.flavour, targetId)) loadPrusaPlan(); else paintPrusa();
          applyBed();
          return asGeneric;
        };
        // Resolve a catalogue printer's full profile (bed, slots, native machine) the first time it's
        // picked, caching it under its orca:<name> id, then render for it.
        async function ensureOrcaProfile(id) {
          const name = orcaNameFromId(id);
          if (!name || _orcaProfileCache[name]) return;
          try {
            const r = await hub().orcaMachineInfo(name);
            if (r && r.ok && r.info) {
              const info = r.info;
              _orcaProfileCache[name] = {
                id, name: info.printerModel || name, vendor: ((_orcaPrinters || []).find((p) => p.name === name) || {}).vendor || '',
                flavour: 'orca', bed: info.bed, nozzle: info.nozzle, maxColors: info.colors,
                orcaMachine: name, printableArea: info.printableArea, printableHeight: info.printableHeight,
                printerModel: info.printerModel, printerSettingsId: name,
                process: r.defaultProcess || info.defaultProcess || null,
                system: info.colors > 1 ? info.colors + '-colour' : '', fromOrca: true,
              };
            }
          } catch (_) { /* best-effort */ }
        }
        if (sel) sel.onchange = async () => {
          targetId = sel.value;
          if (isOrcaId(targetId) && !getProfileById(targetId)) {
            if (chg) chg.innerHTML = `<div class="conv-fs-loading">${escapeHtml(t('conv.printer_loading') || 'Reading printer profile…')}</div>`;
            await ensureOrcaProfile(targetId);
          }
          renderForTarget();
        };
        // Load the installed-slicer printer catalogue, then fold it into the target dropdown.
        if (hub().orcaPrinters) {
          hub().orcaPrinters().then((r) => {
            if (r && r.available && Array.isArray(r.printers) && r.printers.length) {
              _orcaPrinters = r.printers;
              if (sel) sel.innerHTML = targetOptions(targetId, a.flavour);
            }
          }).catch(() => {});
        }
        paintFs();
        paintFilaments();
        loadBandPlan();
        // ── SPOOL MATCH (renderer/converter-spools.js): "Match to loaded spools" ──
        if (typeof KhaytConvSpools !== 'undefined') {
          KhaytConvSpools.mount(modal, {
            filaments, flavour: a.flavour, targetId: () => targetId, profile: getProfileById,
            skip: () => (P && targetId === P.GENERIC.id) || isCrossEcosystem(a.flavour, targetId),
          });
        }
        if (isPrusaProject(a.flavour, targetId)) loadPrusaPlan();

        // Apply a saved preset: set the target and, when the slot map fits this file's colours, the mapping.
        const applySel = modal.querySelector('#convPresetApply');
        if (applySel) applySel.onchange = () => {
          const preset = convPresets().find((p) => p.id === applySel.value);
          applySel.value = '';
          if (!preset) return;
          targetId = preset.targetId;
          if (sel) sel.value = targetId;
          const isGeneric = renderForTarget();
          if (!isGeneric && Array.isArray(preset.slotMap) && preset.slotMap.length === filaments.length) {
            Array.from(wrap.querySelectorAll('.conv-slot')).forEach((s, i) => { if (preset.slotMap[i] != null) s.value = String(preset.slotMap[i]); });
          }
        };

        // Save the current target + slot mapping as a reusable preset.
        const saveBtn = modal.querySelector('#convPresetSave');
        if (saveBtn) saveBtn.onclick = () => {
          const nameEl = modal.querySelector('#convPresetName');
          const name = ((nameEl && nameEl.value) || '').trim();
          if (!name) { toast(t('conv.preset_name_req') || 'Name the preset first.', 'warning'); if (nameEl) nameEl.focus(); return; }
          let slotMap = null;
          if (!(P && targetId === P.GENERIC.id)) {
            const sm = Array.from(modal.querySelectorAll('.conv-slot')).map((s) => parseInt(s.value, 10) || 0);
            if (sm.length && !sm.every((v, i) => v === i)) slotMap = sm;
          }
          savePreset(name, targetId, slotMap);
          if (nameEl) nameEl.value = '';
          if (applySel) applySel.innerHTML = `<option value="">${escapeHtml(t('conv.preset_apply') || 'Apply a preset…')}</option>` + presetOptions(a.flavour);
          toast(t('conv.preset_saved') || 'Preset saved.', 'success');
        };
      },
      async onSave(modal) {
        const isGeneric = (P && targetId === P.GENERIC.id) || isCrossEcosystem(a.flavour, targetId);
        const bandState = (typeof modal._bandState === 'function') ? modal._bandState() : { enabled: false };
        const bandOn = !isGeneric && bandState.enabled && !!(bandState.plan && bandState.plan.banded);
        const fsState = (typeof modal._fsState === 'function') ? modal._fsState() : { enabled: false };
        // Band-swap and Full Spectrum are mutually exclusive; band-swap wins if somehow both are set.
        const fsOn = !isGeneric && !bandOn && fsState.enabled && !!fsState.plan;
        // ── SPOOL MATCH: a match the maker asked for replaces the slot table, or stops here ──
        const spool = (!isGeneric && !fsOn && !bandOn && typeof modal._spoolState === 'function') ? modal._spoolState() : { active: false };
        if (spool.active && spool.refusal) { toast(spool.refusal, 'error', 6400); return false; }
        const spoolOpts = spool.active ? (spool.request || { slotMap: null }) : null;
        // ── end SPOOL MATCH ──
        let slotMap = null;
        // Band-swap / Full Spectrum handle all colours themselves — the manual slot map doesn't apply.
        if (!spoolOpts && !isGeneric && !fsOn && !bandOn && filaments.length) {
          slotMap = Array.from(modal.querySelectorAll('.conv-slot')).map((s) => parseInt(s.value, 10) || 0);
          if (slotMap.every((v, i) => v === i)) slotMap = null; // identity → no remap
          // A Prusa project may put two colours on one tool on purpose (its plan says so); elsewhere one is dropped.
          const prusaOn = typeof modal._prusaState === 'function' && modal._prusaState().on;
          if (slotMap && !prusaOn && new Set(slotMap).size !== slotMap.length) {
            toast(t('conv.dup_slots') || 'Two colours are mapped to the same slot — one will be dropped. Give each colour its own slot.', 'warning', 5600);
          }
        }
        // A Prusa project with more colours than tools merges them itself; the slot table is hidden.
        const prusaState = (typeof modal._prusaState === 'function') ? modal._prusaState() : { on: false };
        if (prusaState.on && prusaState.merges) slotMap = null;
        const dest = (modal.querySelector('input[name="convDest"]:checked') || {}).value || 'library';
        const mode = isGeneric ? 'normalize' : 'retarget';
        // Custom printers AND installed-slicer catalogue printers convert via an explicit targetProfile.
        const targetProfile = (isCustomId(targetId) || isOrcaId(targetId)) ? getProfileById(targetId) : null;
        const targetName = (getProfileById(targetId) && getProfileById(targetId).name)
          || (isGeneric ? (t('conv.normalize_opt') || 'Generic 3MF') : targetId);
        const intoVaultId = dest === 'folder'
          ? null
          : (src.recordId || (typeof uid === 'function' ? uid('PF') : ('PF' + Date.now().toString(36))));

        const btn = modal.querySelector('[data-act="save"]');
        if (btn) { btn.disabled = true; btn.textContent = t('conv.converting') || 'Converting…'; }
        let r;
        try {
          // Per-slot filament picks (Orca DB) → array indexed by slot.
          const picksMap = (typeof modal._filPicks === 'function') ? modal._filPicks() : {};
          const filaments = Object.keys(picksMap).length
            ? Array.from({ length: Math.max(...Object.keys(picksMap).map((k) => +k + 1)) }, (_, i) => picksMap[i] || null)
            : null;
          const process = (typeof modal._procPick === 'function') ? modal._procPick() : null;
          r = await hub().mfConvert({ path: src.path, targetId, mode, slotMap, intoVaultId, targetProfile, fullSpectrum: fsOn, bandSwap: bandOn, filaments, process, colorMix: !!(prusaState.on && prusaState.colorMix), ...(spoolOpts || {}) });
        } catch (e) { toast(String((e && e.message) || e), 'error'); if (btn) { btn.disabled = false; } return false; }
        if (r && r.refused === 'spool-match' && typeof modal._spoolRefused === 'function') modal._spoolRefused(r.error); // SPOOL MATCH
        if (r && r.canceled) { if (btn) { btn.disabled = false; btn.textContent = t('conv.convert') || 'Convert & save…'; } return false; }
        if (!r || !r.ok) { toast(convertErrorText(r), 'error', r && r.code === 'too_large' ? 7000 : undefined); if (btn) { btn.disabled = false; } return false; }
        const rep = r.report || {};
        for (const w of (rep.warnings || [])) toast((_bdr ? '' : '⚠ ') + w, 'warning', 5200);

        if (dest === 'folder') {
          toast((t('conv.done') || 'Converted to {name}').replace('{name}', rep.targetName || targetName), 'success', 3200);
        } else if (src.recordId) {
          if (typeof attachConverted === 'function') attachConverted(src.recordId, { filename: r.filename, ext: r.ext, size: r.size, targetId, targetName });
          toast(t('conv.added_this') || 'Saved with your print file.', 'success', 3200);
        } else {
          if (typeof importConvertedAsNew === 'function') {
            await importConvertedAsNew({ vaultId: intoVaultId, filename: r.filename, ext: r.ext, size: r.size, targetId, targetName, sourceName: src.name });
          }
          toast(t('conv.added_new') || 'Added to your Print-File library.', 'success', 3200);
        }
        return true;
      },
    });
  }

  /* ---------------- Batch conversion ---------------- */
  let batchFiles = [];
  let batchTargetId = null;   // remembered across panel re-renders (row removal, target change)
  let batchColorMode = 'merge'; // 'merge' | 'fs' (Full Spectrum) | 'band' (band-swap M600)

  async function runBatch() {
    const el = document.getElementById('convBatchPanel');
    if (!el || !batchFiles.length) return;
    const targetId = (el.querySelector('#convBatchTarget') || {}).value || firstTargetId();
    const P = profiles();
    const isGeneric = P && targetId === P.GENERIC.id;
    // Match the single-file path: installed-slicer (Orca) AND custom printers convert via an explicit profile.
    const targetProfile = (isCustomId(targetId) || isOrcaId(targetId)) ? getProfileById(targetId) : null;
    const targetName = (getProfileById(targetId) && getProfileById(targetId).name) || targetId;
    // Colour handling only applies to a real mixing/swap-capable target in retarget mode. The engine
    // no-ops each flag per file where it can't apply (too few colours, not banded, etc.), so it's safe
    // to pass a blanket flag across a mixed batch.
    const tp = getProfileById(targetId);
    const colourCapable = !isGeneric && !!(tp && tp.supportsMixedFilament && tp.maxColors >= 2);
    const fullSpectrum = colourCapable && batchColorMode === 'fs';
    const bandSwap = colourCapable && batchColorMode === 'band';
    // "Merge to the nearest {n} slots" is a real engine option now, not just the absence of the
    // other two: before, a file with more colours than slots converted with a warning and
    // nothing merged.
    const mergeToSlots = colourCapable && batchColorMode === 'merge';
    const dest = (el.querySelector('input[name="convBatchDest"]:checked') || {}).value || 'library';

    let outdir = null;
    if (dest === 'folder') {
      const d = await hub().mfPickOutdir();
      if (!d || !d.ok) return;
      outdir = d.dir;
    }
    const runBtn = el.querySelector('#convBatchRun');
    if (runBtn) runBtn.disabled = true;
    // Lock the panel's inputs while converting. In particular a per-row ✕ remove re-renders the panel
    // and splices batchFiles mid-loop, which would desync `i` from the DOM stat cells and the file list.
    setBatchControlsDisabled(el, true);

    let ok = 0;
    try {
    for (let i = 0; i < batchFiles.length; i++) {
      const f = batchFiles[i];
      const stat = el.querySelector(`.conv-batch-stat[data-i="${i}"]`);
      if (stat) { stat.textContent = '…'; stat.className = 'conv-batch-stat working'; stat.dataset.i = i; }
      const tag = String(targetId || 'out').replace(/[^a-zA-Z0-9]/g, '').slice(0, 14) || 'out';
      const base = String(f.name || 'model').replace(/\.3mf$/i, '');
      const intoVaultId = dest === 'library' ? (typeof uid === 'function' ? uid('PF') : ('PF' + i + Date.now().toString(36))) : null;
      const outPath = dest === 'folder' ? `${outdir}/${base}-${tag}.3mf` : null;

      // Source-ecosystem guard (matches the single-file path): a file from a DIFFERENT slicer ecosystem
      // than the target can't keep its settings, so it must be normalized to a Generic 3MF rather than
      // retargeted — otherwise the retarget silently produces a file with the wrong printer's config.
      let perGeneric = isGeneric;
      if (!isGeneric && hub().mfAnalyze) {
        try { const a = await hub().mfAnalyze(f.path); if (a && a.ok && isCrossEcosystem(a.flavour, targetId)) perGeneric = true; }
        catch (_) { /* analyze failed → fall back to retarget (no worse than before) */ }
      }
      const crossed = perGeneric && !isGeneric; // normalized because of an ecosystem mismatch
      // Colour mixing/swap can't happen on a normalized Generic file.
      const fsThis = fullSpectrum && !perGeneric;
      const bandThis = bandSwap && !perGeneric;
      let r;
      try {
        r = await hub().mfConvert({ path: f.path, targetId, mode: perGeneric ? 'normalize' : 'retarget', intoVaultId, outPath, targetProfile: perGeneric ? null : targetProfile, fullSpectrum: fsThis, bandSwap: bandThis, mergeToSlots: mergeToSlots && !perGeneric });
      } catch (e) { r = { ok: false, error: String((e && e.message) || e) }; }
      if (r && r.ok) {
        ok++;
        const rep = r.report || {};
        const nWarn = (rep.warnings || []).length;
        // Surface whether the colour flag actually kicked in for this file (engine reports it per file),
        // or that it fell back to Generic because it came from another ecosystem.
        const cbadge = crossed ? ' →Generic' : rep.fullSpectrum ? ' ✦' : rep.bandSwap ? ` ⇄${rep.bandSwaps || ''}` : '';
        if (stat) { stat.textContent = (nWarn ? (_bdr ? `✓ ${nWarn}` : `✓ ⚠${nWarn}`) : '✓') + cbadge; stat.className = 'conv-batch-stat ok'; stat.dataset.i = i; stat.title = crossed ? (t('conv.batch_crossed') || 'From another ecosystem — saved as a Generic 3MF (open in that printer’s slicer).') : cbadge ? (rep.fullSpectrum ? (t('conv.fs_applied') || 'Full Spectrum mix applied') : (t('conv.band_applied') || 'Band-swap pauses added')) : ''; }
        if (dest === 'library' && typeof importConvertedAsNew === 'function') {
          const gid = (P && P.GENERIC && P.GENERIC.id) || 'generic';
          await importConvertedAsNew({
            vaultId: intoVaultId, filename: r.filename, ext: r.ext, size: r.size,
            targetId: crossed ? gid : targetId,
            targetName: rep.targetName || (crossed ? (t('conv.normalize_opt') || 'Generic 3MF') : targetName),
            sourceName: f.name, noSwitch: true,
          });
        }
      } else if (stat) {
        stat.textContent = `✕ ${(t('conv.batch_fail') || 'failed')}`; stat.className = 'conv-batch-stat fail'; stat.dataset.i = i;
        stat.title = (r && r.error) || '';
      }
    }
    } finally {
      if (runBtn) runBtn.disabled = false;
      setBatchControlsDisabled(el, false);
    }
    toast((t('conv.batch_done') || 'Converted {ok} of {total} files.').replace('{ok}', ok).replace('{total}', batchFiles.length), ok ? 'success' : 'error', 3600);
  }

  // Enable/disable the batch panel's interactive controls (remove ✕, target, colour + destination radios)
  // so nothing can re-render or mutate batchFiles while a run is in flight.
  function setBatchControlsDisabled(el, on) {
    if (!el) return;
    el.querySelectorAll('[data-batch-x], #convBatchTarget, input[name="convBatchColour"], input[name="convBatchDest"]')
      .forEach((c) => { c.disabled = !!on; });
  }

  function batchPanelHtml() {
    if (!batchFiles.length) return '';
    const rows = batchFiles.map((f, i) => `
      <div class="conv-batch-row"><span class="conv-batch-name" title="${escapeHtml(f.path)}">${_emoI('doc', '📄')}${escapeHtml(f.name)}</span><span class="conv-batch-stat" data-i="${i}"></span><button type="button" class="conv-batch-x" data-batch-x="${i}" title="${escapeHtml(t('conv.batch_remove') || 'Remove from batch')}" aria-label="${escapeHtml(t('conv.batch_remove') || 'Remove from batch')}">✕</button></div>`).join('');
    const selTarget = batchTargetId || firstTargetId();
    const tp = getProfileById(selTarget);
    const P = profiles();
    const isGeneric = P && selTarget === P.GENERIC.id;
    // Multicolour handling row: only when the target can actually mix/swap. Applied blanket across the
    // batch; the engine no-ops it per file where it doesn't apply, so it never corrupts a plain file.
    const colourCapable = !isGeneric && !!(tp && tp.supportsMixedFilament && tp.maxColors >= 2);
    const heads = (tp && tp.maxColors) || 4;
    const colourRow = !colourCapable ? '' : `
        <div class="conv-batch-colour">
          <label class="conv-label">${escapeHtml(t('conv.batch_colour') || 'Files with more colours than slots')}</label>
          <label class="conv-dest-opt"><input type="radio" name="convBatchColour" value="merge"${batchColorMode === 'merge' ? ' checked' : ''}> ${escapeHtml((t('conv.batch_colour_merge') || 'Merge to the nearest {n} slots').replace('{n}', heads))}</label>
          <label class="conv-dest-opt"><input type="radio" name="convBatchColour" value="fs"${batchColorMode === 'fs' ? ' checked' : ''}> ${escapeHtml((t('conv.batch_colour_fs') || 'Full Spectrum — mix extra colours across {n} heads').replace('{n}', heads))}</label>
          <label class="conv-dest-opt"><input type="radio" name="convBatchColour" value="band"${batchColorMode === 'band' ? ' checked' : ''}> ${escapeHtml(t('conv.batch_colour_band') || 'Band-swap (M600) for cleanly banded files')}</label>
        </div>`;
    // Cross-ecosystem note: with a specific printer target, files from a DIFFERENT slicer ecosystem are
    // saved as Generic 3MF per file (they can't inherit this printer's settings). Mirrors the single-file note.
    const crossNote = isGeneric ? '' : `<p class="conv-tip">${escapeHtml(t('conv.batch_cross_note') || 'Files from another printer’s ecosystem are saved as a Generic 3MF (open them in that printer’s slicer); same-ecosystem files keep their settings.')}</p>`;
    return `
      <div class="conv-batch">
        <label class="conv-label">${escapeHtml(t('conv.batch_target') || 'Convert all to')}</label>
        <select id="convBatchTarget" class="conv-target">${targetOptions(selTarget)}</select>
        <div class="conv-dest">
          <label class="conv-dest-opt"><input type="radio" name="convBatchDest" value="library" checked> ${escapeHtml(t('conv.batch_dest_lib') || 'Add all to my Print-File library')}</label>
          <label class="conv-dest-opt"><input type="radio" name="convBatchDest" value="folder"> ${escapeHtml(t('conv.batch_dest_folder') || 'Save all to a folder…')}</label>
        </div>${colourRow}${crossNote}
        <div class="conv-batch-list">${rows}</div>
        <button class="btn primary" id="convBatchRun">${_emoI('convert', '🔄')}${escapeHtml((t('conv.batch_run') || 'Convert {n} files').replace('{n}', batchFiles.length))}</button>
      </div>`;
  }

  // Re-render the batch panel in place and (re)wire its Run + per-row remove buttons. Called after the
  // list changes (file picked or a row removed) so the two stay in sync without a full tab re-render.
  function refreshBatchPanel() {
    const panel = document.getElementById('convBatchPanel');
    if (!panel) return;
    panel.innerHTML = batchPanelHtml();
    wireBatchPanel();
  }

  function wireBatchPanel() {
    const run = document.getElementById('convBatchRun');
    if (run) run.onclick = runBatch;
    document.querySelectorAll('#convBatchPanel [data-batch-x]').forEach((b) => {
      b.onclick = () => {
        const i = parseInt(b.getAttribute('data-batch-x'), 10);
        if (i >= 0 && i < batchFiles.length) batchFiles.splice(i, 1);
        refreshBatchPanel();
      };
    });
    // Changing the target changes which colour options apply → re-render so the row appears/updates.
    const tsel = document.getElementById('convBatchTarget');
    if (tsel) tsel.onchange = () => { batchTargetId = tsel.value; batchColorMode = 'merge'; refreshBatchPanel(); };
    document.querySelectorAll('#convBatchPanel input[name="convBatchColour"]').forEach((r) => {
      r.onchange = () => { if (r.checked) batchColorMode = r.value; };
    });
  }

  /* ---------------- Custom printers ---------------- */
  function saveCustomPrinter(form) {
    const P = profiles();
    if (!P || !P.customProfile) return;
    const val = (sel) => (form.querySelector(sel) || {}).value;
    const spec = {
      id: typeof uid === 'function' ? uid('cp') : ('cp' + Date.now().toString(36)),
      name: val('#cpName'), vendor: val('#cpVendor'), flavour: val('#cpFlavour'),
      maxColors: val('#cpSlots'), nozzle: val('#cpNozzle'),
      bed: { x: val('#cpBedX'), y: val('#cpBedY'), z: val('#cpBedZ') },
      printerModel: val('#cpModel') || val('#cpName'),
    };
    const prof = P.customProfile(spec);
    if (!prof) { toast(t('conv.cp_name_req') || 'Give the printer a name.', 'warning'); return; }
    if (typeof settings === 'undefined') return;
    if (!Array.isArray(settings.customPrinters)) settings.customPrinters = [];
    settings.customPrinters.push(prof);
    if (typeof saveAll === 'function') saveAll();
    toast(t('conv.cp_added') || 'Printer saved.', 'success');
    renderConverter();
  }
  function removeCustomPrinter(id) {
    if (typeof settings === 'undefined' || !Array.isArray(settings.customPrinters)) return;
    settings.customPrinters = settings.customPrinters.filter((p) => p.id !== id);
    if (typeof saveAll === 'function') saveAll();
    renderConverter();
  }

  function customManagerHtml() {
    const P = profiles();
    const flavours = (P && P.FLAVOURS) || ['bambu', 'orca', 'prusa', 'generic'];
    const list = customPrinters();
    const listHtml = list.length
      ? list.map((p) => `<div class="conv-cp-item"><span class="conv-cp-nm">${escapeHtml(p.name)}</span><span class="conv-cp-sub">${escapeHtml((fmtBed(p.bed) || '') + ' · ' + p.maxColors + '★ · ' + p.flavour)}</span><button class="btn small ghost" data-act="cp-remove" data-id="${escapeHtml(p.id)}">✕ ${escapeHtml(t('conv.cp_remove') || 'Remove')}</button></div>`).join('')
      : `<p class="conv-note">${escapeHtml(t('conv.cp_empty') || "No custom printers yet. Add one to convert for a printer that isn't in the list.")}</p>`;
    return `
      <div class="conv-cp">
        <h3 class="conv-cp-h">${_emo('🖨')}${escapeHtml(t('conv.my_printers') || 'My printers')}</h3>
        <div class="conv-cp-list">${listHtml}</div>
        <details class="conv-cp-add">
          <summary>＋ ${escapeHtml(t('conv.add_printer') || 'Add a printer')}</summary>
          <div class="conv-cp-form" id="convCpForm">
            <div class="conv-cp-grid">
              <label>${escapeHtml(t('conv.cp_name') || 'Name')}<input id="cpName" type="text" maxlength="48" placeholder="${escapeHtml(t('conv.cp_name_ph'))}"></label>
              <label>${escapeHtml(t('conv.cp_vendor') || 'Brand')}<input id="cpVendor" type="text" maxlength="32"></label>
              <label>${escapeHtml(t('conv.cp_flavour') || 'Slicer format')}<select id="cpFlavour">${flavours.map((f) => `<option value="${f}">${f}</option>`).join('')}</select></label>
              <label>${escapeHtml(t('conv.cp_slots') || 'Colour slots')}<input id="cpSlots" type="number" min="1" max="16" value="1"></label>
              <label>${escapeHtml(t('conv.cp_nozzle') || 'Nozzle (mm)')}<input id="cpNozzle" type="number" min="0.1" max="2" step="0.1" value="0.4"></label>
              <label>${escapeHtml(t('conv.cp_model') || 'Printer model id')}<input id="cpModel" type="text" maxlength="64"></label>
              <label>${escapeHtml(t('conv.cp_bedx') || 'Bed X')}<input id="cpBedX" type="number" min="1" max="2000" value="256"></label>
              <label>${escapeHtml(t('conv.cp_bedy') || 'Bed Y')}<input id="cpBedY" type="number" min="1" max="2000" value="256"></label>
              <label>${escapeHtml(t('conv.cp_bedz') || 'Bed Z')}<input id="cpBedZ" type="number" min="1" max="2000" value="256"></label>
            </div>
            <button class="btn primary small" id="convCpSave">${escapeHtml(t('conv.cp_save') || 'Save printer')}</button>
          </div>
        </details>
      </div>`;
  }

  function presetManagerHtml() {
    const list = convPresets();
    if (!list.length) return '';
    const rows = list.map((p) => {
      const prof = getProfileById(p.targetId);
      const tgt = prof ? prof.name : (p.targetId || '');
      return `<div class="conv-cp-item"><span class="conv-cp-nm">${escapeHtml(p.name)}</span><span class="conv-cp-sub">→ ${escapeHtml(tgt)}${Array.isArray(p.slotMap) ? ' · ' + p.slotMap.length + '★' : ''}</span><button class="btn small ghost" data-act="preset-remove" data-id="${escapeHtml(p.id)}">✕ ${escapeHtml(t('conv.preset_remove') || 'Remove')}</button></div>`;
    }).join('');
    return `<div class="conv-cp"><h3 class="conv-cp-h">★ ${escapeHtml(t('conv.presets_title') || 'Conversion presets')}</h3><div class="conv-cp-list">${rows}</div></div>`;
  }

  // Standalone Converter tab.
  function renderConverter() {
    const el = document.getElementById('converter-tab');
    if (!el) return;
    const hasHub = !!(hub() && hub().mfPick);
    if (!hasHub) {
      el.innerHTML = `<div class="conv-wrap"><div class="conv-head"><h2 class="conv-title">${_titleIco}${escapeHtml(t('conv.title') || 'Convert 3MF')}</h2></div><div class="pf-empty">${escapeHtml(t('conv.desktop_only') || 'The converter is available in the desktop app.')}</div></div>`;
      return;
    }
    el.innerHTML = `
      <div class="conv-wrap">
        <div class="conv-head">
          <h2 class="conv-title">${_titleIco}${escapeHtml(t('conv.title') || 'Convert 3MF')}</h2>
          <p class="conv-sub">${escapeHtml(t('conv.subtitle') || 'Retarget a multicolour 3MF to a different printer, or normalize it to a clean standard 3MF. Geometry is never altered.')}</p>
        </div>
        <!-- One button opens a file; the other four open a file to do something
             ELSE with it. Five side by side made none of them look like the
             way in. -->
        <div class="act conv-actions">
          <button class="btn primary" id="convPick">${_emoI('plus', '＋')}${escapeHtml(t('conv.pick') || 'Choose a 3MF file…')}</button>
          <!-- No act-end here: this is a row of ways IN, not a card's actions,
               so the overflow belongs beside the primary rather than shoved to
               the far edge of the panel where it reads as unrelated. -->
          <details class="ovf">
            <summary class="btn ghost small icon" role="button" aria-label="${escapeHtml(t('common.more') || 'More actions')}" title="${escapeHtml(t('common.more') || 'More actions')}">${_emoI('more', '⋯', 16)}</summary>
            <div class="ovf-menu">
              <button id="convBatchPick">${_emoI('folder', '🗂')}${escapeHtml(t('conv.batch_pick') || 'Batch convert…')}</button>
              ${hub() && hub().stlPick ? `<button id="convStlBtn">${_emoI('cube', '📐')}${escapeHtml(t('conv.stl_pick') || 'STL → 3MF…')}</button>` : ''}
              ${hub() && hub().mfToStl ? `<button id="convToStlBtn">${_emoI('share', '📤')}${escapeHtml(t('conv.tostl_pick') || '3MF → STL…')}</button>` : ''}
              ${hub() && hub().mfBands ? `<button id="convSwapBtn">${_emoI('palette', '🎨')}${escapeHtml(t('conv.swap_pick') || 'Colour-swap plan…')}</button>` : ''}
            </div>
          </details>
        </div>
        <div class="conv-dropzone" id="convDrop" style="margin-top:14px;padding:20px;border:2px dashed var(--border,#cbd5d1);border-radius:14px;text-align:center;color:var(--text-muted,#869390);font-size:13.5px;transition:border-color .15s ease, background .15s ease;">⤓ ${escapeHtml(t('conv.drop') || 'or drag a 3MF / STL file here')}</div>
        <p class="conv-tip">${escapeHtml(t('conv.tip') || 'Tip: you can also hit Convert on any 3MF in your Print-File library.')}</p>
        <div id="convBatchPanel">${batchPanelHtml()}</div>
        ${presetManagerHtml()}
        ${customManagerHtml()}
      </div>`;

    const pick = document.getElementById('convPick');
    if (pick) pick.onclick = async () => {
      const r = await hub().mfPick();
      if (!r || !r.ok) return;
      openConverter({ path: r.path, name: r.name });
    };
    const bpick = document.getElementById('convBatchPick');
    if (bpick) bpick.onclick = async () => {
      const r = await hub().mfPickMulti();
      if (!r || !r.ok || !r.files || !r.files.length) return;
      batchFiles = r.files;
      refreshBatchPanel();
    };
    wireBatchPanel();

    // Drag-and-drop: dropping a .3mf opens the converter; a .stl runs the STL→3MF flow. Makers live in
    // Finder/Explorer and reach for a drop before a file dialog.
    (function wireDrop() {
      const wrap = el.querySelector('.conv-wrap') || el;
      const dz = document.getElementById('convDrop');
      if (!wrap) return;
      const hi = (on) => { if (!dz) return; dz.style.borderColor = on ? 'var(--accent,#199e8f)' : 'var(--border,#cbd5d1)'; dz.style.background = on ? 'var(--accent-soft,rgba(25,158,143,.08))' : 'transparent'; };
      const over = (e) => { e.preventDefault(); e.stopPropagation(); hi(true); };
      wrap.addEventListener('dragover', over);
      wrap.addEventListener('dragenter', over);
      wrap.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); hi(false); });
      wrap.addEventListener('drop', async (e) => {
        e.preventDefault(); e.stopPropagation(); hi(false);
        const files = (e.dataTransfer && e.dataTransfer.files) ? Array.prototype.slice.call(e.dataTransfer.files) : [];
        const f = files.find((x) => /\.(3mf|stl)$/i.test(x.name));
        if (!f) { if (files.length) toast(t('conv.drop_bad') || 'Drop a 3MF or STL file.', 'error'); return; }
        const p = f.path; if (!p) return;
        if (/\.3mf$/i.test(f.name)) { openConverter({ path: p, name: f.name }); return; }
        const doConvert = async () => {
          toast(t('conv.stl_working') || 'Converting STL…', 'info', 1600);
          const vaultId = typeof uid === 'function' ? uid('PF') : ('PF' + Date.now().toString(36));
          let c;
          try { c = await hub().stlTo3mf({ path: p, intoVaultId: vaultId }); }
          catch (err) { toast(String((err && err.message) || err), 'error'); return; }
          if (!c || !c.ok) { toast((c && c.error) || (t('conv.stl_failed') || 'Could not convert that STL.'), 'error'); return; }
          if (typeof importConvertedAsNew === 'function') await importConvertedAsNew({ vaultId, filename: c.filename, ext: c.ext, size: c.size, targetName: '3MF', sourceName: f.name });
          toast(t('conv.stl_done') || 'STL converted to 3MF and added to your library.', 'success', 3600);
        };
        previewConfirm({ path: p, name: f.name, title: `${_titleIco}${t('conv.stl_pick') || 'STL → 3MF'}`, confirmLabel: t('conv.stl_go') || 'Convert to 3MF', onConfirm: doConvert });
      });
    })();

    const stlBtn = document.getElementById('convStlBtn');
    if (stlBtn) stlBtn.onclick = async () => {
      const r = await hub().stlPick();
      if (!r || !r.ok) return;
      const doConvert = async () => {
        toast(t('conv.stl_working') || 'Converting STL…', 'info', 1600);
        const vaultId = typeof uid === 'function' ? uid('PF') : ('PF' + Date.now().toString(36));
        let c;
        try { c = await hub().stlTo3mf({ path: r.path, intoVaultId: vaultId }); }
        catch (e) { toast(String((e && e.message) || e), 'error'); return; }
        if (!c || !c.ok) { toast((c && c.error) || (t('conv.stl_failed') || 'Could not convert that STL.'), 'error'); return; }
        if (typeof importConvertedAsNew === 'function') {
          await importConvertedAsNew({ vaultId, filename: c.filename, ext: c.ext, size: c.size, targetName: '3MF', sourceName: r.name });
        }
        toast(t('conv.stl_done') || 'STL converted to 3MF and added to your library.', 'success', 3600);
      };
      previewConfirm({ path: r.path, name: r.name, title: `${_titleIco}${t('conv.stl_pick') || 'STL → 3MF'}`, confirmLabel: t('conv.stl_go') || 'Convert to 3MF', onConfirm: doConvert });
    };

    const toStlBtn = document.getElementById('convToStlBtn');
    if (toStlBtn) toStlBtn.onclick = async () => {
      const r = await hub().mfPick();
      if (!r || !r.ok) return;
      const doExtract = async () => {
        toast(t('conv.tostl_working') || 'Extracting mesh…', 'info', 1600);
        let c;
        try { c = await hub().mfToStl({ path: r.path }); }
        catch (e) { toast(String((e && e.message) || e), 'error'); return; }
        if (c && c.canceled) return;
        if (!c || !c.ok) { toast((c && c.error) || (t('conv.tostl_none') || 'No mesh found in that 3MF.'), 'error'); return; }
        toast(t('conv.tostl_done') || 'Saved STL.', 'success', 3200);
      };
      previewConfirm({ path: r.path, name: r.name, title: `${_titleIco}${t('conv.tostl_pick') || '3MF → STL'}`, confirmLabel: t('conv.tostl_go') || 'Extract STL', onConfirm: doExtract });
    };

    const swapBtn = document.getElementById('convSwapBtn');
    if (swapBtn) swapBtn.onclick = async () => {
      const r = await hub().mfPick();
      if (!r || !r.ok) return;
      toast(t('conv.swap_working') || 'Analysing colours…', 'info', 1400);
      let a;
      try { a = await hub().mfBands(r.path, { heads: 1 }); }
      catch (e) { toast(String((e && e.message) || e), 'error'); return; }
      openSwapPlanModal(a, r.name);
    };

    const cpSave = document.getElementById('convCpSave');
    if (cpSave) cpSave.onclick = () => saveCustomPrinter(document.getElementById('convCpForm'));
    el.querySelectorAll('[data-act="cp-remove"]').forEach((b) => { b.onclick = () => removeCustomPrinter(b.dataset.id); });
    el.querySelectorAll('[data-act="preset-remove"]').forEach((b) => { b.onclick = () => removePreset(b.dataset.id); });
  }

  // ---- Single-extruder colour-swap plan ------------------------------------
  // A vertically colour-banded painted 3MF can be printed on ANY pause-capable printer by swapping
  // filament at each colour change (M600). analyzeColorBands(heads:1) gives the swap heights + a ready
  // Orca custom_gcode_per_layer.xml. This generalizes the U1 band-swap to single-extruder printers.
  const cssHex = (h) => (/^#[0-9a-fA-F]{3,8}$/.test(String(h || '')) ? h : '#888');
  const swapChip = (hex) => `<span style="display:inline-block;width:14px;height:14px;border-radius:3px;vertical-align:middle;border:1px solid rgba(0,0,0,.2);background:${cssHex(hex)}"></span>`;

  function swapStartColour(a) {
    const pal = Array.isArray(a.palette) ? a.palette : [];
    return (a.bands && a.bands[0] && pal[a.bands[0].state - 1]) || pal[0] || '';
  }
  function swapPlanText(a, name) {
    if (!a || !a.instructions) return '';
    const start = swapStartColour(a);
    const lines = [`Colour-swap plan — ${name || 'model'}`, `Load to start: ${start || '?'}`, `${a.instructions.length} swaps (single extruder, M600):`];
    a.instructions.forEach((s) => lines.push(`  ${(+s.z).toFixed(2)} mm — swap to ${s.toColour || ('colour ' + s.toSlot)}`));
    return lines.join('\n');
  }

  function openSwapPlanModal(a, name) {
    const esc = (s) => escapeHtml(String(s == null ? '' : s));
    let body;
    if (!a || !a.available) {
      body = `<p>${esc((a && a.error) || 'Could not read colour data from that file.')}</p>`;
    } else if (!a.banded) {
      body = `<p>This model isn’t vertically colour-banded — its colours share layers, so a single-extruder swap can’t reproduce it (it needs a multi-material printer).</p><p class="conv-tip">${esc(a.reason || '')}</p>`;
    } else if (!a.instructions || !a.instructions.length) {
      body = `<p>No swaps needed — this model is effectively a single colour.</p>`;
    } else {
      const start = swapStartColour(a);
      const steps = a.instructions.map((s) => `<div style="display:flex;align-items:center;gap:8px;padding:6px 0;border-top:1px solid var(--border,#e1dace);">
        <b style="font-family:monospace;min-width:70px;">${esc((+s.z).toFixed(2))} mm</b>
        ${swapChip(s.toColour)} <span>Swap to ${esc((s.toColour || '').toUpperCase() || ('colour ' + s.toSlot))}</span>
      </div>`).join('');
      body = `
        <p>${swapChip(start)} <b>Load to start:</b> ${esc((start || '').toUpperCase() || '—')}</p>
        <p class="conv-sub">${a.colorCount} colours · <b>${a.instructions.length}</b> filament swap${a.instructions.length === 1 ? '' : 's'} (M600) for a single-extruder printer.</p>
        <div style="margin:8px 0 12px;">${steps}</div>
        <div class="cal-actions"><button type="button" class="btn primary" id="swapSaveXml">${_emoI('doc', '💾')}Save pauses (.xml)</button><button type="button" class="btn ghost" id="swapCopy">${_emoI('clipboard', '📋')}Copy plan</button></div>
        <p class="conv-tip">Slice your model as a single colour, then pause at each height above (each is an M600 filament change) — or drop the saved Orca <code>custom_gcode_per_layer.xml</code> into your project.</p>`;
    }
    openFormModal({
      title: `${_titleIco}Colour-swap plan`,
      bodyHtml: `<div class="conv-swap-wrap">${body}</div>`,
      noSave: true,
      onMount(modal) {
        const saveBtn = modal.querySelector('#swapSaveXml');
        if (saveBtn) saveBtn.onclick = async () => {
          if (!(hub() && hub().saveTextFile)) return;
          const base = String(name || 'model').replace(/\.[^.]+$/, '').replace(/[^a-z0-9._-]+/gi, '_') || 'model';
          const rr = await hub().saveTextFile({ content: a.customGcodeXml, defaultName: base + '-swap-pauses.xml', filters: [{ name: 'Orca custom G-code', extensions: ['xml'] }] });
          if (rr && rr.ok !== false) toast(t('conv.swaps_saved'), 'success');
        };
        const copyBtn = modal.querySelector('#swapCopy');
        if (copyBtn) copyBtn.onclick = () => { copyAndToast(swapPlanText(a, name)); };
      },
    });
  }

  const pub = { renderConverter, openConverter, _renderPreviewInto: renderPreviewInto };
  Object.assign(global, pub);
  global.KhaytConverter = pub;
  if (typeof module !== 'undefined' && module.exports) module.exports = pub;
})(typeof globalThis !== 'undefined' ? globalThis : this);
