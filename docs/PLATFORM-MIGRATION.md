# Platform & language strategy (decision record)

**Status:** Decision for Khayt **today** — stay on **Electron + Node.js**. Revisit only with evidence, not as a default rewrite.

**Last updated:** 2026-06-04

---

## Current stack

| Layer | Technology |
|-------|------------|
| Desktop shell | [Electron](https://www.electronjs.org/) |
| UI | HTML/CSS/JS (`renderer/`, Studio shell) |
| Main process | Node.js (`main.js`, `lib/*`) |
| Data | Local `store.json` (+ encryption / keychain) |
| LAN / Online | Node HTTP (`lib/lan-server.js`) |
| Tests | `node --test`, E2E smoke |
| Ship | `electron-builder` (macOS arm64/x64, Windows, Linux) |

One codebase ships **macOS, Windows, and Linux**. Feature work (solo maker, print farm, ZATCA, LAN intake) lives here.

---

## Question we considered

> Should we rewrite Khayt as **Swift on Mac** and **C++ on Windows and Linux**?

### Verdict: **No** (as a full product rewrite)

| Approach | Maintenance | Fit for Khayt |
|----------|-------------|---------------|
| **Electron (keep)** | 1 UI, 1 business-logic tree | **Best** for offline shop app, fast iteration, 3 OS from one team |
| **Swift (macOS) + C++ (Win/Linux)** | **3** UI stacks + 3 integration layers | **Poor** — Swift does not run on Win/Linux; C++ desktop still needs Qt/GTK/etc. |
| **SwiftUI macOS-only** | 1 platform | Only if we **exit** Win/Linux |
| **Three native UIs (Swift / C# / GTK)** | 3× every feature | Only with a large multi-platform team |

Khayt is a **business operations app** (queue, invoicing, inventory, integrations), not a performance-critical runtime (game engine, CAD kernel). Pain points so far (settings wiring, release hold, signing) are **engineering process**, not proof that JavaScript cannot support print farms.

---

## When to **stay** on Electron (default)

Stay unless **all** of these are true:

1. A **measured** problem (startup time, memory, CPU under real farm load, LAN limits) — not preference alone  
2. The problem **cannot** be fixed incrementally (profiling, smaller main process, lazy tabs, native module for one hotspot)  
3. We accept **months** of feature freeze or parallel “v2 native” cost  
4. We have a written **parity checklist** (ZATCA, LAN, store migrate, 7 locales, operators, locations, updater, etc.)

Until then: ship on `main`, soak test, tag when [RELEASE-HOLD.md](./RELEASE-HOLD.md) lifts.

---

## If we revisit migration later (ordered options)

Prefer **one** path — not “Swift + C++ per OS.”

### Option A — **Stay Electron, extract shared core** (lowest risk)

- Move pure logic to **TypeScript** or **Rust** crate: store validation, pricing, ZATCA TLV, sync engine (future cloud)  
- Electron keeps UI; main process calls the library  
- **When:** need stricter correctness or shared code with a future cloud service  

### Option B — **Tauri** (Rust shell + existing web UI)

- Keep `renderer/` largely as-is; replace Chromium+Node packaging with Tauri  
- **Pros:** smaller downloads, one UI codebase, Rust for sensitive I/O  
- **Cons:** migration project; rewrite main-process IPC and LAN server integration  
- **When:** binary size / security posture matters; team willing to learn Rust  

### Option C — **macOS SwiftUI companion** (additive)

- iOS/macOS **read-only** or intake companion; desktop remains Electron  
- **When:** mobile/LAN companion (#54-style), not desktop replacement  

### Option D — **Full native desktop rewrite**

- Single framework with real cross-platform UI (e.g. **Qt** / **.NET MAUI**) — still one product language, not Swift+C++ split  
- **When:** Electron blocked by policy or insurmountable perf; **large** budget  
- **Not recommended** for Khayt’s current stage  

### Ruled out for Khayt desktop

- **Swift + C++ per OS** — three products, no shared UI, highest drift risk  
- **Rewrite for “feel more native”** alone — macOS already uses standard keychain, dialogs, titlebar via Electron APIs  

---

## Decision triggers (objective)

| Signal | Possible response |
|--------|------------------|
| App startup > 5s on M1 with warm cache | Profile; defer heavy work; don’t rewrite |
| LAN + 20 printers unstable | Fix `lan-server.js`; add load tests |
| DMG size / memory complaints | Tauri evaluation (Option B) |
| Mac App Store requires APIs Electron lacks | Targeted native helper or Option C/D for Mac only |
| Khayt Cloud needs shared sync core | Option A (Rust/TS core) **before** new UI |
| Solo maintainer, feature roadmap busy | **Stay Electron** |

---

## Action items (now)

- [x] Record this decision (this file)  
- [ ] Complete ~1 week soak on `main` (`npm start`) before **v2.3.3**  
- [ ] Finish print-farm local batch ([FARM-FEATURES.md](./FARM-FEATURES.md))  
- [ ] Defer Khayt Cloud UI until [MULTI-SHOP-CLOUD.md](./MULTI-SHOP-CLOUD.md) product answers  
- [ ] Re-run this doc if post–v2.3.3 metrics or team size change  

---

## Related docs

- [FARM-FEATURES.md](./FARM-FEATURES.md) — multi-site on one machine (no rewrite needed)  
- [MULTI-SHOP-CLOUD.md](./MULTI-SHOP-CLOUD.md) — future sync (separate from desktop language)  
- [RELEASE-HOLD.md](./RELEASE-HOLD.md) — when installers update  
