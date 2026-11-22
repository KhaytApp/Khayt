# Khayt Cloud — security & threat model

Cross-cutting security design for the 3.0 platform. Applies across [Phase 1](./KHAYT-3.0-PHASE1-SPEC.md) (identity + E2E sync), [Phase 2](./KHAYT-3.0-PHASE2-SPEC.md) (mobile + portal), [Phase 3](./KHAYT-3.0-PHASE3-SPEC.md) (multi-shop), and the [AI flagship](./KHAYT-3.0-AI-SPEC.md). This is the doc to read before writing any cloud code.

**Why it matters:** Khayt handles **shop financials, customer PII, payment credentials, ZATCA certificates, and API keys** for small businesses in a regulated market (KSA/ZATCA). The bar is "a breach of Khayt Cloud exposes ciphertext, not shops."

---

## 1. Security invariants (must always hold)

1. **Cloud is optional.** No telemetry, no silent upload; the local app is fully functional and self-contained with cloud off. *(A privacy guarantee, not just a feature.)*
2. **Server stores ciphertext, not shop data.** Operational data (orders/clients/inventory) is E2E-encrypted under a key the server never holds (per-shop passphrase in P1; org data key in P3). A Khayt-side breach yields opaque blobs.
3. **Tenant isolation is absolute.** `orgId` (and `shopId`) on every row and every query; no code path returns another tenant's data. Enforced in a query layer that *requires* the scope, and verified by adversarial tests.
4. **The customer portal sees only a consented per-order projection** — status/item/price/due/pay-link. Never cost, margin, notes, other orders, or the store.
5. **Access ≠ decryption.** Account auth (magic link) grants *access*; a separate key grants *decryption*. A compromised inbox cannot read shop data.
6. **Secrets never leave plaintext at rest.** API keys, payment creds, ZATCA certs, tokens use the existing encrypted-secret + export-redaction pattern, on desktop and server alike.

If a change would break one of these, it needs an explicit, documented decision — not a silent exception.

---

## 2. Assets & trust boundaries

| Asset | Sensitivity | Where |
|-------|-------------|-------|
| Orders / clients / inventory | High (PII + financial) | Desktop (plaintext, source of truth) → cloud (ciphertext) |
| Payment credentials (Stripe/Tabby/Tamara) | Critical | Desktop settings / cloud server-side; never portal client |
| ZATCA certificates (CSID/PCSID) | Critical (regulatory) | Desktop, encrypted; redacted from export |
| Anthropic API key (AI) | High | Desktop settings, encrypted; used client→Anthropic directly |
| Auth tokens / refresh / device tokens | High | Short-lived, rotated, hashed at rest |
| Encryption keys (passphrase-derived / ODK) | Critical | Client devices only; **never** server plaintext |

**Trust boundaries:** desktop↔cloud · phone↔cloud · customer↔portal · payment-provider↔cloud (webhooks) · desktop↔Anthropic (AI). Each is enumerated below.

---

## 3. Threats & controls (STRIDE, per surface)

| Surface | Threat | Control |
|---------|--------|---------|
| **Auth** | Spoofing / credential theft | Passwordless magic link (throttled), short-lived JWT, rotating refresh, device registration + revoke |
| **Sync API** | Tampering / replay | TLS; `rev` compare-and-set (CAS) on writes; idempotent delta ops (op-id) in P3; integrity check on decrypt (AEAD tag) |
| **Tenant data** | Info disclosure (cross-tenant) | `orgId`/`shopId` mandatory in query layer; adversarial isolation tests; no raw queries |
| **At-rest store** | Info disclosure (breach) | E2E: server holds ciphertext only; keys never server-side |
| **Portal** | Info disclosure / enumeration | Per-order unguessable expiring tokens; brute-force throttle (reuse LAN pattern); consented projection only; CSP |
| **Payments** | Tampering / forgery | Provider webhook **signature verification**; secrets server-side; amounts re-validated against the order |
| **HQ aggregate** (P3) | Over-collection | Owner-approved field allowlist; no PII/line-items/margins; every cross-shop read audited |
| **Key distribution** (P3 ODK) | Key leak / rogue device | ODK wrapped to device public keys; owner authorizes devices; rotate on revoke (forward secrecy) |
| **AI egress** | Data leak to third party | Only request text/image + material list sent (user's own key); explicit UI disclosure; nothing else of the store |
| **All APIs** | DoS | Per-device/IP rate limits, request-size caps, blob/delta ceilings |
| **Audit** | Repudiation | Append-only sync/access log (who, shop, rev, ts) |

---

## 4. Key management (the highest-risk area)

- **Phase 1:** sync passphrase → scrypt/Argon2 → data key; one-time **recovery key**. Lost passphrase + recovery key ⇒ cloud copy unrecoverable, **local store unaffected** (re-connect re-uploads). This trade-off is intentional and must be surfaced clearly at setup.
- **Phase 3:** **Org Data Key (ODK)** shared across the org's devices, each copy wrapped to a device/user key; server stores only wrapped blobs. Owner authorizes new devices; **rotate ODK on revoke**.
- **Never:** transmit or store a plaintext data key / ODK server-side; derive keys from the login credential alone (keeps access and decryption separate).
- **Crypto choices:** AEAD (AES-256-GCM or libsodium secretbox) for payloads; memory-hard KDF (scrypt/Argon2id) for passphrases; asymmetric wrap (e.g. X25519/sealed box) for ODK distribution.

---

## 5. Compliance & residency

- **KSA region hosting** option for ZATCA customers; document data residency before onboarding. ZATCA certs stay desktop-side and out of exports regardless.
- **Data minimization:** the HQ aggregate is allowlisted; the portal projection is minimal; AI egress is scoped.
- **Right to delete / export:** account deletion purges ciphertext + metadata; local store is the user's own copy.
- **DPA / consent:** per-shop consent for what HQ/franchisor sees (P3/P4); data-processing terms before launch.

---

## 6. Incident posture

- **Server breach** → attacker gets ciphertext + metadata (emails, shop names, sizes, timestamps), **not** shop operational data. Metadata exposure is the residual risk to communicate honestly.
- **Lost device** → revoke device; rotate ODK (P3); refresh tokens invalidated.
- **Compromised account email** → access only, not decryption (invariant §1.5); still rotate and notify.
- **Payment-webhook spoof** → rejected by signature verification; amounts re-validated.

---

## 7. Pre-launch security checklist

- [ ] Adversarial tenant-isolation tests green (cross-`shopId`/`orgId` access denied).
- [ ] E2E verified by construction: server cannot decrypt without the client key (test + review).
- [ ] No plaintext data key / ODK ever reaches the server (code review + test).
- [ ] Portal returns only the consented projection (assert no cost/margin/notes/other-orders).
- [ ] Payment webhooks signature-verified; amounts re-validated.
- [ ] Rate limits + size caps on every public/authenticated endpoint.
- [ ] Secrets encrypted at rest + redacted from all exports (desktop + server).
- [ ] Audit log covers auth, sync writes, and every cross-shop/HQ read.
- [ ] External security review of the crypto + key-distribution before GA.

---

## 8. Open security decisions

- Exact HQ aggregate allowlist (privacy vs usefulness) — owner-approved, before Phase 3.
- Metadata-at-rest minimization — how much (email, shop name, sizes) the server must hold; can any be reduced/encrypted?
- ODK rotation cadence and re-encryption cost at scale.
- Whether enterprise/franchise (P4) requires self-hosted Cloud to satisfy residency/governance.
- Bug-bounty / responsible-disclosure program at GA.
