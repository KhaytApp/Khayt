const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/mdns.js');
const D = require('../lib/printer-discovery.js');
const R = require('../lib/printer-relocate.js');

/*
 * A printer that changed address is not a printer that went away.
 *
 * These tests are anchored on a real event rather than an imagined one. On
 * 2026-08-24 the bench Snapmaker U1 was mid-print and unreachable: its DHCP
 * lease had moved it from 192.168.68.77 to .56, Khayt was still polling .77, and
 * the shop's completion history was EMPTY rather than short — every job that had
 * finished in the meantime was a measurement that no longer existed, because
 * captureCompletion only ever fires on a live poll.
 *
 * mdns-u1-relocated.json is that printer's actual announcements, captured off
 * the LAN that afternoon. So the fixture is not a description of the bug; it is
 * the bug.
 *
 * The rule under test is narrow on purpose. Retargeting a machine is a WRITE, and
 * the thing being written is where the app will later send print commands. So a
 * serial match — identity the printer proved — may be applied, and everything
 * weaker may only ever be proposed.
 */

const packetsFrom = (file) => require(`./fixtures/${file}`)
  .map((b64) => Buffer.from(b64, 'base64'));

const discover = (file) =>
  D.discoverFromRecords(packetsFrom(file).flatMap((p) => M.decodeMessage(p)));

/** The bench U1, as Khayt had it configured while it was answering nowhere. */
const staleU1 = () => ({
  id: 'MACH-msbqqtlcN1A',
  name: 'Snapmaker U1',
  vendor: 'Snapmaker',
  printerModel: 'snapmaker-u1',
  printerModelName: 'Snapmaker U1',
  printerApi: { type: 'moonraker', host: '192.168.68.77', port: 7125, apiKey: '' },
});

const offline = (id, n = 4) => ({ [id]: { error: 'connect ECONNREFUSED', consecutiveFailures: n } });

/* ── the real event ─────────────────────────────────────────────────────── */

test('the U1 that moved from .77 to .56 is found again, from its own announcements', () => {
  const discovered = discover('mdns-u1-relocated.json');
  assert.equal(discovered.length, 1, 'the capture should hold exactly one printer');
  assert.equal(discovered[0].host, '192.168.68.56', 'discovery did not resolve the new address');

  const machine = staleU1();
  const { moves } = R.planRelocations({
    machines: [machine], discovered, statusCache: offline(machine.id),
  });

  assert.equal(moves.length, 1, 'the moved printer was not offered a new address');
  assert.equal(moves[0].from, '192.168.68.77');
  assert.equal(moves[0].to, '192.168.68.56');
  assert.equal(moves[0].serial, '8110026060810400D73X');
  // No serial was ever recorded for this machine, so identity cannot be proved —
  // this is the model fallback, and it must say so rather than overstating.
  assert.equal(moves[0].confidence, R.CONFIDENCE.MODEL);

  // Applying it records the serial, so the NEXT time this happens the match is
  // identity rather than a guess. That is the whole point of carrying it.
  const fixed = R.applyRelocation(machine, moves[0]);
  assert.equal(fixed.printerApi.host, '192.168.68.56');
  assert.equal(fixed.printerApi.serial, '8110026060810400D73X');
  assert.equal(fixed.printerApi.apiKey, '', 'unrelated printerApi fields were dropped');
  assert.equal(machine.printerApi.host, '192.168.68.77', 'the input machine was mutated');

  const again = R.planRelocations({
    machines: [fixed], discovered, statusCache: offline(fixed.id),
  });
  assert.equal(again.moves.length, 0, 'already at the right address, yet a move was proposed');
  assert.equal(again.noMoves[0].reason, R.NO_MOVE.SAME_HOST);
});

test('a serial match is identity, and outranks every other signal', () => {
  const discovered = discover('mdns-u1-relocated.json');
  // Deliberately mislabelled: wrong name, wrong model, wrong everything except
  // the serial. Identity is not a resemblance score.
  const machine = {
    ...staleU1(),
    name: 'Old Ender', vendor: 'Creality', printerModel: 'ender-3', printerModelName: 'Ender 3',
    printerApi: { type: 'moonraker', host: '192.168.68.77', port: 7125, serial: '8110026060810400D73X' },
  };
  const { moves } = R.planRelocations({ machines: [machine], discovered, statusCache: offline(machine.id) });
  assert.equal(moves.length, 1);
  assert.equal(moves[0].confidence, R.CONFIDENCE.SERIAL);
  assert.equal(moves[0].to, '192.168.68.56');
});

test('a serial that is nowhere on the network is not quietly downgraded to a guess', () => {
  // The dangerous failure: a machine with a recorded identity, a printer on the
  // LAN that is NOT it, and a fallback eager enough to marry the two. Whatever is
  // out there, it is not this machine — say not-found and stop.
  const discovered = discover('mdns-u1-relocated.json');
  const machine = {
    ...staleU1(),
    printerApi: { type: 'moonraker', host: '192.168.68.77', port: 7125, serial: 'SOMEOTHERPRINTER' },
  };
  const { moves, noMoves } = R.planRelocations({
    machines: [machine], discovered, statusCache: offline(machine.id),
  });
  assert.equal(moves.length, 0, 'a machine was retargeted at a printer that is provably not it');
  assert.equal(noMoves[0].reason, R.NO_MOVE.NOT_FOUND);
  assert.equal(noMoves[0].serial, 'SOMEOTHERPRINTER');
});

/* ── restraint ──────────────────────────────────────────────────────────── */

test('a machine that is answering is left alone', () => {
  const discovered = discover('mdns-u1-relocated.json');
  const machine = staleU1();
  // No failures recorded: the printer is fine and simply has a different address
  // in the announcement than in the record — which is not a reason to touch it.
  const { moves } = R.planRelocations({ machines: [machine], discovered, statusCache: {} });
  assert.equal(moves.length, 0, 'a healthy machine was retargeted');

  // One missed poll is a blip, not a relocation.
  const blip = R.planRelocations({
    machines: [machine], discovered, statusCache: { [machine.id]: { error: 'timeout', consecutiveFailures: 1 } },
  });
  assert.equal(blip.moves.length, 0, 'a single missed poll triggered a rescan-and-rewrite');

  // …unless the owner asked directly, which is what the button in front of them means.
  const asked = R.planRelocations({ machines: [machine], discovered, requireOffline: false });
  assert.equal(asked.moves.length, 1);
});

test('two identical printers and no serials is ambiguous, and ambiguous means stop', () => {
  // The shop with two U1s is exactly where a confident guess does real damage:
  // it points one machine record at the other machine's printer, and the queue
  // follows. Report the candidates so the owner can choose; choose nothing.
  const discovered = [
    { connection: 'moonraker', host: '192.168.68.56', port: 7125, name: 'Snapmaker U1', model: 'Snapmaker U1', serial: 'AAA', catalogId: 'snapmaker-u1' },
    { connection: 'moonraker', host: '192.168.68.61', port: 7125, name: 'Snapmaker U1', model: 'Snapmaker U1', serial: 'BBB', catalogId: 'snapmaker-u1' },
  ];
  const machine = staleU1();
  const { moves, noMoves } = R.planRelocations({
    machines: [machine], discovered, statusCache: offline(machine.id),
  });
  assert.equal(moves.length, 0);
  assert.equal(noMoves[0].reason, R.NO_MOVE.AMBIGUOUS);
  assert.equal(noMoves[0].candidates.length, 2);
});

test('an address another machine already uses is never handed to a second one', () => {
  // Two records pointing at one printer is worse than one record pointing at
  // nothing: both look healthy, and the shop sends one machine two queues.
  const discovered = [
    { connection: 'moonraker', host: '192.168.68.56', port: 7125, name: 'Snapmaker U1', model: 'Snapmaker U1', serial: 'AAA', catalogId: 'snapmaker-u1' },
  ];
  const mine = staleU1();
  const theirs = {
    id: 'MACH-other', name: 'Snapmaker U1 #2', printerModelName: 'Snapmaker U1',
    printerApi: { type: 'moonraker', host: '192.168.68.56', port: 7125 },
  };
  const { moves, noMoves } = R.planRelocations({
    machines: [mine, theirs], discovered, statusCache: offline(mine.id),
  });
  assert.equal(moves.length, 0, 'a machine was pointed at an address already in use');
  assert.equal(noMoves[0].reason, R.NO_MOVE.NOT_FOUND);
});

test('a printer speaking a different protocol is not a candidate', () => {
  const discovered = [
    { connection: 'prusalink', host: '192.168.68.41', port: 80, name: 'Prusa CORE One', model: 'CORE One', serial: 'PRU1' },
  ];
  const machine = staleU1();          // moonraker
  const { moves, noMoves } = R.planRelocations({
    machines: [machine], discovered, statusCache: offline(machine.id),
  });
  assert.equal(moves.length, 0);
  assert.equal(noMoves[0].reason, R.NO_MOVE.NOT_FOUND);
});

test('a machine Khayt cannot talk to is not something to relocate', () => {
  const discovered = discover('mdns-u1-relocated.json');
  const manual = { id: 'MACH-manual', name: 'Old Ender', printerApi: { type: 'none', host: '' } };
  const bare = { id: 'MACH-bare', name: 'Resin thing' };
  const { moves, noMoves } = R.planRelocations({
    machines: [manual, bare], discovered, requireOffline: false,
  });
  assert.equal(moves.length, 0);
  assert.equal(noMoves.length, 0, 'a machine with no printer API was reported on at all');
});

/* ── learning an identity while there is still one to learn ─────────────── */

test('a reachable machine acquires the serial that will identify it next time', () => {
  const discovered = discover('mdns-u1-relocated.json');
  // Configured correctly and answering — which is the only moment a provable
  // identity is available. Once it moves, the address no longer matches and the
  // strongest match left is a guess.
  const machine = { ...staleU1(), printerApi: { type: 'moonraker', host: '192.168.68.56', port: 7125 } };
  const learned = R.learnSerials({ machines: [machine], discovered });
  assert.deepEqual(learned, [{ machineId: machine.id, serial: '8110026060810400D73X' }]);

  // Already known: nothing to do, and certainly nothing to overwrite.
  const known = { ...machine, printerApi: { ...machine.printerApi, serial: 'ALREADY' } };
  assert.deepEqual(R.learnSerials({ machines: [known], discovered }), []);

  // At a different address, this tells us nothing about which printer it is.
  assert.deepEqual(R.learnSerials({ machines: [staleU1()], discovered }), []);
});

/* ── input hygiene ──────────────────────────────────────────────────────── */

test('hosts compare equal however they are spelled', () => {
  assert.equal(R.bareHost('http://192.168.68.56:7125/'), '192.168.68.56');
  assert.equal(R.bareHost('  192.168.68.56  '), '192.168.68.56');
  assert.equal(R.bareHost('PRINTER.local'), 'printer.local');
  assert.equal(R.bareHost(null), '');

  // A machine written with a scheme and port must not read as "moved" when it is
  // sitting at exactly the address that was found.
  const discovered = discover('mdns-u1-relocated.json');
  const machine = { ...staleU1(), printerApi: { type: 'moonraker', host: 'http://192.168.68.56:7125', port: 7125 } };
  const { moves, noMoves } = R.planRelocations({
    machines: [machine], discovered, statusCache: offline(machine.id),
  });
  assert.equal(moves.length, 0, 'a differently-spelled but identical host read as a move');
  assert.equal(noMoves[0].reason, R.NO_MOVE.SAME_HOST);
});

test('serials compare on their characters, not their punctuation', () => {
  assert.ok(R.sameSerial('8110026060810400D73X', '8110026060810400d73x'));
  assert.ok(R.sameSerial('SN-123-456', 'sn123456'));
  assert.ok(!R.sameSerial('', ''), 'two absent serials are not a match');
  assert.ok(!R.sameSerial('AAA', 'BBB'));
});

test('nothing throws on missing, empty or junk input', () => {
  for (const bad of [undefined, {}, { machines: null, discovered: null }, { machines: [null, 3], discovered: [null] }]) {
    const r = R.planRelocations(bad);
    assert.ok(Array.isArray(r.moves) && Array.isArray(r.noMoves));
  }
  assert.deepEqual(R.learnSerials(), []);
  assert.equal(R.applyRelocation(null, null), null);
  // A move addressed to a different machine must not be applied to this one.
  const m = staleU1();
  assert.equal(R.applyRelocation(m, { machineId: 'someone-else', to: '10.0.0.1' }), m);
});

test('the port is only touched when it actually differs', () => {
  const discovered = [
    { connection: 'moonraker', host: '192.168.68.56', port: 7125, name: 'Snapmaker U1', model: 'Snapmaker U1', serial: 'AAA', catalogId: 'snapmaker-u1' },
  ];
  // Same port: leave it alone, so applying a move never overrides a deliberate choice.
  const same = staleU1();
  const a = R.planRelocations({ machines: [same], discovered, statusCache: offline(same.id) }).moves[0];
  assert.equal(a.port, null);
  assert.equal(R.applyRelocation(same, a).printerApi.port, 7125);

  // Different port: offer it, because that is how the printer says it is reached.
  const odd = { ...staleU1(), printerApi: { type: 'moonraker', host: '192.168.68.77', port: 80 } };
  const b = R.planRelocations({ machines: [odd], discovered, statusCache: offline(odd.id) }).moves[0];
  assert.equal(b.port, 7125);
  assert.equal(R.applyRelocation(odd, b).printerApi.port, 7125);
});

/* ── volunteering the diagnosis ─────────────────────────────────────────── */

/*
 * The original failure was SILENT, and that is the part a button does not fix.
 * Nobody scans a printer they have no reason to think has moved, so the owner
 * who needs the answer is the one who will never ask for it. shouldScan is what
 * lets the poller work it out unprompted — and the whole question it answers is
 * "how often", because a scan is a multicast burst and the poll loop runs every
 * thirty seconds.
 */

const OK = { state: 'printing', consecutiveFailures: 0, lastUpdated: 1 };

test('a scan runs only when something is offline and unexplained', () => {
  const m = staleU1();
  const base = { machines: [m], lastScanAt: 0, now: 60_000_000 };

  assert.equal(R.shouldScan({ ...base, statusCache: { [m.id]: OK } }), false,
    'a healthy printer triggered a LAN scan');
  assert.equal(R.shouldScan({ ...base, statusCache: { [m.id]: { error: 'x', consecutiveFailures: 1 } } }), false,
    'one missed poll triggered a LAN scan — that is a blip, not a relocation');
  assert.equal(R.shouldScan({ ...base, statusCache: offline(m.id) }), true);

  // Already explained: the answer is on screen, so scanning again buys nothing.
  const explained = { ...offline(m.id)[m.id], relocated: { from: '.77', to: '.56' } };
  assert.equal(R.shouldScan({ ...base, statusCache: { [m.id]: explained } }), false,
    'a printer whose move is already known was scanned for again');

  // A machine Khayt cannot talk to can never be the reason for a scan.
  assert.equal(R.shouldScan({
    ...base, machines: [{ id: 'x', printerApi: { type: 'none' } }], statusCache: { x: { error: 'x', consecutiveFailures: 9 } },
  }), false);
});

test('scans are debounced globally, not per machine', () => {
  // Ten printers going down together is one event on the network, and it is the
  // same single scan that answers for all of them.
  const machines = Array.from({ length: 10 }, (_, i) => ({
    ...staleU1(), id: `M${i}`, printerApi: { type: 'moonraker', host: `192.168.68.${20 + i}`, port: 7125 },
  }));
  const statusCache = Object.fromEntries(machines.map((m) => [m.id, { error: 'x', consecutiveFailures: 9 }]));
  const now = 60_000_000;

  assert.equal(R.shouldScan({ machines, statusCache, lastScanAt: 0, now }), true);
  // Just scanned: not again, however many machines are down.
  assert.equal(R.shouldScan({ machines, statusCache, lastScanAt: now - 1000, now }), false);
  assert.equal(R.shouldScan({ machines, statusCache, lastScanAt: now - 9 * 60_000, now }), false);
  assert.equal(R.shouldScan({ machines, statusCache, lastScanAt: now - 11 * 60_000, now }), true);
});

test('a printer that is simply switched off keeps qualifying, and that is deliberate', () => {
  // It is never "explained", so it never stops being a candidate. That costs one
  // short scan every ten minutes and buys the case that matters: a machine that
  // was off, came back, and came back on a different address than it left on.
  const m = staleU1();
  const off = { [m.id]: { error: 'connect EHOSTDOWN', consecutiveFailures: 40 } };
  const now = 60_000_000;
  assert.equal(R.shouldScan({ machines: [m], statusCache: off, lastScanAt: now - 11 * 60_000, now }), true);
});

test('the hint is only offered when there is something better than the error to say', () => {
  assert.equal(R.relocationHint(null), null);
  assert.equal(R.relocationHint({ error: 'connect ETIMEDOUT' }), null);
  assert.equal(R.relocationHint({ relocated: {} }), null, 'a move with no destination is not a hint');
  const h = R.relocationHint({ error: 'x', relocated: { from: '192.168.68.77', to: '192.168.68.56', confidence: 'serial', serial: 'AAA' } });
  assert.deepEqual(h, { from: '192.168.68.77', to: '192.168.68.56', confidence: 'serial', serial: 'AAA' });
});

test('coming back online clears the explanation rather than leaving it stale', () => {
  // mergePollSuccess builds a FRESH entry, so an annotation from while the
  // printer was missing cannot outlive it and go on claiming a move that has
  // already been accepted. Pinned here because the annotation is written from
  // outside that module and nothing else would notice if it started surviving.
  const cache = require('../lib/printer-poll-cache.js');
  const stale = { error: 'x', consecutiveFailures: 9, relocated: { from: '.77', to: '.56' } };
  const after = cache.mergePollSuccess(stale, { state: 'printing' }, Date.now());
  assert.equal(after.relocated, undefined, 'a resolved relocation hint survived the printer coming back');
  assert.equal(after.error, undefined);

  // …but it must survive further FAILURES, or the diagnosis is lost on the very
  // next poll and shouldScan starts the whole cycle again.
  const kept = cache.mergePollFailure(stale, 'still down', Date.now());
  assert.deepEqual(kept.relocated, { from: '.77', to: '.56' });
});
