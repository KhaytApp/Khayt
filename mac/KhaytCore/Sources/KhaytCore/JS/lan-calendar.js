'use strict';

/**
 * The shop's due dates as a calendar — `/calendar.ics`, one all-day event per
 * open job with a due date. Lifted verbatim out of `lib/lan-server.js` so the
 * native Mac app serves the same feed; the Node server draws from here now and
 * `test/lan-calendar.test.js` holds the module to the original route.
 *
 * PURE: the feed is a function of the book alone. Who may fetch it (the
 * calendar token or the owner PIN) is the host's gate, as it always was.
 */
(function (global) {

  /** The iCalendar text for a book. */
  function feed(store) {
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

  const api = { feed };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLanCalendar = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
