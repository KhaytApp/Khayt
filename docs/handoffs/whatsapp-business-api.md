# Handoff: sending WhatsApp updates automatically (WhatsApp Business API)

**Status:** not built. This note says what it would take.
**What is built:** the no-account version (Mac, branch `mac-whatsapp-updates`).

## What exists today

When a job reaches a milestone the customer cares about, the Mac offers
**Send on WhatsApp**:

| Milestone   | When                                                  |
|-------------|-------------------------------------------------------|
| `received`  | any live order (`pending`, `printing`, `post`, `on_hold`, …) |
| `ready`     | `status: completed`, no `shippedAt`                   |
| `shipped`   | `completed` + `shippedAt` (carrier and tracking number go in the message) |
| `delivered` | `completed` + `deliveredAt`, or the legacy `status: delivered` |

The button opens `https://wa.me/<E.164 digits>?text=<message>` with
`NSWorkspace`. A person presses send in WhatsApp. Opening it writes a line to
the customer's `commLog`:
`{ id, type: 'whatsapp', note: <message>, at, orderId, milestone, lang }`.

The rules live in `lib/whatsapp-message.js`, a pure module with Node tests
(`test/whatsapp-message.test.js`):

- `normalizePhone(raw)`: Saudi local and international forms, Arabic-Indic
  digits, two numbers in one field. It gives E.164 or a reason (`empty`,
  `no_country_code`, `too_short`, `too_long`, `bad_saudi_number`).
- `milestoneOf(order)`: which update a job is due.
- `customerLanguage(client, shopLang)`: `client.messageLang` (`ar` / `en`)
  first. Then the names: Arabic only gives `ar`, English only gives `en`.
  Then the shop's language.
- `templateFor(templates, milestone, lang)`: the shop's `waTemplates` row with
  a matching `milestone` and `lang`, then one with that `milestone` and no
  `lang`, then Khayt's default words (`DEFAULT_BODIES`, Arabic and English).
- `buildUpdate(ctx)`, `commEntry(opts)`, `sentAt(commLog, orderId, milestone)`.

An automatic sender should reuse all of these. The only new piece is the
transport.

## Why the no-account version cannot simply be automated

WhatsApp does not let a business start a conversation with free text. A
**business-initiated** message is one sent outside the 24-hour window that
opens when the customer last wrote to you. It must use a **message template
that Meta has approved in advance**. Free text (`type: text`) only works
inside that 24-hour window.

Most of these updates are business-initiated. "Your order is ready" usually
goes out days after the customer last wrote. So automatic sending needs:

1. A WhatsApp Business Account (WABA), a verified Meta Business, and a phone
   number registered to the API. **That number can no longer be used in the
   WhatsApp app on a phone** unless the provider supports "coexistence".
2. **One approved template per milestone per language.** Category `UTILITY`:
   order updates are utility, not marketing, and are cheaper. The body uses
   numbered parameters, for example:
   - `order_ready` / `ar`: `مرحباً {{1}}، طلبك رقم {{2}} جاهز. راسلنا هنا لترتيب الاستلام أو التوصيل. — {{3}}`
   - `order_shipped` / `en`: `Hi {{1}}, your order {{2}} is on its way. Carrier: {{3}}. Tracking number: {{4}}. — {{5}}`

   Approval takes minutes to a day. A template Meta rejects or pauses (for
   example after a lot of customers block the number) stops sending with
   no warning, so the sender must handle a `template paused` or
   `template not found` error.
3. **Opt-in.** WhatsApp policy requires the customer to have agreed to receive
   messages. Khayt has `marketingOptOut` for campaigns. Order updates would
   need a separate `whatsappOptIn`, recorded when and how it was given, for
   example on the intake form.
4. **Shop-edited words cannot be sent as they are.** A shop's own
   `waTemplates` body is free text. Automatic sending can only fill the
   parameters of an approved template. So either the shop submits its
   wording to Meta through the provider (and Khayt stores the approved
   template name), or automatic sending uses Khayt's fixed approved templates
   and the shop's own words stay on the manual button.

## Providers that work in Saudi Arabia

| Provider | What it is | Notes for KSA |
|---|---|---|
| **Meta WhatsApp Cloud API** | Meta's own hosted API: `POST https://graph.facebook.com/v21.0/<phone-number-id>/messages` with a Bearer token | No middleman fee; Meta's per-message template price applies (Saudi Arabia has its own rate card, and utility templates are cheaper than marketing). You manage templates in WhatsApp Manager. Data is processed by Meta outside KSA. |
| **Unifonic** | Riyadh-based CPaaS, a Meta Business Solution Provider | Arabic support and local billing in SAR. Popular with Saudi retailers. Can host data in-Kingdom, which matters under PDPL. Adds its own margin. Also does SMS as a fallback when a number has no WhatsApp. |
| **Twilio** | Global CPaaS, a Meta BSP | Templates are "Content Templates" (`ContentSid` + `ContentVariables`). The easiest API. Priced in USD, with a Twilio fee on top of Meta's. Good if the shop already uses Twilio for SMS. |

Other BSPs (360dialog, Infobip, and Saudi SMS gateways such as Taqnyat and
Msegat, which now resell WhatsApp) work the same way: an approved template,
parameters, and a webhook for delivery status.

The Electron app already has `lib/sms.js`, with Twilio, `whatsapp_cloud` and
Unifonic request builders and `settings.smsConfig`. Two gaps there to fix
before anyone relies on it:

- It sends WhatsApp as free text (`type: 'text'`). That fails outside the
  24-hour window. It must send `type: 'template'` with a template name,
  language and parameters.
- Its `normalizePhone` only strips non-digits, so `0501234567` becomes
  `+0501234567`. It should call `KhaytWhatsappMessage.normalizePhone`.

## Where the Mac would plug in

1. **Settings.** Add a WhatsApp provider section beside email: provider, phone
   number id or sender, and token. The token is sealed with `Secrets.seal`,
   never stored in the book in plain text. Then add the path to
   `lib/store-secret-paths.js` so it is masked before the book goes to a
   phone. Reuse the `settings.smsConfig` shape so both apps read one config.
2. **Template map.** `settings.whatsappTemplates = { ready: { name: 'order_ready', langs: ['ar','en'] }, … }`.
   It maps each milestone to the approved template, with the parameter order
   fixed in `lib/whatsapp-message.js` (a new `templateParams(milestone, values)`
   next to `messageText`).
3. **The send.** A new `lib/whatsapp-send.js` builds the request, the same way
   `lib/sms.js` does (pure builder, host performs it). It builds the
   `type: 'template'` body from `buildUpdate` output. On the Mac,
   `Shop.sendWhatsApp(for:text:milestone:lang:)` in
   `mac/KhaytCore/Sources/KhaytApp/WhatsApp.swift` is where it goes:
   - provider configured and the customer opted in: POST it and write the same
     `commEntry`, plus `status: 'sent'` and the provider's message id;
   - otherwise: fall back to the `wa.me` link, as now.
4. **Automatic on a move.** `lib/order-status.js:outboundFor` lists what a move
   reaches outside the shop, and the Mac refuses a move it cannot carry out
   fully. Add a `whatsapp` channel there, asked of a
   `lib/whatsapp-message.js:wouldSend(order, newStatus, ctx)`, the same pattern
   `order-email.js:wouldSend` uses. `markShipped`, `ship` and `markDelivered`
   in `Shop.swift` are not status moves, so they need the same hook added
   where they call `writeToOneOrder`.
5. **Delivery status.** Meta and the BSPs report `sent`, `delivered`, `read`
   and `failed` to a **public HTTPS webhook**. The Mac's `LanServer` is on the
   LAN only, so this belongs to the **Khayt Cloud** lane: a
   `POST /webhooks/whatsapp` that verifies the provider's signature and queues
   the status for the Mac to poll. That is the same pattern as the carrier
   webhooks. The Mac then updates the `commLog` line by provider message id.
   Without this, "sent" means "handed to the provider", which is still more
   than the `wa.me` version knows.

## Not decided

- Who owns the WABA: each shop (its own number and Meta business, and the
  shop pays Meta) or Khayt as a BSP-style reseller (one integration, but Khayt
  carries every shop's messaging). Per-shop is simpler and is what the
  settings above assume.
- Whether automatic sending should wait for a person, for example a queue of
  "ready to send" updates approved in one click. That keeps the rule that a
  message in the shop's name is read before it goes.
