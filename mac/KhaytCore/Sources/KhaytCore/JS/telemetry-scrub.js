'use strict';
/**
 * Telemetry scrubbing pipeline — implements §4 of docs/KHAYT-3.0-TELEMETRY-SPEC.md.
 *
 * HARD INVARIANT: no shop data, no PII, no secrets, no raw paths ever leave the device.
 * That is enforced two ways, and the second is the one that matters:
 *   1. Values are scrubbed (paths → <userData>, secrets → mask, PII → <redacted>).
 *   2. The final object is rebuilt FIELD BY FIELD from an allowlist — anything the caller
 *      passes that isn't on the list simply never gets copied. So an upstream mistake
 *      cannot leak a new field; it can only fail to include one.
 *
 * Fails closed: if scrubbing throws, the caller drops the event rather than sending raw.
 */
(function () {
  const SECRET_MASK = '__KHAYT_MASKED__';
  const REDACTED = '<redacted>';
  const MESSAGE_CAP = 300;

  // Key shapes that hold credentials anywhere in the app (mirrors store.js redaction).
  const SECRET_KEY_RE = /(api[-_]?key|secret|password|passwd|token|pin|csid|pcsid|authorization|bearer|access[-_]?code|webhook[-_]?secret|private[-_]?key)/i;

  // Value shapes that are personal data regardless of the key they sit under.
  const PII_PATTERNS = [
    /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi,          // email
    /\+?\d[\d\s().-]{7,}\d/g,                            // phone (incl. +9665…)
    /\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b/g,                 // IBAN
    /\b\d{9,}\b/g,                                       // long digit runs (card / CR / VAT)
  ];

  /**
   * Credential shapes that appear in the BODY of free text, not as an object key.
   * An error message is a string — the key-based masking in scrubValue() never sees it,
   * so a thrown error that quotes a request URL, an auth header, or an openssl argument
   * would otherwise carry the live credential verbatim.
   */
  const SECRET_VALUE_PATTERNS = [
    // Khayt's own tokens and common vendor prefixes (khayt_, whsec_, sk_live_, ghp_ …).
    /\b(?:khayt|whsec|sk|pk|rk|ghp|gho|xox[abps])[_-][A-Za-z0-9_\-]{8,}/g,
    // Authorization headers: "Bearer <x>", "Basic <x>", "Token <x>".
    /\b(?:bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,}/gi,
    // key=value / key: value where the key names a credential. Covers ?apikey=…,
    // X-Api-Key: …, secret=…, -passin pass:… — quoted or bare, up to the next delimiter.
    // Extra key spellings that only ever show up in free text, never as an object key:
    // openssl's `-passin pass:…`, curl's `-u`, generic `pwd=` / `auth=` / `credential=`.
    //
    // `\x29` and `\x7d` are `)` and `}` in the delimiter class, spelled so the
    // brackets in this string do not unbalance the bracket count that
    // test/bundled-modules-are-wrapped.test.js uses to prove this module keeps
    // its names out of the Mac's one shared JavaScriptCore scope. Same pattern.
    new RegExp(
      '(' + SECRET_KEY_RE.source + '|pass(?:in|out|phrase)?|pwd|credentials?|auth)' +
      '["\']?\\s*[:=]\\s*["\']?([^\\s"\'&,;\\x29\\x7d\\]]{4,})',
      'gi',
    ),
  ];

  /** Replace credential-shaped substrings in free text with the mask. */
  function scrubSecrets(str) {
    if (typeof str !== 'string') return str;
    let out = str;
    // Prefix/header forms are whole-match replacements.
    out = out.replace(SECRET_VALUE_PATTERNS[0], SECRET_MASK);
    out = out.replace(SECRET_VALUE_PATTERNS[1], (m) => m.split(/\s+/)[0] + ' ' + SECRET_MASK);
    // The key=value form keeps the KEY (it is useful for debugging) and masks the value.
    out = out.replace(SECRET_VALUE_PATTERNS[2], (m, key) => key + '=' + SECRET_MASK);
    return out;
  }

  // Basenames worth keeping: a stack frame is useless without its module name. Anything
  // else — a customer's invoice, an exported PDF, a photo — is dropped to its extension,
  // because a filename routinely carries a person's name.
  const CODE_FILE_RE = /\.(?:js|mjs|cjs|ts|json|html|css|node|swift)$/i;

  function safeBasename(name) {
    const base = String(name || '').trim();
    if (CODE_FILE_RE.test(base)) return base;
    // Only a real extension is kept: a dot inside a folder or a person's
    // name ("Nouf.v2 Aldossari") is no extension, and the whole name goes.
    const ext = /\.[A-Za-z0-9]{1,10}$/.exec(base);
    return ext ? '<file>' + ext[0] : '<file>';
  }

  /**
   * A path token. It starts at `/`, `~/`, `./` or `../` (a `file://` URL
   * included) or at a drive letter `X:\`, and runs THROUGH SPACES, because
   * shops' folders have them: "My Drive/Nouf Aldossari/lamp.3mf" stopped at
   * the first space used to leak "Drive" and "Aldossari". It ends at a
   * `:<line>` (or a colon before a space or the end), a closing bracket of
   * any kind, `>`, a quote or a newline; `pathEnd` then finds where a
   * sentence carries on after it.
   *
   * A POSIX path starts after anything that cannot be inside a word or a
   * relative path (`readStore@/Users/…`, `x|/…`, `foo</…>` all count), so
   * "and/or", "Trace/BPT" and "KhaytApp/Shop.swift" stay text and are not
   * read as a path that swallows the rest of the line.
   *
   * `\x28`, `\x29` and `\x7d` are `(`, `)` and `}` inside the character
   * classes, spelled so this file's bracket count stays balanced for
   * test/bundled-modules-are-wrapped.test.js.
   */
  // An apostrophe or backtick followed by a letter or digit is part of a
  // folder name ("Sa'ad Alghamdi", "O'Brien"), not the quote that closes the
  // path, which is followed by a space, punctuation or the end.
  const PATH_BODY = '(?:[^\\n:\\x29\\]\\x7d>\'"`\\u2018\\u2019\\u201C\\u201D]|[\'`\\u2019](?=[A-Za-z0-9])|:(?![\\d\\s]|$))*';
  // The first alternative is this scrubber's own `<path>/`, passed over:
  // its `>` would otherwise lead a path and the marker be collapsed again.
  const POSIX_PATH_RE = new RegExp(
    '(<path>\\/)|(^|[^A-Za-z0-9_./\\\\-])((?:file:\\/\\/)?(?:~|\\.{1,2})?\\/(?![\\s\\x29])' + PATH_BODY + ')', 'g');
  // No word boundary before the drive letter: "openC:\Users\…" is still a path.
  const WINDOWS_PATH_RE = new RegExp('[A-Za-z]:\\\\' + PATH_BODY, 'g');
  // A RELATIVE run with two slashes or more, right after a word or a symbol
  // the POSIX lead does not take: "Users/nouf/Desktop/order.3mf",
  // "abc/Users/…", "x-/Users/…", "$HOME/../nouf/b.3mf". One slash
  // ("and/or", "KhaytApp/Shop.swift") stays text. Past its second slash it
  // runs on like any other path.
  const RELATIVE_PATH_RE = new RegExp(
    '(<path>\\/)|(^|[^A-Za-z0-9_.$~\\/\\\\-])([A-Za-z0-9_.$~-]+\\/[^\\s\\/:\\x29\\]\\x7d>\'"`]+\\/(?![\\s\\x29])' +
    PATH_BODY + ')', 'g');

  /**
   * Where the path in a token ends and the sentence resumes: at ", ", or at
   * a space once the segment before it has a file extension and the word
   * after it is not more path ("…/lamp.3mf because disk full",
   * "…/Shop.swift, line 120"). A space inside folder names
   * ("My Drive/Nouf Aldossari/lamp.3mf") is still part of the path.
   */
  function pathEnd(token) {
    for (let i = 0; i < token.length; i++) {
      if (token.startsWith(', ', i)) return i;
      if (token[i] !== ' ') continue;
      const segment = token.slice(Math.max(token.lastIndexOf('/', i), token.lastIndexOf('\\', i)) + 1, i);
      const next = token.slice(i + 1).split(' ')[0];
      if (/\.[A-Za-z0-9]{1,10}$/.test(segment) && !/[\\/]/.test(next)) return i;
    }
    return token.length;
  }

  /** The last segment of a path token, the only part kept. */
  function lastSegment(token) {
    return token.split(/[\\/]/).map((s) => s.trim()).filter(Boolean).pop();
  }

  /** A path token reduced to its basename, and the sentence after it scrubbed in turn. */
  function collapse(token) {
    const at = pathEnd(token);
    return '<path>/' + safeBasename(lastSegment(token.slice(0, at))) + scrubPath(token.slice(at));
  }

  /** Collapse any filesystem path to a basename, so home dirs and usernames never leak. */
  function scrubPath(str) {
    if (typeof str !== 'string') return str;
    return str
      .replace(WINDOWS_PATH_RE, (m) => collapse(m))
      .replace(POSIX_PATH_RE, (m, done, lead, token) => (done ? m : lead + collapse(token)))
      .replace(RELATIVE_PATH_RE, (m, done, lead, token) => (done ? m : lead + collapse(token)));
  }

  /** Strip PII value shapes out of any free text. */
  function scrubPii(str) {
    if (typeof str !== 'string') return str;
    let out = str;
    for (const re of PII_PATTERNS) out = out.replace(re, REDACTED);
    // QUOTED VALUES. An error quoting what it was handed — "No client 'Noura
    // Al-Qahtani'", "Unknown material "Galaxy Black"" — carries shop data no
    // pattern above has a shape for. A quoted CODE NAME is what makes a crash
    // readable ("reading 'name'"), so a lower-case identifier or dotted path
    // is kept — a capitalised word is far more often a person ('Noura'), and
    // a file name carries one too ('Noura_order.3mf') — and anything else
    // between quotes is redacted. Up to 120 characters, so an unpaired quote
    // cannot swallow the message.
    out = out.replace(/(['"`\u2018\u201C])([^'"`\u2018\u2019\u201C\u201D\n]{1,120})(['"`\u2019\u201D])/g,
      (m, open, body, close) => (/^[a-z_$][\w$]*(?:\.[a-z_$][\w$]*)*$/.test(body) ? m : open + REDACTED + close));
    return out;
  }

  /**
   * Full text scrub, in a deliberate order:
   *   secrets → paths → PII → cap.
   * Secrets MUST go first: scrubPath() collapses a URL to its basename, which would
   * mangle "?apikey=…" into something the credential patterns no longer recognise while
   * leaving the credential itself perfectly intact.
   * Paths before PII so that digits inside a path aren't mistaken for a card number.
   */
  function scrubText(str, cap) {
    if (typeof str !== 'string') return '';
    let out = scrubPii(scrubPath(scrubSecrets(str)));
    const limit = cap || MESSAGE_CAP;
    if (out.length > limit) out = out.slice(0, limit) + '…';
    return out;
  }

  /**
   * The ingest refuses a stack longer than this (khayt-cloud
   * src/telemetry-ingest.js, CAPS.stack) and refuses the WHOLE event with it.
   * Thirty lines of up to 201 characters is 6,000, so a deep stack used to be
   * scrubbed, queued, sent and thrown away. Whole lines are kept: a frame cut
   * in half names nothing.
   */
  const STACK_CAP = 4000;

  /** A stack trace reduced to frame function + module basename + line. */
  function scrubStack(stack) {
    if (typeof stack !== 'string') return '';
    const out = [];
    let length = 0;
    for (const line of stack.split('\n').slice(0, 30)) {
      const clean = scrubText(line, 200);
      const added = clean.length + (out.length ? 1 : 0);
      if (length + added > STACK_CAP) break;
      out.push(clean);
      length += added;
    }
    return out.join('\n');
  }

  /** True when a key looks like it holds a credential. */
  function isSecretKey(key) { return SECRET_KEY_RE.test(String(key || '')); }

  /**
   * Deep-scrub an arbitrary object: mask secret-shaped keys, scrub strings, drop functions.
   * Used defensively — the allowlist below is the real guarantee.
   */
  function scrubValue(val, key, depth) {
    const d = depth || 0;
    if (d > 6) return null;
    if (val == null) return val;
    if (isSecretKey(key)) return SECRET_MASK;
    if (typeof val === 'string') return scrubText(val);
    if (typeof val === 'number' || typeof val === 'boolean') return val;
    if (Array.isArray(val)) return val.slice(0, 50).map(v => scrubValue(v, '', d + 1));
    if (typeof val === 'object') {
      const out = {};
      for (const k of Object.keys(val)) out[k] = scrubValue(val[k], k, d + 1);
      return out;
    }
    return null;
  }

  // ── Allowlists (§1). Anything absent here is never sent. ────────────────
  const CRASH_FIELDS = ['type', 'name', 'message', 'stack', 'process', 'appVersion', 'electronVersion', 'osFamily', 'osMajor', 'locale', 'channel', 'installId', 'at'];
  const USAGE_FIELDS = ['feature', 'count', 'mode', 'businessType', 'vatEnabled', 'zatcaEnabled', 'onlineEnabled', 'lanEnabled', 'sessions', 'appVersion', 'locale', 'channel', 'installId', 'at'];

  const USAGE_ENUMS = {
    mode: ['simple', 'professional', 'enthusiast'],
    businessType: ['solo', 'shop', 'farm', 'b2b'],
    channel: ['stable', 'beta', 'alpha'],
    locale: ['en', 'ar', 'de', 'es', 'fr', 'tr', 'ja', 'zh'],
  };

  function pickEnum(val, allowed) {
    return allowed.includes(val) ? val : null;
  }

  /**
   * Build a crash report from raw input. Returns null if there is nothing useful —
   * callers treat null as "drop it".
   */
  function buildCrashReport(raw) {
    const r = raw || {};
    const out = {
      type: pickEnum(r.type, ['uncaughtException', 'unhandledRejection', 'render-process-gone', 'child-process-gone', 'renderer-error']) || 'unknown',
      name: scrubText(String(r.name || 'Error'), 80),
      message: scrubText(String(r.message || ''), MESSAGE_CAP),
      stack: scrubStack(r.stack),
      process: pickEnum(r.process, ['main', 'renderer']) || 'main',
      appVersion: scrubText(String(r.appVersion || ''), 24),
      electronVersion: scrubText(String(r.electronVersion || ''), 24),
      osFamily: pickEnum(r.osFamily, ['macOS', 'Windows', 'Linux']) || 'unknown',
      osMajor: scrubText(String(r.osMajor || ''), 12),
      locale: pickEnum(r.locale, USAGE_ENUMS.locale) || 'en',
      channel: pickEnum(r.channel, USAGE_ENUMS.channel) || 'stable',
      installId: /^[a-f0-9-]{8,64}$/i.test(String(r.installId || '')) ? String(r.installId) : '',
      at: /^\d{4}-\d{2}-\d{2}$/.test(String(r.at || '')) ? String(r.at) : new Date().toISOString().slice(0, 10),
    };
    // Rebuild strictly from the allowlist — nothing else can survive.
    const gated = {};
    for (const k of CRASH_FIELDS) gated[k] = out[k];
    return gated;
  }

  /** Build a usage counter event. Counts and enums only — never any string content. */
  function buildUsageEvent(raw) {
    const r = raw || {};
    const feature = String(r.feature || '').slice(0, 40);
    // Feature names are enum-like identifiers; reject anything with content-ish characters.
    const safeFeature = /^[a-z0-9_]+$/.test(feature) ? feature : null;
    if (!safeFeature) return null;
    const out = {
      feature: safeFeature,
      count: Number.isFinite(+r.count) ? Math.max(1, Math.min(1e6, Math.round(+r.count))) : 1,
      mode: pickEnum(r.mode, USAGE_ENUMS.mode),
      businessType: pickEnum(r.businessType, USAGE_ENUMS.businessType),
      vatEnabled: !!r.vatEnabled,
      zatcaEnabled: !!r.zatcaEnabled,
      onlineEnabled: !!r.onlineEnabled,
      lanEnabled: !!r.lanEnabled,
      sessions: Number.isFinite(+r.sessions) ? Math.max(0, Math.round(+r.sessions)) : 0,
      appVersion: scrubText(String(r.appVersion || ''), 24),
      locale: pickEnum(r.locale, USAGE_ENUMS.locale) || 'en',
      channel: pickEnum(r.channel, USAGE_ENUMS.channel) || 'stable',
      installId: /^[a-f0-9-]{8,64}$/i.test(String(r.installId || '')) ? String(r.installId) : '',
      at: /^\d{4}-\d{2}-\d{2}$/.test(String(r.at || '')) ? String(r.at) : new Date().toISOString().slice(0, 10),
    };
    const gated = {};
    for (const k of USAGE_FIELDS) gated[k] = out[k];
    return gated;
  }

  /** Bound the offline queue: newest kept, oldest dropped. */
  function boundQueue(queue, maxEvents) {
    const cap = maxEvents || 200;
    const q = Array.isArray(queue) ? queue : [];
    return q.length > cap ? q.slice(q.length - cap) : q.slice();
  }

  /** Dedupe identical scrubbed crash stacks so a crash storm can't flood the queue. */
  function dedupeCrashes(queue) {
    const seen = new Set();
    const out = [];
    for (const e of (Array.isArray(queue) ? queue : [])) {
      if (!e || e.kind !== 'crash') { out.push(e); continue; }
      const key = (e.payload && e.payload.name) + '|' + (e.payload && e.payload.stack);
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(e);
    }
    return out;
  }

  const api = {
    SECRET_MASK, REDACTED, MESSAGE_CAP, CRASH_FIELDS, USAGE_FIELDS,
    scrubPath, scrubPii, scrubSecrets, scrubText, scrubStack, scrubValue, isSecretKey,
    buildCrashReport, buildUsageEvent, boundQueue, dedupeCrashes,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytTelemetryScrub = api;
})();
