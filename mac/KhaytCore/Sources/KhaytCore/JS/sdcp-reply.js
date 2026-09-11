'use strict';
(function (global) {
/**
 * Which SDCP frame is the answer, and what it says.
 *
 * A mainboard PUSHES on its own schedule as well as answering, so a socket
 * carries traffic that has nothing to do with the question just asked. Deciding
 * what counts as the reply is the part that is easy to get subtly wrong and is
 * worth exactly one implementation.
 *
 * Split out of `lib/sdcp-client.js` so both apps use it. That file cannot be
 * loaded outside Node: it `require`s at module scope and owns a WebSocket and a
 * UDP socket. `lib/sdcp.js` underneath — framing and status mapping — was
 * already pure and is loaded directly by both.
 *
 * The TRANSPORT is each app's own: a Node WebSocket there,
 * `URLSessionWebSocketTask` here. The MEANING is this file, once.
 *
 * Pure: no sockets, no Buffer, no DOM.
 */

  // `lib/sdcp.js` is a plain CommonJS module in Node and publishes
  // `globalThis.KhaytSdcp` everywhere else, which is how it is reached in
  // JavaScriptCore.
  const sdcp = (typeof module !== 'undefined' && module.exports)
    ? require('./sdcp.js')
    : global.KhaytSdcp;

  /**
   * Is this message the answer to a question we asked THIS printer?
   *
   * A mainboard id is checked because one Khayt can watch several resin
   * printers, and on a network where a broadcast reply named the wrong address
   * a status could otherwise be filed against the wrong machine. Absent on the
   * message means "cannot tell" and is allowed through — the spec does not
   * promise it on every frame, and refusing every unlabelled frame would reject
   * a perfectly good status.
   */
  function forThisBoard(msg, mainboardId) {
    const id = msg && (msg.MainboardID || (msg.Data && msg.Data.MainboardID));
    return !id || !mainboardId || String(id) === String(mainboardId);
  }

  /** The reason on an error frame, or null if this is not one. */
  function errorIn(msg) {
    if (sdcp.messageKind(msg) !== 'error') return null;
    const d = (msg && msg.Data) || {};
    return String(d.ErrorMessage || d.Message || 'printer reported an error');
  }

  /**
   * A status, if this frame is one for us. Null means "keep listening".
   *
   * An error frame is the printer ANSWERING, so it is returned as a refusal
   * rather than skipped — skipping it would let the request time out and read
   * as "unreachable", which is the opposite of what happened.
   */
  function takeStatus(msg, mainboardId) {
    if (!forThisBoard(msg, mainboardId)) return null;
    const refused = errorIn(msg);
    if (refused) return { error: refused };
    if (sdcp.messageKind(msg) !== 'status' && !msg.Status) return null;
    return { status: sdcp.statusFrom(msg) };
  }

  /** The machine's own description of itself, on the same terms. */
  function takeAttributes(msg, mainboardId) {
    if (!forThisBoard(msg, mainboardId)) return null;
    const refused = errorIn(msg);
    if (refused) return { error: refused };
    if (sdcp.messageKind(msg) !== 'attributes' && !msg.Attributes) return null;
    return { attributes: sdcp.attributesFrom(msg) };
  }

  const api = { forThisBoard, errorIn, takeStatus, takeAttributes };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSdcpReply = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
