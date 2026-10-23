'use strict';
/**
 * A WhatsApp update to a customer: the number, the words, and the link.
 *
 * Saudi customers expect WhatsApp, not email. Khayt already knew how to write
 * a customer an email when a job moves (`lib/order-email.js`) and how to fill
 * one of the shop's own saved messages (`lib/wa-template.js`). What it did not
 * know was the three things that decide whether a WhatsApp message reaches
 * anybody at all:
 *
 *   1. THE NUMBER. Shops type phone numbers the way customers say them —
 *      `05x xxx xxxx`, `9665…`, `+966 5…`, sometimes in Arabic-Indic digits.
 *      `wa.me` takes one shape only: the international number, digits only.
 *      A local `05…` number handed to it opens WhatsApp on a chat with nobody,
 *      which looks like the feature not working. So the number is normalised
 *      here, once, and refused out loud when it cannot be.
 *   2. THE MILESTONE. Which update a job is due: received, ready, shipped or
 *      delivered. Read from the job the way the board reads it — shipped and
 *      delivered are date stamps on a `completed` job, not statuses.
 *   3. THE LANGUAGE. The customer's, not the shop's screen language. A shop
 *      working in English still writes to most of its customers in Arabic.
 *
 * TWO WAYS OUT. With no account, this builds a
 * `https://wa.me/<number>?text=<message>` link; the host opens it and a person
 * presses send in WhatsApp. A shop that connects its own WhatsApp Business
 * account can have the update SENT instead, with a template Meta approved —
 * `wouldSend` below decides when, and `lib/whatsapp-send.js` builds the
 * request (docs/handoffs/whatsapp-business-api.md).
 *
 * PURE: no clock, no DOM, no network, no randomness. The host passes the
 * moment and the id when it wants a log line, and passes money and dates
 * already formatted — what a price looks like is each app's own answer (the
 * same split `wa-template.js` makes).
 */
(function (global) {

  const tplApi = () =>
    global.KhaytWaTemplate ||
    (typeof require === 'function' ? require('./wa-template.js') : null);

  // ── MILESTONES ────────────────────────────────────────────────────────────

  /** The customer-facing moments, in the order a job passes them. */
  const MILESTONES = ['received', 'ready', 'shipped', 'delivered'];

  /** The languages a customer message is written in. */
  const LANGS = ['ar', 'en'];

  /**
   * Statuses that are not a customer's order in progress. A quote has not
   * been accepted, a cancelled job is not coming, and a split parent has been
   * replaced by the sub-orders that carry its work.
   */
  const NOT_AN_ORDER = ['quote', 'cancelled', 'split'];

  /**
   * Which update this job is due now, or null when it owes the customer none.
   *
   * Mirrors `KhaytOrderStatus.stageOf`: delivered is asked before shipped,
   * because a parcel that has arrived was also posted. `delivered` as a STATUS
   * is legacy data from before it became a date stamp, and still means
   * delivered.
   */
  function milestoneOf(order) {
    if (!order || typeof order !== 'object') return null;
    if (order.voidedAt) return null;
    const status = String(order.status || '');
    if (!status || NOT_AN_ORDER.indexOf(status) !== -1) return null;
    if (status === 'delivered') return 'delivered';
    if (status === 'completed') {
      if (order.deliveredAt) return 'delivered';
      if (order.shippedAt) return 'shipped';
      return 'ready';
    }
    return 'received';
  }

  // ── THE NUMBER ────────────────────────────────────────────────────────────

  /** Arabic-Indic (U+0660…) and Extended Arabic-Indic (U+06F0…) digits → ASCII. */
  function westernDigits(s) {
    return String(s).replace(/[٠-٩۰-۹]/g, (d) => {
      const c = d.charCodeAt(0);
      return String(c >= 0x06F0 ? c - 0x06F0 : c - 0x0660);
    });
  }

  /** Saudi Arabia's calling code, and the length of a number after it. */
  const SA = '966';
  const SA_NATIONAL = 9;

  /**
   * One number, or a refusal that says why.
   *
   * Returns `{ ok, e164, digits, reason }`:
   *   `e164`   `+9665XXXXXXXX` — for showing to a person
   *   `digits` `9665XXXXXXXX` — what `wa.me` takes
   *   `reason` when not ok: `empty`, `no_country_code`, `too_short`,
   *            `too_long`, `bad_saudi_number`
   *
   * Understood forms:
   *   `+966 5X XXX XXXX`, `00966 5X…`, `9665XXXXXXXX`   international
   *   `+966 05X…`, `009660 5X…`                          the stray trunk 0
   *   `05X XXX XXXX`, `5X XXX XXXX`                       Saudi local
   *   `011 XXX XXXX`                                      Saudi landline
   *   `+971 5…`, `0044 7…`                                any other country,
   *                                                        WITH its code
   *
   * A local number that is not Saudi-shaped is refused rather than guessed:
   * `0712345678` could be anywhere, and a message about somebody's order
   * delivered to a stranger is worse than one not sent.
   *
   * A field holding two numbers — `0501234567 / 0559876543` — gives the first
   * one that works, instead of gluing them into one long wrong number.
   */
  function normalizePhone(raw) {
    const text = westernDigits(raw == null ? '' : raw).trim();
    if (!text) return refuse('empty');
    const pieces = text.split(/[\/,;|\n]|\bor\b|أو/).map((p) => p.trim()).filter(Boolean);
    let first = null;
    for (const piece of pieces) {
      const out = normalizeOne(piece);
      if (out.ok) return out;
      if (!first) first = out;
    }
    return first || refuse('empty');
  }

  function refuse(reason) {
    return { ok: false, e164: '', digits: '', reason };
  }

  function accept(digits) {
    return { ok: true, e164: '+' + digits, digits, reason: '' };
  }

  function normalizeOne(piece) {
    // An extension is not dialled by WhatsApp; drop it before counting.
    const s = piece.replace(/\s*(ext\.?|x|#)\s*\d+\s*$/i, '');
    let intl = false;
    let digits;
    if (/^\s*\+/.test(s)) {
      intl = true;
      digits = s.replace(/\D/g, '');
    } else {
      digits = s.replace(/\D/g, '');
      if (digits.indexOf('00') === 0) { intl = true; digits = digits.slice(2); }
    }
    if (!digits) return refuse('empty');

    if (!intl) {
      // Saudi without the plus: 9665XXXXXXXX, or 9660 5XXXXXXXX.
      if (digits.indexOf(SA) === 0 && digits.length >= SA.length + SA_NATIONAL) {
        return saudi(digits.slice(SA.length));
      }
      // Saudi local: 05XXXXXXXX / 011XXXXXXX, or the mobile without its 0.
      if (digits[0] === '0' && digits.length === SA_NATIONAL + 1) return saudi(digits.slice(1));
      if (digits[0] === '5' && digits.length === SA_NATIONAL) return saudi(digits);
      if (digits.length < 8) return refuse('too_short');
      return refuse('no_country_code');
    }

    if (digits.indexOf(SA) === 0) return saudi(digits.slice(SA.length));
    if (digits.length < 8) return refuse('too_short');
    if (digits.length > 15) return refuse('too_long');
    return accept(digits);
  }

  /** The part after 966, with a stray trunk 0 forgiven. */
  function saudi(national) {
    let n = national;
    if (n.length === SA_NATIONAL + 1 && n[0] === '0') n = n.slice(1);
    if (n.length < SA_NATIONAL) return refuse('too_short');
    if (n.length > SA_NATIONAL) return refuse('too_long');
    // Mobiles start with 5; landlines with an area digit. 0, 8 and 9 start
    // no Saudi subscriber number (800 and 9200 are toll-free and unified
    // numbers, which have no WhatsApp).
    if (!/^[1-7]/.test(n)) return refuse('bad_saudi_number');
    return accept(SA + n);
  }

  /**
   * The link that opens WhatsApp on this number with this message typed in.
   *
   * `encodeURIComponent`, not a query-string builder: a `+` left as itself is
   * read as a space by `wa.me`, and `&` would end the message early. An empty
   * message opens the chat with nothing typed.
   */
  function waLink(digits, text) {
    const d = String(digits || '').replace(/\D/g, '');
    const base = 'https://wa.me/' + d;
    const t = text == null ? '' : String(text);
    return t ? base + '?text=' + encodeURIComponent(t) : base;
  }

  /** Normalise and link in one step; `{ ok, reason, e164, digits, link }`. */
  function chatLink(rawPhone, text) {
    const p = normalizePhone(rawPhone);
    return {
      ok: p.ok, reason: p.reason, e164: p.e164, digits: p.digits,
      link: p.ok ? waLink(p.digits, text) : '',
    };
  }

  // ── THE LANGUAGE ──────────────────────────────────────────────────────────

  /**
   * The language to write to this customer in.
   *
   * The customer's own `messageLang` when the shop set one. Otherwise the
   * names say it: a customer written down only in Arabic is written to in
   * Arabic, one written down only in English in English. Otherwise the shop's
   * language when it is one of the two, and Arabic — this is a Saudi shop's
   * feature — when it is not.
   */
  function customerLanguage(client, shopLang) {
    const c = client || {};
    const set = String(c.messageLang || '');
    if (LANGS.indexOf(set) !== -1) return set;
    const ar = String(c.nameAr || '').trim();
    const en = String(c.nameEn || '').trim();
    if (ar && !en) return 'ar';
    if (en && !ar) return 'en';
    return shopLang === 'en' ? 'en' : 'ar';
  }

  // ── THE WORDS ─────────────────────────────────────────────────────────────

  /**
   * What each milestone says when the shop has not written its own.
   *
   * These are the starting point, not the rule: a shop saves a template with
   * the same `milestone` and `lang` and that is what goes out instead.
   */
  const DEFAULT_BODIES = {
    received: {
      en: 'Hi {{client}}, thank you for your order with {{shop}}. We have received order {{id}} and will let you know as soon as it is ready.',
      ar: 'مرحباً {{client}}، شكراً لطلبك من {{shop}}. استلمنا طلبك رقم {{id}} وسنبلغك فور جاهزيته.',
    },
    ready: {
      en: 'Hi {{client}}, good news: your order {{id}} is ready. Reply here to arrange pickup or delivery.\n— {{shop}}',
      ar: 'مرحباً {{client}}، يسعدنا إبلاغك أن طلبك رقم {{id}} جاهز. راسلنا هنا لترتيب الاستلام أو التوصيل.\n— {{shop}}',
    },
    shipped: {
      en: 'Hi {{client}}, your order {{id}} is on its way.\nCarrier: {{carrier}}\nTracking number: {{tracking}}\n— {{shop}}',
      ar: 'مرحباً {{client}}، تم شحن طلبك رقم {{id}}.\nشركة الشحن: {{carrier}}\nرقم التتبع: {{tracking}}\n— {{shop}}',
    },
    delivered: {
      en: 'Hi {{client}}, your order {{id}} has been delivered. Thank you for choosing {{shop}}, we hope you love it!',
      ar: 'مرحباً {{client}}، تم تسليم طلبك رقم {{id}}. شكراً لاختيارك {{shop}}، نتمنى أن ينال إعجابك!',
    },
  };

  /** A stage in the customer's words, for a shop template that says `{{status}}`. */
  const STATUS_WORDS = {
    en: {
      pending: 'received', printing: 'being printed', post: 'being finished',
      on_hold: 'on hold', completed: 'ready', shipped: 'on its way', delivered: 'delivered',
    },
    ar: {
      pending: 'مستلم', printing: 'قيد الطباعة', post: 'في مرحلة التشطيب',
      on_hold: 'متوقف مؤقتاً', completed: 'جاهز', shipped: 'في الطريق إليك', delivered: 'تم التسليم',
    },
  };

  /** Carrier ids as a customer knows them. Brand names are not translated. */
  const CARRIER_NAMES = { smsa: 'SMSA', aramex: 'Aramex', spl: 'SPL', dhl: 'DHL', fedex: 'FedEx', ups: 'UPS' };

  function defaultBody(milestone, lang) {
    const m = DEFAULT_BODIES[milestone];
    if (!m) return '';
    return m[lang] || m.en;
  }

  /**
   * The shop's template for this milestone in this language, or the default.
   *
   * A template for the milestone in THIS language wins; one for the milestone
   * with no language set is the shop's words for every customer; otherwise
   * the default above. Returns `{ id, body, isDefault }` — `id` null for the
   * default.
   */
  function templateFor(templates, milestone, lang) {
    const rows = (Array.isArray(templates) ? templates : [])
      .filter((t) => t && typeof t.body === 'string' && t.body.trim() && t.milestone === milestone);
    const exact = rows.find((t) => t.lang === lang);
    const any = rows.find((t) => !t.lang);
    const pick = exact || any;
    if (pick) return { id: String(pick.id || ''), body: pick.body, isDefault: false };
    return { id: null, body: defaultBody(milestone, lang), isDefault: true };
  }

  /**
   * A line about a tracking number with no number in it is a line the
   * customer cannot use — "Tracking number: " and nothing after it. So a line
   * that names `{{tracking}}` or `{{carrier}}` is left out when that value is
   * empty, rather than printed with a hole in it.
   */
  function dropEmptyLines(body, values) {
    const optional = ['tracking', 'carrier'];
    return String(body).split('\n').filter((line) =>
      !optional.some((k) => line.indexOf('{{' + k + '}}') !== -1 && !String(values[k] || '').trim())
    ).join('\n');
  }

  const langApi = () =>
    global.KhaytContentLanguages ||
    (typeof require === 'function' ? require('./content-languages.js') : null);

  /**
   * A record's `<base>En` / `<base>Ar` / `<base>Tr`… field in the CUSTOMER's
   * language, falling back to whatever is filled in — `KhaytContentLanguages`,
   * not a hand-written English/Arabic pair, so a shop that writes its name
   * only in Turkish still signs its messages. No settings are passed on
   * purpose: the customer's language goes first whichever languages the shop
   * writes in, because the message is for the customer.
   */
  function nameIn(record, base, lang) {
    const CL = langApi();
    if (!CL) throw new Error('whatsapp-message: lib/content-languages.js is not loaded');
    return String(CL.read(record || {}, base, lang, null) || '').trim();
  }

  /**
   * The text of an update, with no number involved.
   *
   * `ctx`: `{ order, client, settings, templates, milestone, lang, values }`.
   * `values` carries what only the host can format: `price`, `currency`,
   * `due`. Anything else it passes overrides what is worked out here.
   */
  function messageText(ctx) {
    const c = ctx || {};
    const tpl = tplApi();
    if (!tpl) throw new Error('whatsapp-message: lib/wa-template.js is not loaded');
    const lang = LANGS.indexOf(c.lang) !== -1 ? c.lang : 'ar';
    const chosen = templateFor(c.templates, c.milestone, lang);
    const values = valuesFor(Object.assign({}, c, { lang }));
    const text = tpl.fillTemplate(dropEmptyLines(chosen.body, values), values);
    return { text, templateId: chosen.id, isDefault: chosen.isDefault };
  }

  /**
   * The named values an update is filled from — the customer's name and the
   * shop's in the customer's language, the job id, the carrier and tracking
   * number, the stage in the customer's words — with `ctx.values` laid over.
   * ONE set, for the shop's own words above and for an approved template's
   * parameters below, so the two kinds of message cannot name a customer two
   * ways.
   */
  function valuesFor(ctx) {
    const c = ctx || {};
    const o = c.order || {};
    const lang = LANGS.indexOf(c.lang) !== -1 ? c.lang : 'ar';
    const milestone = c.milestone;
    const stage = milestone === 'shipped' || milestone === 'delivered' ? milestone : String(o.status || '');
    const carrierId = String(o.carrier || '').toLowerCase();
    return Object.assign({
      client: nameIn(c.client || {}, 'name', lang) || String(o.client || ''),
      id: String(o.id || ''),
      shop: nameIn(c.settings || {}, 'biz', lang),
      tracking: String(o.trackingNumber || ''),
      carrier: carrierId === 'manual' ? '' : (CARRIER_NAMES[carrierId] || String(o.carrier || '')),
      status: (STATUS_WORDS[lang] || STATUS_WORDS.en)[stage] || '',
    }, c.values || {});
  }

  /**
   * Everything a host needs to offer "Send on WhatsApp" for one job.
   *
   * `ctx`: `{ order, client, settings, templates, milestone?, lang?,
   *           shopLang?, values? }`. `milestone` defaults to where the job is
   * now, `lang` to the customer's language.
   *
   * Returns `{ ok, reason, milestone, lang, text, templateId, isDefault,
   *            e164, digits, link }`.
   *
   * The TEXT comes back even when the number is unusable, so a shop can still
   * read and copy it. `ok` is whether it can be opened in WhatsApp; `reason`
   * says why not: `no_milestone`, `no_customer`, `no_phone`, or one of
   * `normalizePhone`'s reasons.
   */
  function buildUpdate(ctx) {
    const c = ctx || {};
    const milestone = MILESTONES.indexOf(c.milestone) !== -1 ? c.milestone : milestoneOf(c.order);
    const lang = LANGS.indexOf(c.lang) !== -1 ? c.lang : customerLanguage(c.client, c.shopLang);
    const base = {
      ok: false, reason: '', milestone: milestone || '', lang, text: '',
      templateId: null, isDefault: true, e164: '', digits: '', link: '',
    };
    if (!milestone) return Object.assign(base, { reason: 'no_milestone' });
    const msg = messageText(Object.assign({}, c, { milestone, lang }));
    Object.assign(base, { text: msg.text, templateId: msg.templateId, isDefault: msg.isDefault });
    if (!c.client) return Object.assign(base, { reason: 'no_customer' });
    if (!String(c.client.phone || '').trim()) return Object.assign(base, { reason: 'no_phone' });
    const chat = chatLink(c.client.phone, msg.text);
    if (!chat.ok) return Object.assign(base, { reason: chat.reason });
    return Object.assign(base, { ok: true, e164: chat.e164, digits: chat.digits, link: chat.link });
  }

  // ── SENT FOR THE SHOP: WHATSAPP BUSINESS ─────────────────────────────────
  //
  // Everything above opens WhatsApp and a person presses send. A shop that
  // connects its own WhatsApp Business account (Meta's Cloud API) can have the
  // update sent for it instead — with a TEMPLATE Meta has approved, because a
  // business may not open a conversation with free text (`lib/whatsapp-send.js`
  // says why). The template's words live in the shop's WhatsApp Manager; what
  // Khayt sends is its name, its language and its parameters, in an order
  // fixed here so a shop knows what {{1}}, {{2}}… will be when it writes one.
  //
  // `settings.smsConfig` is the account, the shape the other app's SMS settings
  // already write (`provider: 'whatsapp_cloud'`, `phoneNumberId`, `token` —
  // the token a registered secret in `store-secret-paths.js`, sealed on disk
  // and masked before a book goes to a phone). `settings.whatsappTemplates` is
  // which approved template each milestone sends:
  //
  //   { ready: { name: 'order_ready', langs: ['ar', 'en'] }, … }
  //
  // A milestone with no template is one the shop has not asked to have sent,
  // which is how a shop sends "shipped" automatically and nothing else.

  /** The body parameters each milestone's template is given, in order. */
  const TEMPLATE_PARAMS = {
    received: ['client', 'id', 'shop'],
    ready: ['client', 'id', 'shop'],
    shipped: ['client', 'id', 'carrier', 'tracking', 'shop'],
    delivered: ['client', 'id', 'shop'],
  };

  /** The template names the settings suggest. A shop may call them anything. */
  const SUGGESTED_TEMPLATES = {
    received: 'order_received', ready: 'order_ready',
    shipped: 'order_shipped', delivered: 'order_delivered',
  };

  /**
   * A milestone's template parameters, in `TEMPLATE_PARAMS` order, from the
   * values `valuesFor` works out. An empty value is sent as `-`: Meta refuses a
   * message with an empty parameter, and a parcel handed over without a
   * tracking number is still worth telling the customer about.
   */
  function templateParams(milestone, values) {
    const keys = TEMPLATE_PARAMS[milestone] || [];
    const v = values || {};
    return keys.map((k) => {
      const s = String(v[k] == null ? '' : v[k]).trim();
      return s || '-';
    });
  }

  const sendApi = () =>
    global.KhaytWhatsappSend ||
    (typeof require === 'function' ? require('./whatsapp-send.js') : null);

  /**
   * The shop's WhatsApp Business account as stored, or why there is none.
   * `{ ok, phoneNumberId, token, reason }`, `reason` one of `not_set_up`,
   * `no_phone_number_id`, `no_token`. The token is returned as STORED — the
   * host opens a sealed one at the point of use, as it does every secret.
   */
  function cloudAccount(settings) {
    const cfg = ((settings || {}).smsConfig) || {};
    const out = { ok: false, phoneNumberId: '', token: '', reason: '' };
    if (cfg.provider !== 'whatsapp_cloud') return Object.assign(out, { reason: 'not_set_up' });
    const id = String(cfg.phoneNumberId || '').trim();
    const token = String(cfg.token || '').trim();
    if (!id) return Object.assign(out, { reason: 'no_phone_number_id' });
    if (!token) return Object.assign(out, { reason: 'no_token' });
    return { ok: true, phoneNumberId: id, token, reason: '' };
  }

  /**
   * The approved template for this milestone, in the language nearest the
   * customer's: `{ name, language }`, or null when the shop has not given the
   * milestone one. `langs` are Meta's codes (`ar`, `en`, `en_US`) in the order
   * the shop listed them; the first whose language is the customer's wins,
   * else the first — a template approved only in Arabic still tells an
   * English-speaking customer their parcel left.
   */
  function cloudTemplate(settings, milestone, lang) {
    const map = ((settings || {}).whatsappTemplates) || {};
    const t = map[milestone];
    const S = sendApi();
    if (!t || !S || !S.isTemplateName(String(t.name || '').trim())) return null;
    const langs = (Array.isArray(t.langs) ? t.langs : [])
      .map((x) => String(x || '').trim()).filter((x) => S.isLanguage(x));
    if (!langs.length) return null;
    const near = langs.find((x) => x.split('_')[0] === lang);
    return { name: String(t.name).trim(), language: near || langs[0] };
  }

  /**
   * Whether the customer agreed to order updates on WhatsApp.
   *
   * Its OWN field, apart from `marketingOptOut`: agreeing to hear that your
   * order shipped is not agreeing to offers, and opting out of offers is not
   * opting out of your order. `whatsappOptIn: { at, how }` — when, and how it
   * was given (`asked`, `form`, `customer_wrote`, `other`) — so a shop asked
   * by Meta can say. Removing the field is withdrawing it.
   */
  const OPT_IN_HOW = ['asked', 'form', 'customer_wrote', 'other'];
  function optedIn(client) {
    const o = client && client.whatsappOptIn;
    return !!(o && typeof o === 'object' && String(o.at || '').trim());
  }

  function orderIndex(m) { return m ? MILESTONES.indexOf(m) : -1; }

  /**
   * Whether this change to a job is sent to its customer through the shop's
   * WhatsApp Business account, and with what.
   *
   * `before`/`after` are the job as it was and as it now is — a status move,
   * or a shipment or handover stamped on a finished job. Only a step FORWARD
   * into a milestone sends: a job moved back from shipped to finished is not
   * news, and a job edited without moving is not either.
   *
   * `ctx`: `{ settings, clients, shopLang }`.
   *
   * Returns `{ send, reason, milestone, lang, template, to, clientId }`.
   * `send` false is ordinary and silent for every reason but the last few:
   *   `no_change` `not_set_up` `no_phone_number_id` `no_token` `no_template`
   *   `no_customer` `not_opted_in` `already_sent` — nothing owed, nobody missed;
   *   `no_phone` or a `normalizePhone` reason — the customer agreed and cannot
   *   be reached, which a host should SAY, so the shop can fix the number.
   */
  function wouldSend(before, after, ctx) {
    const c = ctx || {};
    const settings = c.settings || {};
    const out = { send: false, reason: '', milestone: '', lang: '', template: null, to: '', clientId: '' };
    const now = milestoneOf(after);
    if (!now || orderIndex(now) <= orderIndex(milestoneOf(before))) return Object.assign(out, { reason: 'no_change' });
    out.milestone = now;
    const account = cloudAccount(settings);
    if (!account.ok) return Object.assign(out, { reason: account.reason });
    const o = after || {};
    const clients = Array.isArray(c.clients) ? c.clients : [];
    const client = o.clientId ? clients.find((x) => x && x.id === o.clientId) : null;
    if (!client) return Object.assign(out, { reason: 'no_customer' });
    out.clientId = String(client.id);
    out.lang = customerLanguage(client, c.shopLang);
    out.template = cloudTemplate(settings, now, out.lang);
    if (!out.template) return Object.assign(out, { reason: 'no_template' });
    if (!optedIn(client)) return Object.assign(out, { reason: 'not_opted_in' });
    if (sentAt(client.commLog, String(o.id || ''), now)) return Object.assign(out, { reason: 'already_sent' });
    if (!String(client.phone || '').trim()) return Object.assign(out, { reason: 'no_phone' });
    const phone = normalizePhone(client.phone);
    if (!phone.ok) return Object.assign(out, { reason: phone.reason });
    return Object.assign(out, { send: true, to: phone.digits });
  }

  /** The reasons `wouldSend` gives that a host should tell the shop about. */
  function isUnreachable(reason) {
    return ['', 'no_change', 'not_set_up', 'no_phone_number_id', 'no_token', 'no_template',
      'no_customer', 'not_opted_in', 'already_sent'].indexOf(String(reason || '')) === -1;
  }

  /**
   * Whether a job's update for a milestone could be sent for the shop right
   * now, asked by a button rather than a move: the same answer as
   * `wouldSend`, with the job's own milestone and no step required.
   */
  function canSendNow(order, ctx) {
    if (!milestoneOf(order)) return Object.assign(wouldSend(order, order, ctx), { reason: 'no_milestone' });
    return wouldSend(null, order, ctx);
  }

  /**
   * Everything the host sends: `wouldSend`'s answer plus `params`, worked
   * out from the same values the shop's own words use. `ctx` is `wouldSend`'s
   * plus `values` (what only the host formats) and `now: true` for a send a
   * person asked for (`canSendNow`) rather than one a change owes. `params`
   * is empty when `send` is false.
   */
  function cloudMessage(before, after, ctx) {
    const c = ctx || {};
    const ws = c.now ? canSendNow(after, c) : wouldSend(before, after, c);
    if (!ws.send) return Object.assign({}, ws, { params: [] });
    const client = (c.clients || []).find((x) => x && x.id === ws.clientId);
    const values = valuesFor({
      order: after, client, settings: c.settings, lang: ws.lang, milestone: ws.milestone, values: c.values,
    });
    return Object.assign({}, ws, { params: templateParams(ws.milestone, values) });
  }

  // ── THE LOG ───────────────────────────────────────────────────────────────

  /**
   * The line written to the customer's communications log.
   *
   * The shape the other app's customer editor writes — `{ id, type, note,
   * at }` with `type: 'whatsapp'` — so both apps list it, plus what this
   * feature reads back: which job and which milestone, so the job can stop
   * offering an update it has already sent.
   *
   * `opts`: `{ id, at, text, orderId?, milestone?, lang?, messageId?,
   * template? }`. The note is the
   * message itself — what the customer was sent is the useful thing to find
   * later.
   */
  function commEntry(opts) {
    const o = opts || {};
    const out = { id: String(o.id || ''), type: 'whatsapp', note: String(o.text || ''), at: String(o.at || '') };
    if (o.orderId) out.orderId = String(o.orderId);
    if (MILESTONES.indexOf(o.milestone) !== -1) out.milestone = o.milestone;
    if (LANGS.indexOf(o.lang) !== -1) out.lang = o.lang;
    // Sent for the shop rather than opened for a person: the id Meta's
    // delivery reports name (`lib/whatsapp-status.js` matches on it), the
    // first status, and the template that carried it.
    const mid = String(o.messageId || '').trim();
    if (mid) {
      out.messageId = mid;
      out.status = 'sent';
      out.via = 'whatsapp_cloud';
      if (o.template) out.template = String(o.template);
    }
    return out;
  }

  /**
   * When this job's update for this milestone was last opened in WhatsApp,
   * or null. The newest `at` among matching lines.
   */
  function sentAt(commLog, orderId, milestone) {
    const log = Array.isArray(commLog) ? commLog : [];
    let best = null;
    for (const e of log) {
      if (!e || e.orderId !== orderId || e.milestone !== milestone) continue;
      const kind = e.type || e.channel;
      if (kind !== 'whatsapp' && kind !== 'wa') continue;
      const at = String(e.at || '');
      if (!best || at > best) best = at;
    }
    return best;
  }

  const api = {
    MILESTONES, LANGS, DEFAULT_BODIES, STATUS_WORDS, CARRIER_NAMES,
    milestoneOf, westernDigits, normalizePhone, waLink, chatLink,
    customerLanguage, defaultBody, templateFor, messageText, valuesFor, buildUpdate,
    commEntry, sentAt,
    TEMPLATE_PARAMS, SUGGESTED_TEMPLATES, OPT_IN_HOW, templateParams, cloudAccount,
    cloudTemplate, optedIn, wouldSend, isUnreachable, canSendNow, cloudMessage,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWhatsappMessage = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
