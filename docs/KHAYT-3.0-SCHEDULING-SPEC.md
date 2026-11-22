# Print-farm scheduling — smart auto-assignment (assistive)

**Scope:** a **local, deterministic scheduler** that recommends *which printer prints which job, in what queue order*, by deadline, material, and printer capability — and proposes **batches** of same-material jobs. It **proposes**; the operator **approves**. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) farm-ops; complements [Phase 3 multi-shop](./KHAYT-3.0-PHASE3-SPEC.md) (scheduling is **shop-scoped**) and [AI assist](./KHAYT-3.0-AI-SPEC.md) (optional NL tie-in). Can ship independent of cloud.

---

## 1. Governing principle (assistive, local, opt-in)

Same stance as every Khayt feature: **the operator stays in control.**

- **Assistive, human-in-the-loop.** The scheduler computes a *proposal* (printer + queue position per job, plus suggested batches). Nothing moves until the operator clicks **Apply**. This mirrors the kanban's manual drag-reorder (`renderer/kanban.js` — `setupKanbanDrag` writes `queuePos`/`queueCol` only on an explicit drop) — we never auto-move a card.
- **Local-first.** The whole algorithm runs in the renderer over the in-memory `printLog` + `machines` arrays. **No cloud, no AI required.** A cloud-off, single-shop, no-key user gets the full feature.
- **Opt-in.** Off by default; a **Suggest assignments** affordance on the kanban / machine view. Hidden behind the same graceful-degradation rule as the rest of the app — if no machines have capability data, the panel explains what to fill in rather than guessing.

---

## 2. Data model

### 2.1 Machine capability (extend the existing machine model)

Today (`renderer/machines.js`, editor in `openMachineEditor`) a machine already carries: `compatMaterials[]`, `nozzleDiameter`, `extruderType`, `nozzle{…}`, `isOffline`, `targetHoursPerDay`, `printerApi{type,host,…}`. We **reuse these as the capability set** and add one missing dimension:

| Field | New? | Use in scheduling |
|-------|------|-------------------|
| `compatMaterials[]` | existing | **Hard filter** — job material must match one entry (substring, case-insensitive, same rule as the order editor's compat warning, `order-flows.js:796`). Empty = "accepts anything" (back-compat). |
| `nozzleDiameter` | existing | Soft filter — if a job declares a required nozzle, mismatch is a warning, not exclusion. |
| `isOffline` | existing | **Hard exclude** — offline/paused machines never receive a proposal. |
| `targetHoursPerDay` | existing | **Overcommit check** — compare to queued `printTime` sum per machine. |
| `buildVolume {x,y,z}` (mm) | **new** | Optional hard filter when a job carries `dimensionsMm`. Null = unconstrained (back-compat; no migration needed). Added to the machine editor next to `nozzleDiameter`. |

### 2.2 Order fields (extend the existing order model)

Orders already have everything the scheduler needs: `machineId`, `material`, `dueDate`, `priority`/`priorityLevel` (`normal|high|urgent`), `printTime`, `printWeight`, `queuePos`, `queueCol`, `status`, and `parts[]` (each with its own `machineId`/`material`/`printTime`). Additions are minimal:

| Field | New? | Use |
|-------|------|-----|
| `priorityLevel` | existing | Tie-break within a deadline tier (urgent > high > normal), same ordering the kanban pending column already uses (`kanban.js:398`). |
| `dueDate` | existing | Primary ordering key (via `kanbanUrgencyScore`). |
| `dimensionsMm {x,y,z}` | **new, optional** | Enables build-volume filtering. Absent → volume filter skipped. |
| `requiredNozzleMm` | **new, optional** | Soft nozzle filter. Absent → skipped. |
| `_scheduleLockMachineId` | **new, optional** | Operator "pin": exclude this job from re-proposals (respect a manual choice). |

No field is mandatory; absence degrades a *filter* to "unconstrained", never an error.

---

## 3. Scheduling algorithm (deterministic)

Pure function: `proposeSchedule(orders, machines, opts) → { assignments[], batches[], unplaceable[] }`. No side effects, no `saveAll`, no AI. Deterministic given the same inputs (stable sort, fixed tie-breaks) so the same board always yields the same proposal.

**Inputs:** the schedulable set = `printLog` filtered to `status === 'pending'` and `!_scheduleLockMachineId`, scoped to the current shop (`shopId`, per Phase 3) and location filter. Candidate machines = `machines` where `!isOffline`.

**Step 1 — Capability filter (hard).** For each job, eligible machines are those where:
- material matches `compatMaterials` (empty list = accepts all), **and**
- if `job.dimensionsMm` and `machine.buildVolume` both set → fits in all three axes, **and**
- `nozzleDiameter` / `requiredNozzleMm` mismatch downgrades to a *warning* but does not exclude.
A job with **zero** eligible machines → `unplaceable[]` (see edge cases).

**Step 2 — Order by deadline, then priority.** Sort the schedulable jobs by **`kanbanUrgencyScore(o)`** (existing, `kanban.js:114` — overdue most-negative, then days-to-due, `printTime` as a minor tiebreak), then by `priorityLevel` rank (urgent=0, high=1, normal=2), then by current `queuePos`. This reuses the exact urgency model already shown on the board, so a proposal never contradicts the kanban's own sort.

**Step 3 — Assign printer + queue position (greedy, load-balanced).** Walk jobs in the Step-2 order; maintain a per-machine running **load = Σ printTime** of jobs already proposed onto it (seed with the machine's current in-flight + queued `printTime`, the same reduction used at `kanban.js:489`). For each job, pick the eligible machine with the **lowest projected finish** (current load, capped against `targetHoursPerDay` for the overcommit flag). Proposed `queuePos` = that machine's current proposed depth. Ties broken by machine `id` (stable).

**Step 4 — Batch same-material jobs.** Within each machine's proposed queue, group contiguous jobs sharing the **same material** (and compatible nozzle) into a `batch` suggestion ("3 PLA-Black jobs, ~6.5 h, fits before the 16 Jun due date"). Batching only **reorders within a machine** to cluster identical material (reducing spool swaps); it never crosses a job ahead of an earlier deadline tier — deadline always wins over batch convenience.

**Output:** `assignments = [{ orderId, machineId, queuePos, warnings[] }]`, `batches = [{ machineId, material, orderIds[], totalPrintTime }]`, `unplaceable = [{ orderId, reason }]`.

---

## 4. Flow / UX (propose → approve → apply)

```
[Suggest assignments]  (kanban toolbar / machine view, opt-in)
        │
        ▼
 proposeSchedule(printLog, machines, opts)   ← local, deterministic, no AI
        │
        ▼
 Proposal panel  — read-only preview:
   • per machine: ordered job list with proposed queuePos
   • batch groupings highlighted (same material)
   • warnings inline (nozzle mismatch, overcommit, pin conflicts)
   • unplaceable jobs listed with the reason
        │
        ├─ operator edits a row (override machine / exclude a job)  ──┐
        │                                                            │
        ▼                                                            │
 [Apply]  ── writes ONLY on click ──┐                                │
        │                           │                                │
        ▼                           ▼                                │
 for each accepted assignment:  set order.machineId = machineId       │
                                set order.queuePos = pos,             │
                                    order.queueCol = 'pending'        │
                                saveAll(); renderKanban();  ──────────┘
```

- **Apply == the existing assignment path.** We do not add a parallel assignment mechanism: applying sets `order.machineId` (the same field the `#machineAssign` select writes, `order-flows.js:58`) and `order.queuePos`/`order.queueCol` (the same fields `setupKanbanDrag` writes, `kanban.js:107`), then `saveAll()` + `renderKanban()`. To the rest of the app a proposal is indistinguishable from a human drag + assign.
- **Partial accept.** The operator can accept some rows and reject others; rejected jobs are untouched. Per-part assignment (split orders, `order-flows.js:2098`) is honored — a job with `parts[].machineId` set is treated as already placed.
- **Reversible.** Because Apply is just field writes, the existing undo / manual drag fully overrides it afterward.
- **Optional AI tie-in (BYO key, per [AI spec](./KHAYT-3.0-AI-SPEC.md)).** With a key set, a natural-language box ("get the rush orders out by Thursday") maps to `opts` (priority weighting, due-date cutoff) that re-bias `proposeSchedule` — **the AI tunes parameters; the deterministic core still produces the assignment.** No key → the box is hidden; the button still works. AI never writes to the store (same guardrail as the quote feature).

---

## 5. Integration points (exact files / functions)

| Concern | File · symbol | Action |
|---------|---------------|--------|
| Capability fields, machine editor | `renderer/machines.js` · `openMachineEditor`, `renderMachineDropdown` | add `buildVolume {x,y,z}` inputs; read in `proposeSchedule` |
| Material compat rule | `renderer/order-flows.js:796` (compat warn) | extract the substring/case-insensitive match into a shared `machineAcceptsMaterial(machine, material)` helper, reused by both |
| Deadline ordering | `renderer/kanban.js:114` · `kanbanUrgencyScore` | reuse verbatim as the Step-2 sort key |
| Queue position | `renderer/kanban.js:36,107` · `kanbanQueuePos`, drag drop | Apply writes `queuePos`/`queueCol` exactly as the drag handler does |
| Machine assignment | `renderer/order-flows.js:58` · `machineId` write | Apply writes `order.machineId` (no new assignment fn) |
| Per-machine load / ETA | `renderer/kanban.js:489,610` · `printTime` sums, `printingStartedAt` ETA | seed Step-3 load; show projected finish |
| Live printer state | `machineStatusCache` (`app-state.js:259`, polled in `app-boot.js`) | optional: treat an API-reported `error`/paused state as offline for the proposal |
| New module | `renderer/scheduler.js` (new, `(function(global){…})` pattern) | houses `proposeSchedule` + panel render; exported on `global` like other renderer modules |

---

## 6. Edge cases

- **No capable printer for a job** → goes to `unplaceable[]` with a precise reason ("no machine supports Nylon" / "exceeds every build volume"). Never silently assigned to an incompatible machine. Panel suggests the fix (add the material to a machine's `compatMaterials`).
- **Overcommit** → if a machine's proposed `Σ printTime` exceeds `targetHoursPerDay` (where set) before the earliest due date, the row is flagged "over capacity — may miss <date>"; the proposal still stands (assistive, not blocking) but spills the surplus to the next-best eligible machine when one exists.
- **Paused / offline machine** (`isOffline`, or live API error/paused via `machineStatusCache`) → excluded from candidates; jobs already pinned to it surface a "machine paused — reassign?" warning rather than a forced move.
- **Already-assigned / pinned jobs** (`machineId` set, or `_scheduleLockMachineId`, or `parts[].machineId`) → treated as fixed; counted toward machine load but not re-proposed unless the operator clears the pin.
- **No due dates** → `kanbanUrgencyScore` already handles `!dueDate` (large positive bucket); ordering falls back to priority then `queuePos`. Feature still works.
- **No capability data anywhere** (empty `compatMaterials`, no `buildVolume`) → every machine is eligible; scheduler degrades to pure load-balancing by deadline — still useful, never errors.
- **Empty queue / single machine** → trivial proposal (or "nothing to schedule"); no crash.

---

## 7. Test plan & DoD

- **Capability filter:** a Nylon job with one Nylon-capable machine is proposed only there; with none → `unplaceable` with the right reason (no assignment).
- **Deadline ordering:** given mixed due dates + priorities, proposed order equals `kanbanUrgencyScore` sort (assert against the same function the board uses — no divergence).
- **Load balancing:** N same-capability jobs across M idle machines distribute by lowest projected finish, deterministically (same input → same output, stable tie-break).
- **Batching:** contiguous same-material jobs on a machine are grouped; a batch is **never** allowed to push a later-material job ahead of an earlier deadline tier.
- **Apply == manual:** after Apply, `order.machineId`/`queuePos`/`queueCol` are byte-identical to what a manual assign + drag would produce; `renderKanban` shows the same board (snapshot test).
- **Human-in-the-loop:** computing a proposal mutates nothing (assert `printLog` unchanged until Apply); partial accept leaves rejected jobs untouched.
- **Overcommit / paused:** over-`targetHoursPerDay` is flagged not blocked; offline machines never receive a proposal.
- **No-AI / cloud-off:** full feature with no key and no network (model mocked / absent); AI box hidden, button works.
- **Shop scope:** in a multi-shop org, a proposal only considers the current shop's `printLog`/`machines` (Phase 3 isolation).

**DoD:** an operator clicks **Suggest assignments**, sees a capability-valid, deadline-ordered, batch-aware proposal with clear warnings and unplaceable jobs called out, edits freely, and **Apply** places jobs using the existing `machineId` + `queuePos`/`queueCol` path — nothing moves without that click. The core is fully deterministic and works with no cloud and no AI key; an AI key only adds natural-language parameter tuning, never autonomous writes.
