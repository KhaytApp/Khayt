'use strict';
/*
 * Print-File Library (3.1) — a standalone, order-independent catalogue of the maker's
 * STL / 3MF / gcode files, with a real preview thumbnail (embedded slicer thumbnail
 * for gcode/3MF, software-rendered for STL), an optional user photo, parsed metadata,
 * multicolour info, a "tested settings" note + slicer profile (the BedReady "design
 * library" idea), and one-click "open in slicer".
 *
 * Records live in the `printFiles` store collection; the model file + generated images
 * live under userData/print-files-vault/<id>/ (main-process handlers). Everything is
 * local — no network. Degrades gracefully in the web/LAN build (no window.hubAPI).
 */
(function (global) {
  const api = () => (typeof window !== 'undefined' && window.hubAPI) || null;
  const EXT_ICON = { stl: '🧊', obj: '🧊', '3mf': '🎨', gcode: '📄', gco: '📄' };
  /** What is worth handing to a slicer. The vault folder also holds thumb.jpg
   *  and sidecars, so "the first file in the directory" is not an answer. */
  const MODEL_EXT = /\.(stl|3mf|obj|gcode|gco)$/i;
  const EXT_ICON_NAME = { stl: 'cube', obj: 'cube', '3mf': 'colour', gcode: 'doc', gco: 'doc' };
  /* Bed Ready swaps in its bespoke drafting glyphs; KHAYT USED TO KEEP THE EMOJI,
   * and that is what a row of 🖨 🛠 🔎 🧊 🎨 🔄 🗑 was. renderer/icons.js has
   * said since it was written that a toolbar of emoji "breaks the rule twice:
   * the glyphs shout, and they render in whatever colour and metrics the OS
   * emoji font decides" — and it ends "never inline an emoji in markup that this
   * could cover". This markup was covered by nothing, because the fallback here
   * skipped straight past the shared set to the glyph.
   *
   * Order is deliberate: the flavour's own set first where there is one, then
   * the shared line icons, then the emoji — which now only shows up for a name
   * neither set draws. */
  const _BDR = (typeof document !== 'undefined' && document.documentElement && document.documentElement.dataset.app === 'bedready');
  const _bi = (name, glyph, size) => {
    if (_BDR && window.BedReadyIcons) {
      return `<span class="pf-ico" aria-hidden="true">${window.BedReadyIcons.get(name, size || 15)}</span>`;
    }
    const svg = (typeof window !== 'undefined' && window.KhaytIcons)
      ? window.KhaytIcons.icon(name, size || 15) : '';
    if (svg) return `<span class="pf-ico" aria-hidden="true">${svg}</span>`;
    return glyph ? glyph + ' ' : '';
  };

  function fmtTime(mins) {
    if (mins == null || !isFinite(mins) || mins <= 0) return '';
    const h = Math.floor(mins / 60), m = Math.round(mins % 60);
    return h ? `${h}h ${m}m` : `${m}m`;
  }
  function fmtSize(bytes) {
    if (!bytes) return '';
    return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }
  function base64ToArrayBuffer(b64) {
    const bin = atob(b64);
    const len = bin.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
    return bytes.buffer;
  }
  // Downscale a data URL through a canvas so previews stay small in the synced store.
  function resizeDataUrl(dataUrl, maxDim, quality) {
    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        const ratio = Math.min(1, maxDim / Math.max(img.width, img.height));
        const w = Math.round(img.width * ratio), h = Math.round(img.height * ratio);
        const c = document.createElement('canvas'); c.width = w; c.height = h;
        try { c.getContext('2d').drawImage(img, 0, 0, w, h); resolve(c.toDataURL('image/jpeg', quality || 0.82)); }
        catch (_) { resolve(dataUrl); }
      };
      img.onerror = () => resolve(dataUrl);
      img.src = dataUrl;
    });
  }

  function filtered(query) {
    const list = Array.isArray(printFiles) ? printFiles : [];
    const q = (query || '').trim().toLowerCase();
    let rows = q
      ? list.filter((r) => (r.name + ' ' + (r.originalName || '') + ' ' + (r.tags || []).join(' ') + ' ' + (r.material || '')).toLowerCase().includes(q))
      : list.slice();
    if (_tagFilter) rows = rows.filter((r) => (r.tags || []).some((tg) => tg.toLowerCase() === _tagFilter.toLowerCase()));
    /* Both axes narrow at once, deliberately: "the busts in the Saudi Kings"
     * is the question a library of hundreds is actually asked. */
    if (_folderFilter === UNFILED) rows = rows.filter((r) => !groupOf(r));
    else if (_folderFilter) rows = rows.filter((r) => groupOf(r).toLowerCase() === _folderFilter.toLowerCase());
    if (_catFilter === UNFILED) rows = rows.filter((r) => !categoryOf(r));
    else if (_catFilter) rows = rows.filter((r) => categoryOf(r).toLowerCase() === _catFilter.toLowerCase());
    return rows.sort((a, b) => (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0) || (b.updatedAt || 0) - (a.updatedAt || 0));
  }

  /**
   * Distinct groups or categories, with counts, and how many are in neither.
   *
   * Through lib/organise.js, which FOLDS THE SPELLINGS. This counted the exact
   * string, so a shop that had typed "Saudi Kings" once and "saudi kings" twice
   * saw two chips for one collection and each found part of it — the same drift
   * the tag work exists to stop, and worse here because a group is the thing you
   * reach for when you want the whole set.
   *
   * Sorted most-used first rather than alphabetically: with fifty groups the
   * ones a shop actually works in should not be below the fold.
   */
  /**
   * The chips for one axis, counted against everything EXCEPT that axis.
   *
   * These counted the whole library while the grid narrows on four axes at
   * once, so with Busts on, the group bar still offered "Saudi Kings 7" and
   * pressing it showed 2. A number on a button is a promise about what pressing
   * it gives you.
   *
   * Its OWN filter is excluded, or every chip but the active one would read 0
   * and the bar would collapse to a single choice the moment you used it. This
   * is what faceted search does everywhere: each facet counts against the
   * others.
   */
  function filedUnder(field) {
    const shared = _O();
    const read = field === 'category' ? categoryOf : groupOf;
    const pool = rowsExcept(field);
    const names = shared
      ? shared.counts(pool, field)
      : (() => {
          const m = new Map();
          for (const r of pool) { const v = read(r); if (v) m.set(v, (m.get(v) || 0) + 1); }
          return [...m.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
        })();
    let unfiled = 0;
    for (const r of pool) if (!read(r)) unfiled++;
    return { names, unfiled, total: pool.length };
  }

  /** Everything the OTHER filters leave standing — the search box and the tag
   *  bar included, since both narrow the grid too. */
  function rowsExcept(field) {
    const list = Array.isArray(printFiles) ? printFiles : [];
    const q = (_query || '').trim().toLowerCase();
    return list.filter((r) => {
      if (q && !(r.name + ' ' + (r.originalName || '') + ' ' + (r.tags || []).join(' ') + ' ' + (r.material || '')).toLowerCase().includes(q)) return false;
      if (_tagFilter && !(r.tags || []).some((tg) => tg.toLowerCase() === _tagFilter.toLowerCase())) return false;
      if (field !== 'group') {
        if (_folderFilter === UNFILED) { if (groupOf(r)) return false; }
        else if (_folderFilter && groupOf(r).toLowerCase() !== _folderFilter.toLowerCase()) return false;
      }
      if (field !== 'category') {
        if (_catFilter === UNFILED) { if (categoryOf(r)) return false; }
        else if (_catFilter && categoryOf(r).toLowerCase() !== _catFilter.toLowerCase()) return false;
      }
      return true;
    });
  }

  /** Every tag the shop already uses, most-used first. The dialog offers these
   *  so a tag is REUSED rather than retyped — retyping is where "resin" and
   *  "Resin" come from. */
  function knownTags() {
    const shared = _T();
    if (shared) return shared.tagCounts(printFiles || []).map(([label]) => label);
    return [...new Set((printFiles || []).flatMap((r) => (r.tags || []).map((x) => String(x).trim())).filter(Boolean))];
  }

  /**
   * Every group or category already in use, for the box to offer.
   *
   * Across the print files AND the catalogue, because a shop with "Saudi Kings"
   * on both screens has ONE collection. Offering only this screen's names is how
   * the same group gets typed twice and drifts.
   */
  function knownNames(field) {
    const shared = _O();
    const pool = (printFiles || []).concat(typeof products !== 'undefined' && Array.isArray(products) ? products : []);
    if (shared) return shared.known(pool, field);
    const read = field === 'category' ? categoryOf : groupOf;
    return [...new Set(pool.map(read).filter(Boolean))].sort();
  }

  const nameOptions = (field) =>
    knownNames(field).map((f) => `<option value="${escapeHtml(f)}"></option>`).join('');

  /**
   * A row of chips for one axis. Absent entirely when nothing is filed under it,
   * because an empty filter bar is a control that teaches the shop nothing.
   */
  function fileBarHtml(field) {
    const { names, unfiled, total } = filedUnder(field);
    if (!names.length) return '';
    const isCat = field === 'category';
    const act = isCat ? 'pf-cat' : 'pf-folder';
    const attr = isCat ? 'data-cat' : 'data-folder';
    const active = isCat ? _catFilter : _folderFilter;
    const chip = (val, label, n, on) =>
      `<button type="button" class="pf-folderchip ${on ? 'on' : ''}" data-act="${act}"`
      + (val === UNFILED ? ' data-unfiled="1"' : ` ${attr}="${escapeHtml(val)}"`)
      + `>${escapeHtml(label)}${n != null ? ` <span class="pf-tagchip-n">${n}</span>` : ''}</button>`;
    let html = chip('', t(isCat ? 'plib.all_cats' : 'plib.all_files') || 'All', total, !active);
    html += names.map(([f, n]) => chip(f, f, n, active && active.toLowerCase() === f.toLowerCase())).join('');
    if (unfiled) html += chip(UNFILED, t(isCat ? 'plib.uncategorised' : 'plib.unfiled') || 'Unfiled', unfiled, active === UNFILED);
    const label = t(isCat ? 'plib.filter_cats' : 'plib.filter_folders') || 'Filter';
    return `<div class="pf-folderbar" role="group" aria-label="${escapeHtml(label)}">${html}</div>`;
  }

  /* Distinct tags across all files, most-used first, for the filter bar.
   *
   * Through lib/tags.js, which folds the spellings. This keyed on the exact
   * string, so a shop that had typed "resin" and "Resin" saw TWO chips for one
   * idea and each found only its own share of the files — the drift the tag
   * work exists to stop. The chip now says the spelling used most and its count
   * is the real one. */
  const _T = () => (typeof window !== 'undefined' && window.KhaytTags) || null;
  /** lib/print-file-parts.js — a print may be several files (Spiderman is a
   *  head, two arms and a torso). Falls back to reading the record the old way
   *  so a build that has not loaded the module still shows the primary file. */
  const _P = () => (typeof window !== 'undefined' && window.KhaytPrintParts) || null;
  /** lib/organise.js — GROUPS (a set that belongs together: the Saudi Kings)
   *  and CATEGORIES (what a thing is: busts, functional parts). One vocabulary
   *  shared with the catalogue, and one spelling per name. `group` is the field
   *  that used to be called `folder`; nothing is migrated, both are written. */
  const _O = () => (typeof window !== 'undefined' && window.KhaytOrganise) || null;
  const groupOf = (rec) => (_O() ? _O().groupOf(rec) : String((rec && (rec.group || rec.folder)) || '').trim());
  const categoryOf = (rec) => (_O() ? _O().categoryOf(rec) : String((rec && rec.category) || '').trim());
  const partsOf = (rec) => (_P() ? _P().partsOf(rec) : (rec && rec.sourceFile ? [rec.sourceFile] : []));
  /** lib/print-versions.js — big and small, coloured and plain: alternatives
   *  printed INSTEAD OF each other, each with its own time and weight. */
  const _V = () => (typeof window !== 'undefined' && window.KhaytPrintVersions) || null;
  function allTags() {
    const shared = _T();
    if (shared) return shared.tagCounts(printFiles || []);
    const counts = new Map();
    for (const r of (printFiles || [])) for (const tg of (r.tags || [])) {
      const key = String(tg).trim();
      if (key) counts.set(key, (counts.get(key) || 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  }

  function tagBarHtml() {
    const tags = allTags();
    if (!tags.length) return '';
    const chips = tags.map(([tg, n]) =>
      `<button type="button" class="pf-tagchip ${_tagFilter && _tagFilter.toLowerCase() === tg.toLowerCase() ? 'on' : ''}" data-act="pf-tag" data-tag="${escapeHtml(tg)}">${escapeHtml(tg)} <span class="pf-tagchip-n">${n}</span></button>`).join('');
    const clear = _tagFilter ? `<button type="button" class="pf-tagchip pf-tagclear" data-act="pf-tag-clear">✕ ${escapeHtml(t('plib.tag_clear') || 'Clear')}</button>` : '';
    return `<div class="pf-tagbar" role="group" aria-label="${escapeHtml(t('plib.filter_tags') || 'Filter by tag')}">${chips}${clear}</div>`;
  }

  /* Is there a cloud to sync to? Same test Settings uses. A sync button with
   * nowhere to send anything is worse than no button — it looks broken. */
  /**
   * Push the library to the cloud now.
   *
   * Sync already runs on a schedule; this is for the moment a shop has just
   * added files and wants them somewhere safe before closing the laptop —
   * asked for as "why do I need to sync by going to settings?". It says what
   * happened either way, because a silent button is indistinguishable from a
   * broken one.
   */
  async function syncLibraryNow() {
    const cs = _cloudSync();
    if (!cs) return;
    try {
      await cs.syncNow();
      toast(t('plib.synced') || 'Library synced to Khayt Cloud.', 'success');
    } catch (e) {
      console.error('library sync failed', e);
      toast((t('plib.sync_failed') || 'Could not sync') + (e && e.message ? ` — ${e.message}` : ''), 'error', 6000);
    }
  }

  /* An accessor, never a bare global. Bed Ready shares this screen and does not
   * ship cloud sync, so reading the name directly is a ReferenceError waiting
   * for whoever opens the library there — the same rule the rest of this file
   * already follows for its optional modules. */
  function _cloudSync() {
    return (typeof globalThis !== 'undefined' && globalThis.KhaytCloudSync) || null;
  }
  function _cloudOn() {
    const c = (typeof settings !== 'undefined' && settings && settings.cloud) || {};
    return !!(c.enabled && c.url && c.shopId && _cloudSync());
  }

  /* Pictures fetched from the vault, kept for the life of the window.
   *
   * Bounded, because the point of moving them out of the store was to stop
   * holding every picture in the library at once: a thousand thumbnails is
   * 14 MB whether it is the store holding them or this Map. Oldest out first —
   * a shop scrolls a library, it does not revisit at random. */
  const _thumbCache = new Map();
  /* Big enough to hold what is on screen, always.
   *
   * A fixed 300 was fine while the grid drew one screenful; with paging, a shop
   * who has grown the page to 600 has 600 cards wanting a picture against a
   * 300-entry cache, so EVERY repaint refetched the whole page from disk and the
   * arriving batch evicted the front of itself. Starring one file cost 300 disk
   * reads — the exact per-press cost paging exists to remove.
   *
   * It follows the page instead: a headroom of one page over what is painted, so
   * the entries evicted are ones that scrolled away. Each entry is a ~13 KB data
   * URL, so 1,000 is about 13 MB — the ceiling is there to stop a very long
   * session, not to ration a screen. */
  let THUMB_CACHE_MAX = 300;
  const THUMB_CACHE_CEILING = 1000;
  function growThumbCache(painted) {
    THUMB_CACHE_MAX = Math.min(THUMB_CACHE_CEILING, Math.max(300, painted + PAGE));
  }
  function cacheThumb(id, src) {
    if (_thumbCache.has(id)) _thumbCache.delete(id);
    _thumbCache.set(id, src);
    while (_thumbCache.size > THUMB_CACHE_MAX) _thumbCache.delete(_thumbCache.keys().next().value);
  }

  /** Fetch the pictures for the rows just drawn, in ONE call, and fill them in
   *  where they belong — patching the <img> rather than re-rendering, so the
   *  grid is not rebuilt for something as small as a picture arriving. */
  async function warmThumbs(rows) {
    const hub = api();
    if (!hub || !hub.printLibLoadThumbs) return;
    /* The gallery draws <figure class="pf-shot"> from `userPhoto`, not cards
     * from `thumbFile`. Warming there read up to a page of previews off disk,
     * found no `.pf-card` to patch, threw them away — and evicted the library's
     * cache entries on the way out. */
    if (_view === 'gallery') return;
    const wanted = (rows || [])
      .filter((r) => r && r.thumbFile && !r.thumb && !_thumbCache.has(r.id))
      .map((r) => ({ id: r.id, file: r.thumbFile }));
    if (!wanted.length) return;
    let got = null;
    try { got = await hub.printLibLoadThumbs(wanted); } catch (_) { return; }
    for (const [id, src] of Object.entries(got || {})) {
      cacheThumb(id, src);
      const img = document.querySelector(`.pf-card[data-id="${CSS.escape(id)}"] .pf-thumb`);
      if (img && img.tagName === 'IMG') img.src = safeImageSrc(src);
    }
  }

  function thumbHtml(rec) {
    const src = rec.thumb || rec.userPhoto || _thumbCache.get(rec.id) || null;
    if (src) return `<img class="pf-thumb" src="${safeImageSrc(src)}" alt="" loading="lazy">`;
    /* Known to have a picture, just not fetched yet. An empty <img> holds the
     * card's shape so the grid does not jump when it arrives — a reflow of a
     * thousand cards is the thing this change is trying not to do. */
    if (rec.thumbFile) return `<img class="pf-thumb" src="" alt="" loading="lazy">`;
    const ext = rec.sourceFile?.ext;
    const ico = (_BDR && window.BedReadyIcons)
      ? window.BedReadyIcons.get(EXT_ICON_NAME[ext] || 'cube', 44)
      : (EXT_ICON[ext] || '📦');
    /* Say WHY there is no picture.
     *
     * Khayt never renders a model to make one: it lifts the preview the slicer
     * already embedded (a PNG block in gcode, Metadata/*.png in a 3MF), and
     * renders STL separately. So a card with no preview means one of two quite
     * different things, and a bare box says neither — reported as "why in
     * printfile every file has a box as an image, isn't it supposed to load the
     * 3D file?"
     *
     * `sourceFile: null` is a record with no file on this computer at all —
     * every one built by importing a printer's job history, which carries names,
     * times and weights and no geometry. There is nothing to preview and never
     * was. The other case is a real file whose slicer embedded no thumbnail. */
    const why = rec.sourceFile
      ? (t('plib.no_preview') || 'This file has no preview embedded by the slicer.')
      : (t('plib.no_file') || 'No file on this computer — this record came from the printer\'s own history, so there is nothing to preview.');
    return `<div class="pf-thumb pf-thumb-icon" title="${escapeHtml(why)}">${ico}</div>`;
  }

  function colorDotsHtml(rec) {
    if (!Array.isArray(rec.colors) || !rec.colors.length) return '';
    const cols = rec.colors.slice(0, 8);
    // Bed Ready shows colours as CAD layer-index chips (real filament colour + index-coded hairline
    // + a mono L-number) instead of a rainbow of dots — the Cyanotype Draft "layer index" device.
    const dots = _BDR
      ? cols.map((c, i) => `<span class="pf-lchip" title="${escapeHtml(c.label || c.hex)}${c.grams ? ' · ' + c.grams + ' g' : ''}"><span class="pf-lchip-sw" style="background:${escapeHtml(c.hex)};border-color:var(--l${(i % 6) + 1})"></span><span class="pf-lchip-n">L${i + 1}</span></span>`).join('')
      : cols.map((c) => `<span class="pf-dot" title="${escapeHtml(c.label || c.hex)}${c.grams ? ' · ' + c.grams + ' g' : ''}" style="background:${escapeHtml(c.hex)}"></span>`).join('');
    const swap = rec.swapCount > 0 ? `<span class="pf-chip">↔ ${rec.swapCount} ${escapeHtml(t('plib.swaps') || 'swaps')}</span>` : '';
    return `<div class="pf-colors">${dots}${swap}</div>`;
  }

  function metaChips(rec) {
    const p = rec.parsed || {};
    const chips = [];
    const ext = rec.sourceFile?.ext; if (ext) chips.push(ext.toUpperCase());
    const tm = fmtTime(p.printTimeMins); if (tm) chips.push((_BDR ? '' : '⏱ ') + tm);
    if (p.filamentGrams) chips.push((_BDR ? '' : '⛁ ') + Math.round(p.filamentGrams) + ' g');
    if (p.slicer) chips.push(escapeHtml(p.slicer));
    if (p.bbox && p.bbox.x) chips.push(`${Math.round(p.bbox.x)}×${Math.round(p.bbox.y)}×${Math.round(p.bbox.z)} mm`);
    /* The size of the PRINT, not of its first file. A four-part Spiderman that
     * said "42 MB" because that is what the head weighs would be describing a
     * quarter of what you are about to print. */
    const sz = fmtSize(_P() ? _P().totalSize(rec) : rec.sourceFile?.size); if (sz) chips.push(sz);
    /* No "7 files" chip: partsListHtml() below says it on the same condition,
     * and says it as something you can open. The card carried both, one inert
     * line under the other. */
    return chips.map((c) => `<span class="pf-chip">${escapeHtml(String(c))}</span>`).join('');
  }

  /**
   * The files this print is made of, when there is more than one.
   *
   * Collapsed. A Spiderman kit is a dozen STLs, and a dozen rows on every card
   * would bury the print under its own parts — the row of chips already says
   * "12 files", and this is where you go when that number is the thing you want
   * to act on.
   *
   * The primary is marked rather than hidden: it is the file the card speaks
   * for — its icon, its extension, what "Convert" and "View in 3D" resolve to —
   * so which part holds that job has to be visible and has to be changeable.
   */
  function partsListHtml(rec) {
    const parts = partsOf(rec);
    if (parts.length < 2) return '';
    const primaryLabel = t('plib.part_primary') || 'Main file';
    return `<details class="pf-parts">
      <summary>${_bi('doc', '📄')}${escapeHtml(t('plib.n_files', { n: String(parts.length) }) || `${parts.length} files`)}</summary>
      <div class="pf-part-list">${parts.map((f, i) => `
        <div class="pf-part${i === 0 ? ' is-primary' : ''}">
          <span class="pf-part-name" title="${escapeHtml(f.originalName || f.filename)}">${escapeHtml(f.originalName || f.filename)}</span>
          ${i === 0 ? `<span class="pf-part-tag">${escapeHtml(primaryLabel)}</span>` : ''}
          <span class="pf-part-size">${escapeHtml(fmtSize(f.size) || '')}</span>
          <button class="btn small ghost icon" data-act="pf-part-open" data-id="${escapeHtml(rec.id)}" data-fn="${escapeHtml(f.filename)}" aria-label="${escapeHtml(t('plib.open_slicer') || 'Open in slicer')}" title="${escapeHtml(t('plib.open_slicer') || 'Open in slicer')}">${_bi('printer', '🖨')}</button>
          ${i === 0 ? '' : `<button class="btn small ghost icon" data-act="pf-part-primary" data-id="${escapeHtml(rec.id)}" data-fn="${escapeHtml(f.filename)}" aria-label="${escapeHtml(t('plib.make_primary') || 'Make this the main file')}" title="${escapeHtml(t('plib.make_primary') || 'Make this the main file')}">${_bi('target', '◎')}</button>`}
          <button class="btn small ghost danger icon" data-act="pf-part-del" data-id="${escapeHtml(rec.id)}" data-fn="${escapeHtml(f.filename)}" aria-label="${escapeHtml(t('plib.remove_part') || 'Remove this file from the print')}" title="${escapeHtml(t('plib.remove_part') || 'Remove this file from the print')}">${_bi('trash', '🗑')}</button>
        </div>`).join('')}</div>
    </details>`;
  }

  /**
   * The bar that appears once selecting is on.
   *
   * It says how many are held even when the filter has moved on, because the
   * alternative — a count of what is both selected and visible — would make
   * "select the busts, then also the minis" impossible to trust.
   */
  function bulkBarHtml() {
    /* Not in the gallery. Its figures have no checkbox and no picked state, so
     * the bar was floating over photos it could not mark — while still offering
     * Delete for a selection nobody could see. */
    if (!_selectMode || _view === 'gallery') return '';
    const n = _selected.size;
    const shown = filtered(_query);
    const allShown = shown.length > 0 && shown.every((r) => _selected.has(r.id));
    const has = n > 0;
    return `<div class="pf-bulk" role="group" aria-label="${escapeHtml(t('plib.bulk_label') || 'Work on several files')}">
      <span class="pf-bulk-n">${escapeHtml(t('plib.n_selected', { n: String(n) }) || `${n} selected`)}</span>
      <button class="btn small ghost" data-act="pf-pick-all">${escapeHtml(
        (allShown ? t('plib.pick_none_shown') : t('plib.pick_all_shown', { n: String(shown.length) }))
        || (allShown ? 'Clear these' : `Select all ${shown.length} shown`))}</button>
      <span class="pf-bulk-sep"></span>
      <button class="btn small ghost" data-act="pf-bulk-group" ${has ? '' : 'disabled'}>${_bi('folder', '🗂')}${escapeHtml(t('plib.group') || 'Group')}</button>
      <button class="btn small ghost" data-act="pf-bulk-cat" ${has ? '' : 'disabled'}>${_bi('board', '▦')}${escapeHtml(t('plib.category') || 'Category')}</button>
      <button class="btn small ghost" data-act="pf-bulk-tag" ${has ? '' : 'disabled'}>${escapeHtml(t('plib.tags_short') || 'Tags')}</button>
      <button class="btn small ghost danger" data-act="pf-bulk-del" ${has ? '' : 'disabled'}>${_bi('trash', '🗑')}${escapeHtml(t('common.delete') || 'Delete')}</button>
      <span class="act-end"></span>
      <button class="btn small" data-act="pf-select-off">${escapeHtml(t('common.done') || 'Done')}</button>
    </div>`;
  }

  /** The held records, in library order, skipping any that have since gone. */
  const selectedRecords = () => (printFiles || []).filter((r) => _selected.has(r.id));

  function renderBulkBar() {
    const host = document.getElementById('pfBulk');
    if (host) host.innerHTML = bulkBarHtml();
  }

  /**
   * Toggle one card WITHOUT redrawing the grid.
   *
   * A full redraw is 41 ms at a thousand cards and 79 ms at two thousand, and
   * selecting twenty files would pay it twenty times. Only the one card and the
   * bar change, so this stays instant however big the library is.
   */
  function togglePick(id) {
    if (_selected.has(id)) _selected.delete(id); else _selected.add(id);
    const card = document.querySelector(`.pf-card[data-id="${CSS.escape(id)}"]`);
    if (card) {
      const on = _selected.has(id);
      card.classList.toggle('is-picked', on);
      const box = card.querySelector('[data-act="pf-pick"]');
      if (box) { box.checked = on; box.setAttribute('aria-checked', String(on)); }
    }
    renderBulkBar();
  }

  /* "Shown" means every record the filter matches, NOT the page that happens to
   * be painted. A shop that narrows to seven hundred kings and presses this is
   * asking for seven hundred, and the bar's count says seven hundred. */
  function pickAllShown() {
    const shown = filtered(_query);
    const allShown = shown.length > 0 && shown.every((r) => _selected.has(r.id));
    for (const r of shown) { if (allShown) _selected.delete(r.id); else _selected.add(r.id); }
    renderList();
    renderBulkBar();
  }

  function setSelectMode(on) {
    _selectMode = on;
    if (!on) _selected.clear();
    renderPrintFiles();
  }

  /**
   * File everything selected under one name.
   *
   * Through lib/organise.js, so the name lands in the spelling the shop already
   * uses — the whole point of doing two hundred at once is that they end up
   * identical, and two hundred records each carrying whatever was typed that
   * time is the drift this exists to stop.
   *
   * An empty box CLEARS the field on all of them. That is a real thing to want
   * ("take these out of the group") and the dialog says so rather than leaving
   * a shop guessing whether blank means "clear" or "leave alone".
   */
  function bulkFile(field) {
    const recs = selectedRecords();
    if (!recs.length) return;
    const isCat = field === 'category';
    const known = knownNames(field);
    openFormModal({
      title: (isCat ? t('plib.bulk_cat_title') : t('plib.bulk_group_title')) || 'Set for the selected files',
      sizeLg: false, saveLabel: t('common.save') || 'Save',
      bodyHtml: `
        <p class="pf-pick-hint">${escapeHtml((t('plib.bulk_count', { n: String(recs.length) }) || `${recs.length} files selected.`))}</p>
        <label>${escapeHtml((isCat ? t('plib.category') : t('plib.group')) || 'Name')}</label>
        <input type="text" id="pfBulkName" list="pfBulkList" maxlength="60" value=""
               placeholder="${escapeHtml((isCat ? t('plib.category_ph') : t('plib.group_ph')) || '')}">
        <datalist id="pfBulkList">${known.map((n) => `<option value="${escapeHtml(n)}"></option>`).join('')}</datalist>
        <p class="pf-pick-hint" style="margin-top:8px;">${escapeHtml(t('plib.bulk_clear_hint') || 'Leave it empty to take these files out of it.')}</p>`,
      onSave(modal) {
        const value = modal.querySelector('#pfBulkName').value || '';
        const O = _O();
        const kn = { group: knownNames('group'), category: knownNames('category') };
        for (const rec of recs) {
          Object.assign(rec, O ? O.assign(rec, { [field]: value }, kn)
            : (isCat ? { category: value.trim() } : { group: value.trim(), folder: value.trim() }));
          rec.updatedAt = Date.now();
        }
        saveAll();
        renderPrintFiles();
        toast(t('plib.bulk_filed', { n: String(recs.length) }) || `${recs.length} files updated`, 'success');
      },
    });
  }

  /**
   * Add or remove a tag across the selection.
   *
   * Two separate actions rather than one box that replaces everything: tags are
   * a list, and a bulk edit that REPLACED them would quietly throw away whatever
   * each file already carried. Adding is the safe, common case.
   */
  function bulkTag() {
    const recs = selectedRecords();
    if (!recs.length) return;
    const known = knownTags();
    openFormModal({
      title: t('plib.bulk_tag_title') || 'Tags for the selected files',
      sizeLg: false, saveLabel: t('common.save') || 'Save',
      bodyHtml: `
        <p class="pf-pick-hint">${escapeHtml((t('plib.bulk_count', { n: String(recs.length) }) || `${recs.length} files selected.`))}</p>
        <label>${escapeHtml(t('plib.tags') || 'Tags (comma separated)')}</label>
        <input type="text" id="pfBulkTags" value="" placeholder="${escapeHtml(known.slice(0, 3).join(', '))}">
        <div class="pf-tagpicks">${known.slice(0, 24).map((tg) => `<button type="button" class="pf-tag" data-bulktag="${escapeHtml(tg)}">${escapeHtml(tg)}</button>`).join('')}</div>
        <div class="seg" style="margin-top:10px;" role="group" aria-label="${escapeHtml(t('plib.bulk_tag_mode') || 'Add or remove')}">
          <button type="button" class="btn small state-on" id="pfTagAdd" aria-pressed="true">${escapeHtml(t('plib.bulk_tag_add') || 'Add to these files')}</button>
          <button type="button" class="btn small" id="pfTagRemove" aria-pressed="false">${escapeHtml(t('plib.bulk_tag_remove') || 'Remove from these files')}</button>
        </div>`,
      onMount(modal) {
        const input = modal.querySelector('#pfBulkTags');
        modal.querySelectorAll('[data-bulktag]').forEach((chip) => chip.addEventListener('click', () => {
          const cur = input.value.split(',').map((x) => x.trim()).filter(Boolean);
          const k = String(chip.dataset.bulktag).toLowerCase();
          const next = cur.some((x) => x.toLowerCase() === k)
            ? cur.filter((x) => x.toLowerCase() !== k)
            : cur.concat(chip.dataset.bulktag);
          input.value = next.join(', ');
          chip.classList.toggle('on');
        }));
        const add = modal.querySelector('#pfTagAdd'), rem = modal.querySelector('#pfTagRemove');
        const mode = (removing) => {
          add.classList.toggle('state-on', !removing); add.setAttribute('aria-pressed', String(!removing));
          rem.classList.toggle('state-on', removing); rem.setAttribute('aria-pressed', String(removing));
          modal.dataset.removing = removing ? '1' : '';
        };
        add.addEventListener('click', () => mode(false));
        rem.addEventListener('click', () => mode(true));
      },
      onSave(modal) {
        const T = _T();
        const typed = T ? T.normaliseTags(modal.querySelector('#pfBulkTags').value, known)
          : modal.querySelector('#pfBulkTags').value.split(',').map((x) => x.trim()).filter(Boolean);
        if (!typed.length) return false;              // nothing to do; keep the dialog open
        const removing = !!modal.dataset.removing;
        const keys = new Set(typed.map((x) => String(x).toLowerCase()));
        for (const rec of recs) {
          const have = Array.isArray(rec.tags) ? rec.tags : [];
          rec.tags = removing
            ? have.filter((x) => !keys.has(String(x).toLowerCase()))
            // Through normaliseTags so the ADDED tag adopts the shop's spelling
            // and a file that already carries it does not gain a second copy.
            : (T ? T.normaliseTags(have.concat(typed), known) : have.concat(typed.filter((x) => !have.some((y) => String(y).toLowerCase() === String(x).toLowerCase()))));
          rec.updatedAt = Date.now();
        }
        saveAll();
        renderPrintFiles();
        toast((removing ? t('plib.bulk_untagged', { n: String(recs.length) }) : t('plib.bulk_tagged', { n: String(recs.length) }))
          || `${recs.length} files updated`, 'success');
      },
    });
  }

  /**
   * Delete everything selected, and its files.
   *
   * The count is in the sentence and in the button, because "Delete" over a
   * selection the shop can no longer see all of is the most expensive mistake
   * this screen can make. Deleting reports what actually went: a file that could
   * not be removed from disk must not read as gone.
   */
  function bulkDelete() {
    const recs = selectedRecords();
    if (!recs.length) return;
    const n = recs.length;
    openFormModal({
      title: t('plib.bulk_del_title') || 'Delete the selected files',
      sizeLg: false,
      saveLabel: (t('plib.bulk_del_btn', { n: String(n) }) || `Delete ${n} files`),
      bodyHtml: `<p>${escapeHtml((t('plib.bulk_del_confirm', { n: String(n) })
        || `Remove ${n} print files and everything they hold on disk? This cannot be undone.`))}</p>
        <ul class="pf-del-list">${recs.slice(0, 8).map((r) => `<li>${escapeHtml(r.name || r.originalName || r.id)}</li>`).join('')}
        ${n > 8 ? `<li class="pf-del-more">${escapeHtml(t('plib.and_n_more', { n: String(n - 8) }) || `…and ${n - 8} more`)}</li>` : ''}</ul>`,
      async onSave() {
        const hub = api();
        let allGone = true, removed = 0;
        for (const rec of recs) {
          if (hub && hub.printLibList && hub.printLibDelete) {
            try {
              const files = await hub.printLibList(rec.id);
              for (const f of (files || [])) if ((await hub.printLibDelete(f.fullPath)) === false) allGone = false;
            } catch (e) { console.error('printLibDelete:', e); allGone = false; }
          }
          removed++;
        }
        const ids = new Set(recs.map((r) => r.id));
        printFiles = (printFiles || []).filter((r) => !ids.has(r.id));
        _selected.clear();
        saveAll();
        renderPrintFiles();
        if (allGone) toast(t('plib.bulk_deleted', { n: String(removed) }) || `${removed} files deleted`, 'success');
        else toast('⚠ ' + (t('plib.delete_partial') || 'Removed from the library, but some files could not be deleted from disk'), 'error', 7000);
      },
    });
  }

  function cardHtml(rec) {
    const prof = rec.slicerProfileId && (slicerProfiles || []).find((s) => s.id === rec.slicerProfileId);
    return `
      <div class="pf-card${_selectMode && _selected.has(rec.id) ? ' is-picked' : ''}" data-id="${escapeHtml(rec.id)}">
        <!-- Not wrapped in a <label>: a label click forwards a SECOND click to
             the input, so the handler ran twice and the card never changed. The
             box is sized in CSS to be a real target instead. -->
        ${_selectMode ? `<input type="checkbox" class="pf-pick" data-act="pf-pick" data-id="${escapeHtml(rec.id)}"${_selected.has(rec.id) ? ' checked' : ''} title="${escapeHtml(t('plib.pick') || 'Select this file')}" aria-label="${escapeHtml(t('plib.pick') || 'Select this file')}">` : ''}
        <button class="pf-fav ${rec.favorite ? 'on' : ''}" data-act="pf-fav" data-id="${escapeHtml(rec.id)}" title="${escapeHtml(t('plib.favorite') || 'Favorite')}">${rec.favorite ? '★' : '☆'}</button>
        ${thumbHtml(rec)}
        <div class="pf-body">
          <div class="pf-name" title="${escapeHtml(rec.originalName || rec.name)}">${escapeHtml(rec.name || rec.originalName || 'Untitled')}</div>
          <div class="pf-chips">${metaChips(rec)}</div>
          ${partsListHtml(rec)}
          ${colorDotsHtml(rec)}
          ${prof ? `<div class="pf-prof">${_bi('nozzle', '🛠')}${escapeHtml(prof.name)}</div>` : ''}
          ${rec.testedNotes ? `<div class="pf-notes">${escapeHtml(rec.testedNotes)}</div>` : ''}
          ${(() => {
            /* Where this print is filed, and what it is. Both are buttons that
             * FILTER — the fastest way to "show me the rest of the Saudi Kings"
             * is the chip on the king you are already looking at. */
            const g = groupOf(rec), c = categoryOf(rec);
            const tags = Array.isArray(rec.tags) ? rec.tags : [];
            if (!g && !c && !tags.length) return '';
            const chip = (act, attr, val, icon, title, on) =>
              `<button type="button" class="pf-folder ${on ? 'on' : ''}" data-act="${act}" ${attr}="${escapeHtml(val)}" title="${escapeHtml(title)}">${icon}${escapeHtml(val)}</button>`;
            return '<div class="pf-tags">'
              + (g ? chip('pf-folder', 'data-folder', g, _bi('folder', '🗂'), t('plib.group') || 'Group',
                          _folderFilter && _folderFilter.toLowerCase() === g.toLowerCase()) : '')
              + (c ? chip('pf-cat', 'data-cat', c, _bi('board', '▦'), t('plib.category') || 'Category',
                          _catFilter && _catFilter.toLowerCase() === c.toLowerCase()) : '')
              + tags.map((tg) => `<button type="button" class="pf-tag ${_tagFilter && _tagFilter.toLowerCase() === String(tg).toLowerCase() ? 'on' : ''}" data-act="pf-tag" data-tag="${escapeHtml(tg)}">${escapeHtml(tg)}</button>`).join('')
              + '</div>';
          })()}
          ${duplicateLine(rec)}
          ${recommendedLine(rec)}
          ${(rec.timesPrinted || rec.timesFailed) ? `<div class="pf-history" title="${escapeHtml(t('plib.history_title') || 'Print history')}">${_bi('printer', '🖨')}${(rec.timesPrinted || 0)}× ${escapeHtml(t('plib.printed') || 'printed')}${rec.timesFailed ? ` · ${rec.timesFailed} ${escapeHtml(t('plib.failed') || 'failed')}` : ''}${rec.lastPrinted ? ` · ${escapeHtml(t('plib.last') || 'last')} ${escapeHtml(fmtPfDate(rec.lastPrinted))}` : ''}</div>` : ''}
          ${(() => {
            /* The versions of this print, as a row of choices. Picking one
             * changes what the card describes — its files, and the time and
             * weight it is quoted from — because that is what a version IS. */
            const V = _V();
            if (!V || !V.hasVersions(rec)) return '';
            const active = V.activeVersion(rec);
            return `<div class="pf-versions" role="group" aria-label="${escapeHtml(t('plib.versions') || 'Versions')}">`
              + V.versionsOf(rec).map((v, i) => {
                  const label = v.name || (t('plib.version_n', { n: String(i + 1) }) || `Version ${i + 1}`);
                  const on = active && String(active.id) === String(v.id);
                  return `<button type="button" class="pf-verchip ${on ? 'on' : ''}" data-act="pf-version" data-id="${escapeHtml(rec.id)}" data-ver="${escapeHtml(v.id)}" aria-pressed="${on ? 'true' : 'false'}">${escapeHtml(label)}</button>`;
                }).join('')
              + '</div>';
          })()}
          ${Array.isArray(rec.converted) && rec.converted.length && !(_V() && _V().hasVersions(rec)) ? `<div class="pf-converted">${rec.converted.map((c) => `
            <div class="pf-conv-row">
              <span class="pf-conv-name" title="${escapeHtml(c.filename)}">${_bi('convert', '🔄')}${escapeHtml(c.targetName || c.targetId || (t('conv.convert_short') || 'Converted'))}</span>
              <button class="btn small ghost icon" data-act="pf-conv-open" data-id="${escapeHtml(rec.id)}" data-fn="${escapeHtml(c.filename)}" title="${escapeHtml(t('plib.open_slicer') || 'Open in slicer')}">${_bi('printer', '🖨')}</button>
              <button class="btn small ghost danger icon" data-act="pf-conv-del" data-id="${escapeHtml(rec.id)}" data-fn="${escapeHtml(c.filename)}" aria-label="${escapeHtml(t('common.delete') || 'Delete')}" title="${escapeHtml(t('common.delete') || 'Delete')}">${_bi('trash', '🗑')}</button>
            </div>`).join('')}</div>` : ''}
        </div>
        <!-- ONE ROW SHAPE, WHATEVER THIS FILE CAN DO.
             Ten buttons wrapped here, and two cards side by side wrapped at
             different points, so nothing lined up across the grid and one card
             ended with a lone bin on a row of its own. What a record can do now
             changes the MENU; the row is always: the thing you came to do, the
             two things you do after every print, and everything else. -->
        <div class="act">
          <button class="btn small primary" data-act="pf-slice" data-id="${escapeHtml(rec.id)}">${_bi('printer', '🖨')}${escapeHtml(t('plib.open_slicer') || 'Open in slicer')}</button>
          <button class="btn small ghost icon" data-act="pf-log-print" data-id="${escapeHtml(rec.id)}" aria-label="${escapeHtml(t('plib.log_print') || 'Log a successful print')}" title="${escapeHtml(t('plib.log_print') || 'Log a successful print')}">${_bi('check', '✓')}</button>
          <button class="btn small ghost icon" data-act="pf-log-fail" data-id="${escapeHtml(rec.id)}" aria-label="${escapeHtml(t('plib.log_fail') || 'Log a failed print')}" title="${escapeHtml(t('plib.log_fail') || 'Log a failed print')}">${_bi('cross', '✗')}</button>
          <details class="ovf act-end">
            <summary class="btn small ghost icon" role="button" aria-label="${escapeHtml(t('common.more') || 'More actions')}" title="${escapeHtml(t('common.more') || 'More actions')}">${_bi('more', '⋯', 16)}</summary>
            <div class="ovf-menu">
              <button data-act="pf-setups" data-id="${escapeHtml(rec.id)}">${_bi('nozzle', '🛠')}${escapeHtml(t('setup.title') || 'Settings that worked')}</button>
              ${typeof openModelViewer === 'function' && /^(stl|3mf)$/i.test(rec.sourceFile?.ext || '') ? `<button data-act="pf-view3d" data-id="${escapeHtml(rec.id)}">${_bi('cube', '🧊')}${escapeHtml(t('plib.view3d') || 'View in 3D')}</button>` : ''}
              ${!rec.geometryKey ? `<button data-act="pf-identify" data-id="${escapeHtml(rec.id)}" title="${escapeHtml(t('plib.identify_hint') || 'Let Khayt recognise this model when you print it again')}">${_bi('search', '🔎')}${escapeHtml(t('plib.identify') || 'Identify')}</button>` : ''}
              ${Array.isArray(rec.colors) && rec.colors.filter((c) => c && c.hex).length > 1 ? `<button data-act="pf-plan" data-id="${escapeHtml(rec.id)}">${_bi('palette', '🎨')}${escapeHtml(t('plan.title') || 'Plan colours')}</button>` : ''}
              ${rec.sourceFile?.ext === '3mf' ? `<button data-act="pf-convert" data-id="${escapeHtml(rec.id)}">${_bi('convert', '🔄')}${escapeHtml(t('conv.convert_short') || 'Convert')}</button>` : ''}
              <button data-act="pf-add-parts" data-id="${escapeHtml(rec.id)}" title="${escapeHtml(t('plib.add_parts_hint') || 'A print can be several files — a head, two arms, a torso')}">${_bi('plus', '＋')}${escapeHtml(t('plib.add_parts') || 'Add files to this print')}</button>
              <button data-act="pf-edit" data-id="${escapeHtml(rec.id)}">${_bi('pencil', '✏')}${escapeHtml(t('common.edit') || 'Edit')}</button>
              <!-- Under a rule and last: delete used to sit one button along
                   from "Open in slicer". -->
              <div class="ovf-sep"></div>
              <button class="danger" data-act="pf-del" data-id="${escapeHtml(rec.id)}">${_bi('trash', '🗑')}${escapeHtml(t('common.delete') || 'Delete')}</button>
            </div>
          </details>
        </div>
      </div>`;
  }

  let _query = '';
  let _tagFilter = ''; // active tag filter (empty = all)
  /* "In neither" is its OWN ATTRIBUTE, not a magic value in the name attribute.
   *
   * This was `'\u0000unfiled'`, written into `data-folder` — and the HTML
   * tokenizer replaces U+0000 in an attribute value with U+FFFD, so what came
   * back off `dataset` was `'\uFFFDunfiled'` and never equalled the sentinel it
   * was compared against. The Unfiled chip set a filter matching no group,
   * normalizeFilters quietly reset it, and the grid redrew identical to All. It
   * has never worked, and adding a Category axis doubled it into two dead chips.
   *
   * Verified in a real parser: `fffd,75,6e,66,69,6c,65,64`.
   *
   * A separate attribute cannot collide with a name and cannot be mangled. The
   * value still travels in code, where a string is a string. */
  const UNFILED = '\u2400unfiled';   // in code only; never written to markup
  let _folderFilter = ''; // '' = all, UNFILED = no group, else group name
  let _catFilter = '';    // the other axis; the two narrow together
  /** Two filter values meaning the same thing. UNFILED compares exactly; a name
   *  compares the way the rest of this file compares names. */
  const sameFilter = (a, b) => (a === UNFILED || b === UNFILED)
    ? a === b
    : String(a || '').toLowerCase() === String(b || '').toLowerCase();
  /* ── WORKING ON MANY FILES AT ONCE ────────────────────────────────────────
   * Groups and categories are worth nothing at scale without this: filing two
   * hundred kings one dialog at a time is not filing them. Selection is by
   * RECORD ID and survives the filter changing, deliberately — the way you
   * select a big set is to narrow to part of it, take all of that, narrow to
   * the next part, and take that too. The bar always says how many are held,
   * including the ones no longer on screen. */
  let _selectMode = false;
  const _selected = new Set();
  /* ── HOW MANY CARDS ARE ACTUALLY DRAWN ────────────────────────────────────
   * Measured, not guessed: painting every card takes 95 ms at 400 records and
   * 701 ms at 3,415 — and that is paid on every filter press, every star, and
   * every round of the thumbnail migration. Nearly a second of frozen window
   * for a library the size of a real one.
   *
   * So a page is drawn and the rest arrives as you reach it. The number is not
   * a limit on anything: search and the filters narrow the WHOLE library first
   * (0.2-1.0 ms per thousand), and it is the painting that costs. */
  const PAGE = 120;
  let _page = PAGE;
  let _view = 'library'; // 'library' | 'gallery'

  // Finished-prints gallery: a photo-forward showcase of every print file you've
  // added a photo to, with its material, tested settings and print tally. A local
  // personal portfolio — nothing to sell, just what you've made and how.
  /**
   * What the list is showing right now, whichever view is on.
   *
   * ONE definition. The gallery filtered `printFiles` for a photo while
   * showMore asked `filtered(_query)` how much there was, so the two could
   * disagree about what "the rest" even is — and a paged list where the page and
   * the count are computed in different places is a bug waiting for whoever
   * adds the third view.
   */
  function visibleRows() {
    return _view === 'gallery'
      ? (printFiles || []).filter((r) => r.userPhoto)
      : filtered(_query);
  }

  function galleryHtml() {
    const shots = visibleRows();
    if (!shots.length) {
      return `<div class="pf-empty">${escapeHtml(t('plib.gallery_empty') || 'No print photos yet — add a photo to a print file to start your gallery.')}</div>`;
    }
    /* Paged like the library, and for a sharper reason: every figure here holds
     * a FULL PHOTO, not a 320px preview. Drawing a thousand of them at once is
     * a thousand images decoded before anything appears. */
    const painted = shots.slice(0, _page);
    const more = shots.length - painted.length;
    const tail = more > 0 ? `<div class="pf-more" id="pfMore">
        <button class="btn ghost small" data-act="pf-more">${escapeHtml(t('plib.show_more', { n: String(Math.min(more, PAGE)) }))}</button>
        <span class="pf-more-n">${escapeHtml(t('plib.n_of_m', { n: String(painted.length), m: String(shots.length) }))}</span>
      </div>` : '';
    return `<div class="pf-gallery">${painted.map((r) => `
      <figure class="pf-shot" data-act="pf-edit" data-id="${escapeHtml(r.id)}" title="${escapeHtml(t('common.edit') || 'Edit')}">
        <img src="${safeImageSrc(r.userPhoto)}" alt="${escapeHtml(r.name || '')}" loading="lazy">
        <figcaption>
          <div class="pf-shot-name">${escapeHtml(r.name || r.originalName || 'Untitled')}</div>
          <div class="pf-shot-meta">
            ${r.material ? `<span>${escapeHtml(r.material)}</span>` : ''}
            ${(r.timesPrinted || r.timesFailed) ? `<span>${_bi('printer', '🖨')}${(r.timesPrinted || 0)}×${r.timesFailed ? ` · ${r.timesFailed} ${escapeHtml(t('plib.failed') || 'failed')}` : ''}</span>` : ''}
          </div>
          ${r.testedNotes ? `<div class="pf-shot-notes">${escapeHtml(r.testedNotes)}</div>` : ''}
        </figcaption>
      </figure>`).join('')}</div>${tail}`;
  }

  // Inner HTML of the results area only (grid / gallery / empty state). Kept separate from the
  // header + search box so a keystroke re-renders just the list, leaving the <input> — and its
  // caret — untouched.
  // Drop a folder/tag filter that no longer matches any file (e.g. its last file was re-foldered or
  // deleted) so the grid can't get stuck on an empty, unclearable filter.
  function normalizeFilters() {
    const list = printFiles || [];
    if (_folderFilter === UNFILED) { if (!list.some((r) => !groupOf(r))) _folderFilter = ''; }
    else if (_folderFilter && !list.some((r) => groupOf(r).toLowerCase() === _folderFilter.toLowerCase())) _folderFilter = '';
    if (_catFilter === UNFILED) { if (!list.some((r) => !categoryOf(r))) _catFilter = ''; }
    else if (_catFilter && !list.some((r) => categoryOf(r).toLowerCase() === _catFilter.toLowerCase())) _catFilter = '';
    if (_tagFilter && !list.some((r) => (r.tags || []).some((tg) => tg.toLowerCase() === _tagFilter.toLowerCase()))) _tagFilter = '';
  }

  function listInnerHtml() {
    normalizeFilters();
    const hasHub = !!(api() && api().printLibPick);
    const isGallery = _view === 'gallery';
    const rows = visibleRows();
    const total = (printFiles || []).length;
    if (!hasHub) return `<div class="pf-empty">${escapeHtml(t('plib.desktop_only') || 'The print-file library is available in the desktop app.')}</div>`;
    if (isGallery) return galleryHtml();
    const painted = rows.slice(0, _page);
    const more = rows.length - painted.length;
    const grid = rows.length
      ? `<div class="pf-grid">${painted.map(cardHtml).join('')}</div>`
        + (more > 0 ? `<div class="pf-more" id="pfMore">
             <button class="btn ghost small" data-act="pf-more">${escapeHtml(t('plib.show_more', { n: String(Math.min(more, PAGE)) }))}</button>
             <span class="pf-more-n">${escapeHtml(t('plib.n_of_m', { n: String(painted.length), m: String(rows.length) }))}</span>
           </div>` : '')
      : `<div class="pf-empty">${escapeHtml(total ? ((_tagFilter || _folderFilter || _catFilter) ? (t('plib.no_filter_match') || 'No files match this filter.') : (t('plib.no_match') || 'No files match your search.')) : (t('plib.empty') || 'No print files yet. Add your first STL, 3MF or G-code file.'))}</div>`;
    return fileBarHtml('group') + fileBarHtml('category') + tagBarHtml() + grid;
  }

  function renderList() {
    const list = document.getElementById('pfList');
    if (list) list.innerHTML = listInnerHtml();
    // The pictures for WHAT WAS JUST DRAWN. This asked for every match — 3,415
    // thumbnails off disk to fill in 120 cards, on every keystroke.
    warmThumbs(visibleRows().slice(0, _page));
    watchForMore();
    /* The bar lives OUTSIDE #pfList, so narrowing the grid left its count
     * speaking for the old filter: "Select all 3,415 shown" over seven kings,
     * and "Clear these" when none of the seven were held. The count being
     * trustworthy is the entire reason that bar says a number. */
    renderBulkBar();
  }

  /* Growing the page as you reach the bottom, so nothing needs pressing. The
   * button stays: an observer that never fires (no layout, a hidden tab) must
   * not be the only way to see the rest of a library. */
  let _moreObserver = null;
  function watchForMore() {
    if (_moreObserver) { _moreObserver.disconnect(); _moreObserver = null; }
    const sentinel = document.getElementById('pfMore');
    if (!sentinel || typeof IntersectionObserver !== 'function') return;
    _moreObserver = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) showMore();
    }, { rootMargin: '600px' });
    _moreObserver.observe(sentinel);
  }

  function showMore() {
    if (_page >= visibleRows().length) return;
    _page += PAGE;
    /* The cache has to hold what is PAINTED, or every repaint re-reads the
     * whole page off disk and the batch evicts the front of itself as it lands.
     * At 600 painted cards against a 300-entry cache, starring one file re-read
     * 300 thumbnails — the cost paging exists to remove. */
    growThumbCache(_page);
    renderList();
  }

  /** Back to one page. Every filter, search or view change starts at the top. */
  function resetPage() { _page = PAGE; growThumbCache(PAGE); }

  function renderPrintFiles() {
    const el = document.getElementById('printfiles-tab');
    if (!el) return;
    wirePfDrop();
    const hasHub = !!(api() && api().printLibPick);
    const isGallery = _view === 'gallery';
    /* THE LIST IS BUILT FIRST, AND SITS SECOND.
     *
     * listInnerHtml() runs normalizeFilters(), which drops a filter that no
     * longer matches anything. Inlined in the template below, the bar was built
     * in source order — against the filter that was about to be dropped. Clear
     * the group of every selected file and it read "Select all 0 shown" over a
     * grid of the whole library, and the first press of that button did nothing,
     * because pickAllShown re-read the same stale filter. The second press
     * worked.
     *
     * The bar still renders above the grid; only the ORDER OF EVALUATION moved. */
    const listHtml = listInnerHtml();
    const bulkBar = bulkBarHtml();
    el.innerHTML = `
      <div class="pf-wrap">
        <div class="pf-head">
          <div>
            <h2 class="pf-title">${escapeHtml(t('tab.printfiles') || 'Print Files')}</h2>
            <p class="pf-sub">${escapeHtml(t('plib.subtitle') || 'Your STL, 3MF and G-code library — previews, tested settings, open in your slicer.')}</p>
          </div>
          <div class="pf-head-actions">
            <div class="pf-view-toggle" role="group" aria-label="${escapeHtml(t('plib.view') || 'View')}">
              <button class="pf-view-btn ${isGallery ? '' : 'on'}" data-act="pf-view-library" aria-pressed="${!isGallery}">${escapeHtml(t('plib.view_library') || 'Library')}</button>
              <button class="pf-view-btn ${isGallery ? 'on' : ''}" data-act="pf-view-gallery" aria-pressed="${isGallery}">${escapeHtml(t('plib.view_gallery') || 'Gallery')}</button>
            </div>
            ${isGallery ? '' : `<input type="search" id="pfSearch" class="pf-search" placeholder="${escapeHtml(t('common.search') || 'Search')}" value="${escapeHtml(_query)}" aria-label="${escapeHtml(t('common.search') || 'Search')}">`}
            ${isGallery ? '' : `<button class="btn ghost${_selectMode ? ' state-on' : ''}" data-act="pf-select-toggle" aria-pressed="${_selectMode}" title="${escapeHtml(t('plib.select_hint') || 'Work on several files at once — group, categorise, tag or delete them together')}">${_bi('check', '✓')}${escapeHtml(t('plib.select') || 'Select')}</button>`}
            ${typeof openCalibration === 'function' ? `<button class="btn ghost" data-act="pf-calibrate">${_bi('target', '🎯')}${escapeHtml(t('plib.calibrate') || 'Calibrate')}</button>` : ''}
            ${_cloudOn() ? `<button class="btn ghost" data-act="pf-sync" title="${escapeHtml(t('plib.sync_hint') || 'Push this library to Khayt Cloud now, instead of waiting for the next automatic sync.')}">${_bi('cloud', '☁')}${escapeHtml(t('plib.sync') || 'Sync')}</button>` : ''}
            <button class="btn primary" data-act="pf-add" ${hasHub ? '' : 'disabled'} title="${escapeHtml(t('plib.add_multi_hint') || 'Add one or more files — select several at once')}">＋ ${escapeHtml(t('plib.add') || 'Add file')}</button>
          </div>
        </div>
        <div id="pfBulk">${bulkBar}</div>
        <div id="pfList">${listHtml}</div>
      </div>`;

    el.onclick = onClick;
    const search = document.getElementById('pfSearch');
    /* DEBOUNCED, because a keystroke re-renders the whole grid.
     *
     * Filtering is not the cost — measured at 0.2-1.0 ms over a thousand
     * records. Putting the result in the DOM is: 41 ms at a thousand cards,
     * 79 ms at two thousand, and it was paid on EVERY keystroke with nothing
     * between. The worst case is not typing but backspacing to empty, which
     * re-renders every card in the library each time a character goes.
     *
     * 120 ms is under the ~150 ms at which a pause starts to feel like lag, and
     * long enough that an ordinary typing speed renders once at the end rather
     * than once per letter. */
    if (search) {
      let _searchTimer = null;
      search.oninput = (e) => {
        _query = e.target.value;
        if (_searchTimer) clearTimeout(_searchTimer);
        _searchTimer = setTimeout(() => { _searchTimer = null; resetPage(); renderList(); }, 120);
      };
    }
    /* This builds the tab's markup itself rather than going through renderList,
     * so the two things renderList does AFTER writing the DOM have to happen
     * here too. They did not: on a fresh render the pictures were never fetched
     * and the observer that grows the page was never attached, so the first
     * screen a shop sees had thumbnails that filled in only after some other
     * action and a list that stopped at 120 until the button was pressed.
     *
     * Found by looking at a screenshot — the E2E pressed the button, which
     * works, and never scrolled. */
    warmThumbs(visibleRows().slice(0, _page));
    watchForMore();
  }

  function onClick(e) {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const id = btn.dataset.id;
    switch (btn.dataset.act) {
      case 'pf-add':   addPrintFile(); break;
      case 'pf-sync':  syncLibraryNow(); break;
      case 'pf-calibrate': if (typeof openCalibration === 'function') openCalibration(); break;
      case 'pf-slice': openInSlicer(id); break;
      case 'pf-view3d': view3d(id); break;
      case 'pf-edit':  editPrintFile(id); break;
      case 'pf-del':   deletePrintFile(id); break;
      case 'pf-fav':   toggleFav(id); break;
      case 'pf-version': {
        const V = _V(); const r = (printFiles || []).find((x) => x.id === id);
        if (V && r) { Object.assign(r, V.selectVersion(r, btn.dataset.ver)); r.updatedAt = Date.now(); saveAll(); renderPrintFiles(); }
        break;
      }
      case 'pf-plan':  { const r = (printFiles || []).find((x) => x.id === id); if (r && typeof openColorPlanner === 'function') openColorPlanner(r); break; }
      case 'pf-convert': convertPrintFile(id); break;
      case 'pf-add-parts': addPartsToPrint(id); break;
      case 'pf-part-open': openPart(id, btn.dataset.fn); break;
      case 'pf-part-primary': makePartPrimary(id, btn.dataset.fn); break;
      case 'pf-part-del': removePartFromPrint(id, btn.dataset.fn); break;
      case 'pf-conv-open': openConvertedInSlicer(id, btn.dataset.fn); break;
      case 'pf-conv-del':  deleteConverted(id, btn.dataset.fn); break;
      case 'pf-setups': openSetups(id); break;
      case 'pf-identify': identifyPrintFile(id); break;
      case 'pf-log-print': logPrint(id, true); break;
      case 'pf-log-fail':  logPrint(id, false); break;
      case 'pf-pick': togglePick(id); break;
      case 'pf-pick-all': pickAllShown(); break;
      case 'pf-select-toggle': setSelectMode(!_selectMode); break;
      case 'pf-select-off': setSelectMode(false); break;
      case 'pf-bulk-group': bulkFile('group'); break;
      case 'pf-bulk-cat': bulkFile('category'); break;
      case 'pf-bulk-tag': bulkTag(); break;
      case 'pf-bulk-del': bulkDelete(); break;
      case 'pf-view-library': if (_view !== 'library') { _view = 'library'; resetPage(); renderPrintFiles(); } break;
      // Leaving the library drops the selection rather than carrying it
      // invisibly into a screen with no way to see or change it.
      case 'pf-view-gallery': if (_view !== 'gallery') { _view = 'gallery'; resetPage(); setSelectMode(false); } break;
      case 'pf-more': showMore(); break;
      /* Every narrowing starts at the top again: a shop that has scrolled deep
       * into one group and then picks another is asking a new question. */
      case 'pf-tag': { const tg = btn.dataset.tag || ''; _tagFilter = (_tagFilter.toLowerCase() === tg.toLowerCase()) ? '' : tg; resetPage(); renderList(); break; }
      case 'pf-tag-clear': _tagFilter = ''; resetPage(); renderList(); break;
      /* `data-unfiled` rather than a value, and case-folded like every other
       * comparison here: the bar's chip carries the spelling used MOST while a
       * card's carries that record's own, so a strict === meant pressing the lit
       * chip on a "saudi kings" card did not clear a filter set from the
       * "Saudi Kings" bar — it replaced it, and the filter looked stuck. */
      case 'pf-folder': {
        const fv = btn.dataset.unfiled ? UNFILED : (btn.dataset.folder || '');
        _folderFilter = sameFilter(_folderFilter, fv) ? '' : fv;
        resetPage(); renderList(); break;
      }
      case 'pf-cat': {
        const cv = btn.dataset.unfiled ? UNFILED : (btn.dataset.cat || '');
        _catFilter = sameFilter(_catFilter, cv) ? '' : cv;
        resetPage(); renderList(); break;
      }
    }
  }

  // Short, locale-aware date for the print-history line.
  function fmtPfDate(iso) {
    try { return new Date(iso).toLocaleDateString(localeTag(), { month: 'short', day: 'numeric' }); }
    catch (e) { return String(iso || '').slice(0, 10); }
  }

  /* ---- Do we already have this? (R6) ------------------------------------
   * A repeat customer sends the same bracket they sent in March. Without this
   * it becomes a second library entry with none of the first one's history —
   * and the shop re-slices a part it already has a known-good setup and a
   * measured cost for.
   *
   * Identical bytes is a certainty. Identical geometry is a hint, and is worded
   * as one: presenting the second as the first would eventually merge two
   * different customers' parts.
   * ---------------------------------------------------------------------- */
  const MI = () => (typeof globalThis !== 'undefined' && globalThis.KhaytModelIdentity) || null;

  function matchesFor(rec) {
    const mi = MI();
    if (!mi || !rec) return { exact: [], similar: [] };
    return mi.findMatches(printFiles || [], rec);
  }

  function warnIfAlreadyHave(rec) {
    const { exact } = matchesFor(rec);
    if (!exact.length) return;
    const twin = exact[0];
    openFormModal({
      title: t('dup.title') || 'You already have this file',
      saveLabel: t('dup.open') || 'Open the one I have',
      sizeLg: false,
      bodyHtml: `
        <p style="margin:0 0 10px;">${escapeHtml(
          (t('dup.body') || 'This is byte-for-byte the same file as “{name}”, added {when}.')
            .replace('{name}', twin.name || twin.originalName || '')
            .replace('{when}', twin.createdAt ? fmtPfDate(new Date(twin.createdAt).toISOString()) : ''))}</p>
        <p style="margin:0 0 12px;font-size:13px;color:var(--text-muted);">${escapeHtml(
          t('dup.why') || 'The one you already have carries its print history and the settings that worked for it. The new copy carries none of that.')}</p>
        <label style="display:flex;align-items:flex-start;gap:8px;cursor:pointer;">
          <input type="checkbox" id="dupRemove" checked style="width:auto;margin:3px 0 0;">
          <span style="font-weight:400;">${escapeHtml(t('dup.remove') || 'Remove the copy I just added')}</span>
        </label>`,
      onSave(modal) {
        // Removing is the default but never automatic — a shop may genuinely
        // want two entries for the same bytes (two customers, two jobs).
        if (modal.querySelector('#dupRemove')?.checked) {
          const at = (printFiles || []).findIndex((x) => x.id === rec.id);
          if (at !== -1) printFiles.splice(at, 1);
          _selected.delete(rec.id);   // every removal, not just the ones you asked for
          saveAll();
        }
        renderPrintFiles();
        return true;
      },
    });
  }

  /** A line on the card when this file has a twin, or something close to one. */
  function duplicateLine(rec) {
    const { exact, similar } = matchesFor(rec);
    if (exact.length) {
      return `<div class="pf-dup" style="font-size:11px;color:var(--warn,#b45309);">${escapeHtml(
        (t('dup.badge') || 'Same file as “{name}”').replace('{name}', exact[0].name || exact[0].originalName || ''))}</div>`;
    }
    if (similar.length) {
      // Deliberately hedged. This is a hint, not a fact.
      return `<div class="pf-dup" style="font-size:11px;color:var(--text-muted);">${escapeHtml(
        (t('dup.similar') || 'Looks like “{name}”').replace('{name}', similar[0].name || similar[0].originalName || ''))}</div>`;
    }
    return '';
  }

  /* ---- Settings that worked (R4) ---------------------------------------
   * A file's print tally said it had worked, never with WHAT. A setup is one
   * combination of machine, material and the two numbers that decide most
   * outcomes, plus its own record. The rules — what counts as trustworthy, and
   * which one to reach for — live in lib/print-setups.js so they can be tested.
   * -------------------------------------------------------------------- */
  const PS = () => (typeof globalThis !== 'undefined' && globalThis.KhaytPrintSetups) || null;

  function setupsOf(rec) {
    return Array.isArray(rec && rec.setups) ? rec.setups : [];
  }

  function machineNameFor(setup) {
    const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x && x.id === (setup && setup.machineId));
    return (m && m.name) || (setup && setup.machineName) || '';
  }

  const STATUS_LABEL = {
    'known-good': () => t('setup.known_good') || 'Known good',
    'needs-test': () => t('setup.needs_test') || 'Needs testing',
    failed:       () => t('setup.failed') || 'Failed',
  };
  const STATUS_COLOR = {
    'known-good': 'var(--ok,#159d68)',
    'needs-test': 'var(--warn,#b45309)',
    failed:       'var(--danger,#e0492f)',
  };

  function statusBadge(setup) {
    const ps = PS(); if (!ps) return '';
    const st = ps.statusOf(setup);
    const label = (STATUS_LABEL[st] || (() => st))();
    return `<span style="font-size:11px;font-weight:600;color:${STATUS_COLOR[st] || 'inherit'};">${escapeHtml(label)}</span>`;
  }

  /** The one-line "use this" hint on a file's card. */
  function recommendedLine(rec) {
    const ps = PS(); if (!ps) return '';
    const setups = setupsOf(rec);
    if (!setups.length) return '';
    const best = ps.recommendSetup(setups);
    if (!best) {
      // Every recorded setup has failed. Saying nothing here would leave a shop
      // to rediscover that by wasting another spool.
      return `<div class="pf-setup" style="font-size:11px;color:var(--danger,#e0492f);">${escapeHtml(
        t('setup.none_good') || 'No setup has worked yet')}</div>`;
    }
    const desc = ps.describeSetup(best, machineNameFor(best)) || (best.name || '');
    const okN = best.ok || 0;
    const tail = okN
      ? ` · ${okN}× ${escapeHtml(t('plib.printed') || 'printed')}${best.failed ? ` · ${best.failed} ${escapeHtml(t('plib.failed') || 'failed')}` : ''}`
      : ` · ${escapeHtml(t('setup.untried') || 'not tried yet')}`;
    return `<div class="pf-setup" style="font-size:11px;color:var(--text-muted);">${statusBadge(best)} ${escapeHtml(desc)}${tail}</div>`;
  }

  function setupRowHtml(rec, setup) {
    const ps = PS();
    const desc = ps.describeSetup(setup, machineNameFor(setup)) || (setup.name || '—');
    return `<div style="display:flex;align-items:center;gap:8px;padding:8px;border:1px solid var(--border);border-radius:var(--radius);margin-bottom:6px;">
      <div style="flex:1;min-width:0;">
        <div style="font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(setup.name || desc || '—')}</div>
        <div style="font-size:11px;color:var(--text-muted);">${statusBadge(setup)} · ${escapeHtml(desc)} · ${setup.ok || 0}✓ ${setup.failed || 0}✗</div>
        ${setup.notes ? `<div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${escapeHtml(setup.notes)}</div>` : ''}
      </div>
      <button class="btn small ghost" data-sact="ok" data-sid="${escapeHtml(setup.id)}" title="${escapeHtml(t('setup.log_ok') || 'Log a good print')}">✓</button>
      <button class="btn small ghost" data-sact="fail" data-sid="${escapeHtml(setup.id)}" title="${escapeHtml(t('setup.log_fail') || 'Log a failure')}">✗</button>
      <button class="btn small ghost" data-sact="edit" data-sid="${escapeHtml(setup.id)}" title="${escapeHtml(t('common.edit') || 'Edit')}">✎</button>
      <button class="btn small ghost danger" data-sact="del" data-sid="${escapeHtml(setup.id)}" title="${escapeHtml(t('common.delete') || 'Delete')}">🗑</button>
    </div>`;
  }

  function openSetups(id) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    const ps = PS(); if (!ps) return;
    if (!Array.isArray(rec.setups)) rec.setups = [];

    const body = () => {
      const list = rec.setups.length
        ? rec.setups.map((su) => setupRowHtml(rec, su)).join('')
        : `<p style="color:var(--text-muted);font-size:13px;margin:12px 0;">${escapeHtml(
            t('setup.empty') || 'No setups recorded yet. Add the settings you printed this with, then log how it went.')}</p>`;
      return `<div id="pfSetupList">${list}</div>
        <button class="btn small" data-sact="add" style="margin-top:6px;">${escapeHtml(t('setup.add') || '＋ Add a setup')}</button>`;
    };

    openFormModal({
      title: t('setup.title') || 'Settings that worked',
      sizeLg: true,
      noSave: true,
      bodyHtml: body(),
      onMount(modal) {
        const redraw = () => {
          const host = modal.querySelector('#pfSetupList');
          if (host) host.innerHTML = rec.setups.length
            ? rec.setups.map((su) => setupRowHtml(rec, su)).join('')
            : `<p style="color:var(--text-muted);font-size:13px;margin:12px 0;">${escapeHtml(
                t('setup.empty') || 'No setups recorded yet. Add the settings you printed this with, then log how it went.')}</p>`;
          saveAll();
          renderPrintFiles();
        };
        modal.addEventListener('click', (e) => {
          const b = e.target.closest('[data-sact]'); if (!b) return;
          const sid = b.dataset.sid;
          const at = rec.setups.findIndex((x) => x.id === sid);
          if (b.dataset.sact === 'add') { editSetup(rec, null, redraw); return; }
          if (at === -1) return;
          if (b.dataset.sact === 'ok')   { rec.setups[at] = ps.recordOutcome(rec.setups[at], true,  new Date().toISOString()); redraw(); return; }
          if (b.dataset.sact === 'fail') { rec.setups[at] = ps.recordOutcome(rec.setups[at], false, new Date().toISOString()); redraw(); return; }
          if (b.dataset.sact === 'edit') { editSetup(rec, rec.setups[at], redraw); return; }
          if (b.dataset.sact === 'del')  { rec.setups.splice(at, 1); redraw(); }
        });
      },
    });
  }

  function editSetup(rec, existing, done) {
    const ps = PS(); if (!ps) return;
    const su = existing || {};
    const machineOpts = (typeof machines !== 'undefined' ? machines : []).map((m) =>
      `<option value="${escapeHtml(m.id)}"${su.machineId === m.id ? ' selected' : ''}>${escapeHtml(m.name || m.id)}</option>`).join('');
    const statusOpts = ['', 'known-good', 'needs-test', 'failed'].map((v) =>
      `<option value="${v}"${(su.status || '') === v ? ' selected' : ''}>${escapeHtml(
        v ? (STATUS_LABEL[v] || (() => v))() : (t('setup.status_auto') || 'From the record'))}</option>`).join('');

    openFormModal({
      title: existing ? (t('setup.edit') || 'Edit setup') : (t('setup.add_title') || 'Add a setup'),
      saveLabel: t('common.save') || 'Save',
      bodyHtml: `
        <label>${escapeHtml(t('setup.name') || 'Name')}</label>
        <input type="text" id="suName" value="${escapeHtml(su.name || '')}" placeholder="${escapeHtml(t('setup.name_ph') || 'e.g. Draft on the MK4')}">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px;">
          <div>
            <label>${escapeHtml(t('setup.machine') || 'Printer')}</label>
            <select id="suMachine"><option value="">— ${escapeHtml(t('common.none') || 'None')} —</option>${machineOpts}</select>
          </div>
          <div>
            <label>${escapeHtml(t('plib.material') || 'Material')}</label>
            <input type="text" id="suMaterial" value="${escapeHtml(su.material || '')}">
          </div>
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin-top:10px;">
          <div>
            <label>${escapeHtml(t('setup.colour') || 'Colour')}</label>
            <input type="text" id="suColour" value="${escapeHtml(su.colour || '')}">
          </div>
          <div>
            <label>${escapeHtml(t('setup.layer') || 'Layer height (mm)')}</label>
            <input type="number" id="suLayer" step="0.01" min="0" value="${su.layerHeightMm || ''}">
          </div>
          <div>
            <label>${escapeHtml(t('setup.nozzle') || 'Nozzle (mm)')}</label>
            <input type="number" id="suNozzle" step="0.1" min="0" value="${su.nozzleMm || ''}">
          </div>
        </div>
        <label style="margin-top:10px;">${escapeHtml(t('setup.status') || 'Verdict')}</label>
        <select id="suStatus">${statusOpts}</select>
        <div style="font-size:11px;color:var(--text-muted);margin-top:4px;">${escapeHtml(
          t('setup.status_hint') || 'Leave on "From the record" and Khayt works it out from how the prints went.')}</div>
        <label style="margin-top:10px;">${escapeHtml(t('setup.notes') || 'Notes')}</label>
        <textarea id="suNotes" rows="2">${escapeHtml(su.notes || '')}</textarea>`,
      onSave(modal) {
        const numOf = (sel) => {
          const v = parseFloat(modal.querySelector(sel)?.value);
          return Number.isFinite(v) && v > 0 ? v : 0;
        };
        const next = Object.assign({}, su, {
          id: su.id || (typeof uid === 'function' ? uid('SETUP') : `SETUP-${Date.now().toString(36)}`),
          createdAt: su.createdAt || new Date().toISOString(),
          name: modal.querySelector('#suName')?.value.trim() || '',
          machineId: modal.querySelector('#suMachine')?.value || '',
          material: modal.querySelector('#suMaterial')?.value.trim() || '',
          colour: modal.querySelector('#suColour')?.value.trim() || '',
          layerHeightMm: numOf('#suLayer'),
          nozzleMm: numOf('#suNozzle'),
          status: modal.querySelector('#suStatus')?.value || null,
          notes: modal.querySelector('#suNotes')?.value.trim() || '',
          ok: su.ok || 0,
          failed: su.failed || 0,
        });
        if (!Array.isArray(rec.setups)) rec.setups = [];
        const at = rec.setups.findIndex((x) => x.id === next.id);
        if (at === -1) rec.setups.push(next); else rec.setups[at] = next;
        saveAll();
        if (typeof done === 'function') done();
        // Reopen the list the shop came from, rather than dropping them back to
        // the grid having lost their place. Deferred because we are INSIDE
        // onSave: openFormModal empties the shared #modalMount as it closes, so
        // a modal opened synchronously here is destroyed a moment later. This
        // codebase has shipped that bug before.
        setTimeout(() => openSetups(rec.id), 0);
        return true;
      },
    });
  }

  // Print journal: a self-contained tally of successful/failed prints per file
  // (no queue linkage needed). Increments the counter, stamps the date, saves.
  function logPrint(id, ok) {
    const rec = (printFiles || []).find((x) => x.id === id);
    if (!rec) return;
    if (ok) {
      rec.timesPrinted = (rec.timesPrinted || 0) + 1;
      rec.lastPrinted = new Date().toISOString();
      toast(t('plib.logged_print') || 'Logged a print ✓', 'success');
    } else {
      rec.timesFailed = (rec.timesFailed || 0) + 1;
      toast(t('plib.logged_fail') || 'Logged a failed print', 'info');
    }
    saveAll();
    renderPrintFiles();
  }

  /**
   * ingestPicked, but it cannot take the rest of the drop down with it.
   *
   * It is the one un-guarded call in addDroppedFiles' loop, and it does real
   * work — saveAll(), a re-render, and warnIfAlreadyHave() which OPENS A MODAL.
   * A throw from any of those aborted the whole drop: the files already copied
   * kept no records, the archive's temp folder was never cleaned up, and the
   * rejection was unhandled because the drop listener has no .catch.
   *
   * Every other per-item call in that loop is guarded. This one now is too:
   * one file failing costs that file.
   */
  function ingestSafely(id, picked, opts) {
    try { return ingestPicked(id, picked, opts); }
    catch (e) { console.error('ingest failed for', picked && picked.originalName, e); return null; }
  }

  // Build + persist a record from a copied-in file (shape from printLibPick / printLibCopyPath).
  //
  // `opts.name` overrides the name taken from the file — an archive imported as
  // ONE print is called after the archive, not after whichever of its twelve
  // files happened to be extracted first.
  // `opts.parts` are the rest of the files this print is made of, already copied
  // into the same record's vault.
  function ingestPicked(id, picked, opts) {
    const o = opts || {};
    const ext = (picked.ext || '').toLowerCase();
    const rec = {
      id,
      name: o.name || (picked.originalName || 'Untitled').replace(/\.[^.]+$/, ''),
      originalName: picked.originalName,
      createdAt: Date.now(), updatedAt: Date.now(),
      sourceFile: { filename: picked.filename, originalName: picked.originalName, size: picked.size, ext, kind: /^(stl|3mf|obj)$/.test(ext) ? 'model' : 'gcode' },
      parsed: {}, colors: [], swapCount: 0,
      thumb: null, thumbSource: null, userPhoto: null,
      slicerProfileId: null, testedNotes: '', tags: [], folder: '', material: '', favorite: false,
      // Identity, so a file the shop already has is recognised rather than
      // becoming a second entry with none of the first one's history.
      contentHash: picked.contentHash || null, geometryKey: null,
    };
    if (o.parts && o.parts.length && _P()) Object.assign(rec, _P().addParts(rec, o.parts));
    if (!Array.isArray(printFiles)) printFiles = [];
    printFiles.unshift(rec);
    saveAll();
    renderPrintFiles();
    // The hash is known now; the geometry key only after parsing.
    warnIfAlreadyHave(rec);
    enrichPrintFile(rec, picked.fullPath);
    return rec;
  }

  /**
   * Work out what an existing entry is, after the fact.
   *
   * Identity was only ever computed while CREATING a record, so an entry that
   * arrived without one could never gain one: dropping the model into the
   * calculator does not touch the library, and editing an entry does not look at
   * its file. Entries reconstructed from print history, and every 3MF imported
   * before the line above existed, were therefore permanently unrecognisable —
   * and an unrecognisable entry is one the calculator can never link a part to,
   * which is what keeps per-file calibration out of reach.
   *
   * Two cases, one action:
   *   the entry already has a file  -> re-read it; nothing to ask the shop
   *   the entry has no file at all  -> ask for one, copy it into the entry's own
   *                                    vault, then read it
   */
  async function identifyPrintFile(id) {
    const hub = api(); if (!hub) return;
    const rec = (printFiles || []).find((r) => r && r.id === id);
    if (!rec) return;

    let fullPath = await resolveModelPath(rec);
    if (!fullPath) {
      if (!hub.printLibPick) return;
      let picked;
      try { picked = await hub.printLibPick(id); } catch (err) { toast(String(err.message || err), 'error'); return; }
      if (!picked) return;                       // cancelled
      const ext = (picked.ext || '').toLowerCase();
      rec.sourceFile = {
        filename: picked.filename, originalName: picked.originalName,
        size: picked.size, ext, kind: /^(stl|3mf|obj)$/.test(ext) ? 'model' : 'gcode',
      };
      if (!rec.originalName) rec.originalName = picked.originalName;
      rec.contentHash = picked.contentHash || null;
      fullPath = picked.fullPath;
    }
    // Cleared rather than kept: whatever is on the record describes some earlier
    // file, and a stale key is worse than none — it would match the wrong model.
    rec.geometryKey = null;
    rec.updatedAt = Date.now();
    saveAll();
    renderPrintFiles();
    await enrichPrintFile(rec, fullPath);
    toast(rec.geometryKey
      ? (t('plib.identified') || 'Khayt can recognise this model now')
      : (t('plib.identify_failed') || 'Read the file, but could not measure a shape from it'),
      rec.geometryKey ? 'success' : 'warning');
  }

  /** Remove the temp folder an archive was unpacked into. The ONE place that
   *  does it: every way an import ends has to come through here, or temp
   *  folders pile up for as long as the app is open. */
  async function cleanupZip(dir) {
    const hub = api();
    if (!hub || !hub.printLibUnpackCleanup || !dir) return;
    try { await hub.printLibUnpackCleanup(dir); } catch (_) { /* best effort */ }
  }

  /**
   * Persist a change to a print's parts.
   *
   * The record mirrors its ACTIVE VERSION, so `rec.files` changing is that
   * version changing — and without writing it back, the next press of a version
   * chip called `mirror()` and restored the frozen snapshot: parts added since
   * disappeared, and a part that had been removed AND deleted from disk came
   * back as a row that opens nothing.
   *
   * Every path that touches `rec.files` goes through here.
   */
  function partsChanged(rec) {
    const V = _V();
    if (V && V.syncActive) Object.assign(rec, V.syncActive(rec));
    rec.updatedAt = Date.now();
    saveAll();
  }

  /** The `sourceFile`/`files[]` descriptor for a file the main process copied in. */
  function fileDescriptor(copied) {
    const ext = String(copied.ext || '').toLowerCase();
    return {
      filename: copied.filename,
      originalName: copied.originalName,
      size: copied.size,
      ext,
      kind: /^(stl|3mf|obj)$/.test(ext) ? 'model' : 'gcode',
    };
  }

  /**
   * Add more files to a print that already exists.
   *
   * The library could only ever make a NEW entry per file, so the way to record
   * a Spiderman was twelve entries with nothing tying them together. This is
   * the other direction: the files land in THIS record's own vault folder, and
   * the record grows a part.
   *
   * A zip is offered here too — a pack downloaded for a print you already have.
   */
  async function addPartsToPrint(id) {
    const hub = api(); if (!hub || !hub.printLibCopyPath) return;
    const rec = (printFiles || []).find((r) => r && r.id === id); if (!rec) return;
    const P = _P(); if (!P) return;

    let paths = [];
    if (hub.printLibPickMulti) {
      let res;
      try { res = await hub.printLibPickMulti(); } catch (err) { toast(String(err.message || err), 'error'); return; }
      if (!res || !res.ok || !Array.isArray(res.paths) || !res.paths.length) return;
      paths = res.paths;
    } else if (hub.printLibPick) {
      let picked;
      try { picked = await hub.printLibPick(id); } catch (err) { toast(String(err.message || err), 'error'); return; }
      if (!picked) return;
      Object.assign(rec, P.addParts(rec, fileDescriptor(picked)));
      partsChanged(rec);
      renderPrintFiles();
      toast(t('plib.parts_added', { n: '1' }) || '1 file added to this print', 'success');
      return;
    } else return;

    // An archive chosen here is unpacked INTO this print — every model in it
    // becomes a part of it. No question to ask: you chose the print it belongs
    // to before you chose the archive.
    //
    // Copied and cleaned up one archive at a time rather than collecting the
    // temp folders to delete afterwards, so there is no list to forget to drain.
    const added = [];
    let bad = 0;
    const copyInto = async (pth) => {
      let r; try { r = await hub.printLibCopyPath(id, pth); } catch (_) { r = null; }
      if (!r || !r.ok) { bad++; return; }
      added.push(fileDescriptor(r));
    };
    for (const pth of paths) {
      if (/\.zip$/i.test(String(pth)) && hub.printLibUnpackZip) {
        let z; try { z = await hub.printLibUnpackZip(pth); } catch (_) { z = null; }
        if (!z || !z.ok) { toast((z && z.error) || (t('plib.zip_empty') || 'No print files in that archive.'), 'error'); continue; }
        for (const f of z.files) await copyInto(f.path);
        await cleanupZip(z.dir);
        continue;
      }
      await copyInto(pth);
    }

    if (!added.length) { toast(t('plib.drop_bad') || 'Drop STL, 3MF, OBJ or G-code files.', 'error'); return; }
    Object.assign(rec, P.addParts(rec, added));
    partsChanged(rec);
    renderPrintFiles();
    toast(t('plib.parts_added', { n: String(added.length) }) || `${added.length} files added to this print`, 'success');
    // Said separately: a count that quietly swallowed the rejects would read as
    // "all of them came in".
    if (bad) toast(`${bad} ${t('plib.parts_rejected') || 'were not print files and were skipped'}`, 'info');
  }

  /** Open ONE part of a multi-part print, rather than the whole thing. */
  async function openPart(id, filename) {
    const hub = api(); if (!hub || !hub.printLibList) return;
    let files = [];
    try { files = await hub.printLibList(id); } catch (_) { files = []; }
    const f = (files || []).find((x) => x.filename === filename);
    if (!f) { toast(t('plib.file_missing') || 'File is missing.', 'error'); return; }
    openInSlicer(id, f.fullPath);
  }

  /**
   * Make a different part the file the card speaks for.
   *
   * The record's numbers — print time, weight, colours, the picture — were read
   * off the OLD primary, and they describe that file and no other. So the new
   * primary is re-read here rather than left with the previous part's figures
   * under a new name, which would be a card quietly lying about what it holds.
   */
  async function makePartPrimary(id, filename) {
    const rec = (printFiles || []).find((r) => r && r.id === id); if (!rec) return;
    const P = _P(); if (!P) return;
    Object.assign(rec, P.makePrimary(rec, filename));
    /* WHAT THE OLD PRIMARY SAID IS DROPPED, not left to be half-overwritten.
     *
     * This said the record was "re-read", and enrichPrintFile does not do that:
     * its STL branch merges only triangleCount/volumeMm3/bbox onto whatever
     * `parsed` already held, and never touches `colors`. So promoting a plain
     * STL inside a print whose primary was a five-colour 3MF left the card
     * showing five colour dots, "12 swaps", "6h 0m" and "120 g" — the previous
     * file's figures under the new file's name, which is exactly the card
     * quietly lying that this exists to prevent.
     *
     * Cleared first and re-read after: a print whose main file is an STL HAS no
     * slicer time, so showing nothing is right and showing the 3MF's is not. */
    rec.parsed = {};
    rec.colors = [];
    rec.swapCount = 0;
    partsChanged(rec);
    renderPrintFiles();
    const full = await resolveModelPath(rec);
    if (full) await enrichPrintFile(rec, full);
    renderPrintFiles();
  }

  /** Take a file out of a print — and off the disk, since nothing else holds it. */
  function removePartFromPrint(id, filename) {
    const rec = (printFiles || []).find((r) => r && r.id === id); if (!rec) return;
    const P = _P(); if (!P) return;
    const part = P.partsOf(rec).find((f) => String(f.filename) === String(filename));
    openFormModal({
      title: t('plib.remove_part') || 'Remove this file from the print',
      sizeLg: false, saveLabel: t('common.delete') || 'Delete',
      bodyHtml: `<p>${escapeHtml((t('plib.remove_part_confirm') || 'Remove "{name}" from this print and delete it? The rest of the print is untouched.')
        .replace('{name}', (part && (part.originalName || part.filename)) || filename))}</p>`,
      async onSave() {
        const hub = api();
        let gone = true;
        if (hub && hub.printLibList && hub.printLibDelete) {
          try {
            const files = await hub.printLibList(id);
            const f = (files || []).find((x) => x.filename === filename);
            if (f && (await hub.printLibDelete(f.fullPath)) === false) gone = false;
          } catch (e) { console.error('printLibDelete:', e); gone = false; }
        }
        // The record forgets the part either way: leaving it listed when the file
        // is gone gives a card a row that opens nothing. What differs is what the
        // shop is told.
        const wasPrimary = String(P.primaryOf(rec) && P.primaryOf(rec).filename) === String(filename);
        Object.assign(rec, P.removePart(rec, filename));
        if (wasPrimary) { rec.parsed = {}; rec.colors = []; rec.swapCount = 0; }
        partsChanged(rec);
        renderPrintFiles();
        if (!gone) toast('⚠ ' + (t('plib.delete_partial') || 'Removed from the library, but some files could not be deleted from disk'), 'error', 7000);
        if (wasPrimary) {
          const full = await resolveModelPath(rec);
          if (full) { await enrichPrintFile(rec, full); renderPrintFiles(); }
        }
      },
    });
  }

  async function addPrintFile() {
    const hub = api(); if (!hub) return;
    // Prefer the multi-select picker (bulk import); each file is copied into its own record's vault via
    // the same path-ingest as drag-and-drop. Fall back to the single picker on an older main process.
    if (hub.printLibPickMulti) {
      let res;
      try { res = await hub.printLibPickMulti(); } catch (err) { toast(String(err.message || err), 'error'); return; }
      if (!res || !res.ok || !Array.isArray(res.paths) || !res.paths.length) return;
      await addDroppedFiles(res.paths);
      return;
    }
    if (!hub.printLibPick) return;
    const id = uid('PF');
    let picked;
    try { picked = await hub.printLibPick(id); } catch (err) { toast(String(err.message || err), 'error'); return; }
    if (!picked) return;
    ingestPicked(id, picked);
    toast(t('plib.added') || 'File added', 'success');
  }

  /**
   * Ask whether an archive is one print or many.
   *
   * Resolves to 'one', 'many', or null if the shop closed the question without
   * answering — which is a real answer here and means "import nothing", not
   * "pick one for me".
   *
   * @param {string} zipPath   full path of the archive, for its name
   * @param {number} n         print files found inside it
   * @param {number} howMany   archives in this drop, so the question can say
   *                           that the answer covers all of them
   */
  function askZipShape(zipPath, n, howMany) {
    const name = String(zipPath).split(/[\\/]/).pop();
    return new Promise((resolve) => {
      let choice = null;
      openFormModal({
        title: t('plib.zip_shape_title') || 'One print, or many?',
        sizeLg: false, noSave: true,
        bodyHtml: `
          <p class="pf-pick-hint">${escapeHtml((t('plib.zip_shape_q') || '"{name}" holds {n} print files.').replace('{name}', name).replace('{n}', String(n)))}</p>
          <div class="pf-zip-choices">
            <button type="button" class="btn pf-zip-pick" data-shape="one">
              <span class="pf-zip-pick-t">${escapeHtml((t('plib.zip_one') || 'One print, {n} parts').replace('{n}', String(n)))}</span>
              <span class="pf-zip-pick-d">${escapeHtml(t('plib.zip_one_d') || 'A model that comes in pieces — a head, two arms, a torso. One entry you open all of at once.')}</span>
            </button>
            <button type="button" class="btn pf-zip-pick" data-shape="many">
              <span class="pf-zip-pick-t">${escapeHtml((t('plib.zip_many') || '{n} separate prints').replace('{n}', String(n)))}</span>
              <span class="pf-zip-pick-d">${escapeHtml(t('plib.zip_many_d') || 'A pack of unrelated models. Each gets its own entry, its own tags and its own history.')}</span>
            </button>
          </div>
          ${howMany > 1 ? `<p class="pf-pick-hint">${escapeHtml((t('plib.zip_shape_all') || 'This answer is used for all {n} archives you dropped.').replace('{n}', String(howMany)))}</p>` : ''}`,
        onMount(modal) {
          modal.querySelectorAll('[data-shape]').forEach((b) => b.addEventListener('click', () => {
            choice = b.dataset.shape;
            modal.querySelector('[data-act="cancel"]').click();
          }));
        },
        onClose() { resolve(choice); },
      });
    });
  }

  // Import files dropped onto the library (each copied into its own record's vault). Skips anything the
  // main-process handler rejects (non-print extensions).
  async function addDroppedFiles(paths) {
    const hub = api(); if (!hub || !hub.printLibCopyPath) return;
    let added = 0, bad = 0, skipped = 0, truncated = false;
    // Asked at the first multi-file archive and then held for the whole drop.
    let zipShape = null;                                   // null | 'one' | 'many'
    const zipCount = paths.filter((x) => /\.zip$/i.test(String(x))).length;
    for (const p of paths) {
      // A .zip is a pack of models, not a model. It is unpacked to a temp
      // folder and each file then goes through the ORDINARY intake below, so a
      // six-part pack becomes six records exactly as if they had been unzipped
      // and dropped — and there is still only one path that ingests a file.
      if (/\.zip$/i.test(String(p)) && hub.printLibUnpackZip) {
        let z;
        try { z = await hub.printLibUnpackZip(p); } catch (_) { z = null; }
        if (!z || !z.ok) {
          bad++;
          if (z && z.empty) toast(z.error || (t('plib.zip_empty') || 'No print files in that archive.'), 'error');
          continue;
        }
        // AN ARCHIVE IS AMBIGUOUS AND ONLY THE SHOP KNOWS WHICH IT IS.
        //
        // A pack of twelve files is either twelve prints (a bundle of keychains)
        // or one print in twelve pieces (Spiderman). Both are ordinary; nothing
        // in the zip says which, and guessing gets it wrong half the time — in
        // one direction leaving eleven strays to delete, in the other a print
        // you cannot open in one go. So it is asked, ONCE for the whole drop:
        // somebody dropping four packs at once is dropping four of the same kind
        // of thing, and four dialogs to say so twice would be its own bug.
        if (z.files.length > 1 && zipShape == null) {
          zipShape = await askZipShape(String(p), z.files.length, zipCount);
          if (!zipShape) { skipped += z.files.length; await cleanupZip(z.dir); continue; }
        }
        if (z.files.length > 1 && zipShape === 'one') {
          const zid = uid('PF');
          const copied = [];
          for (const f of z.files) {
            let zr; try { zr = await hub.printLibCopyPath(zid, f.path); } catch (_) { zr = null; }
            if (!zr || !zr.ok) { skipped++; continue; }
            copied.push(zr);
          }
          if (copied.length) {
            // Named after the archive: "spider-man-pack", not "left-arm".
            const packName = String(p).split(/[\\/]/).pop().replace(/\.zip$/i, '');
            if (ingestSafely(zid, copied[0], { name: packName, parts: copied.slice(1).map(fileDescriptor) })) added++;
            else bad++;
          }
        } else {
          for (const f of z.files) {
            const zid = uid('PF');
            let zr;
            try { zr = await hub.printLibCopyPath(zid, f.path); } catch (_) { zr = null; }
            if (!zr || !zr.ok) { skipped++; continue; }
            if (ingestSafely(zid, zr)) added++; else bad++;
          }
        }
        skipped += (z.skipped || []).length + (z.failed || []).length;
        truncated = truncated || !!z.truncated;
        await cleanupZip(z.dir);
        continue;
      }
      const id = uid('PF');
      let r;
      try { r = await hub.printLibCopyPath(id, p); } catch (_) { bad++; continue; }
      if (!r || !r.ok) { bad++; continue; }
      if (ingestSafely(id, r)) added++; else bad++;
    }
    if (added) toast(added === 1 ? (t('plib.added') || 'File added') : `${added} ${t('plib.files_added') || 'files added'}`, 'success');
    else if (bad) toast(t('plib.drop_bad') || 'Drop STL, 3MF, OBJ or G-code files.', 'error');
    // Said out loud rather than folded into the success count: an archive that
    // was partly ignored must not read as "all of it came in".
    if (truncated) toast(t('plib.zip_truncated') || 'The archive was too large — not every file was imported.', 'error');
    else if (added && skipped) toast(`${skipped} ${t('plib.zip_skipped') || 'other files in the archive were skipped'}`, 'info');
  }

  // Bind drag-and-drop once to the (persistent) tab element; renderPrintFiles only swaps its innerHTML.
  let _dropWired = false;
  function wirePfDrop() {
    if (_dropWired) return;
    const host = document.getElementById('printfiles-tab');
    if (!host) return;
    _dropWired = true;
    const hi = (on) => { const w = host.querySelector('.pf-wrap'); if (w) { w.style.outline = on ? '2px dashed var(--accent,#199e8f)' : ''; w.style.outlineOffset = on ? '6px' : ''; } };
    const over = (e) => { if (!(api() && api().printLibCopyPath)) return; e.preventDefault(); e.stopPropagation(); hi(true); };
    host.addEventListener('dragover', over);
    host.addEventListener('dragenter', over);
    host.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); hi(false); });
    host.addEventListener('drop', (e) => {
      e.preventDefault(); e.stopPropagation(); hi(false);
      const files = (e.dataTransfer && e.dataTransfer.files) ? Array.prototype.slice.call(e.dataTransfer.files) : [];
      const paths = files.map((f) => f.path).filter(Boolean);
      if (paths.length) addDroppedFiles(paths);
    });
  }

  // ---- 3MF converter integration -------------------------------------------
  // A converted 3MF is written straight into the record's own vault folder (main
  // process), so it lives WITH the print file instead of a random export folder.

  /** Attach a just-converted file (already in this record's vault) to the record. */
  function attachConverted(recordId, meta) {
    const rec = (printFiles || []).find((r) => r.id === recordId); if (!rec) return;
    if (!Array.isArray(rec.converted)) rec.converted = [];
    rec.converted.unshift({
      filename: meta.filename, ext: (meta.ext || '3mf').toLowerCase(), size: meta.size || 0,
      targetId: meta.targetId || '', targetName: meta.targetName || '', createdAt: Date.now(),
    });
    rec.updatedAt = Date.now();
    saveAll();
    renderPrintFiles();
  }

  /** Create a NEW print-file record from a standalone conversion (bytes already in vaultId's folder). */
  async function importConvertedAsNew(meta) {
    const id = meta.vaultId;
    const ext = (meta.ext || '3mf').toLowerCase();
    const baseName = String(meta.sourceName || 'model').replace(/\.[^.]+$/, '');
    // displayName wins verbatim (e.g. a cloud-library design keeps its own title); otherwise fall back
    // to the converted-file naming ("Model → Target" / "Model (Converted)").
    const name = meta.displayName
      ? String(meta.displayName)
      : (meta.targetName ? `${baseName} → ${meta.targetName}` : `${baseName} (${t('conv.convert_short') || 'Converted'})`);
    const rec = {
      id, name, originalName: meta.filename,
      createdAt: Date.now(), updatedAt: Date.now(),
      sourceFile: { filename: meta.filename, originalName: meta.filename, size: meta.size || 0, ext, kind: 'model' },
      parsed: {}, colors: [], swapCount: 0,
      thumb: null, thumbSource: null, userPhoto: null,
      slicerProfileId: null, testedNotes: '', tags: [], folder: '', material: '', favorite: false, converted: [],
    };
    if (!Array.isArray(printFiles)) printFiles = [];
    printFiles.unshift(rec);
    saveAll();
    renderPrintFiles();
    try {
      const hub = api();
      const files = hub && hub.printLibList ? await hub.printLibList(id) : [];
      const f = (files || []).find((x) => x.filename === meta.filename);
      if (f) enrichPrintFile(rec, f.fullPath);
    } catch (_) { /* thumbnail is best-effort */ }
    if (!meta.noSwitch && typeof switchTab === 'function') switchTab('printfiles-tab');
    return rec;
  }

  async function openConvertedInSlicer(id, filename) {
    const hub = api(); if (!hub || !hub.printLibList) return;
    const files = await hub.printLibList(id);
    const f = (files || []).find((x) => x.filename === filename);
    if (!f) { toast(t('plib.file_missing') || 'File is missing.', 'error'); return; }
    await openInSlicer(id, f.fullPath);
  }

  function deleteConverted(id, filename) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    const hub = api();
    (async () => {
      try {
        const files = hub && hub.printLibList ? await hub.printLibList(id) : [];
        const f = (files || []).find((x) => x.filename === filename);
        if (f && hub.printLibDelete) await hub.printLibDelete(f.fullPath);
      } catch (_) {}
      rec.converted = (rec.converted || []).filter((c) => c.filename !== filename);
      rec.updatedAt = Date.now();
      saveAll();
      renderPrintFiles();
    })();
  }

  /**
   * Put a freshly made thumbnail where thumbnails live now: the record's vault
   * folder, not the store. Falls back to the store if the write cannot be
   * verified — a picture in the store is a picture, and losing it to be tidy
   * would be a bad trade.
   */
  async function setThumb(rec, dataUrl, source) {
    if (!rec || !dataUrl) return;
    rec.thumbSource = source;
    const hub = api();
    if (hub && hub.printLibSaveThumb) {
      let res = null;
      try { res = await hub.printLibSaveThumb(rec.id, dataUrl); } catch (_) { res = null; }
      if (res && res.ok && res.verified && res.filename) {
        rec.thumbFile = res.filename;
        delete rec.thumb;
        cacheThumb(rec.id, dataUrl);
        return;
      }
    }
    rec.thumb = dataUrl;      // unverified, so it stays where it is known to be
  }

  async function enrichPrintFile(rec, fullPath) {
    const hub = api(); if (!hub) return;
    // A record can legitimately have NO file: the library also holds entries
    // made from a printer's own history, where there is nothing on disk to
    // parse. Reading `.ext` off null threw a TypeError from OUTSIDE the try
    // below, so enrichment died before the thumbnail and geometry work that
    // does not need a file either.
    if (!rec || !rec.sourceFile) return;
    /* A converted file is an alternative to this print made for another
     * printer, which is what a version is — so the old list becomes the new one
     * rather than sitting beside it as a fourth vocabulary for one idea. Adds
     * nothing and selects nothing new; the original stays on show. */
    if (_V()) { const patch = _V().fromConverted(rec); if (patch && patch.versions) Object.assign(rec, patch); }
    const ext = rec.sourceFile.ext;
    let tooBig = false, noPicture = false, problem = '';
    try {
      if (ext === 'gcode' || ext === 'gco' || ext === '3mf') {
        if (hub.parsePrintFile) {
          const p = await hub.parsePrintFile(fullPath);
          /* A REFUSAL IS TRUTHY, and this treated it as an answer.
           *
           * Past the size ceiling the handler returns {ok:false, error, …} with
           * no numbers on it, so `if (p)` passed and every field was overwritten
           * with `undefined`: the file joined the library with no print time, no
           * weight, no material and no slicer, and nothing anywhere said why.
           * That is what "a big file can't be read" looks like from the shop's
           * side — the import LOOKS like it worked. */
          if (p && p.ok === false) {
            if (p.warnings && p.warnings.includes('too-large')) tooBig = true;
            // Not only the size ceiling: this handler also refuses a path
            // outside the directories it will read. That refusal was silent too.
            else problem = problem || p.error || '';
          }
          if (p && p.ok !== false) rec.parsed = Object.assign({}, rec.parsed, { printTimeMins: p.printTimeMins, filamentGrams: p.filamentGrams, filamentType: p.filamentType, slicer: p.slicer });
          // A g-code file has no mesh, so it used to get no geometryKey at all —
          // and its contentHash changes on every re-slice, so the same model came
          // back a stranger and per-file calibration never reached MIN_JOBS. The
          // printed envelope survives re-slicing; see lib/gcode-geometry.js.
          const mi = MI();
          if (mi && p && p.ok !== false) {
            try {
              if (p.silhouette && mi.gcodeGeometryKey) {
                rec.geometryKey = mi.gcodeGeometryKey(p.silhouette);
              } else if (p.geometry) {
                // A 3MF carries a mesh, and the parse above already measured it —
                // the volume and triangle count were being shown to the shop and
                // then thrown away. Same key an STL gets, from the same numbers,
                // so a model imported as a 3MF and the same model imported as an
                // STL recognise each other.
                rec.geometryKey = mi.geometryKey(p.geometry);
              }
            } catch (_) { /* non-fatal */ }
          }
        }
        if (hub.extractThumbnail) {
          const th = await hub.extractThumbnail(fullPath);
          // An empty answer is ordinary — plenty of 3MFs carry no thumbnail —
          // so the refusal has to say it is one, or a big file looks like a
          // plain one. It costs the PICTURE and not the numbers, which is a
          // different sentence.
          if (th && th.tooLarge) noPicture = true;
          if (th) {
            if (Array.isArray(th.colors) && th.colors.length) rec.colors = th.colors;
            if (th.swapCount) rec.swapCount = th.swapCount;
            if (th.pngBase64) await setThumb(rec, await resizeDataUrl('data:image/png;base64,' + th.pngBase64, 280, 0.82), 'embedded');
          }
        }
      }
      /* IDENTITY IS NOT A THUMBNAIL CONCERN, and must not be gated like one.
       *
       * geometry matching is the only key that still recognises a model after a
       * re-slice: contentHash hashes the bytes, and a slicer that writes its own
       * time estimate into the filename (SnapmakerOrca: `MBS_PLA_5h36m.gcode`)
       * changes fileRef too. So every condition this sits behind is a condition
       * on whether a model can be recognised at all.
       *
       * It used to sit behind `!rec.thumb && … && KhaytStlThumb` — a file that
       * already had a picture, or a build shipped without the thumbnail
       * RENDERER, silently got no key. Then, still behind the base64 round trip
       * and a keepTriangles parse IN THE PAGE, which is the expensive shape: a
       * model too big to DRAW got no volume, no bounding box and no key either,
       * and per-file calibration quietly fell back to the machine median for it.
       *
       * Measuring and drawing are different questions. The measurements come
       * from main now, off the file already on disk, with no bytes crossing
       * IPC — so a big STL is measured and simply not drawn. */
      if ((ext === 'stl' || ext === 'obj') && hub.parsePrintFile) {
        const p = await hub.parsePrintFile(fullPath);
        if (p && p.ok === false) {
          if (p.warnings && p.warnings.includes('too-large')) tooBig = true;
          else problem = problem || p.error || '';
        } else if (p && p.geometry) {
          rec.parsed = Object.assign({}, rec.parsed, {
            triangleCount: p.geometry.triangleCount,
            volumeMm3: p.geometry.volumeMm3,
            bbox: p.geometry.bbox,
          });
          // A weaker signal than the hash: the same mesh in a different
          // container. Never presented as certainty — see lib/model-identity.
          //
          // Through MI(), not the bare global. This file already guards every other use
          // that way, and this one did not: in an app that does not load model-identity
          // the bare name threw a ReferenceError straight into the catch below, so
          // geometryKey was never set and geometry matching silently did nothing. The
          // catch is for a malformed mesh, not for a missing module.
          const mi = MI();
          if (mi) { try { rec.geometryKey = mi.geometryKey(rec.parsed); } catch (_) { /* non-fatal */ } }
        }
      }

      // The picture, and only the picture. Refused past the mesh budget, which
      // is a smaller number than the one above on purpose: a triangle list costs
      // about six times the file's own size, and by now the numbers are in.
      if (ext === 'stl' && !rec.thumb && hub.printLibReadBytes && KhaytStl && KhaytStlThumb) {
        // {ok, b64|reason}. This used to be a bare string or null, and `if (b64)`
        // skipped everything for all four reasons null could mean — including a
        // file that was merely big.
        const rb = await hub.printLibReadBytes(fullPath);
        if (rb && rb.ok === false && rb.reason === 'too-large') noPicture = true;
        if (rb && rb.ok && rb.b64) {
          try {
            const g = KhaytStl.parseStl(base64ToArrayBuffer(rb.b64), { keepTriangles: true });
            if (g.triangles && g.triangles.length) {
              const r = KhaytStlThumb.renderStlThumbnail(g.triangles, { size: 300 });
              if (r.ok && r.dataUrl) await setThumb(rec, r.dataUrl, 'render');
            }
          } catch (_) { /* obj / bad stl → icon fallback */ }
        }
      }
    } catch (_) { /* keep whatever we got */ }
    /* Said out loud, and the two sentences are not the same.
     *
     * The record is KEPT either way — the file is in the vault, it opens in a
     * slicer, it prints. `tooBig` means nothing could be read and the shop has
     * numbers to type. `noPicture` means it WAS read and only the preview is
     * missing, which is worth a quieter note and no work. Collapsing them would
     * tell a shop to go and type figures that are already on the card. */
    if (tooBig) toast(t('intake.too_large') || 'That file is too large for Khayt to read.', 'warning', 6000);
    else if (problem) toast(problem, 'warning', 6000);
    else if (noPicture) toast(t('plib.no_preview_large') || 'Too big to draw a preview — its measurements are in.', 'info', 5000);
    rec.updatedAt = Date.now();
    saveAll();
    renderPrintFiles();
  }

  async function resolveModelPath(rec) {
    const hub = api(); if (!hub || !hub.printLibList) return null;
    const files = await hub.printLibList(rec.id);
    if (!Array.isArray(files) || !files.length) return null;
    /* `rec.sourceFile` can be NULL — removePart() sets it so when the last part
     * goes, and thumb.jpg keeps the vault folder non-empty, so the guard above
     * does not catch it. Pressing Identify on such a record threw a TypeError
     * out of an async handler: no dialog, no toast, nothing happened. */
    const named = rec.sourceFile && files.find((f) => f.filename === rec.sourceFile.filename);
    const openable = named || files.find((f) => MODEL_EXT.test(String(f.filename || '')));
    return openable ? openable.fullPath : null;
  }

  async function view3d(id) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    const hub = api();
    if (!hub || !hub.printLibMesh || typeof openModelViewer !== 'function') return;
    const full = await resolveModelPath(rec);
    if (!full) { toast(t('plib.view3d_nofile') || 'Model file not found.', 'error'); return; }
    let m;
    try { m = await hub.printLibMesh(full); } catch (_) { m = null; }
    if (!m || !m.ok || !m.verts) { toast(t('plib.view3d_nomesh') || 'No 3D geometry in that file.', 'error'); return; }
    openModelViewer({ verts: m.verts, count: m.count, bbox: m.bbox, colors: m.colors, triColors: m.triColors, triObj: m.triObj, triCode: m.triCode, palette: m.palette, plates: m.plates, volumeMm3: m.volumeMm3, name: rec.name || rec.sourceFile?.filename || '' });
  }

  /**
   * Every part of this print, as paths on disk, in the record's own order.
   *
   * Silently short: a part whose file is not in the vault is dropped rather
   * than turning the open into an error, because a print with eleven of its
   * twelve files is still worth opening. The COUNT comes back with the paths so
   * the toast can say eleven and not twelve.
   */
  async function resolvePartPaths(rec) {
    const hub = api(); if (!hub || !hub.printLibList) return [];
    let files = [];
    try { files = await hub.printLibList(rec.id); } catch (_) { files = []; }
    if (!Array.isArray(files) || !files.length) return [];
    const byName = new Map(files.map((f) => [String(f.filename), f.fullPath]));
    const paths = partsOf(rec).map((p) => byName.get(String(p.filename))).filter(Boolean);
    if (paths.length) return paths;
    /* A record whose parts name nothing on disk still opens what IS there —
     * the pre-`files[]` shape, where the old code took files[0].
     *
     * But hub:printlib-list returns EVERY file in the vault folder, and that
     * folder also holds the record's thumb.jpg and any converted 3MF. Taking
     * files[0] blind meant the fallback could hand the slicer a JPEG. Only a
     * model or a G-code is a thing to open. */
    const openable = files.find((f) => MODEL_EXT.test(String(f.filename || '')));
    return openable ? [openable.fullPath] : [];
  }

  /**
   * Open a print in the slicer.
   *
   * `overrideFull` opens exactly one file and is what a converted file and a
   * single part use. Without it the WHOLE print opens — all four of Spiderman's
   * files in one slicer window, not just his head.
   */
  async function openInSlicer(id, overrideFull) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    const hub = api(); if (!hub || !hub.printLibOpenSlicer) return;
    const full = overrideFull ? [overrideFull] : await resolvePartPaths(rec);
    if (!full.length) { toast(t('plib.file_missing') || 'File is missing.', 'error'); return; }
    const slicers = (global.KhaytSlicers ? KhaytSlicers.listSlicers(settings) : []);
    // More than one slicer configured → let the maker pick which to launch.
    if (slicers.length > 1) {
      const preferId = rec.slicerId;
      openFormModal({
        title: t('slicer.pick_title') || 'Choose slicer',
        sizeLg: false, noSave: true,
        bodyHtml: `<p class="pf-pick-hint">${escapeHtml(t('slicer.pick_hint') || 'Open this file with which slicer?')}</p>
          <div class="pf-slicer-list">${slicers.map((s) => `<button type="button" class="btn pf-slicer-pick${s.id === preferId ? ' primary' : ''}" data-slicer-id="${escapeHtml(s.id)}">🖨 ${escapeHtml(s.name)}</button>`).join('')}</div>`,
        onMount(modal) {
          modal.querySelectorAll('[data-slicer-id]').forEach((b) => b.addEventListener('click', async () => {
            const s = slicers.find((x) => x.id === b.dataset.slicerId);
            modal.querySelector('[data-act="cancel"]')?.click();
            await doOpen(rec, full, s);
          }));
        },
      });
      return;
    }
    await doOpen(rec, full, (global.KhaytSlicers ? KhaytSlicers.defaultSlicer(settings) : null));
  }

  /** `full` is a LIST of paths — a print may be several files. */
  async function doOpen(rec, full, slicer) {
    const hub = api(); if (!hub || !hub.printLibOpenSlicer) return;
    const paths = Array.isArray(full) ? full : [full];
    const slicerPath = slicer ? slicer.path : ((settings.slicer && settings.slicer.path) || '');
    // Remember the maker's choice on the file so next time it's pre-highlighted.
    if (slicer && slicer.id && rec.slicerId !== slicer.id) { rec.slicerId = slicer.id; rec.updatedAt = Date.now(); saveAll(); }
    // One command with several arguments where the main process can take it, so
    // a twelve-part print is one slicer window. An older main process only knows
    // the single-path shape; it gets the primary, which is what it did before.
    const r = paths.length > 1 && hub.printLibOpenSlicerAll
      ? await hub.printLibOpenSlicerAll(paths, slicerPath)
      : await hub.printLibOpenSlicer(paths[0], slicerPath);
    if (!r || !r.ok) toast((r && r.error) || (t('plib.open_failed') || 'Could not open the file.'), 'error');
    else if (r.opened === 'slicer') toast(((r.count > 1 ? (t('plib.opened_slicer_n', { n: String(r.count) }) || `Opened ${r.count} files in your slicer.`) : (t('plib.opened_slicer') || 'Opened in your slicer.'))) + (slicer ? ` (${slicer.name})` : ''), 'success');
    else toast(t('plib.opened_os') || 'Opened. Set a slicer path in Settings → Printers to open there.', 'info', 4200);
  }

  async function convertPrintFile(id) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    if (typeof openConverter !== 'function') { toast(t('conv.desktop_only') || 'The converter is available in the desktop app.', 'error'); return; }
    const full = await resolveModelPath(rec);
    if (!full) { toast(t('plib.file_missing') || 'File is missing.', 'error'); return; }
    openConverter({ path: full, name: rec.originalName || rec.name || 'model.3mf', recordId: rec.id });
  }

  function toggleFav(id) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    rec.favorite = !rec.favorite; rec.updatedAt = Date.now();
    saveAll(); renderPrintFiles();
  }

  function deletePrintFile(id) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    openFormModal({
      title: t('plib.delete_title') || 'Delete print file',
      sizeLg: false, saveLabel: t('common.delete') || 'Delete',
      bodyHtml: `<p>${escapeHtml((t('plib.delete_confirm') || 'Remove "{name}" and its files? This cannot be undone.').replace('{name}', rec.name || rec.originalName || ''))}</p>`,
      async onSave() {
        const hub = api();
        // Track whether the files actually went. The record was removed and "File deleted"
        // toasted unconditionally, so a locked or permission-denied file vanished from the
        // library while remaining on disk.
        let allGone = true;
        if (hub && hub.printLibList && hub.printLibDelete) {
          try {
            const files = await hub.printLibList(id);
            for (const f of (files || [])) {
              if ((await hub.printLibDelete(f.fullPath)) === false) allGone = false;
            }
          } catch (e) { console.error('printLibDelete:', e); allGone = false; }
        }
        printFiles = (printFiles || []).filter((r) => r.id !== id);
        // …and out of the selection, or the bar counts a record that is gone.
        _selected.delete(id);
        saveAll(); renderPrintFiles();
        if (allGone) toast(t('plib.deleted') || 'File deleted', 'success');
        else toast('⚠ ' + (t('plib.delete_partial') || 'Removed from the library, but some files could not be deleted from disk'), 'error', 7000);
      },
    });
  }

  function editPrintFile(id) {
    const rec = (printFiles || []).find((r) => r.id === id); if (!rec) return;
    const profOptions = (slicerProfiles || []).map((s) =>
      `<option value="${escapeHtml(s.id)}"${rec.slicerProfileId === s.id ? ' selected' : ''}>${escapeHtml(s.name)}</option>`).join('');
    const matOptions = [...new Set((inventory || []).map((i) => i.material).filter(Boolean))].map((m) =>
      `<option value="${escapeHtml(m)}"${rec.material === m ? ' selected' : ''}>${escapeHtml(m)}</option>`).join('');
    openFormModal({
      title: t('plib.edit_title') || 'Edit print file',
      saveLabel: t('common.save') || 'Save',
      bodyHtml: `
        <label>${escapeHtml(t('plib.name') || 'Name')}</label>
        <input type="text" id="pfName" value="${escapeHtml(rec.name || '')}">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px;">
          <div>
            <label>${escapeHtml(t('plib.material') || 'Material')}</label>
            <input type="text" id="pfMaterial" list="pfMatList" value="${escapeHtml(rec.material || '')}">
            <datalist id="pfMatList">${matOptions}</datalist>
          </div>
          <div>
            <label>${escapeHtml(t('plib.slicer_profile') || 'Slicer profile')}</label>
            <select id="pfProfile"><option value="">— ${escapeHtml(t('common.none') || 'None')} —</option>${profOptions}</select>
          </div>
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px;">
          <div>
            <!-- A SET THAT BELONGS TOGETHER. This box is the one that used to
                 say "Folder" and holds the same field; what changed is that the
                 name now means something on the catalogue too. -->
            <label>${escapeHtml(t('plib.group') || 'Group')}</label>
            <input type="text" id="pfFolder" list="pfFolderList" maxlength="60" value="${escapeHtml(groupOf(rec))}" placeholder="${escapeHtml(t('plib.group_ph') || 'e.g. Saudi Kings')}">
            <datalist id="pfFolderList">${nameOptions('group')}</datalist>
          </div>
          <div>
            <!-- WHAT THE THING IS. The question you ask when you do not know
                 what you want yet, which is what a library of hundreds does. -->
            <label>${escapeHtml(t('plib.category') || 'Category')}</label>
            <input type="text" id="pfCategory" list="pfCatList" maxlength="60" value="${escapeHtml(categoryOf(rec))}" placeholder="${escapeHtml(t('plib.category_ph') || 'e.g. Busts')}">
            <datalist id="pfCatList">${nameOptions('category')}</datalist>
          </div>
        </div>
        <div style="display:grid;grid-template-columns:1fr;gap:10px;margin-top:10px;">
          <div>
            <label>${escapeHtml(t('plib.tags') || 'Tags (comma separated)')}</label>
            <input type="text" id="pfTags" value="${escapeHtml((rec.tags || []).join(', '))}">
            <!-- A <datalist> cannot help here: it matches the WHOLE value of an
                 input, and this one holds a list. So the tags the shop already
                 uses are offered as chips instead — one press adds or removes
                 one, which is what keeps a library on one spelling per idea. -->
            ${(() => {
              const known = knownTags().slice(0, 24);
              if (!known.length) return '';
              const on = new Set((rec.tags || []).map((x) => String(x).trim().toLowerCase()));
              return `<div class="pf-tagpick" role="group" aria-label="${escapeHtml(t('plib.tags_reuse') || 'Tags you already use')}">`
                + known.map((tg) => `<button type="button" class="pf-tagchip ${on.has(tg.toLowerCase()) ? 'on' : ''}" data-tagpick="${escapeHtml(tg)}">${escapeHtml(tg)}</button>`).join('')
                + '</div>';
            })()}
          </div>
        </div>
        <!-- WHERE IT CAME FROM, AND WHAT MAY BE DONE WITH IT.
             A library holds work the shop made and models it downloaded, and
             they look identical in a grid. Most of what is on the model sites
             is Creative Commons and a good share of that is NonCommercial —
             the licence that makes selling a print of it a breach rather than
             a favour — and Khayt recorded neither fact. -->
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px;">
          <div>
            <label>${escapeHtml(t('plib.source') || 'Source')}</label>
            <input type="text" id="pfSource" maxlength="300"
              value="${escapeHtml(rec.source || '')}"
              placeholder="${escapeHtml(t('plib.source_ph') || 'e.g. printables.com/model/… or your own design')}">
          </div>
          <div>
            <label>${escapeHtml(t('plib.licence') || 'Licence')}</label>
            <select id="pfLicence">
              <!-- "Not recorded" is the default and is NOT the same as "may not
                   be sold". A shop that has filled nothing in must not be told
                   it cannot sell its own work. -->
              <option value="">— ${escapeHtml(t('plib.licence_unknown') || 'Not recorded')} —</option>
              ${(window.KhaytModelLicence ? window.KhaytModelLicence.list() : []).map((l) =>
                `<option value="${escapeHtml(l.id)}"${rec.licence === l.id ? ' selected' : ''}>`
                + escapeHtml(t('plib.licence_' + l.id.replace(/-/g, '_')) || l.id)
                + `</option>`).join('')}
            </select>
          </div>
        </div>
        <label style="margin-top:10px;">${escapeHtml(t('plib.tested_notes') || 'Tested settings / notes')}</label>
        <textarea id="pfNotes" rows="3">${escapeHtml(rec.testedNotes || '')}</textarea>
        <label style="margin-top:10px;">${escapeHtml(t('plib.photo') || 'Photo (optional)')}</label>
        <div style="display:flex;align-items:center;gap:10px;">
          <img id="pfPhotoPrev" src="${rec.userPhoto ? safeImageSrc(rec.userPhoto) : ''}" alt="" style="width:56px;height:56px;object-fit:cover;border-radius:8px;${rec.userPhoto ? '' : 'display:none;'}background:var(--bg-elev);">
          <input type="file" id="pfPhoto" accept="image/*">
          ${rec.userPhoto ? `<button type="button" class="btn small ghost" id="pfPhotoClear">${escapeHtml(t('common.remove') || 'Remove')}</button>` : ''}
        </div>`,
      onMount(modal) {
        /* Clicking a chip edits the text box rather than a hidden model, so what
         * you see in the field is always what will be saved — and a tag typed by
         * hand and one added by chip end up in the same place. */
        const tagsInput = modal.querySelector('#pfTags');
        modal.querySelectorAll('[data-tagpick]').forEach((chip) => {
          chip.addEventListener('click', () => {
            const tag = chip.dataset.tagpick;
            const cur = _T() ? _T().normaliseTags(tagsInput.value, knownTags())
                             : tagsInput.value.split(',').map((x) => x.trim()).filter(Boolean);
            const k = String(tag).toLowerCase();
            const next = cur.some((x) => String(x).toLowerCase() === k)
              ? cur.filter((x) => String(x).toLowerCase() !== k)
              : cur.concat([tag]);
            tagsInput.value = next.join(', ');
            chip.classList.toggle('on');
          });
        });

        let stagedPhoto = rec.userPhoto || null;
        let cleared = false;
        const prev = modal.querySelector('#pfPhotoPrev');
        modal.querySelector('#pfPhoto').addEventListener('change', async (ev) => {
          const file = ev.target.files && ev.target.files[0]; if (!file) return;
          try { stagedPhoto = await resizeImage(file, 480, 0.82); cleared = false; if (prev) { prev.src = stagedPhoto; prev.style.display = ''; } }
          catch (_) { toast(t('plib.photo_failed') || 'Could not load image', 'error'); }
        });
        const clr = modal.querySelector('#pfPhotoClear');
        if (clr) clr.addEventListener('click', () => { stagedPhoto = null; cleared = true; if (prev) prev.style.display = 'none'; });
        modal._getPhoto = () => ({ stagedPhoto, cleared });
      },
      onSave(modal) {
        const name = modal.querySelector('#pfName').value.trim();
        if (!name) { toast(t('plib.name_required') || 'Enter a name', 'error'); return false; }
        rec.name = name;
        rec.material = modal.querySelector('#pfMaterial').value.trim();
        rec.slicerProfileId = modal.querySelector('#pfProfile').value || null;
        /* Reconciled against what the shop already uses, so typing "Resin" where
         * "resin" exists files it under the tag they already have rather than
         * inventing a second one. A genuinely new tag keeps the spelling typed —
         * see lib/tags.js for why this does not simply lower-case everything. */
        rec.tags = _T()
          ? _T().normaliseTags(modal.querySelector('#pfTags').value, knownTags())
          : modal.querySelector('#pfTags').value.split(',').map((s) => s.trim()).filter(Boolean);
        /* Through lib/organise.js, so a name that matches one already in use
         * ADOPTS ITS SPELLING. Typed straight onto the record, "saudi kings"
         * became a second collection holding part of the first — and a group is
         * exactly the thing you reach for when you want the whole set.
         *
         * `folder` is written alongside `group`; see lib/organise.js. */
        const _org = _O();
        const _patch = {
          group: (modal.querySelector('#pfFolder').value || ''),
          category: (modal.querySelector('#pfCategory').value || ''),
        };
        Object.assign(rec, _org
          ? _org.assign(rec, _patch, { group: knownNames('group'), category: knownNames('category') })
          : { group: _patch.group.trim(), folder: _patch.group.trim(), category: _patch.category.trim() });
        rec.testedNotes = modal.querySelector('#pfNotes').value.trim();
        rec.source = modal.querySelector('#pfSource').value.trim();
        rec.licence = modal.querySelector('#pfLicence').value;
        const ph = modal._getPhoto ? modal._getPhoto() : null;
        if (ph) { if (ph.cleared) rec.userPhoto = null; else if (ph.stagedPhoto) rec.userPhoto = ph.stagedPhoto; }
        rec.updatedAt = Date.now();
        saveAll(); renderPrintFiles();
        toast(t('plib.saved') || 'Saved', 'success');
      },
    });
  }

  // warnIfAlreadyHave is public because it is a real library operation — "is
  // this one we already have?" — that any future ingest path needs, not just
  // the picker. It is also the one branch here that DELETES a record, so it
  // is worth being able to drive end to end.
  /**
   * Move thumbnails out of the store, one record at a time, on proof.
   *
   * THE ONLY RULE THAT MATTERS: the in-store copy is dropped after the on-disk
   * one has been read back and compared, and never before. `printLibSaveThumb`
   * does the write and the read-back in a single main-process call for exactly
   * that reason — a verification the renderer had to ask for separately is one
   * a reload could land in the middle of.
   *
   * A record that fails keeps its picture where it is and is tried again next
   * launch. Nothing is deleted, ever: the worst case is a library that has not
   * shrunk yet.
   *
   * Paced deliberately. A shop with three thousand thumbnails is 40 MB of
   * base64 to rewrite, and doing it in one pass would freeze the window on the
   * launch after an update — which is exactly when somebody is least willing to
   * believe nothing is wrong.
   */
  let _migrating = false;
  async function migrateThumbsToDisk() {
    const hub = api();
    const TS = (typeof window !== 'undefined' && window.KhaytThumbStore) || null;
    if (_migrating || !TS || !hub || !hub.printLibSaveThumb) return;
    const plan = TS.planMigration(printFiles || []);
    if (!plan.length) return;
    _migrating = true;
    let moved = 0, sinceSave = 0;
    try {
      /* THE WHOLE LIBRARY, NOT FORTY OF IT.
       *
       * This did `plan.slice(0, 40)` — one slice per launch — because a round
       * was expensive: painting every card cost 701 ms at 3,415 records and was
       * paid on every round. So a shop with 3,415 files needed EIGHTY-SIX
       * launches to finish, and until it did, its data file stayed over the size
       * the store will save at. The thing this migration exists to fix stayed
       * broken for months of daily use.
       *
       * Painting is bounded now (a page, not the library), and the write itself
       * was never the cost: 0.8 ms per preview, measured. 3,415 of them is about
       * six seconds of background work, yielding to the window between each, and
       * the shop is under the cap when they next close the app instead of in
       * March.
       *
       * Saved every 400 so progress survives a quit half way; a crash before a
       * save leaves verified files on disk that the next run simply rewrites. */
      for (const item of plan) {
        const rec = (printFiles || []).find((r) => r.id === item.id);
        if (!rec || !TS.isDataUrl(rec.thumb)) continue;
        let res = null;
        try { res = await hub.printLibSaveThumb(rec.id, rec.thumb); } catch (_) { res = null; }
        const patch = TS.completeMigration(rec, res && res.ok ? res : null);
        if (!patch.migrated) continue;                 // keeps its picture, tried again next time
        cacheThumb(rec.id, rec.thumb);                 // so the card does not blink
        delete rec.thumb;
        rec.thumbFile = patch.thumbFile;
        moved++;
        sinceSave++;
        if (sinceSave >= 400) { sinceSave = 0; saveAll(); }
        await new Promise((r) => setTimeout(r, 0));    // let the window breathe
      }
    } finally { _migrating = false; }
    if (moved) { saveAll(); renderPrintFiles(); }
  }

  const pub = { renderPrintFiles, migrateThumbsToDisk, addPrintFile, openInSlicer, editPrintFile, deletePrintFile, attachConverted, importConvertedAsNew, warnIfAlreadyHave, identifyPrintFile };
  Object.assign(global, pub);
  global.KhaytPrintFiles = pub;
  if (typeof module !== 'undefined' && module.exports) module.exports = pub;
})(typeof globalThis !== 'undefined' ? globalThis : this);
