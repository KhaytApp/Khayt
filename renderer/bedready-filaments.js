/* ============================================================
   BED READY — Orca filament installer (renderer).
   A self-contained modal that browses the OrcaSlicer filament library (served by
   bedready.io) and installs a profile straight into the user's Snapmaker Orca so it
   shows up for the Snapmaker U1. Uses the main-process bridge on window.hubAPI:
     orcaFilaSlicers / orcaFilaManifest / orcaFilaInstall / orcaFilaReveal
   Bed Ready flavor only; no dependency on the app's nav/tab system.
   ============================================================ */
(function () {
  if (typeof document === 'undefined' || document.documentElement.dataset.app !== 'bedready') return;
  var api = (typeof window !== 'undefined' && window.hubAPI) || null;
  if (!api || typeof api.orcaFilaManifest !== 'function') return; // older preload — silently unavailable

  var root = null, body = null, lastFocus = null;
  var manifest = null, slicers = [], sel = { slicerId: null, printerLabel: null };
  var installed = {}; // installed this session: id → true
  var installedSet = new Set(); // preset basenames already on disk for the selected slicer (reported by main)

  // Mirror of lib/orca-filament-install.js safeFileBase — lets us match a manifest profile to the file
  // the installer would write, so a profile already on disk shows "Installed ✓" across sessions.
  function safeName(name) {
    return String(name || 'filament').replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').replace(/^[.\s]+|[.\s]+$/g, '').slice(0, 120) || 'filament';
  }
  function isDone(p) { return !!installed[p.id] || installedSet.has(safeName(p.name)); }
  async function refreshInstalled() {
    installedSet = new Set();
    if (typeof api.orcaFilaInstalled !== 'function') return; // older preload
    try { var r = await api.orcaFilaInstalled(sel.slicerId); if (r && r.ok && Array.isArray(r.names)) installedSet = new Set(r.names); }
    catch (e) { /* leave empty — worst case a row shows Install when it's already there */ }
  }

  function curSlicer() { return slicers.find(function (s) { return s.id === sel.slicerId; }) || slicers[0] || null; }
  function hasPrinter() { var s = curSlicer(); return !!(s && s.printers && s.printers.length); }
  var CAP = 60; // max rows rendered at once — filters/search narrow the 1200+ library

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function build() {
    root = document.createElement('div');
    root.className = 'brf-overlay';
    root.style.cssText = 'position:fixed;inset:0;z-index:9999;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.55);padding:24px;';
    root.innerHTML =
      '<div class="brf-modal" role="dialog" aria-modal="true" aria-label="Add filament to your slicer" style="width:100%;max-width:640px;max-height:86vh;display:flex;flex-direction:column;border-radius:18px;background:var(--surface,#ffffff);color:var(--text,#14201e);border:1px solid var(--border,rgba(17,40,37,0.10));box-shadow:0 20px 60px rgba(0,0,0,.5);">' +
        '<div style="display:flex;align-items:center;justify-content:space-between;gap:12px;padding:18px 20px;border-bottom:1px solid var(--border,rgba(17,40,37,0.10));flex:0 0 auto;">' +
          '<b style="font-size:16px;">🎨 Add filament to your slicer</b>' +
          '<button type="button" class="brf-close" aria-label="Close" style="border:0;background:transparent;color:inherit;font-size:20px;cursor:pointer;line-height:1;" title="Close">✕</button>' +
        '</div>' +
        '<div class="brf-body" style="padding:18px 20px;overflow:auto;"></div>' +
      '</div>';
    document.body.appendChild(root);
    body = root.querySelector('.brf-body');
    root.addEventListener('click', function (e) { if (e.target === root) close(); });
    root.querySelector('.brf-close').addEventListener('click', close);
    document.addEventListener('keydown', function (e) {
      if (!isOpen()) return;
      if (e.key === 'Escape') { close(); return; }
      if (e.key === 'Tab') trapTab(e);
    });
  }

  function focusables() {
    if (!root) return [];
    return Array.prototype.slice
      .call(root.querySelectorAll('button, input, select, [href], [tabindex]:not([tabindex="-1"])'))
      .filter(function (el) { return el.offsetParent !== null && !el.disabled; });
  }
  function trapTab(e) {
    var f = focusables();
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    // Focus can end up OUTSIDE the modal without ever passing through first/last: disabling
    // the focused element (Install becoming "Installing…") or re-rendering the list under it
    // drops focus to <body>. The wrap-around checks below both miss that, so Tab escaped into
    // the page behind — the one thing the trap exists to prevent. Pull it back first.
    if (!root.contains(document.activeElement)) { e.preventDefault(); first.focus(); return; }
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }

  var isOpen = function () { return root && root.style.display !== 'none'; };
  // Make the app behind the modal inert (non-focusable / hidden from AT), so a screen-reader virtual
  // cursor can't wander the page underneath. Complements the Tab focus-trap.
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

  // Solid brand teal (matches .btn.primary) — the old purple→cyan→lime gradient was off-identity and
  // white-on-lime failed WCAG AA. --accent resolves in both light/dark themes.
  var CTA = 'background:var(--accent,#199e8f);color:#fff;border:0;';
  var PLAIN = 'background:var(--surface-2,#f2f6f5);color:var(--text,#14201e);border:1px solid var(--border,rgba(17,40,37,0.16));';

  function loadingView() {
    body.innerHTML = '<p style="color:var(--text-muted,#869390);">Loading the OrcaSlicer filament library…</p>';
  }
  function errorView(msg) {
    body.innerHTML = '<p style="margin:0 0 14px;">' + esc(msg) + '</p>' +
      '<button type="button" class="brf-retry" style="cursor:pointer;border-radius:12px;padding:10px 16px;font-weight:600;' + CTA + '">Try again</button>';
    body.querySelector('.brf-retry').addEventListener('click', load);
  }

  // Header: pick the target slicer + printer, reveal the folder, and the "quit first" nudge.
  function headerHtml() {
    var s = curSlicer();
    var slicerOpts = slicers.map(function (x) { return '<option value="' + esc(x.id) + '"' + (x.id === sel.slicerId ? ' selected' : '') + '>' + esc(x.label) + '</option>'; }).join('');
    var printers = (s && s.printers) || [];
    var printerOpts = printers.map(function (p) { return '<option value="' + esc(p.label) + '"' + (p.label === sel.printerLabel ? ' selected' : '') + '>' + esc(p.label) + '</option>'; }).join('');
    var selCss = 'style="' + PLAIN + 'border-radius:10px;padding:8px 10px;font-size:13px;flex:1 1 46%;min-width:0;"';
    // A detected slicer with no printers can't receive an install — show an inline note instead of a
    // blank dropdown (which would otherwise send an undefined printer to the installer).
    var printerControl = printers.length
      ? '<select class="brf-printer" aria-label="Printer" ' + selCss + '>' + printerOpts + '</select>'
      : '<span class="brf-noprinter" style="flex:1 1 46%;min-width:0;font-size:12px;color:var(--danger,#e0492f);font-weight:600;">No printers in ' + esc((s && s.label) || 'this slicer') + ' — add one there first.</span>';
    return '<div style="background:var(--surface-2,#f2f6f5);border:1px solid var(--border,rgba(17,40,37,0.12));border-radius:12px;padding:12px;margin-bottom:14px;">' +
      '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">' +
        '<select class="brf-slicer" aria-label="Slicer" ' + selCss + '>' + slicerOpts + '</select>' +
        printerControl +
        '<button type="button" class="brf-reveal" style="cursor:pointer;border-radius:9px;padding:7px 11px;font-size:12px;font-weight:600;' + PLAIN + '">Reveal folder</button>' +
      '</div>' +
      '<div style="margin-top:9px;font-size:12px;color:var(--text,#14201e);">⚠️ Quit ' + esc((s && s.label) || 'your slicer') + ' before installing — it reads filament profiles at startup. Relaunch it after.</div>' +
    '</div>';
  }

  function filtersHtml() {
    var opts = function (arr) { return ['<option value="">All</option>'].concat((arr || []).map(function (v) { return '<option value="' + esc(v) + '">' + esc(v) + '</option>'; })).join(''); };
    var sel = 'style="' + PLAIN + 'border-radius:10px;padding:8px 10px;font-size:13px;max-width:38%;"';
    return '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:10px;">' +
      '<input class="brf-q" type="text" placeholder="Search filament (e.g. SUNLU PLA)" aria-label="Search filament" style="' + PLAIN + 'border-radius:10px;padding:8px 12px;font-size:13px;flex:1 1 180px;">' +
      '<select class="brf-vendor" aria-label="Brand" ' + sel + '>' + opts(manifest.vendors) + '</select>' +
      '<select class="brf-type" aria-label="Material" ' + sel + '>' + opts(manifest.types) + '</select>' +
    '</div>';
  }

  function match(p, q, vendor, type) {
    if (vendor && p.vendor !== vendor) return false;
    if (type && p.type !== type) return false;
    if (q && (p.name + ' ' + p.vendor).toLowerCase().indexOf(q) === -1) return false;
    return true;
  }

  function rowHtml(p) {
    var done = isDone(p);
    var canInstall = hasPrinter();
    var btn = done
      ? '<span class="brf-done" style="font-size:12px;color:var(--ok,#159d68);font-weight:600;white-space:nowrap;">Installed ✓</span>'
      : canInstall
        ? '<button type="button" class="brf-install" data-id="' + esc(p.id) + '" style="cursor:pointer;border-radius:10px;padding:8px 14px;font-weight:600;font-size:13px;white-space:nowrap;' + CTA + '">Install</button>'
        : '<button type="button" class="brf-install" disabled title="Add a printer to this slicer first" style="border-radius:10px;padding:8px 14px;font-weight:600;font-size:13px;white-space:nowrap;opacity:.45;cursor:not-allowed;' + CTA + '">Install</button>';
    return '<div class="brf-row" data-id="' + esc(p.id) + '" style="display:flex;align-items:center;gap:10px;padding:9px 10px;border:1px solid var(--border,rgba(17,40,37,0.10));border-radius:10px;">' +
      '<div style="min-width:0;flex:1 1 auto;">' +
        '<div title="' + esc(p.name) + '" style="font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + esc(p.name) + '</div>' +
        '<div style="font-size:11px;color:var(--text-muted,#869390);">' + esc(p.vendor) + ' · ' + esc(p.type) + ' · 🌡️ ' + esc(p.nozzleTemp) + '°/' + esc(p.bedTemp) + '°</div>' +
      '</div>' + btn +
    '</div>';
  }

  // The count is announced on a delay, and deliberately NOT from the visible element.
  // renderList() runs on every keystroke, so a live region holding the count re-announced
  // on each one: typing "PLA" read out three different totals over the top of itself, and
  // the search field is where a screen-reader user spends the most time in this modal.
  // The visible number still updates instantly — only the announcement waits for a pause.
  var announceTimer = null;
  var lastAnnounced = '';
  function announceCount(text) {
    if (announceTimer) clearTimeout(announceTimer);
    announceTimer = setTimeout(function () {
      var el = body && body.querySelector('.brf-count-live');
      // Re-announcing an unchanged total is the same noise in a different costume:
      // narrowing a vendor filter that does not change the result count says nothing new.
      if (!el || text === lastAnnounced) return;
      lastAnnounced = text;
      el.textContent = text;
    }, 600);
  }

  function renderList() {
    var q = (body.querySelector('.brf-q').value || '').trim().toLowerCase();
    var vendor = body.querySelector('.brf-vendor').value;
    var type = body.querySelector('.brf-type').value;
    var all = manifest.profiles.filter(function (p) { return match(p, q, vendor, type); });
    var shown = all.slice(0, CAP);
    var count = all.length ? ('Showing ' + shown.length + ' of ' + all.length + (all.length > CAP ? ' — refine to see more' : '')) : 'No filaments match.';
    var listEl = body.querySelector('.brf-list');
    var countEl = body.querySelector('.brf-count');
    countEl.textContent = count;
    announceCount(count);
    listEl.innerHTML = shown.map(rowHtml).join('');
  }

  // (Re)render the slicer/printer header and bind its controls. Split out so switching to a slicer
  // with no printers can swap the printer <select> for the inline note and refresh the install state.
  function renderHeader() {
    var h = body.querySelector('.brf-header');
    if (!h) return;
    h.innerHTML = headerHtml();
    h.querySelector('.brf-reveal').addEventListener('click', async function () {
      try {
        var r = await api.orcaFilaReveal(sel.slicerId);
        if (!r || !r.ok) result(esc((r && r.error) || 'Couldn’t open the folder.'), 'var(--danger,#e0492f)');
      } catch (e) { result('Couldn’t open the folder.', 'var(--danger,#e0492f)'); }
    });
    h.querySelector('.brf-slicer').addEventListener('change', async function (e) {
      sel.slicerId = e.target.value;
      var s = curSlicer();
      sel.printerLabel = (s && s.defaultPrinter) || null;
      renderHeader();          // swap the printer control for the newly selected slicer
      renderList();            // reflect whether the new slicer can install
      await refreshInstalled(); // re-read what's already installed for this slicer
      renderList();
    });
    var ps = h.querySelector('.brf-printer');
    if (ps) ps.addEventListener('change', function (e) { sel.printerLabel = e.target.value; });
  }

  function mainView() {
    body.innerHTML = '<div class="brf-header"></div>' + filtersHtml() +
      // Visible count carries no live semantics; .brf-count-live is the (debounced) announcement.
      '<div class="brf-count" style="font-size:12px;color:var(--text-muted,#869390);margin-bottom:8px;"></div>' +
      '<div class="brf-count-live" role="status" aria-live="polite" style="position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0;"></div>' +
      '<div class="brf-list" style="display:grid;gap:7px;"></div>' +
      '<div class="brf-result" role="status" aria-live="polite" style="margin-top:12px;font-size:13px;min-height:18px;"></div>';
    renderHeader();
    body.querySelector('.brf-q').addEventListener('input', renderList);
    body.querySelector('.brf-vendor').addEventListener('change', renderList);
    body.querySelector('.brf-type').addEventListener('change', renderList);
    body.querySelector('.brf-list').addEventListener('click', function (e) {
      var b = e.target.closest ? e.target.closest('.brf-install') : null;
      if (b) install(b.getAttribute('data-id'), b);
    });
    renderList();
  }

  function result(html, color) {
    var el = body && body.querySelector('.brf-result');
    if (el) el.innerHTML = '<span style="color:' + (color || 'var(--text-muted,#869390)') + ';">' + html + '</span>';
  }

  async function install(id, b) {
    var p = manifest.profiles.find(function (x) { return x.id === id; });
    if (!p) return;
    if (!sel.printerLabel) { result('Add a printer to this slicer first, then reopen this.', 'var(--danger,#e0492f)'); return; }
    // Keyboard path: this button IS the focused element when it was activated by Enter/Space.
    // Disabling it next line would drop focus to <body>. On success renderList() replaces the
    // row entirely, so there is nothing to hand focus back to — park it on the search field,
    // which survives every re-render and is where you would carry on from anyway.
    var hadFocus = !!(b && document.activeElement === b);
    if (hadFocus) { var qEl = body.querySelector('.brf-q'); if (qEl) try { qEl.focus(); } catch (_e) { /* noop */ } }
    if (b) { b.disabled = true; b.textContent = 'Installing…'; b.style.opacity = '0.7'; }
    result('Installing “' + esc(p.name) + '”…');
    try {
      var r = await api.orcaFilaInstall({ file: p.file, name: p.name }, sel.slicerId, sel.printerLabel);
      if (!r || !r.ok) throw new Error((r && r.error) || 'Install failed.');
      installed[id] = true;
      renderList(); // re-render so this row now shows "Installed ✓"
      result('Installed “' + esc(p.name) + '” for ' + esc(r.printer || 'your printer') + '. Relaunch ' + esc(r.slicer || 'your slicer') + ' to see it.', 'var(--ok,#159d68)');
    } catch (e) {
      if (b) { b.disabled = false; b.textContent = 'Install'; b.style.opacity = '1'; }
      // The row still exists on failure, so give the button back to the keyboard user who
      // pressed it — retrying is the likely next move and it should not require Tabbing back.
      if (hadFocus && b) try { b.focus(); } catch (_e2) { /* noop */ }
      result(esc(e && e.message ? e.message : 'Install failed.'), 'var(--danger,#e0492f)');
    }
  }

  async function load() {
    loadingView();
    try {
      var sres = await api.orcaFilaSlicers();
      slicers = (sres && sres.ok && Array.isArray(sres.slicers)) ? sres.slicers : [];
      if (!slicers.length) {
        errorView('No supported slicer detected. Install and open OrcaSlicer, Snapmaker Orca, Bambu Studio, or another Orca-family slicer, then reopen this.');
        return;
      }
      // Default to Snapmaker Orca if present (this app’s core printer), else the first detected slicer.
      var def = slicers.find(function (s) { return s.id === 'snapmaker'; }) || slicers[0];
      sel.slicerId = def.id;
      sel.printerLabel = def.defaultPrinter;
      var r = await api.orcaFilaManifest();
      if (!r || !r.ok || !r.manifest) throw new Error((r && r.error) || 'Couldn’t load the filament library.');
      manifest = r.manifest;
      await refreshInstalled();
      mainView();
    } catch (e) { errorView(e && e.message ? e.message : 'Couldn’t load the filament library. Check your connection and try again.'); }
  }

  function open() {
    if (!root) build();
    lastFocus = (typeof document !== 'undefined' && document.activeElement) || null;
    root.style.display = 'flex';
    bgInert(true);
    load();
    var closeBtn = root.querySelector('.brf-close');
    if (closeBtn && closeBtn.focus) { try { closeBtn.focus(); } catch (e) { /* noop */ } }
  }

  window.BedReadyFilaments = { open: open };
})();
