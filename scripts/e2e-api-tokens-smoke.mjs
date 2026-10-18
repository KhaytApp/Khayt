/**
 * E2E smoke — scoped API tokens over the real LAN HTTP server (PUBLIC-API-SPEC §1).
 *
 * Security-critical properties proven end-to-end:
 *   - /v1 is served (versioned surface) and /api still works (permanent alias).
 *   - A read-scoped token can read but is 403 insufficient_scope on a write.
 *   - A write-scoped token can write.
 *   - A revoked/unknown token is 401 — immediately, no caching.
 *   - A token for one collection cannot reach another (no scope widening).
 *
 * Run: npm run test:e2e:apitokens   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir, E2E_LAN_PORT, E2E_LAN_PIN } from './e2e/helpers.mjs';
import { createRequire } from 'node:module';
// api-tokens.js is a main-process CommonJS module — mint here in Node, then inject the
// (hash-only) records into the renderer's settings, exactly as the real UI would.
const require_ = createRequire(import.meta.url);
const ApiTokens = require_('../lib/api-tokens.js');

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

async function call(path, { method = 'GET', token, body } = {}) {
  const headers = {};
  if (token) headers.authorization = 'Bearer ' + token;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(`http://127.0.0.1:${E2E_LAN_PORT}${path}`, {
    method, headers, body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let parsed; const text = await res.text();
  try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { status: res.status, body: parsed };
}

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  // Mint two tokens directly through the same library the server verifies against.
  const readTok = ApiTokens.generateToken({ label: 'read-only', scopes: ['orders:read'] });
  const writeTok = ApiTokens.generateToken({ label: 'writer', scopes: ['orders:read', 'orders:write'] });
  const staleTok = ApiTokens.generateToken({ label: 'revoked', scopes: ['orders:read'] });
  const toks = { read: readTok.token, write: writeTok.token, revoked: staleTok.token };
  await window.evaluate(async ({ port, pin, records }) => {
    settings.lanApi = {
      ...(settings.lanApi || {}), enabled: true, port, pin, bindLan: false,
      // staleTok's record is deliberately NOT stored → it models a revoked token
      apiTokens: records,
    };
    printLog.unshift({ id: 'API-1', status: 'pending', project: 'API test', date: '2026-07-20', price: 10, parts: [], statusHistory: [] });
    saveAll();
    await window.hubAPI.startLanServer({ port, pin, bindLan: false });
  }, { port: E2E_LAN_PORT, pin: E2E_LAN_PIN, records: [readTok.record, writeTok.record] });
  await new Promise(r => setTimeout(r, 1200));

  // /v1 surface is live, and the legacy /api alias still works.
  const v1 = await call('/v1/orders', { token: toks.read });
  ok(v1.status === 200, `/v1/orders readable with orders:read (${v1.status})`);
  const legacy = await call('/api/orders', { token: toks.read });
  ok(legacy.status === 200, '/api alias still works (no breakage for iOS/PWA)');

  // Read token must NOT be able to write.
  const denied = await call('/v1/orders/API-1', { method: 'PATCH', token: toks.read, body: { status: 'printing' } });
  ok(denied.status === 403, `read token on write → 403 (${denied.status})`);
  ok(denied.body && denied.body.error === 'insufficient_scope', 'error names insufficient_scope');
  ok(denied.body.required === 'orders:write', `and states the required scope (${denied.body.required})`);

  // Write token can write.
  const allowed = await call('/v1/orders/API-1', { method: 'PATCH', token: toks.write, body: { status: 'printing' } });
  ok(allowed.status >= 200 && allowed.status < 300, `write token on write → ${allowed.status}`);
  await window.waitForFunction(() => printLog.find(o => o.id === 'API-1')?.status === 'printing', { timeout: 8000 });
  ok(true, 'the write actually landed in the store');

  // Revoked / unknown tokens are rejected outright.
  const revoked = await call('/v1/orders', { token: toks.revoked });
  ok(revoked.status === 401, `revoked token → 401 (${revoked.status})`);
  const bogus = await call('/v1/orders', { token: 'khayt_not_a_real_token' });
  ok(bogus.status === 401, 'unknown token → 401');

  // No scope widening across collections.
  const cross = await call('/v1/clients', { token: toks.read });
  ok(cross.status === 403, `orders token cannot read clients (${cross.status})`);

  // A token must NOT widen access beyond the scope model: an unscoped PIN-gated page
  // (the LAN kiosk shell) still requires the owner PIN, even with a valid token.
  // With no PIN the page is now its PIN form (200), never the queue.
  const page = await call('/', { token: toks.read });
  ok(typeof page.body === 'string' && page.body.includes('action="/session"'),
    `token cannot open an unscoped PIN-gated page (${page.status}: the PIN form, not the queue)`);
  // …while its own scoped data remains reachable.
  const stillOk = await call('/v1/orders', { token: toks.read });
  ok(stillOk.status === 200, 'scoped data still reachable with the same token');

  console.log('\n✅ API token smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
