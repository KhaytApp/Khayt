const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/webcam.js');

// The U1's literal replies, captured read-only from the bench printer.
const WEBCAMS = require('./fixtures/u1-webcams-list.json');
const FILES = require('./fixtures/u1-camera-files.json');
const HISTORY = require('./fixtures/u1-history-around-timelapse.json');
const MONITOR = require('./fixtures/u1-monitor-jpg-headers.json');

const U1 = { type: 'moonraker', host: '192.168.68.56', port: 7125 };
const U1_PORT = { type: 'moonraker', host: '192.168.68.56:7125' };
const DEAD = { enabled: false, snapshotUrl: 'http://192.168.68.56:8080/?action=snapshot' };

test('discovery asks the saved camera, then the printer, then the camera folder, then guesses', () => {
  const steps = W.discoverySteps(U1_PORT, DEAD);
  assert.deepEqual(steps.map((s) => s.source), ['configured', 'printer_list', 'camera_files', 'guess']);
  assert.equal(steps[0].snapshotUrl, DEAD.snapshotUrl);
  assert.equal(steps[1].listUrl, 'http://192.168.68.56:7125/server/webcams/list');
  assert.equal(steps[2].listUrl, 'http://192.168.68.56:7125/server/files/list?root=camera');
  // The saved :8080 address is also the first guess; it is asked once, not twice.
  assert.equal(steps[3].snapshotUrl, 'http://192.168.68.56/webcam/?action=snapshot');
});

test('a port kept beside a bare host reaches the API, and a Moonraker with none is 7125', () => {
  const a = W.discoverySteps(U1, null);
  assert.equal(a[0].listUrl, 'http://192.168.68.56:7125/server/webcams/list');
  assert.equal(a[1].listUrl, 'http://192.168.68.56:7125/server/files/list?root=camera');
  const bare = W.discoverySteps({ type: 'moonraker', host: '192.168.68.56' }, null);
  assert.equal(bare[0].listUrl, 'http://192.168.68.56:7125/server/webcams/list');
  // A port in the host wins over the field.
  assert.equal(W.apiWithPort({ type: 'moonraker', host: '10.0.0.2:7130', port: 7125 }).host, '10.0.0.2:7130');
  // OctoPrint with no port is left alone (its scheme's default).
  assert.equal(W.apiWithPort({ type: 'octoprint', host: '10.0.0.2' }).host, '10.0.0.2');
  assert.equal(W.cameraFileUrl(U1, 'monitor.jpg'), 'http://192.168.68.56:7125/server/files/camera/monitor.jpg');
});

test('no saved camera: the printer is asked first', () => {
  assert.equal(W.discoverySteps(U1_PORT, null)[0].source, 'printer_list');
  assert.equal(W.discoverySteps(U1_PORT, { snapshotUrl: '  ' })[0].source, 'printer_list');
});

test('only Moonraker has a camera folder to look in', () => {
  const octo = W.discoverySteps({ type: 'octoprint', host: '192.168.1.5' }, null);
  assert.ok(!octo.some((s) => s.source === 'camera_files'));
  assert.deepEqual(W.discoverySteps({ type: 'bambu', host: '192.168.1.5' }, null), []);
});

test('the U1 announces no camera: /server/webcams/list is an empty list', () => {
  const step = W.discoverySteps(U1_PORT, null).find((s) => s.source === 'printer_list');
  assert.equal(W.candidateFromStep(step, WEBCAMS, U1_PORT), null);
});

test('the U1 camera folder yields Snapmaker’s monitor.jpg on the printer’s own host', () => {
  const step = W.discoverySteps(U1_PORT, null).find((s) => s.source === 'camera_files');
  const cam = W.candidateFromStep(step, FILES, U1_PORT);
  assert.equal(cam.snapshotUrl, 'http://192.168.68.56:7125/server/files/camera/monitor.jpg');
  assert.equal(cam.vendor, 'snapmaker');
  assert.equal(cam.modifiedS, 1792670463.6568646);
  // And the SSRF guard passes it because it IS the printer's host.
  assert.deepEqual(W.assertWebcamHostAllowed(cam.snapshotUrl, U1_PORT), { ok: true, reason: null });
  // The unwrapped result array reads the same.
  assert.equal(W.parseCameraFiles(FILES.result, U1_PORT).snapshotUrl, cam.snapshotUrl);
});

test('a camera folder without monitor.jpg offers nothing', () => {
  const only = { result: FILES.result.filter((r) => r.path !== 'monitor.jpg') };
  assert.equal(W.parseCameraFiles(only, U1_PORT), null);
  assert.equal(W.parseCameraFiles({ error: { code: 400 } }, U1_PORT), null);
});

test('the monitor.jpg reply on the bench was a PAUSED camera, judged on the printer’s clock', () => {
  const age = W.stillAge({ lastModified: MONITOR.headers['Last-Modified'], date: MONITOR.headers.Date,
    // A Mac whose clock is an hour out must not change the verdict.
    nowMs: Date.parse('2026-10-22T13:07:07Z') });
  assert.deepEqual(age, { ageS: 364, paused: true });
  // The headers pass the image check: it is the age that says paused, not the bytes.
  assert.deepEqual(W.checkSnapshotHeaders(MONITOR.status, MONITOR.headers['Content-Type'],
    MONITOR.headers['Content-Length']), { ok: true, reason: null });
});

test('a fresh still is live; a source with no Last-Modified is not judged', () => {
  assert.deepEqual(W.stillAge({ lastModified: 'Thu, 22 Oct 2026 12:07:05 GMT', date: 'Thu, 22 Oct 2026 12:07:07 GMT' }),
    { ageS: 2, paused: false });
  assert.deepEqual(W.stillAge({ date: 'Thu, 22 Oct 2026 12:07:07 GMT' }), { ageS: null, paused: false });
  assert.deepEqual(W.stillAge({}), { ageS: null, paused: false });
  // No Date header: the asking machine's clock.
  assert.equal(W.stillAge({ lastModified: 'Thu, 22 Oct 2026 12:00:00 GMT',
    nowMs: Date.parse('2026-10-22T12:00:20Z') }).paused, false);
  // The file listing's mtime works when there is no header.
  assert.equal(W.stillAge({ fileModifiedS: 1792670463.6568646, nowMs: 1792670463656 + 31000 }).paused, true);
  // A still from the future (skew) is age 0, not negative.
  assert.equal(W.stillAge({ lastModified: 'Thu, 22 Oct 2026 12:08:00 GMT', date: 'Thu, 22 Oct 2026 12:07:07 GMT' }).ageS, 0);
  assert.equal(W.PAUSED_AFTER_S, 30);
});

test('a found camera is a suggestion, and the saved one is never replaced without asking', () => {
  const found = { snapshotUrl: 'http://192.168.68.56:7125/server/files/camera/monitor.jpg' };
  assert.equal(W.suggestionFor(DEAD, found), 'replace');
  assert.equal(W.suggestionFor(null, found), 'new');
  assert.equal(W.suggestionFor({ enabled: false, snapshotUrl: found.snapshotUrl }, found), 'enable');
  assert.equal(W.suggestionFor({ enabled: true, snapshotUrl: found.snapshotUrl }, found), 'same');
  assert.equal(W.suggestionFor(DEAD, null), null);
});

test('camera file names: one segment, a jpg or an mp4, nothing else', () => {
  assert.equal(W.cameraFileUrl(U1_PORT, 'Dark Knight_PLA_5h39m_20260626202455.mp4'),
    'http://192.168.68.56:7125/server/files/camera/Dark%20Knight_PLA_5h39m_20260626202455.mp4');
  for (const bad of ['../config/printer.cfg', 'a/b.mp4', '.hidden.mp4', 'x.gcode', 'x\\y.jpg', '', 'a\u0000.mp4']) {
    assert.equal(W.cameraFileUrl(U1_PORT, bad), '', bad);
  }
});

test('the bench U1’s job 00004E matches its timelapse by stem and start time', () => {
  const job = HISTORY.result.jobs.find((j) => j.job_id === '00004E');
  // The printer's history does not point at the file: the match is by name.
  assert.deepEqual(job.auxiliary_data, []);
  const m = W.matchTimelapse(job, FILES);
  assert.deepEqual(m, {
    video: 'd0de11b4e5a09b4119ca41bdab22300d_PLA_4h29m_20260803192022.mp4',
    cover: 'd0de11b4e5a09b4119ca41bdab22300d_PLA_4h29m_20260803192022.jpg',
    bytes: 59481447,
  });
});

test('a job that recorded no timelapse matches nothing, even beside ones that did', () => {
  for (const j of HISTORY.result.jobs.filter((x) => x.job_id !== '00004E')) {
    assert.equal(W.matchTimelapse(j, FILES), null, j.filename);
  }
});

test('a reprint of the same file does not claim the earlier print’s video', () => {
  const job = HISTORY.result.jobs.find((j) => j.job_id === '00004E');
  const later = { ...job, start_time: job.start_time + 86400 * 3, end_time: job.end_time + 86400 * 3 };
  assert.equal(W.matchTimelapse(later, FILES), null);
});

test('a printer clock writing local time (UTC+3) still matches', () => {
  const files = { result: [{ path: 'Part_PLA_1h_20260803222022.mp4', modified: 1785789035, size: 10 }] };
  const job = { filename: 'Part_PLA_1h.gcode', start_time: Date.UTC(2026, 7, 3, 19, 20, 22) / 1000,
    end_time: Date.UTC(2026, 7, 3, 20, 30, 0) / 1000 };
  assert.equal(W.matchTimelapse(job, files).video, 'Part_PLA_1h_20260803222022.mp4');
  assert.equal(W.matchTimelapse(job, files).cover, null);
});

test('stems: the folder and the extension go', () => {
  assert.equal(W.gcodeStem('sub/Name_PLA_1h.gcode'), 'Name_PLA_1h');
  assert.equal(W.splitTimelapseName('Dragon_Textured_PLA_20260621175317.mp4').stem, 'Dragon_Textured_PLA');
  assert.equal(W.splitTimelapseName('monitor.jpg'), null);
});

test('a job keeps file names, and the link is built from the machine’s host when it is opened', () => {
  const match = W.matchTimelapse(HISTORY.result.jobs.find((j) => j.job_id === '00004E'), FILES);
  const rec = W.timelapseRecord('M1', match, '2026-08-04T00:01:30.000Z');
  assert.deepEqual(rec, { machineId: 'M1', video: match.video, cover: match.cover,
    at: '2026-08-04T00:01:30.000Z', bytes: 59481447 });
  const order = { id: 'J1', printerTimelapse: rec };
  const link = W.timelapseLink(order, { id: 'M1', printerApi: U1_PORT });
  assert.equal(link.videoUrl, 'http://192.168.68.56:7125/server/files/camera/' + encodeURIComponent(match.video));
  assert.equal(link.coverUrl, 'http://192.168.68.56:7125/server/files/camera/' + encodeURIComponent(match.cover));
  assert.equal(link.bytes, 59481447);
  // The machine moved: the link follows it, because the book holds no address.
  assert.ok(W.timelapseLink(order, { id: 'M1', printerApi: { type: 'moonraker', host: '10.0.0.9:7125' } })
    .videoUrl.startsWith('http://10.0.0.9:7125/'));
});

test('a timelapse record from a restored or synced book cannot aim anywhere', () => {
  const m = { id: 'M1', printerApi: U1_PORT };
  assert.equal(W.timelapseLink({ printerTimelapse: { machineId: 'M1', video: '../../etc/passwd.mp4' } }, m), null);
  assert.equal(W.timelapseLink({ printerTimelapse: { machineId: 'M1', video: 'http://evil.example/x.mp4' } }, m), null);
  assert.equal(W.timelapseLink({ printerTimelapse: { machineId: 'M2', video: 'a_20260101000000.mp4' } }, m), null);
  assert.equal(W.timelapseLink({ printerTimelapse: { machineId: 'M1', video: 'a.mp4' } },
    { id: 'M1', printerApi: { type: 'octoprint', host: '192.168.1.2' } }), null);
  assert.equal(W.timelapseLink({}, m), null);
  assert.equal(W.timelapseRecord('M1', { video: 'a/b.mp4' }, 'x'), null);
});
