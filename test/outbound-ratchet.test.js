'use strict';
/**
 * Every network primitive in the desktop's code is either GATED by the
 * "make no internet calls" switch, tagged as a LAN or exempt call, or counted
 * in a per-file baseline that only shrinks (P8; design note §2).
 *
 * A hit is tagged when its line, or the line above, carries
 *   // outbound: <purpose>          a purpose from lib/outbound.js PURPOSES, AND
 *                                   the file asks the gate for that purpose
 *                                   (check('<purpose>' / gate('<purpose>' /
 *                                   .for('<purpose>' / updatesAllowed)
 *   // outbound-exempt: <kind> — <reason>
 *                                   kind: browser | inbound-server | served-page | not-run | local-file
 *                                   | gate (lib/main/outbound-fetch.js's own wrapper)
 * Everything else counts against the file's baseline
 * (test/fixtures/outbound-ratchet-baseline.json). A new untagged call fails;
 * one that is gated or tagged must come off the baseline, so the list only
 * shrinks. It ends at {} (design PR 4).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PURPOSES } = require('../lib/outbound.js');

const ROOT = path.join(__dirname, '..');
const BASELINE_FILE = path.join(__dirname, 'fixtures', 'outbound-ratchet-baseline.json');
const EXEMPT_KINDS = ['browser', 'inbound-server', 'served-page', 'not-run', 'local-file', 'gate'];

const PRIMITIVES = [
  /(?<![\w.$])fetch\s*\(/, /globalThis\.fetch\b/, /\|\|\s*(?:globalThis\.)?fetch\b/,
  /require\(\s*['"](?:https?|net|tls|dgram)['"]\s*\)/,
  /\bnet\.request\(/, /\bsession\.[a-zA-Z]+\.fetch\b/,
  /require\(\s*['"]electron-updater['"]\s*\)/, /\.checkForUpdates\(/, /\.downloadUpdate\(/,
  /require\(\s*['"]localtunnel['"]\s*\)/, /require\(\s*['"]@sentry\/electron[^'"]*['"]\s*\)/,
  /\bnew WebSocket\(/, /\bnew EventSource\(/, /\bXMLHttpRequest\b/,
  /\bshell\.openExternal\(/,
];

function files() {
  const out = ['main.js', 'preload.js'];
  const walk = (dir) => {
    for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
      const rel = path.join(dir, e.name);
      if (e.isDirectory()) { if (!['locales', 'vendor', 'node_modules'].includes(e.name)) walk(rel); }
      else if (e.name.endsWith('.js')) out.push(rel);
    }
  };
  walk('lib'); walk('renderer');
  return out;
}

/** Each line's code with comments removed (block comments tracked across lines). */
function codeLines(src) {
  const lines = src.split('\n');
  const out = [];
  let inBlock = false;
  for (const line of lines) {
    let code = '';
    for (let i = 0; i < line.length; i++) {
      if (inBlock) { if (line[i] === '*' && line[i + 1] === '/') { inBlock = false; i++; } continue; }
      if (line[i] === '/' && line[i + 1] === '*') { inBlock = true; i++; continue; }
      if (line[i] === '/' && line[i + 1] === '/' && line[i - 1] !== ':') break;   // not the // of a URL
      code += line[i];
    }
    out.push(code);
  }
  return { lines, code: out };
}

function tagOf(raw) {
  const m = /\/\/\s*outbound:\s*([a-z-]+)/.exec(raw);
  if (m) return { purpose: m[1] };
  const e = /\/\/\s*outbound-exempt:\s*([a-z-]+)\s*[—-]\s*\S/.exec(raw);
  if (e) return { exempt: e[1] };
  return null;
}

function scan(rel) {
  const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
  const { lines, code } = codeLines(src);
  let untagged = 0;
  const bad = [];
  for (let i = 0; i < code.length; i++) {
    // Every match counts, not every line: a second call added to a line
    // already on the baseline is a new call (review of #2627).
    let hits = 0;
    for (const re of PRIMITIVES) hits += (code[i].match(new RegExp(re.source, 'g')) || []).length;
    if (!hits) continue;
    const tag = tagOf(lines[i]) || (i > 0 ? tagOf(lines[i - 1]) : null);
    if (!tag) { untagged += hits; continue; }
    if (tag.exempt) { if (!EXEMPT_KINDS.includes(tag.exempt)) bad.push(`${rel}:${i + 1} unknown exempt kind ${tag.exempt}`); continue; }
    if (!PURPOSES.includes(tag.purpose)) { bad.push(`${rel}:${i + 1} unknown purpose ${tag.purpose}`); continue; }
    // In CODE, not a comment: a tag cannot be satisfied by writing the words
    // (review of #2627). `lan` needs no gate yet: PR 4 adds the address check
    // (and the resolve-time one) every lan call must go through.
    const body = code.join('\n');
    const asks = [`check('${tag.purpose}'`, `gate('${tag.purpose}'`, `Gate('${tag.purpose}'`, `.for('${tag.purpose}'`].some((n) => body.includes(n))
      || (tag.purpose === 'updates' && body.includes('updatesAllowed()'))
      || tag.purpose === 'lan';   // TODO(PR 4): require the lan address gate here
    if (!asks) bad.push(`${rel}:${i + 1} tagged ${tag.purpose} but the file never asks the gate for it`);
  }
  return { untagged, bad };
}

test('every network call is gated, tagged, or on a baseline that only shrinks', () => {
  const baseline = JSON.parse(fs.readFileSync(BASELINE_FILE, 'utf8'));
  const now = {};
  const bad = [];
  for (const f of files()) {
    const r = scan(f);
    bad.push(...r.bad);
    if (r.untagged) now[f] = r.untagged;
  }
  assert.deepEqual(bad, [], 'tags that do not hold');
  const grew = Object.keys(now).filter((f) => now[f] > (baseline[f] || 0)).map((f) => `${f}: ${baseline[f] || 0} → ${now[f]}`);
  assert.deepEqual(grew, [], 'a new untagged network call: gate it through lib/main/outbound-fetch.js and tag it, or tag it lan/exempt');
  const shrank = Object.keys(baseline).filter((f) => (now[f] || 0) < baseline[f]).map((f) => `${f}: ${baseline[f]} → ${now[f] || 0}`);
  assert.deepEqual(shrank, [], 'fewer untagged calls than the baseline: lower it in test/fixtures/outbound-ratchet-baseline.json');
});

test('the gated phone-home paths are tagged (PR 2)', () => {
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  assert.match(main, /\/\/ outbound: install-count\n\s*const res = await fetch\(ACTIVE_COUNT_E2E/);
  assert.match(main, /const gate = outboundGate\.check\('install-count'\);\s*\n\s*if \(!gate\.allowed\) \{/);
  assert.match(main, /crash = tm\.crashOptIn === true && outboundGate\.check\('crash-reports'\)\.allowed;/);
  assert.match(main, /usage = tm\.usageOptIn === true && outboundGate\.check\('usage-stats'\)\.allowed;/);
  // Sentry: every envelope (client reports, retries of queued ones) through the gate.
  assert.match(main, /sendClientReports: false,/);
  assert.match(main, /transport: sentry\.makeElectronOfflineTransport\(\(options\) => \{\s*\n\s*const base = sentry\.makeElectronTransport\(options\);/);
  assert.match(main, /return ok \? base\.send\(envelope\) : Promise\.resolve\(\{\}\);/);
  assert.match(main, /!require\('\.\/lib\/main\/outbound-fetch\.js'\)\.offlineAtStartup\(/);
  const upd = fs.readFileSync(path.join(ROOT, 'lib', 'updater.js'), 'utf8');
  assert.match(upd, /if \(g\.allowed\) \{ autoUpdater\.checkForUpdates\(\)\.catch\(\(\) => \{\}\); return; \}/);
  assert.match(upd, /if \(g\.reason === 'settings-unknown' && waits < 10\)/);
  assert.match(upd, /if \(!gate\.allowed\) return \{ status: 'blocked', currentVersion, blocked:/);
  assert.match(upd, /if \(!gate\.allowed\) return \{ ok: false, blocked: \{ purpose: 'updates'/);
});

module.exports = { scan, files };
