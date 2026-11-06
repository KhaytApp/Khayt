'use strict';
/**
 * Everything added in this release is REACHABLE.
 *
 * The recurring failure in this repo is not a wrong module — it is a right
 * module with no caller: a script tag never added, a report nothing surfaces, a
 * helper the save path does not consult. Unit tests pass either way, because in
 * Node the require() always succeeds. #578 was that, the print-file preview
 * migration was that, and lib/split-order.js would have been that this morning
 * if the <script> guard had not caught it.
 *
 * So: one place that names every new seam and asserts something calls it.
 * Deleting a call site fails here, which is the only thing that makes the rest
 * of the suite mean anything.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
/** Source with comments stripped: a caller named only in prose is not a caller. */
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

/**
 * Each row: what was added, and the call site that has to exist for a shop to
 * ever see it. The message is what the reader needs when it fails.
 */
const SEAMS = [
  {
    what: 'a failed backup is reported',
    where: 'renderer/app-exports.js',
    needs: /reportBackupFailure\(r\.error\)/,
    why: 'maybeAutoBackup ignores the result again — Settings shows a date over a backup that did not happen',
  },
  {
    what: 'the Last backup line recovers',
    where: 'renderer/app-exports.js',
    needs: /el\.style\.color = 'var\(--text-dim\)'/,
    why: 'the warning colour is never cleared, so a healthy shop keeps reading as broken',
  },
  {
    what: 'a .prev recovery says the last save was lost',
    where: 'renderer/app-state.js',
    needs: /store\.__recovered === 'prev'/,
    why: 'real loss is shown as a green tick again',
  },
  {
    what: 'main sends the recovered copy\'s age',
    where: 'main.js',
    needs: /masked\.__recoveredAt = rec\.writtenAt/,
    why: 'the renderer has nothing to tell the shop WHEN the copy it got back was written',
  },
  {
    what: 'an overwritten local edit is surfaced',
    where: 'renderer/settings.js',
    needs: /onConflicts: \(conflicts\) => \{[^}]*reportOverwrittenEdits\(conflicts\)/,
    why: 'the merge records the discarded edit and nothing shows it — the whole report is dead',
  },
  {
    what: 'the conflict deps reach the sync engine',
    where: 'renderer/settings.js',
    needs: /KhaytCloudSync\.configure\(cloudSyncDeps\(\)\)/,
    why: 'onConflicts is never handed to cloud-sync, so no conflict is ever reported',
  },
  {
    what: 'a successful push records the synced baseline',
    where: 'renderer/cloud-sync.js',
    needs: /KhaytSync\.markSynced\(deps\.buildSnapshot\(\)\)/,
    why: 'without a baseline every merge reports nothing — the detection is off',
  },
  {
    what: 'the completion history survives a save',
    where: 'lib/store-io.js',
    needs: /for \(const key of MAIN_OWNED_KEYS\)/,
    why: 'every renderer save deletes what the printer measured',
  },
  {
    what: 'LAN writes go through the chain',
    where: 'lib/lan-server.js',
    needs: /updateStoreOnDisk\(/,
    why: 'the endpoints write whole-store snapshots again and lose each other\'s work',
  },
  {
    what: 'main hands the store getter to store-io',
    where: 'main.js',
    needs: /getStore: \(\) => lanServerStore/,
    why: 'updateStoreOnDisk cannot read inside the chain, so it re-opens the race it closed',
  },
  {
    what: 'the background completion writer uses it too',
    where: 'main.js',
    needs: /updateStoreOnDisk\(\(cur\) => \(\{ \.\.\.cur, \[COMPLETIONS_KEY\]/,
    why: 'the poll timer writes a stale whole-store snapshot on a background timer',
  },
  {
    what: 'a superseded parent is out of the money',
    // The chokepoints moved to lib/order-money.js so the Mac app could share
    // them; the two repeated gates are now one `earns(o)` that all three money
    // functions call — which is why this asks for three and not two.
    where: 'lib/order-money.js',
    needs: /!earns\(o\)\) return 0;[\s\S]{0,900}!earns\(o\)\) return 0;[\s\S]{0,900}!earns\(o\)\) return 0;/,
    why: 'a split job is counted twice — every money chokepoint must gate it, not one',
  },
  {
    what: 'the shared money gate still excludes a superseded parent',
    where: 'lib/order-money.js',
    needs: /function earns\(o\)[\s\S]{0,300}isSuperseded/,
    why: 'the gate every money figure goes through stopped checking for a split parent',
  },
  {
    what: 'the split uses the tested share arithmetic',
    where: 'renderer/order-flows.js',
    needs: /KhaytSplitOrder\.splitMoney\(/,
    why: 'the split does its own rounding again, untested, and the deposit stops travelling',
  },
  {
    what: 'the VAT return computes VAT',
    where: 'lib/vat-return.js',
    needs: /Tax\.computeTax\(gross, taxProfile\)/,
    why: 'the return declares zero VAT due again',
  },
  {
    what: 'the desktop VAT return is the shared one',
    where: 'renderer/operations-extras.js',
    needs: /KhaytVatReturn\.boxes\(printLog[\s\S]{0,300}revenueOf: orderNetRevenueBase/,
    why: 'the desktop works the return out on its own again, and the Mac prints a different one',
  },
  {
    what: 'mailto refuses a hidden recipient',
    where: 'main.js',
    needs: /return mailtoHasNoHiddenRecipients\(s\)/,
    why: 'any mailto: is opened again, whatever headers it carries',
  },
];

for (const seam of SEAMS) {
  test(`wired: ${seam.what}`, () => {
    assert.match(code(seam.where), seam.needs, `${seam.where}: ${seam.why}`);
  });
}

test('every new lib module is loaded by both entry documents', () => {
  // A pure module with no script tag is undefined at runtime, and the feature
  // throws on first use. Unit tests cannot see it; only the page can.
  const NEW = ['lib/split-order.js'];
  for (const html of ['renderer/index.html', 'renderer/bedready.html']) {
    const doc = read(html);
    for (const mod of NEW) {
      assert.ok(doc.includes(`src="../${mod}"`), `${html} does not load ${mod}`);
    }
  }
});

test('every locale string added this release exists in all nine locales', () => {
  const NEW_KEYS = [
    'set.backup_failed',
    'store.recovered_prev',
    'sync.overwritten_one',
    'sync.overwritten_many',
  ];
  const dir = path.join(ROOT, 'renderer', 'locales');
  const locales = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  assert.equal(locales.length, 9, 'the locale set changed — update this guard');
  for (const f of locales) {
    const src = read(path.join('renderer', 'locales', f));
    for (const k of NEW_KEYS) {
      assert.ok(src.includes(`"${k}"`), `${f} is missing ${k}`);
    }
  }
});

test('and each of those strings is actually rendered somewhere', () => {
  // A translated string nothing asks for is nine translations of nothing.
  const renderers = fs.readdirSync(path.join(ROOT, 'renderer'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => code(path.join('renderer', f)))
    .join('\n');
  for (const k of ['set.backup_failed', 'store.recovered_prev', 'sync.overwritten_one', 'sync.overwritten_many']) {
    assert.ok(renderers.includes(`'${k}'`) || renderers.includes(`"${k}"`),
      `${k} is translated nine times and asked for nowhere`);
  }
});
