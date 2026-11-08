'use strict';
/**
 * A saved secret goes only where it was saved to go.
 *
 * The renderer never holds a saved secret: it holds the mask, and the main
 * process fills the real value in from the encrypted store just before a
 * request leaves. The destination, though, used to come from the renderer too —
 * so anything that could run script in the window (an XSS in a customer name, a
 * poisoned import) could send the mask plus ITS OWN address and have the main
 * process deliver the shop's real secret there: the cloud token as a Bearer
 * header, the accounting secret, the SMTP password in a login, the event
 * webhook's HMAC over any body it liked.
 *
 * So a secret filled in from the store is now bound to the destination stored
 * beside it. `resolveStoreSecretFor` (lib/store-io.js) fills it in only when the
 * request goes to the same place; otherwise it refuses. A secret the renderer
 * sends in plaintext is not bound — the caller already knows it, which is the
 * case of a shop typing a new key and pressing Test before saving.
 *
 * The keys below are what "the same place" means for each kind of destination.
 * An unparseable or empty destination has no key, and no key matches nothing.
 */

/** A whole URL: scheme, host, port and path. A trailing slash is not a different place. */
function urlKey(value) {
  const s = String(value == null ? '' : value).trim();
  if (!s) return '';
  try {
    const u = new URL(s);
    const path = u.pathname.replace(/\/+$/, '');
    return `${u.protocol}//${u.host.toLowerCase()}${path}${u.search}`;
  } catch (_) { return ''; }
}

/** Just the server: scheme, host and port. A Bearer token is for a server, not a path on it. */
function originKey(value) {
  const s = String(value == null ? '' : value).trim();
  if (!s) return '';
  try {
    const u = new URL(s);
    return `${u.protocol}//${u.host.toLowerCase()}`;
  } catch (_) { return ''; }
}

/** A mail server: host and port (587 when none is set, as hub:send-email sends). */
function smtpKey(host, port) {
  const h = String(host == null ? '' : host).trim().toLowerCase().replace(/\.$/, '');
  if (!h) return '';
  const p = Number(port) || 587;
  return `${h}:${p}`;
}

/** Do two keys name the same place? Two empty keys do not. */
function sameDestination(a, b) {
  return !!a && !!b && a === b;
}

/**
 * Every saved secret whose destination the shop sets, with where that
 * destination lives. Binding at send time is only half of it: the window can
 * also SAVE a new destination, and the save puts the masked secret back from
 * disk. So a save that moves one of these destinations while its secret comes
 * back masked (or empty) drops the secret instead — moving where a secret goes
 * means entering it again. lib/store-io.js mergeStoreSecretsFromDisk.
 */
const BOUND_SECRETS = Object.freeze([
  { section: 'cloud', key: (s) => originKey(s && s.url), secrets: ['token'] },
  { section: 'accountingSync', key: (s) => urlKey(s && s.webhookUrl), secrets: ['secret'] },
  { section: 'eventWebhooks', key: (s) => urlKey(s && s.url), secrets: ['secret'] },
  { section: 'emailConfig', key: (s) => smtpKey(s && s.smtpHost, s && s.smtpPort), secrets: ['smtpPassword'] },
  { section: 'smsConfig', key: (s) => urlKey(s && s.url), secrets: ['authToken', 'token', 'appSid', 'secret'] },
]);

/**
 * Where a plugin's secrets may go: the hosts the shop consented to
 * (`settings.plugins[].granted.domains`, the manifest's `domains[]` as
 * approved). The key is that list, normalised and sorted, so an update that
 * adds a domain is a MOVE — the save drops the masked secrets and the shop
 * enters them again with the new consent (lib/store-io.js).
 */
function pluginKey(plugin) {
  const g = plugin && plugin.granted;
  const list = (g && Array.isArray(g.domains) ? g.domains : [])
    .map((d) => String(d || '').trim().toLowerCase().replace(/\.$/, '')).filter(Boolean);
  return Array.from(new Set(list)).sort().join(',');
}

/**
 * May a plugin's secret be sent to `url`? Only over https, with no user or
 * password in the URL, and only to a host the shop granted — EXACTLY that
 * host. Not a subdomain of it: the consent screen and the privacy wording
 * promise "these fields go to this host", and the manifest's URLs are held to
 * the same rule (lib/plugin-manifest.js, lib/plugin-payload.js urlFor).
 * No grant, no destination.
 */
function pluginDestinationAllowed(plugin, url) {
  let host;
  try {
    const u = new URL(String(url == null ? '' : url).trim());
    if (u.protocol !== 'https:' || u.username || u.password) return false;
    host = u.hostname.toLowerCase().replace(/\.$/, '');
  } catch (_) { return false; }
  return pluginKey(plugin).split(',').filter(Boolean).includes(host);
}

const SecretDestination = { urlKey, originKey, smtpKey, sameDestination, BOUND_SECRETS, pluginKey, pluginDestinationAllowed };

if (typeof module !== 'undefined' && module.exports) module.exports = SecretDestination;
