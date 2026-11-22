#!/usr/bin/env node
/**
 * E2E: the organisation overview's money and late lines, in the real renderer.
 *
 * These are the only place the app puts a CHAIN-WIDE money figure in front of an
 * owner, and the three ways they can be wrong are all invisible to a unit test:
 *
 *  1. **Scope.** `renderer/settings.js` is an IIFE, so `localDateStr` and
 *     `fmtMoneyIn` resolve through the global at call time. A Node test that
 *     stubs them proves nothing about whether they are reachable in the app; if
 *     they are not, the overview throws the moment it is opened.
 *  2. **Currency labelling.** A branch's figures are in THAT branch's base
 *     currency. Formatting them with the reader's symbol would read as a
 *     conversion that never happened.
 *  3. **The refusal.** Branches on different bases are deliberately not totalled
 *     — see totalMoney in lib/branch-summary.js. What must never happen is a
 *     number appearing next to that explanation anyway.
 *
 * Requires a display (xvfb-run -a on CI).
 */
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  const out = await window.evaluate(() => {
    const S = window.KhaytSettings || {};
    const strip = (h) => String(h).replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
    return {
      missing: ['orgLateLine', 'orgMoneyLine', 'orgTotalMoneyLine'].filter((k) => typeof S[k] !== 'function'),
      reachable: {
        localDateStr: typeof localDateStr,
        fmtMoneyIn: typeof fmtMoneyIn,
        today: typeof localDateStr === 'function' ? localDateStr() : null,
      },
      branchSar: strip(S.orgMoneyLine({ currency: 'SAR', revenue: 48250, outstanding: 3200 })),
      branchUsd: strip(S.orgMoneyLine({ currency: 'USD', revenue: 5300, outstanding: 0 })),
      branchNone: S.orgMoneyLine(null),
      late: strip(S.orgLateLine({ overdue: 2, dueToday: 1 })),
      lateNone: S.orgLateLine({ overdue: 0, dueToday: 0 }),
      lateUnknown: S.orgLateLine({}),
      total: strip(S.orgTotalMoneyLine({ mixed: false, currency: 'SAR', revenue: 68150, outstanding: 3200 })),
      totalPartial: strip(S.orgTotalMoneyLine({ mixed: false, currency: 'SAR', revenue: 100, outstanding: 0, partial: true })),
      totalMixed: strip(S.orgTotalMoneyLine({ mixed: true, currencies: ['SAR', 'USD'] })),
    };
  });

  console.log(JSON.stringify(out, null, 2));
  const fail = (m) => { throw new Error(m); };

  if (out.missing.length) fail(`the overview's line builders are not exported: ${out.missing.join(', ')}`);

  // (1) scope
  if (out.reachable.localDateStr !== 'function') fail('localDateStr is not reachable from settings.js — the overview would throw on open');
  if (out.reachable.fmtMoneyIn !== 'function') fail('fmtMoneyIn is not reachable from settings.js');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(out.reachable.today))) fail(`the day sent to the main process is malformed: ${out.reachable.today}`);

  // (2) currency labelling
  if (!out.branchSar.includes('SAR')) fail(`a SAR branch must be labelled SAR: ${out.branchSar}`);
  if (!out.branchUsd.includes('$')) fail(`a USD branch must not wear the reader's currency: ${out.branchUsd}`);
  if (out.branchNone !== '') fail('a branch whose money could not be read must render nothing, not a zero');

  // Late lines are claims, so they appear only when there is something to claim.
  if (out.lateNone !== '' || out.lateUnknown !== '') fail('a late line appeared with nothing late');
  if (!/2 .*1 /.test(out.late)) fail(`the late line lost a number: ${out.late}`);

  // (3) the refusal
  if (!/sar,\s*usd/i.test(out.totalMixed)) fail(`the mixed-currency refusal must name the currencies: ${out.totalMixed}`);
  if (/\d/.test(out.totalMixed.replace(/SAR|USD/g, ''))) fail(`the mixed-currency refusal showed a number: ${out.totalMixed}`);
  if (!/68150|68,150/.test(out.total)) fail(`the single-currency total is missing its figure: ${out.total}`);
  if (out.totalPartial === out.total) fail('a partial total must say so');

  console.log('✅ the overview reports each branch in its own currency, and refuses to total across two');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
}
