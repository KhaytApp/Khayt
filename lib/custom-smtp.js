'use strict';

const net = require('net');
const tls = require('tls');
const { isBlockedLoopbackOrMetadata } = require('./host-guard');
// The rules — reply boundaries, header sanitising, dot-stuffing, the message
// itself — live in a module with no Node imports, because the Mac app speaks
// this protocol too and cannot require('net'). See lib/smtp-format.js.
const {
  EHLO_NAME, sanitizeHeader, dotStuff, offersStartTls, replyIsComplete, buildMessage,
} = require('./smtp-format');

function readReply(socket) {
  return new Promise((resolve, reject) => {
    let buf = '';
    const onData = (chunk) => {
      buf += chunk.toString();
      const reply = replyIsComplete(buf);
      if (!reply) return;
      socket.off('data', onData);
      socket.off('error', onErr);
      if (!reply.ok) reject(new Error(reply.text.split('\r\n').pop().trim()));
      else resolve(reply.text);
    };
    const onErr = (e) => reject(e);
    socket.on('data', onData);
    socket.on('error', onErr);
  });
}

function writeCmd(socket, cmd) {
  socket.write(`${cmd}\r\n`);
}

async function smtpDialog(sock, { user, pass, from, fromName, to, subject, html }) {
  const safeFrom = sanitizeHeader(from);
  const safeTo = sanitizeHeader(to);
  if (user && pass) {
    writeCmd(sock, 'AUTH LOGIN');
    await readReply(sock);
    writeCmd(sock, Buffer.from(String(user)).toString('base64'));
    await readReply(sock);
    writeCmd(sock, Buffer.from(String(pass)).toString('base64'));
    await readReply(sock);
  }
  writeCmd(sock, `MAIL FROM:<${safeFrom}>`);
  await readReply(sock);
  writeCmd(sock, `RCPT TO:<${safeTo}>`);
  await readReply(sock);
  writeCmd(sock, 'DATA');
  await readReply(sock);
  // Headers, body, dot-stuffing and the terminating dot, all from the shared
  // rule; the trailing CRLF is writeCmd's.
  writeCmd(sock, buildMessage({ from, fromName, to, subject, html }));
  await readReply(sock);
  writeCmd(sock, 'QUIT');
  try { await readReply(sock); } catch { /* ignore */ }
  sock.end();
}

/** Minimal SMTP send for custom relay (STARTTLS + AUTH LOGIN). */
async function sendCustomSmtp({ host, port = 587, user, pass, secure = false, from, fromName, to, subject, html }) {
  if (!host || !from || !to) return { ok: false, error: 'Missing host, from, or to' };
  const smtpHost = String(host).trim().toLowerCase();
  if (isBlockedLoopbackOrMetadata(smtpHost)) {
    return { ok: false, error: 'SMTP host not allowed (loopback or metadata address)' };
  }

  const socket = await new Promise((resolve, reject) => {
    const s = secure
      ? tls.connect({ host, port, servername: host, rejectUnauthorized: true }, () => resolve(s))
      : net.connect({ host, port }, () => resolve(s));
    s.setTimeout(20000, () => { s.destroy(); reject(new Error('SMTP timeout')); });
    s.on('error', reject);
  });

  try {
    await readReply(socket);
    writeCmd(socket, `EHLO ${EHLO_NAME}`);
    const ehlo = await readReply(socket);

    if (!secure) {
      // Never send AUTH credentials over a plaintext socket. If the server
      // doesn't advertise STARTTLS (or an active MITM stripped it from EHLO),
      // refuse rather than leak the password in cleartext.
      if (!offersStartTls(ehlo)) {
        throw new Error('SMTP server did not offer STARTTLS — refusing to send credentials over an unencrypted connection. Use a TLS port (465) or a server that supports STARTTLS.');
      }
      writeCmd(socket, 'STARTTLS');
      await readReply(socket);
      const tlsSocket = await new Promise((resolve, reject) => {
        const ts = tls.connect({ socket, servername: host, rejectUnauthorized: true }, () => resolve(ts));
        ts.on('error', reject);
      });
      writeCmd(tlsSocket, `EHLO ${EHLO_NAME}`);
      await readReply(tlsSocket);
      await smtpDialog(tlsSocket, { user, pass, from, fromName, to, subject, html });
      return { ok: true };
    }

    await smtpDialog(socket, { user, pass, from, fromName, to, subject, html });
    return { ok: true };
  } catch (e) {
    try { socket.destroy(); } catch { /* ignore */ }
    return { ok: false, error: String(e.message || e) };
  }
}

module.exports = { sendCustomSmtp, sanitizeHeader, dotStuff };
