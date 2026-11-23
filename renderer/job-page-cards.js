/**
 * The job page's lower cards (S1, old-editor retirement step 4; Figma 103:1531,
 * rules 103:1785): Photos, Files, Comments, Customer updates and Connected
 * apps, each moved out of the old job editor, which ran the same calls.
 *
 * None of this is money. Each action is the one the editor ran, with one
 * difference: the page acts AT ONCE, so the editor's Cancel is no longer an
 * undo. Remove therefore moves a photo, an attached file or a job-folder copy
 * to the system Trash (hub:trash-job-file), says so, and only when that fails
 * (a network drive) asks again before deleting it for good (Dev Hub, Nov 18).
 *
 * "Copy a file in" is the editor's Vault section: it copies the model into
 * this job's own folder (copyFileToVault). It is not Khayt Vault.
 *
 * job-page.js asks for `html(o)` when it draws the page and calls `after(el, o)`
 * once the page is in the DOM; the clicks are delegated here, scoped to
 * #jobPage, so a redraw (every saveAll) leaves no listeners behind.
 */
(function (global) {
  'use strict';

  const hub = () => global.hubAPI || {};
  // printLog and products are top-level `let`s (app-state.js), not window properties.
  const byId = (id) => (typeof printLog !== 'undefined' ? printLog.find((o) => o && o.id === id) : null) || null;
  const sizeText = (n) => (n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : n > 1024 ? (n / 1024).toFixed(0) + ' KB' : (n || 0) + ' B');
  const card = (cls, head, body) => `<section class="card jp-card ${cls}"><h3 class="jp-card-head">${head}</h3>${body}</section>`;

  /** The job's product, when it was made from one still in the catalogue (the editor's rule). */
  function productOf(o) {
    if (!o.productId) return null;
    const list = typeof products !== 'undefined' && Array.isArray(products) ? products : [];
    return list.find((p) => p && p.id === o.productId) || null;
  }

  function photosHtml(o) {
    const photos = Array.isArray(o.printPhotos) ? o.printPhotos : [];
    const product = productOf(o);
    const cells = photos.map((ph, i) => `<div class="jp-photo">
        <img src="${safeImageSrc(ph.thumb)}" alt="">
        <button type="button" class="jp-photo-rm" data-jpc="rm-photo" data-i="${i}" aria-label="${escapeHtml(t('jpc.remove_photo'))}" title="${escapeHtml(t('jpc.remove_photo'))}">×</button>
        ${product && ph.thumb ? `<button type="button" class="jp-photo-star" data-jpc="photo-product" data-i="${i}" aria-label="${escapeHtml(t('oe.use_as_product_photo'))}" title="${escapeHtml(t('oe.use_as_product_photo'))}">★</button>` : ''}
      </div>`).join('');
    return card('jp-photos', `${escapeHtml(t('oe.photos'))} · ${photos.length}`,
      `${photos.length ? `<div class="jp-photo-strip">${cells}</div>` : `<p class="jp-empty">${escapeHtml(t('jpc.no_photos'))}</p>`}
      <div class="jp-actions"><button type="button" class="btn" data-jpc="add-photo">${escapeHtml(t('oe.add_photo'))}</button>
      <input type="file" accept="image/*" data-jpc="photo-input" hidden></div>`);
  }

  /* ── A U1's time-lapse, kept as the customer's proof only on request
   * (Figma 134:359, U1-3; lib/main/timelapse-keep.js). Five states: found on
   * the printer, copying, kept, too large to keep, couldn't copy. ── */
  const lapseState = new Map();   // job id → { copying: {got,total} } | { failed: reason, bytes?, maxBytes? }
  const MB = (n) => (Number(n) > 0 ? (Number(n) / 1048576).toFixed(Number(n) >= 10 * 1048576 ? 0 : 1) : '0');
  function machineName(id) {
    const list = typeof machines !== 'undefined' && Array.isArray(machines) ? machines : [];
    const m = list.find((x) => x && String(x.id) === String(id));
    return m ? (m.name || '') : '';
  }
  function lapseHtml(o) {
    const rec = o.printerTimelapse;
    if (!rec || !rec.video) return '';
    const files = Array.isArray(o.attachedFiles) ? o.attachedFiles : [];
    const kept = files.findIndex((f) => f && f.kind === 'timelapse' && f.from && f.from.video === rec.video);
    const name = `<bdi>${escapeHtml(machineName(rec.machineId))}</bdi>`;
    const when = rec.at ? new Date(rec.at) : null;
    const whenText = when && Number.isFinite(when.getTime()) ? when.toLocaleString(localeTag(), { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '';
    const st = lapseState.get(o.id) || {};
    const box = (eyebrow, title, sub, acts, extra) => `<div class="jp-lapse"><div class="jp-lapse-eyebrow">${escapeHtml(eyebrow)}</div>
      <div class="jp-lapse-row"><div class="jp-lapse-text"><div class="jp-row-name">${title}</div>${sub ? `<div class="jp-hint">${sub}</div>` : ''}${extra || ''}</div>
      <div class="jp-row-acts">${acts}</div></div></div>`;
    if (kept !== -1) {
      const f = files[kept];
      return box(t('tl.kept_eyebrow'), escapeHtml(t('tl.kept_title', { size: MB(f.size) })), `${escapeHtml(t('tl.from'))} ${name}${whenText ? ' · ' + escapeHtml(whenText) : ''}`,
        `<button type="button" class="linkish" data-jpc="open-file" data-i="${kept}">${escapeHtml(t('tl.show'))}</button>
         <button type="button" class="linkish" data-jpc="rm-file" data-i="${kept}">${escapeHtml(t('tl.remove'))}</button>`);
    }
    if (st.copying) {
      const total = st.copying.total || Number(rec.bytes) || 0;
      const pct = total ? Math.min(100, Math.round((st.copying.got / total) * 100)) : 0;
      return box(t('tl.copying_eyebrow'), `${escapeHtml(t('tl.copying_title'))} ${name}`,
        escapeHtml(t('tl.copying_of', { got: MB(st.copying.got), total: MB(total) })),
        `<button type="button" class="linkish" data-jpc="lapse-cancel">${escapeHtml(t('common.cancel'))}</button>`,
        `<div class="jp-lapse-bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}"><i style="width:${pct}%"></i></div>`);
    }
    const max = (st.failed === 'over-budget' && st.maxBytes) || 150 * 1048576;
    const bytes = st.bytes || Number(rec.bytes) || 0;
    if (st.failed === 'over-budget' || (bytes && bytes > max)) {
      return box(t('tl.large_eyebrow'), escapeHtml(t('tl.large_title', { size: MB(bytes) })), escapeHtml(t('tl.large_sub', { max: MB(max) })),
        `<button type="button" class="btn small" data-jpc="lapse-open">${escapeHtml(t('tl.open_on_printer'))}</button>`);
    }
    const stem = String(rec.video).replace(/\.mp4$/i, '');
    const sub = [`<bdi>${escapeHtml(stem)}</bdi>`, bytes ? `<bdi>${escapeHtml(t('tl.mb', { n: MB(bytes) }))}</bdi>` : '', whenText ? `<bdi>${escapeHtml(t('tl.finished', { when: whenText }))}</bdi>` : ''].filter(Boolean).join(' · ');
    if (st.failed === 'unreachable' || st.failed === 'cancelled') {
      return box(t('tl.offline_eyebrow'), `${escapeHtml(t('tl.found_title'))} ${name}`, escapeHtml(t(st.failed === 'cancelled' ? 'tl.cancelled_sub' : 'tl.offline_sub')),
        `<button type="button" class="btn small" data-jpc="lapse-keep">${escapeHtml(t('tl.try_again'))}</button>`);
    }
    return box(t('tl.found_eyebrow'), `${escapeHtml(t('tl.found_title'))} ${name}`, sub,
      `<button type="button" class="btn small" data-jpc="lapse-keep">${escapeHtml(t('tl.keep'))}</button>`,
      `<div class="jp-hint">${escapeHtml(t('tl.found_note'))}</div>`);
  }

  function filesHtml(o) {
    const files = Array.isArray(o.attachedFiles) ? o.attachedFiles : [];
    const rows = files.map((f, i) => (f && f.kind === 'timelapse' && o.printerTimelapse && f.from && f.from.video === o.printerTimelapse.video) ? '' : `<div class="jp-row jp-file">
        <div><div class="jp-row-name">${escapeHtml(f.originalName || f.filename)}</div><div class="jp-hint">${escapeHtml(t('jpc.attached', { size: sizeText(+f.size || 0) }))}</div></div>
        <div class="jp-row-acts"><button type="button" class="linkish" data-jpc="open-file" data-i="${i}">${escapeHtml(t('oe.open_file'))}</button>
        <button type="button" class="linkish" data-jpc="rm-file" data-i="${i}">${escapeHtml(t('jpc.remove'))}</button></div></div>`).join('');
    const h = hub();
    return card('jp-files', escapeHtml(t('oe.files')),
      `${lapseHtml(o)}${rows}<div data-jpc="copies"></div>
      ${!files.length ? `<p class="jp-empty" data-jpc="files-empty">${escapeHtml(t('jpc.no_files'))}</p>` : ''}
      <div class="jp-actions">
        ${h.pickAndSaveOrderFile ? `<button type="button" class="btn" data-jpc="attach">${escapeHtml(t('oe.attach_file'))}</button>` : ''}
        ${h.pickFile && h.copyFileToVault ? `<button type="button" class="btn" data-jpc="copy-in">${escapeHtml(t('jpc.copy_in'))}</button>` : ''}
      </div>`);
  }

  /** The job-folder copies, read from disk after the page is drawn. */
  async function drawCopies(el, o) {
    const box = el.querySelector('[data-jpc="copies"]');
    const h = hub();
    if (!box || !h.listVaultFiles) return;
    let files = [];
    try { files = (await h.listVaultFiles(o.id)) || []; } catch (e) { console.error('job copies', e); }
    if (!box.isConnected) return;
    box.innerHTML = files.map((f) => `<div class="jp-row jp-file">
        <div><div class="jp-row-name">${escapeHtml(f.filename)}</div><div class="jp-hint">${escapeHtml(t('jpc.copied_in', { size: sizeText(+f.size || 0) }))}</div></div>
        <div class="jp-row-acts"><button type="button" class="linkish" data-jpc="open-copy" data-path="${escapeHtml(f.fullPath)}">${escapeHtml(t('oe.open_file'))}</button>
        <button type="button" class="linkish" data-jpc="rm-copy" data-path="${escapeHtml(f.fullPath)}" data-name="${escapeHtml(f.filename)}">${escapeHtml(t('jpc.remove'))}</button></div></div>`).join('');
    const empty = el.querySelector('[data-jpc="files-empty"]');
    if (empty && files.length) empty.hidden = true;
  }

  function html(o) {
    if (!o) return '';
    const updates = typeof global.customerUpdatesHtml === 'function' ? global.customerUpdatesHtml(o) : '';
    // A connected app's fields and buttons: NOTHING while connectors are off
    // (pluginEditorHtml answers ''), so no empty card either.
    const apps = typeof global.pluginEditorHtml === 'function' ? global.pluginEditorHtml('order', o) : '';
    return `<div class="jp-cards" data-jpc-job="${escapeHtml(o.id)}">
      <div class="jp-grid">${photosHtml(o)}${filesHtml(o)}</div>
      <div class="jp-grid">
        ${card('jp-comments', escapeHtml(t('jpc.comments')), '<div data-jpc="comments"></div>')}
        ${updates ? card('jp-updates', escapeHtml(t('jpc.updates')), updates) : ''}
      </div>
      ${apps ? card('jp-apps', escapeHtml(t('jpc.apps')), apps) : ''}
    </div>`;
  }

  function after(el, o) {
    if (!el || !o) return;
    const comments = el.querySelector('[data-jpc="comments"]');
    if (comments && typeof global.renderOrderComments === 'function') global.renderOrderComments(o.id, comments);
    drawCopies(el, o);
    const apps = el.querySelector('.jp-apps');
    if (apps && typeof global.wirePluginEditor === 'function') {
      global.wirePluginEditor(apps, 'order', () => ({
        order: o,
        customer: typeof global.customerOfOrder === 'function' ? global.customerOfOrder(o) : null,
        write: (rec) => { if (rec.plugins) o.plugins = rec.plugins; else delete o.plugins; global.saveAll(); },
      }));
    }
  }

  /**
   * Remove a file the job holds: to the Trash, and only if the Trash refuses
   * it, ask again and delete for good. Resolves true once it is gone.
   */
  async function removeFile(kind, name, label, deleteForGood) {
    if (!(await confirmModal(t('jpc.trash_q', { name: label }), { okText: t('jpc.trash_ok'), danger: true }))) return false;
    const h = hub();
    const r = h.trashJobFile ? await h.trashJobFile(kind, name) : { ok: false, error: 'unavailable' };
    if (r && r.ok) { toast(t('jpc.trashed', { name: label }), 'success', 5000); return true; }
    if (!(await confirmModal(t('jpc.trash_failed_q', { name: label }), { okText: t('jpc.delete_ok'), danger: true }))) return false;
    try {
      const gone = await deleteForGood();
      if (gone === false) { toast(t('ord.vault_delete_failed'), 'error', 6000); return false; }
      return true;
    } catch (e) {
      toast(t('common.error') + ': ' + (e && e.message ? e.message : 'delete failed'), 'error');
      return false;
    }
  }

  function redrawLapse(id) {
    const o = byId(id);
    const box = document.querySelector(`#jobPage .jp-cards[data-jpc-job="${CSS.escape(String(id))}"] .jp-lapse`);
    if (!o || !box) return;
    const html = lapseHtml(o);
    const tmp = document.createElement('div');
    tmp.innerHTML = html;
    if (tmp.firstElementChild) box.replaceWith(tmp.firstElementChild);
  }
  async function keepLapse(o) {
    const h = hub();
    if (!h.timelapseKeep || (lapseState.get(o.id) || {}).copying) return;
    lapseState.set(o.id, { copying: { got: 0, total: Number(o.printerTimelapse && o.printerTimelapse.bytes) || 0 } });
    redrawLapse(o.id);
    let r;
    try { r = await h.timelapseKeep(o.id); } catch (_) { r = { ok: false, reason: 'unreachable' }; }
    const now = byId(o.id);
    // Copied, but the job is gone meanwhile: the file would belong to nothing.
    if (r && r.ok && r.row && !now) { if (h.deleteOrderFile) h.deleteOrderFile(r.row.filename); lapseState.delete(o.id); return; }
    // Already copying (a reload lost this window's state): say so, not "found".
    if (r && r.reason === 'busy') { lapseState.set(o.id, { copying: { got: 0, total: Number(o.printerTimelapse && o.printerTimelapse.bytes) || 0 } }); redrawLapse(o.id); return; }
    if (r && r.ok && r.row && now) {
      lapseState.delete(o.id);
      if (!Array.isArray(now.attachedFiles)) now.attachedFiles = [];
      if (!now.attachedFiles.some((f) => f && f.kind === 'timelapse' && f.from && r.row.from && f.from.video === r.row.from.video)) now.attachedFiles.push(r.row);
      global.saveAll();
      return;
    }
    if (r && r.error === 'not_permitted') { lapseState.delete(o.id); toast(explainRefusal('not_permitted'), 'error'); redrawLapse(o.id); return; }
    lapseState.set(o.id, { failed: (r && r.reason) || 'unreachable', bytes: r && r.bytes, maxBytes: r && r.maxBytes });
    redrawLapse(o.id);
  }
  if (hub().onTimelapseProgress) {
    hub().onTimelapseProgress((d) => {
      if (!d || !lapseState.has(d.id) || !(lapseState.get(d.id) || {}).copying) return;
      lapseState.set(d.id, { copying: { got: Number(d.got) || 0, total: Number(d.total) || 0 } });
      redrawLapse(d.id);
    });
  }

  async function onClick(b, o, el) {
    const act = b.dataset.jpc;
    const h = hub();
    const i = +b.dataset.i;
    if (act === 'add-photo') { el.querySelector('[data-jpc="photo-input"]')?.click(); return; }
    if (act === 'photo-product') {
      const ph = (o.printPhotos || [])[i];
      if (ph && o.productId && typeof global.usePrintPhotoAsProductPhoto === 'function') global.usePrintPhotoAsProductPhoto(o.productId, ph);
      return;
    }
    if (act === 'rm-photo') {
      const ph = (o.printPhotos || [])[i];
      if (!ph) return;
      const ok = !ph.filename || await removeFile('photo', ph.filename, t('jpc.this_photo'), () => h.deleteOrderPhoto(ph.filename));
      if (!ok) return;
      const at = (o.printPhotos || []).indexOf(ph);
      if (at !== -1) o.printPhotos.splice(at, 1);
      global.saveAll();
      return;
    }
    if (act === 'open-file') { const f = (o.attachedFiles || [])[i]; if (f && h.openOrderFile) h.openOrderFile(f.filename); return; }
    if (act === 'rm-file') {
      const f = (o.attachedFiles || [])[i];
      if (!f) return;
      if (!(await removeFile('file', f.filename, f.originalName || f.filename, () => h.deleteOrderFile(f.filename)))) return;
      const at = (o.attachedFiles || []).indexOf(f);
      if (at !== -1) o.attachedFiles.splice(at, 1);
      global.saveAll();
      return;
    }
    if (act === 'attach') {
      try {
        const res = await h.pickAndSaveOrderFile(o.id);
        if (res) { if (!Array.isArray(o.attachedFiles)) o.attachedFiles = []; o.attachedFiles.push(res); global.saveAll(); }
      } catch (e) {
        console.error('attach file error', e);
        toast(t('oe.attach_failed'), 'error');
      }
      return;
    }
    if (act === 'lapse-keep') { keepLapse(o); return; }
    if (act === 'lapse-cancel') { if (h.timelapseCancel) h.timelapseCancel(o.id); return; }
    if (act === 'lapse-open') { if (h.timelapseOpen) h.timelapseOpen(o.id); return; }
    if (act === 'open-copy') { if (h.openFile) h.openFile(b.dataset.path); return; }
    if (act === 'rm-copy') {
      if (await removeFile('vault', b.dataset.path, b.dataset.name, () => h.deleteVaultFile(b.dataset.path))) drawCopies(el, o);
      return;
    }
    if (act === 'copy-in') {
      try {
        const src = await h.pickFile({ filters: [{ name: '3D Files', extensions: ['stl', '3mf', 'obj', 'step', 'stp', 'gcode', 'zip'] }] });
        if (!src) return;
        // copyFileToVault RETURNS { ok:false, error } for a source outside the allowed places.
        const res = await h.copyFileToVault(src, o.id);
        if (!res || res.ok === false) { toast('⚠ ' + (res && res.error ? res.error : t('ord.vault_add_failed')), 'error', 6000); return; }
        drawCopies(el, o);
      } catch (e) {
        console.error('copy in error', e);
        toast('⚠ ' + t('ord.vault_add_failed'), 'error', 6000);
      }
    }
  }

  /** A photo added here: resized as the editor did, saved to disk at once, then recorded. */
  async function addPhoto(file, o) {
    if (!file) return;
    if (file.size > 8 * 1024 * 1024) { toast(t('pe.image_too_big'), 'error'); return; }
    try {
      const thumb = await global.resizeImage(file, 240, 0.85);
      const full = await global.resizeImage(file, 1600, 0.88);
      const photos = Array.isArray(o.printPhotos) ? o.printPhotos : (o.printPhotos = []);
      let filename = null;
      try {
        filename = await hub().saveOrderPhoto(o.id, photos.length + '-' + Date.now().toString(36), full);
      } catch (e) {
        console.error('save order photo failed', e);
        toast(t('pe.save_failed'), 'error');
      }
      // `source`: 'shop' is a photo added at the desk (lib/lan-server.js names the others).
      photos.push({ thumb, filename, source: 'shop' });
      global.saveAll();
    } catch (err) {
      console.error(err);
      toast(t('pe.upload_failed'), 'error');
    }
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('click', (e) => {
      const b = e.target.closest && e.target.closest('#jobPage [data-jpc]');
      if (!b || b.tagName === 'INPUT') return;
      const el = b.closest('.jp-cards');
      const o = el && byId(el.dataset.jpcJob);
      if (o) onClick(b, o, el);
    });
    document.addEventListener('change', (e) => {
      const inp = e.target.closest && e.target.closest('#jobPage [data-jpc="photo-input"]');
      if (!inp) return;
      const el = inp.closest('.jp-cards');
      const o = el && byId(el.dataset.jpcJob);
      const file = inp.files && inp.files[0];
      inp.value = '';
      if (o) addPhoto(file, o);
    });
  }

  global.KhaytJobPageCards = { html, after };
})(typeof window !== 'undefined' ? window : globalThis);
