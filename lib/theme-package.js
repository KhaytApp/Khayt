'use strict';

(function (global) {
/**
 * The gate an installed theme has to get through.
 *
 * WHY A THEME IS NOT LIKE A SETTING
 *
 * Khayt already knows how to register a custom theme: `registry-core.js`
 * validates a manifest, blocks path traversal in its stylesheet names, bounds
 * its accents and allowlists its shell. That work is good and this does not
 * repeat it.
 *
 * What nothing checks is the CSS, and the CSS is the whole of a theme. It is
 * injected into a running Electron app that shows prices, customer addresses and
 * a button that starts a printer. A stylesheet is not decoration in that
 * context — it is code with opinions about what the operator sees.
 *
 * Concretely, an unchecked theme can:
 *
 *   - phone home. `background: url(https://x/p.png)` fires on render, and CSS
 *     attribute selectors can make that request depend on the page's contents,
 *     which turns a stylesheet into a slow exfiltration channel.
 *   - pull in more CSS later with `@import`, so what was reviewed at install
 *     time is not what runs tomorrow.
 *   - rewrite what a number says. `content:` on a ::after can put a different
 *     figure beside a real one.
 *   - hide or cover a control, which is how a "Cancel" ends up over a "Delete".
 *   - break out of its own <style> element with a literal `</style>`, at which
 *     point it is not CSS at all any more.
 *
 * WHERE THIS RUNS, AND WHY IT IS SEPARATE
 *
 * At INSTALL time, in the main process, on a file that just arrived from
 * somewhere. `registry-core.js` keeps validating at registration, because a
 * theme already on disk should not be trusted merely for having been trusted
 * once — but the first look happens here, before anything is written.
 *
 * NOT A CSS PARSER
 *
 * Deliberately. A parser that understands CSS well enough to rewrite it safely
 * is a large thing to own and a good place to hide a bypass. This refuses on
 * sight instead: a theme carrying any of the constructs below is rejected whole,
 * with the reason, rather than quietly cleaned up and installed. A theme author
 * gets an error they can fix; nobody gets a stylesheet that was edited into
 * something they did not write.
 */

/** Nothing legitimate in a colour theme needs any of these. */
const FORBIDDEN = [
  {
    id: 'import',
    // Fetches more CSS at render time, so review at install time proves nothing.
    re: /@import\b/i,
    why: '@import — a theme must be self-contained, or what was reviewed is not what runs',
  },
  {
    id: 'remote-url',
    // Any url() that is not an inline data: image. Covers background, cursor,
    // mask, @font-face src and the rest in one rule, because they all reach the
    // network the same way.
    re: /url\(\s*(?!['"]?data:image\/(?:png|jpe?g|gif|webp|svg\+xml);base64,)/i,
    why: 'url() pointing outside the file — every one of these is a network request made on render',
  },
  {
    id: 'style-break',
    // The string that ends the element this gets injected into.
    re: /<\s*\/\s*style/i,
    why: '</style> — this would end the stylesheet and start being HTML',
  },
  {
    id: 'script-ish',
    re: /<\s*script|javascript\s*:|expression\s*\(|-moz-binding|behavior\s*:/i,
    why: 'script, javascript:, expression(), -moz-binding or behavior — none of these are styling',
  },
  {
    id: 'content-text',
    // `content` with a quoted string writes visible text. Counters, attr() and
    // the empty string are fine; a literal is how a theme rewrites a number.
    re: /content\s*:\s*(?![^;{}]*\b(?:none|normal|counter|attr|open-quote|close-quote)\b)[^;{}]*["'][^"']+["']/i,
    why: 'content: with literal text — a theme may not put words or figures on the screen',
  },
];

/**
 * Rules that must not be aimed at the whole document.
 *
 * A theme legitimately styles Khayt's own classes. It has no business setting
 * `position: fixed` on `*`, or hiding `body`. These are the shapes that produce
 * an overlay nobody asked for, and they are cheap to spot without parsing.
 */
const SUSPICIOUS_GLOBAL = [
  { id: 'hide-all', re: /(^|[},])\s*(?:\*|html|body)\s*\{[^}]*display\s*:\s*none/i,
    why: 'display:none on the whole document' },
  { id: 'overlay-all', re: /(^|[},])\s*\*\s*\{[^}]*position\s*:\s*fixed/i,
    why: 'position:fixed on every element' },
];

/** A theme's stylesheet is tokens and rules, not a payload. */
const MAX_CSS_BYTES = 512 * 1024;
const MAX_MANIFEST_BYTES = 64 * 1024;

/**
 * Inspect one stylesheet.
 *
 * @param {string} css
 * @param {string} [label] which file this is, for the message
 * @returns {{ok: boolean, problems: Array<{id: string, why: string}>}}
 */
function inspectCss(css, label = 'tokens.css') {
  const problems = [];
  if (typeof css !== 'string') {
    return { ok: false, problems: [{ id: 'not-text', why: `${label} is not text` }] };
  }
  const bytes = Buffer.byteLength(css, 'utf8');
  if (bytes > MAX_CSS_BYTES) {
    problems.push({ id: 'too-big', why: `${label} is ${Math.round(bytes / 1024)} KB; the limit is ${MAX_CSS_BYTES / 1024} KB` });
  }
  if (css.includes('\u0000')) {
    problems.push({ id: 'nul', why: `${label} contains a NUL byte` });
  }

  // Comments are stripped BEFORE matching. A construct hidden in a comment is
  // harmless, and leaving them in makes /* url( */ a false positive — but this
  // runs on the copy used for matching only. The stored file is never rewritten.
  const bare = css.replace(/\/\*[\s\S]*?\*\//g, ' ');

  for (const rule of FORBIDDEN) {
    if (rule.re.test(bare)) problems.push({ id: rule.id, why: `${label}: ${rule.why}` });
  }
  for (const rule of SUSPICIOUS_GLOBAL) {
    if (rule.re.test(bare)) problems.push({ id: rule.id, why: `${label}: ${rule.why}` });
  }
  return { ok: problems.length === 0, problems };
}

/**
 * Inspect a whole package: the manifest plus every stylesheet it names.
 *
 * @param {object} pkg
 *   manifest  the parsed manifest.json
 *   files     {filename: cssText} for every stylesheet the manifest names
 *   rawManifestBytes  optional, so an enormous manifest is caught before parsing
 * @returns {{ok: boolean, problems: Array, id: string|null, files: string[]}}
 */
function inspectPackage(pkg) {
  const p = pkg || {};
  const manifest = p.manifest;
  const files = p.files || {};
  const problems = [];

  if (Number.isFinite(p.rawManifestBytes) && p.rawManifestBytes > MAX_MANIFEST_BYTES) {
    problems.push({ id: 'manifest-too-big', why: `manifest.json is over ${MAX_MANIFEST_BYTES / 1024} KB` });
  }
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    return { ok: false, problems: [...problems, { id: 'no-manifest', why: 'manifest.json is missing or is not an object' }], id: null, files: [] };
  }

  // Names of the stylesheets this manifest claims. registry-core already refuses
  // path separators here; repeated because this runs FIRST, on a file that has
  // not been trusted by anything yet.
  const SAFE_CSS = /^[a-zA-Z0-9._-]+\.css$/;
  const named = [];
  for (const field of ['tokens', 'compat', 'shellCss']) {
    const v = manifest[field];
    if (v === undefined || v === null || v === '') continue;
    if (typeof v !== 'string' || !SAFE_CSS.test(v)) {
      problems.push({ id: 'bad-css-name', why: `${field} must be a plain .css filename` });
      continue;
    }
    named.push(v);
  }
  if (!named.length) problems.push({ id: 'no-tokens', why: 'the manifest names no stylesheet' });

  for (const name of named) {
    if (!Object.prototype.hasOwnProperty.call(files, name)) {
      problems.push({ id: 'missing-file', why: `${name} is named in the manifest but not in the package` });
      continue;
    }
    problems.push(...inspectCss(files[name], name).problems);
  }

  // Anything shipped that the manifest does not name is not installed. A theme
  // is its manifest plus the files it declares; a package that also carries a
  // spare .js is carrying it for some other reason.
  const extra = Object.keys(files).filter((f) => !named.includes(f));
  for (const f of extra) {
    problems.push({ id: 'unexpected-file', why: `${f} is in the package but not named in the manifest` });
  }

  return {
    ok: problems.length === 0,
    problems,
    id: typeof manifest.id === 'string' ? manifest.id : null,
    files: named,
  };
}

/** One sentence per problem, for a dialog rather than a log. */
function explain(result) {
  if (!result || result.ok) return '';
  return (result.problems || []).map((p) => `• ${p.why}`).join('\n');
}

const api = { inspectCss, inspectPackage, explain, FORBIDDEN, SUSPICIOUS_GLOBAL, MAX_CSS_BYTES, MAX_MANIFEST_BYTES };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytThemePackage = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
