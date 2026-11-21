'use strict';
/**
 * C10 (batch 4 of ~/Khayt-proposals/prusa-ideas-plan.md): found printers are
 * remembered with first/last seen, expire, and the list is capped.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const F = require('../lib/found-printers.js');

const H = 60 * 60 * 1000;
const T0 = Date.parse('2026-11-21T10:00:00Z');
const u1 = { id: '_snapmaker._tcp.local|U1._snapmaker._tcp.local', name: 'Snapmaker U1', host: '192.168.1.40', port: 7125, serial: 'SNU1-0001', connection: 'moonraker', raw: { ip: '192.168.1.40', junk: 'x' } };
const core = { id: '_prusalink._tcp.local|prusa-core-one', name: 'Prusa CORE One', host: '192.168.1.41', port: 80, serial: '', connection: 'prusalink' };

test('a find is remembered with first and last seen, without the TXT dump', () => {
  const list = F.remember([], [u1], T0);
  assert.equal(list.length, 1);
  assert.equal(list[0].firstSeen, T0);
  assert.equal(list[0].lastSeen, T0);
  assert.equal(list[0].seenCount, 1);
  assert.equal(list[0].source, 'mdns');
  assert.equal(list[0].raw, undefined);
});

test('seen again: last seen moves, first seen stays, never mutates the input', () => {
  const a = F.remember([], [u1], T0);
  const frozen = JSON.stringify(a);
  const b = F.remember(a, [u1], T0 + H);
  assert.equal(JSON.stringify(a), frozen);
  assert.equal(b.length, 1);
  assert.equal(b[0].firstSeen, T0);
  assert.equal(b[0].lastSeen, T0 + H);
  assert.equal(b[0].seenCount, 2);
});

test('a serial follows the printer to a new address, and the old address is noted', () => {
  const a = F.remember([], [u1], T0);
  const b = F.remember(a, [Object.assign({}, u1, { host: '192.168.1.77' })], T0 + H);
  assert.equal(b.length, 1);
  assert.equal(b[0].host, '192.168.1.77');
  assert.equal(b[0].previousHost, '192.168.1.40');
  assert.equal(b[0].firstSeen, T0);
});

test('a sweep hit on a known address merges into it and keeps what mDNS said', () => {
  const a = F.remember([], [u1], T0);
  const hit = { id: 'sweep|moonraker|192.168.1.40', name: 'Klipper', host: '192.168.1.40', port: 7125, serial: '', connection: 'moonraker', mac: 'aa:bb:cc:dd:ee:ff' };
  const b = F.remember(a, [hit], T0 + H, { source: 'sweep' });
  assert.equal(b.length, 1);
  assert.equal(b[0].serial, 'SNU1-0001');
  assert.equal(b[0].mac, 'aa:bb:cc:dd:ee:ff');
  assert.equal(b[0].source, 'sweep');
});

test('another printer on the same address and port replaces the old entry', () => {
  const a = F.remember([], [u1], T0);
  const other = Object.assign({}, u1, { serial: 'SNU1-0002', name: 'Second U1' });
  const b = F.remember(a, [other], T0 + H);
  assert.deepEqual(b.map((p) => p.serial), ['SNU1-0002']);
});

test('entries expire after the TTL', () => {
  const a = F.remember([], [u1, core], T0);
  const b = F.remember(a, [core], T0 + 2 * 24 * H);
  assert.equal(b.length, 2);
  const c = F.remember(b, [core], T0 + 3 * 24 * H);
  assert.deepEqual(c.map((p) => p.name), ['Prusa CORE One']);
  assert.equal(F.recent(b, T0 + 3 * 24 * H).length, 1);
  assert.equal(F.recent(b, T0 + 2 * 24 * H, { ttlMs: H }).length, 1);
});

test('the list is capped, the most recently seen kept', () => {
  let list = [];
  for (let i = 0; i < 50; i++) list = F.remember(list, [{ host: `10.0.0.${i + 1}`, port: 80, name: `P${i}` }], T0 + i * 1000);
  assert.equal(list.length, F.CAP);
  assert.equal(list[0].name, 'P49');
  assert.equal(list[list.length - 1].name, 'P10');
  assert.equal(F.remember(list, [], T0 + 50000, { cap: 5 }).length, 5);
});

test('junk from disk or the LAN is dropped or bounded', () => {
  const list = F.remember([null, 'x', { host: '' }, { host: '10.0.0.9', lastSeen: 'yesterday' }, { host: '10.0.0.8', port: 80, lastSeen: T0 }],
    [{ host: '10.0.0.7', port: 99999, name: 'n'.repeat(5000) }, {}, null], T0);
  assert.deepEqual(list.map((p) => p.host).sort(), ['10.0.0.7', '10.0.0.8']);
  const seven = list.find((p) => p.host === '10.0.0.7');
  assert.equal(seven.port, 0);
  assert.equal(seven.name.length, 200);
});

test('SDCP and sweep finds are labelled by where they came from', () => {
  const list = F.remember([], [{ id: 'sdcp|ABC', host: '10.0.0.3', port: 3030, serial: 'ABC' }, { id: 'sweep|duet|10.0.0.4', host: '10.0.0.4', port: 80 }], T0);
  assert.deepEqual(list.map((p) => p.source).sort(), ['sdcp', 'sweep']);
});

test('forScan: this scan first, then remembered printers it missed', () => {
  const list = F.remember(F.remember([], [u1, core], T0), [core], T0 + H);
  const shown = F.forScan(list, [core], T0 + 2 * H);
  assert.deepEqual(shown.map((p) => [p.name, p.seenNow]), [['Prusa CORE One', true], ['Snapmaker U1', false]]);
  assert.equal(shown[1].lastSeen, T0);
  // A remembered printer seen now at its address under a fresh scan id is not listed twice.
  const again = F.forScan(list, [Object.assign({}, u1, { id: 'other' })], T0 + 2 * H);
  assert.equal(again.filter((p) => p.host === '192.168.1.40').length, 1);
});

test('desktop: every scan is remembered, and the IPC returns this scan plus earlier finds', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main', 'printer-discovery.js'), 'utf8');
  assert.match(src, /rememberFound\(printers\);\s*\n\s*finish\(\{ ok: true, printers \}\)/);
  assert.match(src, /rememberFound\(out, 'sweep'\)/);
  assert.match(src, /'hub:found-printers'/);
  assert.match(src, /'hub:found-printers-forget'/);
  const pre = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  assert.match(pre, /foundPrinters: \(\)\s+=> ipcRenderer\.invoke\('hub:found-printers'\)/);
});
