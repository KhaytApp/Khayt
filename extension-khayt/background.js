// The extension's background: the popup's messages to Khayt go through here.
//
// A popup closes the moment the shop clicks elsewhere, and a native message in
// flight from it dies with it. Sent from here, the save completes whether the
// popup is still open or not.
//
// A CLASSIC SCRIPT, not a module, so the one file loads the same way as
// Chrome's service worker, Firefox's event page and Safari's non-persistent
// background page. `src/native.js` is the popup's copy of the same two rules.
'use strict';

const api = globalThis.browser || globalThis.chrome;
const HOST = 'app.khayt.mac';

async function sendToKhayt(message) {
  try {
    const reply = await api.runtime.sendNativeMessage(HOST, message);
    if (reply && typeof reply === 'object' && typeof reply.state === 'string') return reply;
    return { ok: false, state: 'no-host' };
  } catch (e) {
    return { ok: false, state: 'no-host', error: String((e && e.message) || e).slice(0, 200) };
  }
}

api.runtime.onMessage.addListener((msg, sender, reply) => {
  // Only the extension's own pages: there are no content scripts, so a
  // message from a tab is not one of ours.
  if (!msg || typeof msg !== 'object' || (sender && sender.tab)) return false;
  if (msg.type === 'khayt' && msg.message && typeof msg.message === 'object') {
    sendToKhayt(msg.message).then(reply);
    return true;
  }
  return false;
});
