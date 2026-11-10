'use strict';
/**
 * A connector is data, never code.
 *
 * A Khayt plugin (v1, "connectors") is a manifest the app INTERPRETS: which
 * fields it adds to a job or a customer, which buttons it puts beside them,
 * which book fields each button sends, and which hosts may receive them. It
 * runs nothing. That is what lets the same manifest work on the Mac, on
 * Windows/Linux and on the iPhone (App Store 2.5.2: no downloaded code), and
 * what lets a consent screen say, truthfully and completely, "these fields go
 * to this host" — everything a connector can send is written down here before
 * it is installed.
 *
 * So this module is the whole contract:
 *   - validateManifest   the only way a manifest gets in; unknown keys are refused
 *   - SENDABLE_FIELDS    every book field a connector may ever send, with the
 *                        Apple privacy category each one falls under. A
 *                        developer picks keys from it and cannot declare a
 *                        category, so the review, the consent screen and the
 *                        App Privacy label all read ONE table
 *   - permissionsOf      what a manifest asks for, flattened
 *   - diffPermissions    what an update asks for that was not granted — a
 *                        non-empty answer pauses the plugin until the shop agrees
 *   - consentRows        "these fields → this host", for the consent screen
 *   - canonicalJSON      the bytes an ed25519 signature is over
 *   - manifestJsonSchema the same rules as JSON Schema, for the developer docs
 *
 * Pure: no network, no crypto, no clock. Verifying a signature is the
 * platform's job (CryptoKit / node:crypto) over `canonicalJSON`.
 */
(function () {
  const MANIFEST_VERSION = 1;

  // ── WHO MAY SAY "REVIEWED" ─────────────────────────────────────────────
  //
  // ed25519 public keys (base64 of the raw 32 bytes). A manifest is reviewed
  // when its `signature` verifies, over the UTF-8 of `canonicalJSON`, against
  // ANY of these — a list, so the key can rotate without stranding what was
  // signed before. The private half lives in the owner's login Keychain
  // ("Khayt connector signing key") and is used only by
  // scripts/sign-connector.js. Verifying is the platform's job (CryptoKit,
  // node:crypto); this module stays free of crypto.
  const SIGNING_KEYS = [
    { id: 'khayt-2026-11', key: 'LGzEHSMW6OGkgSXgYvP9egtqAVSUn+xIyoSxiPDO8sE=' },
  ];

  // ── WHAT A CONNECTOR MAY SEND ──────────────────────────────────────────
  //
  // `from` is the record the value is read from, `path` the field on it (the
  // names lib/order-new.js and the customer sheet really write), `category`
  // the App Privacy category it is declared under. `customer.name` falls back
  // to the order's own `client` text when the job has no customer record.
  const SENDABLE_FIELDS = {
    'order.id':             { from: 'order', path: 'id',             type: 'text',   category: 'purchase.history' },
    'order.number':         { from: 'order', path: 'invoiceNumber',  type: 'text',   category: 'purchase.history' },
    'order.title':          { from: 'order', path: 'project',        type: 'text',   category: 'content.other' },
    'order.status':         { from: 'order', path: 'status',         type: 'text',   category: 'purchase.history' },
    'order.total':          { from: 'order', path: 'price',          type: 'number', category: 'purchase.history' },
    'order.currency':       { from: 'order', path: 'currency',       type: 'text',   category: 'purchase.history' },
    'order.qty':            { from: 'order', path: 'qty',            type: 'number', category: 'purchase.history' },
    'order.material':       { from: 'order', path: 'material',       type: 'text',   category: 'purchase.history' },
    'order.dueDate':        { from: 'order', path: 'dueDate',        type: 'date',   category: 'purchase.history' },
    'order.date':           { from: 'order', path: 'date',           type: 'date',   category: 'purchase.history' },
    'order.carrier':        { from: 'order', path: 'carrier',        type: 'text',   category: 'purchase.history' },
    'order.trackingNumber': { from: 'order', path: 'trackingNumber', type: 'text',   category: 'purchase.history' },
    // WORKED OUT, not stored: what the customer still owes on this job, in
    // the job's own currency — lib/order-money.js orderOwedRaw, so mode-aware
    // (an exclusive shop's bill is price + tax) and net of payments, gift
    // cards and credit notes. `Minor` is the same figure in the currency's
    // minor units (halalas, cents, fils), the integer a payment API takes.
    'order.amountDue':      { from: 'order', path: null, computed: true, type: 'number', category: 'purchase.history' },
    'order.amountDueMinor': { from: 'order', path: null, computed: true, type: 'number', category: 'purchase.history' },
    // The currency both are in: the job's own, else its customer's, else the
    // shop's. `order.currency` is the job's own only, and a job in the shop's
    // currency has none — a payment link needs one.
    'order.amountDueCurrency': { from: 'order', path: null, computed: true, type: 'text', category: 'purchase.history' },
    'customer.name':        { from: 'customer', path: 'name',        type: 'text',   category: 'contact.name' },
    'customer.company':     { from: 'customer', path: 'company',     type: 'text',   category: 'contact.other' },
    'customer.phone':       { from: 'customer', path: 'phone',       type: 'text',   category: 'contact.phone' },
    'customer.email':       { from: 'customer', path: 'email',       type: 'text',   category: 'contact.email' },
    'customer.address':     { from: 'customer', path: 'address',     type: 'text',   category: 'contact.address' },
  };
  // The clock, for a payment link's expiry: `{now.epochMs}` and
  // `{now.plusDays.<N>.epochMs}`, N from 1 to NOW_MAX_DAYS. Not book data, so
  // not something a shop grants: it is left out of permissionsOf. The time
  // is handed in by the platform (ctx.nowMs) — never read inside lib/.
  const NOW_MAX_DAYS = 90;
  const NOW_RE = /^now\.(?:plusDays\.([1-9][0-9]?)\.)?epochMs$/;
  /** Days ahead a `now.` reference asks for (0 for now itself), or -1 if it is not one. */
  function nowDays(ref) {
    const m = NOW_RE.exec(String(ref));
    if (!m) return -1;
    const n = m[1] ? Number(m[1]) : 0;
    return n <= NOW_MAX_DAYS ? n : -1;
  }
  // How a secret goes into its header. Absent: as it is. "basic": HTTP Basic
  // — base64 of "user:password"; a secret with no colon is the user name with
  // an empty password (Moyasar's secret key), so a ":" is added.
  const AUTH_ENCODINGS = ['basic'];

  // A plugin's OWN field, `field.<key>`: whatever the shop typed into it.
  const OWN_FIELD_CATEGORY = 'content.other';

  // Which record prefixes a button on each kind of record can reach. A
  // customer has no single order, so a customer button cannot send one.
  const PLACEMENT_SOURCES = {
    order: ['order', 'customer'],
    customer: ['customer'],
  };
  const FIELD_TYPES = ['text', 'number', 'bool', 'enum', 'date'];
  const FIELD_ATTACH = ['order', 'customer', 'machine', 'spool'];
  const ACTION_KINDS = ['post', 'open'];
  const SECRET_KINDS = ['apiKey', 'token', 'password', 'signingKey', 'url'];
  // v1 has ONE scope. A v1 connector runs on the developer's server and
  // cannot reach the shop: what it learns is exactly the fields it sends
  // (shown field by field on the consent sheet), and the only thing it can do
  // to the book is fill its own fields from a reply. Reading jobs or customers
  // and moving a job need a token the shop issues, which arrives with the
  // Cloud relay (v2). Until then they are REFUSED, not accepted-and-ignored,
  // so no shop is asked to consent to something nothing delivers.
  const SCOPES = ['fields.write'];
  const RESERVED_SCOPES = ['orders.read', 'customers.read', 'jobs.status'];
  // Order events only in v1: each carries one job, so `order.*` and
  // `customer.*` mean something. A subset of lib/webhook-bus.js EVENTS (a test
  // holds it there).
  const EVENTS = [
    'order_created', 'status_changed', 'order_shipped', 'order_delivered',
    'payment_received', 'quote_created', 'quote_approved',
  ];
  const BODY_FORMATS = ['khayt-v1', 'json-template'];

  // ── REFRESH: ASKING FOR NEWS ON OPEN JOBS ─────────────────────────────
  //
  // A courier knows when a parcel moved; the shop does not, until someone
  // presses a button. `refresh` (v1.1, at most one per connector) is a
  // request the computer holding the book makes on its own, every `every`
  // minutes, for each OPEN job whose `when` field (one of the connector's own
  // job fields, like the courier's order id) is filled in. It carries only
  // what the manifest declares — every {…} in its URL, `send` and template,
  // listed on the consent sheet like a button's — and its reply can fill only
  // the connector's own job fields, from the paths `response` names.
  //
  // It runs only on a computer holding the book lock (a Mac or the desktop);
  // the lock is a file beside the book on a computer's own disk, so a phone
  // never holds it, and a phone never runs refresh in any case. Never more
  // often than every 15 minutes, at most 50 jobs a run, least recently
  // checked first (lib/plugin-host.js refreshJobs).
  const REFRESH_METHODS = ['GET', 'POST'];
  const REFRESH = { minEvery: 15, maxEvery: 1440, jobsPerRun: 50 };

  // ── SETTINGS: WHAT THE SHOP TYPES IN ONCE ─────────────────────────────
  //
  // A courier needs the shop's own sender name, phone and address; a log
  // needs a sheet name. Those are typed into the connector's settings by the
  // shop, stored with it (`settings.plugins[].config`, synced like the
  // grant), and referenced as `{config.<key>}`. They are NOT secrets — those
  // stay in `secrets[]` and the device's Keychain.
  //
  // `kind` says what the value IS, from a closed list, and the lib maps it to
  // the App Privacy category — a sender phone is a phone number, whoever's it
  // is. The developer never names a category.
  const SETTING_TYPES = ['text', 'number', 'bool', 'enum'];
  const SETTING_KINDS = {
    name: 'contact.name', phone: 'contact.phone', email: 'contact.email',
    address: 'contact.address', text: 'content.other',
  };

  const LIMITS = { domains: 10, secrets: 5, fields: 20, actions: 10, events: 10, send: 30, label: 80, description: 300, url: 500, settings: 10, settingValue: 500 };
  const TOP_KEYS = ['khayt', 'id', 'name', 'publisher', 'version', 'description', 'homepage',
    'domains', 'secrets', 'settings', 'fields', 'actions', 'events', 'refresh', 'scopes', 'signature'];

  const ID_RE = /^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$/;
  const KEY_RE = /^[a-z][a-zA-Z0-9_]{0,31}$/;
  const SEMVER_RE = /^(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,5})$/;
  const HOST_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
  const PLACEHOLDER_RE = /\{([a-zA-Z0-9_.]+)\}/g;

  function isObj(v) { return !!v && typeof v === 'object' && !Array.isArray(v); }

  /**
   * A host a connector may name. No IPs, no single-label names, nothing that
   * is only ever local — a connector cannot be pointed back into the shop.
   */
  function isAllowedHost(h) {
    if (typeof h !== 'string' || !HOST_RE.test(h)) return false;
    if (/\.(local|localhost|internal|lan|home|arpa|test|invalid|example)$/.test(h)) return false;
    return true;
  }

  function placeholders(s) {
    const out = [];
    String(s).replace(PLACEHOLDER_RE, (_, k) => { out.push(k); return ''; });
    return out;
  }

  /** Every string inside a body template, in order. */
  function templateStrings(t, out) {
    if (typeof t === 'string') out.push(t);
    else if (Array.isArray(t)) t.forEach(x => templateStrings(x, out));
    else if (isObj(t)) Object.values(t).forEach(x => templateStrings(x, out));
    return out;
  }

  function templateDepth(t) {
    if (Array.isArray(t)) return 1 + Math.max(0, ...t.map(templateDepth));
    if (isObj(t)) return 1 + Math.max(0, ...Object.values(t).map(templateDepth));
    return 0;
  }

  function checkLabel(errors, where, v, max) {
    const limit = max || LIMITS.label;
    if (!isObj(v) || typeof v.en !== 'string' || !v.en.trim()) {
      errors.push(`${where}: a label is {"en": "...", other locales...} and needs "en"`);
      return;
    }
    for (const [loc, s] of Object.entries(v)) {
      if (!/^[a-z]{2}(-[A-Z]{2})?$/.test(loc)) errors.push(`${where}: "${loc}" is not a locale`);
      if (typeof s !== 'string' || s.length > limit) errors.push(`${where}.${loc}: text up to ${limit} characters`);
    }
  }

  function checkArray(errors, m, key, max) {
    if (m[key] === undefined) return [];
    if (!Array.isArray(m[key])) { errors.push(`${key}: must be a list`); return []; }
    if (m[key].length > max) errors.push(`${key}: at most ${max}`);
    return m[key];
  }

  function checkOnly(errors, where, o, keys) {
    for (const k of Object.keys(o)) if (!keys.includes(k)) errors.push(`${where}: unknown key "${k}"`);
  }

  /**
   * What `send`, a URL or a template may reference, for a button on
   * `placement` (or an event, which carries an order). `secret.<name>` is
   * allowed only where the caller says so: in a POST URL, never in a link a
   * browser opens and keeps in its history.
   */
  function checkRef(errors, where, ref, ctx) {
    if (ref.startsWith('secret.')) {
      if (!ctx.allowSecret) errors.push(`${where}: a secret cannot appear here`);
      else if (!ctx.secretNames.has(ref.slice(7))) errors.push(`${where}: no secret named "${ref.slice(7)}"`);
      return;
    }
    if (ref.startsWith('config.')) {
      if (!ctx.settingsByKey.has(ref.slice(7))) errors.push(`${where}: no setting named "${ref.slice(7)}"`);
      return;
    }
    if (ref.startsWith('now.')) {
      if (nowDays(ref) < 0) errors.push(`${where}: "${ref}" is not a time (now.epochMs, or now.plusDays.<1–${NOW_MAX_DAYS}>.epochMs)`);
      return;
    }
    if (ref.startsWith('field.')) {
      const f = ctx.fieldsByKey.get(ref.slice(6));
      if (!f) errors.push(`${where}: no field named "${ref.slice(6)}"`);
      else if (!ctx.sources.includes(f.attach)) errors.push(`${where}: field "${f.key}" is on a ${f.attach}, which this cannot reach`);
      return;
    }
    const s = SENDABLE_FIELDS[ref];
    if (!s) { errors.push(`${where}: "${ref}" is not a field a connector can send`); return; }
    if (!ctx.sources.includes(s.from)) errors.push(`${where}: "${ref}" is not reachable from a ${ctx.placement}`);
  }

  function checkUrl(errors, where, url, domains, ctx) {
    if (typeof url !== 'string' || url.length > LIMITS.url) { errors.push(`${where}: a URL up to ${LIMITS.url} characters`); return; }
    // The host has to be readable BEFORE anything is filled in, or a field
    // value could choose where the data goes.
    const m = /^https:\/\/([^/?#{}]+)(?:[/?#]|$)/.exec(url);
    if (!m) { errors.push(`${where}: must start https://<host>/ with no placeholder in the host`); return; }
    const host = m[1].toLowerCase();
    if (host !== m[1]) errors.push(`${where}: write the host in lower case`);
    if (!domains.includes(host)) errors.push(`${where}: host "${host}" is not in domains`);
    for (const ref of placeholders(url)) checkRef(errors, where, ref, ctx);
  }

  function checkBody(errors, where, body, ctx) {
    if (body === undefined) return;
    if (!isObj(body)) { errors.push(`${where}: body is {"format": ...}`); return; }
    checkOnly(errors, where, body, ['format', 'template']);
    if (!BODY_FORMATS.includes(body.format)) errors.push(`${where}.format: one of ${BODY_FORMATS.join(', ')}`);
    if (body.format === 'json-template') {
      if (!isObj(body.template)) { errors.push(`${where}.template: a JSON object`); return; }
      if (templateDepth(body.template) > 4) errors.push(`${where}.template: at most 4 levels deep`);
      for (const s of templateStrings(body.template, [])) {
        for (const ref of placeholders(s)) checkRef(errors, `${where}.template`, ref, Object.assign({}, ctx, { allowSecret: false }));
      }
    } else if (body.template !== undefined) {
      errors.push(`${where}.template: only with "json-template"`);
    }
  }

  function checkAuth(errors, where, auth, ctx) {
    if (auth === undefined) return;
    if (!isObj(auth)) { errors.push(`${where}: auth is {"header", "secret"}`); return; }
    checkOnly(errors, where, auth, ['header', 'scheme', 'secret', 'encode']);
    if (auth.encode !== undefined && !AUTH_ENCODINGS.includes(auth.encode)) errors.push(`${where}.encode: one of ${AUTH_ENCODINGS.join(', ')}`);
    if (!/^[A-Za-z][A-Za-z0-9-]{0,40}$/.test(String(auth.header || ''))) errors.push(`${where}.header: a header name`);
    if (/^(host|cookie|content-length|transfer-encoding|connection)$/i.test(String(auth.header || ''))) errors.push(`${where}.header: "${auth.header}" cannot be set`);
    if (auth.scheme !== undefined && !/^[A-Za-z]{1,20}$/.test(String(auth.scheme))) errors.push(`${where}.scheme: one word, like Bearer`);
    if (!ctx.secretNames.has(auth.secret)) errors.push(`${where}.secret: no secret named "${auth.secret}"`);
  }

  /**
   * A `response`: which of the connector's own fields on `placement` a reply
   * fills, and from which path in it. Nothing else can be named.
   */
  function checkResponse(errors, where, response, placement, fieldsByKey) {
    if (response === undefined) return;
    if (!isObj(response) || !isObj(response.fields)) { errors.push(`${where}: {"fields": {"<own field>": "path.in.reply"}}`); return; }
    checkOnly(errors, where, response, ['fields']);
    if (!Object.keys(response.fields).length) errors.push(`${where}.fields: name at least one field`);
    for (const [k, p] of Object.entries(response.fields)) {
      const f = fieldsByKey.get(k);
      if (!f) errors.push(`${where}.fields: no field named "${k}" — a reply can only fill the plugin's own fields`);
      else if (f.attach !== placement) errors.push(`${where}.fields.${k}: is on a ${f.attach}, the reply is about a ${placement}`);
      if (typeof p !== 'string' || !/^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+){0,5}$/.test(p)) errors.push(`${where}.fields.${k}: a dotted path, like "data.tracking"`);
    }
  }

  /** Every trigger in a manifest that sends something: buttons, events, and the refresh. */
  function triggersOf(m) {
    const out = (Array.isArray(m && m.actions) ? m.actions : []).concat(Array.isArray(m && m.events) ? m.events : []);
    if (isObj(m) && isObj(m.refresh)) out.push(m.refresh);
    return out;
  }

  /**
   * Check a manifest. Returns { ok, errors }. Every rule is a refusal with a
   * sentence, because the person reading it is a developer at a terminal.
   */
  function validateManifest(m) {
    const errors = [];
    if (!isObj(m)) return { ok: false, errors: ['a manifest is a JSON object'] };
    checkOnly(errors, 'manifest', m, TOP_KEYS);

    if (!isObj(m.khayt) || m.khayt.manifest !== MANIFEST_VERSION) errors.push(`khayt: must be {"manifest": ${MANIFEST_VERSION}}`);
    else checkOnly(errors, 'khayt', m.khayt, ['manifest']);
    if (typeof m.id !== 'string' || !ID_RE.test(m.id) || m.id.length > 100) errors.push('id: reverse-DNS in lower case, like "com.example.shipping"');
    checkLabel(errors, 'name', m.name);
    if (m.description !== undefined) checkLabel(errors, 'description', m.description, LIMITS.description);
    if (typeof m.publisher !== 'string' || !m.publisher.trim() || m.publisher.length > LIMITS.label) errors.push('publisher: who made it, up to 80 characters');
    if (typeof m.version !== 'string' || !SEMVER_RE.test(m.version)) errors.push('version: major.minor.patch');
    if (m.homepage !== undefined && !/^https:\/\/[^\s]{4,300}$/.test(String(m.homepage))) errors.push('homepage: an https URL');
    if (m.signature !== undefined && (typeof m.signature !== 'string' || !/^[A-Za-z0-9+/]{86}==$/.test(m.signature))) errors.push('signature: base64 ed25519 (64 bytes)');

    const domains = checkArray(errors, m, 'domains', LIMITS.domains);
    domains.forEach((d, i) => { if (!isAllowedHost(d)) errors.push(`domains[${i}]: "${d}" is not a public host name (lower case, no scheme, no IP)`); });
    if (new Set(domains).size !== domains.length) errors.push('domains: listed twice');

    const secrets = checkArray(errors, m, 'secrets', LIMITS.secrets);
    const secretNames = new Set();
    secrets.forEach((s, i) => {
      const w = `secrets[${i}]`;
      if (!isObj(s)) { errors.push(`${w}: an object`); return; }
      checkOnly(errors, w, s, ['name', 'label', 'kind']);
      if (!KEY_RE.test(String(s.name))) errors.push(`${w}.name: a short identifier`);
      else if (secretNames.has(s.name)) errors.push(`${w}.name: "${s.name}" twice`);
      else secretNames.add(s.name);
      checkLabel(errors, `${w}.label`, s.label);
      if (!SECRET_KINDS.includes(s.kind)) errors.push(`${w}.kind: one of ${SECRET_KINDS.join(', ')}`);
    });

    const settingsList = checkArray(errors, m, 'settings', LIMITS.settings);
    const settingsByKey = new Map();
    settingsList.forEach((st, i) => {
      const w = `settings[${i}]`;
      if (!isObj(st)) { errors.push(`${w}: an object`); return; }
      checkOnly(errors, w, st, ['key', 'label', 'type', 'kind', 'options', 'required']);
      if (!KEY_RE.test(String(st.key))) errors.push(`${w}.key: a short identifier`);
      else if (settingsByKey.has(st.key)) errors.push(`${w}.key: "${st.key}" twice`);
      else settingsByKey.set(st.key, st);
      checkLabel(errors, `${w}.label`, st.label);
      if (!SETTING_TYPES.includes(st.type)) errors.push(`${w}.type: one of ${SETTING_TYPES.join(', ')}`);
      if (st.kind !== undefined && !Object.prototype.hasOwnProperty.call(SETTING_KINDS, st.kind)) {
        errors.push(`${w}.kind: one of ${Object.keys(SETTING_KINDS).join(', ')}`);
      }
      if (st.kind !== undefined && st.kind !== 'text' && st.type !== 'text') errors.push(`${w}.kind: only a text setting can be a ${st.kind}`);
      if (st.required !== undefined && typeof st.required !== 'boolean') errors.push(`${w}.required: true or false`);
      if (st.type === 'enum') {
        if (!Array.isArray(st.options) || !st.options.length || st.options.length > 30) errors.push(`${w}.options: 1 to 30 choices`);
        else st.options.forEach((o, j) => {
          if (!isObj(o) || typeof o.value !== 'string' || !o.value) errors.push(`${w}.options[${j}]: {"value", "label"}`);
          else { checkOnly(errors, `${w}.options[${j}]`, o, ['value', 'label']); checkLabel(errors, `${w}.options[${j}].label`, o.label); }
        });
      } else if (st.options !== undefined) errors.push(`${w}.options: only for enum`);
    });

    const fields = checkArray(errors, m, 'fields', LIMITS.fields);
    const fieldsByKey = new Map();
    fields.forEach((f, i) => {
      const w = `fields[${i}]`;
      if (!isObj(f)) { errors.push(`${w}: an object`); return; }
      checkOnly(errors, w, f, ['key', 'label', 'type', 'attach', 'options']);
      if (!KEY_RE.test(String(f.key))) errors.push(`${w}.key: a short identifier`);
      else if (fieldsByKey.has(f.key)) errors.push(`${w}.key: "${f.key}" twice`);
      else fieldsByKey.set(f.key, f);
      checkLabel(errors, `${w}.label`, f.label);
      if (!FIELD_TYPES.includes(f.type)) errors.push(`${w}.type: one of ${FIELD_TYPES.join(', ')}`);
      if (!FIELD_ATTACH.includes(f.attach)) errors.push(`${w}.attach: one of ${FIELD_ATTACH.join(', ')}`);
      if (f.type === 'enum') {
        if (!Array.isArray(f.options) || !f.options.length || f.options.length > 30) errors.push(`${w}.options: 1 to 30 choices`);
        else f.options.forEach((o, j) => {
          if (!isObj(o) || typeof o.value !== 'string' || !o.value) errors.push(`${w}.options[${j}]: {"value", "label"}`);
          else { checkOnly(errors, `${w}.options[${j}]`, o, ['value', 'label']); checkLabel(errors, `${w}.options[${j}].label`, o.label); }
        });
      } else if (f.options !== undefined) errors.push(`${w}.options: only for enum`);
    });

    const actions = checkArray(errors, m, 'actions', LIMITS.actions);
    const actionIds = new Set();
    actions.forEach((a, i) => {
      const w = `actions[${i}]`;
      if (!isObj(a)) { errors.push(`${w}: an object`); return; }
      checkOnly(errors, w, a, ['id', 'label', 'placement', 'kind', 'url', 'send', 'body', 'auth', 'signWith', 'response']);
      if (!KEY_RE.test(String(a.id))) errors.push(`${w}.id: a short identifier`);
      else if (actionIds.has(a.id)) errors.push(`${w}.id: "${a.id}" twice`);
      else actionIds.add(a.id);
      checkLabel(errors, `${w}.label`, a.label);
      const sources = PLACEMENT_SOURCES[a.placement];
      if (!sources) { errors.push(`${w}.placement: one of ${Object.keys(PLACEMENT_SOURCES).join(', ')}`); return; }
      if (!ACTION_KINDS.includes(a.kind)) { errors.push(`${w}.kind: "post" or "open"`); return; }
      const ctx = { placement: a.placement, sources, fieldsByKey, settingsByKey, secretNames, allowSecret: a.kind === 'post' };
      checkUrl(errors, `${w}.url`, a.url, domains, ctx);
      if (a.kind === 'open') {
        for (const k of ['send', 'body', 'auth', 'signWith', 'response']) if (a[k] !== undefined) errors.push(`${w}.${k}: an "open" button only opens its URL`);
        return;
      }
      const send = a.send === undefined ? [] : a.send;
      if (!Array.isArray(send) || send.length > LIMITS.send) errors.push(`${w}.send: a list of up to ${LIMITS.send} fields`);
      else send.forEach((ref, j) => checkRef(errors, `${w}.send[${j}]`, String(ref), Object.assign({}, ctx, { allowSecret: false })));
      checkBody(errors, `${w}.body`, a.body, ctx);
      checkAuth(errors, `${w}.auth`, a.auth, ctx);
      if (a.signWith !== undefined && !secretNames.has(a.signWith)) errors.push(`${w}.signWith: no secret named "${a.signWith}"`);
      checkResponse(errors, `${w}.response`, a.response, a.placement, fieldsByKey);
    });

    const events = checkArray(errors, m, 'events', LIMITS.events);
    events.forEach((e, i) => {
      const w = `events[${i}]`;
      if (!isObj(e)) { errors.push(`${w}: an object`); return; }
      checkOnly(errors, w, e, ['event', 'url', 'send', 'body', 'auth', 'signWith', 'response']);
      if (!EVENTS.includes(e.event)) errors.push(`${w}.event: one of ${EVENTS.join(', ')}`);
      const ctx = { placement: 'order', sources: PLACEMENT_SOURCES.order, fieldsByKey, settingsByKey, secretNames, allowSecret: true };
      checkUrl(errors, `${w}.url`, e.url, domains, ctx);
      const send = e.send === undefined ? [] : e.send;
      if (!Array.isArray(send) || send.length > LIMITS.send) errors.push(`${w}.send: a list of up to ${LIMITS.send} fields`);
      else send.forEach((ref, j) => checkRef(errors, `${w}.send[${j}]`, String(ref), Object.assign({}, ctx, { allowSecret: false })));
      checkBody(errors, `${w}.body`, e.body, ctx);
      checkAuth(errors, `${w}.auth`, e.auth, ctx);
      if (e.signWith !== undefined && !secretNames.has(e.signWith)) errors.push(`${w}.signWith: no secret named "${e.signWith}"`);
      // An event is about one job, so its reply can fill that job's fields.
      checkResponse(errors, `${w}.response`, e.response, 'order', fieldsByKey);
    });

    if (m.refresh !== undefined) {
      const r = m.refresh;
      const w = 'refresh';
      if (!isObj(r)) errors.push(`${w}: an object`);
      else {
        checkOnly(errors, w, r, ['every', 'when', 'method', 'url', 'send', 'body', 'auth', 'signWith', 'response']);
        if (!Number.isInteger(r.every) || r.every < REFRESH.minEvery || r.every > REFRESH.maxEvery) {
          errors.push(`${w}.every: whole minutes, ${REFRESH.minEvery} to ${REFRESH.maxEvery}`);
        }
        const when = fieldsByKey.get(String(r.when));
        if (!when) errors.push(`${w}.when: one of the connector's own job fields — a job is checked only when it is filled in`);
        else if (when.attach !== 'order') errors.push(`${w}.when: "${r.when}" is on a ${when.attach}; refresh checks jobs`);
        const method = r.method === undefined ? 'POST' : r.method;
        if (!REFRESH_METHODS.includes(method)) errors.push(`${w}.method: "GET" or "POST"`);
        const ctx = { placement: 'order', sources: PLACEMENT_SOURCES.order, fieldsByKey, settingsByKey, secretNames, allowSecret: true };
        checkUrl(errors, `${w}.url`, r.url, domains, ctx);
        if (method === 'GET') {
          for (const k of ['send', 'body']) if (r[k] !== undefined) errors.push(`${w}.${k}: a GET has no body; put what it needs in the URL`);
        } else {
          const send = r.send === undefined ? [] : r.send;
          if (!Array.isArray(send) || send.length > LIMITS.send) errors.push(`${w}.send: a list of up to ${LIMITS.send} fields`);
          else send.forEach((ref, j) => checkRef(errors, `${w}.send[${j}]`, String(ref), Object.assign({}, ctx, { allowSecret: false })));
          checkBody(errors, `${w}.body`, r.body, ctx);
        }
        checkAuth(errors, `${w}.auth`, r.auth, ctx);
        if (r.signWith !== undefined && !secretNames.has(r.signWith)) errors.push(`${w}.signWith: no secret named "${r.signWith}"`);
        // A refresh that fills nothing would send the shop's data for no use.
        if (r.response === undefined) errors.push(`${w}.response: required — a refresh exists to fill the connector's own fields`);
        else checkResponse(errors, `${w}.response`, r.response, 'order', fieldsByKey);
      }
    }

    const scopes = checkArray(errors, m, 'scopes', SCOPES.length);
    scopes.forEach((s, i) => {
      if (RESERVED_SCOPES.includes(s)) errors.push(`scopes[${i}]: "${s}" arrives with the Cloud relay; a connector cannot reach the shop yet`);
      else if (!SCOPES.includes(s)) errors.push(`scopes[${i}]: one of ${SCOPES.join(', ')}`);
    });
    // A reply that fills fields is a write to the book, so it is asked for —
    // and shown on the consent screen — like any other write.
    if (actions.some(a => isObj(a) && a.response !== undefined) && !scopes.includes('fields.write')) {
      errors.push('scopes: an action with a "response" needs "fields.write"');
    }
    if (events.some(e => isObj(e) && e.response !== undefined) && !scopes.includes('fields.write')) {
      errors.push('scopes: an event with a "response" needs "fields.write"');
    }
    if (m.refresh !== undefined && !scopes.includes('fields.write')) {
      errors.push('scopes: "refresh" needs "fields.write"');
    }

    // A declared host nothing uses is a host the consent screen would show for
    // no reason — and a reason to ask what it is for.
    const used = new Set();
    for (const t of triggersOf(m)) {
      const mm = isObj(t) && typeof t.url === 'string' && /^https:\/\/([^/?#{}]+)/.exec(t.url);
      if (mm) used.add(mm[1]);
    }
    domains.forEach(d => { if (isAllowedHost(d) && !used.has(d)) errors.push(`domains: "${d}" is not used by any action, event or refresh`); });

    return { ok: errors.length === 0, errors };
  }

  /** Every book reference a trigger sends: `send`, URL placeholders and template placeholders. */
  function refsOf(t) {
    const refs = new Set();
    if (!isObj(t)) return refs;
    (Array.isArray(t.send) ? t.send : []).forEach(r => refs.add(String(r)));
    placeholders(t.url || '').forEach(r => refs.add(r));
    if (isObj(t.body) && t.body.format === 'json-template') {
      for (const s of templateStrings(t.body.template, [])) placeholders(s).forEach(r => refs.add(r));
    }
    for (const r of Array.from(refs)) if (r.startsWith('secret.') || r.startsWith('now.')) refs.delete(r);
    return refs;
  }

  function hostOf(url) {
    const m = /^https:\/\/([^/?#{}]+)/.exec(String(url || ''));
    return m ? m[1] : '';
  }

  /** The category a reference is declared under. `m` is needed for a `config.` ref. */
  function categoryOf(ref, m) {
    if (String(ref).startsWith('field.')) return OWN_FIELD_CATEGORY;
    if (String(ref).startsWith('config.')) {
      const st = (isObj(m) && Array.isArray(m.settings) ? m.settings : []).find(x => isObj(x) && x.key === String(ref).slice(7));
      return st ? SETTING_KINDS[st.kind || 'text'] || null : null;
    }
    return SENDABLE_FIELDS[ref] ? SENDABLE_FIELDS[ref].category : null;
  }

  /**
   * What a manifest asks for, flattened and sorted: the fields it can send,
   * the hosts it can reach, the scopes it wants, and the privacy categories
   * those fields fall under. This is what a shop grants.
   */
  function permissionsOf(m) {
    const fields = new Set();
    const domains = new Set();
    for (const t of triggersOf(m)) {
      refsOf(t).forEach(r => fields.add(r));
      const h = hostOf(t && t.url);
      if (h) domains.add(h);
    }
    const categories = new Set(Array.from(fields).map(f => categoryOf(f, m)).filter(Boolean));
    const out = {
      version: String((m && m.version) || ''),
      fields: Array.from(fields).sort(),
      domains: Array.from(domains).sort(),
      scopes: Array.from(new Set(Array.isArray(m && m.scopes) ? m.scopes : [])).sort(),
      categories: Array.from(categories).sort(),
    };
    // How often it may check on its own, in minutes — only when it does.
    const every = refreshEvery(m);
    if (every) out.refresh = every;
    return out;
  }

  /** A manifest's refresh interval in minutes (never under the floor), or 0 for none. */
  function refreshEvery(m) {
    if (!isObj(m) || !isObj(m.refresh) || !Number.isFinite(Number(m.refresh.every))) return 0;
    return Math.max(REFRESH.minEvery, Math.floor(Number(m.refresh.every)));
  }

  /**
   * What `manifest` asks for beyond `granted` (a shop's stored
   * `settings.plugins[].granted`, or null for never granted). Any non-empty
   * list means the plugin waits for the shop to agree again. Asking for LESS
   * is never a reason to ask.
   */
  function diffPermissions(granted, manifest) {
    const want = permissionsOf(manifest);
    const g = isObj(granted) ? granted : {};
    const has = k => new Set(Array.isArray(g[k]) ? g[k] : []);
    const more = k => want[k].filter(x => !has(k).has(x));
    const out = { fields: more('fields'), domains: more('domains'), scopes: more('scopes') };
    // A refresh the shop never agreed to, or one that checks more often than
    // it agreed to, is asking for more. Checking less often is not.
    const grantedEvery = Number(g.refresh);
    out.refresh = !!want.refresh && !(Number.isFinite(grantedEvery) && grantedEvery > 0 && grantedEvery <= want.refresh);
    out.widened = out.fields.length > 0 || out.domains.length > 0 || out.scopes.length > 0 || out.refresh;
    return out;
  }

  /** The grant to store once a shop agrees: exactly what it was shown. */
  function grantFor(manifest) {
    const p = permissionsOf(manifest);
    const g = { version: p.version, fields: p.fields, domains: p.domains, scopes: p.scopes };
    if (p.refresh) g.refresh = p.refresh;
    return g;
  }

  /**
   * The consent screen, one row per host: which fields go there and the
   * category each is declared under. A host that receives nothing from the
   * book (an "open" link with no placeholders) still gets a row — the shop is
   * still sent there.
   */
  function consentRows(m) {
    const byHost = new Map();
    for (const t of triggersOf(m)) {
      const h = hostOf(t && t.url);
      if (!h) continue;
      if (!byHost.has(h)) byHost.set(h, new Set());
      refsOf(t).forEach(r => byHost.get(h).add(r));
    }
    return Array.from(byHost.keys()).sort().map(host => ({
      host,
      fields: Array.from(byHost.get(host)).sort().map(key => ({ key, category: categoryOf(key, m) })),
    }));
  }

  /**
   * The consent sheet's refresh line (`plg.consent_refresh`), or null when
   * the connector never checks on its own: how often, which host, and the
   * field that decides which jobs — its label in `lang`, else English.
   */
  function refreshConsent(m, lang) {
    const every = refreshEvery(m);
    if (!every) return null;
    const host = hostOf(m.refresh.url);
    const f = (Array.isArray(m.fields) ? m.fields : []).find(x => isObj(x) && x.key === m.refresh.when);
    const label = f && isObj(f.label) ? (f.label[lang] || f.label[String(lang || '').split('-')[0]] || f.label.en || f.key) : String(m.refresh.when || '');
    return { every, host, field: m.refresh.when, fieldLabel: label };
  }

  /**
   * One installed connector as the book stores it (`settings.plugins[]`):
   * { id, version, enabled, manifest, granted, config }, plus `secrets` on
   * the desktop only (stripped before a book reaches a phone or the cloud).
   * The manifest travels whole, signature inside, because a phone has no
   * catalogue of its own. Whether it is REVIEWED is never stored — a stored
   * flag can be written by anyone; the platform verifies the signature.
   *
   * Returns { ok, errors, paused } — `paused` when the manifest asks for more
   * than was granted, which every device honours.
   */
  function checkEntry(e) {
    const errors = [];
    if (!isObj(e)) return { ok: false, errors: ['an entry is an object'], paused: true };
    checkOnly(errors, 'entry', e, ['id', 'version', 'enabled', 'manifest', 'granted', 'config', 'secrets']);
    const v = validateManifest(e.manifest);
    v.errors.forEach(x => errors.push('manifest: ' + x));
    if (isObj(e.manifest) && (e.id !== e.manifest.id || e.version !== e.manifest.version)) {
      errors.push('entry: id and version must be the manifest\'s');
    }
    if (e.config !== undefined && !isObj(e.config)) errors.push('config: an object');
    if (isObj(e.config) && isObj(e.manifest)) {
      const known = new Set((Array.isArray(e.manifest.settings) ? e.manifest.settings : []).filter(isObj).map(x => x.key));
      for (const [k, v] of Object.entries(e.config)) {
        if (!known.has(k)) errors.push(`config.${k}: not a setting of this connector`);
        else if (typeof v === 'string' && v.length > LIMITS.settingValue) errors.push(`config.${k}: longer than ${LIMITS.settingValue} characters`);
      }
    }
    // A grant can only narrow what the signed manifest declares. A book edited
    // to grant a host or scope the manifest never named would otherwise widen
    // what may be sent without a new signature or a new consent.
    if (isObj(e.granted) && isObj(e.manifest)) {
      const declared = permissionsOf(e.manifest);
      for (const k of ['fields', 'domains', 'scopes']) {
        const extra = (Array.isArray(e.granted[k]) ? e.granted[k] : []).filter(x => !declared[k].includes(x));
        if (extra.length) errors.push(`granted.${k}: ${extra.join(', ')} not in the manifest`);
      }
      if (e.granted.refresh !== undefined && !(Number.isInteger(e.granted.refresh) && e.granted.refresh >= REFRESH.minEvery)) {
        errors.push(`granted.refresh: whole minutes, at least ${REFRESH.minEvery}`);
      }
    }
    const paused = errors.length > 0 || diffPermissions(e.granted, e.manifest).widened;
    return { ok: errors.length === 0, errors, paused };
  }

  /** May a reply be written into this plugin's fields? Only with fields.write granted. */
  function mayWriteFields(entry) {
    return isObj(entry) && isObj(entry.granted) && Array.isArray(entry.granted.scopes)
      && entry.granted.scopes.includes('fields.write') && !checkEntry(entry).paused;
  }

  /** Sorted keys, no whitespace, `signature` left out: the bytes that are signed. */
  function canonicalJSON(m) {
    const walk = (v) => {
      if (Array.isArray(v)) return '[' + v.map(walk).join(',') + ']';
      if (isObj(v)) {
        return '{' + Object.keys(v).sort().filter(k => v[k] !== undefined).map(k => JSON.stringify(k) + ':' + walk(v[k])).join(',') + '}';
      }
      return JSON.stringify(v === undefined ? null : v);
    };
    const copy = Object.assign({}, m);
    delete copy.signature;
    return walk(copy);
  }

  /**
   * The rules above as JSON Schema (2020-12), for the developer docs and for
   * editors. The validator is the authority — it also checks what a schema
   * cannot say (a host used by a URL, a field reachable from a placement) —
   * and a test holds the two to the same keys and enums.
   */
  function manifestJsonSchema() {
    const label = { type: 'object', required: ['en'], additionalProperties: { type: 'string', maxLength: LIMITS.label },
      propertyNames: { pattern: '^[a-z]{2}(-[A-Z]{2})?$' } };
    const key = { type: 'string', pattern: KEY_RE.source };
    const url = { type: 'string', maxLength: LIMITS.url, pattern: '^https://[a-z0-9.-]+(/|\\?|#|$)' };
    const send = { type: 'array', maxItems: LIMITS.send, items: { type: 'string',
      anyOf: [{ enum: Object.keys(SENDABLE_FIELDS) }, { pattern: '^(field|config)\\.[a-z][a-zA-Z0-9_]{0,31}$' },
        { pattern: NOW_RE.source }] } };
    const body = { type: 'object', additionalProperties: false, required: ['format'],
      properties: { format: { enum: BODY_FORMATS }, template: { type: 'object' } } };
    const auth = { type: 'object', additionalProperties: false, required: ['header', 'secret'],
      properties: { header: { type: 'string' }, scheme: { type: 'string' }, secret: key, encode: { enum: AUTH_ENCODINGS } } };
    const response = { type: 'object', additionalProperties: false, required: ['fields'],
      properties: { fields: { type: 'object', minProperties: 1, additionalProperties: { type: 'string' } } } };
    return {
      $schema: 'https://json-schema.org/draft/2020-12/schema',
      $id: 'https://khaytapp.com/schemas/plugin-manifest-v1.json',
      title: 'Khayt connector manifest',
      type: 'object',
      additionalProperties: false,
      required: ['khayt', 'id', 'name', 'publisher', 'version'],
      properties: {
        khayt: { type: 'object', additionalProperties: false, required: ['manifest'], properties: { manifest: { const: MANIFEST_VERSION } } },
        id: { type: 'string', maxLength: 100, pattern: ID_RE.source },
        name: label,
        description: Object.assign({}, label, { additionalProperties: { type: 'string', maxLength: LIMITS.description } }),
        publisher: { type: 'string', minLength: 1, maxLength: LIMITS.label },
        version: { type: 'string', pattern: SEMVER_RE.source },
        homepage: { type: 'string', pattern: '^https://' },
        signature: { type: 'string', pattern: '^[A-Za-z0-9+/]{86}==$' },
        domains: { type: 'array', maxItems: LIMITS.domains, uniqueItems: true, items: { type: 'string', pattern: HOST_RE.source } },
        settings: { type: 'array', maxItems: LIMITS.settings, items: { type: 'object', additionalProperties: false,
          required: ['key', 'label', 'type'],
          properties: { key, label, type: { enum: SETTING_TYPES }, kind: { enum: Object.keys(SETTING_KINDS) },
            required: { type: 'boolean' },
            options: { type: 'array', minItems: 1, maxItems: 30, items: { type: 'object', additionalProperties: false,
              required: ['value', 'label'], properties: { value: { type: 'string', minLength: 1 }, label } } } } } },
        secrets: { type: 'array', maxItems: LIMITS.secrets, items: { type: 'object', additionalProperties: false,
          required: ['name', 'label', 'kind'], properties: { name: key, label, kind: { enum: SECRET_KINDS } } } },
        fields: { type: 'array', maxItems: LIMITS.fields, items: { type: 'object', additionalProperties: false,
          required: ['key', 'label', 'type', 'attach'],
          properties: { key, label, type: { enum: FIELD_TYPES }, attach: { enum: FIELD_ATTACH },
            options: { type: 'array', minItems: 1, maxItems: 30, items: { type: 'object', additionalProperties: false,
              required: ['value', 'label'], properties: { value: { type: 'string', minLength: 1 }, label } } } } } },
        actions: { type: 'array', maxItems: LIMITS.actions, items: { type: 'object', additionalProperties: false,
          required: ['id', 'label', 'placement', 'kind', 'url'],
          properties: { id: key, label, placement: { enum: Object.keys(PLACEMENT_SOURCES) }, kind: { enum: ACTION_KINDS },
            url, send, body, auth, signWith: key, response } } },
        events: { type: 'array', maxItems: LIMITS.events, items: { type: 'object', additionalProperties: false,
          required: ['event', 'url'],
          properties: { event: { enum: EVENTS }, url, send, body, auth, signWith: key, response } } },
        refresh: { type: 'object', additionalProperties: false, required: ['every', 'when', 'url', 'response'],
          properties: { every: { type: 'integer', minimum: REFRESH.minEvery, maximum: REFRESH.maxEvery }, when: key,
            method: { enum: REFRESH_METHODS }, url, send, body, auth, signWith: key, response } },
        scopes: { type: 'array', uniqueItems: true, items: { enum: SCOPES } },
      },
    };
  }

  const api = {
    MANIFEST_VERSION, SIGNING_KEYS, SENDABLE_FIELDS, OWN_FIELD_CATEGORY, PLACEMENT_SOURCES,
    FIELD_TYPES, FIELD_ATTACH, SETTING_TYPES, SETTING_KINDS, ACTION_KINDS, SECRET_KINDS, SCOPES, RESERVED_SCOPES, EVENTS, BODY_FORMATS, LIMITS, TOP_KEYS,
    REFRESH, REFRESH_METHODS, NOW_MAX_DAYS, AUTH_ENCODINGS, nowDays,
    validateManifest, permissionsOf, diffPermissions, grantFor, consentRows, refreshConsent, refreshEvery, categoryOf, checkEntry, mayWriteFields,
    canonicalJSON, manifestJsonSchema, isAllowedHost, placeholders,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginManifest = api;
})();
