'use strict';

/**
 * What the phone is shown: the pages and the JSON the LAN server serves for
 * the shop floor — the live queue page, the status and queue APIs, and the
 * three files that make the queue installable on a home screen.
 *
 * Lifted out of `lib/lan-server.js`, where each lived inside its route
 * handler beside Node's `http`, so that a second host — the native Mac app,
 * which has no Node — can serve the SAME bytes. The Node server draws from
 * this module now; `test/lan-pages.test.js` holds the module to the original
 * handlers, copied verbatim, over generated books. Byte-identical is the
 * point: a phone that gets a slightly different page from the Mac than from
 * the PC is a phone whose shop cannot tell which one is wrong.
 *
 * PURE. The clock is handed in — `today` as the shop's local day, `now` as a
 * formatted time — because a page that asked the clock itself would render
 * differently on the two sides of a test. Escaping is `lan-auth`'s, the one
 * the server has always used.
 */
(function (global) {

  const LanAuth = global.KhaytLanAuth
    || (typeof require === 'function' ? require('./lan-auth.js') : null);
  const esc = (s) => LanAuth.lanEscapeHtml(s);
  const listOf = (v) => (Array.isArray(v) ? v : []);

  /** `/api/status?format=json` — the counters a status widget wants. */
  function statusJson(store, today) {
    const s = store || {};
    const queue = listOf(s.printLog).filter(o => o.status !== 'completed' && o.status !== 'delivered');
    const waitingActive = listOf(s.waitingList).filter(w => w.status !== 'declined').length;
    return {
      queued: queue.length,
      pending:    queue.filter(o => o.status === 'pending').length,
      printing:   queue.filter(o => o.status === 'printing').length,
      post:       queue.filter(o => o.status === 'post').length,
      qc:         queue.filter(o => o.status === 'qc').length,
      completed_today: listOf(s.printLog).filter(o => o.completedAt &&
        o.completedAt.startsWith(today)).length,
      waiting: waitingActive,
    };
  }

  /** `/api/queue` — the live work, with the names on it (owner data, PIN-gated). */
  function queueJson(store) {
    const s = store || {};
    const queue = listOf(s.printLog).filter(o =>
      ['pending','printing','post','qc'].includes(o.status));
    return queue.map(o => ({
      id: o.id, project: o.project, client: o.client, status: o.status,
      machine: o.machine, machineId: o.machineId || null,
      dueDate: o.dueDate, priority: o.priority,
    }));
  }

  /** `/manifest.json` — what makes the queue page installable. */
  function manifest(store) {
    const s = store || {};
    const shopName = (s.settings && s.settings.shopName) || 'Khayt';
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
          purpose: 'maskable' },
      ],
    };
  }

  /** `/sw.js` — cache the shell, serve the network first. */
  function serviceWorker() {
    return `const CACHE='khayt-v1';
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['/']))));
self.addEventListener('fetch',e=>e.respondWith(fetch(e.request).catch(()=>caches.match(e.request))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));`;
  }

  /**
   * `/` — the live queue, for a phone on the shop's Wi‑Fi.
   * @param opts.now  the time as the page should print it ("09:16 AM").
   */
  function queuePage(store, opts) {
    const s = store || {};
    const now = (opts && opts.now) || '';
    const shopName = esc((s.settings && s.settings.shopName) || 'Khayt');
    const queue = listOf(s.printLog).filter(o => ['pending','printing','post','qc','on_hold'].includes(o.status));
    const pending  = queue.filter(o => o.status === 'pending').length;
    const printing = queue.filter(o => o.status === 'printing').length;
    const post     = queue.filter(o => o.status === 'post').length;
    const qc       = queue.filter(o => o.status === 'qc').length;
    const onHold   = queue.filter(o => o.status === 'on_hold').length;
    const badgeMap = { pending:'#374151|#d1d5db', printing:'#1d4ed8|#bfdbfe', post:'#065f46|#a7f3d0', qc:'#7c3aed|#ddd6fe', on_hold:'#92400e|#fde68a' };
    const orderCards = queue.slice(0, 30).map(o => {
      const [bg, fg] = (badgeMap[o.status] || '#374151|#d1d5db').split('|');
      return `<div class="oc"><div><div class="on">${esc(o.project || o.id)}</div><div class="cl">${esc(o.client || '')}</div></div><span class="bd" style="background:${bg};color:${fg}">${esc(o.status)}</span></div>`;
    }).join('') || '<div class="empty">No active orders</div>';
    return `<!DOCTYPE html><html lang="en"><head>
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
  }

  /** The 404 body: what IS here, for whoever typed the wrong thing. */
  function notFound() {
    return { error: 'Not found', endpoints: ['/api/status','/api/orders','/api/queue','/api/machines','/api/inventory','/api/waiting-list','/api/clients','/api/webhook/printer/:machineId','/calendar.ics','/intake','/api/intake','/api/intake/estimate','/api/webhook/salla','/api/webhook/zid','/api/webhook/smsa','/api/webhook/aramex','/api/webhook/spl'] };
  }

  /** The four headers every response carries, JSON included — see lan-server.js. */
  const SECURITY_HEADERS = {
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'",
  };

  const api = { statusJson, queueJson, manifest, serviceWorker, queuePage, notFound, SECURITY_HEADERS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLanPages = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
