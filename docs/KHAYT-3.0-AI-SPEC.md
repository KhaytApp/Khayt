# AI assist — flagship spec (quote from description/photo)

**Scope:** the first AI feature. **Cloud-independent** — works with a BYO Anthropic API key, no Khayt Cloud account, no internet platform. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) §5.1. Can ship **before** Phase 0/1.

**Governing principle:** AI **fills the quote form**; the **existing calculator computes the price**. The model never invents a number, never finalizes a quote, never writes to the store. Owner reviews and edits everything before it's saved or sent.

---

## 1. The contract (why this is safe)

The quote calculator is deterministic (`lib/calculator-cost.js → computePartBaseCost(part)`), consuming a `part`:

```
part = { qty, filamentId | spoolCost+spoolWeight, printWeight, supportWeight,
         printTime, prepTime, postTime, extraMaterials[], priceTiers[],
         wearRate, powerDraw, elecRate, laborRate, failureRate }
```

The **physical** fields (qty, material, printWeight, printTime, dimensions/complexity) are what a human normally eyeballs from a customer request. The **rate** fields (wearRate, elecRate, laborRate, …) come from settings defaults, untouched by AI.

**AI's job:** read the request → produce the *physical* fields + an explicit confidence/assumptions note. **Calculator's job:** turn that `part` into a cost. **Owner's job:** review, correct, apply margin, send.

---

## 2. Flow

```
Customer request (text and/or image)
        │
        ▼
 [AI extract]  Claude with structured output (tool/JSON schema)
        │      → { qty, materialGuess, printWeightG, printTimeMin,
        │          dimensionsMm?, complexity, assumptions[], confidence }
        ▼
 [Map]  materialGuess → matched inventory filamentId (fuzzy) or prompt user
        │   merge with settings rate defaults → full `part`
        ▼
 [computePartBaseCost(part)]  ← deterministic price (existing code)
        ▼
 [Quote form, pre-filled]  owner sees AI assumptions inline, edits, sets margin
        ▼
 [Owner saves/sends]  ← normal existing quote path; AI is out of the loop here
```

---

## 3. Model call

- **SDK/transport:** Anthropic Messages API, **tool use / structured output** so the model returns a validated object (not prose to parse). The tool schema mirrors §2's extract shape.
- **Model:** default to the latest capable Claude (e.g. Opus/Sonnet 4.x); configurable. Vision-capable model when a photo is attached.
- **Prompt:** system prompt states the shop's materials (from inventory), units (grams/minutes/mm), and that it must return ranges + assumptions, never a price. Few-shot with 2–3 example requests.
- **Input:** the request text and/or image (base64); a compact list of the shop's available materials so `materialGuess` maps to real stock.
- **Output validation:** reject/repair if the structured object is missing required fields; never feed an unvalidated object to the calculator.

---

## 4. BYO key & settings

- **Settings → AI assist** (new, opt-in, off by default): paste Anthropic API key → stored with the **existing encrypted-secret pattern** (masked, redacted from exports — same as ZATCA/SMTP/BNPL keys).
- Model picker + a monthly spend reminder (display only; cost is on the user's own Anthropic account).
- **No key → the feature is hidden/disabled; the app is unaffected.** Same graceful-degradation rule as every cloud-optional feature.

---

## 5. Guardrails

- **Human-in-the-loop, always** — AI output lands in an editable form; nothing is saved/sent without an explicit owner action.
- **AI never touches the store or the price math** — it only proposes form values.
- **Assumptions surfaced** — every inferred field shows the AI's assumption ("assumed 40 g at 0.2 mm, ~90 min") so the owner can correct at a glance.
- **Confidence gating** — low confidence → flag fields for review rather than silently filling.
- **Privacy** — the request text/image goes to Anthropic (the user's own key); make this explicit in the UI. No shop data beyond the material list is sent. Honors the same "leaves only when you say so" stance.
- **Failure** — API error/timeout → fall back to the blank manual quote form with a non-blocking notice. Never blocks quoting.

---

## 6. Follow-on AI features (same key, later)

Sequenced after the flagship proves the BYO-key plumbing:
2. **Message drafting (AR/EN)** — quote/follow-up/ready-for-pickup text in the shop's voice; plugs into the existing quote-follow-up automation.
3. **Natural-language analytics** — questions over already-computed metrics (read-only).
4. **Smart reorder / demand forecast** — from order history + spool burn-down.

Each is independently opt-in and degrades gracefully.

---

## 7. Test plan & DoD

- **Extraction → calculator:** a fixed request + stubbed model response → produces a `part` → `computePartBaseCost` returns the expected deterministic cost (model mocked; no network in tests).
- **Schema validation:** malformed model output is rejected/repaired, never reaches the calculator.
- **Material mapping:** `materialGuess` matches an inventory item; unmatched → prompts rather than guessing a price.
- **No-key:** feature hidden; app behavior unchanged (assert).
- **Secret handling:** API key masked in UI, redacted from export (reuse existing secret tests).
- **Failure path:** API error → manual form, no crash, no partial save.

**DoD:** with a key set, a text/photo request pre-fills an editable, calculator-priced quote with visible assumptions; with no key, zero change to the app. AI never finalizes or persists anything autonomously.
