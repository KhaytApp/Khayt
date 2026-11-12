/**
 * E2E smoke — primary buttons are readable in light and dark, and every typed
 * field has the one field style (Windows/Linux).
 *
 * applyAccent() wrote the light accent preset inline on <html>, which beat
 * each design's dark lift, so dark mode drew navy text on a mid blue
 * (about 2.5:1) on every primary button, and Blueprint dark lost its PRINTING
 * pill and tags. And date, password and URL inputs were missing from the
 * field rule: 150 px browser boxes, 22 px tall, white in dark mode. Here, for
 * Khayt and Blueprint, light and dark:
 *   - every visible .btn.primary has text at WCAG AA (4.5:1) on its fill;
 *   - the preset's hue still applies in dark (the accent is the shop's);
 *   - a date, a password and a URL field are as tall as a text field and
 *     fill their column.
 *
 * Run: npm run test:e2e:darkcontrast
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    clients.push({ id: 'CLI-dc', nameEn: 'Amal', createdAt: '2026-01-01' });
    printLog.push({ id: 'J-dc', project: 'Cup', clientId: 'CLI-dc', status: 'printing', price: 90, paidAmount: 30, date: '2026-11-01', parts: [] });
    saveAll();
  });

  const audit = () => window.evaluate(() => {
    const lum = (c) => { const m = c.match(/[\d.]+/g).map(Number); const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(m[0]) + 0.7152 * f(m[1]) + 0.0722 * f(m[2]); };
    const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
    const btns = [...document.querySelectorAll('.btn.primary')].filter((b) => b.offsetParent && b.textContent.trim());
    return btns.map((b) => { const cs = getComputedStyle(b); return { t: b.textContent.trim().slice(0, 24), r: Math.round(ratio(cs.color, cs.backgroundColor) * 10) / 10 }; });
  });

  for (const design of ['khayt', 'blueprint']) {
    for (const dark of [false, true]) {
      await window.evaluate(([d, dk]) => {
        settings.designTheme = d; applyDesignTheme(d); applyTheme(dk ? 'dark' : 'light');
        const m = document.getElementById('modalMount'); if (m) m.innerHTML = '';
        switchTab('clients-tab');
      }, [design, dark]);
      await window.waitForTimeout(300);
      await window.evaluate(() => openPaymentModal('J-dc'));
      await window.waitForSelector('#modalMount .btn.primary', { timeout: 10000 });
      const rows = await audit();
      const worst = rows.reduce((a, b) => (b.r < a.r ? b : a), { r: 99 });
      ok(rows.length >= 2 && worst.r >= 4.5, `${design} ${dark ? 'dark' : 'light'}: ${rows.length} primary buttons, the lowest at ${worst.r}:1 (${worst.t})`);
      if (dark) {
        const h = await window.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--accent-h').trim());
        const want = await window.evaluate((d) => String(KhaytThemeRegistry.accentsForTheme(d)[KhaytThemeRegistry.defaultAccentForTheme(d)].h), design);
        ok(h === want, `${design} dark keeps the preset's hue (${h})`);
      }
    }
  }

  // Fields: date (payment dialog), password and URL (built here so the check
  // does not depend on which settings pane holds them this week).
  await window.evaluate(() => { applyTheme('dark'); });
  const f = await window.evaluate(() => {
    const box = document.querySelector('#modalMount .modal-body, #modalMount .modal') || document.body;
    const mk = (type) => { const w = document.createElement('div'); w.style.width = '300px'; const i = document.createElement('input'); i.type = type; w.appendChild(i); box.appendChild(w); return i; };
    const els = { text: mk('text'), date: box.querySelector('input[type="date"]') || mk('date'), password: mk('password'), url: mk('url') };
    const out = {};
    for (const [k, el] of Object.entries(els)) { const r = el.getBoundingClientRect(); out[k] = { h: Math.round(r.height), w: Math.round(r.width), bg: getComputedStyle(el).backgroundColor }; }
    out.scheme = getComputedStyle(document.documentElement).colorScheme;
    return out;
  });
  for (const k of ['date', 'password', 'url']) {
    ok(Math.abs(f[k].h - f.text.h) <= 2, `a ${k} field is as tall as a text field (${f[k].h} vs ${f.text.h})`);
    ok(f[k].bg === f.text.bg, `and drawn on the same fill in dark (${f[k].bg})`);
  }
  ok(f.password.w >= 290 && f.url.w >= 290, `password and URL fields fill their column (${f.password.w}, ${f.url.w})`);
  ok(f.scheme === 'dark', `native control parts follow dark mode (color-scheme: ${f.scheme})`);

  console.log('e2e-dark-contrast: ok');
} catch (err) {
  failed = true;
  console.error('e2e-dark-contrast FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
