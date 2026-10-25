// The one way out of the extension: the browser's native messaging, to Khayt.
//
// Never a localhost address and never a khayt:// link. Native messaging is
// reachable only by the extension itself — a web page cannot send on it — and
// on the other end is code that ships inside Khayt.app: the Safari extension's
// handler, or the small host program Khayt installs for Chrome, Edge, Brave
// and Firefox from its own Settings. What the page said goes to this Mac and
// nowhere else.
//
// The popup does not send itself: it asks the background (`background.js`),
// which outlives the popup, so a save in flight is not cut off when the popup
// closes.

/** `browser` where it exists (Safari, Firefox), else `chrome`. */
export function extensionApi() {
  return globalThis.browser || globalThis.chrome;
}

/** Khayt's answer to one message, or `{state: 'no-host'}` when it cannot be reached. `tabId` is the tab a save was read from, so the background can tell its download (`background.js` `matchDownload`). */
export async function askKhayt(api, message, tabId) {
  try {
    const reply = await api.runtime.sendMessage({ type: 'khayt', message, tabId: typeof tabId === 'number' ? tabId : undefined });
    if (reply && typeof reply === 'object' && typeof reply.state === 'string') return reply;
  } catch { /* the background is gone; say so the same way */ }
  return { ok: false, state: 'no-host' };
}

/** The message a save is: the page as read, and the format's version. */
export function saveMessage(page, tabUrl) {
  // The tab's own address beside the page's claim, so the app can make the
  // same same-site check (`WebSave.page`) without trusting this end.
  return { v: 1, kind: 'save', page: tabUrl ? { ...page, tabUrl: String(tabUrl) } : page };
}
