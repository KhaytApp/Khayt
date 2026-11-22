# Marketing & campaigns — spec

**Scope:** segment clients and send promotions / announcements / abandoned-quote recovery over Khayt's **existing** messaging rails (WhatsApp templates, email, Telegram), extending the quote-follow-up automation. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) marketing track.

**Governing principle:** **local, opt-in, consent-respecting.** Campaigns run from the shop's own machine using its own channels — no Khayt Cloud, no platform account. Nothing sends until the owner enables a campaign. Every send checks per-client consent and opt-out first; the shop owner, not Khayt, is the sender of record. We **reuse** `waTemplates`, the `quote-followup` selector pattern, and the existing client/order fields — we do **not** add a new transport.

---

## 1. The reuse contract (why this is safe & cheap)

- **Transports already exist.** WhatsApp → `window.hubAPI.shareWhatsApp({ phone, message })` with a `wa.me` fallback (`renderer/invoicing.js:466`). Email → `window.hubAPI.sendEmail({ to, subject, body, smtpConfig })` (`renderer/integrations.js:70`). Telegram → `window.hubAPI.sendTelegram({ botToken, chatId, message })` (`renderer/integrations.js:1033`). Campaigns call these — no new IPC.
- **The selector pattern already exists.** `lib/quote-followup.js` is a pure, side-effect-free "who is due right now" selector + a `markFollowUpPatch` writer. Marketing copies this shape exactly: a pure `selectClientsForCampaign(...)` plus a `markCampaignSentPatch(...)`.
- **Templates already exist.** `waTemplates` (`renderer/app-state.js:213`) with `{{client}}`/`{{id}}`/`{{price}}`/`{{currency}}` substitution. Campaign messages render through the same substitution.
- **WhatsApp is open-only (anti-spam by design).** `shareWhatsApp`/`wa.me` opens a prepared chat for the owner to send by hand — Khayt never blasts WhatsApp silently. Campaigns inherit this: WhatsApp = a reviewed outbox queue, not a fire-and-forget broadcast.

---

## 2. Data model

New store key `K.CAMPAIGNS` (array; same `loadJSON`/`saveAll`/export plumbing as `waTemplates`).

```
campaign = {
  id, name,
  type,            // 'promotion' | 'announcement' | 'abandoned_quote' | 'winback' | 'review_request'
  segment,         // filter spec, see §3
  channel,         // 'whatsapp' | 'email' | 'telegram'
  templateId,      // waTemplates id  (or inline subject/body for email)
  subject,         // email only
  schedule: { mode: 'once'|'recurring', sendAt, frequency, weekday, hour, quietStart, quietEnd },
  status,          // 'draft' | 'scheduled' | 'running' | 'paused' | 'done'
  throttle: { perRunMax, minGapMinutes },
  lastRunAt, createdAt,
}
```

**Per-client consent** (new fields on the client record, defaulted on read — clients have no `tags` today, only `source`/loyalty):
```
client.marketing = {
  consent: 'unknown'|'opted_in'|'opted_out',  // default 'unknown'
  optOutAt, optOutChannel,
  tags: [],                  // NEW free-text segment tags
  lastContacted,             // ISO; bumped after any campaign send
  lastContactedByCampaign,   // campaignId
}
```

**Send log** `K.CAMPAIGN_LOG` (append-only; powers dedup, opt-out audit, and reporting):
```
logEntry = { id, campaignId, clientId, channel, templateId,
             sentAt, status: 'sent'|'skipped'|'failed', reason, messageHash }
```

---

## 3. Segmentation

Pure filter over the existing `clients` + `printLog` (orders) arrays — no new derived store. Reuses fields that already exist:

| Filter | Source field |
|---|---|
| Tags | `client.marketing.tags[]` (new) |
| Source | `client.source` (`instagram/referral/walk_in/website/exhibition/other`, `renderer/clients.js:505`) |
| Total spend / order count | summed from `printLog` via `orderRevenueBase(o)` — same pass as loyalty tiers (`renderer/clients.js:117`) |
| Loyalty tier | `getClientTier(client)` (`renderer/clients.js:889`) |
| Recency | last completed order date from `printLog`; "no order in N days" drives win-back |
| Has phone / has email | `client.phone` / `client.email` (channel reachability) |
| Consent | `client.marketing.consent !== 'opted_out'` (always applied) |

`selectClientsForCampaign(clients, orders, segment, now)` returns the eligible list, sorted by `lastContacted` ascending (least-recently-contacted first), mirroring `selectQuotesDueForFollowUp`'s soonest-first ordering. Pure → unit-testable.

---

## 4. Channels

All three already wired; campaign picks one per campaign:

- **WhatsApp** — render template → `shareWhatsApp({ phone, message })`, `wa.me` fallback. Opens one chat at a time for owner review/send (manual gating = built-in throttle & anti-spam). Requires `client.phone`.
- **Email** — render subject + HTML body → `sendEmail({ to, subject, body, smtpConfig: settings.emailConfig })`. Truly automated; requires `client.email` and a configured `emailConfig`. Reuses the same digest plumbing in `renderer/integrations.js`.
- **Telegram** — render text → `sendTelegram({ botToken, chatId, message })` from `settings.telegram`. Broadcasts to the shop's own configured chat/channel (announcements), not per-client DMs.

If the channel is unavailable (no SMTP, no bot token, client missing the contact field), the send is logged `skipped` with a reason and the run continues.

---

## 5. Campaign types

1. **Promotion / announcement** — owner writes/AI-drafts copy, picks a segment, picks a channel, schedules once or recurring. Email & Telegram auto-send; WhatsApp queues for review.
2. **Abandoned-quote recovery** — **extends `lib/quote-followup.js` directly.** Quote-followup already finds expiring/expired unapproved quotes; the recovery campaign reuses `selectQuotesDueForFollowUp` and `sendQuoteFollowUp` (`renderer/invoicing.js:449`), layering a campaign template + the consent/dedup checks below. Marks via the existing `markFollowUpPatch` so dashboard + campaign de-dupe agree.
3. **Win-back** — segment = "no completed order in N days" (recency filter, §3), default template "we miss you / here's an offer".
4. **Post-delivery review request** — triggered for orders that reached a delivered/completed status M days ago and have no review-request log entry; one-shot per order, respects consent.

---

## 6. Sending & throttling

A pure planner `planCampaignRun(campaign, clients, orders, log, now)` returns `{ toSend[], skipped[] }`; the renderer executes `toSend` through the channel transport and appends to `K.CAMPAIGN_LOG`. Guards, in order:

1. **Opt-out enforcement** — skip any client with `marketing.consent === 'opted_out'`. Hard rule, never overridable.
2. **Quiet hours** — no sends outside `schedule.quietStart..quietEnd` (default 21:00–09:00 KSA). Defer to next allowed window.
3. **Dedup** — skip a `(campaignId, clientId)` pair already `sent` in the log; for recurring, enforce `minGapMinutes`/cooldown per client (same cooldown idea as `quoteFollowUp.cooldownDays`). `messageHash` blocks identical re-sends.
4. **Rate limit** — at most `throttle.perRunMax` per run, `minGapMinutes` between sends (protects WhatsApp/SMTP reputation). WhatsApp's manual review naturally throttles further.
5. **Reachability** — skip if the chosen channel's contact field is empty (`skipped`, reason `no_phone`/`no_email`).

After each successful send: bump `client.marketing.lastContacted`, write the log entry, `saveAll()`.

**Scheduling** reuses the existing timer/digest pattern (`startQuoteFollowUpTimer` at `renderer/app-state.js:595`, digest `lastSentDate` double-send guard at `renderer/app-state.js:207`). No new scheduler.

---

## 7. AI tie-in (optional)

Optional, BYO-key, off by default — same plumbing and guardrails as [KHAYT-3.0-AI-SPEC.md](./KHAYT-3.0-AI-SPEC.md) §6 ("Message drafting AR/EN, in the shop's voice"). AI **drafts campaign copy** (subject + body, AR/EN) into the editor; the owner reviews and edits before anything is scheduled or sent. AI never selects recipients, never sends, never touches consent. With no key configured, campaigns work fully on hand-written templates.

---

## 8. Integration points (exact)

- `lib/campaigns.js` (**new**, mirrors `lib/quote-followup.js`): `campaignConfig`, `selectClientsForCampaign`, `planCampaignRun`, `markCampaignSentPatch`, `messageHash`. Pure, exported via `module.exports` + `globalThis.KhaytCampaigns`.
- `renderer/app-state.js` — add `K.CAMPAIGNS` / `K.CAMPAIGN_LOG`; load/save/export/reset alongside `waTemplates` (lines 224, 333, 412, 496); kick a `startCampaignTimer()` next to `startQuoteFollowUpTimer()` (line 595).
- `renderer/invoicing.js` — reuse `sendQuoteFollowUp` for `abandoned_quote`; extract its template-render + transport block as a shared `dispatchMessage(client, channel, message)` helper.
- `renderer/integrations.js` — reuse `sendEmail`/`sendTelegram` transports as-is.
- `renderer/clients.js` — add `marketing` field defaults, a tags editor in the client modal (near `source`, line 503), and an opt-out toggle.
- `renderer/settings.js` — add a "Marketing" settings panel mirroring `renderDigestSettings` (line 268): global enable, quiet hours, default throttle, AI-draft toggle.
- New `renderer/campaigns.js` — campaign list/editor UI + a WhatsApp review outbox.

---

## 9. Edge cases

- **Opt-out wins always** — opted-out clients are filtered in the pure selector *and* re-checked at send time; an STOP/unsubscribe reply flips `consent` to `opted_out` (manual in v1).
- **Channel unavailable** — missing SMTP / bot token / phone / email → `skipped` with reason; run continues, owner sees a per-run summary.
- **Duplicate sends** — `(campaignId, clientId)` + `messageHash` in the log prevent repeats across reruns, app restarts, and overlapping campaigns; recurring campaigns honor cooldown.
- **Client deleted / merged mid-campaign** — planner re-reads `clients` each run; stale `clientId` rows in the queue are dropped.
- **Quiet-hours / app-closed** — if the machine is off at `sendAt`, the next launch's timer catches up (idempotent via dedup), like the digest catch-up.
- **No consent recorded (`unknown`)** — owner setting decides whether `unknown` is treated as eligible; default conservative (treat `unknown` as sendable for transactional-style recovery, but `promotion` requires explicit `opted_in` — configurable).

---

## 10. Test plan & Definition of Done

**Unit (pure, no DOM — like `quote-followup` tests):**
- `selectClientsForCampaign`: tags / source / spend / recency / consent filters; opted-out always excluded; sort by `lastContacted`.
- `planCampaignRun`: quiet-hours deferral, `perRunMax` cap, dedup via log + `messageHash`, reachability skips with correct reasons.
- `abandoned_quote` path returns the same set as `selectQuotesDueForFollowUp` for the matching segment.
- `markCampaignSentPatch` / `messageHash` are deterministic and idempotent.

**Integration:** template substitution renders correct AR/EN copy; each channel calls the right `hubAPI` with the right payload; failed transport → `failed` log, run continues.

**DoD:**
- [ ] Campaigns are off by default; nothing sends without explicit enable.
- [ ] Every send passes opt-out, quiet-hours, dedup, rate-limit, reachability guards.
- [ ] WhatsApp stays review-gated (no silent blast); email/Telegram auto-send when configured.
- [ ] Reuses `waTemplates`, `quote-followup`, existing `hubAPI` transports, client fields — no new transport, no Khayt Cloud dependency.
- [ ] Works fully with no AI key; AI drafting is optional and review-gated.
- [ ] Send log is append-only and complete (sent/skipped/failed + reason).
- [ ] Pure selector/planner covered by unit tests; AR/EN copy verified.
