const { test } = require('node:test');
const assert = require('node:assert/strict');
const A = require('../lib/active-count.js');

test('the body holds exactly the six fields the privacy page names', () => {
  const b = A.buildBody({ platform: 'win32', version: '3.11.21', lastCounted: null, today: '2026-10-21' });
  assert.deepEqual(Object.keys(b).sort(), [...A.FIELDS].sort());
  assert.deepEqual(b, { platform: 'win', channel: 'stable', version: '3.11.21', firstThisWeek: true, firstThisMonth: true, firstEver: true });
});

test('platform and channel come from the running build', () => {
  assert.equal(A.platformOf('linux'), 'linux');
  assert.equal(A.platformOf('darwin'), 'mac');
  assert.equal(A.channelOf('3.7.0-beta.25'), 'beta');
  assert.equal(A.channelOf('4.0.0-alpha.85'), 'alpha');
  assert.equal(A.channelOf('3.11.21'), 'stable');
});

test('a version the cloud would refuse is not sent', () => {
  assert.equal(A.buildBody({ platform: 'linux', version: '3.11', today: '2026-10-21' }), null);
  assert.equal(A.buildBody({ platform: 'linux', version: '3.11.21-RC1', today: '2026-10-21' }), null);
});

test('ISO weeks start on Monday and take the year of their Thursday', () => {
  assert.equal(A.isoWeek('2026-10-19'), '2026-W43'); // Monday
  assert.equal(A.isoWeek('2026-10-25'), '2026-W43'); // Sunday
  assert.equal(A.isoWeek('2026-10-26'), '2026-W44');
  assert.equal(A.isoWeek('2027-01-01'), '2026-W53'); // a Friday: still 2026's last week
  assert.equal(A.isoWeek('2025-12-29'), '2026-W01'); // a Monday: already 2026's first
});

test('the flags say first counted day of the week, month and ever', () => {
  assert.deepEqual(A.flags(null, '2026-10-21'), { firstThisWeek: true, firstThisMonth: true, firstEver: true });
  assert.deepEqual(A.flags('2026-10-20', '2026-10-21'), { firstThisWeek: false, firstThisMonth: false, firstEver: false });
  assert.deepEqual(A.flags('2026-10-25', '2026-10-26'), { firstThisWeek: true, firstThisMonth: false, firstEver: false });
  assert.deepEqual(A.flags('2026-10-31', '2026-11-01'), { firstThisWeek: false, firstThisMonth: true, firstEver: false });
  // firstEver never comes without the other two.
  for (const last of [null, 'garbage', '2026-10-20']) {
    const f = A.flags(last, '2026-10-21');
    if (f.firstEver) assert.ok(f.firstThisWeek && f.firstThisMonth);
  }
});

test('once a UTC day, never while off, never before READY', () => {
  assert.equal(A.due({}, '2026-10-21', true), true);
  assert.equal(A.due({ doneDay: '2026-10-21' }, '2026-10-21', true), false);
  assert.equal(A.due({ doneDay: '2026-10-20' }, '2026-10-21', true), true);
  assert.equal(A.due({ off: true }, '2026-10-21', true), false);
  assert.equal(A.due({}, '2026-10-21', false), false);
});

test('only a 200 counts; a 422 ends the day; anything else is tried again', () => {
  const s = { lastCounted: '2026-10-01' };
  assert.deepEqual(A.after(s, '2026-10-21', 200), { lastCounted: '2026-10-21', doneDay: '2026-10-21' });
  assert.deepEqual(A.after(s, '2026-10-21', 422), { lastCounted: '2026-10-01', doneDay: '2026-10-21' });
  for (const st of [404, 500, 503, 0]) assert.deepEqual(A.after(s, '2026-10-21', st), s);
  // Turning it off keeps the dates, so turning it back on is not a new install.
  assert.deepEqual(A.after({ ...s, off: true }, '2026-10-21', 404), { ...s, off: true });
});

test('it is on, and says which privacy section allows it', () => {
  // Every field sent is named at khaytapp.com/privacy#active-count-en. Adding
  // one means changing that page first.
  assert.equal(A.READY, true);
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'lib', 'active-count.js'), 'utf8');
  assert.match(src, /khaytapp\.com\/privacy#active-count-en/);
});
