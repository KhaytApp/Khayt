/**
 * SDCP v3.0.0 — the protocol layer for Elegoo resin printers.
 *
 * Every payload here is the vendor's own, copied out of
 * cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0, so what is being tested is
 * agreement with the specification rather than agreement with my reading of it.
 * Where a test asserts something the spec does not state outright, it says so.
 *
 * NOT VERIFIED AGAINST HARDWARE. There is no Elegoo resin printer on the LAN —
 * it is a Prusa CORE One and a Snapmaker U1. This proves the framing and the
 * mapping; it proves nothing about whether a real mainboard accepts the frames.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const sdcp = require('../lib/sdcp.js');

/** The discovery reply, verbatim from the spec's "Device Discovery" section. */
const DISCOVERY = {
  Id: 'xxx',
  Data: {
    Name: 'PrinterName',
    MachineName: 'MachineModel',
    BrandName: 'CBD',
    MainboardIP: '192.168.1.2',
    MainboardID: '000000000001d354',
    ProtocolVersion: 'V3.0.0',
    FirmwareVersion: 'V1.0.0',
  },
};

/** The status message, verbatim from the spec's "Status Information" section. */
const STATUS = {
  Status: {
    CurrentStatus: [0, 1, 2, 3],
    PreviousStatus: 0,
    PrintScreen: 0,
    ReleaseFilm: 0,
    TempOfUVLED: 0,
    TimeLapseStatus: 0,
    TempOfBox: 0,
    TempTargetBox: 0,
    PrintInfo: {
      Status: 0,
      CurrentLayer: 100,
      TotalLayer: 1000,
      CurrentTicks: 65535,
      TotalTicks: 65535,
      Filename: 'HitWork.ctb',
      ErrorNumber: 1,
      TaskId: 'xxx',
    },
  },
  MainboardID: 'ffffffff',
  TimeStamp: 1687069655,
  Topic: 'sdcp/status/ffffffff',
};

test('discovery: the spec\'s reply yields something connectable', () => {
  const d = sdcp.parseDiscoveryReply(DISCOVERY);
  assert.equal(d.ip, '192.168.1.2');
  assert.equal(d.mainboardId, '000000000001d354');
  assert.equal(d.model, 'MachineModel');
  assert.equal(d.protocolVersion, 'V3.0.0');
  // The whole point of discovery is arriving at an address you can open.
  assert.equal(d.url, 'ws://192.168.1.2:3030/websocket');
  assert.equal(sdcp.DISCOVERY_MAGIC, 'M99999');
  assert.equal(sdcp.DISCOVERY_PORT, 3000);
});

test('discovery: junk on the broadcast socket returns null, never throws', () => {
  // This listens on a LAN broadcast port. It will be handed whatever else is
  // shouting there, and one malformed datagram must not end the scan.
  for (const junk of ['', 'not json', '{}', '{"Data":{}}', null, undefined, 42, '[]',
                      JSON.stringify({ Data: { MainboardIP: '1.2.3.4' } }),   // no ID
                      JSON.stringify({ Data: { MainboardID: 'abc' } })]) {    // no IP
    assert.equal(sdcp.parseDiscoveryReply(junk), null, `junk: ${String(junk)}`);
  }
  // And it accepts the reply as a raw JSON string, which is how a socket sees it.
  assert.equal(sdcp.parseDiscoveryReply(JSON.stringify(DISCOVERY)).ip, '192.168.1.2');
});

test('request framing matches the spec, doubled Data and all', () => {
  // The envelope nests Data inside Data. It reads like a bug and is not; getting
  // it wrong yields a frame the mainboard ignores silently.
  const req = sdcp.buildRequest(sdcp.CMD.STATUS_REFRESH, {
    mainboardId: 'ffffffff', requestId: '000000000001d354', timestamp: 1687069655,
  });
  assert.equal(req.Topic, 'sdcp/request/ffffffff');
  assert.equal(req.Data.Cmd, 0);
  assert.deepEqual(req.Data.Data, {});
  assert.equal(req.Data.RequestID, '000000000001d354');
  assert.equal(req.Data.MainboardID, 'ffffffff');
  assert.equal(req.Data.TimeStamp, 1687069655);
  assert.equal(req.Data.From, 0);
  assert.ok('Id' in req, 'the brand id field is present even when empty');
});

test('request refuses to build something unsendable', () => {
  assert.throws(() => sdcp.buildRequest(0, {}), /mainboardId required/);
  assert.throws(() => sdcp.buildRequest('0', { mainboardId: 'x' }), /cmd must be an integer/);
  assert.throws(() => sdcp.buildRequest(undefined, { mainboardId: 'x' }), /cmd must be an integer/);
});

test('the command numbers are the spec\'s', () => {
  assert.equal(sdcp.CMD.STATUS_REFRESH, 0);
  assert.equal(sdcp.CMD.ATTRIBUTES, 1);
  assert.equal(sdcp.CMD.START, 128);
  assert.equal(sdcp.CMD.PAUSE, 129);
  assert.equal(sdcp.CMD.STOP, 130);
  assert.equal(sdcp.CMD.RESUME, 131);
  assert.equal(sdcp.CMD.FILE_LIST, 258);
  assert.equal(sdcp.CMD.HISTORY, 320);
});

test('a message is routed by its topic', () => {
  assert.equal(sdcp.messageKind(STATUS), 'status');
  assert.equal(sdcp.messageKind({ Topic: 'sdcp/attributes/ff' }), 'attributes');
  assert.equal(sdcp.messageKind({ Topic: 'sdcp/error/ff' }), 'error');
  assert.equal(sdcp.messageKind({ Topic: 'sdcp/notice/ff' }), 'notice');
  assert.equal(sdcp.messageKind({ Topic: 'something/else' }), null);
  assert.equal(sdcp.messageKind({}), null);
  assert.equal(sdcp.messageKind(null), null);
});

test('status maps to the shape every other Khayt adapter returns', () => {
  const s = sdcp.statusFrom(STATUS);
  assert.equal(s.type, 'sdcp');
  assert.equal(s.filename, 'HitWork.ctb');
  assert.equal(s.progress, 10, '100 of 1000 layers');
  assert.equal(s.progressSource, 'layers');
  assert.equal(s.currentLayer, 100);
  assert.equal(s.totalLayer, 1000);
  assert.equal(s.taskId, 'xxx');
  assert.equal(s.mainboardId, 'ffffffff');
});

test('progress prefers layers over time, because layers are exact', () => {
  // The spec's own example has CurrentTicks === TotalTicks (65535) while only
  // 100 of 1000 layers are done. Trusting the clock would report 100% on a job
  // one tenth finished — the estimate drifts, the layer count does not.
  const s = sdcp.statusFrom(STATUS);
  assert.equal(s.progress, 10);

  // With no layer count, time is the fallback rather than nothing.
  const noLayers = JSON.parse(JSON.stringify(STATUS));
  noLayers.Status.PrintInfo.TotalLayer = 0;
  noLayers.Status.PrintInfo.CurrentTicks = 30000;
  noLayers.Status.PrintInfo.TotalTicks = 60000;
  const t = sdcp.statusFrom(noLayers);
  assert.equal(t.progress, 50);
  assert.equal(t.progressSource, 'time');
});

test('a resin printer reports no nozzle and no bed — null, not zero', () => {
  // Zero would render as a cold hotend: a number that looks like a measurement
  // and is not one. The spec has no nozzle, bed, extruder or filament field —
  // the word "nozzle" does not appear in it once.
  const s = sdcp.statusFrom(STATUS);
  assert.equal(s.tempNozzle, null);
  assert.equal(s.tempBed, null);
  // What it does have is carried instead.
  assert.equal(s.tempUVLED, 0);
  assert.equal(s.tempBox, 0);
  assert.equal(s.releaseFilmCount, 0);
});

test('a multi-valued CurrentStatus resolves to printing', () => {
  // The spec's example is [0,1,2,3] — idle, printing, transferring and testing
  // at once. A shop needs to see the one that means the machine is busy.
  assert.equal(sdcp.statusFrom(STATUS).machineState, 'printing');

  const idle = JSON.parse(JSON.stringify(STATUS));
  idle.Status.CurrentStatus = [0];
  assert.equal(sdcp.statusFrom(idle).machineState, 'idle');

  const scalar = JSON.parse(JSON.stringify(STATUS));
  scalar.Status.CurrentStatus = 2;
  assert.equal(sdcp.statusFrom(scalar).machineState, 'transferring');
});

test('the latching sub-status refines a print, and never overrides idle', () => {
  // The spec: the sub-status "will always retain the most recent status ... after
  // the print is completed, the sub-status value will continue to be maintained
  // as Print Completed". So it answers what happened last, not what is happening.
  const done = JSON.parse(JSON.stringify(STATUS));
  done.Status.CurrentStatus = [0];              // machine idle
  done.Status.PrintInfo.Status = 9;             // sub-status still says complete
  const s = sdcp.statusFrom(done);
  assert.equal(s.machineState, 'idle');
  assert.equal(s.printState, 'complete');
  assert.equal(s.state, 'idle', 'the top-level status decides whether it is busy');

  const printing = JSON.parse(JSON.stringify(STATUS));
  printing.Status.CurrentStatus = [1];
  printing.Status.PrintInfo.Status = 3;         // exposing
  assert.equal(sdcp.statusFrom(printing).state, 'exposing');
});

test('a print error is reported in words, not a number', () => {
  // The spec's example carries ErrorNumber 1.
  assert.equal(sdcp.statusFrom(STATUS).error, 'File checksum failed');

  const mismatch = JSON.parse(JSON.stringify(STATUS));
  mismatch.Status.PrintInfo.ErrorNumber = 5;
  assert.match(sdcp.statusFrom(mismatch).error, /different machine/);

  const fine = JSON.parse(JSON.stringify(STATUS));
  fine.Status.PrintInfo.ErrorNumber = 0;
  assert.equal(sdcp.statusFrom(fine).error, null, '0 means normal, not an error');
});

test('time remaining is seconds, from milliseconds, never negative', () => {
  const m = JSON.parse(JSON.stringify(STATUS));
  m.Status.PrintInfo.CurrentTicks = 60000;
  m.Status.PrintInfo.TotalTicks = 300000;
  assert.equal(sdcp.statusFrom(m).timeRemaining, 240, '240s left, not 240000');

  // An overrunning job reports 0 rather than a negative countdown.
  const over = JSON.parse(JSON.stringify(STATUS));
  over.Status.PrintInfo.CurrentTicks = 400000;
  over.Status.PrintInfo.TotalTicks = 300000;
  assert.equal(sdcp.statusFrom(over).timeRemaining, 0);
});

test('a garbled status degrades instead of throwing', () => {
  // This is parsed from a network socket. It has to survive anything.
  for (const bad of [null, undefined, {}, { Status: null }, { Status: {} }, 'text', 42]) {
    const s = sdcp.statusFrom(bad);
    assert.equal(typeof s.progress, 'number');
    assert.equal(s.type, 'sdcp');
    assert.equal(s.tempNozzle, null);
  }
  assert.equal(sdcp.statusFrom({}).state, 'Unknown');
  assert.equal(sdcp.statusFrom({}).progress, 0);
});

test('progress can never leave 0-100, whatever the printer claims', () => {
  const wild = JSON.parse(JSON.stringify(STATUS));
  wild.Status.PrintInfo.CurrentLayer = 5000;
  wild.Status.PrintInfo.TotalLayer = 1000;
  assert.equal(sdcp.statusFrom(wild).progress, 100);

  wild.Status.PrintInfo.CurrentLayer = -50;
  assert.equal(sdcp.statusFrom(wild).progress, 0);
});
