# AI prompt: redesign Khayt iOS Companion UI

Copy everything inside the fenced block below into ChatGPT, Claude, Figma AI, or another design tool. Attach screenshots of the current app if you have them.

---

```
You are a senior product designer + iOS SwiftUI specialist. Redesign the UI/UX for **Khayt Companion** — a native iPhone app for 3D print shop owners that connects over **local Wi‑Fi only** to the Khayt desktop app (Electron). It is NOT a full clone of desktop Khayt.

## Product context

- **Users:** Shop owner / operator on the print floor, often one hand, quick glances, gloves, bright/dim garage lighting.
- **Jobs-to-be-done (priority order):**
  1. See shop pulse: queue size, what’s printing, completed today
  2. Move orders through kanban: Pending → Printing → Post → QC → Completed
  3. Check / add filament inventory (scan label photo, NFC tag, or manual)
  4. Glance at printer machine status
  5. Pair phone to desktop once (IP + LAN PIN)
- **Trust:** Data lives on desktop; phone is a remote control. Must feel **connected / disconnected** clearly.
- **Brand:** Khayt — modern print-shop ops, bilingual-friendly (English + Arabic labels on spools). Primary accent today: soft indigo ~#6366F1.

## Technical constraints (do not violate)

- **SwiftUI**, iOS 17+, iPhone portrait-first
- **LAN-only** — no cloud account UI
- **Tabs today:** Home (dashboard), Orders (active queue + recent history), Inventory, Machines, Settings
- **No** invoicing, ZATCA, tax, calculator, or full desktop settings in v1
- **Native capabilities to highlight in UI:** NFC tap, camera label OCR, Keychain PIN, haptics on status change
- **Accessibility:** Dynamic Type, sufficient contrast, 44pt touch targets on floor

## Current feature set (must remain reachable)

| Area | Features |
|------|----------|
| Home | Stat cards (queued, printing, post, QC, completed today), low-stock alert, quick actions (add spool, orders, inventory), active order preview |
| Orders | Segmented: **Active** (filter chips: All / Pending / Printing / …) + **Recent** (order log); tap row → detail sheet with advance + set status |
| Inventory | Search, filter low stock, sort; tap spool → detail (SKU, lot, temps); + add spool sheet (scan photo / NFC / manual) |
| Machines | List printers with status chips |
| Settings | LAN host, port, PIN, connection test, unpair |
| Onboarding | 4-step pairing wizard |

## Deliverables I need from you

1. **Design direction** — One paragraph positioning (e.g. “calm control room” vs “bold factory dashboard”) and 3 reference apps (with why).

2. **Design system**
   - Color roles (background, surface, brand, success, warning, status colors per kanban stage)
   - Typography scale (large numbers for stats, readable captions)
   - Corner radius, spacing grid (4/8/12/16/24)
   - Icon style (SF Symbols mapping per screen)
   - Light + **dark** mode specs

3. **Information architecture**
   - Confirm or propose tab structure (max 5 tabs)
   - Proposed navigation map (Mermaid or ASCII)

4. **Screen designs** (describe in detail or provide Figma-style frames):
   - Home / dashboard
   - Orders (active + recent)
   - Order detail (bottom sheet or full screen — pick one and justify)
   - Inventory list + spool detail
   - Add spool flow (method picker → camera / NFC / form)
   - Machines
   - Settings + pairing wizard
   - Empty, loading, and error states
   - **Disconnected** state (desktop offline / wrong PIN)

5. **Key UX improvements** over current generic SwiftUI lists:
   - Floor-friendly **one-thumb** actions (advance order without drilling into menus)
   - **At-a-glance** kanban strip or timeline on Home
   - Low-stock and overdue due dates as **actionable alerts**, not buried lists
   - Label scan: make **Photo mode** the hero; show live capture preview
   - Optional: widget concept (queue count + connection dot)

6. **SwiftUI implementation notes**
   - Which components to build (`KanbanStrip`, `StatHero`, `ConnectionBanner`, etc.)
   - Animation/motion principles (subtle, &lt;300ms, respect Reduce Motion)
   - Do NOT write full app code — wireframe-level component list + 2–3 sample `View` pseudocode snippets max

7. **Localization** — Layout must tolerate **Arabic RTL** for labels/descriptions (strings may be Arabic later); keep numerals and status chips LTR-friendly.

## Anti-patterns to avoid

- Generic “AI slop” purple gradient on white cards with no hierarchy
- Hamburger menus hiding primary actions
- Desktop-density tables on phone
- Requiring cloud login or account creation
- Hiding connection/PIN errors

## Output format

Use clear headings, bullet lists, and ASCII or Mermaid wireframes where helpful. If you propose visual mocks, describe them precisely enough that a developer can implement in SwiftUI without guessing colors or spacing.

Start by asking 0 clarifying questions — assume a small FDM print farm (2–8 printers) in Saudi Arabia / GCC using Khayt desktop in English or Arabic.
```

---

## After you get a design back

1. Share the response with your dev agent or implement in `ios/KhaytCompanion/Theme/`.
2. Replace `CompanionTheme.swift` tokens with the new system.
3. Refactor views screen-by-screen (Home → Orders → Inventory first).
4. Keep `docs/LAN_API.md` behavior unchanged unless you add new API features.

## Related docs

- [IOS_COMPANION.md](./IOS_COMPANION.md) — scope and architecture  
- [LAN_API.md](./LAN_API.md) — endpoints the UI must call
