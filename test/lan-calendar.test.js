/**
 * lib/lan-calendar.js is the /calendar.ics feed, lifted out of lib/lan-server.js
 * so the Mac app serves the same bytes. THE PROOF METHOD: the route's block is
 * copied below VERBATIM and run against generated books; the module must
 * produce the identical calendar.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const LanCalendar = require('../lib/lan-calendar.js');

function original(store) {
          const calOrders = (store.printLog || []).filter(o =>
            o.dueDate && o.status !== 'completed' && o.status !== 'delivered' && o.status !== 'cancelled'
          );
          const formatIcalDate = (dateStr) => {
            // Parse YYYY-MM-DD → YYYYMMDD
            const d = new Date(dateStr + 'T00:00:00Z');
            if (isNaN(d.getTime())) return null;
            const y = d.getUTCFullYear();
            const m = String(d.getUTCMonth() + 1).padStart(2, '0');
            const dy = String(d.getUTCDate()).padStart(2, '0');
            return `${y}${m}${dy}`;
          };
          const calStatusMap = {
            printing: 'CONFIRMED', post: 'CONFIRMED', qc: 'CONFIRMED',
            pending: 'TENTATIVE', on_hold: 'CANCELLED'
          };
          const vevents = calOrders.map(o => {
            const dtstart = formatIcalDate(o.dueDate);
            if (!dtstart) return '';
            // DTEND = dueDate + 1 day
            const dEnd = new Date(o.dueDate + 'T00:00:00Z');
            dEnd.setUTCDate(dEnd.getUTCDate() + 1);
            const ye = dEnd.getUTCFullYear();
            const me = String(dEnd.getUTCMonth() + 1).padStart(2, '0');
            const de = String(dEnd.getUTCDate()).padStart(2, '0');
            const dtend = `${ye}${me}${de}`;
            const icalEscape = s => String(s || '').replace(/[\r\n]+/g, ' ').replace(/[\\;,]/g, '\\$&');
            const summary = `${icalEscape(o.project || o.id)} (${icalEscape(o.client || 'No client')})`;
            const icalStatus = calStatusMap[o.status] || 'TENTATIVE';
            return [
              'BEGIN:VEVENT',
              `UID:khayt-${o.id}@khaytapp.com`,
              `DTSTART;VALUE=DATE:${dtstart}`,
              `DTEND;VALUE=DATE:${dtend}`,
              `SUMMARY:${summary}`,
              `STATUS:${icalStatus}`,
              'END:VEVENT'
            ].join('\r\n');
          }).filter(Boolean).join('\r\n');
          const shopName = (store.settings?.shopName || 'Khayt').replace(/[\r\n]+/g, ' ').replace(/[\\;,]/g, '\\$&');
          const icalBody = [
            'BEGIN:VCALENDAR',
            'VERSION:2.0',
            'PRODID:-//Khayt//Khayt//EN',
            'CALSCALE:GREGORIAN',
            'METHOD:PUBLISH',
            `X-WR-CALNAME:${shopName} Orders`,
            vevents,
            'END:VCALENDAR'
          ].join('\r\n');
  return icalBody;
}

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
const pick = (r, list) => list[Math.floor(r() * list.length)];
function genBook(r) {
  const n = Math.floor(r() * 8);
  const printLog = [];
  for (let i = 0; i < n; i++) {
    const o = { id: `J-${i}`, status: pick(r, ['pending', 'printing', 'post', 'qc', 'completed', 'delivered', 'cancelled', 'on_hold', 'quote']) };
    if (r() < 0.8) o.dueDate = pick(r, ['2027-01-31', '2027-02-29', '2026-12-31', 'not-a-date', '']);
    if (r() < 0.7) o.project = pick(r, ['Bracket', 'Vase; with, commas\\', 'line\nbreak', '']);
    if (r() < 0.6) o.client = pick(r, ['Sara', 'A, B; C', '']);
    printLog.push(o);
  }
  return { printLog, settings: pick(r, [{ shopName: 'Khayt' }, { shopName: 'Al Noor; & Sons, Ltd' }, {}]) };
}

test('the feed is byte-identical to the route over generated books', () => {
  const r = rng(20260916);
  let events = 0;
  for (let i = 0; i < 400; i++) {
    const store = genBook(r);
    const expected = original(store);
    assert.equal(LanCalendar.feed(store), expected, `book ${i}: ${JSON.stringify(store)}`);
    events += (expected.match(/BEGIN:VEVENT/g) || []).length;
  }
  assert.ok(events > 200, `only ${events} events across the run`);
  assert.equal(LanCalendar.feed({}), original({}));
});

test('the server draws the feed from the module', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  assert.ok(src.includes('const icalBody = LanCalendar.feed(store);'));
  assert.ok(!src.includes("'PRODID:-//Khayt//Khayt//EN'"), 'an inline copy of the feed is back in the server');
});
