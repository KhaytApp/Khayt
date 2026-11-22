#!/usr/bin/env node
/**
 * E2E: the update gate, against the notes THIS release actually carries.
 *
 * A release with a `### Before you update` section must stop and hold the
 * download until the shop accepts it. That was asked for in as many words —
 * "the update can only be done if the person accepts the changes" — and until
 * now it had been proved only by unit tests and a hand-built fixture. A fixture
 * is exactly what lied about it once already: I rendered the consent panel
 * outside `.update-modal`, the disabled Download looked clickable, and I spent
 * an hour on a bug that was in my own scaffolding.
 *
 * So this reads CHANGELOG.md, parses it the way the main process does, and
 * drives the real modal in the real app.
 *
 * It passes when there is no section to gate on, too — most releases have none,
 * and that is the point of the gate being rare.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import path from 'path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';
import { sectionFor } from './changelog-section.js';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const require_ = createRequire(import.meta.url);
const { parseMajorChanges } = require_(path.join(ROOT, 'lib/major-changes.js'));

/* WHICH SECTION, AND IN WHICH SHAPE — both were wrong.
 *
 * `Unreleased` is emptied by the cut: the procedure MOVES it under `## [X.Y.Z]`,
 * so on the release commit — the only commit that is tagged and shipped — this
 * read an empty section, took its "nothing to gate" branch, and passed
 * trivially. It proved the gate for a version that is never released.
 *
 * The version in package.json is what a build ships, so that is read first and
 * `Unreleased` is the fallback for ordinary development.
 *
 * And the app never sees markdown. electron-updater reads the GitHub release
 * atom feed, which carries RENDERED HTML — the shape in which a multi-line item
 * used to vanish entirely. Both are put through the modal, and both must agree,
 * so a change that reads correctly here and not in production fails HERE. */
const changelog = fs.readFileSync(path.join(ROOT, 'CHANGELOG.md'), 'utf8');
const shipping = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version;
const notes = sectionFor(changelog, shipping) || sectionFor(changelog, 'Unreleased');
const source = sectionFor(changelog, shipping) ? shipping : 'Unreleased';

/** Roughly what GitHub serves for a markdown section, which is what the app gets. */
function asRendered(md) {
  const out = [];
  for (const line of String(md).split(/\r?\n/)) {
    const bullet = line.match(/^- (.*)$/);
    if (bullet) { out.push('<li>', bullet[1]); continue; }
    if (/^#{1,6} /.test(line)) { out.push(line.replace(/^#{1,6} (.*)$/, '<h3>$1</h3>')); continue; }
    out.push(line.replace(/^\s+/, ''));       // list indentation is consumed
  }
  return out.join('\n').replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
}

const major = parseMajorChanges(notes);
const asShipped = parseMajorChanges(asRendered(notes));

/* THE SECTION THE NEXT CUT WILL SHIP IS THE ONE NOBODY CHECKS.
 *
 * `notes` is the section matching package.json's version — the last RELEASED
 * one. That is right for a regression guard and blind to the release about to
 * happen: a malformed "Before you update" in [Unreleased] is found the day
 * after the cut, by the shop, on the update it was written to warn them about.
 *
 * So the markdown/rendered agreement is checked on [Unreleased] too, whenever
 * it exists and is not simply the same section. Nothing else about it is
 * asserted — how many items it has is the author's business; whether the app
 * would read the same number as the file is not. */
const pending = source === 'Unreleased' ? null : sectionFor(changelog, 'Unreleased');
const pendingMd = pending ? parseMajorChanges(pending) : null;
const pendingHtml = pending ? parseMajorChanges(asRendered(pending)) : null;

const userData = makeUserDataDir();
let app;
let failed = 0;
const ok = (cond, msg) => { if (!cond) failed++; console.log(`  ${cond ? '✓' : '✗'} ${msg}`); };
/* THE SUMMARY LINE HAS TO KNOW WHETHER ANYTHING FAILED.
 *
 * It did not: this printed "e2e-update-consent: ok (…)" at the end whatever the
 * assertions had said, so every caller that greps for that line — me, and the
 * CI step that only shows the tail — read a green result off a red run. Found
 * by mutation: the gate was broken three different ways and the script still
 * said ok. The process exit code was right the whole time and nobody was
 * reading it, which is its own lesson. */
const say = (what) => {
  if (failed) console.log(`\ne2e-update-consent: FAILED — ${failed} assertion(s), ${what}`);
  else console.log(`\ne2e-update-consent: ok (${what})`);
};

/* The button lookup is written out at each site rather than passed in as a
 * string to eval. The app's CSP is `script-src 'self'` with no 'unsafe-eval',
 * so source cannot be smuggled into the page — which is the app being properly
 * locked down, and not worth weakening for a test. */

try {
  ({ electronApp: app } = await launchApp(userData));
  const w = await app.firstWindow();
  w.setDefaultTimeout(120_000);
  await dismissWizard(w);

  const state = await w.evaluate(async ([releaseNotes, m]) => {
    const info = { version: '9.9.9-e2e', releaseNotes, majorChanges: m };
    await window.KhaytUpdateUI.showUpdateChangesModal(info, { currentVersion: '0.0.1' });
    await new Promise((r) => setTimeout(r, 600));
    const btn = document.querySelector('[data-act="upd-download"]')
      || [...document.querySelectorAll('.update-modal button')].find((b) => /download/i.test(b.textContent));
    return {
      modalOpen: !!document.querySelector('.update-modal'),
      gateShown: !!document.querySelector('.update-consent'),
      items: [...document.querySelectorAll('.update-consent-list li')].map((li) => li.textContent.trim()),
      btnFound: !!btn,
      btnDisabled: btn ? btn.disabled : null,
      btnOpacity: btn ? getComputedStyle(btn).opacity : null,
      // Nothing in the panel may arrive as live markup.
      htmlInPanel: (document.querySelector('.update-consent')?.querySelectorAll('script, img, iframe, a').length) || 0,
    };
  }, [notes, major]);

  ok(state.modalOpen, 'the update modal opens');
  /* The one that would have caught the real bug: the markdown we write and the
   * page GitHub serves have to yield the same gate. They did not — every
   * multi-line item was dropped from the rendered form, and this release's items
   * are all multi-line, so the gate simply would not have appeared. */
  ok(asShipped.needsConsent === major.needsConsent,
    `markdown says needsConsent=${major.needsConsent} and the rendered page says `
    + `${asShipped.needsConsent} — production reads the rendered one`);
  ok(asShipped.items.length === major.items.length,
    `markdown yields ${major.items.length} item(s), the rendered page ${asShipped.items.length}`);

  if (pending) {
    ok(pendingMd.needsConsent === pendingHtml.needsConsent,
      `[Unreleased] (the next cut): markdown says needsConsent=${pendingMd.needsConsent}, `
      + `the rendered page ${pendingHtml.needsConsent}`);
    ok(pendingMd.items.length === pendingHtml.items.length,
      `[Unreleased] (the next cut): markdown yields ${pendingMd.items.length} item(s), `
      + `the rendered page ${pendingHtml.items.length}`);
  }

  if (!major.needsConsent) {
    ok(!state.gateShown, 'no gate for a release with nothing to accept');
    ok(state.btnFound && state.btnDisabled === false, 'and the download is available straight away');
    say(`no "Before you update" section in [${source}] — nothing to gate`);
  } else {
    ok(state.gateShown, 'the gate is shown');
    ok(state.items.length === major.items.length,
      `every parsed item is on screen (${state.items.length} of ${major.items.length})`);
    ok(state.htmlInPanel === 0, 'the notes are rendered as text, not as markup');
    ok(state.btnFound, 'the download control exists');
    ok(state.btnDisabled === true, 'the download is DISABLED until the box is ticked');
    ok(Number(state.btnOpacity) < 0.9, 'and it looks unavailable rather than merely being inert');

    const after = await w.evaluate(async () => {
      const a = document.getElementById('updAccept');
      a.checked = true; a.dispatchEvent(new Event('change', { bubbles: true }));
      await new Promise((r) => setTimeout(r, 200));
      const btn = document.querySelector('[data-act="upd-download"]')
        || [...document.querySelectorAll('.update-modal button')].find((b) => /download/i.test(b.textContent));
      return { disabled: btn.disabled, opacity: getComputedStyle(btn).opacity };
    });
    ok(after.disabled === false, 'ticking the box releases the download');
    ok(Number(after.opacity) > 0.9, 'and it looks available');

    const back = await w.evaluate(async () => {
      const a = document.getElementById('updAccept');
      a.checked = false; a.dispatchEvent(new Event('change', { bubbles: true }));
      await new Promise((r) => setTimeout(r, 200));
      const btn = document.querySelector('[data-act="upd-download"]')
        || [...document.querySelectorAll('.update-modal button')].find((b) => /download/i.test(b.textContent));
      return btn.disabled;
    });
    ok(back === true, 'unticking holds it again — the gate is not a one-way latch');

    say(`${major.items.length} item(s) from [${source}] gated, held until accepted`);
  }
} catch (e) {
  failed++;
  console.error('\n' + (e && e.message ? e.message : e));
} finally {
  if (app) await app.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}
