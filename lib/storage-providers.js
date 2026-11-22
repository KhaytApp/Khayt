'use strict';
// Wrapped so JavaScriptCore on the Mac can load it into its one shared
// context (top-level `const`s would collide there); Node still requires it.
(function (global) {

/**
 * The buckets a shop is actually likely to point Khayt at.
 *
 * `lib/s3-client.js` already speaks to every one of these — they are all SigV4,
 * and not one of them needed a line of protocol code. What they needed was for
 * the endpoint not to be a blank box. "https://<account>.r2.cloudflarestorage.com"
 * is a placeholder nobody can fill in without leaving the app to go and read
 * Cloudflare's docs, and a mistyped endpoint fails exactly like a wrong secret:
 * a 403 that says nothing about which of the six fields is wrong.
 *
 * So this is a lookup table, not an integration. Pick a provider, type the one
 * thing only you know (an account id, a region), and the endpoint is built for
 * you. `custom` stays at the end because this list will always be missing
 * someone's provider — a regional host, a company MinIO — and refusing to let
 * them type a URL would be a downgrade from what shipped before it.
 *
 * ── On the numbers ──────────────────────────────────────────────────────────
 * `cost` is a ROUGH HINT at 500 GB, checked on PRICED_ON below. It is here
 * because the choice between these is mostly a cost choice and the spread is
 * more than 5×; a shop picking from a list of bare brand names picks the brand
 * it recognises, which is reliably the most expensive one on the list.
 *
 * It is a hint and the UI says so. Providers reprice, every one of them has a
 * free tier or a minimum that these strings cannot express, and a figure in a
 * dropdown that claims more precision than that would be a lie with a currency
 * symbol on it. `egress` is the field worth trusting longest: whether downloads
 * are billed is a pricing *philosophy* and changes far more slowly than a rate.
 * The dated table with the real conditions lives in docs/CLOUD-STORAGE.md.
 *
 * Egress matters more than storage here and it is worth saying why once: a print
 * library is re-read constantly. Every reprint of a year-old order pulls the
 * model back down, and with tiering (lib/print-library-tier.js) that is the
 * normal path rather than the exception. A provider that bills downloads bills
 * this app's busiest hour.
 *
 * Pure: no network, no fs, no Electron.
 */

const PRICED_ON = '2026-08-23';

const str = (v) => String(v == null ? '' : v).trim();

/**
 * `vars` are the parts of an endpoint that only the shop knows. Each carries a
 * `hint` because "Account ID" is not self-locating — the entire point is to
 * save a trip to the provider's dashboard, so the field says where to look.
 *
 * `egress`:
 *   'free'      downloads are never billed
 *   'allowance' free up to some quota, billed past it
 *   'metered'   billed per GB from the first byte
 *   'self'      your own hardware and your own bandwidth
 *
 * `signup` is where a shop that does not have an account yet goes to open one.
 * The dropdown otherwise assumes an account already exists — every field on the
 * page asks for something you can only read off a dashboard you have to have
 * signed up for first, so the one shop the presets help least is the one that
 * has never used object storage. A link is the whole fix.
 *
 * These point at each provider's own product or signup page rather than at a
 * deep link into a signup funnel. Funnel URLs are re-cut every time a provider
 * redesigns; a product page outlives that and always carries the signup button.
 * A link that 404s is worse than no link — it reads as the app being abandoned.
 * `custom` has none on purpose: there is no such thing as signing up for
 * "some other S3-compatible provider".
 */
const PROVIDERS = [
  {
    id: 'r2',
    label: 'Cloudflare R2',
    signup: 'https://dash.cloudflare.com/sign-up',
    endpoint: 'https://{account}.r2.cloudflarestorage.com',
    region: 'auto',
    vars: [{ key: 'account', label: 'Account ID', hint: 'Cloudflare dashboard → R2 → Overview, right-hand sidebar' }],
    cost: '~$7.50/mo for 500 GB',
    egress: 'free',
    note: 'Downloads are never billed, at any volume.',
    // Recommended is not a tie-break between near-equals. R2 is the only entry
    // where re-reading the library can never produce a bill, and re-reading the
    // library is what this app does.
    recommended: true,
  },
  {
    id: 'b2',
    label: 'Backblaze B2',
    signup: 'https://www.backblaze.com/sign-up/cloud-storage',
    endpoint: 'https://s3.{region}.backblazeb2.com',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: "In your bucket's endpoint, e.g. us-west-004" }],
    cost: '~$3.00/mo for 500 GB',
    egress: 'allowance',
    note: 'Downloads free up to 3× what you store — 1.5 TB/mo on a 500 GB library.',
    recommended: true,
  },
  {
    id: 'idrive',
    label: 'IDrive e2',
    signup: 'https://www.idrive.com/e2/',
    // No template, deliberately. e2 issues every account its OWN endpoint host —
    // r4a6.or5.idrivee2-75.com, u6a5.bn.idrivee2-61.com — and even the numeric
    // suffix on the domain varies. There is no pattern to fill in, so this preset
    // sets the region and the cost note and asks for the endpoint.
    endpoint: '',
    endpointFromDashboard: true,
    endpointHint: 'e2 dashboard → your bucket → its endpoint, e.g. r4a6.or5.idrivee2-75.com. '
      + 'Every account gets a different one; do not copy another shop\'s.',
    region: '',
    vars: [],
    cost: '~$2.00/mo for 500 GB',
    egress: 'allowance',
    note: 'Among the cheapest per GB. Downloads free up to what you store.',
  },
  {
    id: 'wasabi',
    label: 'Wasabi',
    signup: 'https://wasabi.com/cloud-object-storage',
    endpoint: 'https://s3.{region}.wasabisys.com',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'e.g. us-east-1, eu-central-1, ap-southeast-1' }],
    cost: '~$7/mo minimum',
    egress: 'free',
    // Stated rather than omitted. Wasabi's headline rate is competitive and a
    // shop will find it anyway; the two minimums are what make it a bad fit for
    // a library that is under 1 TB or that churns, and they are not on the
    // pricing page's front page.
    note: 'Bills a 1 TB minimum, so a 500 GB library pays for 1 TB — and a deleted '
      + 'file keeps billing for 90 days. Good above 1 TB, poor below it.',
  },
  {
    id: 'storj',
    label: 'Storj',
    signup: 'https://www.storj.io/signup',
    endpoint: 'https://gateway.storjshare.io',
    region: 'us-east-1',
    vars: [],
    cost: '~$2.00/mo for 500 GB',
    egress: 'metered',
    note: 'Cheap per GB, but bills per segment — a library of many small thumbnails '
      + 'costs more than its size suggests. Downloads are billed.',
  },
  {
    id: 'hetzner',
    label: 'Hetzner Object Storage',
    signup: 'https://www.hetzner.com/storage/object-storage/',
    endpoint: 'https://{location}.your-objectstorage.com',
    region: '',
    vars: [{ key: 'location', label: 'Location', hint: 'fsn1, nbg1 or hel1 — wherever you made the bucket' }],
    cost: '~$6/mo floor (includes 1 TB + 1 TB traffic)',
    egress: 'allowance',
    note: 'Flat base fee rather than per-GB, so it is poor value well under 1 TB '
      + 'and good value approaching it. EU only.',
    residency: 'EU',
  },
  {
    id: 'scaleway',
    label: 'Scaleway',
    signup: 'https://www.scaleway.com/en/object-storage/',
    endpoint: 'https://s3.{region}.scw.cloud',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'fr-par, nl-ams or pl-waw' }],
    cost: 'free under 75 GB',
    egress: 'allowance',
    note: 'A real free tier (75 GB storage and egress), which makes it the cheapest '
      + 'way to try tiering before committing. EU sovereign.',
    residency: 'EU',
  },
  {
    id: 'ovh',
    label: 'OVHcloud',
    signup: 'https://www.ovhcloud.com/en/public-cloud/object-storage/',
    endpoint: 'https://s3.{region}.io.cloud.ovh.net',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'e.g. gra, sbg, de, uk' }],
    cost: '~$4–6/mo for 500 GB',
    egress: 'allowance',
    note: 'EU sovereign, with an archive tier for genuinely cold models.',
    residency: 'EU',
  },
  {
    id: 'do',
    label: 'DigitalOcean Spaces',
    signup: 'https://www.digitalocean.com/products/spaces',
    endpoint: 'https://{region}.digitaloceanspaces.com',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'nyc3, ams3, sgp1, fra1, sfo3 or syd1' }],
    cost: '~$10/mo for 500 GB',
    egress: 'allowance',
    note: 'Flat $5 covers the first 250 GB and 1 TB of transfer, then per-GB.',
  },
  {
    id: 'linode',
    label: 'Akamai / Linode',
    signup: 'https://www.linode.com/products/object-storage/',
    endpoint: 'https://{region}.linodeobjects.com',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'e.g. us-east-1, eu-central-1, ap-south-1' }],
    cost: '~$10/mo for 500 GB',
    egress: 'allowance',
    note: 'Like Spaces: a flat tier covering 250 GB and 1 TB of transfer, then per-GB.',
  },
  {
    id: 'aws',
    label: 'Amazon S3',
    signup: 'https://aws.amazon.com/s3/',
    endpoint: 'https://s3.{region}.amazonaws.com',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'e.g. me-central-1, eu-central-1, us-east-1' }],
    cost: '~$11.50/mo for 500 GB, plus downloads',
    egress: 'metered',
    // Named honestly. S3 is what people reach for because it is the name they
    // know; here it is roughly 4× R2 and bills every download on top.
    note: 'Every download billed at ~$0.09/GB on top. Widest region coverage — '
      + 'pick it if your IT requires it, or if you need a region nobody else has.',
  },
  {
    id: 'gcs',
    label: 'Google Cloud Storage',
    signup: 'https://cloud.google.com/storage',
    endpoint: 'https://storage.googleapis.com',
    region: 'auto',
    vars: [],
    cost: '~$10/mo for 500 GB, plus downloads',
    egress: 'metered',
    note: 'Needs an HMAC key from Cloud Storage → Settings → Interoperability, '
      + 'not an ordinary service-account key.',
  },
  {
    id: 'oci',
    label: 'Oracle Cloud (OCI)',
    signup: 'https://www.oracle.com/cloud/free/',
    endpoint: 'https://{namespace}.compat.objectstorage.{region}.oraclecloud.com',
    region: '',
    vars: [
      { key: 'namespace', label: 'Object storage namespace', hint: 'Tenancy details → Object storage namespace' },
      { key: 'region', label: 'Region', hint: 'e.g. me-jeddah-1, eu-frankfurt-1, us-ashburn-1' },
    ],
    cost: '~$12/mo for 500 GB',
    egress: 'allowance',
    note: 'A large monthly egress allowance, and a generous always-free tier.',
  },
  {
    id: 'synology',
    label: 'Synology C2',
    signup: 'https://c2.synology.com/en-global/object-storage/overview',
    endpoint: 'https://{region}.s3.synologyc2.net',
    region: '',
    vars: [{ key: 'region', label: 'Region', hint: 'The left-most part of your C2 endpoint, e.g. eu-003' }],
    cost: '~$3/mo for 500 GB',
    egress: 'free',
    note: 'Worth a look if the shop already runs Synology gear. EU and US regions.',
  },
  {
    id: 'minio',
    label: 'MinIO / NAS (self-hosted)',
    signup: 'https://min.io/download',
    endpoint: 'http://{host}:{port}',
    region: 'us-east-1',
    vars: [
      { key: 'host', label: 'Host or IP', hint: 'e.g. nas.local or 192.168.1.20' },
      { key: 'port', label: 'Port', hint: 'MinIO defaults to 9000' },
    ],
    cost: 'your own hardware',
    egress: 'self',
    // The one entry that is not off-site, and the caveat is load-bearing: a shop
    // that tiers cold models onto the NAS in the same room has moved its files
    // off the laptop, which is the disk problem solved — but it has not made a
    // backup, and a fire takes both.
    note: 'A NAS in the shop (MinIO, TrueNAS, Synology, QNAP). Frees the laptop\'s '
      + 'disk, but it is in the same building — pair it with an off-site copy.',
    selfHosted: true,
  },
  {
    id: 'custom',
    label: 'Other (S3-compatible)',
    endpoint: '',
    region: 'auto',
    vars: [],
    cost: '',
    egress: '',
    note: 'Any provider that speaks S3. Type the endpoint exactly as they give it.',
  },
];

/**
 * Referral / affiliate links, keyed by provider id.
 *
 * Empty on purpose, and shipping empty is the normal state. Several of these
 * providers run a referral programme, and pointing a shop at one is free money
 * for the project and usually a signup credit for the shop — so the slot is
 * here rather than the links being hard to add later. But a referral code is
 * an *account* the project has to hold, not a URL that can be guessed, so none
 * can be invented in a source file.
 *
 * All of them live in this one table rather than beside each provider because
 * whether the app is monetising a link is a property of the build, not of the
 * provider: a reviewer should be able to see every commercial link in the app
 * on one screen instead of grepping fifteen entries for a query string.
 *
 * To add one: enrol with the provider, paste the URL they issue here, and
 * nothing else changes — the UI already discloses a referral link as one
 * wherever it shows it, which is not optional and is why the disclosure lives
 * in the renderer rather than in whatever text a marketing page suggests.
 *
 *   const REFERRALS = { b2: 'https://www.backblaze.com/…?ref=khayt' };
 *
 * @type {Record<string,string>}
 */
const REFERRALS = {};

/**
 * Is this a link the app is willing to hand to the OS browser?
 *
 * The signup URLs above are literals in this file and cannot be hostile. A
 * referral URL is different in kind: it is pasted out of a provider dashboard
 * into a build, which is exactly the sort of string that arrives with a
 * `javascript:` scheme or a set of credentials in it by accident. main.js
 * screens external URLs too (`isAllowedExternalUrl`), so this is the second of
 * two gates rather than the only one — but a link the app *renders* as a
 * signup button and then refuses to open is a dead button, and it is better to
 * fall back to the honest link than to ship one.
 */
function isSafeSignupUrl(url) {
  const u = str(url);
  if (!/^https:\/\/[^\s]+$/i.test(u)) return false;
  try {
    const parsed = new URL(u);
    if (parsed.username || parsed.password) return false;
    return parsed.hostname.includes('.');
  } catch (_) { return false; }
}

/**
 * Where "create an account" should send a shop for a given provider.
 *
 * @param {string} id
 * @returns {{url: string, referral: boolean}|null} null when the provider has
 *   no signup destination at all ('custom'), so the caller draws no link.
 */
function signupLink(id) {
  const p = byId(id);
  if (!p) return null;
  const ref = REFERRALS[p.id];
  if (ref && isSafeSignupUrl(ref)) return { url: ref, referral: true };
  return p.signup ? { url: p.signup, referral: false } : null;
}

/**
 * The table as the renderer sees it, with the signup link already resolved.
 *
 * Resolved here rather than in the renderer so that the referral table stays a
 * main-process concern: the window is handed a URL and a flag saying whether to
 * disclose it, and never a list of the project's affiliate codes.
 */
const list = () => PROVIDERS.map((p) => {
  const link = signupLink(p.id);
  return {
    ...p,
    vars: p.vars.map((v) => ({ ...v })),
    signup: link ? link.url : '',
    signupReferral: !!(link && link.referral),
  };
});

const byId = (id) => PROVIDERS.find((p) => p.id === str(id)) || null;

/**
 * Build a provider's endpoint from the values the shop typed.
 *
 * Reports every missing variable at once rather than the first — a form that
 * complains one field at a time is a form people fill in three times.
 *
 * @param {string} id
 * @param {Record<string,string>} vars
 * @returns {{ok: true, endpoint: string, region: string}
 *          |{ok: false, missing: string[], error: string}}
 */
/**
 * A field that has had the WHOLE ENDPOINT pasted into it.
 *
 * ── THIS IS NOT A HYPOTHETICAL ─────────────────────────────────────────────
 *
 * Backblaze's template is `https://s3.{region}.backblazeb2.com` and the hint on
 * the Region box says "In your bucket's endpoint, e.g. us-west-004". A shop
 * copied the endpoint out of the B2 dashboard — `s3.us-west-001.backblazeb2.com`
 * — and pasted the whole thing into Region, which composed:
 *
 *     https://s3.s3.us-west-001.backblazeb2.com.backblazeb2.com
 *
 * That host does not exist. It was saved with `enabled: true` and sat there,
 * because nothing between the settings page and the first upload ever asks
 * whether the address resolves — and by then the failure is an S3 error in a
 * background job, months after the tab that caused it was closed.
 *
 * The hint already tried to prevent this and did not, so the fix is not a
 * better hint. A value that IS the endpoint is read as one and the variable is
 * taken back out of it, which is unambiguous: it only fires when the pasted
 * value matches this provider's whole template, and the recovered part is by
 * construction what the shop meant.
 *
 * A plain value — `us-west-004`, an R2 account id — has no dot and is never
 * touched.
 */
function varsFromPastedEndpoint(p, vars) {
  const out = { ...vars };
  if (!p.endpoint) return out;
  for (const v of p.vars) {
    const value = str(out[v.key]);
    if (!value.includes('.')) continue;
    const asEndpoint = /^https?:\/\//i.test(value) ? value : `https://${value}`;
    const back = extractVars(p.id, asEndpoint);
    if (back[v.key] && back[v.key] !== value) out[v.key] = back[v.key];
  }
  return out;
}

function resolveEndpoint(id, vars = {}) {
  const p = byId(id);
  if (!p) return { ok: false, missing: [], error: `Unknown storage provider: ${str(id)}` };
  // 'custom', and providers whose endpoint is per-account (IDrive e2), keep
  // whatever the shop typed. Returning '' here instead would silently erase a
  // working endpoint every time any other field on the page was saved.
  if (!p.endpoint) {
    return { ok: true, endpoint: str(vars.endpoint), region: str(vars.region) || p.region || 'auto' };
  }

  const recovered = varsFromPastedEndpoint(p, vars);
  const missing = p.vars.filter((v) => !str(recovered[v.key])).map((v) => v.key);
  if (missing.length) {
    const names = p.vars.filter((v) => missing.includes(v.key)).map((v) => v.label);
    return { ok: false, missing, error: `${p.label} also needs: ${names.join(', ')}.` };
  }

  const endpoint = p.endpoint.replace(/\{(\w+)\}/g, (_m, k) => str(recovered[k]));
  // A provider whose endpoint carries its region must be signed against THAT
  // region. B2 and friends reject 'auto' with a signature error, which reads to
  // the shop as a wrong secret and sends them to re-copy a key that was fine.
  const region = str(recovered.region) || p.region || 'auto';
  return { ok: true, endpoint, region };
}

/**
 * Which preset does an already-saved endpoint correspond to?
 *
 * Without this, opening Settings on a shop that configured its bucket by hand
 * six months ago shows the dropdown parked on the first entry regardless of what
 * the endpoint says — and saving anything else on the page would rewrite a
 * working endpoint into a broken one. Matching on the distinctive host suffix
 * keeps the dropdown honest about what is actually configured.
 *
 * Ordered longest-suffix-first where two could both match.
 *
 * @param {string} endpoint
 * @returns {string} a provider id; 'custom' when nothing matches, '' when empty
 */
const SUFFIXES = [
  ['.r2.cloudflarestorage.com', 'r2'],
  ['.backblazeb2.com', 'b2'],
  ['.wasabisys.com', 'wasabi'],
  ['gateway.storjshare.io', 'storj'],
  ['.your-objectstorage.com', 'hetzner'],
  ['.scw.cloud', 'scaleway'],
  ['.io.cloud.ovh.net', 'ovh'],
  ['.digitaloceanspaces.com', 'do'],
  ['.linodeobjects.com', 'linode'],
  ['.oraclecloud.com', 'oci'],
  ['.s3.synologyc2.net', 'synology'],
  ['storage.googleapis.com', 'gcs'],
  ['.amazonaws.com', 'aws'],
];

/**
 * e2 gets a pattern rather than a suffix: the domain itself carries a varying
 * numeric suffix (idrivee2-75.com, idrivee2-61.com) and a plain endsWith would
 * miss every account but the ones on the unnumbered domain.
 */
const IDRIVE_HOST = /(^|\.)idrivee2(-\d+)?\.com$/i;

function detect(endpoint) {
  const host = str(endpoint).replace(/^https?:\/\//, '').split('/')[0].toLowerCase();
  if (!host) return '';
  const bare = host.split(':')[0];
  for (const [suffix, id] of SUFFIXES) if (bare.endsWith(suffix)) return id;
  if (IDRIVE_HOST.test(bare)) return 'idrive';
  // A bare host or an IP with a port is overwhelmingly a NAS or a MinIO box, and
  // calling that 'custom' would hide the one caveat worth showing about it.
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(bare) || bare.endsWith('.local') || !bare.includes('.')) return 'minio';
  return 'custom';
}

/**
 * Pull the variable values back out of a saved endpoint, so re-opening Settings
 * shows the account id that is in use rather than an empty box that would
 * overwrite it on save.
 *
 * @param {string} id
 * @param {string} endpoint
 * @returns {Record<string,string>}
 */
function extractVars(id, endpoint) {
  const p = byId(id);
  const out = {};
  if (!p || !p.endpoint) return out;
  const pattern = p.endpoint
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')          // literal-escape first…
    .replace(/\\\{(\w+)\\\}/g, '(?<$1>[^./:]+)');    // …then re-open the placeholders
  const m = new RegExp(`^${pattern}$`, 'i').exec(str(endpoint));
  if (!m || !m.groups) return out;
  for (const [k, v] of Object.entries(m.groups)) if (v) out[k] = v;
  return out;
}

/**
 * Heal a config that was SAVED before the recovery above existed.
 *
 * `varsFromPastedEndpoint` runs when the settings page is saved, so it repairs
 * the shop that pastes an endpoint into Region from now on. It does nothing for
 * the shop that already did it: that book holds
 *
 *     endpoint: 'https://s3.s3.us-west-001.backblazeb2.com.backblazeb2.com'
 *     region:   's3.us-west-001.backblazeb2.com'
 *
 * with `enabled: true`, and nothing will touch it again until somebody opens
 * that settings tab and presses Save — which nobody does, because from the
 * shop's side the library simply never syncs and there is no error on any
 * screen to send them there.
 *
 * So the endpoint is repaired where it is READ instead of only where it is
 * written. Recomposing from the provider and the recovered variable gives the
 * address the shop meant; a config that already resolves is returned unchanged,
 * and one this cannot make sense of is left exactly as it is rather than
 * replaced with a guess.
 *
 * @param {{provider?: string, endpoint?: string, region?: string}} cfg
 * @returns {object} the same shape, with a working endpoint where one is knowable
 */
function repair(cfg) {
  if (!cfg || typeof cfg !== 'object') return cfg;
  const endpoint = str(cfg.endpoint);
  // The stored provider first; a book written before that field existed still
  // has the host, and `detect` matches on the suffix, which survives the
  // doubling that broke the address in the first place.
  const id = str(cfg.provider) || detect(endpoint);
  const p = byId(id);
  if (!p || !p.endpoint) return cfg;

  // Already the address this provider composes? Then there is nothing to heal,
  // and re-deriving it would be a chance to get it wrong.
  const vars = extractVars(p.id, endpoint);
  if (p.vars.every((v) => vars[v.key])) return cfg;

  const r = resolveEndpoint(p.id, { ...vars, region: str(cfg.region), endpoint });
  if (!r.ok || !r.endpoint || r.endpoint === endpoint) return cfg;
  return { ...cfg, endpoint: r.endpoint, region: r.region || str(cfg.region) };
}

const api = {
  PROVIDERS, PRICED_ON, REFERRALS, list, byId,
  resolveEndpoint, detect, extractVars, signupLink, isSafeSignupUrl, repair,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytStorageProviders = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
