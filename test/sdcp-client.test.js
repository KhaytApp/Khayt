const { test } = require('node:test');
const assert = require('node:assert/strict');
const sdcp = require('../lib/sdcp.js');
const client = require('../lib/sdcp-client.js');

/*
 * There is no Elegoo resin printer on this bench, and there may not be one for
 * a while. lib/sdcp.js says as much and stops at the protocol edge on purpose.
 *
 * So this transport has one honest defence: every decision it makes has to be
 * reachable from a test. The socket is injected, and the fake below can do the
 * things a real one does at the worst moment — open late, answer out of order,
 * answer for a different machine, say nothing, hang up mid-handshake, hand back
 * a frame that is not JSON.
 *
 * What remains unproven is narrow and stated rather than implied: whether a real
 * mainboard accepts this frame and replies on the topic the spec promises.
 * Everything this side of that is covered here.
 */

/** A socket that behaves however a test needs it to. */
function fakeSocket({ openImmediately = false, script = [], onSend } = {}) {
  const listeners = new Map();
  const sock = {
    readyState: openImmediately ? 1 : 0,
    sent: [],
    closed: false,
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
      // A real socket connects asynchronously and then fires `open`. Emitting it
      // on a later turn is what makes the fake exercise the ordinary path rather
      // than only the already-open one.
      if (type === 'open' && !openImmediately) setTimeout(() => sock.emit('open'), 0);
    },
    send(data) {
      sock.sent.push(data);
      if (onSend) onSend(data, sock);
      // Whatever the script says to say back, in order.
      for (const step of script) sock.emit(step.type, step.payload);
    },
    close() { sock.closed = true; },
    emit(type, payload) {
      for (const fn of (listeners.get(type) || [])) {
        fn(type === 'message' ? { data: payload } : payload);
      }
    },
  };
  return sock;
}

const BOARD = 'MB-000123';
const statusFrame = (over = {}) => JSON.stringify({
  Topic: `sdcp/status/${BOARD}`,
  MainboardID: BOARD,
  Status: {
    CurrentStatus: 1,
    PrintInfo: { Status: 3, CurrentLayer: 250, TotalLayer: 1000, Filename: 'ring.ctb' },
    TempOfUVLED: 41,
    ...over,
  },
});

/* ── the happy path, and the one that is easy to get wrong ──────────────── */

test('a status is asked for, not waited for', () => {
  // Waiting for the mainboard's own push means a poll that sometimes takes ten
  // seconds because nothing happened to be broadcast — which reads as a
  // flapping printer rather than as a quiet one.
  let socket;
  const connect = () => (socket = fakeSocket({ script: [{ type: 'message', payload: statusFrame() }] }));
  return client.fetchStatus({ connect, ip: '192.168.1.50', mainboardId: BOARD }).then((st) => {
    const sent = JSON.parse(socket.sent[0]);
    assert.equal(sent.Data.Cmd, sdcp.CMD.STATUS_REFRESH);
    assert.equal(sent.Data.MainboardID, BOARD);
    assert.equal(sent.Topic, `sdcp/request/${BOARD}`);
    // …and the answer arrives in the shape every other adapter returns.
    assert.equal(st.type, 'sdcp');
    assert.equal(st.state, 'exposing');
    assert.equal(st.progress, 25, '250 of 1000 layers');
    assert.equal(st.progressSource, 'layers');
    assert.equal(st.tempNozzle, null, 'a resin printer has no nozzle to report');
    assert.equal(socket.closed, true, 'the socket was left open');
  });
});

test('a socket handed over already open is not waited on', () => {
  // A connect() that returns an open socket never fires `open` again, so
  // listening for it would hang until the timeout on the one case that was
  // ready immediately.
  const socket = fakeSocket({ openImmediately: true, script: [{ type: 'message', payload: statusFrame() }] });
  return client.fetchStatus({ connect: () => socket, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 250 })
    .then((st) => assert.equal(st.state, 'exposing'));
});

test('attributes come back as the machine describes itself', () => {
  const frame = JSON.stringify({
    Topic: `sdcp/attributes/${BOARD}`,
    MainboardID: BOARD,
    Attributes: { Name: 'Saturn', MachineName: 'ELEGOO Saturn 3', Resolution: '11520x5120', FirmwareVersion: '1.4.2' },
  });
  let socket;
  const connect = () => (socket = fakeSocket({ script: [{ type: 'message', payload: frame }] }));
  return client.fetchAttributes({ connect, ip: '10.0.0.4', mainboardId: BOARD }).then((a) => {
    assert.equal(JSON.parse(socket.sent[0]).Data.Cmd, sdcp.CMD.ATTRIBUTES);
    assert.equal(a.model, 'ELEGOO Saturn 3');
    assert.equal(a.resolution, '11520x5120');
  });
});

/* ── traffic that is not the answer ─────────────────────────────────────── */

test('the mainboard’s own chatter is skipped, not mistaken for the reply', () => {
  // It pushes on its own schedule as well as answering, so a socket carries
  // frames that have nothing to do with this request.
  const noise = JSON.stringify({ Topic: `sdcp/notice/${BOARD}`, MainboardID: BOARD, Data: { Message: 'film replaced' } });
  const connect = () => fakeSocket({ script: [
    { type: 'message', payload: 'not json at all' },
    { type: 'message', payload: noise },
    { type: 'message', payload: statusFrame() },
  ] });
  return client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 500 })
    .then((st) => assert.equal(st.state, 'exposing', 'noise was taken for the answer'));
});

test('a status for another printer is never filed against this one', () => {
  // One Khayt can watch several resin printers. A reply naming a different
  // board is somebody else's reading.
  const other = JSON.stringify({
    Topic: 'sdcp/status/MB-999', MainboardID: 'MB-999',
    Status: { CurrentStatus: 0, PrintInfo: { Status: 9 } },
  });
  const connect = () => fakeSocket({ script: [{ type: 'message', payload: other }] });
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 200 }),
    /timeout/i,
    'another machine’s status was accepted as this machine’s',
  );
});

test('an unlabelled frame is allowed through rather than refused', () => {
  // The spec does not promise MainboardID on every frame, and refusing every
  // unlabelled one would reject a perfectly good status.
  const bare = JSON.stringify({
    Topic: `sdcp/status/${BOARD}`,
    Status: { CurrentStatus: 0, PrintInfo: { Status: 9, CurrentLayer: 10, TotalLayer: 10 } },
  });
  const connect = () => fakeSocket({ script: [{ type: 'message', payload: bare }] });
  return client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 400 })
    .then((st) => assert.equal(st.state, 'idle'));
});

test('forThisBoard reads the id wherever the frame carries it', () => {
  assert.equal(client.forThisBoard({ MainboardID: BOARD }, BOARD), true);
  assert.equal(client.forThisBoard({ Data: { MainboardID: BOARD } }, BOARD), true);
  assert.equal(client.forThisBoard({ MainboardID: 'MB-999' }, BOARD), false);
  assert.equal(client.forThisBoard({}, BOARD), true, 'unlabelled must not be refused');
  assert.equal(client.forThisBoard({ MainboardID: BOARD }, ''), true, 'nothing to compare against');
});

/* ── the unhappy paths a poll loop actually meets ───────────────────────── */

test('an error frame is the printer ANSWERING, and says why', () => {
  // Letting this time out would report a printer that replied promptly as
  // unreachable, and send whoever reads the log looking at the network.
  const err = JSON.stringify({
    Topic: `sdcp/error/${BOARD}`, MainboardID: BOARD,
    Data: { ErrorMessage: 'File was sliced for a different machine' },
  });
  const connect = () => fakeSocket({ script: [{ type: 'message', payload: err }] });
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 300 }),
    /sliced for a different machine/,
  );
});

test('silence times out, and lets go of the socket', () => {
  let socket;
  const connect = () => (socket = fakeSocket({ script: [] }));   // answers nothing
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 120 }),
    /timeout/i,
  ).then(() => {
    // A descriptor per failed poll, on a printer that is merely switched off, is
    // one every thirty seconds forever.
    assert.equal(socket.closed, true, 'a timed-out poll leaked its socket');
  });
});

test('hanging up before answering is reported as that, not as a timeout', () => {
  // Reachable-and-refusing is a different fault from unreachable, and the log
  // is where somebody works out which.
  const connect = () => {
    const s = fakeSocket({ onSend: (_d, sock) => sock.emit('close') });
    return s;
  };
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 2000 }),
    /closed before answering/,
  );
});

test('a socket error rejects instead of hanging', () => {
  const connect = () => fakeSocket({ onSend: (_d, sock) => sock.emit('error') });
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 2000 }),
    /socket error/,
  );
});

test('connect itself failing is caught, not thrown at the poll loop', () => {
  const connect = () => { throw new Error('EHOSTUNREACH'); };
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD }),
    /connect failed: EHOSTUNREACH/,
  );
});

test('connect returning nothing is a failure, not a hang', () => {
  return assert.rejects(
    client.fetchStatus({ connect: () => null, ip: '10.0.0.4', mainboardId: BOARD }),
    /returned nothing/,
  );
});

test('send throwing after open is caught', () => {
  const connect = () => {
    const s = fakeSocket({ openImmediately: true });
    s.send = () => { throw new Error('socket already closing'); };
    return s;
  };
  return assert.rejects(
    client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 2000 }),
    /send failed: socket already closing/,
  );
});

test('a poll with no address or no board id refuses before opening anything', () => {
  let opened = 0;
  const connect = () => { opened++; return fakeSocket(); };
  return Promise.all([
    assert.rejects(client.fetchStatus({ connect, mainboardId: BOARD }), /no address/),
    assert.rejects(client.fetchStatus({ connect, ip: '10.0.0.4' }), /no mainboard id/),
    assert.rejects(client.fetchAttributes({ connect, mainboardId: BOARD }), /no address/),
  ]).then(() => assert.equal(opened, 0, 'a socket was opened for a request that could not be made'));
});

test('only the first acceptable answer settles it', () => {
  // Two statuses in one burst is one reading, and a second resolve must not
  // throw or overwrite the first.
  let socket;
  const connect = () => (socket = fakeSocket({ script: [
    { type: 'message', payload: statusFrame() },
    { type: 'message', payload: statusFrame({ PrintInfo: { Status: 9, CurrentLayer: 1000, TotalLayer: 1000 } }) },
    { type: 'close' },
  ] }));
  return client.fetchStatus({ connect, ip: '10.0.0.4', mainboardId: BOARD, timeoutMs: 400 })
    .then((st) => assert.equal(st.progress, 25, 'a later frame overwrote the settled answer'));
});

/* ── discovery ──────────────────────────────────────────────────────────── */

test('discovery replies are parsed, deduped and sorted', () => {
  const reply = (name, id, ip) => JSON.stringify({
    Id: 'brand', Data: { Name: name, MachineName: 'ELEGOO Mars 5', MainboardID: id, MainboardIP: ip },
  });
  const found = client.collectDiscovered([
    Buffer.from(reply('Saturn', 'MB-2', '10.0.0.5')),
    reply('Mars', 'MB-1', '10.0.0.4'),
    // The same printer answering on a second interface is still one printer.
    reply('Mars', 'MB-1', '10.0.0.4'),
    'not json',
    JSON.stringify({ Data: { Name: 'no id or ip' } }),
  ]);
  assert.equal(found.length, 2);
  assert.deepEqual(found.map((f) => f.name), ['Mars', 'Saturn']);
  assert.equal(found[0].ip, '10.0.0.4');
  assert.equal(found[0].mainboardId, 'MB-1');

  assert.deepEqual(client.collectDiscovered([]), []);
  assert.deepEqual(client.collectDiscovered(null), []);
});

/* ── how it is wired, which is the part a unit test cannot reach ────────── */

const fs = require('fs');
const path = require('path');
const mainJs = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

test('the SDCP branch sits behind the host guard, like every other adapter', () => {
  // A WebSocket URL built from a machine record is the same SSRF surface an HTTP
  // one is, and this branch is reached from a renderer-supplied machine list —
  // the poll handler says so in as many words. isAllowedPrinterHost restricts
  // every target to RFC1918 / link-local, and it has to run FIRST.
  const at = mainJs.indexOf('async function fetchPrinterStatus(');
  assert.ok(at > 0, 'fetchPrinterStatus moved — this guard is now checking nothing');
  const body = mainJs.slice(at, at + 4000);

  const guard = body.indexOf('resolvePrinterTarget(host)');
  const branch = body.indexOf("if (type === 'sdcp')");
  assert.ok(guard > 0, 'the host guard is not in fetchPrinterStatus');
  assert.ok(branch > 0, 'the SDCP branch is not in fetchPrinterStatus');
  assert.ok(guard < branch,
    'the SDCP branch runs before the host guard — a machine record could point a '
    + 'WebSocket at any address on the network');
});

test('SDCP refuses without a mainboard id rather than opening a socket to nothing', () => {
  // The id is the printer's address on this protocol: every frame is
  // topic-addressed by it, so a poll without one cannot be answered and must
  // say why rather than timing out for eight seconds per cycle.
  const at = mainJs.indexOf("if (type === 'sdcp')");
  const body = mainJs.slice(at, at + 700);
  assert.match(body, /mainboard ID/i, 'the missing-id case does not explain itself');
  assert.match(body, /sdcpClient\.fetchStatus\(/, 'the branch does not use the tested client');
  assert.match(body, /connect: \(url\) => new WebSocket\(url\)/,
    'the real socket is not injected — the tested seam is being bypassed');
});

test('the default SDCP port is the one the spec names', () => {
  // 3030 for the WebSocket; 3000 is discovery and is a different socket entirely.
  assert.equal(sdcp.WEBSOCKET_PORT, 3030);
  assert.equal(sdcp.DISCOVERY_PORT, 3000);
  assert.match(mainJs, /sdcp: 3030/, 'defaultPrinterPort does not know about SDCP');
  assert.equal(sdcp.websocketUrl('10.0.0.4'), 'ws://10.0.0.4:3030/websocket');
});
