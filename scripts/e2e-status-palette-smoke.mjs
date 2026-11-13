/**
 * E2E smoke — one status palette in every theme (decided Nov 11 2026).
 *
 * Printing is AMBER (thread dot on an amber wash, warn-ink text); done, paid
 * and delivered are GREEN; unpaid and partial are a STEEL chip with amber ink
 * (money still owed is waiting, not late); pending, queued, quote and on-hold
 * are STEEL; RED is for overdue only. Before this, PAID was grey, UNPAID red
 * in seven themes, Printing green on the dashboard and blue on the queue, and
 * invisible in Blueprint dark.
 *
 * Seeds a job in each status and payment state, then for the Khayt and
 * Blueprint designs in light and dark reads the COMPUTED colours of the chips
 * in the order log and on the queue board, and checks each tone and that each
 * chip's text clears 4.5:1 on its own fill.
 *
 * Run: npm run test:e2e:statuspalette
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab, applyDesignTheme } from './e2e/helpers.mjs';

let checks = 0;
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); checks++; };

/* ---------- colour maths ---------- */
function parse(css) {
  const m = String(css).match(/rgba?\(([^)]+)\)/);
  if (!m) return null;
  const [r, g, b, a = 1] = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
  return { r, g, b, a };
}
function hsl({ r, g, b }) {
  const R = r / 255, G = g / 255, B = b / 255;
  const max = Math.max(R, G, B), min = Math.min(R, G, B), d = max - min;
  const l = (max + min) / 2;
  if (d === 0) return { h: 0, s: 0, l };
  const s = d / (1 - Math.abs(2 * l - 1));
  let h;
  if (max === R) h = ((G - B) / d) % 6;
  else if (max === G) h = (B - R) / d + 2;
  else h = (R - G) / d + 4;
  return { h: (h * 60 + 360) % 360, s, l };
}
function lum({ r, g, b }) {
  const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}
function contrast(a, b) {
  const x = lum(a), y = lum(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
const hex = (c) => '#' + [c.r, c.g, c.b].map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');

const TONES = {
  amber: (c) => { const { h, s } = hsl(c); return h >= 25 && h <= 50 && s >= 0.3; },
  green: (c) => { const { h, s } = hsl(c); return h >= 115 && h <= 165 && s >= 0.3; },
  red:   (c) => { const { h, s } = hsl(c); return (h <= 15 || h >= 340) && s >= 0.3; },
  steel: (c) => { const { h, s } = hsl(c); return h >= 195 && h <= 235 && s > 0.05 && s <= 0.35; },
};

function checkChip(where, chip, wantBg, wantInk) {
  ok(chip, `${where}: the chip is on screen`);
  const fg = parse(chip.color), bg = parse(chip.bg);
  ok(fg && bg && bg.a >= 0.99, `${where}: an opaque fill (${chip.bg})`);
  ok(TONES[wantBg](bg), `${where}: fill is ${wantBg} (got ${hex(bg)})`);
  ok(TONES[wantInk](fg), `${where}: text is ${wantInk} (got ${hex(fg)})`);
  const cr = contrast(fg, bg);
  ok(cr >= 4.5, `${where}: text ${hex(fg)} on ${hex(bg)} is ${cr.toFixed(2)}:1 (needs 4.5)`);
}

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  /* ---------- seed one job per status / payment state ---------- */
  await window.evaluate(() => {
    settings.mode = 'professional';
    const today = new Date();
    const iso = (d) => d.toISOString().slice(0, 10);
    const daysAgo = (n) => { const d = new Date(today); d.setDate(d.getDate() - n); return iso(d); };
    const base = { date: iso(today), timestamp: today.toISOString(), material: 'PLA', clientName: 'Sample' };
    const jobs = [
      { id: 'SP-pending',   project: 'SP pending',   status: 'pending',   price: 100, paidAmount: 0 },
      { id: 'SP-printing',  project: 'SP printing',  status: 'printing',  price: 100, paidAmount: 40 },
      { id: 'SP-completed', project: 'SP completed', status: 'completed', price: 100, paidAmount: 100, completedAt: today.toISOString() },
      { id: 'SP-delivered', project: 'SP delivered', status: 'delivered', price: 100, paidAmount: 100, completedAt: today.toISOString(), deliveredAt: today.toISOString() },
      { id: 'SP-quote',     project: 'SP quote',     status: 'quote',     price: 100, paidAmount: 0 },
      { id: 'SP-on_hold',   project: 'SP on_hold',   status: 'on_hold',   price: 100, paidAmount: 0 },
      { id: 'SP-overdue',   project: 'SP overdue',   status: 'pending',   price: 100, paidAmount: 0, dueDate: daysAgo(3) },
    ];
    printLog.length = 0;
    for (const j of jobs) printLog.push({ ...base, ...j });
    if (typeof saveAll === 'function') saveAll();
  });

  const COMBOS = [
    ['khayt', 'light'], ['khayt', 'dark'], ['blueprint', 'light'], ['blueprint', 'dark'],
  ];
  for (const [designId, appearance] of COMBOS) {
    await applyDesignTheme(window, { designId, appearance });
    await window.waitForFunction((a) => document.documentElement.dataset.theme === a, appearance);
    const tag = `${designId}/${appearance}`;
    const before = checks;

    /* ---------- the order log ---------- */
    await switchTab(window, 'logs-tab');
    await window.evaluate(() => { if (typeof clearLogFilters === 'function') clearLogFilters(); renderLogs(); });
    const log = await window.evaluate(() => {
      const read = (el) => {
        if (!el) return null;
        const cs = getComputedStyle(el);
        return { color: cs.color, bg: cs.backgroundColor };
      };
      const rows = {};
      for (const tr of document.querySelectorAll('#logs-tab tbody tr')) {
        const name = tr.querySelector('strong')?.textContent || '';
        if (!name.startsWith('SP ')) continue;
        const status = tr.querySelector('td:nth-child(4) .badge');
        rows[name.slice(3)] = {
          status: read(status), statusClass: status?.className || '',
          pay: read(tr.querySelector('.badge[class*="pay-"]')),
          payClass: tr.querySelector('.badge[class*="pay-"]')?.className || '',
          overdue: read(tr.querySelector('.due-badge.overdue')),
        };
      }
      return rows;
    });
    ok(Object.keys(log).length === 7, `${tag}: all seven sample jobs are in the log (${Object.keys(log).join(', ')})`);
    checkChip(`${tag} log PRINTING`, log.printing.status, 'amber', 'amber');
    checkChip(`${tag} log COMPLETED`, log.completed.status, 'green', 'green');
    checkChip(`${tag} log DELIVERED`, log.delivered.status, 'green', 'green');
    for (const s of ['pending', 'quote', 'on_hold']) checkChip(`${tag} log ${s.toUpperCase()}`, log[s].status, 'steel', 'steel');
    ok(/pay-paid/.test(log.completed.payClass), `${tag}: the completed job reads paid`);
    checkChip(`${tag} log PAID`, log.completed.pay, 'green', 'green');
    ok(/pay-partial/.test(log.printing.payClass), `${tag}: the printing job reads partial`);
    checkChip(`${tag} log PARTIAL`, log.printing.pay, 'steel', 'amber');
    ok(/pay-unpaid/.test(log.pending.payClass), `${tag}: the pending job reads unpaid`);
    checkChip(`${tag} log UNPAID`, log.pending.pay, 'steel', 'amber');
    checkChip(`${tag} log OVERDUE`, log.overdue.overdue, 'red', 'red');

    /* ---------- the queue board ---------- */
    await switchTab(window, 'queue-tab');
    await window.evaluate(() => {
      settings.queueView = 'kanban';
      document.querySelector('.kanban')?.classList.remove('queue-list-mode');
      renderKanban();
    });
    const q = await window.evaluate(() => {
      const dot = (s) => {
        const el = document.querySelector(`.kanban-col[data-status="${s}"] h3 .dot`);
        return el ? getComputedStyle(el).backgroundColor : null;
      };
      const read = (el) => {
        if (!el) return null;
        const cs = getComputedStyle(el);
        return { color: cs.color, bg: cs.backgroundColor };
      };
      const card = (s, sel) => read(document.querySelector(`#list-${s} ${sel}`));
      return {
        dots: { pending: dot('pending'), on_hold: dot('on_hold'), printing: dot('printing'), completed: dot('completed'), delivered: dot('delivered') },
        partial: card('printing', '.badge.pay-partial'),
        unpaid: card('pending', '.badge.pay-unpaid'),
        overdue: card('pending', '.due-badge.overdue'),
      };
    });
    const dotIs = (s, tone) => {
      const c = parse(q.dots[s]);
      ok(c && TONES[tone](c), `${tag} queue: the ${s} column dot is ${tone} (got ${c ? hex(c) : q.dots[s]})`);
    };
    dotIs('printing', 'amber');
    dotIs('pending', 'steel');
    dotIs('on_hold', 'steel');
    dotIs('completed', 'green');
    dotIs('delivered', 'green');
    checkChip(`${tag} queue PARTIAL`, q.partial, 'steel', 'amber');
    checkChip(`${tag} queue UNPAID`, q.unpaid, 'steel', 'amber');
    checkChip(`${tag} queue OVERDUE`, q.overdue, 'red', 'red');

    console.log(`  ✓ ${tag}: ${checks - before} checks`);
  }
  console.log(`\n✅ Status palette smoke: ${checks} checks passed`);
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  try { await electronApp.close(); } catch { /* already closed */ }
}
process.exit(failed ? 1 : 0);
