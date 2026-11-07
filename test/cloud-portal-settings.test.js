'use strict';
// The shop's cross-shop portal switch (Cloud "portal crossShop"):
// GET/PUT /v1/shops/{id}/portal-settings {crossShop}.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const cc = require('../lib/cloud-client.js');

function server(handler) {
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      const out = handler(req, raw ? JSON.parse(raw) : null);
      res.writeHead(out.status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(out.body));
    });
  });
  return srv;
}

test('read and change the switch; on unless the shop turned it off', async () => {
  let stored;   // never set: the shop has not chosen
  const seen = [];
  const srv = server((req, body) => {
    seen.push(req.method + ' ' + req.url);
    if (req.method === 'PUT') { stored = body.crossShop; return { status: 200, body: { crossShop: stored, updatedAt: 'T' } }; }
    return { status: 200, body: stored === undefined ? {} : { crossShop: stored, updatedAt: 'T' } };
  });
  await new Promise((r) => srv.listen(0, r));
  const base = `http://localhost:${srv.address().port}`;
  try {
    assert.equal((await cc.getPortalSettings(base, 'S1', 'tok')).crossShop, true, 'absent reads as on');
    assert.equal((await cc.setPortalSettings(base, 'S1', 'tok', false)).crossShop, false);
    assert.equal(stored, false, 'a boolean went over the wire');
    assert.equal((await cc.getPortalSettings(base, 'S1', 'tok')).crossShop, false);
    assert.deepEqual(seen, ['GET /v1/shops/S1/portal-settings', 'PUT /v1/shops/S1/portal-settings', 'GET /v1/shops/S1/portal-settings']);
  } finally { srv.close(); }
});

test('a member who may not change it is told why (reason "role")', async () => {
  const srv = server(() => ({ status: 403, body: { error: 'forbidden', reason: 'role' } }));
  await new Promise((r) => srv.listen(0, r));
  const base = `http://localhost:${srv.address().port}`;
  try {
    await assert.rejects(() => cc.setPortalSettings(base, 'S1', 'tok', false), (e) => e.reason === 'role');
  } finally { srv.close(); }
});
