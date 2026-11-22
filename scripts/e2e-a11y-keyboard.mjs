/**
 * E2E — a modal is usable without a mouse.
 *
 * Four things have to hold together, and each fails silently on its own:
 *
 *   1. Opening a modal moves focus INTO it. Without this a keyboard user is left
 *      on the page behind, and — because the focus trap listens on the modal
 *      root rather than the document — Tab never reaches the trap either. The
 *      modal is visible and unreachable.
 *   2. Tab stays inside. Otherwise focus walks the page behind an overlay the
 *      user cannot see past.
 *   3. Escape closes it. Escape is bound on `document` through a stack, so it
 *      works wherever focus is and nested modals close top-first.
 *   4. Closing gives focus back to whatever opened it, or the user is dumped at
 *      the top of the document with no idea where they were.
 *
 * All four work today. None of them was tested, and all four are the kind of
 * thing a refactor removes without any visible symptom for anyone using a mouse.
 *
 * This was written after a static read concluded the opposite — that nothing
 * focused the modal — which running the app immediately disproved. Hence an e2e
 * rather than a source scan: focus is a runtime property.
 *
 * Run: npm run test:e2e:a11y
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-a11y-'));
let app;
let failed = false;
try {
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`], cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_USER_DATA: userData },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  await page.waitForSelector('.khayt-app', { timeout: 60_000 });
  await page.waitForFunction(
    () => (document.querySelector('#dashboardContent')?.innerHTML?.length || 0) > 100,
    { timeout: 60_000 },
  );

  const state = () => page.evaluate(() => {
    const a = document.activeElement;
    const modal = document.querySelector('.modal');
    return {
      modalOpen: !!modal,
      activeId: a ? a.id : '',
      activeTag: a ? a.tagName.toLowerCase() : 'none',
      insideModal: !!(modal && a && modal.contains(a)),
      focusables: modal
        ? modal.querySelectorAll('button,input,select,textarea,a[href],[tabindex]:not([tabindex="-1"])').length
        : 0,
    };
  });

  // Give the opener a known, focusable identity so "focus came back" is provable
  // rather than merely "focus is somewhere outside the modal".
  await page.evaluate(() => {
    const b = document.createElement('button');
    b.id = 'a11yOpener';
    b.textContent = 'open';
    document.body.appendChild(b);
    b.focus();
  });
  ok((await state()).activeId === 'a11yOpener', 'a known control holds focus before the modal opens');

  await page.evaluate(() => {
    openFormModal({
      title: 'Keyboard probe',
      bodyHtml: '<label>One</label><input id="probeA"><label>Two</label><input id="probeB">',
      onSave() { return true; },
    });
  });
  await page.waitForTimeout(300);

  let s = await state();
  ok(s.modalOpen, 'the modal opened');
  ok(s.focusables >= 3, `the modal has focusable controls (found ${s.focusables})`);
  ok(s.insideModal, `opening a modal moves focus into it (focus is on ${s.activeTag}#${s.activeId})`);

  // Tab further than the modal holds, so a missing trap escapes into the page.
  for (let i = 0; i < s.focusables + 2; i++) {
    await page.keyboard.press('Tab');
    await page.waitForTimeout(50);
    const t = await state();
    ok(t.insideModal, `Tab #${i + 1} stays inside the modal (on ${t.activeTag}#${t.activeId})`);
  }

  // Shift+Tab off the front must wrap to the end, not leave.
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press('Shift+Tab');
    await page.waitForTimeout(50);
  }
  ok((await state()).insideModal, 'Shift+Tab wraps backwards inside the modal too');

  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);
  s = await state();
  ok(!s.modalOpen, 'Escape closes the modal');
  ok(s.activeId === 'a11yOpener', `closing returns focus to whatever opened it (focus is on #${s.activeId})`);

  /* A DISABLED CONTROL HAS TO LOOK DISABLED.
   *
   * Measured, because this is exactly the thing eyes slide over: a disabled
   * `.btn` came back `opacity: 1; cursor: pointer` — pixel-identical to a
   * working one, with the pointer still promising it would do something.
   * Everywhere except the update gate, which had its own rule and a comment
   * saying why.
   *
   * Asserted against the LIVE computed style rather than the stylesheet's text,
   * because what matters is what a later, more specific rule leaves standing. */
  const look = await page.evaluate(() => {
    const host = document.createElement('div');
    host.style.position = 'fixed'; host.style.left = '-9999px';
    host.innerHTML = '<button class="btn primary">x</button><button class="btn primary" disabled>x</button>'
      + '<button class="btn">y</button><button class="btn" disabled>y</button>'
      + '<button class="btn ghost">z</button><button class="btn ghost" disabled>z</button>';
    document.body.appendChild(host);
    const read = (el) => { const c = getComputedStyle(el); return { opacity: c.opacity, cursor: c.cursor }; };
    const out = [...host.children].map(read);
    host.remove();
    return out;
  });
  for (let i = 1; i < look.length; i += 2) {
    const off = look[i];
    ok(Number(off.opacity) < 0.9, `a disabled button is dimmed (variant ${(i - 1) / 2 + 1}: opacity ${off.opacity})`);
    ok(off.cursor !== 'pointer', `a disabled button does not offer a pointer (variant ${(i - 1) / 2 + 1}: ${off.cursor})`);
  }

  console.log('\n✅ Keyboard a11y smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + (e && e.message ? e.message : e));
} finally {
  if (app) await app.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}
