/* ============================================================
   BED READY — cloud library panel (renderer).
   A self-contained modal that connects the app to the user's MakerRun
   account and pulls their saved designs from makerrun.com, using the
   main-process bridge on window.hubAPI (see preload.js):
     bedreadyLinked / bedreadyOpenSignIn / onBedreadyLinked /
     bedreadyLibrary / bedreadyDownloadAll / bedreadyUnlink
   NAMING, because the two halves of this feature do not share a name: the
   main-process client is lib/makerrun-library.js (MakerRun is the product), while
   this file keeps the bedready-* prefix because renderer/bedready-*.js is the Bed
   Ready FLAVOR family — bedready-home, bedready-icons, bedready-queue. The prefix
   here means "the Bed Ready app's UI", not "the BedReady product".

   Bed Ready flavor only; no dependency on the app's nav/tab system, so it
   can't affect Khayt or the existing renderer. Worth knowing that this gate is
   why Khayt itself cannot open a MakerRun library today (see main.js, which also
   refuses to link an account off this flavor) — a product question, not an
   oversight of the rename.
   ============================================================ */
(function () {
  if (typeof document === 'undefined' || document.documentElement.dataset.app !== 'bedready') return;
  var api = (typeof window !== 'undefined' && window.hubAPI) || null;
  if (!api || typeof api.bedreadyLinked !== 'function') return; // older preload — silently unavailable

  var root = null, body = null, items = [], linkedListenerBound = false, lastFocus = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function build() {
    root = document.createElement('div');
    root.className = 'brl-overlay';
    root.style.cssText = 'position:fixed;inset:0;z-index:9999;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.55);padding:24px;';
    root.innerHTML =
      '<div class="brl-modal" role="dialog" aria-modal="true" aria-label="' + esc(t('brl.title')) + '" style="width:100%;max-width:900px;max-height:86vh;overflow:auto;border-radius:18px;background:var(--surface,#ffffff);color:var(--text,#14201e);border:1px solid var(--border,rgba(17,40,37,0.10));box-shadow:0 20px 60px rgba(0,0,0,.5);">' +
        '<div style="display:flex;align-items:center;justify-content:space-between;gap:12px;padding:18px 20px;border-bottom:1px solid var(--border,rgba(17,40,37,0.10));">' +
          // Was a hardcoded English "My BedReady library" while the aria-label beside it
          // used t('brl.title') — so a translated build showed one name and announced another,
          // and the MakerRun rename would have moved only the announced one. The leading emoji
          // goes with it: this panel is Bed Ready-only, and t() strips decorative leading emoji
          // in that flavor precisely because they read as off-identity there.
          '<b style="font-size:16px;">' + esc(t('brl.title')) + '</b>' +
          // The public catalogue lives in its own panel (bedready-makerrun.js); this is the door to it
          // from the user's own saved designs. Drawn only when that panel loaded.
          '<span style="flex:1;"></span>' +
          ((window.BedReadyMakerRun && typeof window.BedReadyMakerRun.open === 'function')
            ? '<button type="button" class="brl-browse" style="cursor:pointer;border:1px solid var(--border,rgba(17,40,37,0.16));background:transparent;color:inherit;border-radius:10px;padding:6px 12px;font-size:13px;">' + esc(t('mr.browse_button')) + '</button>'
            : '') +
          '<button type="button" class="brl-close" aria-label="Close" style="border:0;background:transparent;color:inherit;font-size:20px;cursor:pointer;line-height:1;" title="Close">✕</button>' +
        '</div>' +
        '<div class="brl-body" style="padding:20px;"></div>' +
      '</div>';
    document.body.appendChild(root);
    body = root.querySelector('.brl-body');
    root.addEventListener('click', function (e) { if (e.target === root) close(); });
    root.querySelector('.brl-close').addEventListener('click', close);
    var browseBtn = root.querySelector('.brl-browse');
    if (browseBtn) browseBtn.addEventListener('click', function () {
      close();
      if (window.BedReadyMakerRun && typeof window.BedReadyMakerRun.open === 'function') window.BedReadyMakerRun.open();
    });
    document.addEventListener('keydown', function (e) {
      if (!isOpen()) return;
      if (e.key === 'Escape') { close(); return; }
      if (e.key === 'Tab') trapTab(e); // keep focus inside the modal
    });
  }

  // Visible, focusable controls currently inside the modal.
  function focusables() {
    if (!root) return [];
    return Array.prototype.slice
      .call(root.querySelectorAll('button, [href], [tabindex]:not([tabindex="-1"])'))
      .filter(function (el) { return el.offsetParent !== null; });
  }
  function trapTab(e) {
    var f = focusables();
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }

  var isOpen = function () { return root && root.style.display !== 'none'; };
  // Make the app behind the modal inert so an AT virtual cursor can't wander the page underneath.
  function bgInert(on) {
    if (!document.body) return;
    Array.prototype.forEach.call(document.body.children, function (el) {
      if (el === root) return;
      try { if (on) el.setAttribute('inert', ''); else el.removeAttribute('inert'); } catch (e) { /* noop */ }
    });
  }
  function close() {
    if (root) root.style.display = 'none';
    bgInert(false);
    if (lastFocus && lastFocus.focus) { try { lastFocus.focus(); } catch (e) { /* trigger gone */ } }
    lastFocus = null;
  }

  // 1×1 transparent GIF — a cover <img> shows this until the main process returns the real data: URI,
  // so there's no broken-image flash (remote img-src is blocked by the CSP; covers are proxied instead).
  var BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

  function btn(label, kind) {
    // Solid brand teal (matches .btn.primary); the old purple→cyan→lime gradient was off-identity and
    // failed contrast at the lime end. --accent resolves in both light/dark themes.
    var cta = 'background:var(--accent,#199e8f);color:#fff;';
    var plain = 'background:var(--surface-2,#f2f6f5);color:var(--text,#14201e);border:1px solid var(--border,rgba(17,40,37,0.16));';
    var primary = (kind === 'primary' || kind === 'connect' || kind === 'sync' || kind === 'import');
    return '<button type="button" class="brl-btn" data-act="' + kind + '" style="cursor:pointer;border:0;border-radius:12px;padding:11px 18px;font-weight:600;font-size:14px;' + (primary ? cta : plain) + '">' + esc(label) + '</button>';
  }

  function loadCovers() {
    if (!body || typeof api.bedreadyCover !== 'function') return;
    Array.prototype.forEach.call(body.querySelectorAll('img.brl-cover[data-cover]'), function (img) {
      var url = img.getAttribute('data-cover');
      img.removeAttribute('data-cover'); // fetch each cover once
      if (!url) return;
      api.bedreadyCover(url).then(function (r) { if (r && r.ok && r.dataUrl) img.src = r.dataUrl; }).catch(function () {});
    });
  }

  function setBody(html) { if (body) body.innerHTML = html; bindActions(); }

  function bindActions() {
    if (!body) return;
    body.querySelectorAll('.brl-btn').forEach(function (b) {
      b.addEventListener('click', function () { onAct(b.getAttribute('data-act')); });
    });
  }

  async function onAct(act) {
    if (act === 'connect') { try { api.bedreadyOpenSignIn(); } catch (e) {} renderConnecting(); return; }
    if (act === 'recheck') { await refresh(); return; }
    if (act === 'sync') { await sync(); return; }
    if (act === 'import') { await importAll(); return; }
    if (act === 'download') { await downloadAll(); return; }
    if (act === 'unlink') { try { await api.bedreadyUnlink(); } catch (e) {} items = []; await refresh(); return; }
    if (act === 'close') { close(); return; }
  }

  function renderConnecting() {
    setBody(
      '<p style="margin:0 0 6px;">' + t('brl.opening') + '</p>' +
      '<p style="margin:0 0 16px;color:var(--text-muted,#869390);font-size:13px;">' + t('brl.opening_hint') + '</p>' +
      btn(t('brl.recheck'), 'recheck'));
  }

  function renderNotLinked() {
    setBody(
      '<p style="margin:0 0 6px;">' + t('brl.connect_lead') + '</p>' +
      '<p style="margin:0 0 18px;color:var(--text-muted,#869390);font-size:13px;">' + t('brl.connect_hint') + '</p>' +
      btn(t('brl.connect'), 'connect'));
  }

  /* ---- browsing ---------------------------------------------------------
   * The shell (search box, chips, sort) is rendered once; paint() then updates
   * only the chips and the grid. A full re-render per keystroke would destroy
   * the <input> the user is typing into and drop the caret.
   * ---------------------------------------------------------------------- */

  var view = { query: '', types: [], downloadableOnly: false, sort: 'name' };

  /** lib/library-browse.js — loaded as a plain script ahead of this one. */
  function B() { return (typeof globalThis !== 'undefined' && globalThis.KhaytLibraryBrowse) || null; }

  function visible() { var b = B(); return b ? b.browse(items, view) : items.slice(); }

  function filtering() { return !!(view.query || view.types.length || view.downloadableOnly); }

  function chipStyle(on) {
    return 'border:1px solid ' + (on ? 'var(--accent,#159d68)' : 'var(--border,rgba(17,40,37,0.10))') + ';' +
      'background:' + (on ? 'color-mix(in srgb, var(--accent,#159d68) 14%, transparent)' : 'transparent') + ';' +
      'color:inherit;border-radius:999px;padding:4px 10px;font-size:12px;cursor:pointer;';
  }

  function chip(label, on, act, arg) {
    return '<button type="button" class="brl-chip" data-act="' + act + '"' +
      (arg != null ? ' data-arg="' + esc(arg) + '"' : '') +
      ' aria-pressed="' + (on ? 'true' : 'false') + '" style="' + chipStyle(on) + '">' + esc(label) + '</button>';
  }

  /** One design card. `idx` indexes `items`, so an action never depends on titles being unique. */
  function card(it, idx) {
    var b = B();
    var type = (b ? b.typeOf(it) : (it.fileType || '3mf')).toUpperCase();
    var can = b ? b.isDownloadable(it) : !!it.downloadUrl;
    var name = b ? b.labelOf(it) : (it.title || it.slug || '');
    var cover = it.cover
      ? '<img class="brl-cover" data-cover="' + esc(it.cover) + '" src="' + BLANK + '" alt="" ' +
        'style="width:100%;aspect-ratio:4/3;object-fit:cover;background:var(--surface-3,#e8efed);display:block;">'
      : '<div style="width:100%;aspect-ratio:4/3;background:var(--surface-3,#e8efed);"></div>';
    var act = function (a, label) {
      return '<button type="button" class="brl-one" data-act="' + a + '" data-idx="' + idx + '" ' +
        'style="flex:1;border:1px solid var(--border,rgba(17,40,37,0.10));background:transparent;color:inherit;' +
        'border-radius:8px;padding:5px;font-size:12px;cursor:pointer;">' + esc(label) + '</button>';
    };
    return '<div class="brl-card" style="border:1px solid var(--border,rgba(17,40,37,0.10));border-radius:12px;' +
      'overflow:hidden;display:flex;flex-direction:column;">' + cover +
      '<div style="padding:8px 10px;display:flex;flex-direction:column;gap:6px;flex:1;">' +
        '<div title="' + esc(name) + '" style="font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + esc(name) + '</div>' +
        '<div style="font-size:11px;color:var(--text-muted,#869390);">' + esc(type) +
          printFacts(it) + (can ? '' : ' · ' + esc(t('brl.link_only'))) + '</div>' +
        licenceLine(it) +
        (can ? '<div style="display:flex;gap:6px;margin-top:auto;">' +
                 (canImport() ? act('one-import', t('brl.add')) : '') +
                 act('one-download', t('brl.download_one')) +
               '</div>' : '') +
      '</div></div>';
  }

  /**
   * The designer's own print numbers, appended to the type line.
   *
   * Every field is optional and each is rendered only if present — an absent
   * layer height must read as "not stated", never as a zero, because a shop
   * quoting from this would take 0 mm as a number rather than as a silence.
   *
   * `fromVerifiedProfile` decides the tooltip and nothing else. It says whether
   * these came out of a file MakerRun opened or a form somebody filled in, and
   * that is the difference between a measurement and a claim — worth saying on
   * hover, not worth a badge competing with the design's name.
   */
  function printFacts(it) {
    var p = it && it.print;
    if (!p) return '';
    var bits = [];
    if (typeof p.layerHeightMm === 'number' && p.layerHeightMm > 0) bits.push(p.layerHeightMm + ' mm');
    if (Array.isArray(p.filamentTypes) && p.filamentTypes.length) bits.push(p.filamentTypes.join('/'));
    if (typeof p.colorCount === 'number' && p.colorCount > 1) bits.push(p.colorCount + ' ' + t('conv.colours'));
    if (!bits.length) return '';
    var src = p.fromVerifiedProfile ? t('brl.print_from_file') : t('brl.print_from_designer');
    return '<span title="' + esc(src) + '"> · ' + esc(bits.join(' · ')) +
      (p.fromVerifiedProfile ? '' : ' *') + '</span>';
  }

  /**
   * Whether the licence permits selling the print — in three states, because the
   * API answers in three.
   *
   * `null` is the important one and is NOT "unknown, assume no". MakerRun reads
   * only the licences it knows plus the Creative Commons NC clause and returns
   * null for anything else, deliberately: guessing false blocks a shop from a
   * print it may sell, and guessing true tells it to sell one it may not. So
   * null renders as "check the licence" — a job, not a verdict.
   *
   * A `true` is only ever about the COMMERCIAL clause. Attribution, share-alike
   * and no-derivatives still bind, which is why this says "commercial use
   * allowed" and not anything resembling "free to use". The licence's own name
   * is on hover, so the shop can always reach the actual terms.
   */
  function licenceLine(it) {
    if (!it || it.commercialUse === undefined) return '';
    var v = it.commercialUse;
    var label = v === true ? t('brl.lic_commercial')
      : v === false ? t('brl.lic_noncommercial')
      : t('brl.lic_check');
    var colour = v === true ? 'var(--success,#159d68)'
      : v === false ? 'var(--warning,#a8710a)'
      : 'var(--text-muted,#869390)';
    var name = it.license ? String(it.license) : '';
    return '<div style="font-size:11px;color:' + colour + ';"' +
      (name ? ' title="' + esc(name) + '"' : '') + '>' + esc(label) + '</div>';
  }

  /**
   * Where a saved design came from, for the print-file record: its page, its
   * licence as the record's own licence id when that can be read with
   * certainty (lib/makerrun-terms.js), and the raw MakerRun facts beside it.
   * The same three fields the catalogue browser (bedready-makerrun.js) passes,
   * so a design reads the same whichever door it came through.
   */
  function provenance(it) {
    var T = (typeof globalThis !== 'undefined' && globalThis.BedReadyMakerRunTerms) || null;
    var out = {};
    if (it && typeof it.url === 'string' && /^https:\/\//.test(it.url)) out.source = it.url;
    if (it && it.license && T) { var lic = T.toRecordLicence(it.license); if (lic) out.licence = lic; }
    if (it && it.slug) out.makerrun = { slug: String(it.slug), license: it.license || null, creator: it.creator || null };
    return out;
  }

  function canImport() {
    return typeof api.bedreadyImportToLib === 'function' && typeof window.importConvertedAsNew === 'function';
  }

  /** Update chips and grid in place. Safe to call while the search box has focus. */
  function paint() {
    if (!body) return;
    body.querySelectorAll('.brl-chip').forEach(function (c) {
      var a = c.getAttribute('data-act');
      var on = a === 'type' ? view.types.indexOf(c.getAttribute('data-arg')) !== -1
        : a === 'dl-only' ? view.downloadableOnly : false;
      c.setAttribute('aria-pressed', on ? 'true' : 'false');
      c.setAttribute('style', chipStyle(on));
      if (a === 'clear') c.hidden = !filtering();
    });

    var grid = body.querySelector('.brl-grid');
    if (!grid) return;
    var shown = visible();
    grid.innerHTML = shown.length
      ? '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;">' +
          shown.map(function (it) { return card(it, items.indexOf(it)); }).join('') + '</div>'
      : '<p style="margin:22px 0;text-align:center;color:var(--text-muted,#869390);font-size:13px;">' +
          esc(t('brl.no_match')) + '</p>';

    var count = body.querySelector('.brl-count');
    if (count) {
      count.textContent = filtering()
        ? t('brl.showing', { n: shown.length, total: items.length })
        : t(items.length === 1 ? 'brl.saved_one' : 'brl.saved_other', { n: items.length });
    }
    bindCards();
    loadCovers();
  }

  function bindCards() {
    if (!body) return;
    body.querySelectorAll('.brl-one').forEach(function (b) {
      b.addEventListener('click', function () {
        var it = items[Number(b.getAttribute('data-idx'))];
        if (it) onOne(b.getAttribute('data-act'), it);
      });
    });
  }

  /** Wire the controls once, after the shell is in the DOM. */
  function bindControls() {
    if (!body) return;
    var q = body.querySelector('.brl-q');
    if (q) {
      q.addEventListener('input', function () { view.query = q.value; paint(); });
      // Escape clears the search rather than closing the whole panel — losing the
      // library because you wanted to undo a search is a bad trade.
      q.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && q.value) { e.stopPropagation(); q.value = ''; view.query = ''; paint(); }
      });
    }
    var sort = body.querySelector('.brl-sort');
    if (sort) sort.addEventListener('change', function () { view.sort = sort.value; paint(); });

    body.querySelectorAll('.brl-chip').forEach(function (c) {
      c.addEventListener('click', function () {
        var a = c.getAttribute('data-act');
        if (a === 'type') {
          var ty = c.getAttribute('data-arg');
          var at = view.types.indexOf(ty);
          if (at === -1) view.types.push(ty); else view.types.splice(at, 1);
        } else if (a === 'dl-only') {
          view.downloadableOnly = !view.downloadableOnly;
        } else if (a === 'clear') {
          view.query = ''; view.types = []; view.downloadableOnly = false;
          if (q) q.value = '';
        }
        paint();
      });
    });
  }

  function renderLinked() {
    var b = B();
    var f = b ? b.facets(items) : { total: items.length, types: {}, presentTypes: [], linkOnly: 0, downloadable: 0 };
    var controls = '';

    if (items.length) {
      // Chip counts come from the WHOLE library, so a chip does not renumber as
      // you type into the search box — a control that moves cannot be aimed at.
      var typeChips = f.presentTypes.map(function (ty) {
        return chip(ty.toUpperCase() + ' (' + f.types[ty] + ')', false, 'type', ty);
      }).join(' ');

      controls =
        '<div style="margin:12px 0 10px;display:flex;gap:8px;flex-wrap:wrap;align-items:center;">' +
          // `view` outlives a re-render (Sync rebuilds the shell), so the box has to
          // be refilled from it — otherwise it comes back empty while the grid stays
          // filtered, and the missing designs have no visible explanation.
          '<input type="search" class="brl-q" value="' + esc(view.query) + '" placeholder="' + esc(t('brl.search_ph')) + '" ' +
            'aria-label="' + esc(t('brl.search_ph')) + '" ' +
            'style="flex:1;min-width:180px;padding:6px 10px;border:1px solid var(--border,rgba(17,40,37,0.10));' +
            'border-radius:8px;background:var(--surface-2,transparent);color:inherit;font-size:13px;">' +
          '<select class="brl-sort" aria-label="' + esc(t('brl.sort')) + '" ' +
            'style="padding:6px 8px;border:1px solid var(--border,rgba(17,40,37,0.10));border-radius:8px;' +
            'background:var(--surface-2,transparent);color:inherit;font-size:12px;">' +
            '<option value="name">' + esc(t('brl.sort_az')) + '</option>' +
            '<option value="name-desc">' + esc(t('brl.sort_za')) + '</option>' +
            '<option value="type">' + esc(t('brl.sort_type')) + '</option>' +
          '</select>' +
        '</div>' +
        (f.presentTypes.length > 1 || f.linkOnly
          ? '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px;">' + typeChips +
              (f.linkOnly ? ' ' + chip(t('brl.downloadable'), false, 'dl-only') : '') +
              ' ' + chip(t('brl.clear'), false, 'clear') +
            '</div>'
          : '') +
        '<div class="brl-grid" style="margin-bottom:12px;"></div>';
    }

    var downloadable = f.downloadable;
    var showImportAll = downloadable && canImport();
    setBody(
      '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;">' +
        '<span class="brl-count" style="color:var(--text-muted,#869390);font-size:13px;">' +
          (items.length ? esc(t(items.length === 1 ? 'brl.saved_one' : 'brl.saved_other', { n: items.length })) : esc(t('brl.empty_hint'))) + '</span>' +
        btn(t('brl.sync'), 'sync') +
      '</div>' + controls +
      '<div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;">' +
        (showImportAll ? btn(t('brl.add_all', { n: downloadable }), 'import') : '') +
        (downloadable ? btn(t('brl.download_folder'), 'download') : '') +
        btn(t('brl.disconnect'), 'unlink') +
      '</div>' +
      '<div class="brl-result" role="status" aria-live="polite" style="margin-top:12px;font-size:13px;"></div>');

    bindControls();
    paint();
  }

  /**
   * Download or import a single design.
   *
   * Reuses the bulk channels with a one-item array rather than adding new IPC —
   * hub:bedready-download-all already takes a list, and it is the same SSRF-guarded
   * path, so a per-item button cannot reach anywhere the bulk button could not.
   */
  async function onOne(act, it) {
    var b = B();
    var name = b ? b.labelOf(it) : (it.title || it.slug || '');
    if (act === 'one-download') {
      result(esc(t('brl.downloading_one', { name: name })));
      try {
        var r = await api.bedreadyDownloadAll([it]);
        if (!r || !r.ok) { result(esc((r && r.error) || t('brl.download_failed')), 'var(--danger,#e0492f)'); return; }
        if (r.saved && r.saved.length) result(esc(t('brl.downloaded_one', { name: name, folder: folderOf(r) })), 'var(--ok,#159d68)');
        else if (r.skipped && r.skipped.length) result(esc(t('brl.skipped_one', { name: name })), '#fbbf24');
        else result(esc(t('brl.download_failed')), 'var(--danger,#e0492f)');
      } catch (e) { result(esc(e && e.message ? e.message : t('brl.download_failed')), 'var(--danger,#e0492f)'); }
      return;
    }
    if (act === 'one-import') {
      if (!canImport()) { result(esc(t('brl.no_import')), 'var(--danger,#e0492f)'); return; }
      result(esc(t('brl.adding_one', { name: name })));
      try {
        var vaultId = (typeof uid === 'function') ? uid('PF') : ('PF' + Date.now().toString(36));
        var d = await api.bedreadyImportToLib(it, vaultId);
        if (!d || !d.ok) { result(esc((d && d.error) || t('brl.add_one_failed')), 'var(--danger,#e0492f)'); return; }
        await window.importConvertedAsNew(Object.assign({
          vaultId: vaultId, filename: d.filename, ext: d.ext, size: d.size,
          displayName: name, sourceName: d.filename, noSwitch: true,
        }, provenance(it)));
        result(esc(t('brl.added_one', { name: name })), 'var(--ok,#159d68)');
      } catch (e) { result(esc(e && e.message ? e.message : t('brl.add_one_failed')), 'var(--danger,#e0492f)'); }
    }
  }

  function result(html, color) {
    var el = body && body.querySelector('.brl-result');
    if (el) el.innerHTML = '<span style="color:' + (color || 'var(--text-muted,#869390)') + ';">' + html + '</span>';
  }

  async function sync() {
    result(esc(t('brl.syncing')));
    try {
      var r = await api.bedreadyLibrary();
      if (!r || !r.ok) { result(esc((r && r.error) || t('brl.sync_failed')), 'var(--danger,#e0492f)'); return; }
      items = r.items || [];
      renderLinked();
      result(esc(items.length ? t(items.length === 1 ? 'brl.found_one' : 'brl.found_other', { n: items.length }) : t('brl.none_yet')), 'var(--ok,#159d68)');
    } catch (e) { result(esc(e && e.message ? e.message : t('brl.sync_failed')), 'var(--danger,#e0492f)'); }
  }

  // Import saved designs straight into the Print-File Library (via a per-design vault download +
  // importConvertedAsNew), so a synced design lands IN the app with a thumbnail instead of orphaned
  // in a Downloads folder. Falls back to "Download to folder" if the bridge isn't available.
  async function importAll() {
    var list = visible().filter(function (i) { return i.downloadUrl; });
    if (!list.length) { result(esc(t('brl.nothing_import')), 'var(--text-muted,#869390)'); return; }
    if (typeof api.bedreadyImportToLib !== 'function' || typeof window.importConvertedAsNew !== 'function') {
      result(esc(t('brl.no_import')), 'var(--danger,#e0492f)'); return;
    }
    result(esc(t(list.length === 1 ? 'brl.adding_n_one' : 'brl.adding_n_other', { n: list.length })));
    var added = 0, failed = 0;
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      try {
        var vaultId = (typeof uid === 'function') ? uid('PF') : ('PF' + Date.now().toString(36) + i);
        var r = await api.bedreadyImportToLib(it, vaultId);
        if (!r || !r.ok) { failed++; continue; }
        await window.importConvertedAsNew(Object.assign({
          vaultId: vaultId, filename: r.filename, ext: r.ext, size: r.size,
          displayName: it.title || it.slug, sourceName: r.filename, noSwitch: true,
        }, provenance(it)));
        added++;
      } catch (e) { failed++; }
    }
    var msg = t(added === 1 ? 'brl.added_n_one' : 'brl.added_n_other', { n: added });
    if (failed) msg += ' ' + t('brl.n_not_added', { n: failed });
    result(esc(msg), added ? 'var(--ok,#159d68)' : 'var(--danger,#e0492f)');
    if (added && typeof switchTab === 'function') { close(); switchTab('printfiles-tab'); }
  }

  /**
   * The folder main actually wrote to. It is reported rather than named here because
   * it varies: a shop that downloaded designs before the MakerRun rename keeps its
   * existing BedReady-Library folder, and a message that hardcoded either name would
   * be wrong for half of them.
   */
  function folderOf(r) { return (r && r.folder) || 'MakerRun-Library'; }

  async function downloadAll() {
    result(esc(t('brl.downloading')));
    try {
      // The visible set, not the whole library — with a filter on, the button
      // says "Download to folder" next to a grid of three designs.
      var r = await api.bedreadyDownloadAll(visible());
      if (!r || !r.ok) { result(esc((r && r.error) || t('brl.download_failed')), 'var(--danger,#e0492f)'); return; }
      var msg = t(r.saved.length === 1 ? 'brl.saved_file_one' : 'brl.saved_file_other', { n: r.saved.length, folder: folderOf(r) });
      if (r.failed && r.failed.length) msg += ' ' + t('brl.n_failed', { n: r.failed.length });
      // `kept` is reported separately from `skipped`, and it has to be reported at
      // all: now that a design whose bytes have not moved is not fetched again, a
      // second sync of an unchanged library saves nothing — and "Saved 0 files"
      // on its own reads as a failure of the thing that just worked perfectly.
      if (r.kept && r.kept.length) msg += ' ' + t('brl.n_kept', { n: r.kept.length });
      if (r.skipped && r.skipped.length) msg += ' ' + t('brl.n_skipped', { n: r.skipped.length });
      result(esc(msg), r.failed && r.failed.length ? '#fbbf24' : 'var(--ok,#159d68)');
    } catch (e) { result(esc(e && e.message ? e.message : t('brl.download_failed')), 'var(--danger,#e0492f)'); }
  }

  async function refresh() {
    setBody('<p style="color:var(--text-muted,#869390);">' + esc(t('brl.checking')) + '</p>');
    try {
      var r = await api.bedreadyLinked();
      if (r && r.ok && r.linked) renderLinked(); else renderNotLinked();
    } catch (e) { renderNotLinked(); }
  }

  function open() {
    if (!root) build();
    if (!linkedListenerBound && typeof api.onBedreadyLinked === 'function') {
      api.onBedreadyLinked(function () { if (isOpen()) refresh(); });
      linkedListenerBound = true;
    }
    lastFocus = (typeof document !== 'undefined' && document.activeElement) || null;
    root.style.display = 'flex';
    bgInert(true);
    refresh();
    // Move focus into the dialog for keyboard/AT users (the close button is always present).
    var closeBtn = root.querySelector('.brl-close');
    if (closeBtn && closeBtn.focus) { try { closeBtn.focus(); } catch (e) { /* noop */ } }
  }

  window.BedReadyLibrary = { open: open };
})();
