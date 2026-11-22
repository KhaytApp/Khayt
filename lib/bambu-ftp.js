'use strict';

/**
 * Minimal implicit-FTPS client for uploading a sliced file to a Bambu Lab
 * printer's SD cache (main-process, Node-only). Bambu's file endpoint is
 * implicit FTPS on :990 — the control AND data channels are TLS from the first
 * byte. Auth: user "bblp", password = the LAN access code.
 *
 * We implement just enough of RFC 959 to STOR one file in passive mode. The
 * reply parsers are pure + unit-tested; bambuFtpUpload() drives a real socket.
 */

const FTPS_DEFAULT_PORT = 990;

// ---- pure parsers (no I/O) -------------------------------------------------

/**
 * Given the accumulated control-channel text, return the first COMPLETE reply
 * and the leftover text, or null if no full reply has arrived yet. A reply is
 * complete when a line begins with "NNN " (3 digits + space), per RFC 959 —
 * this also terminates a multi-line "NNN-…" reply.
 */
function readFtpReply(text) {
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\d{3}) /.exec(lines[i]);
    if (m) {
      const consumed = lines.slice(0, i + 1).join('\n');
      const rest = lines.slice(i + 1).join('\n');
      return { code: parseInt(m[1], 10), text: consumed, rest };
    }
  }
  return null;
}

/** Parse a 227 passive-mode reply → { host, port } (or throw). */
function parsePasv(replyText) {
  const m = /\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)/.exec(replyText);
  if (!m) throw new Error('Bad PASV reply: ' + replyText);
  const host = `${m[1]}.${m[2]}.${m[3]}.${m[4]}`;
  const port = (parseInt(m[5], 10) << 8) + parseInt(m[6], 10);
  return { host, port };
}

// ---- live upload -----------------------------------------------------------

/**
 * Upload `data` (Buffer) to the printer as `remoteName`. Injectable `tls` +
 * `fs` for tests. Resolves { ok, fileName } or rejects with a useful message.
 */
function bambuFtpUpload({ host, port = FTPS_DEFAULT_PORT, accessCode, remoteName, data, timeoutMs = 60000, tls }) {
  tls = tls || require('node:tls');
  return new Promise((resolve, reject) => {
    let settled = false;
    const fail = (e) => { if (!settled) { settled = true; clearTimeout(timer); try { ctrl.destroy(); } catch {} reject(e instanceof Error ? e : new Error(String(e))); } };
    const done = (v) => { if (!settled) { settled = true; clearTimeout(timer); try { ctrl.end(); } catch {} resolve(v); } };
    const timer = setTimeout(() => fail(new Error('Bambu FTPS upload timed out')), timeoutMs);

    const ctrl = tls.connect({ host, port, rejectUnauthorized: false, timeout: timeoutMs });
    let buf = '';
    // A small command queue: each step sends a command and waits for an
    // expected reply-code class before advancing.
    let step = 0;
    const send = (cmd) => ctrl.write(cmd + '\r\n');

    const advance = (reply) => {
      const code = reply.code;
      switch (step) {
        case 0: // banner (220) → USER
          if (code !== 220) return fail(new Error('FTPS banner: ' + reply.text));
          send('USER bblp'); step = 1; break;
        case 1: // 331 need password → PASS
          send('PASS ' + String(accessCode || '')); step = 2; break;
        case 2: // 230 logged in → PBSZ
          if (code >= 400) return fail(new Error('Bambu rejected the access code (FTPS ' + code + ')'));
          send('PBSZ 0'); step = 3; break;
        case 3: send('PROT P'); step = 4; break;
        case 4: send('TYPE I'); step = 5; break;
        case 5: send('PASV'); step = 6; break;
        case 6: { // 227 → open data channel + STOR
          if (code !== 227) return fail(new Error('PASV failed: ' + reply.text));
          let pasv;
          try { pasv = parsePasv(reply.text); } catch (e) { return fail(e); }
          // Bambu hands back its own LAN IP; reuse the control host (PASV IPs
          // are often wrong behind the printer's own stack).
          const dataSock = tls.connect({ host, port: pasv.port, rejectUnauthorized: false, timeout: timeoutMs }, () => {
            dataSock.write(data, () => dataSock.end());
          });
          dataSock.on('error', fail);
          send('STOR ' + remoteName); step = 7; break;
        }
        case 7: // 150/125 transfer starting → wait for 226 completion
          if (code >= 400) return fail(new Error('STOR failed: ' + reply.text));
          if (code === 226 || code === 250) return done({ ok: true, fileName: remoteName });
          step = 8; break;
        case 8: // 226 after the 150
          if (code === 226 || code === 250) return done({ ok: true, fileName: remoteName });
          if (code >= 400) return fail(new Error('STOR failed: ' + reply.text));
          break;
        default: break;
      }
    };

    ctrl.on('error', fail);
    ctrl.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      for (;;) {
        const reply = readFtpReply(buf);
        if (!reply) break;
        buf = reply.rest;
        advance(reply);
      }
    });
  });
}

module.exports = { FTPS_DEFAULT_PORT, readFtpReply, parsePasv, bambuFtpUpload };
