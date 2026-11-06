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
const Devices = require_('../lib/lan-devices.js');
import crypto from 'node:crypto';

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
  // The move ran the shared status rule: one history entry, not one from the
  // server and a second from the window.
  const trail = await window.evaluate(() => (printLog.find(o => o.id === 'API-1')?.statusHistory || []).map(h => h.status));
  ok(JSON.stringify(trail) === JSON.stringify(['printing']), `one history entry for the move (${JSON.stringify(trail)})`);

  // A completion over the LAN runs the rule's effects in the window: the
  // filament comes off the shelf, as a move to Completed on the board takes it.
  await window.evaluate(() => {
    inventory.push({ id: 'SP-E2E', material: 'PLA', brand: 'E2E', weight: 500, weightTotal: 1000, cost: 80 });
    printLog.unshift({ id: 'API-2', status: 'qc', project: 'Done over LAN', date: '2026-07-20', price: 10, statusHistory: [],
      parts: [{ name: 'p', filamentId: 'SP-E2E', printWeight: 20, qty: 1, material: 'PLA' }] });
    return flushSave();
  });
  const finished = await call('/v1/orders/API-2', { method: 'PATCH', token: toks.write, body: { status: 'completed' } });
  ok(finished.status === 200, `PATCH to completed → ${finished.status}`);
  await window.waitForFunction(() => printLog.find(o => o.id === 'API-2')?.materialDeducted === true, { timeout: 8000 });
  const shelf = await window.evaluate(() => ({ grams: inventory.find(s => s.id === 'SP-E2E').weight, done: printLog.find(o => o.id === 'API-2').completedAt }));
  ok(shelf.grams === 480, `the 20 g came off the spool (${shelf.grams} g left)`);
  ok(typeof shelf.done === 'string', 'and the job carries its completion date');

  // A job made over the LAN survives the window's next save. Before, the
  // window never took lan-order-created and its whole-book save removed it.
  const made = await call('/v1/orders', { method: 'POST', token: toks.write, body: { project: 'From the API', price: 42 } });
  ok(made.status === 201, `POST a job over the LAN → ${made.status}`);
  const madeId = made.body && made.body.order && made.body.order.id;
  ok(/^INV-\d{4}-\d{4}-[0-9a-z]{4}$/.test(String(madeId)), `numbered from the shop's counter (${madeId})`);
  await window.waitForFunction((id) => printLog.some(o => o.id === id), madeId, { timeout: 8000 });
  ok(true, 'the window took the new job');
  const afterSave = await window.evaluate(async (id) => {
    settings.shopName = (settings.shopName || 'Shop') + ' ';   // an unrelated edit at the desk
    await flushSave();
    const disk = await window.hubAPI.loadStore();
    const tok = ((disk.settings.lanApi || {}).apiTokens || []).find(t => t.label === 'writer');
    return { kept: (disk.printLog || []).some(o => o.id === id), lastUsedAt: tok && tok.lastUsedAt };
  }, madeId);
  ok(afterSave.kept, 'the job is still in the book after a save from the window');
  ok(typeof afterSave.lastUsedAt === 'string' && afterSave.lastUsedAt.length > 0, `the write token's lastUsedAt is on disk, not wound back by the save (${afterSave.lastUsedAt})`);

  // A paired phone adds a job photo (POST /api/orders/:id/photos, as the Mac's
  // LanServer). Enrol the way the phone does, then send a real JPEG bigger than
  // the 1600px copy, so Electron's encoder resizes it in the main process.
  const pair = crypto.generateKeyPairSync('x25519');
  const phonePub = crypto.createPublicKey(pair.privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
  const enrol = await fetch(`http://127.0.0.1:${E2E_LAN_PORT}/api/devices`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-khayt-pin': E2E_LAN_PIN }, body: JSON.stringify({ publicKey: phonePub, name: 'E2E phone' }) });
  ok(enrol.status === 200, `a phone enrols with the PIN (${enrol.status})`);
  const dev = await enrol.json();
  const macPub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(dev.publicKey, 'base64')]), format: 'der', type: 'spki' });
  const devKey = Devices.deriveDeviceKey(crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: macPub }), dev.deviceId);
  const photoJpeg = Buffer.from(await electronApp.evaluate(({ nativeImage }) => {
    const w = 2400, h = 1200, px = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h; i++) { px[i * 4] = i % 251; px[i * 4 + 1] = (i >> 3) % 255; px[i * 4 + 2] = 128; px[i * 4 + 3] = 255; }
    return nativeImage.createFromBitmap(px, { width: w, height: h }).toJPEG(90).toString('base64');
  }), 'base64');
  const photoTarget = '/api/orders/API-1/photos';
  const time = String(Math.floor(Date.now() / 1000)), nonce = crypto.randomBytes(16).toString('hex');
  const photoRes = await fetch(`http://127.0.0.1:${E2E_LAN_PORT}${photoTarget}`, { method: 'POST', body: photoJpeg, headers: {
    'content-type': 'image/jpeg', 'x-khayt-device': dev.deviceId, 'x-khayt-time': time, 'x-khayt-nonce': nonce,
    'x-khayt-mac': Devices.requestMac(devKey, Devices.canonicalRequest('POST', photoTarget, time, nonce, photoJpeg)) } });
  const photoOut = await photoRes.json();
  ok(photoRes.status === 201 && photoOut.ok && photoOut.index === 0, `a paired phone adds a job photo → ${photoRes.status} ${JSON.stringify(photoOut)}`);
  const pinOnlyPhoto = await fetch(`http://127.0.0.1:${E2E_LAN_PORT}${photoTarget}`, { method: 'POST', body: photoJpeg, headers: { 'x-khayt-pin': E2E_LAN_PIN } });
  ok(pinOnlyPhoto.status === 403, `the PIN alone may not (${pinOnlyPhoto.status})`);
  await window.waitForFunction(() => (printLog.find(o => o.id === 'API-1')?.printPhotos || []).length === 1, null, { timeout: 8000 });
  const shot = await electronApp.evaluate(({ app, nativeImage }, name) => {
    const img = nativeImage.createFromPath(app.getPath('userData') + '/order-photos/' + name);
    return img.isEmpty() ? null : img.getSize();
  }, photoOut.filename);
  ok(shot && Math.max(shot.width, shot.height) === 1600, `the copy in order-photos/ is the 1600px one (${JSON.stringify(shot)})`);
  const photoKept = await window.evaluate(async () => {
    const thumb = printLog.find(o => o.id === 'API-1').printPhotos[0].thumb;
    settings.shopName = (settings.shopName || 'Shop') + ' ';
    await flushSave();
    const disk = await window.hubAPI.loadStore();
    const kept = (disk.printLog || []).find(o => o.id === 'API-1')?.printPhotos || [];
    return { thumb: thumb.slice(0, 23), onDisk: kept.length, source: kept[0] && kept[0].source };
  });
  ok(photoKept.thumb === 'data:image/jpeg;base64,', 'the window holds the inline thumbnail');
  ok(photoKept.onDisk === 1, 'and the photo is still on the job after a save from the window');
  ok(photoKept.source === 'phone', `tagged as the phone's (${photoKept.source})`);

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
