#!/usr/bin/env node
/**
 * A renderer global that nothing loads is a feature that quietly does nothing.
 *
 * This class of bug has now appeared three times in a week, and it never errors:
 *
 *   #578  renderer/printfiles.js read a global bare instead of through its
 *         accessor, so model matching SILENTLY never matched
 *   #581  the production queue's status buttons called a shim no-op, so they
 *         drew, the handler ran, and nothing moved
 *   #587  I referenced KhaytPollCache from order-flows.js before adding the
 *         script tag; it would have fallen back to "whatever finished last"
 *         forever. Caught only because I wrote an e2e for it by hand.
 *
 * Unit tests cannot see any of it: in Node, require() always succeeds. Only the
 * assembled HTML entry point knows what the renderer will really have.
 *
 * THE HARD PART: a guarded reference to a missing global is EXACTLY what
 * deliberate flavour gating looks like. `window.KhaytBedReadyUI?.init?.()` in a
 * shared file is correct and intentional — Khayt does not load Bed Ready's UI.
 * Structurally that is identical to the #587 bug. What separates them is not the
 * call site but the OWNER: a flavour-specific module is expected to be absent
 * from the other flavour's page, and anything else is not.
 */
'use strict';
const fs = require('fs');
const path = require('path');

/** Modules a page may legitimately reference without loading, by owner path. */
const FLAVOUR_DIRS = ['renderer/bedready/'];

const GLOBAL_DEF = new RegExp(
  '(?:global|window|globalThis|self|g)\\s*\\.\\s*(Khayt[A-Za-z0-9_]*)\\s*=' +
  '|Object\\.assign\\(\\s*(?:global|globalThis|window)\\s*,\\s*\\{\\s*(Khayt[A-Za-z0-9_]*)\\s*:',
  'g',
);
const GLOBAL_USE = /\b(Khayt[A-Z][A-Za-z0-9_]*)\b/g;

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.js')) out.push(p);
  }
  return out;
}

/** global name -> the file that assigns it */
function findDefinitions(roots) {
  const defs = new Map();
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const file of walk(root)) {
      const src = fs.readFileSync(file, 'utf8');
      for (const m of src.matchAll(GLOBAL_DEF)) {
        const g = m[1] || m[2];
        if (g && !defs.has(g)) defs.set(g, file.split(path.sep).join('/'));
      }
    }
  }
  return defs;
}

/** The scripts an HTML entry point loads, as repo-relative paths. */
function scriptsIn(htmlPath) {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const dir = path.dirname(htmlPath);
  const out = new Set();
  for (const m of html.matchAll(/<script[^>]*\ssrc="([^"]+)"/g)) {
    if (/^https?:/i.test(m[1])) continue;
    out.add(path.normalize(path.join(dir, m[1])).split(path.sep).join('/'));
  }
  return out;
}

const isFlavourOwned = (owner) => FLAVOUR_DIRS.some((d) => owner.startsWith(d));

/**
 * Gaps that already existed when this page was first checked. A RATCHET, not an
 * exemption: everything listed here is a feature Bed Ready silently does not
 * have, and the list may only shrink. A new gap is a failure.
 *
 * It started at 32 and is 12. The twelve that went were five modules Bed Ready
 * reads for and never loaded — the consumable category filter, the reorder
 * suggestions, the printer-state rule and two the theme dashboards need. Every
 * one of them was workshop logic that had simply never been given a script tag —
 * as was printer-relocate, and the three that let an estimate learn from what
 * the printer actually did. What is left is Khayt's own three themes, which Bed
 * Ready replaces with its own, and six modules reached from settings.js and the
 * customer intake — all commerce.
 *
 * `renderer/bedready.html` was outside this check until a shared module
 * (lib/order-deduction.js) was added to inventory.js without a matching script
 * tag there. Nothing errored at build time; the Bed Ready smoke failed on
 * "Cannot read properties of null (reading 'isLowStock')" — the fourth time
 * this class of bug has shipped. Checking the page with its known gaps written
 * down catches the fifth without a day spent closing the other thirty-two.
 *
 * Fixing one of these is a script tag away: add it, delete the line, and the
 * check will tell you if you were wrong.
 */
const KNOWN_ABSENT = {
  'renderer/bedready.html': [
    ['KhaytFlow', 'renderer/dashboard.js'],
    ['KhaytFlowShell', 'renderer/themes.js'],
    ['KhaytForeman', 'renderer/dashboard.js'],
    ['KhaytForemanShell', 'renderer/themes.js'],
    ['KhaytIntakeView', 'renderer/wire-events.js'],
    ['KhaytMedusa', 'renderer/settings.js'],
    ['KhaytMeridian', 'renderer/dashboard.js'],
    ['KhaytMeridianShell', 'renderer/themes.js'],
    ['KhaytPrivacy', 'renderer/settings.js'],
    ['KhaytTelemetryScrub', 'renderer/settings.js'],
  ],
};

const absentKey = (v) => `${v.global}|${v.user}`;
const knownAbsentFor = (entry) => new Set(
  (KNOWN_ABSENT[entry.split(path.sep).join('/')] || []).map(([g, user]) => `${g}|${user}`),
);

/**
 * @returns {{entry: string, violations: Array<{global,owner,user}>}}
 */
function audit(htmlPath, defs) {
  const loaded = scriptsIn(htmlPath);
  const violations = [];
  const seen = new Set();
  for (const file of loaded) {
    if (!file.endsWith('.js') || !fs.existsSync(file)) continue;
    const src = fs.readFileSync(file, 'utf8');
    for (const m of src.matchAll(GLOBAL_USE)) {
      const g = m[1];
      const owner = defs.get(g);
      if (!owner) continue;              // not ours, or defined elsewhere
      if (loaded.has(owner)) continue;   // present — fine
      if (isFlavourOwned(owner)) continue; // deliberately absent from this flavour
      const key = `${g}|${file}`;
      if (seen.has(key)) continue;
      seen.add(key);
      violations.push({ global: g, owner, user: file });
    }
  }
  return { entry: htmlPath, violations };
}

module.exports = { audit, findDefinitions, scriptsIn, isFlavourOwned, FLAVOUR_DIRS, KNOWN_ABSENT };

if (require.main === module) {
  const defs = findDefinitions(['lib', 'renderer']);
  const entries = process.argv.slice(2);
  const targets = entries.length ? entries : ['renderer/index.html', 'renderer/bedready.html'];

  let bad = 0;
  for (const entry of targets) {
    if (!fs.existsSync(entry)) { process.stdout.write(`skipped ${entry} (not found)\n`); continue; }
    const { violations } = audit(entry, defs);
    const known = knownAbsentFor(entry);
    const fresh = violations.filter((v) => !known.has(absentKey(v)));

    // A gap that has been closed must leave the list, or the list stops meaning
    // "these are the ones we know about" and starts meaning nothing.
    const stillMissing = new Set(violations.map(absentKey));
    const closed = [...known].filter((k) => !stillMissing.has(k));
    if (closed.length) {
      process.stderr.write(
        `\n${entry}: ${closed.length} entr(ies) in KNOWN_ABSENT are no longer missing.\n` +
        `Delete them from scripts/check-globals-loaded.js — the list only ratchets down.\n`);
      for (const k of closed) process.stderr.write(`  ${k.replace('|', ' — used by ')}\n`);
      bad += closed.length;
    }

    if (!fresh.length) {
      const note = known.size ? ` (${known.size} known gap(s))` : '';
      process.stdout.write(`globals ok — ${entry}${note}\n`);
      continue;
    }
    bad += fresh.length;
    process.stderr.write(`\n${entry}: ${fresh.length} global(s) referenced but never loaded\n`);
    for (const v of fresh) {
      process.stderr.write(`  ${v.global} — defined in ${v.owner}, used by ${v.user}\n`);
    }
  }

  if (bad) {
    process.stderr.write(
      `\nEach of these reads a global the page never loads. A guarded read fails\n` +
      `SILENTLY — the feature is simply absent, with no error anywhere. Add a\n` +
      `<script> tag for the owning file, or move the owner under one of:\n` +
      FLAVOUR_DIRS.map((d) => `  ${d}\n`).join('') +
      `if it is meant to be absent from this flavour.\n`,
    );
    process.exit(1);
  }
  process.stdout.write(`globals check ok — ${targets.length} entry point(s)\n`);
}
