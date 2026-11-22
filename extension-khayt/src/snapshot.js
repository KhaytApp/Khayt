// What the popup asks the active tab for, and the one thing that runs in it.
//
// `pageSnapshot` is handed to `scripting.executeScript({ func })`, which
// serialises it and runs it in the tab the shop pressed the button on — only
// that tab, only then (`activeTab`): there is no content script and no host
// permission. It reads and returns; it changes nothing on the page and sends
// nothing anywhere. The popup parses what it returns in an inert document
// (`DOMParser`), so nothing of the page's runs in the extension.
//
// SELF-CONTAINED, because it is serialised: nothing outside its own body is
// in scope when it runs.

export const MAX_HTML = 3_000_000;

export function pageSnapshot(maxHtml) {
  const html = document.documentElement ? document.documentElement.outerHTML : '';
  return {
    url: String(location.href),
    title: String(document.title || ''),
    html: html.length > maxHtml ? html.slice(0, maxHtml) : html,
  };
}
