const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  rrConnectResult, dsfConnectResult, objectModel, duetHeaterTemp,
  statusFromObjectModel, ENDPOINTS,
} = require('../lib/duet.js');
const { fileProgressPct } = require('../lib/printer-status.js');
const { extractActuals } = require('../lib/printer-actuals.js');

const helpers = { fileProgressPct, extractActuals, stockOpts: {} };

/* A Duet mid-job, as each transport delivers it. Same model, two envelopes. */
const JOB = {
  state: { status: 'processing' },
  job: {
    duration: 4200, filePosition: 337942, rawExtrusion: 12500,
    timesLeft: { file: 900 },
  },
  heat: { heaters: [{ current: 59.8 }, { current: 212.4 }], bedHeaters: [0] },
  tools: [{ heaters: [1] }],
};
const FILE = { fileName: '0:/gcodes/bracket.gcode', size: 1468987 };

// rr_model wraps in `result` and — because of the `f` flag — omits job.file.
const standalonePayload = { key: '', flags: 'd99fn', result: JOB };
// machine/model returns the model bare, complete, file included.
const sbcPayload = { ...JOB, job: { ...JOB.job, file: FILE } };

test('the two transports produce the same status from the same machine', () => {
  // This is the reason there is one parser rather than two. The envelope differs;
  // nothing else does. If these ever disagree, one transport has grown a quirk
  // the other has not.
  const standalone = statusFromObjectModel(standalonePayload, FILE, helpers);
  const sbc = statusFromObjectModel(sbcPayload, null, helpers);
  assert.deepEqual(standalone, sbc);

  assert.equal(sbc.progress, 23);
  assert.equal(sbc.filename, '0:/gcodes/bracket.gcode');
  assert.equal(sbc.state, 'processing');
  assert.equal(sbc.timeRemaining, 900);
  assert.equal(sbc.tempNozzle, 212.4);
  assert.equal(sbc.tempBed, 59.8);
  assert.equal(sbc.actuals.durationS, 4200);
  assert.equal(sbc.actuals.filamentMm, 12500);
});

test('objectModel unwraps rr_model and leaves a bare model alone', () => {
  assert.equal(objectModel({ result: JOB }), JOB);
  assert.equal(objectModel(JOB), JOB);
  for (const junk of [null, undefined, 'x', 5, []]) {
    assert.equal(typeof objectModel(junk), 'object');
  }
});

test('a standalone Duet with no separate file query still reports honestly', () => {
  // The live query alone: filePosition arrives with nothing to be a percentage
  // of. 0 is the right answer — the wrong one is 50,000,000%.
  const s = statusFromObjectModel(standalonePayload, null, helpers);
  assert.equal(s.progress, 0);
  assert.equal(s.filename, '');
  // …while the measured figures, which ARE in the live query, survive.
  assert.equal(s.actuals.durationS, 4200);
});

test('rr_connect: err 0 succeeds, and each failure says something different', () => {
  const ok = rrConnectResult({ err: 0, sessionTimeout: 8000, boardType: 'duet3mb6hc', sessionKey: 123456 });
  assert.equal(ok.ok, true);
  assert.equal(ok.sessionKey, '123456');

  // Older firmware authenticates by IP and returns no key. Not a failure.
  const noKey = rrConnectResult({ err: 0, sessionTimeout: 8000 });
  assert.equal(noKey.ok, true);
  assert.equal(noKey.sessionKey, null);

  const badPw = rrConnectResult({ err: 1 });
  assert.equal(badPw.ok, false);
  assert.match(badPw.error, /password/i);

  // Not a Khayt problem, and the message should not imply it is: this is a Duet
  // Web Control tab left open on somebody's laptop.
  const full = rrConnectResult({ err: 2 });
  assert.equal(full.ok, false);
  assert.match(full.error, /sessions/i);

  for (const junk of [null, {}, { err: 'x' }, 'nope']) {
    assert.equal(rrConnectResult(junk).ok, false, JSON.stringify(junk));
  }
});

test('machine/connect: a key or a clear refusal', () => {
  assert.deepEqual(dsfConnectResult({ sessionKey: 'abc' }), { ok: true, sessionKey: 'abc', error: null });
  // DSF signals a bad password with HTTP 403, so a body with no key means
  // something else went wrong and must not read as authenticated.
  for (const junk of [{}, null, { sessionKey: '' }, { sessionKey: null }]) {
    assert.equal(dsfConnectResult(junk).ok, false, JSON.stringify(junk));
  }
});

test('the endpoints differ in exactly the ways the vendors document', () => {
  // Standalone needs a second query because `f` filters job.file out; SBC's
  // model is complete, so it must NOT make one.
  assert.ok(ENDPOINTS.standalone.file, 'standalone fetches the file separately');
  assert.equal(ENDPOINTS.sbc.file, null, 'machine/model already carries it');

  // "Every request except for rr_connect returns 401" / SBC answers 403.
  assert.equal(ENDPOINTS.standalone.unauthorized, 401);
  assert.equal(ENDPOINTS.sbc.unauthorized, 403);

  // "If no password is expected, the `password` key can be omitted."
  assert.equal(ENDPOINTS.sbc.connect(''), '/machine/connect');
  assert.match(ENDPOINTS.sbc.connect('hunter2'), /^\/machine\/connect\?password=hunter2$/);

  // rr_connect always carries the parameter — omitting it means `reprap`.
  assert.match(ENDPOINTS.standalone.connect(''), /^\/rr_connect\?password=&sessionKey=yes$/);

  // A password with URL-significant characters must not break out of the query.
  assert.equal(ENDPOINTS.sbc.connect('a&b=c d'), '/machine/connect?password=a%26b%3Dc%20d');
  assert.match(ENDPOINTS.standalone.connect('a&b'), /password=a%26b&sessionKey=yes$/);
});

test('heaters are resolved from the machine, not from index 0 and 1', () => {
  const heaters = [{ current: 59.8 }, { current: 212.4 }];

  // A stock config publishes no mapping and must keep working unchanged.
  assert.equal(duetHeaterTemp({ heaters }, undefined, 'bed'), 59.8);
  assert.equal(duetHeaterTemp({ heaters }, undefined, 'tool'), 212.4);

  // The same machine, describing itself. Same answers.
  assert.equal(duetHeaterTemp({ heaters, bedHeaters: [0] }, [{ heaters: [1] }], 'bed'), 59.8);
  assert.equal(duetHeaterTemp({ heaters, bedHeaters: [0] }, [{ heaters: [1] }], 'tool'), 212.4);

  // A bedless machine with its hotend on heater 0. RRF documents bedHeaters
  // entries as "may be -1 if unconfigured".
  const bedless = { heaters: [{ current: 212.4 }], bedHeaters: [-1] };
  assert.equal(duetHeaterTemp(bedless, [{ heaters: [0] }], 'bed'), null);
  assert.equal(duetHeaterTemp(bedless, [{ heaters: [0] }], 'tool'), 212.4);
});

test('junk in never becomes numbers out', () => {
  for (const junk of [null, undefined, {}, { result: null }, { job: 'x' }, { job: { file: 'x' } }]) {
    const s = statusFromObjectModel(junk, null, helpers);
    assert.equal(s.type, 'duet', JSON.stringify(junk));
    assert.equal(s.progress, 0);
    assert.equal(s.filename, '');
    assert.equal(typeof s.state, 'string');
  }
});

test('the parser needs no siblings — it works with no helpers injected', () => {
  // lib/duet.js is required by the main process, and a module that silently
  // depends on two others is a module that breaks when one moves.
  const s = statusFromObjectModel(sbcPayload);
  assert.equal(s.progress, 23);
  assert.equal(s.actuals, undefined, 'actuals only appear when an extractor is given');
});
