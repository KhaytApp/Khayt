# Preventive-maintenance scheduler — spec

**Scope:** hours-based (and optional date-based) recurring maintenance reminders per printer — nozzle replacement, belt tension, lubrication, etc. — built on the existing maintenance log, surfaced through the existing notification centre. Implements the PM line item in the [roadmap](./KHAYT-3.0-ROADMAP.md).

**Governing principle:** **Fully local, opt-in per machine.** This **extends, never replaces, `machMaintLog`** — completing a scheduled task writes an ordinary `machMaintLog` entry, so existing analytics (`renderer/analytics.js` maintenance-cost roll-ups) keep working untouched. It generalizes today's single `serviceInterval`/`lastServiceHours` pair (one generic "service" per machine in `renderer/machines.js`) into N named recurring tasks. A machine with no tasks defined behaves exactly as it does today.

---

## 1. The contract (why this is safe)

Today (`renderer/machines.js`):
- `machineHoursMeter(machineId)` = Σ `printTime` over completed orders for that machine — the single source of run-hours.
- `machineServiceStatus(machine)` compares `machineHoursMeter − lastServiceHours` against `machine.serviceInterval`, returning `{ due | warning | ok }`.
- `logMachineService()` sets `machine.lastServiceHours = totalHrs` and unshifts a `machMaintLog` entry.

The scheduler keeps this exact pattern but per-task: each task carries its own interval and its own `lastDoneHours`, all measured against the **same** `machineHoursMeter`. No new clock, no new units (hours from `printTime`, days from calendar).

---

## 2. Data model

New collection `machMaintTasks` (array), persisted via the existing `loadJSON`/`saveAll` + `K.*` key pattern in `renderer/app-state.js`; add to the store snapshot, reset/import lists, and `store-validate.js` allow-list alongside `machMaintLog`.

```
MaintTask = {
  id,                  // uid('MTASK')
  machineId,           // FK → machines[].id
  task,                // label, e.g. "Replace nozzle" (free text or preset key)
  enabled,             // opt-in toggle; default true on create
  intervalHours,       // > 0 → hours-based; 0/undefined → not hours-driven
  intervalDays,        // > 0 → also/instead date-based; optional
  lastDoneAt,          // ISO date of last completion (date-based clock)
  lastDoneHours,       // machineHoursMeter snapshot at last completion (hours clock)
  warnAtFraction,      // default 0.9 (matches existing "service soon" threshold)
  snoozedUntil,        // ISO date; reminder suppressed until then (optional)
  notes                // optional default note prefilled into the log entry
}
```

Run-hours are **not stored on the task**; they are always recomputed from `machineHoursMeter(machineId)` so the meter and the schedule cannot drift. `lastDoneHours` is the only hours snapshot persisted.

**Per-task status** (mirror of `machineServiceStatus`, returns the worse of the two clocks):
```
hoursSince = machineHoursMeter(machineId) − (lastDoneHours || 0)
daysSince  = today − (lastDoneAt || machine-created)
due      = (intervalHours>0 && hoursSince >= intervalHours) ||
           (intervalDays>0  && daysSince  >= intervalDays)
warning  = !due && over warnAtFraction of either active interval
```
Snoozed tasks (`snoozedUntil > today`) report `ok` regardless.

---

## 3. Flow / UX

```
[Machine editor] opt-in → add recurring tasks (task, intervalHours, intervalDays?)
        │                  (lives next to today's serviceInterval field in renderer/machines.js)
        ▼
[Orders complete] printTime accrues into machineHoursMeter  ← no new wiring
        ▼
[buildNotifications()] per enabled task: status → due/warning → notification
        │   icon 🔧, type 'service' (reuse existing group), body "Nozzle due — Printer A (612h)"
        ▼
[Notification row click] → opens the machine's maintenance modal (openMaintLog)
        ▼
[Mark done]  sets lastDoneHours = machineHoursMeter, lastDoneAt = today,
             clears snoozedUntil, unshifts a machMaintLog entry {date, note=task, cost}
        ▼
[Reminder clears] next status recompute returns ok; reschedules from the new snapshot
```

- Task management UI sits in the existing machine editor (`openMachineEditor`) as a small "Maintenance schedule" list (add/edit/delete/toggle rows), under the current Service-interval inputs.
- "Mark done" reuses the same write the manual log uses (`machMaintLog.unshift({ id: uid('MAINT'), machineId, date, note, cost })`), with optional "add as expense" checkbox identical to `openMaintLog`.
- The maintenance modal (`openMaintLog`) gains a top section listing scheduled tasks with their status badge and a per-task "Mark done" button; the free-form history table below is unchanged.

---

## 4. Run-hours accounting

1. **Primary — order `printTime` (existing, unchanged):** `machineHoursMeter` already sums `printTime` over completed orders. Completion captures `actualPrintTime` via `promptActuals` (`renderer/order-flows.js`); meter should prefer `actualPrintTime ?? printTime` so corrected times feed the schedule. (One-line change in `machineHoursMeter`, benefitting today's service status too.)
2. **Optional — printer-API polling (where present):** machines with live polling already populate `printerStatusCache` every 30s (`main.js hub:start-printer-polling`). A future enhancement may accrue hours from observed printing time for API-connected machines that aren't logged as orders; **out of scope for v1** — v1 relies solely on `printTime`. The data model is forward-compatible (a `polledHours` accumulator could add into the meter later without schema change to tasks).

No background timer is added: status is recomputed lazily inside `buildNotifications()` on the existing notification refresh cadence (same as machine-service alerts today).

---

## 5. Integration points (exact)

- `renderer/app-state.js` — declare `machMaintTasks`, add `K.MTASKS`, include in store snapshot / reset / import filters (model after `machMaintLog`).
- `lib/store-validate.js` — add `machMaintTasks` to the collection allow-list and `isPlainObject` map.
- `renderer/machines.js` — add `machineMaintTaskStatus(task)` next to `machineServiceStatus`; extend `openMachineEditor` with the task list; extend `openMaintLog` with the scheduled-task section + "Mark done"; export new helpers from the module `api`.
- `renderer/notifications.js` — in `buildNotifications()` §4 (Machines due for service) loop, also iterate `machMaintTasks.filter(t => t.enabled)`, push per-task alerts (`type:'service'`, `key:'mtask:'+task.id`), honoring `isDismissed` + `snoozedUntil`. Snooze reuses the existing dismiss machinery.
- `renderer/order-flows.js` — no change required (meter reads its data); only the `machineHoursMeter` `actualPrintTime` preference touches this domain.
- `renderer/settings.js` — add `machMaintTasks = []` to the data-reset path beside `machMaintLog`.
- i18n — add `maint.schedule.*` / `notif.mtask_*` keys (AR + EN) following existing `maint.*` / `notif.*` keys.

---

## 6. Edge cases

- **Machine reset / replacement:** deleting a machine (`deleteMachine`) must also drop its `machMaintTasks` (and leave `machMaintLog` history intact, as today). Replacing a printer = new machine id → fresh tasks; old log/tasks stay with the retired machine.
- **Hours unknown / no orders yet:** `machineHoursMeter` returns 0 → no hours-based task fires; date-based tasks still run from `lastDoneAt` (falling back to first-seen date). Hours-only tasks simply stay `ok`.
- **Meter goes backwards** (orders deleted, lower than `lastDoneHours`): clamp `hoursSince = max(0, …)` so a task never shows perpetually due.
- **Snooze:** per-task `snoozedUntil` (e.g. "remind me in 3 days") plus the global notification "Snooze until tomorrow" / "Snooze all" already in `notifications.js` — both supported; snooze never clears the underlying due state, it only hides the reminder.
- **Both intervals set:** task is due when **either** clock trips; "Mark done" resets both snapshots together.
- **Disabled / opt-out:** `enabled:false` (or deleting the task) removes it from notifications immediately; existing log entries remain.
- **Interval edited downward** past current usage → task may become immediately due; that is correct and surfaces on next refresh.

---

## 7. Test plan & DoD

- **Status math (pure):** given a machine with completed orders summing to known `printTime`, a task with `intervalHours` and `lastDoneHours` produces `ok` / `warning` (≥ `warnAtFraction`) / `due` at the expected thresholds — mirror existing `machineServiceStatus` tests.
- **Date-based:** task with only `intervalDays` goes due on the calendar boundary; hours absent.
- **Mark done:** writes exactly one `machMaintLog` entry, sets `lastDoneHours`/`lastDoneAt`, clears snooze, and the next status recompute returns `ok`.
- **Notification wiring:** an overdue task appears in `buildNotifications()` under the service group with a stable `mtask:` key; dismiss/snooze suppresses it per the existing rules.
- **Backwards meter / no orders:** zero or decreased hours never produce a false "due".
- **Persistence:** `machMaintTasks` survives save → reload, passes `store-validate`, and is dropped on machine delete and on data reset.
- **No-task regression:** a machine with no tasks behaves identically to current build; existing `serviceInterval` service alert still fires.

**DoD:** an owner can opt a machine in, define recurring hours/date tasks, see due/overdue reminders accrue from real order `printTime` in the existing notification centre, and mark a task done — which logs to `machMaintLog`, clears the reminder, and reschedules. With no tasks defined, the app is unchanged. Everything stays local; nothing leaves the device.
