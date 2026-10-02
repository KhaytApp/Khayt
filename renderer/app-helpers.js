/**
 * Shared order/client helpers, tags, priorities, date filters, CSV import, locale.
 */
/* Make sure the working week is loaded, WITHOUT declaring a binding for it.
 *
 * lib/working-week.js assigns globalThis.KhaytWorkingWeek itself, so the script
 * tag has already done this in the renderer, and `require` does it under Node,
 * where these files are pulled in directly by tests.
 *
 * The obvious version — a shared `const` at the top of each file — is a trap.
 * Classic scripts share ONE global lexical scope, so the second file to declare
 * the same top-level const throws "already been declared" and kills every script
 * after it. That is what happened: settings.js never reached its export list,
 * and the app died wiring a button whose handler had silently ceased to exist. */
if (typeof KhaytWorkingWeek === 'undefined' && typeof require === 'function') {
  require('../lib/working-week.js');
}
// ── Shared helpers ────────────────────────────────────────────────────────────
/** Localised name — picks AR or EN depending on current language. */

/**
 * The shop's own text in a given language — business name, address, footer…
 *
 * These were read as `settings.bizEn || settings.bizAr` in eighteen files, which
 * is correct for a shop writing English and Arabic and returns an empty string
 * for one writing Turkish. The fallback runs the language asked for, then the
 * shop's chosen content languages, then anything filled in at all: an invoice
 * with a Turkish business name on it beats one with a blank where the name goes.
 */
function shopField(base, lang) {
  if (typeof KhaytContentLanguages === 'undefined') {
    const s = (typeof settings !== 'undefined' && settings) || {};
    return s[base + 'En'] || s[base + 'Ar'] || '';
  }
  return KhaytContentLanguages.read(
    (typeof settings !== 'undefined' ? settings : {}), base,
    lang || (typeof i18n !== 'undefined' ? i18n.current : 'en'),
    (typeof settings !== 'undefined' ? settings : null));
}

/** The shop's name in the current language, or the best one it has. */
function shopName(lang) { return shopField('biz', lang); }

function localName(obj) {
  // Reads through the content-language model so a shop writing Turkish or
  // German sees its own name rather than a blank: the fallback runs the
  // interface language, then the shop's chosen content languages, then anything
  // filled in at all. A Turkish name beats an empty space where a product goes.
  if (typeof KhaytContentLanguages !== 'undefined') {
    return KhaytContentLanguages.read(obj, 'name', i18n.current,
      (typeof settings !== 'undefined' ? settings : null));
  }
  return i18n.current === 'ar' ? (obj.nameAr || obj.nameEn) : (obj.nameEn || obj.nameAr);
}
/**
 * The name in the shop's OTHER content language, for the second line.
 *
 * Empty for a single-language shop, and empty when that language's field has
 * not been filled in — a blank second line is correct there, where repeating
 * the primary name would just look like a bug.
 */
function altLocalName(obj) {
  if (typeof KhaytContentLanguages === 'undefined') {
    // The pre-module fallback, kept in step with localName's: two languages only.
    return (i18n.current === 'ar' ? (obj && obj.nameEn) : (obj && obj.nameAr)) || '';
  }
  return KhaytContentLanguages.readAlt(obj, 'name', i18n.current,
    (typeof settings !== 'undefined' ? settings : null));
}
/** Normalise payment status with fallback, accounting for credit notes.
 *
 *  The rule moved to lib/order-payment.js. It was one of three answers to "is
 *  this paid" and the only complete one; the payment modal had its own, which
 *  is why an order could be WRITTEN as partial and READ as paid a line later.
 *  This name stays because sixty call sites use it. */
function payStatus(order) {
  const rules = (typeof globalThis !== 'undefined' && globalThis.KhaytOrderPayment)
    || (() => { try { return require('../lib/order-payment.js'); } catch (e) { return null; } })();
  // With the shop's settings, so a shop that adds tax on top is paid when the
  // customer has paid the price AND the tax (lib/order-money.js orderGrossRaw).
  return rules ? rules.statusOf(order, { settings: (typeof settings !== 'undefined') ? settings : undefined }) : 'unpaid';
}
/* csvFormulaNeutralize — renderer/format.js */
/** Escape a value for CSV (RFC 4180). */
function csvEsc(v) { return '"' + csvFormulaNeutralize(v).replace(/"/g, '""') + '"'; }
/** Trigger a file download from a Blob. */
function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}
/** Return printLog entries matching the current log filter UI state. */
/* getFilteredLogs, clearLogFilters, renderLogs, batch actions, exportOrdersCsv — renderer/logs.js */

/** Parse a comma-separated tags string into a sorted, deduped array of trimmed tags. */
function parseTags(str) {
  return [...new Set((str || '').split(',').map(t => t.trim()).filter(Boolean))].sort();
}

/** Render tag chips HTML for display in table rows and kanban cards. */
function renderTagChips(tags, clickable = false) {
  if (!tags || tags.length === 0) return '';
  return tags.map(tag => clickable
    ? `<span class="tag-chip" data-act="filter-tag" data-tag="${escapeHtml(tag)}" title="${escapeHtml(t('tag.filter_hint'))}">${escapeHtml(tag)}</span>`
    : `<span class="tag-chip">${escapeHtml(tag)}</span>`
  ).join('');
}

/** Collect all unique tags used across all orders (for filter dropdown). */
function getAllTags() {
  const all = new Set();
  for (const o of printLog) { for (const tag of (o.tags || [])) all.add(tag); }
  return [...all].sort();
}
/* uid — renderer/util.js */

/** Feature 2: Return normalised priority level for an order.
 *  Supports both legacy boolean and new string values. */
function getPriorityLevel(order) {
  const rules = (typeof globalThis !== 'undefined' && globalThis.KhaytOrderEdit)
    || (() => { try { return require('../lib/order-edit.js'); } catch (e) { return null; } })();
  return rules ? rules.priorityOf(order) : 'normal';
}
/** Feature 2: Sort comparator — urgent > high > normal, then by queuePos */
function prioritySortValue(order) {
  const lv = getPriorityLevel(order);
  return lv === 'urgent' ? 0 : lv === 'high' ? 1 : 2;
}
/** Feature 2: HTML badge for priority level (empty string if normal) */
function priorityBadgeHtml(order) {
  const lv = getPriorityLevel(order);
  if (lv === 'urgent') return `<span class="priority-label priority-urgent">${escapeHtml(t('ord.priority_urgent'))}</span>`;
  if (lv === 'high')   return `<span class="priority-label priority-high">${escapeHtml(t('ord.priority_high'))}</span>`;
  return '';
}
/* Invoicing — renderer/invoicing.js */

function formatDueDateBadge(dueDate) {
  if (!dueDate) return '';
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const due   = new Date(dueDate + 'T00:00:00');
  const diff  = Math.round((due - today) / 86400000);
  let cls, label;
  if (diff < 0)       { cls = 'overdue';   label = t('oe.due_overdue', { n: Math.abs(diff) }); }
  else if (diff === 0){ cls = 'due-today'; label = t('oe.due_today'); }
  else if (diff <= 3) { cls = 'due-soon';  label = t('oe.due_soon',  { n: diff }); }
  else                { cls = 'due-ok';    label = t('oe.due_in',    { n: diff }); }
  return `<span class="due-badge ${cls}">${escapeHtml(label)}</span>`;
}
/* escapeHtml, parseCsvString — renderer/util.js */

/**
 * Reusable CSV import modal.
 * @param {object} opts
 * @param {string}   opts.title    — Modal title
 * @param {Array}    opts.fields   — [{ key, label, required?, type? }]
 * @param {Function} opts.onImport — (objects) => { imported, skipped }
 */
function openCsvImportModal({ title, fields, onImport }) {
  let parsedHeaders = [];
  let parsedRows = [];

  function autoMapIdx(fieldKey, fieldLabel, headers) {
    const norm = s => s.toLowerCase().replace(/[\s_-]/g, '');
    const targets = [norm(fieldKey), norm(fieldLabel)];
    const idx = headers.findIndex(h => targets.includes(norm(h)));
    return idx >= 0 ? String(idx) : '';
  }

  function buildMappingHtml(headers, rows) {
    if (!headers.length) return '';
    return `
      <div style="margin-top:12px;">
        <p style="font-size:12px;color:var(--text-muted);margin-bottom:8px;">${rows.length} ${escapeHtml(t('csv.rows_found') || 'rows found')}. ${escapeHtml(t('csv.map_hint') || 'Map CSV columns to fields:')}</p>
        <table style="width:100%;font-size:12px;border-collapse:collapse;">
          <thead>
            <tr style="background:var(--bg-alt);">
              <th style="padding:6px 8px;text-align:left;">${escapeHtml(t('csv.field') || 'Field')}</th>
              <th style="padding:6px 8px;text-align:left;">${escapeHtml(t('csv.column') || 'CSV Column')}</th>
              <th style="padding:6px 8px;text-align:left;color:var(--text-muted);">${escapeHtml(t('csv.preview') || 'Preview')}</th>
            </tr>
          </thead>
          <tbody>
            ${fields.map(f => {
              const autoIdx = autoMapIdx(f.key, f.label, headers);
              const optHtml = `<option value="">(${escapeHtml(t('csv.skip') || 'skip')})</option>` +
                headers.map((h, i) => `<option value="${i}"${String(i) === autoIdx ? ' selected' : ''}>${escapeHtml(h)}</option>`).join('');
              const previewVal = autoIdx !== '' ? (rows[0]?.[+autoIdx] || '—') : '—';
              return `<tr style="border-bottom:1px solid var(--border);">
                <td style="padding:6px 8px;font-weight:${f.required ? '600' : '400'};">${escapeHtml(f.label)}${f.required ? ' <span style="color:var(--danger);">*</span>' : ''}</td>
                <td style="padding:6px 8px;"><select class="csv-map-sel" data-field="${escapeHtml(f.key)}" style="width:100%;font-size:12px;padding:3px;">${optHtml}</select></td>
                <td class="csv-map-preview" data-field="${escapeHtml(f.key)}" style="padding:6px 8px;color:var(--text-muted);font-size:11px;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(String(previewVal))}</td>
              </tr>`;
            }).join('')}
          </tbody>
        </table>
        <p id="csvImportCount" style="margin-top:8px;font-size:12px;color:var(--primary);font-weight:600;"></p>
      </div>`;
  }

  function updatePreviewsAndCount() {
    $$('.csv-map-sel').forEach(sel => {
      const field = sel.dataset.field;
      const idx = sel.value !== '' ? +sel.value : -1;
      const previewEl = $(`.csv-map-preview[data-field="${field}"]`);
      if (previewEl) previewEl.textContent = idx >= 0 ? (parsedRows[0]?.[idx] || '—') : '—';
    });
    const required = fields.filter(f => f.required);
    const mappings = {};
    $$('.csv-map-sel').forEach(sel => { mappings[sel.dataset.field] = sel.value !== '' ? +sel.value : -1; });
    const validCount = parsedRows.filter(row => required.every(f => mappings[f.key] >= 0 && row[mappings[f.key]]?.trim())).length;
    const countEl = $('#csvImportCount');
    if (countEl) countEl.textContent = `${validCount} ${t('csv.rows_to_import') || 'rows will be imported'}`;
  }

  function parseAndRender(text) {
    const { headers, rows } = parseCsvString(text);
    parsedHeaders = headers;
    parsedRows = rows;
    const area = $('#csvMappingArea');
    if (area) {
      area.innerHTML = buildMappingHtml(headers, rows);
      $$('.csv-map-sel').forEach(sel => sel.addEventListener('change', updatePreviewsAndCount));
      updatePreviewsAndCount();
    }
  }

  openFormModal({
    title,
    sizeLg: true,
    bodyHtml: `
      <div>
        <div style="display:flex;gap:8px;align-items:center;margin-bottom:8px;">
          <label class="btn small ghost" style="cursor:pointer;margin:0;">
            ${escapeHtml(t('csv.choose_file') || 'Choose CSV file')}
            <input type="file" id="csvFileInput" accept=".csv,.txt" style="display:none;">
          </label>
          <span style="font-size:12px;color:var(--text-muted);" id="csvFileName">${escapeHtml(t('csv.no_file') || 'No file chosen')}</span>
          <button class="btn small ghost" id="csvPasteToggle" style="margin-inline-start:auto;">${escapeHtml(t('csv.paste') || 'Paste CSV')}</button>
        </div>
        <textarea id="csvPasteArea" rows="4" class="form-control" placeholder="${escapeHtml(t('csv.paste_ph') || 'Paste CSV text here…')}" style="display:none;font-size:11px;font-family:monospace;"></textarea>
        <div id="csvMappingArea"></div>
      </div>`,
    saveLabel: t('csv.import_btn') || 'Import',
    onSave: () => {
      if (!parsedRows.length) { toast(t('csv.no_data') || 'No data to import', 'error'); return false; }
      const mappings = {};
      $$('.csv-map-sel').forEach(sel => { mappings[sel.dataset.field] = sel.value !== '' ? +sel.value : -1; });
      const objects = parsedRows.map(row => {
        const obj = {};
        fields.forEach(f => {
          if (mappings[f.key] >= 0) {
            const raw = row[mappings[f.key]]?.trim() || '';
            obj[f.key] = f.type === 'number' ? (+raw || 0) : raw;
          }
        });
        return obj;
      }).filter(obj => fields.filter(f => f.required).every(f => obj[f.key]));

      if (!objects.length) { toast(t('csv.no_valid_rows') || 'No valid rows found — check required fields', 'error'); return false; }
      const result = onImport(objects);
      toast(`${result.imported} ${t('csv.imported') || 'imported'}${result.skipped ? `, ${result.skipped} ${t('csv.skipped') || 'skipped'}` : ''}`, 'success', 4000);
      return true;
    }
  });

  requestAnimationFrame(() => {
    $('#csvFileInput')?.addEventListener('change', e => {
      const file = e.target.files?.[0];
      if (!file) return;
      const nameEl = $('#csvFileName');
      if (nameEl) nameEl.textContent = file.name;
      const reader = new FileReader();
      reader.onload = ev => parseAndRender(ev.target.result);
      reader.readAsText(file, 'UTF-8');
    });
    $('#csvPasteToggle')?.addEventListener('click', () => {
      const ta = $('#csvPasteArea');
      if (!ta) return;
      ta.style.display = ta.style.display === 'none' ? 'block' : 'none';
    });
    $('#csvPasteArea')?.addEventListener('input', e => {
      if (e.target.value.trim()) parseAndRender(e.target.value);
    });
  });
}

/* safeCssColor, initials — renderer/util.js */
function safeBizLogo() {
  const v = settings.bizLogo;
  return (v && v.startsWith('data:image/')) ? v : '';
}


/* ============================================================
   Date helpers (filtering by month/quarter/year)
   ============================================================ */
// Custom range state — set when any filter select changes to 'custom'
let customRangeFrom = { log: '', analytics: '', expenses: '' };
let customRangeTo   = { log: '', analytics: '', expenses: '' };

/**
 * Whether a record's date falls in a range picker's period.
 *
 * The rule is lib/date-range.js, shared with the Mac app; this hands it the
 * clock and the page's custom span for the list asking.
 */
function inRange(dateStr, range, ctx) {
  const DR = (typeof globalThis !== 'undefined' && globalThis.KhaytDateRange)
    || require('../lib/date-range.js');
  return DR.inRange(dateStr, range, {
    now: new Date(),
    from: ctx ? customRangeFrom[ctx] : '',
    to:   ctx ? customRangeTo[ctx]   : '',
  });
}

/* ============================================================
   New Feature 7: Working-hours helpers
   ============================================================ */
const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

/** Count available working hours from now until targetDate (exclusive), using
 *  settings.workingHours per day-of-week and skipping settings.holidays. */
function availableHoursUntil(targetDate) {
  const wh = KhaytWorkingWeek.workingHours(settings);
  const holidays = new Set(settings.holidays || []);
  const cursor = new Date();
  cursor.setHours(0, 0, 0, 0);
  const end = new Date(targetDate);
  end.setHours(0, 0, 0, 0);
  let total = 0;
  while (cursor < end) {
    const iso = localDateStr(cursor);
    if (!holidays.has(iso)) {
      const key = DAY_KEYS[cursor.getDay()];
      total += Math.max(0, +(wh[key] || 0));
    }
    cursor.setDate(cursor.getDate() + 1);
  }
  return total;
}

/** Get daily working hours for today (used in clearDays forecast) */
function avgDailyWorkingHours() {
  const wh = KhaytWorkingWeek.workingHours(settings);
  const days = Object.values(wh);
  const totalWeeklyHours = days.reduce((s, h) => s + (h > 0 ? h : 0), 0);
  // Divide by 7 to get calendar-day average (correct for delivery-date estimation)
  return totalWeeklyHours > 0 ? totalWeeklyHours / 7 : 8;
}

/* ============================================================
   Feature 2 (new): Machine downtime helpers
   ============================================================ */
/** Sum hours of overlap between [fromDate, toDate] and machine.downtimeBlocks */
function machineDowntimeHoursInRange(machine, fromDate, toDate) {
  const blocks = machine.downtimeBlocks || [];
  if (blocks.length === 0) return 0;
  const from = new Date(fromDate).getTime();
  const to   = new Date(toDate).getTime();
  let total = 0;
  for (const b of blocks) {
    if (!b.from || !b.to) continue;
    const bFrom = new Date(b.from).getTime();
    const bTo   = new Date(b.to).getTime();
    const overlapStart = Math.max(from, bFrom);
    const overlapEnd   = Math.min(to,   bTo);
    if (overlapEnd > overlapStart) {
      total += (overlapEnd - overlapStart) / 3600000;
    }
  }
  return total;
}

/* ============================================================
   Feature 6 (new): Client credit limit helpers
   ============================================================ */
function clientOutstandingBalance(clientId) {
  return printLog
    .filter(o => o.clientId === clientId && o.status !== 'quote' && payStatus(o) !== 'paid')
    .reduce((s, o) => s + orderOwedBase(o), 0);
}

/** True when moving orderId into newStatus would meet or exceed the configured WIP limit.
 *
 *  The rule moved to lib/order-status.js with the rest of the status rules, so
 *  the Mac app can grey out a full column by the same arithmetic. This name
 *  stays because bedready-queue.js and the queue view both call it. */
function wouldExceedWipLimit(orders, orderId, newStatus, wipLimits) {
  const rules = (typeof globalThis !== 'undefined' && globalThis.KhaytOrderStatus)
    || (() => { try { return require('../lib/order-status.js'); } catch (e) { return null; } })();
  return rules ? rules.wouldExceedWipLimit(orders, orderId, newStatus, wipLimits) : false;
}


/* ============================================================
   Locale helpers — Hijri date + Arabic numerals
   ============================================================ */
const ARABIC_DIGITS = '٠١٢٣٤٥٦٧٨٩';
function toArabicNumerals(s) {
  return String(s ?? '').replace(/[0-9]/g, d => ARABIC_DIGITS[+d]);
}
// Converts an ISO date string to a Saudi Hijri (Umm al-Qura) display string,
// e.g. "٤ ذو القعدة ١٤٤٧" or "1447/11/04". Defaults to short numeric.
function hijriDate(isoDate, format = 'short') {
  if (!isoDate) return '';
  try {
    const d = new Date(isoDate);
    if (format === 'long') {
      return d.toLocaleDateString('ar-SA-u-ca-islamic-umalqura-nu-latn', {
        day: 'numeric', month: 'long', year: 'numeric'
      });
    }
    // Compact YYYY/MM/DD style
    const parts = new Intl.DateTimeFormat('en-u-ca-islamic-umalqura', {
      day: '2-digit', month: '2-digit', year: 'numeric'
    }).formatToParts(d);
    const y = parts.find(p => p.type === 'year')?.value || '';
    const m = parts.find(p => p.type === 'month')?.value || '';
    const dd = parts.find(p => p.type === 'day')?.value || '';
    return `${y}/${m}/${dd}`;
  } catch { return ''; }
}





/* ============================================================
   Team activity log — append-only "who did what, when"
   ============================================================ */

/** Append an entry to the team activity log, attributed to the active operator.
 *  Never throws (must not break the underlying action). Capped locally. */
function logActivity(action, detail, ref) {
  try {
    if (typeof auditLog === 'undefined') return;
    const opId = (typeof settings !== 'undefined' && settings.activeOperatorId) || null;
    const op = opId && typeof operators !== 'undefined' ? operators.find((o) => o.id === opId) : null;
    auditLog.push({
      id: uid('AL'),
      at: new Date().toISOString(),
      action: String(action || ''),
      detail: String(detail || ''),
      ref: ref ? String(ref) : '',
      operatorId: opId,
      operatorName: op ? op.name : '',
    });
    if (auditLog.length > 2000) auditLog = auditLog.slice(-2000);
  } catch (e) { /* logging must never break the action */ }
}

/** View the team activity log (newest first), optionally filtered by member. */
function openActivityLog() {
  if (typeof openFormModal !== 'function') return;
  let opFilter = '';
  const fmtWhen = (iso) => { try { return new Date(iso).toLocaleString(i18n.current === 'ar' ? 'ar-SA-u-nu-latn' : 'en-US', { dateStyle: 'medium', timeStyle: 'short' }); } catch (e) { return iso; } };
  const actionLabel = (a) => t('audit.act_' + a) || a;
  const render = (modal) => {
    const entries = (typeof auditLog !== 'undefined' ? auditLog : [])
      .filter((e) => !opFilter || e.operatorId === opFilter)
      .slice().reverse().slice(0, 300);
    const ops = (typeof operators !== 'undefined' ? operators : []);
    const rows = entries.length ? entries.map((e) => `
      <div style="display:flex;gap:10px;padding:7px 0;border-bottom:1px solid var(--border-soft);font-size:13px;">
        <div style="flex:1;"><strong>${escapeHtml(actionLabel(e.action))}</strong> ${escapeHtml(e.detail || '')}</div>
        <div style="text-align:end;color:var(--text-muted);font-size:11.5px;white-space:nowrap;">${escapeHtml(e.operatorName || t('audit.system') || '—')}<br>${escapeHtml(fmtWhen(e.at))}</div>
      </div>`).join('') : `<div style="text-align:center;color:var(--text-muted);padding:20px 0;">${escapeHtml(t('audit.empty') || 'No activity yet.')}</div>`;
    modal.querySelector('#auditBody').innerHTML = `
      <select id="auditOp" style="font-size:12.5px;margin-bottom:10px;width:auto;">
        <option value="">${escapeHtml(t('audit.all_members') || 'All members')}</option>
        ${ops.map((o) => `<option value="${escapeHtml(o.id)}"${o.id === opFilter ? ' selected' : ''}>${escapeHtml(o.name)}</option>`).join('')}
      </select>
      ${rows}`;
    modal.querySelector('#auditOp')?.addEventListener('change', (e) => { opFilter = e.target.value; render(modal); });
  };
  openFormModal({
    title: '🧾 ' + (t('audit.title') || 'Activity log'),
    noSave: true,
    bodyHtml: `<div id="auditBody"></div>`,
    onMount(modal) { render(modal); },
  });
}


(function (global) {
  const api = {
    logActivity,
    openActivityLog,
    localName,
    altLocalName,
    // Declared above the IIFE, like localName, so they are globals in the
    // browser — but a module required under Node sees only what this list
    // exports, which is how renderInvoice threw "shopField is not defined"
    // in test/render-paths.test.js and not in the app.
    shopField,
    shopName,
    payStatus,
    csvEsc,
    downloadBlob,
    parseTags,
    renderTagChips,
    getAllTags,
    getPriorityLevel,
    prioritySortValue,
    priorityBadgeHtml,
    formatDueDateBadge,
    openCsvImportModal,
    safeBizLogo,
    inRange,
    availableHoursUntil,
    avgDailyWorkingHours,
    machineDowntimeHoursInRange,
    clientOutstandingBalance,
    wouldExceedWipLimit,
    toArabicNumerals,
    hijriDate,
  };
  Object.assign(global, api);
  global.KhaytAppHelpers = api;
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { ...api, customRangeFrom, customRangeTo, DAY_KEYS };
  }
})(typeof globalThis !== 'undefined' ? globalThis : window);
