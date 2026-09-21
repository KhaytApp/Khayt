'use strict';

/**
 * The parts of an SMTP conversation that are RULES rather than plumbing.
 *
 * ── WHY THIS IS ITS OWN MODULE ────────────────────────────────────────────
 *
 * `custom-smtp.js` opens a socket with Node's `net` and `tls`, which the Mac
 * app has no way to run: its JavaScript lives in JavaScriptCore, where there
 * is no `require('net')`. So the Mac speaks SMTP through Network.framework,
 * in Swift — and the moment there are two implementations there are two sets
 * of answers to "where does this reply end", "what may go in a Subject" and
 * "which lines get a second dot".
 *
 * Getting those wrong is not a visible bug. A header that is not sanitised is
 * an injection; a body that is not dot-stuffed is a truncated email; a reply
 * boundary read wrong is a client that hangs on a multi-line greeting. All
 * three look like "it worked" until the day they do not.
 *
 * So the rules live here, with no Node imports at all, which means this file
 * runs in both hosts: the Electron app requires it, and the Mac bundles it and
 * pins its Swift against it in `KhaytCoreTests/Parity.swift`.
 */

(function (global) {
  'use strict';

  /** The name this app gives in EHLO. Both apps must say the same thing. */
  const EHLO_NAME = 'khayt.local';

  /** Strip CR/LF and other control chars so addresses/subjects can't inject SMTP commands or headers. */
  function sanitizeHeader(value) {
    // eslint-disable-next-line no-control-regex
    return String(value || '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim();
  }

  /** Dot-stuff message data per RFC 5321 so body lines beginning with "." can't terminate DATA early. */
  function dotStuff(data) {
    return String(data || '')
      .replace(/\r\n|\r|\n/g, '\r\n')   // normalize line endings
      .replace(/^\./gm, '..');          // escape leading dots on every line
  }

  /**
   * Did the server offer to encrypt?
   *
   * Asked of the whole EHLO response, because the capability arrives as one of
   * its continuation lines. A server that does not offer it gets no password —
   * see `custom-smtp.js`, and `SmtpClient.swift`, which both refuse on this.
   *
   * ANCHORED TO A LINE, not searched for anywhere in the text: a server whose
   * greeting happens to contain the word (a hostname, a banner advertising the
   * product) would otherwise talk this app into sending a password in the clear.
   */
  function offersStartTls(ehlo) {
    return /^250[ -]STARTTLS\s*$/im.test(String(ehlo || ''));
  }

  /**
   * Has a complete reply arrived, and what did it say?
   *
   * Returns `null` while more bytes are still needed — a caller reads again —
   * or `{ code, text, ok }`.
   *
   * ── THE RULE IS THE SPACE, NOT THE NEWLINE ────────────────────────────────
   *
   * A multi-line reply is `250-` on every line but the last, which is `250 `.
   * Ending on the first CRLF would take the first line of an EHLO response as
   * the whole thing and miss STARTTLS entirely — which is not a hang, it is a
   * client that decides the server cannot encrypt and refuses to send.
   */
  function replyIsComplete(buffer) {
    const text = String(buffer || '');
    const lines = text.split('\r\n').filter(Boolean);
    const last = lines[lines.length - 1] || '';
    if (!/^\d{3} /.test(last)) return null;
    const code = parseInt(last.slice(0, 3), 10);
    // 4xx is a try-again and 5xx a refusal; both end the send, and the line is
    // what the shop is shown, so it is carried rather than summarised.
    return { code, text: text.trim(), ok: code < 400 };
  }

  /**
   * The whole DATA payload, terminator included.
   *
   * The headers are the ones `custom-smtp.js` has always written, in that order.
   * The trailing dot line is part of what is returned rather than left to the
   * caller: it is the single most consequential character in the protocol, and a
   * transport that forgot it would hang rather than fail.
   */
  function buildMessage({ from, fromName, to, subject, html }) {
    const safeFrom = sanitizeHeader(from);
    const safeTo = sanitizeHeader(to);
    const safeFromName = sanitizeHeader(fromName);
    const safeSubject = sanitizeHeader(subject);
    const fromLine = safeFromName ? `${safeFromName} <${safeFrom}>` : safeFrom;
    const headers = [
      `From: ${fromLine}`,
      `To: ${safeTo}`,
      `Subject: ${safeSubject}`,
      'MIME-Version: 1.0',
      'Content-Type: text/html; charset=UTF-8',
      '',
    ].join('\r\n');
    return `${dotStuff(`${headers}\r\n${html || ''}`)}\r\n.`;
  }

  const api = {
    EHLO_NAME, sanitizeHeader, dotStuff, offersStartTls, replyIsComplete, buildMessage,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSmtpFormat = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
