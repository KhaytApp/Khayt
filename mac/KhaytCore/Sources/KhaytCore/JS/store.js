/**
 * Khayt store snapshot helpers — export/import/backup payloads and secret redaction.
 * Loaded before app.js; collections live in app.js globals.
 *
 * IN `lib/`, NOT `renderer/`, BECAUSE THE MAC APP EXPORTS TOO.
 *
 * `redactSettingsForExport` is what stands between a shop's accountant and its
 * API keys, and it is data-driven precisely so that adding a shipping carrier
 * does not quietly export the next one's credentials. A second copy of that in
 * Swift would be a second thing to forget to update — so the Mac loads this
 * one, the renderer loads it by script tag like the hundred other `../lib/`
 * modules, and Node requires it.
 */
(function (global) {
  const STORE_VERSION = 10;
  const STORE_SECRET_MASK = '__KHAYT_MASKED__';
  // Credential-shaped key names, for the data-driven provider groups below where the
  // exact field names are not known ahead of time. Mirrors lib/telemetry-scrub.js.
  const STORE_SECRET_KEY_RE = /(api[-_]?key|secret|password|passwd|token|pin|csid|pcsid|authorization|bearer|access[-_]?code|private[-_]?key)/i;

  function redactSettingsForExport(src) {
    const s = JSON.parse(JSON.stringify(src || {}));
    const mask = (obj, key) => { if (obj?.[key]) obj[key] = STORE_SECRET_MASK; };
    mask(s.emailConfig, 'apiKey');
    mask(s.emailConfig, 'smtpPassword');
    for (const k of ['authToken', 'token', 'appSid', 'secret']) mask(s.smsConfig, k);
    mask(s.accountingSync, 'secret');
    // The print library's credentials. These were on `lib/store-secret-paths.js`
    // — so they are encrypted at rest and masked on the way to the renderer —
    // and on NEITHER of the two lists here, so an export built from anything
    // holding real values (the store on disk, rather than the renderer's already
    // masked copy) shipped them. The Drive refresh token outranks the bucket
    // secret: a leaked bucket key reaches one bucket, that reaches every file
    // Khayt ever put in the shop's Drive, and it does not expire.
    mask(s.printLibrary?.s3, 'secretAccessKey');
    mask(s.printLibrary?.gdrive, 'refreshToken');
    mask(s.printLibrary?.gdrive, 'clientSecret');
    mask(s.telegram, 'botToken');
    mask(s.ntfy, 'token');
    mask(s.webhooks, 'secret');
    mask(s.eventWebhooks, 'secret');
    mask(s.ai, 'apiKey');
    mask(s.cloud, 'token');
    mask(s.zatcaPhase2, 'csid');
    mask(s.zatcaPhase2, 'pcsid');
    ['tabby', 'tamara', 'stripe'].forEach(prov => {
      mask(s.bnpl?.[prov], 'apiKey');
      if (prov === 'tamara') mask(s.bnpl?.tamara, 'notificationToken');
    });
    if (s.lanApi) {
      ['pin', 'intakePin', 'intakeToken', 'calendarToken', 'webhookToken', 'sallaWebhookSecret', 'zidWebhookSecret']
        .forEach(k => mask(s.lanApi, k));
    }
    // Scoped API tokens: drop the hashes entirely on export (a hash is still a
    // credential-equivalent for offline cracking; the owner re-mints instead).
    if (Array.isArray(s.lanApi?.apiTokens)) {
      s.lanApi.apiTokens = s.lanApi.apiTokens.map(tk => ({
        id: tk.id, label: tk.label, scopes: tk.scopes, createdAt: tk.createdAt, lastUsedAt: tk.lastUsedAt,
        hash: STORE_SECRET_MASK,
      }));
    }
    // Per-subscription webhook signing secrets.
    if (Array.isArray(s.webhooks?.subscriptions)) {
      s.webhooks.subscriptions = s.webhooks.subscriptions.map(sub => (
        sub && sub.secret ? { ...sub, secret: STORE_SECRET_MASK } : sub
      ));
    }
    // Shipping carriers and BNPL providers are DATA-DRIVEN: a new one is added to a
    // catalog (renderer/carriers.js, BNPL_CATALOG), not here. A hardcoded list of ids
    // would silently export the next carrier's credentials in cleartext, so iterate
    // whatever is actually present and mask every credential-shaped key on it.
    for (const group of [s.shipping, s.bnpl]) {
      for (const provider of Object.values(group || {})) {
        if (!provider || typeof provider !== 'object') continue; // e.g. shipping.defaultCarrier
        for (const key of Object.keys(provider)) {
          if (STORE_SECRET_KEY_RE.test(key)) mask(provider, key);
        }
      }
    }
    return s;
  }

  /**
   * Take the per-order access tokens out.
   *
   * `trackingToken` and `quoteApprovalToken` are CAPABILITIES, not data.
   * `verifyOrderAccessToken` in lan-quote-page.js is the whole of the
   * authorisation for both: the tracking token opens an order's status page
   * over LAN and is the `/p/<token>` segment of the customer portal (and the
   * key `cloudPortalReply` posts a message with, as that customer); the
   * approval token APPROVES A QUOTE, which turns it into an order in the
   * shop's book. Handing an accountant a file with nineteen of them in it is
   * handing over nineteen live links.
   *
   * DELETED rather than masked, unlike everything else here. Both are minted on
   * demand — `ensureTrackingToken`, `ensureQuoteApprovalToken`, and the same
   * fallback in renderer/util.js — so an absent one is re-minted at first use,
   * while `__KHAYT_MASKED__` is truthy and would be adopted AS the token by
   * every order at once. Same reasoning as the `lanApi.apiTokens` hashes above:
   * the owner re-mints.
   *
   * The cost is that a shop that migrates by export/import republishes its
   * portal links. The backup in `backups/` is not redacted and is the copy that
   * restores a shop whole; this is the copy that leaves.
   */
  function redactOrdersForExport(arr) {
    return (arr || []).map(o => {
      if (!o || typeof o !== 'object') return o;
      if (!o.trackingToken && !o.quoteApprovalToken) return o;
      const out = { ...o };
      delete out.trackingToken;
      delete out.quoteApprovalToken;
      return out;
    });
  }

  function redactMachinesForExport(arr) {
    return (arr || []).map(m => {
      if (!m?.printerApi && !m?.smartPlug) return m;
      const out = { ...m };
      if (m.printerApi) {
        const pa = { ...m.printerApi };
        if (pa.apiKey) pa.apiKey = STORE_SECRET_MASK;
        if (pa.accessCode) pa.accessCode = STORE_SECRET_MASK;
        out.printerApi = pa;
      }
      // A plug's token or password switches a printer's power: the same rule.
      if (m.smartPlug) {
        const sp = { ...m.smartPlug };
        if (sp.token) sp.token = STORE_SECRET_MASK;
        if (sp.password) sp.password = STORE_SECRET_MASK;
        out.smartPlug = sp;
      }
      return out;
    });
  }

  /** Plain snapshot of all persisted collections (shallow object of live arrays). */
  function buildSnapshot(collections) {
    // Stamp the schema version INTO the file. STORE_VERSION existed but only ever reached
    // export payloads, so the store on disk was unversioned — a build could not tell
    // which Khayt wrote it, and opening a newer store silently truncated the
    // collections it did not recognise. See the downgrade guard in main.js.
    return { version: STORE_VERSION, ...collections };
  }

  function buildExportPayload(collections, { redactSecrets = false } = {}) {
    const snap = buildSnapshot(collections);
    return {
      version: STORE_VERSION,
      exportedAt: new Date().toISOString(),
      ...snap,
      settings: redactSecrets ? redactSettingsForExport(snap.settings) : snap.settings,
      machines: redactSecrets ? redactMachinesForExport(snap.machines) : snap.machines,
      printLog: redactSecrets ? redactOrdersForExport(snap.printLog) : snap.printLog,
    };
  }

  const api = {
    VERSION: STORE_VERSION,
    SECRET_MASK: STORE_SECRET_MASK,
    redactSettingsForExport,
    redactMachinesForExport,
    redactOrdersForExport,
    buildSnapshot,
    buildExportPayload,
  };

  global.KhaytStore = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
