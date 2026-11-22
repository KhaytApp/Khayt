'use strict';
/*
 * Bed Ready — Filament Care log. A local tracker for when each spool was last dried and how it's
 * stored, with a "dry me again" nudge derived from lib/filament-dryness.js. Hygroscopic filament
 * (PETG/Nylon/TPU especially) prints wet after sitting out; makers lose prints to it and have no
 * record of what they dried when. Bed Ready-only; persists in the `filamentDryLog` store collection.
 */
(function () {
  var D = (typeof KhaytFilamentDryness !== 'undefined' && KhaytFilamentDryness) || null;
  var root = null, body = null, lastFocus = null, mode = 'list', editId = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function tt(k, fallback) { return (typeof t === 'function' && t(k)) || fallback; }
  function uidFor() { return (typeof uid === 'function' ? uid('DRY') : 'DRY' + Date.now().toString(36) + Math.round(performance.now())); }
  function nowIso() { return new Date().toISOString(); }
  function safeHex(h) { return /^#[0-9a-fA-F]{6}$/.test(String(h || '')) ? h : '#4b9bd6'; }

  var CTA = 'background:var(--accent,#199e8f);color:#fff;border:0;';
  var PLAIN = 'background:var(--surface-2,#f2f6f5);color:var(--text,#14201e);border:1px solid var(--border,rgba(17,40,37,0.16));';

  function records() {
    if (typeof filamentDryLog === 'undefined' || !Array.isArray(filamentDryLog)) return [];
    return filamentDryLog;
  }
  function persist() { if (typeof saveAll === 'function') saveAll(); }

  var MATERIAL_OPTS = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'Nylon', 'PC', 'PVA', 'Other'];
  var STORAGE = [
    { v: 'drybox', label: 'Drybox / active dryer' },
    { v: 'sealed', label: 'Sealed bag + desiccant' },
    { v: 'open', label: 'Open air / on the shelf' },
  ];

  function build() {
    root = document.createElement('div');
    root.className = 'brdry-overlay';
    root.style.cssText = 'position:fixed;inset:0;z-index:9999;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.55);padding:24px;';
    root.innerHTML =
      '<div class="brdry-modal" role="dialog" aria-modal="true" aria-label="Filament care" style="width:100%;max-width:600px;max-height:86vh;display:flex;flex-direction:column;border-radius:18px;background:var(--surface,#fff);color:var(--text,#14201e);border:1px solid var(--border,rgba(17,40,37,0.10));box-shadow:0 20px 60px rgba(0,0,0,.5);">' +
        '<div style="display:flex;align-items:center;justify-content:space-between;gap:12px;padding:18px 20px;border-bottom:1px solid var(--border,rgba(17,40,37,0.10));flex:0 0 auto;">' +
          '<b style="font-size:16px;">💧 ' + esc(tt('dry.title', 'Filament care')) + '</b>' +
          '<button type="button" class="brdry-close" aria-label="' + esc(tt('common.close', 'Close')) + '" style="border:0;background:transparent;color:inherit;font-size:20px;cursor:pointer;line-height:1;" title="' + esc(tt('common.close', 'Close')) + '">✕</button>' +
        '</div>' +
        '<div class="brdry-body" style="padding:18px 20px;overflow:auto;"></div>' +
      '</div>';
    document.body.appendChild(root);
    body = root.querySelector('.brdry-body');
    root.addEventListener('click', function (e) { if (e.target === root) close(); });
    root.querySelector('.brdry-close').addEventListener('click', close);
    body.addEventListener('click', onBodyClick);
    body.addEventListener('change', onBodyChange);
    document.addEventListener('keydown', function (e) {
      if (!isOpen()) return;
      if (e.key === 'Escape') { if (mode !== 'list') { mode = 'list'; editId = null; render(); } else close(); return; }
      if (e.key === 'Tab') trapTab(e);
    });
  }

  function focusables() {
    if (!root) return [];
    return Array.prototype.slice
      .call(root.querySelectorAll('button, input, select, textarea, [href], [tabindex]:not([tabindex="-1"])'))
      .filter(function (el) { return el.offsetParent !== null && !el.disabled; });
  }
  function trapTab(e) {
    var f = focusables(); if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }
  var isOpen = function () { return root && root.style.display !== 'none'; };
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
    mode = 'list'; editId = null;
    if (lastFocus && lastFocus.focus) { try { lastFocus.focus(); } catch (e) { /* gone */ } }
    lastFocus = null;
  }

  // ---- status rendering ----
  var STATE_STYLE = {
    good:    { bg: 'rgba(34,160,107,.14)', fg: '#1c8f5f', label: 'Dry' },
    due:     { bg: 'rgba(214,158,46,.16)', fg: '#a9761a', label: 'Dry soon' },
    overdue: { bg: 'rgba(212,68,75,.14)',  fg: '#c23b42', label: 'Re-dry' },
    unknown: { bg: 'var(--surface-2,#eef2f1)', fg: 'var(--text-muted,#869390)', label: 'Not logged' },
  };
  function relDays(iso) {
    if (!iso) return '';
    var days = Math.floor((Date.now() - new Date(iso).getTime()) / 86400000);
    if (!isFinite(days)) return '';
    if (days <= 0) return tt('dry.today', 'today');
    if (days === 1) return tt('dry.yesterday', 'yesterday');
    return (tt('dry.days_ago', '{n} days ago')).replace('{n}', days);
  }
  function statusFor(rec) {
    if (!D) return { state: 'unknown', intervalDays: 0 };
    return D.dryStatus(rec, Date.now());
  }
  function pill(rec) {
    var st = statusFor(rec);
    var s = STATE_STYLE[st.state] || STATE_STYLE.unknown;
    var extra = '';
    if (st.state === 'overdue') extra = ' · ' + (tt('dry.overdue_by', '{n}d over')).replace('{n}', Math.max(1, Math.round(st.daysSince - st.intervalDays)));
    else if (st.state === 'due') extra = ' · ' + (tt('dry.due_in', '{n}d left')).replace('{n}', Math.max(0, Math.ceil(st.intervalDays - st.daysSince)));
    return '<span class="brdry-pill" style="background:' + s.bg + ';color:' + s.fg + ';font-size:11px;font-weight:700;padding:2px 9px;border-radius:999px;white-space:nowrap;">' + esc(s.label) + esc(extra) + '</span>';
  }

  // ---- views ----
  function summaryHtml() {
    var recs = records();
    if (!recs.length) return '';
    var counts = { good: 0, due: 0, overdue: 0, unknown: 0 };
    recs.forEach(function (r) { counts[statusFor(r).state]++; });
    var bits = [];
    if (counts.overdue) bits.push('<b style="color:#c23b42;">' + counts.overdue + '</b> ' + esc(tt('dry.need_redry', 'need re-drying')));
    if (counts.due) bits.push('<b style="color:#a9761a;">' + counts.due + '</b> ' + esc(tt('dry.due_soon', 'due soon')));
    if (counts.good) bits.push('<b style="color:#1c8f5f;">' + counts.good + '</b> ' + esc(tt('dry.ready', 'ready')));
    return '<div style="font-size:12.5px;color:var(--text-muted,#869390);margin:0 0 12px;">' + bits.join(' · ') + '</div>';
  }

  function cardHtml(rec) {
    return '<div class="brdry-card" style="display:flex;gap:12px;align-items:flex-start;padding:12px 0;border-top:1px solid var(--border-soft,rgba(17,40,37,0.08));">' +
        '<span style="flex:0 0 auto;width:22px;height:22px;border-radius:6px;margin-top:2px;border:1px solid rgba(0,0,0,.2);background:' + esc(safeHex(rec.hex)) + ';"></span>' +
        '<div style="flex:1 1 auto;min-width:0;">' +
          '<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">' +
            '<b style="font-size:13.5px;">' + esc(rec.label || tt('dry.untitled', 'Untitled spool')) + '</b>' + pill(rec) +
          '</div>' +
          '<div style="font-size:12px;color:var(--text-muted,#869390);margin-top:2px;">' +
            esc(rec.material || '—') +
            (rec.driedAt ? ' · ' + esc(tt('dry.dried', 'dried')) + ' ' + esc(relDays(rec.driedAt)) : ' · ' + esc(tt('dry.never_dried', 'never dried'))) +
            ' · ' + esc(storageLabel(rec.storage)) +
          '</div>' +
          (rec.note ? '<div style="font-size:12px;color:var(--text-muted,#869390);margin-top:3px;">' + esc(rec.note) + '</div>' : '') +
        '</div>' +
        '<div style="flex:0 0 auto;display:flex;gap:6px;">' +
          '<button type="button" class="brdry-act" data-act="dried" data-id="' + esc(rec.id) + '" title="' + esc(tt('dry.mark_dried', 'Log a drying now')) + '" style="cursor:pointer;border-radius:8px;padding:5px 9px;font-size:12px;font-weight:600;' + CTA + '">✓ ' + esc(tt('dry.dried_now', 'Dried')) + '</button>' +
          '<button type="button" class="brdry-act" data-act="edit" data-id="' + esc(rec.id) + '" aria-label="' + esc(tt('common.edit', 'Edit')) + '" style="cursor:pointer;border-radius:8px;padding:5px 8px;font-size:12px;' + PLAIN + '" title="' + esc(tt('common.edit', 'Edit')) + '">✎</button>' +
          '<button type="button" class="brdry-act" data-act="del" data-id="' + esc(rec.id) + '" aria-label="' + esc(tt('common.delete', 'Delete')) + '" style="cursor:pointer;border-radius:8px;padding:5px 8px;font-size:12px;' + PLAIN + '" title="' + esc(tt('common.delete', 'Delete')) + '">🗑</button>' +
        '</div>' +
      '</div>';
  }
  function storageLabel(v) {
    for (var i = 0; i < STORAGE.length; i++) if (STORAGE[i].v === v) return tt('dry.storage_' + v, STORAGE[i].label);
    return tt('dry.storage_open', 'Open air / on the shelf');
  }

  function listView() {
    var recs = records().slice().sort(function (a, b) {
      var rank = { overdue: 0, due: 1, unknown: 2, good: 3 };
      return rank[statusFor(a).state] - rank[statusFor(b).state];
    });
    var list = recs.length
      ? recs.map(cardHtml).join('')
      : '<div style="padding:22px 0;color:var(--text-muted,#869390);font-size:13px;text-align:center;">' + esc(tt('dry.empty', 'No spools tracked yet. Add one to start logging when you dry it.')) + '</div>';
    return '<p style="margin:0 0 12px;font-size:13px;color:var(--text-muted,#869390);">' + esc(tt('dry.intro', 'Track when each spool was last dried and how it’s stored. Bed Ready nudges you before it prints wet.')) + '</p>' +
      summaryHtml() + list +
      '<button type="button" class="brdry-act" data-act="add" style="margin-top:16px;cursor:pointer;border-radius:12px;padding:10px 16px;font-weight:700;width:100%;' + CTA + '">＋ ' + esc(tt('dry.add', 'Track a spool')) + '</button>';
  }

  function formView(rec) {
    rec = rec || {};
    var matOpts = MATERIAL_OPTS.map(function (m) {
      var sel = (rec.material && rec.material.toUpperCase().indexOf(m.toUpperCase()) === 0) ? ' selected' : (!rec.material && m === 'PLA' ? ' selected' : '');
      return '<option value="' + esc(m) + '"' + sel + '>' + esc(m) + '</option>';
    }).join('');
    var storeOpts = STORAGE.map(function (s) {
      return '<option value="' + esc(s.v) + '"' + ((rec.storage || 'open') === s.v ? ' selected' : '') + '>' + esc(tt('dry.storage_' + s.v, s.label)) + '</option>';
    }).join('');
    var inCss = 'style="' + PLAIN + 'border-radius:10px;padding:8px 10px;font-size:13px;width:100%;box-sizing:border-box;"';
    var lblCss = 'style="display:block;font-size:12px;font-weight:600;margin:12px 0 4px;"';
    return '<div class="brdry-form">' +
        '<label ' + lblCss + '>' + esc(tt('dry.f_label', 'Spool label')) + '</label>' +
        '<input id="dryLabel" type="text" ' + inCss + ' placeholder="' + esc(tt('dry.f_label_ph', 'e.g. Bambu PLA Matte Charcoal')) + '" value="' + esc(rec.label || '') + '">' +
        '<div style="display:flex;gap:10px;">' +
          '<div style="flex:1 1 50%;"><label ' + lblCss + '>' + esc(tt('dry.f_material', 'Material')) + '</label><select id="dryMaterial" ' + inCss + '>' + matOpts + '</select></div>' +
          '<div style="flex:0 0 auto;"><label ' + lblCss + '>' + esc(tt('dry.f_colour', 'Colour')) + '</label><input id="dryHex" type="color" value="' + esc(safeHex(rec.hex)) + '" style="width:48px;height:38px;padding:2px;border-radius:10px;border:1px solid var(--border,rgba(17,40,37,0.16));background:var(--surface,#fff);cursor:pointer;"></div>' +
        '</div>' +
        '<label ' + lblCss + '>' + esc(tt('dry.f_storage', 'Stored in')) + '</label><select id="dryStorage" ' + inCss + '>' + storeOpts + '</select>' +
        '<div style="display:flex;gap:10px;">' +
          '<div style="flex:1 1 33%;"><label ' + lblCss + '>' + esc(tt('dry.f_temp', 'Dry temp °C')) + '</label><input id="dryTemp" type="number" min="30" max="120" ' + inCss + ' value="' + esc(rec.tempC != null ? rec.tempC : '') + '"></div>' +
          '<div style="flex:1 1 33%;"><label ' + lblCss + '>' + esc(tt('dry.f_hours', 'Hours')) + '</label><input id="dryHours" type="number" min="1" max="48" ' + inCss + ' value="' + esc(rec.hours != null ? rec.hours : '') + '"></div>' +
          '<div style="flex:1 1 34%;display:flex;align-items:flex-end;"><label style="font-size:12px;display:flex;align-items:center;gap:6px;padding-bottom:9px;"><input id="dryNow" type="checkbox"' + (rec.id ? '' : ' checked') + '> ' + esc(tt('dry.f_dried_now', 'Dried just now')) + '</label></div>' +
        '</div>' +
        '<label ' + lblCss + '>' + esc(tt('dry.f_note', 'Note (optional)')) + '</label>' +
        '<input id="dryNote" type="text" ' + inCss + ' value="' + esc(rec.note || '') + '">' +
        '<div style="display:flex;gap:10px;margin-top:18px;">' +
          '<button type="button" class="brdry-act" data-act="save" style="flex:1 1 auto;cursor:pointer;border-radius:12px;padding:10px 16px;font-weight:700;' + CTA + '">' + esc(rec.id ? tt('common.save', 'Save') : tt('dry.add', 'Track a spool')) + '</button>' +
          '<button type="button" class="brdry-act" data-act="cancel" style="cursor:pointer;border-radius:12px;padding:10px 16px;font-weight:600;' + PLAIN + '">' + esc(tt('common.cancel', 'Cancel')) + '</button>' +
        '</div>' +
      '</div>';
  }

  // afterAction=true means this render followed a user action (dried/delete/save/cancel), so the button
  // they clicked is gone — move focus to a stable control (the Add button) instead of dropping it to
  // <body>, which would break keyboard navigation and leave the focus trap with nothing focused.
  function render(afterAction) {
    if (!body) return;
    if (mode === 'form') {
      var rec = editId ? records().find(function (r) { return r.id === editId; }) : null;
      body.innerHTML = formView(rec);
      prefillRecipe();
      var lbl = body.querySelector('#dryLabel'); if (lbl) lbl.focus();
    } else {
      body.innerHTML = listView();
      if (afterAction) { var add = body.querySelector('[data-act="add"]'); if (add) add.focus(); }
    }
  }

  // Fill the dry temp/hours defaults for the chosen material when the fields are empty.
  function prefillRecipe() {
    if (!D) return;
    var mat = body.querySelector('#dryMaterial');
    var temp = body.querySelector('#dryTemp');
    var hrs = body.querySelector('#dryHours');
    if (!mat || !temp || !hrs) return;
    var spec = D.materialSpec(mat.value);
    if (temp.value === '') temp.value = spec.dryTempC;
    if (hrs.value === '') hrs.value = spec.dryHours;
  }

  function onBodyChange(e) {
    if (mode === 'form' && e.target && e.target.id === 'dryMaterial') {
      // Reset recipe hints to the new material's defaults.
      var spec = D ? D.materialSpec(e.target.value) : null;
      if (spec) {
        var temp = body.querySelector('#dryTemp'); var hrs = body.querySelector('#dryHours');
        if (temp) temp.value = spec.dryTempC;
        if (hrs) hrs.value = spec.dryHours;
      }
    }
  }

  function readForm() {
    var g = function (id) { var el = body.querySelector(id); return el ? el.value : ''; };
    var tempN = parseInt(g('#dryTemp'), 10);
    var hrsN = parseInt(g('#dryHours'), 10);
    return {
      label: g('#dryLabel').trim(),
      material: g('#dryMaterial'),
      hex: safeHex(g('#dryHex')),
      storage: g('#dryStorage'),
      tempC: isFinite(tempN) ? tempN : null,
      hours: isFinite(hrsN) ? hrsN : null,
      note: g('#dryNote').trim(),
      driedNow: !!(body.querySelector('#dryNow') && body.querySelector('#dryNow').checked),
    };
  }

  function markDried(rec, tempC, hours) {
    var at = nowIso();
    rec.driedAt = at;
    if (tempC != null) rec.tempC = tempC;
    if (hours != null) rec.hours = hours;
    if (!Array.isArray(rec.history)) rec.history = [];
    rec.history.push({ at: at, tempC: rec.tempC != null ? rec.tempC : null, hours: rec.hours != null ? rec.hours : null });
    if (rec.history.length > 50) rec.history = rec.history.slice(-50);
    rec.updatedAt = at;
  }

  function onBodyClick(e) {
    var btn = e.target.closest ? e.target.closest('.brdry-act') : null;
    if (!btn) return;
    var act = btn.getAttribute('data-act');
    var id = btn.getAttribute('data-id');
    if (act === 'add') { mode = 'form'; editId = null; render(); return; }
    if (act === 'edit') { mode = 'form'; editId = id; render(); return; }
    if (act === 'cancel') { mode = 'list'; editId = null; render(true); return; }
    if (act === 'dried') {
      var r = records().find(function (x) { return x.id === id; });
      if (r) { markDried(r, r.tempC, r.hours); persist(); render(true); if (typeof toast === 'function') toast(tt('dry.logged', 'Logged a drying — clock reset.'), 'success'); }
      return;
    }
    if (act === 'del') {
      if (typeof confirm === 'function' && !confirm(tt('dry.del_confirm', 'Stop tracking this spool?'))) return;
      var arr = records();
      var i = arr.findIndex(function (x) { return x.id === id; });
      if (i >= 0) { arr.splice(i, 1); persist(); render(true); }
      return;
    }
    if (act === 'save') {
      var f = readForm();
      if (!f.label) { if (typeof toast === 'function') toast(tt('dry.need_label', 'Give the spool a label.'), 'error'); return; }
      if (editId) {
        var ex = records().find(function (x) { return x.id === editId; });
        if (ex) {
          var wasDried = !!ex.driedAt;
          ex.label = f.label; ex.material = f.material; ex.hex = f.hex; ex.storage = f.storage;
          ex.note = f.note; ex.updatedAt = nowIso();
          if (f.driedNow || !wasDried) markDried(ex, f.tempC, f.hours);
          else { if (f.tempC != null) ex.tempC = f.tempC; if (f.hours != null) ex.hours = f.hours; }
        }
      } else {
        var rec = {
          id: uidFor(), label: f.label, material: f.material, hex: f.hex, storage: f.storage,
          tempC: f.tempC, hours: f.hours, note: f.note, driedAt: null, history: [],
          createdAt: nowIso(), updatedAt: nowIso(),
        };
        if (f.driedNow) markDried(rec, f.tempC, f.hours);
        records().push(rec);
      }
      persist();
      mode = 'list'; editId = null; render(true);
      return;
    }
  }

  function open() {
    if (typeof document === 'undefined') return;
    lastFocus = document.activeElement;
    if (!root) build();
    mode = 'list'; editId = null;
    render();
    root.style.display = 'flex';
    bgInert(true);
    var c = root.querySelector('.brdry-close'); if (c) c.focus();
  }

  window.BedReadyDryLog = { open: open };
})();
