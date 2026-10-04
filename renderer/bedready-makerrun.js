/* ============================================================
   BED READY — MakerRun catalogue panel (renderer).

   Two jobs, one modal:
     open()         BROWSE the public makerrun.com catalogue, read a design,
                    and download one of its files into the print-file library.
     publish(recId) PUBLISH a print file from the library as a new MakerRun
                    listing (create → model file → optional picture).

   Talks to main only through window.hubAPI (preload.js): makerrunBrowse,
   makerrunDesign, makerrunDownloadToLib, makerrunPublishCreate,
   makerrunPublishFile, makerrunPublishImages, makerrunStatus, makerrunDelete,
   makerrunOpenAge, makerrunOpenPage — plus the existing account bridge
   (bedreadyLinked / bedreadyOpenSignIn / onBedreadyLinked) and the cover proxy
   (bedreadyCover), because remote images are not allowed by this page's CSP.

   The renderer never names a filesystem path: it names a print-file record and
   a filename, and main resolves them inside that record's vault folder.

   Sibling of bedready-library.js (the user's own SAVED designs). Same modal
   conventions: html[data-app="bedready"] guard, focus trap, inert background.
   ============================================================ */
(function () {
  if (typeof document === 'undefined' || document.documentElement.dataset.app !== 'bedready') return;
  var api = (typeof window !== 'undefined' && window.hubAPI) || null;
  if (!api || typeof api.makerrunBrowse !== 'function') return; // older preload — silently unavailable

  var PAGE = 24;
  var BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  var MUTED = 'var(--text-muted,#869390)';
  var BORDER = 'var(--border,rgba(17,40,37,0.12))';
  var OK = 'var(--ok,#159d68)';
  var BAD = 'var(--danger,#e0492f)';
  var WARN = 'var(--warning,#a8710a)';

  var root = null, body = null, lastFocus = null, linkedBound = false;
  var mode = 'browse';
  var seq = 0; // newest browse request wins; an older answer arriving late is dropped
  var view = { q: '', category: '', material: '', verified: false, sale: '', offset: 0 };
  var results = { designs: [], page: null, loading: false, error: null };
  var detail = null; // { slug, data, error, loading, msg }
  var pub = null;    // publish-flow state, see publish()
  var debounceTimer = null;

  /** lib/makerrun-terms.js — loaded as a plain script ahead of this one. */
  function T() {
    return (typeof globalThis !== 'undefined' && globalThis.BedReadyMakerRunTerms)
      || (typeof window !== 'undefined' && window.BedReadyMakerRunTerms) || null;
  }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function tx(key, vars) { try { return t(key, vars); } catch (e) { return key; } }
  function fmtBytes(n) {
    if (!(n > 0)) return '';
    if (n >= 1048576) return (n / 1048576).toFixed(n >= 10485760 ? 0 : 1) + ' MB';
    if (n >= 1024) return Math.round(n / 1024) + ' KB';
    return n + ' B';
  }
  function catLabel(v) { var tm = T(); return (tm && tm.categoryLabel(v)) || v || ''; }
  function materialLabel(m) {
    return m === 'rigid' ? tx('mr.mat_rigid') : m === 'flexible' ? tx('mr.mat_flexible') : m === 'multi' ? tx('mr.mat_multi') : '';
  }

  /* ---- modal shell ---------------------------------------------------- */

  function build() {
    root = document.createElement('div');
    root.className = 'mr-overlay';
    root.style.cssText = 'position:fixed;inset:0;z-index:9999;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.55);padding:24px;';
    root.innerHTML =
      '<div class="mr-modal" role="dialog" aria-modal="true" aria-labelledby="mrTitle" style="position:relative;width:100%;max-width:1040px;height:88vh;display:flex;flex-direction:column;border-radius:18px;background:var(--surface,#ffffff);color:var(--text,#14201e);border:1px solid ' + BORDER + ';box-shadow:0 20px 60px rgba(0,0,0,.5);overflow:hidden;">' +
        '<div style="display:flex;align-items:center;gap:12px;padding:16px 20px;border-bottom:1px solid ' + BORDER + ';">' +
          '<b id="mrTitle" style="font-size:16px;"></b>' +
          '<span style="flex:1;"></span>' +
          '<button type="button" class="mr-close" aria-label="' + esc(tx('mr.close')) + '" title="' + esc(tx('mr.close')) + '" style="border:0;background:transparent;color:inherit;font-size:20px;cursor:pointer;line-height:1;">✕</button>' +
        '</div>' +
        '<div class="mr-body" style="flex:1;overflow:auto;padding:18px 20px;"></div>' +
        // The design drawer sits over the body, not inside it, so it stays put while the grid scrolls.
        '<div class="mr-drawer-host"></div>' +
      '</div>';
    document.body.appendChild(root);
    body = root.querySelector('.mr-body');
    root.addEventListener('click', function (e) { if (e.target === root) close(); });
    root.querySelector('.mr-close').addEventListener('click', close);
    document.addEventListener('keydown', function (e) {
      if (!isOpen()) return;
      if (e.key === 'Escape') {
        if (mode === 'browse' && detail) { detail = null; renderBrowse(); return; }
        if (pub && pub.running) return; // never abandon a publish half-way by a stray keypress
        close();
        return;
      }
      if (e.key === 'Tab') trapTab(e);
    });
    // One delegated handler for every control, so re-rendering never leaks listeners.
    var modal = root.querySelector('.mr-modal');
    modal.addEventListener('click', onClick);
    modal.addEventListener('input', onInput);
    modal.addEventListener('change', onChange);
  }

  function focusables() {
    if (!root) return [];
    return Array.prototype.slice
      .call(root.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'))
      .filter(function (el) { return !el.disabled && el.offsetParent !== null; });
  }
  function trapTab(e) {
    var f = focusables();
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }
  function isOpen() { return !!root && root.style.display !== 'none'; }
  function bgInert(on) {
    if (!document.body) return;
    Array.prototype.forEach.call(document.body.children, function (el) {
      if (el === root) return;
      try { if (on) el.setAttribute('inert', ''); else el.removeAttribute('inert'); } catch (e) { /* noop */ }
    });
  }
  function show(title) {
    if (!root) build();
    if (!linkedBound && typeof api.onBedreadyLinked === 'function') {
      api.onBedreadyLinked(function () { if (isOpen()) onLinked(); });
      linkedBound = true;
    }
    root.querySelector('#mrTitle').textContent = title;
    if (!isOpen()) {
      lastFocus = document.activeElement || null;
      root.style.display = 'flex';
      bgInert(true);
    }
  }
  function close() {
    if (root) root.style.display = 'none';
    bgInert(false);
    if (lastFocus && lastFocus.focus) { try { lastFocus.focus(); } catch (e) { /* trigger gone */ } }
    lastFocus = null;
  }
  function focusFirst(sel) {
    var el = root && root.querySelector(sel);
    if (el && el.focus) { try { el.focus(); } catch (e) { /* noop */ } }
  }

  function btn(label, act, opts) {
    var o = opts || {};
    var primary = 'background:var(--accent,#199e8f);color:#fff;border:1px solid transparent;';
    var plain = 'background:var(--surface-2,#f2f6f5);color:var(--text,#14201e);border:1px solid ' + BORDER + ';';
    var danger = 'background:transparent;color:' + BAD + ';border:1px solid ' + BAD + ';';
    var style = o.kind === 'primary' ? primary : o.kind === 'danger' ? danger : plain;
    return '<button type="button" class="mr-btn" data-mr="' + esc(act) + '"' +
      (o.arg != null ? ' data-arg="' + esc(o.arg) + '"' : '') + (o.disabled ? ' disabled' : '') +
      ' style="cursor:pointer;border-radius:10px;padding:8px 14px;font-weight:600;font-size:13px;' + style + (o.disabled ? 'opacity:.55;cursor:not-allowed;' : '') + '">' + esc(label) + '</button>';
  }
  var INPUT = 'padding:7px 10px;border:1px solid ' + BORDER + ';border-radius:8px;background:var(--surface-2,transparent);color:inherit;font-size:13px;';

  /* ---- errors: branch on the code, never the status ------------------- */

  /**
   * What to tell the user for a failed call, and what they can do about it.
   * Returns html. `ctx` is 'browse' | 'download' | 'publish'.
   */
  function errorHtml(r, ctx) {
    var code = (r && r.code) || '';
    var msg, actions = '';
    if (code === 'not_linked' || code === 'relink' || code === 'auth' || code === 'unauthorized') {
      msg = tx('mr.err_relink');
      actions = btn(tx('mr.connect'), 'connect', { kind: 'primary' });
    } else if (code === 'mfa_required') {
      msg = tx('mr.err_mfa');
      actions = btn(tx('mr.reconnect'), 'connect', { kind: 'primary' });
    } else if (code === 'age_required') {
      msg = tx('mr.err_age');
      actions = btn(tx('mr.confirm_age'), 'age', { kind: 'primary' });
    } else if (code === 'maintenance') {
      msg = tx('mr.err_maintenance', { mins: String(Math.max(1, Math.round((Number(r.retryAfter) || 60) / 60))) });
    } else if (code === 'rate_limited') {
      msg = tx('mr.err_rate', { secs: String(Number(r.retryAfter) || 60) });
    } else if (code === 'forbidden' || code === 'rejected') {
      msg = ctx === 'download' ? tx('mr.err_forbidden_download') : tx('mr.err_forbidden');
    } else if (code === 'not_found') {
      msg = tx('mr.err_not_found');
    } else if (code === 'network' || code === 'timeout') {
      msg = tx('mr.err_network');
    } else if (code === 'unavailable') {
      msg = tx('mr.err_unavailable');
    } else if (code === 'bad_response') {
      msg = tx('mr.err_bad_response');
    } else if (code === 'invalid' && r && Array.isArray(r.details) && r.details.length) {
      msg = r.details.map(function (d) { return d.message; }).filter(Boolean).join(' ') || (r.error || tx('mr.err_generic'));
    } else {
      msg = (r && r.error) || tx('mr.err_generic');
    }
    return '<div class="mr-error" role="alert" style="margin:10px 0;padding:10px 12px;border-radius:10px;border:1px solid ' + BAD + ';font-size:13px;">' +
      '<div>' + esc(msg) + '</div>' + (actions ? '<div style="margin-top:8px;display:flex;gap:8px;flex-wrap:wrap;">' + actions + '</div>' : '') + '</div>';
  }

  async function isLinked() {
    try { var r = await api.bedreadyLinked(); return !!(r && r.ok && r.linked); } catch (e) { return false; }
  }
  function connect() { try { api.bedreadyOpenSignIn(); } catch (e) { /* noop */ } }
  function onLinked() {
    if (mode === 'publish' && pub) renderPublish();
    else if (detail) renderBrowse();
  }

  /* ---- BROWSE ---------------------------------------------------------- */

  function open() {
    mode = 'browse';
    pub = null;
    show(tx('mr.browse_title'));
    renderBrowse();
    focusFirst('.mr-q');
    if (!results.page && !results.loading) load();
  }

  function selectHtml(cls, label, current, options) {
    return '<select class="' + cls + '" aria-label="' + esc(label) + '" style="flex:0 1 auto;width:auto;max-width:220px;' + INPUT + '">' +
      options.map(function (o) {
        return '<option value="' + esc(o[0]) + '"' + (String(current) === String(o[0]) ? ' selected' : '') + '>' + esc(o[1]) + '</option>';
      }).join('') + '</select>';
  }

  function renderBrowse() {
    if (!body) return;
    var tm = T();
    var cats = [['', tx('mr.all_categories')]].concat(((tm && tm.CATEGORIES) || []).map(function (c) { return [c.value, c.label]; }));
    body.innerHTML =
      '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px;">' +
        '<input type="search" class="mr-q" value="' + esc(view.q) + '" placeholder="' + esc(tx('mr.search_ph')) + '" aria-label="' + esc(tx('mr.search_ph')) + '" style="flex:1 1 240px;width:auto;min-width:0;' + INPUT + '">' +
        selectHtml('mr-cat', tx('mr.category'), view.category, cats) +
        selectHtml('mr-mat', tx('mr.material'), view.material, [['', tx('mr.any_material')], ['rigid', tx('mr.mat_rigid')], ['flexible', tx('mr.mat_flexible')], ['multi', tx('mr.mat_multi')]]) +
        selectHtml('mr-sale', tx('mr.price'), view.sale, [['', tx('mr.price_any')], ['free', tx('mr.price_free')], ['sale', tx('mr.price_sale')]]) +
        '<label style="display:inline-flex;align-items:center;gap:6px;font-size:13px;"><input type="checkbox" class="mr-ver"' + (view.verified ? ' checked' : '') + ' style="width:auto;margin:0;">' + esc(tx('mr.verified_only')) + '</label>' +
      '</div>' +
      '<div class="mr-status" role="status" aria-live="polite" style="font-size:13px;color:' + MUTED + ';margin-bottom:10px;"></div>' +
      '<div class="mr-grid"></div>' +
      '<div class="mr-pager" style="display:flex;gap:8px;justify-content:center;align-items:center;margin:14px 0 4px;"></div>';
    paintResults();
    paintDrawer();
  }

  function paintResults() {
    if (!body) return;
    var status = body.querySelector('.mr-status');
    var grid = body.querySelector('.mr-grid');
    var pager = body.querySelector('.mr-pager');
    if (!grid) return;
    if (results.error) {
      status.textContent = '';
      grid.innerHTML = errorHtml(results.error, 'browse') + btn(tx('mr.retry'), 'retry');
      pager.innerHTML = '';
      return;
    }
    if (results.loading && !results.designs.length) {
      status.textContent = tx('mr.loading');
      grid.innerHTML = '';
      pager.innerHTML = '';
      return;
    }
    var pg = results.page || { total: 0, offset: 0 };
    var n = results.designs.length;
    status.textContent = results.loading ? tx('mr.loading')
      : n ? tx('mr.showing', { from: String(pg.offset + 1), to: String(pg.offset + n), total: String(pg.total) })
      : '';
    grid.innerHTML = n
      ? '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:12px;">' +
          results.designs.map(cardHtml).join('') + '</div>'
      : '<p style="margin:28px 0;text-align:center;color:' + MUTED + ';font-size:13px;">' + esc(tx('mr.no_results')) + '</p>';
    var hasPrev = pg.offset > 0;
    var hasNext = pg.offset + n < pg.total;
    pager.innerHTML = (hasPrev || hasNext)
      ? btn(tx('mr.prev'), 'prev', { disabled: !hasPrev }) + btn(tx('mr.next'), 'next', { disabled: !hasNext })
      : '';
    loadCovers(grid);
  }

  function cardHtml(d, idx) {
    var meta = [];
    if (d.category) meta.push(esc(catLabel(d.category)));
    if (d.material && d.material !== 'rigid') meta.push(esc(materialLabel(d.material)));
    var price = d.sale
      ? '<span style="color:' + WARN + ';">' + esc(d.sale.price != null ? tx('mr.for_sale_price', { price: String(d.sale.price), currency: d.sale.currency || '' }) : tx('mr.for_sale')) + '</span>'
      : '<span style="color:' + OK + ';">' + esc(tx('mr.free')) + '</span>';
    return '<button type="button" class="mr-card" data-mr="detail" data-arg="' + idx + '" aria-label="' + esc(d.title) + '" ' +
      'style="text-align:start;cursor:pointer;padding:0;border:1px solid ' + BORDER + ';border-radius:12px;overflow:hidden;display:flex;flex-direction:column;background:transparent;color:inherit;">' +
      (d.cover
        ? '<img class="mr-cover" data-cover="' + esc(d.cover) + '" src="' + BLANK + '" alt="" style="width:100%;aspect-ratio:4/3;object-fit:cover;background:var(--surface-3,#e8efed);display:block;">'
        : '<span style="display:block;width:100%;aspect-ratio:4/3;background:var(--surface-3,#e8efed);"></span>') +
      '<span style="display:flex;flex-direction:column;gap:4px;padding:8px 10px;">' +
        '<span style="font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' + esc(d.title) + '">' + esc(d.title) + '</span>' +
        '<span style="font-size:11px;color:' + MUTED + ';">' + meta.join(' · ') + (d.verification && d.verification.badge ? ' · <span style="color:' + OK + ';">✓ ' + esc(tx('mr.verified')) + '</span>' : '') + '</span>' +
        '<span style="font-size:11px;">' + price + (d.nsfw ? ' · <span style="color:' + BAD + ';">18+</span>' : '') + '</span>' +
      '</span></button>';
  }

  function loadCovers(scope) {
    if (!scope || typeof api.bedreadyCover !== 'function') return;
    Array.prototype.forEach.call(scope.querySelectorAll('img.mr-cover[data-cover]'), function (img) {
      var url = img.getAttribute('data-cover');
      img.removeAttribute('data-cover');
      if (!url) return;
      api.bedreadyCover(url).then(function (r) { if (r && r.ok && r.dataUrl) img.src = r.dataUrl; }).catch(function () {});
    });
  }

  async function load() {
    var mine = ++seq;
    results.loading = true;
    results.error = null;
    paintResults();
    var opts = { q: view.q, category: view.category, material: view.material, verified: view.verified, limit: PAGE, offset: view.offset };
    if (view.sale === 'free') opts.forSale = false;
    else if (view.sale === 'sale') opts.forSale = true;
    var r;
    try { r = await api.makerrunBrowse(opts); } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
    if (mine !== seq) return; // a newer search started while this one was in flight
    results.loading = false;
    if (!r || !r.ok) { results.error = r || {}; results.designs = []; paintResults(); return; }
    results.designs = Array.isArray(r.designs) ? r.designs : [];
    results.page = r.page || { total: results.designs.length, offset: view.offset };
    paintResults();
  }

  function refilter() { view.offset = 0; detail = null; paintDrawer(); load(); }

  /* ---- design drawer --------------------------------------------------- */

  async function openDetail(d) {
    detail = { slug: d.slug, summary: d, data: null, error: null, loading: true, msg: '' };
    paintDrawer();
    var r;
    try { r = await api.makerrunDesign(d.slug); } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
    if (!detail || detail.slug !== d.slug) return;
    detail.loading = false;
    if (!r || !r.ok) detail.error = r || {};
    else detail.data = r;
    paintDrawer();
    focusFirst('.mr-drawer .mr-btn[data-mr="back"]');
  }

  function licenceHtml(d) {
    var lic = d.license ? esc(d.license) : esc(tx('mr.licence_none'));
    var cu = d.commercialUse;
    var line = cu === true ? tx('mr.lic_commercial') : cu === false ? tx('mr.lic_noncommercial') : tx('mr.lic_check');
    var colour = cu === true ? OK : cu === false ? WARN : MUTED;
    return '<div style="margin:10px 0;"><div style="font-size:12px;color:' + MUTED + ';">' + esc(tx('mr.licence')) + '</div>' +
      '<div style="font-weight:600;">' + lic + '</div>' +
      '<div style="font-size:12px;color:' + colour + ';">' + esc(line) + '</div></div>';
  }

  function verificationHtml(v) {
    if (!v) return '';
    var rows = [];
    var yes = function (on, label) {
      return '<li style="color:' + (on ? OK : MUTED) + ';">' + (on ? '✓ ' : '– ') + esc(label) + '</li>';
    };
    rows.push(yes(v.badge, tx('mr.v_badge')));
    rows.push(yes(v.fileChecked, tx('mr.v_file')));
    rows.push(yes(v.printPhotoConfirmed, tx('mr.v_photo')));
    var pr = v.printer && [v.printer.brand, v.printer.model].filter(Boolean).join(' ');
    return '<div style="margin:10px 0;"><div style="font-size:12px;color:' + MUTED + ';">' + esc(tx('mr.verification')) + '</div>' +
      '<ul style="margin:4px 0 0;padding-inline-start:0;list-style:none;font-size:13px;">' + rows.join('') + '</ul>' +
      (pr ? '<div style="font-size:12px;margin-top:4px;">' + esc(tx('mr.v_printer', { printer: pr })) + '</div>' : '') + '</div>';
  }

  function paintDrawer() {
    if (!body) return;
    var wrap = root && root.querySelector('.mr-drawer-host');
    if (!wrap) return;
    if (!detail || mode !== 'browse') { wrap.innerHTML = ''; return; }
    var head = root.querySelector('.mr-modal > div');
    var top = head ? head.offsetHeight : 57;
    var d = (detail.data && detail.data.design) || detail.summary;
    var inner;
    if (detail.loading) inner = '<p style="color:' + MUTED + ';">' + esc(tx('mr.loading')) + '</p>';
    else if (detail.error) inner = errorHtml(detail.error, 'browse');
    else {
      var data = detail.data;
      var files = (data.files || []).filter(function (f) { return f.hosted; });
      var dlLabel = d.license ? tx('mr.download_under', { licence: d.license }) : tx('mr.download_no_licence');
      var filesHtml = files.length
        ? '<ul style="margin:4px 0 0;padding:0;list-style:none;">' + files.map(function (f, i) {
            return '<li style="display:flex;align-items:center;gap:8px;justify-content:space-between;padding:6px 0;border-top:1px solid ' + BORDER + ';">' +
              '<span style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px;" title="' + esc(f.filename) + '">' + esc(f.filename) +
              (f.sizeBytes ? ' <span style="color:' + MUTED + ';">' + esc(fmtBytes(f.sizeBytes)) + '</span>' : '') + '</span>' +
              btn(dlLabel, 'download', { arg: i, kind: 'primary' }) + '</li>';
          }).join('') + '</ul>'
        : '<p style="font-size:13px;color:' + MUTED + ';">' + esc(d.external ? tx('mr.files_external') : tx('mr.files_none')) + '</p>';
      var profiles = (data.profiles || []).map(function (p) {
        var bits = [[p.printerBrand, p.printerModel].filter(Boolean).join(' '), p.filamentType, p.colorCount > 1 ? tx('mr.n_colours', { n: String(p.colorCount) }) : ''].filter(Boolean);
        return '<li style="font-size:12px;padding:3px 0;">' + esc(bits.join(' · ') || tx('mr.profile_unnamed')) + (p.badge ? ' <span style="color:' + OK + ';">✓</span>' : '') + '</li>';
      }).join('');
      var desc = String(d.description || '');
      if (desc.length > 1500) desc = desc.slice(0, 1500) + '…';
      inner =
        (d.cover ? '<img class="mr-cover" data-cover="' + esc(d.cover) + '" src="' + BLANK + '" alt="" style="width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:10px;background:var(--surface-3,#e8efed);">' : '') +
        '<h3 style="margin:10px 0 2px;font-size:17px;">' + esc(d.title) + '</h3>' +
        (d.creator ? '<div style="font-size:12px;color:' + MUTED + ';">' + esc(tx('mr.by_creator', { name: d.creator })) + '</div>' : '') +
        '<div style="font-size:12px;color:' + MUTED + ';margin-top:2px;">' + esc([catLabel(d.category), materialLabel(d.material)].filter(Boolean).join(' · ')) + '</div>' +
        (d.nsfw ? '<div style="font-size:12px;color:' + BAD + ';margin-top:4px;">' + esc(tx('mr.nsfw_note')) + '</div>' : '') +
        licenceHtml(d) +
        verificationHtml(d.verification) +
        (d.sale ? '<div style="margin:10px 0;padding:8px 10px;border-radius:10px;border:1px solid ' + BORDER + ';font-size:13px;">' +
            esc(d.sale.price != null ? tx('mr.for_sale_price', { price: String(d.sale.price), currency: d.sale.currency || '' }) : tx('mr.for_sale')) +
            ' — ' + esc(tx('mr.sale_external')) + '</div>' : '') +
        '<div style="font-size:12px;color:' + MUTED + ';margin-top:12px;">' + esc(tx('mr.files')) + '</div>' + filesHtml +
        (profiles ? '<div style="font-size:12px;color:' + MUTED + ';margin-top:12px;">' + esc(tx('mr.profiles')) + '</div><ul style="margin:4px 0 0;padding:0;list-style:none;">' + profiles + '</ul>' : '') +
        (desc ? '<div style="font-size:12px;color:' + MUTED + ';margin-top:12px;">' + esc(tx('mr.description')) + '</div><div style="white-space:pre-wrap;font-size:13px;line-height:1.45;">' + esc(desc) + '</div>' : '') +
        '<div class="mr-dl-result" role="status" aria-live="polite" style="font-size:13px;margin-top:10px;">' + (detail.msg || '') + '</div>' +
        '<div style="margin-top:12px;">' + btn(tx('mr.open_page'), 'page') + '</div>';
    }
    wrap.innerHTML =
      '<div class="mr-drawer" role="region" aria-label="' + esc(d.title) + '" style="position:absolute;top:' + top + 'px;inset-inline-end:0;bottom:0;width:min(440px,100%);overflow:auto;padding:16px 18px;background:var(--surface,#fff);border-inline-start:1px solid ' + BORDER + ';box-shadow:-12px 0 30px rgba(0,0,0,.18);">' +
        '<div style="margin-bottom:8px;">' + btn(tx('mr.back'), 'back') + '</div>' + inner +
      '</div>';
    loadCovers(wrap);
  }

  function setDetailMsg(html) {
    if (!detail) return;
    detail.msg = html;
    var el = root && root.querySelector('.mr-dl-result');
    if (el) el.innerHTML = html;
  }

  function canImport() { return typeof api.makerrunDownloadToLib === 'function' && typeof window.importConvertedAsNew === 'function'; }

  /** The licence was named on the button the user pressed; that press is the acknowledgement. */
  async function download(fileIdx) {
    if (!detail || !detail.data) return;
    var d = detail.data.design;
    var f = (detail.data.files || []).filter(function (x) { return x.hosted; })[fileIdx];
    if (!f) return;
    if (!canImport()) { setDetailMsg('<span style="color:' + BAD + ';">' + esc(tx('mr.no_import')) + '</span>'); return; }
    if (!(await isLinked())) {
      setDetailMsg(errorHtml({ code: 'not_linked' }, 'download') + '<div style="font-size:12px;color:' + MUTED + ';">' + esc(tx('mr.signin_download')) + '</div>');
      return;
    }
    setDetailMsg(esc(tx('mr.downloading', { name: f.filename })));
    try {
      var vaultId = (typeof uid === 'function') ? uid('PF') : ('PF' + Date.now().toString(36));
      var r = await api.makerrunDownloadToLib(d.slug, f.filename, vaultId, d.title);
      if (!r || !r.ok) { setDetailMsg(errorHtml(r, 'download')); return; }
      var tm = T();
      var lic = d.license && tm ? tm.toRecordLicence(d.license) : null;
      var meta = {
        vaultId: vaultId, filename: r.filename, ext: r.ext, size: r.size,
        displayName: d.title, sourceName: r.filename, noSwitch: true,
        makerrun: { slug: d.slug, license: d.license || null, creator: d.creator || null },
      };
      if (d.url) meta.source = d.url;
      if (lic) meta.licence = lic;
      await window.importConvertedAsNew(meta);
      setDetailMsg('<span style="color:' + OK + ';">' + esc(tx('mr.added', { name: d.title })) + '</span> ' + btn(tx('mr.open_files'), 'files'));
    } catch (e) {
      setDetailMsg(errorHtml({ error: String(e && e.message || e) }, 'download'));
    }
  }

  /* ---- PUBLISH --------------------------------------------------------- */

  function records() { return (typeof printFiles !== 'undefined' && Array.isArray(printFiles)) ? printFiles : []; }
  function recById(id) { return records().filter(function (r) { return r && r.id === id; })[0] || null; }
  function save() { try { if (typeof saveAll === 'function') saveAll(); } catch (e) { /* noop */ } }
  function repaintLibrary() { try { if (typeof renderPrintFiles === 'function') renderPrintFiles(); } catch (e) { /* noop */ } }

  var MODEL_EXTS = ['3mf', 'stl', 'obj', 'step', 'stp'];

  function guessMaterial(m) {
    var s = String(m || '').toLowerCase();
    if (!s) return '';
    if (/tpu|tpe|flex/.test(s)) return 'flexible';
    return 'rigid';
  }
  function hasPhoto(rec) { return !!(rec && typeof rec.userPhoto === 'string' && /^data:image\//.test(rec.userPhoto)); }
  function hasThumb(rec) { return !!(rec && (rec.thumbFile || (typeof rec.thumb === 'string' && /^data:image\//.test(rec.thumb)))); }

  /**
   * Publish a print file. Opens the form for a record with no listing yet, or the
   * listing's status (and the way to finish or remove a half-made one) if it has one.
   */
  function publish(recId) {
    var rec = recById(recId);
    if (!rec) return;
    mode = 'publish';
    detail = null;
    var tm = T();
    var mrLic = tm ? tm.toMakerRunLicence(rec.licence) : null;
    pub = {
      recId: rec.id,
      form: {
        title: String(rec.name || rec.originalName || '').slice(0, 120),
        description: '',
        category: '',
        material: guessMaterial(rec.material),
        license: mrLic || '',
        nsfw: false,
        includePic: false,
        printClaim: false,
      },
      licenceUnmapped: !!rec.licence && !mrLic,
      errors: {},
      stage: rec.makerrunListing ? 'status' : 'form', // form | confirm | running | status
      steps: null,
      error: null,
      running: false,
      note: '',
    };
    show(tx('mr.publish_title'));
    paintDrawer(); // clears a design drawer left open by browsing
    renderPublish();
  }

  function fieldErr(name) {
    var m = pub && pub.errors[name];
    return m ? '<div class="mr-field-err" id="mrErr-' + name + '" style="color:' + BAD + ';font-size:12px;margin-top:3px;">' + esc(m) + '</div>' : '';
  }
  function invalidAttr(name) { return pub && pub.errors[name] ? ' aria-invalid="true" aria-describedby="mrErr-' + name + '"' : ''; }

  async function renderPublish() {
    if (!body || !pub) return;
    var rec = recById(pub.recId);
    if (!rec) { body.innerHTML = '<p>' + esc(tx('mr.publish_missing')) + '</p>'; return; }
    var linked = await isLinked();
    if (!pub) return;
    if (!linked) {
      body.innerHTML =
        '<p style="margin:0 0 8px;">' + esc(tx('mr.publish_signin')) + '</p>' +
        '<p style="margin:0 0 14px;font-size:13px;color:' + MUTED + ';">' + esc(tx('mr.publish_signin_hint')) + '</p>' +
        btn(tx('mr.connect'), 'connect', { kind: 'primary' }) + ' ' + btn(tx('mr.recheck'), 'recheck');
      return;
    }
    if (pub.stage === 'status') { renderListing(rec); return; }
    if (pub.stage === 'confirm') { renderConfirm(rec); return; }
    if (pub.stage === 'running') { renderSteps(rec); return; }
    renderForm(rec);
  }

  function renderForm(rec) {
    var tm = T();
    var f = pub.form;
    var ext = String((rec.sourceFile && rec.sourceFile.ext) || '').toLowerCase();
    var badExt = MODEL_EXTS.indexOf(ext) === -1;
    var cats = [['', tx('mr.choose_category')]].concat(((tm && tm.CATEGORIES) || []).map(function (c) { return [c.value, c.label]; }));
    var lics = [['', tx('mr.choose_licence')]].concat(((tm && tm.LICENCES) || []).map(function (l) { return [l, l]; }));
    var opt = function (list, cur) {
      return list.map(function (o) { return '<option value="' + esc(o[0]) + '"' + (String(cur) === String(o[0]) ? ' selected' : '') + '>' + esc(o[1]) + '</option>'; }).join('');
    };
    var picLabel = hasPhoto(rec) ? tx('mr.include_photo') : tx('mr.include_thumb');
    var LBL = 'display:block;font-size:12px;font-weight:600;margin:12px 0 4px;';
    body.innerHTML =
      '<form class="mr-form" novalidate style="max-width:640px;">' +
        '<p style="margin:0 0 6px;font-size:13px;color:' + MUTED + ';">' + esc(tx('mr.publish_lead', { name: rec.name || rec.originalName || '' })) + '</p>' +
        (rec.makerrun ? '<div style="margin:8px 0;padding:8px 10px;border-radius:10px;border:1px solid ' + WARN + ';font-size:13px;">' +
            esc(rec.makerrun.creator ? tx('mr.publish_downloaded_by', { name: rec.makerrun.creator }) : tx('mr.publish_downloaded')) + '</div>' : '') +
        (badExt ? '<div role="alert" style="margin:8px 0;padding:8px 10px;border-radius:10px;border:1px solid ' + BAD + ';font-size:13px;">' + esc(tx('mr.publish_bad_ext', { ext: ext || '?' })) + '</div>' : '') +
        (pub.error ? errorHtml(pub.error, 'publish') : '') +
        '<label for="mrTitleIn" style="' + LBL + '">' + esc(tx('mr.f_title')) + '</label>' +
        '<input id="mrTitleIn" class="mr-f" data-field="title" maxlength="120" value="' + esc(f.title) + '"' + invalidAttr('title') + ' style="width:100%;' + INPUT + '">' + fieldErr('title') +
        '<label for="mrDescIn" style="' + LBL + '">' + esc(tx('mr.f_description')) + '</label>' +
        '<textarea id="mrDescIn" class="mr-f" data-field="description" rows="4" maxlength="20000"' + invalidAttr('description') + ' style="width:100%;' + INPUT + '">' + esc(f.description) + '</textarea>' + fieldErr('description') +
        '<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;">' +
          '<div><label for="mrCatIn" style="' + LBL + '">' + esc(tx('mr.f_category')) + '</label>' +
            '<select id="mrCatIn" class="mr-f" data-field="category"' + invalidAttr('category') + ' style="width:100%;' + INPUT + '">' + opt(cats, f.category) + '</select>' + fieldErr('category') + '</div>' +
          '<div><label for="mrMatIn" style="' + LBL + '">' + esc(tx('mr.f_material')) + '</label>' +
            '<select id="mrMatIn" class="mr-f" data-field="material"' + invalidAttr('material') + ' style="width:100%;' + INPUT + '">' +
              opt([['', tx('mr.material_unset')], ['rigid', tx('mr.mat_rigid')], ['flexible', tx('mr.mat_flexible')], ['multi', tx('mr.mat_multi')]], f.material) + '</select>' + fieldErr('material') + '</div>' +
        '</div>' +
        '<label for="mrLicIn" style="' + LBL + '">' + esc(tx('mr.f_licence')) + '</label>' +
        (pub.licenceUnmapped ? '<div style="font-size:12px;color:' + WARN + ';margin-bottom:4px;">' + esc(tx('mr.licence_unmapped', { licence: rec.licence })) + '</div>' : '') +
        '<select id="mrLicIn" class="mr-f" data-field="license"' + invalidAttr('license') + ' style="width:100%;' + INPUT + '">' + opt(lics, f.license) + '</select>' + fieldErr('license') +
        '<label style="display:flex;align-items:center;gap:8px;margin-top:12px;font-size:13px;"><input type="checkbox" class="mr-f" data-field="nsfw"' + (f.nsfw ? ' checked' : '') + ' style="width:auto;margin:0;">' + esc(tx('mr.f_nsfw')) + '</label>' +
        ((hasPhoto(rec) || hasThumb(rec))
          ? '<label style="display:flex;align-items:center;gap:8px;margin-top:8px;font-size:13px;"><input type="checkbox" class="mr-f" data-field="includePic"' + (f.includePic ? ' checked' : '') + ' style="width:auto;margin:0;">' + esc(picLabel) + '</label>' +
            (hasPhoto(rec) && f.includePic ? '<label style="display:flex;align-items:center;gap:8px;margin:6px 0 0 24px;font-size:13px;"><input type="checkbox" class="mr-f" data-field="printClaim"' + (f.printClaim ? ' checked' : '') + ' style="width:auto;margin:0;">' + esc(tx('mr.f_print_claim')) + '</label>' : '')
          : '<p style="font-size:12px;color:' + MUTED + ';margin-top:8px;">' + esc(tx('mr.no_picture')) + '</p>') +
        '<p style="font-size:12px;color:' + MUTED + ';margin:14px 0 10px;">' + esc(tx('mr.publish_free_note')) + '</p>' +
        '<div style="display:flex;gap:8px;flex-wrap:wrap;">' + btn(tx('mr.publish_next'), 'review', { kind: 'primary', disabled: badExt }) + btn(tx('mr.cancel'), 'close') + '</div>' +
      '</form>';
    focusFirst(Object.keys(pub.errors)[0] ? '[aria-invalid="true"]' : '#mrTitleIn');
  }

  /** Client-side checks mirroring lib/makerrun-publish.js — the server and main check again. */
  function validateForm() {
    var f = pub.form, e = {};
    var tm = T();
    var title = String(f.title || '').trim();
    if (!title) e.title = tx('mr.e_title');
    else if (title.length > 120) e.title = tx('mr.e_title_long');
    if (String(f.description || '').length > 20000) e.description = tx('mr.e_description');
    if (!f.category) e.category = tx('mr.e_category');
    if (!f.license || (tm && tm.LICENCES.indexOf(f.license) === -1)) e.license = tx('mr.e_licence');
    pub.errors = e;
    return !Object.keys(e).length;
  }

  function renderConfirm(rec) {
    var f = pub.form;
    body.innerHTML =
      '<div role="alertdialog" aria-labelledby="mrConfirmHead" aria-describedby="mrConfirmBody" style="max-width:600px;">' +
        '<h3 id="mrConfirmHead" style="margin:0 0 8px;font-size:16px;">' + esc(tx('mr.confirm_title')) + '</h3>' +
        '<p id="mrConfirmBody" style="margin:0 0 10px;font-size:14px;line-height:1.5;">' + esc(tx('mr.confirm_body')) + '</p>' +
        '<ul style="font-size:13px;margin:0 0 14px;padding-inline-start:18px;line-height:1.6;">' +
          '<li>' + esc(tx('mr.confirm_item_title', { title: String(f.title).trim() })) + '</li>' +
          '<li>' + esc(tx('mr.confirm_item_licence', { licence: f.license })) + '</li>' +
          '<li>' + esc(tx('mr.confirm_item_file', { name: (rec.sourceFile && rec.sourceFile.filename) || '' })) + '</li>' +
          (f.includePic ? '<li>' + esc(hasPhoto(rec) ? tx('mr.include_photo') : tx('mr.include_thumb')) + '</li>' : '') +
        '</ul>' +
        '<div style="display:flex;gap:8px;flex-wrap:wrap;">' + btn(tx('mr.confirm_go'), 'go', { kind: 'primary' }) + btn(tx('mr.back'), 'edit') + '</div>' +
      '</div>';
    focusFirst('.mr-btn[data-mr="go"]');
  }

  var STEP_KEYS = { create: 'mr.step_create', file: 'mr.step_file', images: 'mr.step_images' };

  function renderSteps(rec) {
    var steps = pub.steps || [];
    var L = rec.makerrunListing || {};
    var icon = function (s) { return s === 'done' ? '✓' : s === 'running' ? '…' : s === 'failed' ? '✗' : '○'; };
    var colour = function (s) { return s === 'done' ? OK : s === 'failed' ? BAD : s === 'running' ? 'inherit' : MUTED; };
    var list = '<ol style="list-style:none;padding:0;margin:0 0 12px;">' + steps.map(function (s) {
      return '<li style="display:flex;gap:8px;align-items:center;padding:4px 0;color:' + colour(s.state) + ';"><span aria-hidden="true" style="width:16px;text-align:center;">' + icon(s.state) + '</span>' +
        esc(tx(STEP_KEYS[s.id])) + (s.state === 'running' ? ' <span class="mr-sr" style="position:absolute;left:-9999px;">' + esc(tx('mr.in_progress')) + '</span>' : '') + '</li>';
    }).join('') + '</ol>';
    var tail = '';
    if (!pub.running) {
      if (pub.error) {
        tail = errorHtml(pub.error, 'publish') + '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px;">' +
          (L.slug ? btn(tx('mr.finish_upload'), 'resume', { kind: 'primary' }) + btn(tx('mr.delete_half'), 'delete', { kind: 'danger' })
                  : btn(tx('mr.retry'), 'go', { kind: 'primary' }) + btn(tx('mr.back'), 'edit')) + '</div>';
      } else {
        tail = listingSummary(L) + '<div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;">' + btn(tx('mr.check_status'), 'status') + btn(tx('mr.open_page'), 'page-own') + btn(tx('mr.done'), 'close', { kind: 'primary' }) + '</div>';
      }
    }
    body.innerHTML = '<div role="status" aria-live="polite" style="max-width:600px;">' +
      '<h3 style="margin:0 0 10px;font-size:16px;">' + esc(tx('mr.publishing', { title: rec.name || '' })) + '</h3>' + list + '</div>' + tail +
      (pub.note ? '<div class="mr-note" style="font-size:13px;margin-top:10px;">' + pub.note + '</div>' : '');
  }

  function statusLabel(s) {
    return s === 'pending' ? tx('mr.status_pending')
      : s === 'published' ? tx('mr.status_published')
      : s === 'rejected' ? tx('mr.status_rejected')
      : s === 'draft' ? tx('mr.status_draft')
      : (s || tx('mr.status_unknown'));
  }

  function listingSummary(L) {
    var v = L.verification;
    var vline = '';
    if (v && v.verified === true) vline = '<div style="color:' + OK + ';">' + esc(tx('mr.verified_for', { printer: [v.brand, v.printer].filter(Boolean).join(' ') || '—' })) + '</div>';
    else if (v && v.verified === false) vline = '<div style="color:' + WARN + ';">' + esc(tx('mr.not_verified', { reason: v.reason || tx('mr.reason_unknown') })) + '</div>';
    else if (v && v.badge === true) vline = '<div style="color:' + OK + ';">✓ ' + esc(tx('mr.v_badge')) + '</div>';
    return '<div style="padding:10px 12px;border-radius:10px;border:1px solid ' + BORDER + ';font-size:13px;line-height:1.55;">' +
      '<div><b>' + esc(statusLabel(L.status)) + '</b></div>' +
      (L.status === 'pending' ? '<div style="color:' + MUTED + ';">' + esc(tx('mr.review_note')) + '</div>' : '') +
      vline +
      (L.publishedAt ? '<div style="color:' + MUTED + ';font-size:12px;">' + esc(tx('mr.created_on', { date: new Date(L.publishedAt).toLocaleString() })) + '</div>' : '') +
      '</div>';
  }

  function renderListing(rec) {
    var L = rec.makerrunListing || {};
    var incomplete = L.step && L.step !== 'done';
    body.innerHTML =
      '<div style="max-width:600px;">' +
        '<h3 style="margin:0 0 10px;font-size:16px;">' + esc(tx('mr.listing_title', { title: rec.name || '' })) + '</h3>' +
        listingSummary(L) +
        (incomplete ? '<div role="alert" style="margin-top:10px;padding:8px 10px;border-radius:10px;border:1px solid ' + WARN + ';font-size:13px;">' + esc(tx('mr.incomplete')) + '</div>' : '') +
        (pub.error ? errorHtml(pub.error, 'publish') : '') +
        '<div style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap;">' +
          btn(tx('mr.check_status'), 'status') +
          (incomplete ? btn(tx('mr.finish_upload'), 'resume', { kind: 'primary' }) + btn(tx('mr.delete_half'), 'delete', { kind: 'danger' }) : '') +
          btn(tx('mr.open_page'), 'page-own') +
          btn(tx('mr.close'), 'close') +
        '</div>' +
        '<div class="mr-note" role="status" aria-live="polite" style="font-size:13px;margin-top:10px;">' + (pub.note || '') + '</div>' +
      '</div>';
  }

  /**
   * Run the publish steps from wherever this record left off. Each step that
   * succeeds is written to the record before the next starts, so a failure — or
   * the app closing — leaves a record that knows exactly what exists on MakerRun.
   */
  async function runSteps() {
    var rec = recById(pub.recId);
    if (!rec || pub.running) return;
    var f = pub.form;
    var L = rec.makerrunListing || null;
    var wantPic = !!f.includePic || !!(L && L.wantPic);
    pub.steps = [{ id: 'create', state: 'pending' }, { id: 'file', state: 'pending' }].concat(wantPic ? [{ id: 'images', state: 'pending' }] : []);
    var at = !L ? 0 : L.step === 'created' ? 1 : L.step === 'file' ? 2 : 3;
    for (var i = 0; i < at && i < pub.steps.length; i++) pub.steps[i].state = 'done';
    pub.stage = 'running';
    pub.running = true;
    pub.error = null;
    pub.note = '';
    renderSteps(rec);

    var step = function (id, state) { pub.steps.forEach(function (s) { if (s.id === id) s.state = state; }); renderSteps(rec); };
    var fail = function (id, r) {
      step(id, 'failed');
      pub.running = false;
      pub.error = r || {};
      if (id === 'create' && r && r.code === 'invalid' && Array.isArray(r.details) && r.details.length) {
        // Field errors belong on the form, next to the fields — not in a step list.
        pub.errors = {};
        r.details.forEach(function (d) { if (d && d.field) pub.errors[d.field === 'license' ? 'license' : d.field] = d.message; });
        pub.stage = 'form';
        renderPublish();
        return;
      }
      renderSteps(rec);
    };

    try {
      if (!L) {
        step('create', 'running');
        var c = await api.makerrunPublishCreate({
          title: String(f.title).trim(), description: String(f.description || '').trim(),
          category: f.category, material: f.material || null, license: f.license, nsfw: !!f.nsfw,
        });
        if (!c || !c.ok) { fail('create', c); return; }
        L = rec.makerrunListing = { slug: c.slug, status: c.status || 'pending', step: 'created', publishedAt: Date.now(), verification: null, wantPic: wantPic, kind: f.printClaim ? 'print' : 'gallery', usePhoto: hasPhoto(rec) };
        rec.updatedAt = Date.now();
        save();
        step('create', 'done');
      }
      if (L.step === 'created') {
        step('file', 'running');
        var up = await api.makerrunPublishFile(L.slug, rec.id, rec.sourceFile && rec.sourceFile.filename);
        if (!up || !up.ok) { fail('file', up); return; }
        L.verification = up.verification || null;
        L.status = up.status || L.status;
        L.step = 'file';
        rec.updatedAt = Date.now();
        save();
        step('file', 'done');
      }
      if (L.step === 'file') {
        if (L.wantPic) {
          step('images', 'running');
          var payload = { slug: L.slug, vaultId: rec.id, kind: L.kind === 'print' ? 'print' : 'gallery' };
          if (L.usePhoto && hasPhoto(rec)) payload.dataUrl = rec.userPhoto;
          else if (typeof rec.thumb === 'string' && /^data:image\//.test(rec.thumb)) payload.dataUrl = rec.thumb;
          else payload.useThumb = true;
          var im = await api.makerrunPublishImages(payload);
          if (!im || !im.ok) { fail('images', im); return; }
          if (im.failures && im.failures.length) pub.note = esc(tx('mr.image_failures', { reasons: im.failures.join(' ') }));
          step('images', 'done');
        }
        L.step = 'done';
        rec.updatedAt = Date.now();
        save();
      }
      pub.running = false;
      renderSteps(rec);
      repaintLibrary();
    } catch (e) {
      pub.running = false;
      pub.error = { error: String(e && e.message || e) };
      renderSteps(rec);
    }
  }

  async function checkStatus() {
    var rec = recById(pub.recId);
    if (!rec || !rec.makerrunListing) return;
    pub.note = esc(tx('mr.checking'));
    if (pub.stage === 'status') renderListing(rec); else renderSteps(rec);
    var r;
    try { r = await api.makerrunStatus(rec.makerrunListing.slug); } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
    if (!r || !r.ok) { pub.note = ''; pub.error = r || {}; }
    else if (!r.found) { pub.error = null; pub.note = esc(tx('mr.status_gone')); }
    else {
      pub.error = null;
      rec.makerrunListing.status = r.status;
      if (r.verification) rec.makerrunListing.verification = Object.assign({}, rec.makerrunListing.verification || {}, r.verification);
      rec.updatedAt = Date.now();
      save();
      pub.note = '<span style="color:' + OK + ';">' + esc(tx('mr.status_now', { status: statusLabel(r.status) })) + '</span>';
    }
    pub.stage = 'status';
    renderListing(rec);
  }

  function askDelete() {
    var rec = recById(pub.recId);
    if (!rec || !rec.makerrunListing) return;
    body.innerHTML =
      '<div role="alertdialog" aria-labelledby="mrDelHead" aria-describedby="mrDelBody" style="max-width:560px;">' +
        '<h3 id="mrDelHead" style="margin:0 0 8px;font-size:16px;">' + esc(tx('mr.delete_title')) + '</h3>' +
        '<p id="mrDelBody" style="margin:0 0 14px;font-size:14px;line-height:1.5;">' + esc(tx('mr.delete_body')) + '</p>' +
        '<div style="display:flex;gap:8px;">' + btn(tx('mr.delete_go'), 'delete-go', { kind: 'danger' }) + btn(tx('mr.cancel'), 'delete-cancel') + '</div>' +
      '</div>';
    focusFirst('.mr-btn[data-mr="delete-cancel"]');
  }

  async function doDelete() {
    var rec = recById(pub.recId);
    if (!rec || !rec.makerrunListing) return;
    var r;
    try { r = await api.makerrunDelete(rec.makerrunListing.slug); } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
    if (!r || !r.ok) {
      // Already gone on the website is the outcome the user asked for.
      if (r && r.code === 'not_found') r = { ok: true };
      else { pub.error = r || {}; pub.stage = 'status'; renderListing(rec); return; }
    }
    delete rec.makerrunListing;
    rec.updatedAt = Date.now();
    save();
    repaintLibrary();
    pub.error = null;
    pub.stage = 'form';
    pub.steps = null;
    pub.note = '';
    renderPublish();
  }

  /* ---- events ---------------------------------------------------------- */

  function onInput(e) {
    var el = e.target;
    if (el.classList.contains('mr-q')) {
      view.q = el.value;
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(refilter, 350);
      return;
    }
    if (el.classList.contains('mr-f') && pub) readField(el);
  }
  function readField(el) {
    var k = el.getAttribute('data-field');
    if (!k) return;
    pub.form[k] = el.type === 'checkbox' ? !!el.checked : el.value;
    if (pub.errors[k]) { delete pub.errors[k]; el.removeAttribute('aria-invalid'); }
  }
  function onChange(e) {
    var el = e.target;
    if (el.classList.contains('mr-cat')) { view.category = el.value; refilter(); return; }
    if (el.classList.contains('mr-mat')) { view.material = el.value; refilter(); return; }
    if (el.classList.contains('mr-sale')) { view.sale = el.value; refilter(); return; }
    if (el.classList.contains('mr-ver')) { view.verified = !!el.checked; refilter(); return; }
    if (el.classList.contains('mr-f') && pub) {
      readField(el);
      // The print-photo claim only exists while a photo is being included.
      if (el.getAttribute('data-field') === 'includePic') renderPublish();
    }
  }

  function onClick(e) {
    var el = e.target.closest('[data-mr]');
    if (!el || el.disabled) return;
    var act = el.getAttribute('data-mr');
    var arg = el.getAttribute('data-arg');
    switch (act) {
      case 'close': if (!(pub && pub.running)) close(); break;
      case 'retry': if (mode === 'browse') load(); else runSteps(); break;
      case 'prev': view.offset = Math.max(0, view.offset - PAGE); detail = null; load(); break;
      case 'next': view.offset += PAGE; detail = null; load(); break;
      case 'detail': { var d = results.designs[Number(arg)]; if (d) openDetail(d); break; }
      case 'back': detail = null; paintDrawer(); break;
      case 'download': download(Number(arg)); break;
      case 'page': if (detail) api.makerrunOpenPage(detail.slug); break;
      case 'files': close(); if (typeof switchTab === 'function') switchTab('printfiles-tab'); break;
      case 'connect': connect(); break;
      case 'recheck': renderPublish(); break;
      case 'age': api.makerrunOpenAge(); break;
      case 'review':
        if (!pub) break;
        if (!validateForm()) { renderForm(recById(pub.recId)); break; }
        pub.error = null; pub.stage = 'confirm'; renderPublish(); break;
      case 'edit': if (pub) { pub.stage = 'form'; renderPublish(); } break;
      case 'go': runSteps(); break;
      case 'resume': runSteps(); break;
      case 'status': checkStatus(); break;
      case 'page-own': { var r = pub && recById(pub.recId); if (r && r.makerrunListing) api.makerrunOpenPage(r.makerrunListing.slug); break; }
      case 'delete': askDelete(); break;
      case 'delete-go': doDelete(); break;
      case 'delete-cancel': if (pub) { pub.stage = 'status'; renderPublish(); } break;
    }
  }

  window.BedReadyMakerRun = { open: open, publish: publish };
})();
