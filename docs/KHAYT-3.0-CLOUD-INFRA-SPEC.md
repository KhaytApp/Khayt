# Khayt Cloud — infrastructure & operations spec

How Khayt Cloud is **built, deployed, and run**. The feature specs ([Phase 1](./KHAYT-3.0-PHASE1-SPEC.md)/[2](./KHAYT-3.0-PHASE2-SPEC.md)/[3](./KHAYT-3.0-PHASE3-SPEC.md)) define *what* the backend does; this defines *what it runs on*. Read alongside the [security model](./KHAYT-3.0-SECURITY-MODEL.md).

**Principle:** keep the **offline desktop app untouched and clean**. Cloud is a **separate codebase/service**; the desktop only gains an opt-in client. Nothing here can change the cloud-off experience.

---

## 1. Repo & boundary

- **New repo `khayt-cloud`** (separate from this desktop repo). Rationale: different runtime, deploy cadence, dependencies, and threat surface; keeps the offline app's lean dependency tree and "no backend" property intact.
- The desktop repo gains only a thin **`CloudBackend`** client (implements the Phase 0 `SyncBackend` interface) + Settings UI — no server code, no server deps.
- Shared contracts (API types, delta/crypto format) live in a small versioned spec/package referenced by both.

---

## 2. Tech stack (recommended, decisive)

> **As built (2026-07-27):** production runs **PHP 8.3 + MySQL on shared
> hosting** (Hostinger/LiteSpeed), not the Node/Fastify + Postgres + Redis below.
> PHP executes per request, so there is no process to keep alive — the reason the
> recommendation was not followed. The Node implementation in `src/` is kept as
> the VPS option and both are held to one contract. See
> [CLOUD-STATUS](./KHAYT-3.0-CLOUD-STATUS.md).

Chosen for consistency with the existing codebase (Node everywhere — desktop, `lib/lan-server.js`) and operational simplicity:

| Layer | Choice | Why |
|-------|--------|-----|
| API runtime | **Node.js + Fastify** | Same language as desktop/LAN server; Fastify = fast, schema-validated routes, low overhead |
| Datastore | **PostgreSQL** | Relational tenancy (`orgId`/`shopId`), transactions, mature in every region |
| Blob storage | **Postgres `bytea` (P1)** → object storage (S3-compatible) when blobs grow | Start simple; ciphertext only |
| Cache / rate-limit / jobs | **Redis** | Token throttling, magic-link state, background-job queue |
| Background jobs | Redis-backed worker (BullMQ or similar) | Magic-link email, HQ aggregate rollups (P3), pruning |
| Auth tokens | JWT (access) + opaque rotating refresh (hashed in PG) | Per Phase 1 §2 |
| Email (magic link) | Transactional provider (e.g. SES/Postmark) | Region-aware sender |
| Edge | TLS termination + WAF + rate limit at the proxy (e.g. Cloudflare / ALB) | DoS + TLS + HSTS |

All choices are swappable; the decisive default is **Node/Fastify + Postgres + Redis**.

---

## 3. Topology

```
            ┌── WAF / TLS / rate-limit (edge) ──┐
 clients ──▶│                                   │──▶ API (Fastify, stateless, N replicas)
            └───────────────────────────────────┘            │
                                                              ├─▶ Postgres (primary + read replica)
                                                              ├─▶ Redis (throttle / jobs / magic-link)
                                                              └─▶ Worker(s) ── aggregate rollups, email, pruning
                              object storage (S3-compat) ◀────┘  (blobs, when they outgrow bytea)
```

- **API is stateless** → horizontal scale behind the edge. Session state lives in PG/Redis.
- **One writer DB**, read replica for HQ dashboard reads (P3).

---

## 4. Region & residency

- **KSA region** as the primary for ZATCA customers (roadmap §8.4 / security §5). Provider chosen for a Saudi (or nearest-compliant, e.g. Bahrain) region.
- Residency is a **per-org** attribute (`orgs.region`); data for an org stays in its region. Document residency before onboarding ZATCA users.
- Self-hosted Cloud (enterprise/franchise, P4) packaged as containers + a compose/Helm chart — deferred until asked.

---

## 5. Environments & config

- **dev → staging → prod**, fully isolated (separate DBs, keys, domains). No shared secrets across envs.
- **12-factor config** via env vars; **secrets** in a managed secret store (not in images/repo). Rotation runbook for DB creds, JWT signing keys, provider keys.
- **JWT signing-key rotation** with overlap (accept old+new during a window).

---

## 6. CI/CD

- `khayt-cloud` pipeline: lint → unit tests → **migration check** → integration tests (ephemeral PG/Redis) → **adversarial tenant-isolation tests** (security §7 gate) → build image → deploy staging → smoke → promote to prod.
- **DB migrations** versioned and forward-only (a migration tool, run as a pre-deploy step); every migration reversible-by-design or paired with a rollback plan.
- Prod deploys gated on the security checklist items being green.

---

## 7. Observability & ops

- **Structured logs** (no secrets/plaintext shop data — only ids, sizes, revs, timings). Log scrubbing enforced.
- **Metrics:** request rate/latency/error, sync push/pull volume, blob sizes, queue depth, DB health. Dashboards + alerts.
- **Error tracking** (e.g. Sentry) with PII scrubbing.
- **Audit log** (security §3) is a first-class, append-only, queryable store — not just app logs.
- **Uptime/synthetic checks** on auth + sync round-trip.

---

## 8. Backups & DR

- Postgres: automated daily snapshots + PITR (WAL). Backups hold **ciphertext only** (E2E) — a backup leak ≠ shop-data leak.
- **Restore drills** on a schedule (a backup you haven't restored isn't a backup).
- Object storage versioned + lifecycle-pruned.
- **RPO/RTO targets** set before GA (e.g. RPO ≤ 24 h via snapshots, tighter with PITR).
- Note: the **desktop local store is itself a full copy** — the ultimate DR backstop for the user's own data.

---

## 9. Scaling path

- **P1 (single-shop blobs):** tiny load; one small API instance + managed PG suffice.
- **P3 (multi-shop deltas):** entity-delta write volume rises → read replica for HQ, partition `sync_log`/deltas by `org_id`, move blobs to object storage.
- **P4 (franchise):** per-tenant quotas; consider per-region clusters.
- Real-time (SSE/WebSocket, roadmap Phase 4) adds a stateful fan-out tier — design when it lands, not before.

---

## 10. Cost envelope (rough, for go/no-go)

Order-of-magnitude, not a quote:
- **Pilot (≤ tens of shops):** a small managed PG + Redis + one API instance + edge — low monthly (~tens of USD).
- **Growth (hundreds):** add replica + object storage + worker + monitoring — moderate.
- Dominant variables: DB tier, egress, email volume. AI cost is **on the user's own Anthropic key** (BYO) — zero to Khayt unless a proxied tier ships later.
- This funds the **paid Cloud subscription**; the local app stays free (roadmap §7).

---

## 11. Definition of ready (before writing Phase 1 server code)

- [ ] `khayt-cloud` repo + CI skeleton + ephemeral-PG integration harness.
- [ ] Provider + **KSA region** chosen; dev/staging/prod provisioned via IaC.
- [ ] Secret store + rotation runbook; JWT signing-key strategy.
- [ ] Migration tool wired; first schema (Phase 1 §7) migration written.
- [ ] Observability baseline (logs/metrics/error tracking/audit store) before first real data.
- [ ] Backup + **restore drill** validated on staging.
- [ ] Tenant-isolation adversarial tests in CI as a deploy gate.
