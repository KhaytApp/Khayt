# Privacy & data-protection compliance — PDPL + GDPR-readiness

**Scope:** map Saudi **PDPL** (Personal Data Protection Law) obligations — and their GDPR equivalents — onto concrete Khayt features. Khayt holds **customer PII** (names, phone, email, address, order history) for small businesses in KSA, so the shop owner is a *data controller* and Khayt is, for any cloud feature, a *data processor*. This doc says **what to build**, reusing the existing export/redaction, intake, and wipe machinery. It complements the [security model](./KHAYT-3.0-SECURITY-MODEL.md), [telemetry spec](./KHAYT-3.0-TELEMETRY-SPEC.md), and [Phase 1 spec](./KHAYT-3.0-PHASE1-SPEC.md).

> **Disclaimer — engineering guidance, not legal advice.** This is an implementation spec, not a legal opinion or a compliance certification. PDPL/GDPR interpretation, DPA wording, and a Record of Processing Activities must be reviewed by qualified counsel before any claim of compliance. The goal here is to make the *technical posture* compliance-ready.

**Governing principle:** **privacy by design, local-first.** PII lives in the shop's own `store.json` on the shop's own machine — there is no central database of customers by default. Cloud is **opt-in** ([security model §1.1](./KHAYT-3.0-SECURITY-MODEL.md)) and **E2E-encrypted** ([Phase 1 §3](./KHAYT-3.0-PHASE1-SPEC.md)), so even when sync is on, Khayt the company holds ciphertext, not customer records. Local-first is the single biggest compliance lever: it collapses most "controller/processor/transfer" surface to "the shop's own device."

---

## 1. What personal data Khayt holds (PII inventory)

| Data | Fields | Where stored | Source |
|------|--------|--------------|--------|
| Customer identity | `nameEn`, `nameAr`, `phone`, `email` | `clients[]` in store (`hub_clients_v1`), `renderer/app-state.js` | Owner-entered or intake |
| Customer addresses | `addresses[].{label,address}` | `clients[]` | `renderer/clients.js` editor |
| Tax/registration | `cr`, `vat` (customer CR/VAT) | `clients[]` | Owner-entered |
| Communication log | `commLog[].{type,note,at}` | `clients[]` | Owner-entered (calls/emails) |
| Order history | `printLog[]` orders referencing `clientId`, project, price, notes | `hub_log_v1` | Operational |
| Intake submissions | `name`, `email`, `phone`, `description` | `waitingList[]` (`hub_waiting_v1`); orders via `POST /api/intake` | **Customer self-submitted** (`lib/lan-server.js`) |

**Not PII but adjacent:** shop financials, ZATCA certs, payment creds, API keys — covered by the [security model](./KHAYT-3.0-SECURITY-MODEL.md) and already masked by `redactSettingsForExport()` (`renderer/store.js`). Telemetry collects **no PII** by hard invariant ([telemetry §2](./KHAYT-3.0-TELEMETRY-SPEC.md)).

---

## 2. PDPL obligations → Khayt features

| Obligation (PDPL / GDPR) | How Khayt satisfies it | Build status |
|---|---|---|
| **Lawful basis / consent at collection** | Intake form (`lib/lan-server.js`) is the customer-facing consent point — add an explicit consent checkbox + privacy notice before submit (§3). Owner-entered clients rely on the controller's own legitimate-basis. | **Build** consent capture |
| **Data minimization** | Intake fields are already capped/optional (only name + description required). HQ aggregate allowlisted, portal projection minimal, AI egress scoped, telemetry PII-free — all existing invariants. Don't add fields without a purpose. | Mostly done; audit fields |
| **Right of access (DSAR)** | Per-customer export: extend `exportClientPortal(clientId)` / `exportClientInvoices` to a machine-readable **"Export this customer's data"** (JSON + the existing HTML/CSV) — client record + all `printLog` orders + commLog. | **Build** (reuse export) |
| **Right to rectification** | `openClientEditor()` already edits every field (name/phone/email/address/CR/VAT). Done. | Done |
| **Right to erasure** | `deleteClient()` removes the client and nulls `clientId` on orders; extend with a **cascade option** (also purge intake rows + commLog) and, when cloud-on, a **server purge** (delete blob + re-push). Full account erasure = `hub:request-full-wipe` (`main.js`). | **Extend** |
| **Storage limitation / retention** | Add optional **retention policy**: prompt to purge or anonymize intake/`waitingListHistory` and stale declined leads after N months. Telemetry retention already bounded (90d, [§5](./KHAYT-3.0-TELEMETRY-SPEC.md)). | **Build** retention sweep |
| **Residency (KSA)** | Local-first → PII stays on the shop's device by default. Cloud offers a **KSA-region** hosting option ([Phase 1 §8](./KHAYT-3.0-PHASE1-SPEC.md), [security §5](./KHAYT-3.0-SECURITY-MODEL.md)); ZATCA certs never leave the desktop. | Region option (Phase 1) |
| **Breach notification** | E2E means a server breach leaks ciphertext + metadata, not customer records ([security §6](./KHAYT-3.0-SECURITY-MODEL.md)) — but **build** a documented breach-response runbook + a way to notify affected shops (controllers) within the PDPL timeline; shops then notify their customers. | **Build** runbook |
| **Cross-border transfer** | Default: no transfer (data on-device). Cloud transfer is mitigated by **E2E** (Khayt sees ciphertext) + KSA region. AI egress to Anthropic is a transfer — disclosed, scoped, owner's own key (§5). | E2E + region + disclosure |
| **Transparency / right to know** | `privacy.html`, the intake notice, and "View what's collected" for telemetry. Add a plain-language privacy notice covering customer PII. | **Extend** privacy.html |

---

## 3. Consent management (intake)

The intake form (`renderIntakeFormPage`, `lib/lan-server.js`) is where a **customer** — not the owner — submits their own PII. This is the one place Khayt collects PII directly from a data subject, so it needs explicit consent:

- **Consent checkbox** (required to submit): "I agree that [shop] may store my contact details to process my request." Link to a short privacy notice (purpose, controller = the shop, retention, contact).
- **Record of consent:** store `consent: { agreed: true, at: <ISO>, version: <noticeVersion>, text }` on the created `waitingList` / order row in the `POST /api/intake` handler. Auditable, immutable per submission — mirrors telemetry's `consentAt` pattern.
- **Bilingual** (AR/EN) notice text, matching the intake page language.
- **No pre-ticked box, no bundling** — consent is for processing the request only; marketing/reminders (the quote-follow-up automation) is a separate opt-in.
- **Owner-entered clients** carry no subject-consent (the owner is acting on their own basis as controller); the per-customer export/erasure tools below cover their rights regardless.

---

## 4. Data-subject request (DSR) handling

A practical owner-facing flow, all local, no new backend:

- **Access / portability — "Export customer data":** a button in the client editor / history modal that bundles the client record + their orders (`printLog.filter(clientId)`) + `commLog` + intake rows into a downloadable JSON (machine-readable, portable) alongside the existing human-readable `exportClientPortal` HTML. Reuse `buildExportPayload`'s shape, scoped to one `clientId`, secrets redacted via `redactSettingsForExport`.
- **Erasure — "Delete customer" with order handling:** today `deleteClient()` nulls `clientId` on orders (keeps the order, drops the link). For PDPL erasure offer two modes:
  1. **Unlink (default):** keep orders for the shop's own financial/ZATCA record-keeping (a legitimate retention basis), strip the link — current behavior. The order keeps `client`/project but the identifiable client record is gone.
  2. **Full erase:** also blank the denormalized `client` name on those orders, remove matching `waitingList`/`waitingListHistory` rows and `commLog`. Surface the trade-off (invoices may legally need to retain some data) in the confirm dialog.
- **Cloud purge:** when sync is on, erasure must also re-push the modified store (the blob no longer contains the customer) so the cloud copy reflects the deletion; document that prior `rev` history is purged per retention.
- **Undo window:** the existing 5s undo toast in `deleteClient()` stays for accidental deletes; cloud purge fires after it lapses.

---

## 5. Cloud processor obligations

When a shop enables Khayt Cloud, Khayt Inc. becomes a **processor**. Obligations to satisfy:

- **DPA (Data Processing Agreement):** a signed/click-through DPA at cloud onboarding — purpose, sub-processors, security measures, breach terms, deletion-on-termination. Flagged as a pre-launch item in [security §5](./KHAYT-3.0-SECURITY-MODEL.md) ("data-processing terms before launch").
- **Residency:** KSA-region hosting option, documented before onboarding ([Phase 1 §8](./KHAYT-3.0-PHASE1-SPEC.md)).
- **Sub-processors (declare + DPA each):**
  - **Anthropic** — AI assist sends request text/image to the Claude API under the **user's own key** ([AI spec §5](./KHAYT-3.0-AI-SPEC.md)). Disclosed in-UI; no customer record sent beyond the request, only the material list. This is a cross-border transfer the owner consents to by enabling AI.
  - **Payment providers** (Stripe / Tabby / Tamara) — process payment + customer data for transactions; webhook-verified, secrets server-side ([security §3](./KHAYT-3.0-SECURITY-MODEL.md)).
  - **Email/SMTP, Telegram, hosting/infra** — list in the sub-processor register.
- **Processor security:** E2E (server holds ciphertext), tenant isolation, audit log, rate limits — all per the [security model](./KHAYT-3.0-SECURITY-MODEL.md).
- **Deletion on termination:** account deletion purges ciphertext + metadata ([security §5](./KHAYT-3.0-SECURITY-MODEL.md)); the shop's local store is unaffected (their own copy).

---

## 6. Cross-references

- **[Security model](./KHAYT-3.0-SECURITY-MODEL.md)** — E2E, residency, right-to-delete/export, breach posture, DPA note (the security backbone for these obligations).
- **[Telemetry spec](./KHAYT-3.0-TELEMETRY-SPEC.md)** — opt-in, **no PII ever**, consent timestamp, scrubbing; §6 already maps the telemetry stream to PDPL.
- **[Phase 1 spec](./KHAYT-3.0-PHASE1-SPEC.md)** — E2E key model, KSA-region hosting, tenant isolation — the cloud-side residency + transfer mitigations.
- **[AI spec](./KHAYT-3.0-AI-SPEC.md)** — the Anthropic egress disclosure + scoping (the one third-party PII transfer in the default product).

---

## 7. Implementation checklist

- [ ] Intake consent checkbox + bilingual privacy notice; persist `consent{agreed,at,version}` on intake rows (`lib/lan-server.js`).
- [ ] "Export this customer's data" → portable JSON (client + orders + commLog + intake), reusing `buildExportPayload` scoped to one `clientId`, secrets redacted.
- [ ] `deleteClient()` erasure modes: **unlink** (keep order record) vs **full erase** (blank denormalized name, purge intake/commLog), with a clear confirm.
- [ ] Cloud purge on erasure: re-push modified store when sync on; document `rev`-history purge.
- [ ] Retention sweep: optional prompt to purge/anonymize stale intake + declined `waitingListHistory` after N months.
- [ ] `privacy.html` covers customer PII (purpose, retention, subject rights, controller = the shop, processor = Khayt for cloud).
- [ ] Sub-processor register (Anthropic, payment providers, email, infra) + click-through DPA at cloud onboarding.
- [ ] Breach-response runbook: detection → assess (ciphertext vs metadata) → notify affected shops within the PDPL window → shops notify customers.
- [ ] Confirm no new PII field is added without a documented purpose (minimization review).

---

## 8. Definition of done

- A customer who submits via intake sees and agrees to a clear, bilingual consent notice; their consent is recorded with a timestamp.
- An owner can, in a few clicks, **export** one customer's full data as portable JSON, **rectify** any field, and **erase** the customer with an explicit order-handling choice — and when cloud is on, the erasure propagates to the server copy.
- Default posture keeps all PII on the shop's device (residency by default); cloud is opt-in, E2E, KSA-region, with a DPA and declared sub-processors.
- Telemetry remains PII-free; no customer record ever leaves the device except via the owner-initiated, disclosed paths above (AI egress, cloud sync, exports the owner generates).
- `privacy.html`, the sub-processor register, the DPA, and the breach runbook exist and are linked; counsel has reviewed the legal text. Engineering posture is compliance-ready — the legal claim is counsel's to make.
