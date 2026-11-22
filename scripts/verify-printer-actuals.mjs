#!/usr/bin/env node
/**
 * Point Khayt's actuals reader at a REAL printer and see whether it was right.
 *
 * lib/printer-actuals.js decides what a finished job cost — the number that
 * feeds estimate-vs-actual, the per-setup history, and the calibrated estimator.
 * Its field names were taken from each vendor's documentation and its tests run
 * against fixtures written by hand. Both of those can be self-consistently
 * wrong: a fixture written from the same misreading as the code will agree with
 * it forever.
 *
 * The only thing that settles it is a printer. This script is what to run when
 * one is switched on — it queries the exact endpoint the poller queries, feeds
 * the untouched response to the real extractor, and prints both so any
 * disagreement is visible rather than inferred.
 *
 * Usage
 *   node scripts/verify-printer-actuals.mjs --scan
 *   node scripts/verify-printer-actuals.mjs moonraker 192.168.68.42
 *   node scripts/verify-printer-actuals.mjs prusalink 192.168.68.41 --key XXXX
 *   node scripts/verify-printer-actuals.mjs moonraker 192.168.68.42 --raw
 *
 * WHAT IT CAN AND CANNOT PROVE
 *
 * An idle printer reports filament_used = 0 and print_duration = 0, and
 * extractActuals correctly maps both to null — "we don't know", not "it was
 * free". That is worth confirming, but it does not prove the mapping is right,
 * because null is also what a WRONG field name produces.
 *
 * So the check that matters must run while a job is printing, or immediately
 * after one finishes and before the next begins. Moonraker and OctoPrint retain
 * a completed job's stats until the next print starts. The script says which of
 * the two situations it is in rather than reporting a pass either way.
 *
 * Never writes anything and never commands the printer — GETs only.
 */
// lib/printer-actuals.js is an IIFE with module.exports — CommonJS, so it has no
// named ESM exports. Default-import then destructure, or this file throws on
// load, which is a poor way to discover a problem on the one day a printer is on.
import printerActuals from '../lib/printer-actuals.js';
const { extractActuals, filamentMmToGrams } = printerActuals;

const DEFAULT_PORTS = { octoprint: 80, moonraker: 7125, prusalink: 80, duet: 80 };

/** The exact path lib/../main.js fetchPrinterStatus uses for each type. */
const PROBE = {
  moonraker: '/printer/objects/query?print_stats&virtual_sdcard&extruder&heater_bed',
  octoprint: '/api/job',
  prusalink: '/api/v1/status',
  duet: '/rr_model?key=&flags=d99fn',
};

/**
 * Liveness probe for --scan, plus a shape test for the answer.
 *
 * "It returned 200 and parsed as JSON" is not enough. A device on this very LAN
 * (an embedded web server) answers /api/version with HTTP 200 and the body
 * `[{"error":{"description":"unauthorized user"}}]`, which made the scan report
 * it as BOTH an OctoPrint and a PrusaLink. A scan that names two printer types
 * for a device that is neither is noise on the one day you need signal, so each
 * probe now has to recognise its own API's shape.
 */
const HELLO = {
  moonraker: { path: '/server/info', looksRight: (j) => !!(j && typeof j === 'object' && j.result) },
  octoprint: {
    path: '/api/version',
    // Moonraker ANSWERS THIS TOO. It ships an OctoPrint-compatibility shim so
    // that OctoPrint-only slicers can upload, and a real Snapmaker U1 replies
    // `{"server":"1.5.0","api":"0.1","text":"OctoPrint (Moonraker 1.5.2)"}`.
    // Reporting that as an OctoPrint is worse than reporting nothing: the shim
    // returns filament.length = null and printTime = null, so a machine set up
    // that way extracts no actuals at all, silently and forever. The `text`
    // field names the real server, so use it.
    looksRight: (j) => !!(j && typeof j.api === 'string' && typeof j.server === 'string'
      && !/moonraker/i.test(String(j.text || ''))),
  },
  prusalink: {
    // NOT /api/version. PrusaLink answers it, but so does Moonraker's OctoPrint
    // shim, and the old check accepted any body carrying an `api` string — so a
    // U1 was reported as a PrusaLink as well. This path is PrusaLink's own and
    // 404s on Moonraker.
    path: '/api/v1/status',
    looksRight: (j) => !!(j && (j.printer || j.storage || j.job)),
  },
  duet:      { path: '/rr_model?key=state', looksRight: (j) => !!(j && (j.result !== undefined || j.key)) },
};

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const valueOf = (n) => { const i = args.indexOf(n); return i === -1 ? null : args[i + 1]; };
const apiKey = valueOf('--key');

async function get(url, headers = {}) {
  const res = await fetch(url, { headers, redirect: 'manual', signal: AbortSignal.timeout(4000) });
  if (res.status >= 300 && res.status < 400) throw new Error('unexpected redirect');
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

function headersFor(type) {
  if (!apiKey) return {};
  // Same header the app sends, per type.
  return type === 'repetier' ? { 'x-api-key': apiKey } : { 'X-Api-Key': apiKey };
}

async function scan() {
  const os = await import('node:os');
  const nets = Object.values(os.networkInterfaces()).flat()
    .filter((n) => n && n.family === 'IPv4' && !n.internal);
  if (!nets.length) { console.error('no IPv4 interface found'); process.exit(1); }
  const base = nets[0].address.split('.').slice(0, 3).join('.');
  console.log(`scanning ${base}.0/24 — this takes about a minute\n`);

  const found = [];
  await Promise.all([...Array(254)].map(async (_, i) => {
    const ip = `${base}.${i + 1}`;
    for (const [type, probe] of Object.entries(HELLO)) {
      const port = DEFAULT_PORTS[type];
      try {
        const j = await get(`http://${ip}:${port}${probe.path}`, headersFor(type));
        if (probe.looksRight(j)) found.push({ type, ip, port });
      } catch (e) {
        // PrusaLink answers 401 to everything under /api, including paths that
        // do not exist — so a 401 means "something Prusa-shaped is here", not
        // "this endpoint exists". Worth surfacing as a candidate, not a match.
        // PrusaLink answers 401 to everything under /api, including paths that do
        // not exist, so a 401 here means "something Prusa-shaped" — a candidate,
        // not a match. Moonraker does not require auth, so it never lands here.
        if (type === 'prusalink' && /HTTP 401/.test(e.message)) found.push({ type, ip, port, needsKey: true });
      }
    }
  }));

  if (!found.length) {
    console.log('nothing answered. Printers powered off, or on another subnet.');
    return;
  }
  for (const f of found) {
    console.log(`  ${f.type.padEnd(10)} ${f.ip}:${f.port}${f.needsKey ? '   (needs --key)' : ''}`);
  }
  console.log('\nthen: node scripts/verify-printer-actuals.mjs <type> <ip>');
}

async function check(type, host) {
  const port = valueOf('--port') || DEFAULT_PORTS[type];
  if (!PROBE[type]) { console.error(`unknown type "${type}" — one of ${Object.keys(PROBE).join(', ')}`); process.exit(1); }

  console.log(`${type} at ${host}:${port}\n`);
  let raw;
  try {
    raw = await get(`http://${host}:${port}${PROBE[type]}`, headersFor(type));
  } catch (e) {
    console.error(`could not read ${PROBE[type]}: ${e.message}`);
    if (/401/.test(e.message)) console.error('  → needs --key <api key from the printer>');
    process.exit(1);
  }

  if (flag('--raw')) console.log('raw response:\n' + JSON.stringify(raw, null, 2) + '\n');

  // What the app would extract, from the untouched response.
  const a = extractActuals(type, raw);
  console.log('extractActuals says:');
  console.log(`  filamentMm    ${a.filamentMm}`);
  console.log(`  filamentGrams ${a.filamentGrams === null ? null : a.filamentGrams.toFixed(2)}`);
  console.log(`  durationS     ${a.durationS}`);
  console.log(`  source        ${a.source}\n`);

  // Show the fields it read straight from the payload, so a rename is obvious.
  const probes = {
    moonraker: { 'print_stats.filament_used': raw?.result?.status?.print_stats?.filament_used,
                 'print_stats.print_duration': raw?.result?.status?.print_stats?.print_duration,
                 'print_stats.total_duration': raw?.result?.status?.print_stats?.total_duration,
                 'print_stats.state': raw?.result?.status?.print_stats?.state },
    octoprint: { 'job.filament': raw?.job?.filament, 'progress.printTime': raw?.progress?.printTime,
                 'state': raw?.state },
    prusalink: { 'job.time_printing': raw?.job?.time_printing, 'printer.state': raw?.printer?.state },
    duet:      { 'job.rawExtrusion': raw?.result?.job?.rawExtrusion,
                 'job.duration': raw?.result?.job?.duration,
                 'state.status': raw?.result?.state?.status },
  }[type];
  console.log('fields as the printer actually returned them:');
  for (const [k, v] of Object.entries(probes)) {
    const shown = v === undefined ? 'ABSENT — the field name may have changed' : JSON.stringify(v);
    console.log(`  ${k.padEnd(28)} ${shown}`);
  }

  const missing = Object.entries(probes).filter(([, v]) => v === undefined).map(([k]) => k);
  const printing = /print|busy|running|working/i.test(String(
    probes['print_stats.state'] ?? probes['printer.state'] ?? probes['state.status'] ?? probes.state?.text ?? ''));

  console.log('');
  if (missing.length) {
    console.log(`⚠  ${missing.length} field(s) absent: ${missing.join(', ')}`);
    console.log('   If the printer is mid-job, this is a real mismatch — the adapter is');
    console.log('   reading a name this firmware does not use. Capture --raw and fix it.');
  }
  if (printing && (a.filamentGrams > 0 || a.durationS > 0)) {
    console.log('✅ a job is running and real figures came through — this is the check that counts.');
    console.log(`   Sanity: ${a.filamentMm} mm of 1.75 PLA ≈ ${filamentMmToGrams(a.filamentMm).toFixed(1)} g.`);
    console.log('   Compare that against the slicer\'s estimate for the same job.');
  } else if (printing) {
    console.log('❌ a job IS running but nothing was extracted — the field mapping is wrong.');
    process.exitCode = 1;
  } else {
    console.log('ℹ  the printer is idle, so nulls here are correct and prove little.');
    console.log('   Re-run DURING a print, or right after one finishes and before the next');
    console.log('   starts — that is the only state that distinguishes a right field name');
    console.log('   from a wrong one.');
  }
}

if (flag('--scan') || !args.length) await scan();
else await check(args[0], args[1]);
