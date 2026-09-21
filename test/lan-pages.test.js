'use strict';
/**
 * What the phone is shown, held to what the Node server has always shown.
 *
 * `lib/lan-pages.js` exists so the Mac app can serve the SAME bytes as the
 * Node server. The proof is the usual one: the five original route bodies
 * are copied here verbatim from renderer-era lan-server.js (the clock handed
 * in, `res` writes turned into return values, nothing else changed) and run
 * beside the module over generated books.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const LanAuth = require('../lib/lan-auth.js');
const P = require('../lib/lan-pages.js');
const lanEscapeHtml = LanAuth.lanEscapeHtml;

/* ── ORIGINALS, from lib/lan-server.js before the lift ─────────────────────── */
function originalStatus(store, today) {
  const queue = (store.printLog || []).filter(o => o.status !== 'completed' && o.status !== 'delivered');
  const waitingActive = (store.waitingList || []).filter(w => w.status !== 'declined').length;
  return {
    queued: queue.length,
    pending:    queue.filter(o => o.status === 'pending').length,
    printing:   queue.filter(o => o.status === 'printing').length,
    post:       queue.filter(o => o.status === 'post').length,
    qc:         queue.filter(o => o.status === 'qc').length,
    completed_today: (store.printLog || []).filter(o => o.completedAt &&
      o.completedAt.startsWith(today)).length,
    waiting: waitingActive
  };
}
function originalQueue(store) {
  const queue = (store.printLog || []).filter(o =>
    ['pending','printing','post','qc'].includes(o.status));
  return queue.map(o => ({
    id: o.id, project: o.project, client: o.client, status: o.status,
    machine: o.machine, machineId: o.machineId || null,
    dueDate: o.dueDate, priority: o.priority
  }));
}
function originalManifest(store) {
  const shopName = store.settings?.shopName || 'Khayt';
  return {
    name: shopName + ' Queue',
    short_name: shopName,
    start_url: '/',
    display: 'standalone',
    background_color: '#0A2A51',
    theme_color: '#E06010',
    icons: [
      { src: '/icon-192.png', sizes: '192x192', type: 'image/png' },
      { src: '/icon-512.png', sizes: '512x512', type: 'image/png' },
      { src: '/icon-maskable-512.png', sizes: '512x512', type: 'image/png',
        purpose: 'maskable' }
    ]
  };
}
const originalServiceWorker = `const CACHE='khayt-v1';
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['/']))));
self.addEventListener('fetch',e=>e.respondWith(fetch(e.request).catch(()=>caches.match(e.request))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));`;
function originalQueuePage(store, now) {
          const shopName = lanEscapeHtml(store.settings?.shopName || 'Khayt');
          const queue = (store.printLog || []).filter(o => ['pending','printing','post','qc','on_hold'].includes(o.status));
          const pending  = queue.filter(o => o.status === 'pending').length;
          const printing = queue.filter(o => o.status === 'printing').length;
          const post     = queue.filter(o => o.status === 'post').length;
          const qc       = queue.filter(o => o.status === 'qc').length;
          const onHold   = queue.filter(o => o.status === 'on_hold').length;
          const badgeMap = { pending:'#374151|#d1d5db', printing:'#1d4ed8|#bfdbfe', post:'#065f46|#a7f3d0', qc:'#7c3aed|#ddd6fe', on_hold:'#92400e|#fde68a' };
          const orderCards = queue.slice(0, 30).map(o => {
            const [bg, fg] = (badgeMap[o.status] || '#374151|#d1d5db').split('|');
            return `<div class="oc"><div><div class="on">${lanEscapeHtml(o.project || o.id)}</div><div class="cl">${lanEscapeHtml(o.client || '')}</div></div><span class="bd" style="background:${bg};color:${fg}">${lanEscapeHtml(o.status)}</span></div>`;
          }).join('') || '<div class="empty">No active orders</div>';
          const html = `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-touch-icon" href="/icon-192.png">
<meta name="theme-color" content="#6366f1">
<link rel="manifest" href="/manifest.json">
<title>${shopName} Queue</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,system-ui,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:16px;max-width:480px;margin:0 auto}
h1{font-size:20px;color:#6366f1;margin-bottom:2px}
.sub{font-size:12px;color:#64748b;margin-bottom:18px;display:flex;align-items:center;gap:6px}
.dot{width:7px;height:7px;border-radius:50%;background:#22c55e;animation:pulse 2s infinite;display:inline-block}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.stats{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-bottom:18px}
.sc{background:#1e293b;border-radius:10px;padding:12px 14px}
.sn{font-size:26px;font-weight:700}
.sl{font-size:11px;color:#64748b;margin-top:2px}
.oc{background:#1e293b;border-radius:10px;padding:11px 14px;margin-bottom:7px;display:flex;justify-content:space-between;align-items:center;gap:10px}
.on{font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:200px}
.cl{font-size:11px;color:#94a3b8;margin-top:2px}
.bd{padding:3px 9px;border-radius:20px;font-size:11px;font-weight:600;white-space:nowrap}
.empty{text-align:center;padding:32px 20px;color:#475569;font-size:13px}
.rf{text-align:center;font-size:11px;color:#475569;margin-top:14px}
.hdr{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:18px}
</style></head><body>
<div class="hdr"><div><h1>${shopName}</h1><div class="sub"><span class="dot"></span>Live Queue</div></div></div>
<div class="stats">
<div class="sc"><div class="sn">${pending}</div><div class="sl">Pending</div></div>
<div class="sc"><div class="sn">${printing}</div><div class="sl">Printing</div></div>
<div class="sc"><div class="sn">${post}</div><div class="sl">Post-Processing</div></div>
<div class="sc"><div class="sn">${qc + onHold}</div><div class="sl">QC / On Hold</div></div>
</div>
${orderCards}
<div class="rf">Auto-refreshes every 30s &middot; Updated ${now}</div>
<script>
if('serviceWorker' in navigator){navigator.serviceWorker.register('/sw.js').catch(()=>{})}
setTimeout(()=>location.reload(),30000);
</script>
</body></html>`;
          return html;
}

/* ── Generated books ──────────────────────────────────────────────────────── */
function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
const STATUSES = ['quote', 'pending', 'printing', 'post', 'qc', 'on_hold', 'completed', 'delivered', 'cancelled'];
const NAMES = ['Bracket', 'Lid <b>x</b>', 'مقبض', '', 'Vase & jar', 'Turbine "A"'];
function book(seed) {
  const r = rng(seed);
  const pick = (l) => l[Math.floor(r() * l.length)];
  const printLog = Array.from({ length: Math.floor(r() * 40) }, (_, i) => ({
    id: 'O' + i, project: pick(NAMES), client: pick(NAMES), status: pick(STATUSES),
    machine: pick(['X1C', undefined]), machineId: pick(['M1', undefined, null]),
    dueDate: pick(['2026-09-20', undefined]), priority: pick([true, false, undefined]),
    completedAt: pick(['2026-09-16T09:00:00Z', '2026-09-15T09:00:00Z', undefined]),
  }));
  const waitingList = Array.from({ length: Math.floor(r() * 5) }, () => ({ status: pick(['waiting', 'declined', 'called']) }));
  const settings = r() < 0.7 ? { shopName: pick(['Tuwaiq <Additive>', 'خيط', 'Khayt & Co']) } : {};
  return { printLog, waitingList, settings };
}

test('the status, queue, manifest, service worker and queue page are the originals, byte for byte', () => {
  for (let seed = 1; seed <= 400; seed++) {
    const b = book(seed);
    assert.deepEqual(P.statusJson(b, '2026-09-16'), originalStatus(b, '2026-09-16'), `seed ${seed} status`);
    assert.equal(JSON.stringify(P.statusJson(b, '2026-09-16')), JSON.stringify(originalStatus(b, '2026-09-16')), `seed ${seed} status bytes`);
    assert.equal(JSON.stringify(P.queueJson(b)), JSON.stringify(originalQueue(b)), `seed ${seed} queue`);
    assert.equal(JSON.stringify(P.manifest(b)), JSON.stringify(originalManifest(b)), `seed ${seed} manifest`);
    assert.equal(P.queuePage(b, { now: '09:16 AM' }), originalQueuePage(b, '09:16 AM'), `seed ${seed} page`);
  }
  assert.equal(P.serviceWorker(), originalServiceWorker);
});

test('a book with nothing in it renders, and says so', () => {
  const page = P.queuePage({}, { now: '' });
  assert.match(page, /No active orders/);
  assert.match(page, /<title>Khayt Queue<\/title>/);
  assert.deepEqual(P.statusJson({}, '2026-09-16'), { queued: 0, pending: 0, printing: 0, post: 0, qc: 0, completed_today: 0, waiting: 0 });
  assert.deepEqual(P.queueJson(undefined), []);
});

test('what a customer typed is escaped on the page, and never trusted', () => {
  const page = P.queuePage({ printLog: [{ id: 'O1', project: '<script>alert(1)</script>', client: '"quoted"', status: 'pending' }] }, { now: '' });
  assert.doesNotMatch(page, /<script>alert/);
  assert.match(page, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(page, /&quot;quoted&quot;/);
});

test('the four security headers are the server\'s own', () => {
  assert.deepEqual(Object.keys(P.SECURITY_HEADERS).sort(),
    ['Content-Security-Policy', 'Referrer-Policy', 'X-Content-Type-Options', 'X-Frame-Options']);
  assert.equal(P.SECURITY_HEADERS['X-Frame-Options'], 'DENY');
});

// ── THE 404 SPEAKS FOR ITS OWN HOST ────────────────────────────────────────
//
// The endpoint list is the NODE server's. The native Mac app serves a subset,
// and reciting this list from there advertised eleven routes that answer 404
// on that host — five owner-data APIs and six integration webhooks, to a
// caller who has shown no PIN. The 404 runs before any gate, so mistyping a
// path told a stranger on the shop's Wi-Fi which storefront and which courier
// the shop is wired to.

test('notFound answers for the host that asked', () => {
  const mine = ['/api/status', '/intake'];
  assert.deepEqual(P.notFound(mine).endpoints, mine);
  // Called with nothing it is the Node server's own list, which is the caller
  // that has always been right about this.
  assert.deepEqual(P.notFound().endpoints, P.NODE_ENDPOINTS);
  assert.ok(P.NODE_ENDPOINTS.includes('/api/clients'));
});

test('an empty or nonsense list is the Node list, never an empty 404', () => {
  // A 404 that lists nothing is worse than one that lists too much: it reads
  // as "there is nothing here" on a server that is running and serving.
  for (const bad of [[], null, undefined, 'clients', [''], [null, 0]]) {
    assert.deepEqual(P.notFound(bad).endpoints, P.NODE_ENDPOINTS,
                     `notFound(${JSON.stringify(bad)}) should fall back`);
  }
});

test('the error line is unchanged, whoever is asking', () => {
  assert.equal(P.notFound(['/a']).error, 'Not found');
  assert.equal(P.notFound().error, 'Not found');
});
