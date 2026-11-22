'use strict';
/**
 * Reading a shop's spools out of Spoolman — the main-process half of
 * Inventory ▸ Import from Spoolman (the Mac's SpoolmanImport.swift).
 *
 * Spoolman usually runs on the printer's own board or a Pi beside it, on the
 * shop's network, with no key. This asks it for every spool, a page at a time
 * (`lib/spoolman-import.js listPath`), and hands the raw rows back; the window
 * decides what each becomes through the same module. It only ever reads: there
 * is no request here that could change Spoolman.
 *
 * The address is held to the same rule as a printer's — `resolvePrinterTarget`
 * (lib/main/printer-target.js → lib/printer-host.js): on this network, every
 * address the name resolves to, pinned to the address it resolved to. A URL
 * field that will fetch anything is a request forgery waiting for a pretext,
 * and redirects are refused for the same reason.
 *
 * Failures come back as `{ ok: false, code, host?, status? }` so the window can
 * say them in the shop's language: `no_address`, `not_lan`, `refused`,
 * `not_spoolman`, `network`.
 */
const { resolvePrinterTarget } = require('./printer-target');
const { listPath, PAGE, DEFAULT_PORT } = require('../spoolman-import');

const TIMEOUT_MS = 8000;
/** Twenty pages is ten thousand rolls — past any shop, and short of a server that answers forever. */
const MAX_PAGES = 20;

/**
 * `192.168.1.20`, `192.168.1.20:7912` or `http://192.168.1.20:7912/` — whatever
 * the shop pastes — as the base URL, on this network or refused.
 */
async function spoolmanBase(typed, opts) {
  const o = opts || {};
  let raw = String(typed == null ? '' : typed).trim();
  if (!raw) return { ok: false, code: 'no_address' };
  if (!raw.includes('://')) raw = 'http://' + raw;
  let u;
  try { u = new URL(raw); } catch { return { ok: false, code: 'no_address' }; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return { ok: false, code: 'no_address' };
  if (u.username || u.password) return { ok: false, code: 'no_address' };
  const host = u.hostname.replace(/^\[|\]$/g, '');
  if (!host) return { ok: false, code: 'no_address' };
  const port = u.port ? parseInt(u.port, 10) : DEFAULT_PORT;
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { ok: false, code: 'no_address' };
  const target = await resolvePrinterTarget(host, o.lookup ? { lookup: o.lookup } : undefined);
  if (!target.ok) return { ok: false, code: 'not_lan', host };
  return { ok: true, base: `${u.protocol}//${target.urlHost}:${port}` };
}

/** Every spool Spoolman holds that is not archived, all pages. */
async function fetchSpoolman(typed, opts) {
  const o = opts || {};
  const fetchImpl = o.fetchImpl || fetch;
  const b = await spoolmanBase(typed, o);
  if (!b.ok) return b;
  const out = [];
  for (let n = 0; n < MAX_PAGES; n++) {
    let res;
    try {
      res = await fetchImpl(b.base + listPath(n * PAGE, PAGE), {
        redirect: 'manual', signal: AbortSignal.timeout(o.timeoutMs || TIMEOUT_MS),
        headers: { Accept: 'application/json' },
      });
    } catch (e) {
      return { ok: false, code: 'network', error: String((e && e.message) || e) };
    }
    if (!res || !res.ok) return { ok: false, code: 'refused', status: res ? res.status : 0 };
    let rows;
    try { rows = await res.json(); } catch { rows = null; }
    if (!Array.isArray(rows)) return { ok: false, code: 'not_spoolman' };
    out.push(...rows);
    if (rows.length < PAGE) break;
    const total = parseInt((res.headers && res.headers.get && res.headers.get('x-total-count')) || '', 10);
    if (Number.isFinite(total) && out.length >= total) break;
  }
  return { ok: true, spools: out };
}

module.exports = { spoolmanBase, fetchSpoolman, TIMEOUT_MS };
