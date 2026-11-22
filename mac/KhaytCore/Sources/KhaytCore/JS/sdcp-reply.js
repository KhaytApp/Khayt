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

  /**
   * `sdcp_print_ctrl_ack_t`, from the spec's print-control section. Pause,
   * stop and continue (129/130/131) document only `Ack: 0`; they share the
   * print-control command block, so a non-zero Ack is read against this table
   * and anything outside it is quoted by number.
   */
  const PRINT_CTRL_ACK = {
    1: 'Busy',
    2: 'File not found',
    3: 'MD5 verification failed',
    4: 'File read failed',
    5: 'Resolution mismatch',
    6: 'Unrecognized file format',
    7: 'Machine model mismatch',
  };

  /**
   * The reply to a command we sent, or null if this frame is not it.
   *
   * The spec's reply is `{ Data: { Cmd, Data: { Ack }, RequestID, MainboardID },
   * Topic: "sdcp/response/<id>" }`. It is matched on Cmd AND on RequestID when
   * the frame carries one: a mainboard answering an earlier command — or
   * another client's — must not be taken as this one's answer. An error frame
   * for this board is the printer answering too, and is a refusal.
   *
   * Returns `{ ok: true }` or `{ ok: false, ack, error }`.
   */
  function takeAck(msg, mainboardId, cmd, requestId) {
    if (!forThisBoard(msg, mainboardId)) return null;
    const refused = errorIn(msg);
    if (refused) return { ok: false, ack: null, error: refused };
    if (sdcp.messageKind(msg) !== 'response') return null;
    const d = (msg && msg.Data) || {};
    if (Number(d.Cmd) !== Number(cmd)) return null;
    if (requestId && d.RequestID != null && String(d.RequestID) !== String(requestId)) return null;
    const ack = d.Data && typeof d.Data === 'object' ? d.Data.Ack : undefined;
    if (ack === 0 || ack === '0') return { ok: true };
    const n = Number(ack);
    const why = Number.isInteger(n) && PRINT_CTRL_ACK[n]
      ? PRINT_CTRL_ACK[n]
      : `the printer answered Ack ${ack === undefined ? '(none)' : String(ack)}`;
    return { ok: false, ack: Number.isInteger(n) ? n : null, error: why };
  }

  const api = { forThisBoard, errorIn, takeStatus, takeAttributes, takeAck, PRINT_CTRL_ACK };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSdcpReply = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
