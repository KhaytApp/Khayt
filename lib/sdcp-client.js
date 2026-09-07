'use strict';
/**
 * Talking to an SDCP printer — the half lib/sdcp.js deliberately does not do.
 *
 * That module is pure and says why: framing and status mapping are the parts
 * easy to get subtly wrong, and they can be tested completely without hardware.
 * What it left out was the transport, and "add sockets later" is how a protocol
 * layer ends up sitting in a repository for months being nobody's feature.
 *
 * THE SOCKET IS INJECTED, and that is the whole design.
 *
 * There is no Elegoo resin printer on this bench — the hardware here is a Prusa
 * CORE One and a Snapmaker U1 — so this code cannot be proven against a machine
 * today. Code that cannot meet its hardware has exactly one honest defence,
 * which is that every decision it makes is reachable from a test. So `connect`
 * is a parameter: main.js passes the real WebSocket, the tests pass a fake that
 * can open late, answer out of order, say nothing at all, or die mid-handshake.
 *
 * What is still unproven after all that is narrow and worth naming: whether an
 * actual mainboard accepts this frame and answers on the topic the spec says it
 * will. Everything above that line is covered.
 */
(function (global) {
  // REQUIRED OUTRIGHT, with no global fallback, because there is nothing to
  // fall back to: `sdcp.js` is a plain CommonJS module and publishes no global,
  // and this file speaks UDP and WebSocket, so it could not run in a browser or
  // in JavaScriptCore even if it did. The fallback that used to be here named
  // `KhaytSdcp`, which nothing has ever defined — it promised a portability
  // that does not exist and would have resolved to undefined the first time
  // anything but Node loaded this.
  const sdcp = require('./sdcp.js');

  /** Long enough for a busy mainboard mid-layer, short enough that a poll loop
   *  running every 30s never overlaps itself. */
  const DEFAULT_TIMEOUT_MS = 8000;

  /** Socket states, spelled out rather than assumed from a number. */
  const OPEN = 1;

  /**
   * Ask a printer one question and hang up.
   *
   * Deliberately NOT a long-lived connection. Khayt polls every machine on a
   * timer through one shared loop, and a persistent socket per printer would
   * mean reconnect logic, backoff, and a liveness question for every machine —
   * a lot of state for a reading taken twice a minute. A resin print is measured
   * in hours; nothing here is worth a permanent socket.
   *
   * Resolves with whatever `pick` returns for the first message it accepts.
   * Rejects on error, on close-before-answer, and on timeout — the caller is a
   * poll loop that already treats a throw as "missed a poll".
   */
  function askOnce(opts) {
    const {
      connect, url, request, pick,
      timeoutMs = DEFAULT_TIMEOUT_MS,
    } = opts || {};
    return new Promise((resolve, reject) => {
      let socket = null;
      let settled = false;
      let timer = null;

      // Every exit runs through here. A socket left open on the unhappy path is
      // a file descriptor per failed poll, which on a printer that is merely
      // switched off is one every thirty seconds, forever.
      const finish = (err, value) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        try { if (socket) socket.close(); } catch { /* already gone */ }
        if (err) reject(err); else resolve(value);
      };

      timer = setTimeout(() => finish(new Error('SDCP timeout')), timeoutMs);

      try {
        socket = connect(url);
      } catch (e) {
        return finish(new Error('SDCP connect failed: ' + (e && e.message ? e.message : e)));
      }
      if (!socket) return finish(new Error('SDCP connect returned nothing'));

      const send = () => {
        try {
          socket.send(JSON.stringify(request));
        } catch (e) {
          finish(new Error('SDCP send failed: ' + (e && e.message ? e.message : e)));
        }
      };

      socket.addEventListener('message', (ev) => {
        let msg;
        try {
          const raw = ev && typeof ev === 'object' && 'data' in ev ? ev.data : ev;
          msg = typeof raw === 'string' ? JSON.parse(raw) : raw;
        } catch { return; }        // a frame we cannot read is not a reason to fail the poll
        if (!msg) return;

        // The mainboard PUSHES on its own schedule as well as answering, so a
        // socket carries traffic that has nothing to do with this request. An
        // unrecognised message is skipped rather than treated as the answer.
        try {
          const taken = pick(msg);
          if (taken !== undefined && taken !== null) finish(null, taken);
        } catch (e) {
          finish(new Error('SDCP reply rejected: ' + (e && e.message ? e.message : e)));
        }
      });

      socket.addEventListener('error', () => finish(new Error('SDCP socket error')));
      // Closed before it answered. Distinct from a timeout on purpose: this one
      // means the printer is reachable and hung up, which is worth reading in a log.
      socket.addEventListener('close', () => finish(new Error('SDCP closed before answering')));

      // Listening BEFORE asking, which is not merely tidy. A reply that arrives
      // in the same turn as the send — a socket already open, a stub, a local
      // mainboard answering fast — lands before a listener attached afterwards
      // exists, and is dropped. The request then times out having been answered,
      // which is the kind of fault that reads as a network problem forever.
      //
      // A socket handed over already open never fires `open` again either, so
      // waiting for that event would hang the one case that was ready first.
      if (socket.readyState === OPEN) send();
      else socket.addEventListener('open', send);
    });
  }

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

  /**
   * One status reading, in the shape every other Khayt adapter returns.
   *
   * A STATUS_REFRESH is sent rather than waiting for the mainboard's own push:
   * the push interval is the printer's business, and a poll that sometimes takes
   * ten seconds because nothing happened to be broadcast is a poll that reads as
   * a flapping printer.
   */
  function fetchStatus(opts) {
    const { connect, ip, mainboardId, timeoutMs, brandId } = opts || {};
    if (!ip) return Promise.reject(new Error('SDCP: no address'));
    if (!mainboardId) return Promise.reject(new Error('SDCP: no mainboard id'));
    return askOnce({
      connect,
      url: sdcp.websocketUrl(ip),
      timeoutMs,
      request: sdcp.buildRequest(sdcp.CMD.STATUS_REFRESH, { mainboardId, brandId }),
      pick: (msg) => {
        if (!forThisBoard(msg, mainboardId)) return null;
        // An error frame is the printer answering — surface its reason rather
        // than letting the request time out and read as "unreachable".
        if (sdcp.messageKind(msg) === 'error') {
          const d = msg.Data || {};
          throw new Error(String(d.ErrorMessage || d.Message || 'printer reported an error'));
        }
        if (sdcp.messageKind(msg) !== 'status' && !msg.Status) return null;
        return sdcp.statusFrom(msg);
      },
    });
  }

  /** The machine's own description of itself — model, resolution, firmware. */
  function fetchAttributes(opts) {
    const { connect, ip, mainboardId, timeoutMs, brandId } = opts || {};
    if (!ip) return Promise.reject(new Error('SDCP: no address'));
    if (!mainboardId) return Promise.reject(new Error('SDCP: no mainboard id'));
    return askOnce({
      connect,
      url: sdcp.websocketUrl(ip),
      timeoutMs,
      request: sdcp.buildRequest(sdcp.CMD.ATTRIBUTES, { mainboardId, brandId }),
      pick: (msg) => {
        if (!forThisBoard(msg, mainboardId)) return null;
        if (sdcp.messageKind(msg) !== 'attributes' && !msg.Attributes) return null;
        return sdcp.attributesFrom(msg);
      },
    });
  }

  /**
   * Collect the replies to a discovery broadcast.
   *
   * Pure: the caller owns the socket and hands the datagrams over, exactly as
   * lib/printer-discovery.js takes mDNS records rather than opening anything.
   * Deduped by mainboard id, because a printer on two interfaces answers twice
   * and is still one printer.
   */
  function collectDiscovered(datagrams) {
    const byId = new Map();
    for (const raw of (Array.isArray(datagrams) ? datagrams : [])) {
      const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : raw;
      const found = sdcp.parseDiscoveryReply(text);
      if (!found || !found.mainboardId) continue;
      if (!byId.has(found.mainboardId)) byId.set(found.mainboardId, found);
    }
    return [...byId.values()].sort((a, b) => String(a.name).localeCompare(String(b.name)));
  }

  const api = {
    askOnce, fetchStatus, fetchAttributes, collectDiscovered, forThisBoard,
    DEFAULT_TIMEOUT_MS,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSdcpClient = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
