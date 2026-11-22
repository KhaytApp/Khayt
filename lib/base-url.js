'use strict';
/**
 * Is this address safe to send a secret to?
 *
 * Khayt has three settings that are a URL the shop types in, and every one of
 * them has a credential travelling to it: the cloud server (an email and a
 * password), an OpenAI-compatible AI endpoint (an API key in a header), and
 * self-hosted variants of both. Typed `http://` instead of `https://`, all of
 * those cross the network in clear text.
 *
 * `lib/cloud-client.js` worked this out once and guarded its own field. The AI
 * base URL, added later, did not — it concatenated whatever was typed straight
 * into a fetch with the key in an `authorization` header. So the rule is here
 * now, and both callers ask it, because a rule written down twice is a rule
 * that can disagree with itself.
 *
 * ── WHY PLAIN HTTP IS NOT SIMPLY REFUSED ───────────────────────────────────
 *
 * It is a legitimate address in exactly two places, and both are the point of
 * the features that take it:
 *
 *   loopback   a model running on this machine through Ollama or vLLM — the
 *              only option for a shop whose book must not leave the building,
 *              and nothing crosses a wire at all
 *   RFC1918    a server or gateway on the shop's own LAN
 *
 * Over the public internet there is no such case, so https is required there.
 * Refusing http outright would break the local-model option the compatible
 * provider exists for; allowing it everywhere puts a key on the wire.
 *
 * Link-local (169.254/16) is refused outright: it is the cloud metadata
 * endpoint, never a server a shop set up.
 *
 * Pure: a string in, a normalised origin+path out, or a throw with a reason
 * worth putting on screen.
 */
(function (global) {

  /**
   * @param {string} raw            what the shop typed
   * @param {object} [opts]
   * @param {string} [opts.what]    'a server address' — named in the messages
   * @param {string} [opts.secret]  'password' — what plain http would expose
   * @returns {string} origin + path, trailing slashes trimmed
   */
  function validateBaseUrl(raw, opts) {
    const o = opts || {};
    const what = o.what || 'address';
    const secret = o.secret || 'credentials';

    let u;
    try { u = new URL(String(raw == null ? '' : raw)); }
    catch { throw new Error(`Not a valid ${what}`); }

    if (u.protocol !== 'https:' && u.protocol !== 'http:') {
      throw new Error(`${what[0].toUpperCase()}${what.slice(1)} must start with https://`);
    }
    // Credentials in the URL would be sent to, and logged by, the far end.
    if (u.username || u.password) {
      throw new Error(`${what[0].toUpperCase()}${what.slice(1)} must not contain a username or password`);
    }

    const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
    const isLoopback = h === 'localhost' || h === '::1' || /^127\./.test(h);
    const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
    const [a, b] = v4 ? [Number(v4[1]), Number(v4[2])] : [];
    const isPrivate = !!v4 && (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168));
    // Link-local covers the cloud metadata endpoint.
    if (v4 && a === 169 && b === 254) throw new Error(`That ${what} is not allowed`);

    if (u.protocol === 'http:' && !isLoopback && !isPrivate) {
      throw new Error(`Use https:// — a plain http address would send your ${secret} unencrypted`);
    }
    return (u.origin + u.pathname).replace(/\/+$/, '');
  }

  /** True when the address is one a secret may travel to. Never throws. */
  function baseUrlIsSafe(raw, opts) {
    try { validateBaseUrl(raw, opts); return true; } catch (e) { return false; }
  }

  const api = { validateBaseUrl, baseUrlIsSafe };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytBaseUrl = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
