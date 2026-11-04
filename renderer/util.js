/**
 * DOM, storage, date, HTML escape, CSV parse, and small string helpers.
 */
(function (global) {
  function loadJSON(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      if (raw == null) return fallback;
      const v = safeJsonParse(raw);
      return v ?? fallback;
    } catch {
      return fallback;
    }
  }

  function saveJSON(key, val) {
    localStorage.setItem(key, JSON.stringify(val));
  }

  function $(sel, root = document) {
    return root.querySelector(sel);
  }

  function $$(sel, root = document) {
    return Array.from(root.querySelectorAll(sel));
  }

  function localDateStr(d = new Date()) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  function localMonthStr(d = new Date()) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  }

  /** Allow only safe image URLs in img src (blocks javascript: and markup injection). */
  function safeImageSrc(url) {
    const s = String(url || '').trim();
    /* THE WHOLE STRING, NOT ITS FIRST TWENTY CHARACTERS.
     *
     * This was a PREFIX test — `/^data:image\/…;base64,/` — and then returned
     * the value verbatim, unlike the two branches below it which escape. So a
     * string that merely STARTED like a data URL was written straight into
     * `src="…"`:
     *
     *   data:image/png;base64,iVBORw0KGgo="/data-act="pf-del"/data-id="X
     *
     * renders as `<img src="…" data-act="pf-del" data-id="X" alt="">`, and the
     * print-file grid delegates on `closest('[data-act]')` — so an ordinary
     * click on the biggest target on the card runs a real action.
     *
     * It is reachable: lib/thumbnail-extract.js pulls a preview out of a
     * downloaded .gcode and strips only `;` and whitespace, `resizeDataUrl`
     * resolves the ORIGINAL string when the payload will not decode, and the
     * strict main-process writer rejecting it drives the fallback that stores it
     * in the record. From there it is redrawn on every visit and synced to the
     * shop's other machines.
     *
     * Anchored at both ends against the base64 alphabet, so a well-formed data
     * URL has nothing left to escape and anything else is simply not one. */
    if (/^data:image\/(png|jpeg|jpg|gif|webp);base64,[A-Za-z0-9+/]*={0,2}$/i.test(s)) return s;
    if (/^https?:\/\//i.test(s)) return escapeHtml(s);
    if (/^file:\/\//i.test(s)) return escapeHtml(s);
    return '';
  }

  /** Allow only http(s) links in href attributes. */
  function safeHttpUrl(url) {
    const s = String(url || '').trim();
    if (/^https?:\/\//i.test(s)) return escapeHtml(s);
    return '';
  }

  /** Parse JSON without prototype-pollution keys (matches lib/safe-json.js). */
  function safeJsonParse(text) {
    return JSON.parse(text, (key, value) => {
      if (key === '__proto__' || key === 'constructor') return undefined;
      return value;
    });
  }

  /** Full LAN URL for live order tracking (includes token). */
  function buildLanOrderTrackingUrl(lanBaseUrl, order) {
    if (!lanBaseUrl || !order?.id) return '';
    const base = String(lanBaseUrl).replace(/\/$/, '');
    const token = ensureTrackingToken(order);
    return `${base}/order/${encodeURIComponent(order.id)}?token=${encodeURIComponent(token)}`;
  }

  /** Full LAN URL for quote approval page (includes token when available). */
  function buildLanQuoteApprovalUrl(lanBaseUrl, order) {
    if (!lanBaseUrl || !order?.id) return '';
    const base = String(lanBaseUrl).replace(/\/$/, '');
    const token = ensureQuoteApprovalToken(order);
    return `${base}/order/${encodeURIComponent(order.id)}/quote?token=${encodeURIComponent(token)}`;
  }

  /** Per-order LAN live tracking secret; persists when newly generated. */
  function ensureTrackingToken(order) {
    if (!order) return '';
    if (!order.trackingToken) {
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      order.trackingToken = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      if (typeof saveAll === 'function') saveAll();
    }
    return order.trackingToken;
  }

  /** Per-order LAN quote approval secret; persists when newly generated. */
  function ensureQuoteApprovalToken(order) {
    if (!order) return '';
    if (!order.quoteApprovalToken) {
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      order.quoteApprovalToken = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      if (typeof saveAll === 'function') saveAll();
    }
    return order.quoteApprovalToken;
  }

  function timingSafeEqualHex(a, b) {
    const sa = String(a || '');
    const sb = String(b || '');
    if (sa.length !== sb.length) return false;
    let diff = 0;
    for (let i = 0; i < sa.length; i++) diff |= sa.charCodeAt(i) ^ sb.charCodeAt(i);
    return diff === 0;
  }

  function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;',
    })[c]);
  }

  function uid(prefix = 'ID') {
    return prefix + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5).toUpperCase();
  }

  /**
   * The reference a PERSON reads for a job: its `jobNumber`, else its id.
   *
   * Since ids became unique across computers (lib/order-new.js `mintOrderId`)
   * a new job's id is `INV-2026-0042-k7qx` — the number and a random tag that
   * exists only so two computers can never key two jobs alike. Every list,
   * card, label, page, message and toast shows this; the id stays the key for
   * lookups, `data-` attributes, links and file paths the app reads back.
   * Older jobs have no `jobNumber`, and their id is their number.
   *
   * Takes the order, or an order's id (looked up in the book), for rows a
   * report hands over with only the id. The Mac's rule is `Order.reference`.
   * test/job-reference-display.test.js keeps new screens from showing the id.
   */
  function jobRef(orderOrId) {
    let o = orderOrId;
    if (typeof o === 'string') {
      const book = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
      o = book.find((x) => x && x.id === orderOrId) || { id: orderOrId };
    }
    if (!o || typeof o !== 'object') return '';
    return String((typeof o.jobNumber === 'string' && o.jobNumber) || o.id || '');
  }

  function safeCssColor(val, fallback = '#5E2E14') {
    return /^#[0-9a-fA-F]{3,8}$/.test(String(val || '')) ? String(val) : fallback;
  }

  function initials(name) {
    const n = String(name || '').trim();
    if (!n) return '?';
    const parts = n.split(/\s+/).slice(0, 2);
    return parts.map((p) => p[0]).join('').toUpperCase();
  }

  function parseCsvString(csv) {
    const lines = csv.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim().split('\n');
    if (!lines.length) return { headers: [], rows: [] };

    function parseLine(line) {
      const cols = [];
      let cur = '';
      let inQ = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === '"') {
          if (inQ && line[i + 1] === '"') {
            cur += '"';
            i++;
          } else inQ = !inQ;
        } else if (c === ',' && !inQ) {
          cols.push(cur.trim());
          cur = '';
        } else {
          cur += c;
        }
      }
      cols.push(cur.trim());
      return cols;
    }

    const headers = parseLine(lines[0]);
    const rows = lines.slice(1).filter((l) => l.trim()).map(parseLine);
    return { headers, rows };
  }

  /**
   * Put `text` on the clipboard, and say whether it actually landed there.
   *
   * The main process is tried first: clipboard.writeText() over IPC needs no
   * document focus, no transient user activation and no Chromium permission,
   * so it works from a menu handler or an await-resumed callback where
   * navigator.clipboard does not. navigator.clipboard is the fallback for
   * non-Electron contexts (the LAN pages, tests).
   *
   * Returns false rather than throwing — but callers must check it. Every copy
   * button in the app used to swallow the rejection and print "✓ copied"
   * regardless, so an app-wide clipboard outage looked like success for months.
   */
  async function copyText(text) {
    const s = String(text ?? '');
    if (!s) return false;
    try {
      if (global.hubAPI?.clipboardWrite) {
        const r = await global.hubAPI.clipboardWrite(s);
        if (r?.ok !== false) return true;
      }
    } catch { /* fall through to the web API */ }
    try {
      if (global.navigator?.clipboard?.writeText) {
        await global.navigator.clipboard.writeText(s);
        return true;
      }
    } catch { /* reported below */ }
    return false;
  }

  /** copyText + the toast almost every caller wants. Returns whether it copied. */
  async function copyAndToast(text, copiedMsg) {
    const tr = (k, fallback) => (typeof global.t === 'function' && global.t(k)) || fallback;
    const ok = await copyText(text);
    global.toast?.(
      ok ? (copiedMsg || tr('common.copied', 'Copied!')) : tr('common.copy_failed', 'Copy failed'),
      ok ? 'success' : 'warning',
    );
    return ok;
  }

  const api = {
    $,
    $$,
    copyText,
    copyAndToast,
    loadJSON,
    saveJSON,
    localDateStr,
    localMonthStr,
    escapeHtml,
    timingSafeEqualHex,
    safeJsonParse,
    ensureQuoteApprovalToken,
    ensureTrackingToken,
    buildLanOrderTrackingUrl,
    buildLanQuoteApprovalUrl,
    safeImageSrc,
    safeHttpUrl,
    uid,
    jobRef,
    safeCssColor,
    initials,
    parseCsvString,
  };

  Object.assign(global, api);
  global.KhaytUtil = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
