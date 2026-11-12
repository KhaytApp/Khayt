'use strict';
/* ============================================================
   Simple mode — the reduced screens (S4 cards 6, 7 and 8)
   ============================================================
 *
 * Figma 7Iqw0GcrLLRW7CLDEhTa1P, page "S4 · Simple mode (desktop)":
 *   card 6 (80:273) — a customer in Simple (five fields) and the four-column
 *                     board (the board's filing rule is lib/order-status.js
 *                     simpleStageOf; kanban.js draws it)
 *   card 7 (80:346) — Production settings: the checklist and custom fields
 *                     (styles.css + settings.js; no logic of its own here)
 *   card 8 (80:382) — Library storage: this computer, a folder, Google Drive
 *
 * What lives here is what has a rule worth testing: which name field a
 * customer's one "Name" box edits, how the one "Address" box reads and writes
 * the address book, and which storage place is in use. Every write keeps what
 * Simple does not show (S4 rule 3: switching modes never deletes data).
 */
(function () {
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const str = (v) => (typeof v === 'string' ? v : '');

  /* ── Card 6: the customer ─────────────────────────────────────────── */

  /** The one name field Simple shows edits `nameEn` or `nameAr`: the one the
   *  customer already has; with both, the one in the app's language; with
   *  neither, the app's language. The other is never touched. */
  function nameKey(client, lang) {
    const en = str(client && client.nameEn).trim();
    const ar = str(client && client.nameAr).trim();
    const arabic = String(lang || '').toLowerCase().startsWith('ar');
    if (en && ar) return arabic ? 'nameAr' : 'nameEn';
    if (en) return 'nameEn';
    if (ar) return 'nameAr';
    return arabic ? 'nameAr' : 'nameEn';
  }

  /** A row Simple can edit as one line: nothing but id, label and address.
   *  A structured row (#2416, lib/customer-address.js: country, national
   *  address fields, recipient…) is shown, never rewritten from one line. */
  const PLAIN_KEYS = ['id', 'label', 'address'];
  function isPlainAddress(row) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return false;
    return Object.keys(row).every((k) => PLAIN_KEYS.includes(k));
  }

  /** The address the one-line field shows: the first row of the book. */
  function addressOf(client) {
    const book = client && Array.isArray(client.addresses) ? client.addresses : [];
    const row = book[0] || null;
    return { row, text: row ? str(row.address) : '', editable: !row || isPlainAddress(row) };
  }

  /** Write the one-line address back: into the first row when it is plain,
   *  as a new first row when the book is empty. Every other row, and a
   *  structured first row, is left as it was. Returns the book. */
  function applyAddress(client, text, makeId) {
    if (!Array.isArray(client.addresses)) client.addresses = [];
    const book = client.addresses;
    const value = str(text).trim();
    const { row, editable } = addressOf(client);
    if (!editable) return book;
    if (row) row.address = value;
    else if (value) book.unshift({ id: typeof makeId === 'function' ? makeId() : 'ADDR-' + Date.now(), label: '', address: value });
    return book;
  }

  /* ── Card 8: where the library lives ──────────────────────────────── */

  /** Which of the three places is in use, and what Simple does not list.
   *    place  'computer' | 'folder' | 'drive'
   *    bucket true when S3 / R2 (or tiering to it) is switched on — it keeps
   *           working and the card says "Set up in Professional"
   *    vault  true when the Khayt Vault holds the library (Mac-managed) */
  function libraryPlace(printLibrary) {
    const pl = printLibrary && typeof printLibrary === 'object' ? printLibrary : {};
    const gd = pl.gdrive || {};
    const vault = !!(pl.vault && pl.vault.enabled === true);
    const drive = !vault && gd.enabled === true && !!str(gd.refreshToken);
    const place = drive ? 'drive' : (str(pl.root).trim() ? 'folder' : 'computer');
    const bucket = !vault && !!((pl.s3 && pl.s3.enabled) || (pl.tier && pl.tier.enabled && !drive));
    return { place, bucket, vault, root: str(pl.root).trim(), driveSetUp: !!str(gd.clientId).trim() };
  }

  /* ── DOM (the app only) ───────────────────────────────────────────── */

  const tr = (k, v) => (typeof t === 'function' ? t(k, v) : k);
  const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(s) : String(s == null ? '' : s));

  function placeRow(id, title, sub, inUse, button) {
    return `<div class="sm-row" data-place="${id}">
      <div class="sm-row-text"><div class="sm-row-title">${esc(title)}</div><div class="sm-row-sub">${esc(sub)}</div></div>
      ${inUse ? `<span class="sm-pill-in-use">${esc(tr('sm.lib_in_use'))}</span>` : (button || '')}
    </div>`;
  }

  /** Paint S4 card 8 into #plibPlaces. Shown in Simple only (styles.css). */
  function renderLibraryPlaces() {
    const host = typeof document !== 'undefined' ? document.getElementById('plibPlaces') : null;
    if (!host || typeof settings === 'undefined') return;
    const st = libraryPlace(settings.printLibrary);
    const count = (typeof printFiles !== 'undefined' && Array.isArray(printFiles)) ? printFiles.filter(Boolean).length : 0;
    const locked = st.vault || st.place === 'drive';
    const btn = (act, key) => `<button type="button" class="btn small" data-act="${act}">${esc(tr(key))}</button>`;
    const rows = [
      placeRow('computer', tr('sm.lib_computer'), tr('sm.lib_computer_sub', { n: count }),
        !st.vault && st.place === 'computer', locked ? '' : btn('sm-lib-computer', 'set.plib_use_default')),
      placeRow('folder', tr('sm.lib_folder'), st.place === 'folder' ? st.root : tr('sm.lib_folder_sub'),
        !st.vault && st.place === 'folder', locked ? '' : btn('sm-lib-folder', 'set.plib_choose')),
      placeRow('drive', tr('sm.lib_drive'), tr('sm.lib_drive_sub'), false,
        st.vault ? '' : btn('sm-lib-drive', st.place === 'drive' ? 'sm.lib_manage' : 'sm.lib_connect')),
    ];
    if (st.place === 'drive') rows[2] = rows[2].replace('<button', `<span class="sm-pill-in-use">${esc(tr('sm.lib_in_use'))}</span><button`);
    if (st.bucket) rows.push(placeRow('bucket', tr('sm.lib_bucket'), tr('sm.lib_bucket_sub'), false, ''));
    host.innerHTML = `<div class="sm-rows">${rows.join('')}</div>`;
    if (host.dataset.wired) return;
    host.dataset.wired = '1';
    host.addEventListener('click', (e) => {
      const b = e.target.closest('button[data-act]');
      if (!b || !host.contains(b)) return;
      if (b.dataset.act === 'sm-lib-computer' && typeof clearPrintLibFolder === 'function') clearPrintLibFolder('root');
      if (b.dataset.act === 'sm-lib-folder' && typeof pickPrintLibFolder === 'function') pickPrintLibFolder('root');
      if (b.dataset.act === 'sm-lib-drive') openDriveSetup();
    });
  }

  /** "Connect…" with a client id saved goes straight to Google's sign-in;
   *  otherwise (and "Manage…") it opens the Drive block below the list, which
   *  is where the client id is typed and the account disconnected. */
  function openDriveSetup() {
    const block = document.getElementById('plibDriveBlock');
    const st = libraryPlace(settings.printLibrary);
    if (st.place !== 'drive' && st.driveSetUp && typeof connectPrintLibGDrive === 'function') {
      const on = document.getElementById('set_plibGDriveOn');
      if (on && !on.disabled) on.checked = true;
      connectPrintLibGDrive();
      return;
    }
    if (!block) return;
    block.classList.add('sm-open');
    block.scrollIntoView({ block: 'nearest' });
    (document.getElementById('set_plibGDClientId') || block).focus?.();
  }

  const api = { nameKey, isPlainAddress, addressOf, applyAddress, libraryPlace, renderLibraryPlaces, openDriveSetup };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytSimpleForms = api;
})();
