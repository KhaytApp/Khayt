const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const S = require('../lib/printer-sweep.js');
const R = require('../lib/printer-relocate.js');

/* The real values, from the Snapmaker U1 this was written for. */
const U1 = {
  host: '192.168.68.56',
  was: '192.168.68.77',
  mac: '40:fd:f3:d9:2a:4c',
  serial: '18b6619254671b87',
  info: { result: { state: 'ready', hostname: 'lava', software_version: '1.5.2.13_20260722102206' } },
  sysinfo: { result: { system_info: { cpu_info: { serial_number: '18b6619254671b87' } } } },
};

test('the case this exists for: mDNS finds nothing, the subnet finds the printer', () => {
  // Browsed on the bench LAN while the U1 was printing, _moonraker._tcp and
  // _octoprint._tcp both returned nothing. planRelocations was handed [] and had
  // no way to propose the move, so the owner saw "offline" and no hint.
  const mdnsFound = [];
  const machine = { id: 'm1', name: 'Snapmaker U1', printerApi: { type: 'moonraker', host: U1.was, port: 7125 } };
  const offline = { m1: { error: 'offline', consecutiveFailures: 3 } };

  const before = R.planRelocations({ machines: [machine], discovered: mdnsFound, statusCache: offline });
  assert.deepEqual(before.moves, [], 'nothing to propose — this is the bug');

  const swept = [S.identifyResponse('moonraker', U1.host, 200, U1.info)];
  const after = R.planRelocations({ machines: [machine], discovered: swept, statusCache: offline });
  assert.equal(after.moves.length, 1);
  assert.equal(after.moves[0].from, U1.was);
  assert.equal(after.moves[0].to, U1.host);
});

test('a recorded hardware address is identity, and outranks a guess', () => {
  const machine = {
    id: 'm1', name: 'Snapmaker U1',
    printerApi: { type: 'moonraker', host: U1.was, port: 7125, mac: '40:FD:F3:D9:2A:4C' },
  };
  const offline = { m1: { error: 'offline', consecutiveFailures: 3 } };

  // Two Moonrakers on the LAN. Without a MAC that is AMBIGUOUS and nothing is
  // proposed; with one it is settled, and settled well enough to apply.
  const two = [
    { host: '192.168.68.20', port: 7125, connection: 'moonraker' },
    { host: U1.host, port: 7125, connection: 'moonraker', mac: U1.mac },
  ];
  const guess = R.planRelocations({ machines: [{ ...machine, printerApi: { ...machine.printerApi, mac: undefined } }], discovered: two, statusCache: offline });
  assert.equal(guess.moves.length, 0, 'two candidates, no evidence — refuse');

  const sure = R.planRelocations({ machines: [machine], discovered: two, statusCache: offline });
  assert.equal(sure.moves.length, 1);
  assert.equal(sure.moves[0].to, U1.host);
  assert.equal(sure.moves[0].confidence, 'mac');
  // Case and separator differ between the store and the OS; they must still match.
  assert.match(sure.moves[0].why, /hardware address/);
});

test('a MAC the table does not know yet is "not asked", not "not this printer"', () => {
  // The neighbour table only holds hosts this computer has spoken to. Falling
  // through to the weaker matches is what keeps a cold table from blocking a
  // move that model-matching could still make.
  const machine = { id: 'm1', printerApi: { type: 'moonraker', host: U1.was, mac: U1.mac } };
  // A swept candidate whose MAC we could not read: the probe answered, the
  // neighbour table had not caught up.
  const noMac = [S.identifyResponse('moonraker', U1.host, 200, U1.info)];
  const plan = R.planRelocations({ machines: [machine], discovered: noMac, statusCache: { m1: { error: 'offline', consecutiveFailures: 3 } } });
  assert.equal(plan.moves.length, 1, 'falls through rather than refusing');
  assert.equal(plan.moves[0].confidence, 'protocol', 'proposed with the doubt stated, not applied');
  assert.match(plan.moves[0].why, /check it is the right printer/);

  // And an mDNS candidate with nothing agreed about it stays refused, as before —
  // the sweep earned its proposal by asking, an announcement did not.
  const announced = [{ host: U1.host, port: 7125, connection: 'moonraker' }];
  const quiet = R.planRelocations({ machines: [machine], discovered: announced, statusCache: { m1: { error: 'offline', consecutiveFailures: 3 } } });
  assert.equal(quiet.moves.length, 0);
});

test('Moonraker impersonates OctoPrint, and is not mistaken for one', () => {
  // Found on the first live run: Moonraker ships an OctoPrint compatibility shim,
  // so the U1 answered on :80 and was reported as BOTH. It names itself.
  const shim = { server: '1.5.0', api: '0.1', text: 'OctoPrint (Moonraker 1.5.2)' };
  assert.equal(S.identifyResponse('octoprint', U1.host, 200, shim), null);

  // A real OctoPrint still identifies, and so does one that refuses us.
  assert.ok(S.identifyResponse('octoprint', '10.0.0.5', 200, { server: '1.9.3', api: '0.1', text: 'OctoPrint 1.9.3' }));
  assert.ok(S.identifyResponse('octoprint', '10.0.0.5', 403, null), 'a refusal is still an identification');
});

test('protocols are told apart by what they refuse, not only by what they return', () => {
  // A printer we cannot yet authenticate to is still a printer we have found —
  // and it is the one whose owner most needs the address fixed.
  assert.ok(S.identifyResponse('prusalink', '10.0.0.6', 401, null), 'PrusaLink 401s every /api/v1/*');
  assert.ok(S.identifyResponse('duet', '10.0.0.7', 401, null), 'a password-protected Duet 401s');
  assert.ok(S.identifyResponse('duet', '10.0.0.7', 200, { result: [{ name: 'Duet 3 MB6HC', firmwareVersion: '3.5.4' }] }));

  // …but a 404 or a stranger's web server is not a printer.
  for (const [type, status, body] of [
    ['moonraker', 404, null], ['moonraker', 200, { nope: 1 }],
    ['prusalink', 404, null], ['duet', 404, null], ['octoprint', 500, null],
  ]) {
    assert.equal(S.identifyResponse(type, '10.0.0.8', status, body), null, `${type} ${status}`);
  }
});

test('the durable identity is read the way the printer actually publishes it', () => {
  assert.equal(S.identityProbeFor('moonraker'), '/machine/system_info');
  assert.equal(S.readIdentitySerial('moonraker', U1.sysinfo), U1.serial);
  // Protocols with nothing durable say so rather than inventing one.
  assert.equal(S.identityProbeFor('duet'), null);
  assert.equal(S.readIdentitySerial('duet', {}), '');
  for (const junk of [null, {}, { result: {} }, { result: { system_info: { cpu_info: {} } } }]) {
    assert.equal(S.readIdentitySerial('moonraker', junk), '');
  }
});

test('one neighbour-table parser, four platform layouts', () => {
  const lines = {
    macos: '? (192.168.68.56) at 40:fd:f3:d9:2a:4c on en0 ifscope [ethernet]',
    linuxArp: '? (192.168.68.56) at 40:fd:f3:d9:2a:4c [ether] on eth0',
    ipNeigh: '192.168.68.56 dev eth0 lladdr 40:fd:f3:d9:2a:4c REACHABLE',
    windows: '  192.168.68.56        40-fd-f3-d9-2a-4c     dynamic',
  };
  for (const [name, line] of Object.entries(lines)) {
    assert.deepEqual(S.parseArpTable(line), { '192.168.68.56': U1.mac }, name);
  }
  // Short octets are padded — macOS prints "ec:75:c:62:ed:c8".
  assert.deepEqual(S.parseArpTable('? (192.168.68.1) at ec:75:c:62:ed:c8 on en0'), { '192.168.68.1': 'ec:75:0c:62:ed:c8' });
  // Unresolved entries are not identities. 230 of 256 looked like this live.
  assert.deepEqual(S.parseArpTable('? (192.168.68.3) at (incomplete) on en0'), {});
  // Placeholders are not identities either.
  assert.deepEqual(S.parseArpTable('192.168.1.1 at 00:00:00:00:00:00'), {});
  assert.deepEqual(S.parseArpTable('192.168.1.2 at ff:ff:ff:ff:ff:ff'), {});
  for (const junk of [null, undefined, '', 'no addresses here', 42]) {
    assert.deepEqual(S.parseArpTable(junk), {});
  }
});

test('candidates start where the printer was and work outwards', () => {
  const hosts = S.candidateHosts(U1.was);
  assert.equal(hosts[0], '192.168.68.76');
  assert.equal(hosts[1], '192.168.68.78');
  assert.ok(!hosts.includes(U1.was), 'the dead address is not probed again');
  assert.equal(hosts.length, 253);
  // The real move was 21 hops away and lands well inside the first fifth.
  assert.ok(hosts.indexOf(U1.host) < 50, `found at position ${hosts.indexOf(U1.host)}`);
  // Never leaves the /24.
  assert.ok(hosts.every((h) => h.startsWith('192.168.68.')));
  assert.deepEqual(S.candidateHosts(U1.was, { limit: 4 }).length, 4);
  for (const junk of ['nope', '999.1.1.1', '', null, 'fe80::1']) assert.deepEqual(S.candidateHosts(junk), []);
});

test('the main process sweeps only inside the existing host guard', () => {
  // A subnet sweep is a tool that can be mistaken for an attack. It must not be
  // able to leave the LAN even if a machine record is forged.
  //
  // `sweepForPrinters` moved from main.js into lib/main/printer-discovery.js.
  // The properties asserted below are about the SWEEP, not about which file it
  // sits in, so the guard follows it — and reads both files, because the
  // fallback-ordering assertion at the end is about the caller, which is still
  // in main.js.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main', 'printer-discovery.js'), 'utf8')
    + '\n' + fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const fn = src.slice(src.indexOf('async function sweepForPrinters'), src.indexOf('function readNeighbourTable'));
  assert.ok(fn.includes('isAllowedPrinterHost(host)'), 'every target passes the RFC1918 guard');
  assert.ok(/AbortSignal\.timeout/.test(fn), 'every request is bounded');
  assert.ok(/redirect: 'manual'/.test(fn), 'a printer cannot redirect the probe elsewhere');
  // And the automatic path only sweeps when mDNS came back empty.
  assert.ok(/if \(!discovered\.length\)[\s\S]{0,200}sweepForPrinters/.test(src),
    'the sweep is a fallback, not the first thing tried');
});
