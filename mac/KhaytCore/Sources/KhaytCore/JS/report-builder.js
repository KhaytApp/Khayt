'use strict';
(function () {
/**
 * Custom report builder — pick fields + filters + a date range over a set of
 * already-flattened order records and get a table you can preview or export as
 * CSV. Pure (no DOM / no lookups): the renderer flattens orders into plain
 * records (resolving client/machine names + base-currency amounts), then this
 * selects columns, applies filters, and renders rows. Deterministic + testable.
 */

// The columns a report can include. `key` matches the flattened record field;
// `label` is the default English header (the renderer may localize).
const FIELDS = [
  { key: 'id', label: 'Order #' },
  { key: 'date', label: 'Date' },
  { key: 'project', label: 'Project' },
  { key: 'client', label: 'Client' },
  { key: 'status', label: 'Status' },
  { key: 'material', label: 'Material' },
  { key: 'printTime', label: 'Print Time (h)' },
  { key: 'machine', label: 'Machine' },
  { key: 'price', label: 'Price' },
  { key: 'paidAmount', label: 'Paid' },
  { key: 'balance', label: 'Balance' },
  { key: 'paymentStatus', label: 'Payment' },
  { key: 'dueDate', label: 'Due Date' },
  { key: 'tags', label: 'Tags' },
];
const FIELD_KEYS = FIELDS.map((f) => f.key);

const DEFAULT_FIELDS = ['id', 'date', 'client', 'status', 'price', 'paymentStatus'];

function dkey(d) { return String(d == null ? '' : d).slice(0, 10); }

/**
 * @param {object[]} records flattened order records (flat key→value objects)
 * @param {object} spec { fields:string[], from?, to?, statusIn?:string[] }
 * @returns {{ headers:string[], keys:string[], rows:Array<Array>, count:number }}
 */
function buildReport(records, spec) {
  spec = spec || {};
  const keys = (Array.isArray(spec.fields) && spec.fields.length
    ? spec.fields : DEFAULT_FIELDS).filter((k) => FIELD_KEYS.includes(k));
  const labelOf = (k) => (spec.labels && spec.labels[k]) || (FIELDS.find((f) => f.key === k) || {}).label || k;
  const from = spec.from ? dkey(spec.from) : '';
  const to = spec.to ? dkey(spec.to) : '';
  const statusIn = Array.isArray(spec.statusIn) && spec.statusIn.length ? new Set(spec.statusIn) : null;

  const rows = [];
  for (const r of (Array.isArray(records) ? records : [])) {
    const d = dkey(r.date);
    if (from && d < from) continue;
    if (to && d > to) continue;
    if (statusIn && !statusIn.has(r.status)) continue;
    rows.push(keys.map((k) => {
      const v = r[k];
      return Array.isArray(v) ? v.join(', ') : (v == null ? '' : v);
    }));
  }
  return { headers: keys.map(labelOf), keys, rows, count: rows.length };
}

// Spreadsheet-safe CSV (BOM, CRLF, quoted, formula-neutralized).
function cell(v) {
  if (typeof v === 'number') return '"' + v + '"';
  const s = v == null ? '' : String(v);
  const safe = /^[=+\-@\t\r]/.test(s) ? "'" + s : s;
  return '"' + safe.replace(/"/g, '""') + '"';
}

function reportToCsv(report) {
  const lines = [report.headers.map(cell).join(',')];
  for (const row of report.rows) lines.push(row.map(cell).join(','));
  return '﻿' + lines.join('\r\n');
}

const api = { FIELDS, FIELD_KEYS, DEFAULT_FIELDS, buildReport, reportToCsv };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytReportBuilder = api;
})();
