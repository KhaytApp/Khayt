import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Drafting a message to a customer

    /// The number to open WhatsApp on, or empty.
    ///
    /// From the CUSTOMER RECORD, never from the job: a job carries a name, and
    /// a name is not something to dial. A job with no customer record has no
    /// number, which the sheet says out loud rather than showing a dead button.
    func customerPhone(for job: Order) -> String {
        guard let id = job.clientId, !id.isEmpty else { return "" }
        return clients.first { $0.id == id }?.phone ?? ""
    }

    /// One of the shop's messages, with this job's facts in it.
    ///
    /// The SUBSTITUTION is `WaTemplate` — which placeholders exist and what
    /// stands in for a blank — shared with the other app, because a template
    /// written there is sent from here and a placeholder this app did not know
    /// would go out with braces in it, to a customer.
    ///
    /// The FORMATTING is this app's: a price is written the way every other
    /// figure on this screen is written, and the status is the word this app
    /// uses for that stage rather than the raw field.
    func fillMessage(_ template: MessageTemplate, for job: Order) -> String {
        let name = job.client.isEmpty ? job.project : job.client
        let stage = Stage.of(job)
        return WaTemplate.fill(template.body, values: [
            "client": name,
            "id": job.id,
            "price": Money.figure(job.price),
            "currency": Money.mark(currency),
            "due": job.dueDate ?? "",
            "status": stage.map { words.callIt("queue." + $0.rawValue, fallback: $0.rawValue) } ?? "",
        ])
    }

    /// Draft one, or say why not.
    ///
    /// Returns the text for the shop to read and change. NOTHING IS SENT: this
    /// app cannot email, and a drafted message a shop has not read is not a
    /// message anyone should be sending on its behalf anyway.
    func draftMessage(for job: Order, intent: String, note: String) async -> DraftOutcomeText {
        guard let row = orderRow(job.id) else { return .refused(words.callIt("mac.move_gone")) }
        do {
            // The NAME only. The customer record has an email, a phone and an
            // address on it; the disclosure does not name them and they are not
            // the shop's to send on that person's behalf.
            let text = try await AiClient.draftReply(
                order: row, clientName: job.client, intent: intent, note: note, shop: self)
            Telemetry.feature(.aiReplyDrafted, in: self)
            return .drafted(text)
        } catch AiClient.Failure.notConsented {
            return .refused(words.callIt("mac.ai_reply_not_consented"))
        } catch AiClient.Failure.noKey {
            return .refused(words.callIt("mac.ai_no_key"))
        } catch {
            return .refused(self.said(error))
        }
    }

    enum DraftOutcomeText: Sendable {
        case drafted(String)
        case refused(String)
    }

    // MARK: - Asking about the book

    /// The collections the assistant's summary is built from.
    ///
    /// Named rather than handing over the whole store: the summary is the only
    /// thing that leaves the building, and it is built from these four. A shop
    /// asking "what does it send?" is owed a list, and this is it.
    var bookForAssistant: [String: JSONValue] {
        ["printLog": .array(orderRows),
         "inventory": .array(inventoryRows),
         "clients": .array(clientRows),
         "settings": settingsValue]
    }

    /// One question and its answer, kept so a follow-up resolves.
    struct AskedTurn: Identifiable, Sendable {
        let id = UUID()
        let question: String
        var answer: String?
        var problem: String?
    }

    /// Ask the assistant, keeping the conversation so "and last month?" works.
    func ask(_ question: String) async {
        // ASK THE BOOK answers from a summary of the shop's money — revenue,
        // margins, who owes what — so it is the shop's figures by another
        // door, and asks what Reports asks (`analytics`; alpha.62 re-check,
        // round 3). Refused, not answered from a stripped summary: an
        // assistant without the money answers money questions wrongly.
        guard lockAllows("analytics", "view") else { askingTheBook = false; return }
        let said = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !asking else { return }
        asking = true
        defer { asking = false }
        asked.append(AskedTurn(question: said))
        let at = asked.count - 1

        // The turns BEFORE this one, which is what lets a follow-up resolve.
        let history: [JSONValue] = asked.dropLast().compactMap { turn in
            guard let answer = turn.answer else { return nil }
            return .object(["q": .string(turn.question), "a": .string(answer)])
        }
        do {
            asked[at].answer = try await AiClient.ask(said, history: history, shop: self)
            Telemetry.feature(.askTheBookUsed, in: self)
        } catch AiClient.Failure.notConsented {
            asked[at].problem = words.callIt("mac.ai_assistant_not_consented")
        } catch AiClient.Failure.noKey {
            asked[at].problem = words.callIt("mac.ai_no_key")
        } catch {
            asked[at].problem = self.said(error)
        }
    }

    func forgetConversation() { asked = [] }

    // MARK: - Drafting a quote from a description

    /// The AI features this app can actually perform.
    ///
    /// ── A LIST, BECAUSE THE ALTERNATIVE WAS A CAVEAT THAT OUTLIVED ITSELF ─
    ///
    /// The assistant pane carried one sentence over the whole list saying these
    /// run in the other app. It was true when it was written and false the hour
    /// `quote` started working here, which is how a caveat becomes a lie.
    ///
    /// So the pane asks this instead, per feature, and the note disappears from
    /// each one as it lands. ADD AN ID HERE when its feature can run — the note
    /// is the only thing telling a shop the switch does nothing on this Mac,
    /// and leaving it on a working feature is as wrong as dropping it from a
    /// missing one.
    ///
    /// ALL FOUR, as of 2026-09-21. This said `["quote"]` long after the other
    /// three had been built, so Settings told a shop that price advice, the
    /// drafted reply and the assistant "run in the Windows and Linux app for
    /// now" while this Mac was performing all three. Each has a complete chain
    /// — a view, a `Shop` method, `AiClient`, an engine bridge and the shared
    /// rule:
    ///
    ///   quote      NewJobSheet.draftPartFromDescription -> AiClient.draftQuote
    ///   price      NewJobSheet.recommendMargin          -> AiClient.recommendMargin
    ///   reply      DraftMessageSheet.draftMessage       -> AiClient.draftReply
    ///   assistant  AskTheBook.ask                       -> AiClient.ask
    ///
    /// The comment above already said leaving the note on a working feature is
    /// as wrong as dropping it from a missing one. It was, for three of them.
    ///   library    rescanLinkedFolders / previewLinkedSort -> askAssistantToSort -> AiClient.sortFolders
    ///   pictures   rescanLinkedFolders / previewLinkedSort -> checkPictures -> AiClient.checkPicture
    static let aiFeaturesOnThisMac: Set<String> = ["quote", "price", "reply", "assistant", "library", "pictures"]

    static func aiRunsHere(_ id: String) -> Bool { aiFeaturesOnThisMac.contains(id) }

    /// Has the shop actually agreed to this, on this book?
    ///
    /// Asked of the shared rule rather than worked out from the settings here.
    /// `isFeatureEnabled` reads the master switch, the per-feature answer AND
    /// the consent migration — a Swift copy would be a fourth place for the
    /// three to disagree, and the one that decides whether data leaves.
    var aiCanDraftQuotes: Bool { aiQuoteAllowed }

    /// What came back, in the shape the sheet's own form takes.
    struct DraftedPart: Sendable {
        var qty: Int
        var grams: Double
        var hours: Double
        var spoolId: String?
        var assumptions: [String]
    }

    /// Either a filled form or a sentence saying why not.
    ///
    /// A sentence rather than a thrown error, because every way this can go
    /// wrong is something the shop has to READ: a feature it has not switched
    /// on, a key it has not set, a provider that refused, a network that did
    /// not answer. A spinner that stops with nothing said is the one outcome
    /// that teaches people the button is broken.
    enum DraftOutcome: Sendable {
        case filled(DraftedPart)
        case refused(String)
    }

    /// Ask the assistant to fill a part from a description.
    func draftPartFromDescription(_ said: String) async -> DraftOutcome {
        guard let engine else { return .refused(words.callIt("mac.move_no_engine")) }
        do {
            let draft = try await AiClient.draftQuote(said, shop: self)
            // `defaults` are the shop's RATE fields — Khayt's figures with the
            // shop's own tariff over them (`defaultsFor`), never the model's.
            // This screen still costs the part with `costedPart`, the same call
            // a hand-typed part goes through, so these only keep the drafted
            // part's rate fields from reading as zero.
            let rateDefaults = (try? await engine.printRateDefaults(settings: settingsDict)) ?? [:]
            let out = try await engine.aiQuoteToPart(
                draft: draft, inventory: inventoryRows,
                defaults: rateDefaults.mapValues { .number($0) }, reclaimsTax: reclaimsTax)
            guard case .object(let o) = out, case .object(let part)? = o["part"] else {
                return .refused(words.callIt("mac.ai_no_draft"))
            }
            var notes: [String] = []
            if case .array(let list)? = o["assumptions"] {
                notes = list.compactMap(Self.plainString)
            }
            Telemetry.feature(.aiExtractUsed, in: self)
            return .filled(DraftedPart(
                qty: max(1, min(9999, Int(saturating: Self.plainNumber(part["qty"]) ?? 1))),
                grams: Self.plainNumber(part["printWeight"]) ?? 0,
                hours: Self.plainNumber(part["printTime"]) ?? 0,
                spoolId: Self.plainString(part["filamentId"]),
                assumptions: notes))
        } catch AiClient.Failure.notConsented {
            return .refused(words.callIt("mac.ai_not_consented"))
        } catch AiClient.Failure.noKey {
            return .refused(words.callIt("mac.ai_no_key"))
        } catch {
            return .refused(self.said(error))
        }
    }

    /// A product's pictures, read the way the shared rule reads them.
    ///
    /// Never by pulling `images` off the record: a product can carry the legacy
    /// `imagePath`/`thumbnail` pair, the array, or BOTH — an older build
    /// editing a record a newer one saved writes the legacy fields and leaves
    /// the array behind — and deciding which wins is exactly the migration
    /// `lib/product-images.js` exists to own.
    /// Every picture file named by a product OTHER than `productId` — the
    /// legacy `imagePath` and each `images[].path`, by file name. What a save
    /// or a delete of `productId` must never rewrite or unlink.
    func pictureFilesOfOtherProducts(than productId: String) -> Set<String> {
        Self.pictureFiles(in: productRows, except: productId)
    }

    static func pictureFiles(in productRows: [JSONValue], except productId: String) -> Set<String> {
        var names: Set<String> = []
        for row in productRows {
            guard case .object(let record) = row, Self.recordId(row) != productId else { continue }
            if case .string(let path)? = record["imagePath"], !path.isEmpty {
                names.insert((path as NSString).lastPathComponent)
            }
            if case .array(let images)? = record["images"] {
                for case .object(let image) in images {
                    if case .string(let path)? = image["path"], !path.isEmpty {
                        names.insert((path as NSString).lastPathComponent)
                    }
                }
            }
        }
        return names
    }

    func pictures(of productId: String) async -> [StagedPicture] {
        guard let engine,
              let row = productRows.first(where: { Self.recordId($0) == productId }),
              let read = try? await engine.productPictures(of: row) else { return [] }
        return read.images.map {
            StagedPicture(id: $0.id, kind: $0.kind, caption: $0.caption,
                          thumbnail: $0.thumbnail, path: $0.path, bytes: nil)
        }
    }

    /// The three picture fields a product carries for these pictures, settled
    /// by the shared rule.
    ///
    /// `images` is written even when EMPTY, so removing the last picture
    /// actually removes it. `normalise` treats an empty array beside a set
    /// `imagePath` as an unmigrated product and rebuilds the array from it —
    /// which would resurrect the picture just deleted — so the legacy fields
    /// are cleared in the same breath. And then the shared rule has the last
    /// word on all three, because `imagePath` and `thumbnail` are what the
    /// storefront, the portal and label printing still read, and a Swift copy
    /// of that mirroring is a second thing to get out of step.
    static func pictureFields(_ staged: [StagedPicture], productId: String,
                              engine: KhaytEngine?) async -> [String: JSONValue] {
        var draft: [String: JSONValue] = [
            "id": .string(productId),
            "images": .array(staged.map { $0.record() }),
            "imagePath": .string(staged.first?.path ?? ""),
            "thumbnail": .string(staged.first?.thumbnail ?? ""),
        ]
        if let engine, case .object(let applied)? =
            try? await engine.applyProductPictures(.object(draft)) {
            draft = applied
        }
        var out: [String: JSONValue] = [:]
        for key in ["images", "imagePath", "thumbnail"] { out[key] = draft[key] ?? .string("") }
        return out
    }

    /// A product saved over the stored row `was`.
    ///
    /// `written` is what the sheet made; `baseline` what the same sheet makes
    /// of the stored row untouched. What was not changed goes back as the book
    /// spells it. The price the shared rule worked out (`priced`) is laid on
    /// after, because it is derived rather than typed. Whatever this sheet is
    /// not editing at all — the components, the storefront fields, anything a
    /// newer build writes — is the shop's, and none of this app's business to
    /// drop.
    /// What the sheet would save untouched: the product as the SHEET opened
    /// it, put through its own open→save mapping — `stored` (the row as this
    /// Mac last read it) only for a caller with no sheet. See `saveProduct`.
    static func productOpened(_ stored: [String: JSONValue], sheetOpened: Product?,
                              keys: [Product.LanguageKey], spools: [Spool],
                              reclaimsTax: Bool = false) -> ProductSheet.Payload {
        ProductSheet.payload(ProductSheet.opening(sheetOpened ?? Product.from(stored, keys: keys)),
                             spools: spools, reclaimsTax: reclaimsTax)
    }

    static func productRecord(written: [String: JSONValue], baseline: [String: JSONValue]?,
                              priced: [String: JSONValue],
                              over was: [String: JSONValue]) -> [String: JSONValue] {
        var record = written
        if let baseline {
            // Keeps what the sheet does not edit, and lets a key the edit
            // took away STAY away: a cleared translation, a cleared margin,
            // "Show on web store" switched back on (`storefrontHidden` gone).
            record = RoundTrip.keepUntouched(written: written, baseline: baseline, stored: was)
        } else {
            // No baseline to tell a removal from a field this sheet never
            // reads: keep everything the book has that the sheet did not write.
            for (key, value) in was where record[key] == nil { record[key] = value }
        }
        for (key, value) in priced { record[key] = value }
        return record
    }

    /// The price fields a product save lays over the record — or NONE, when
    /// nothing the price is made from was edited.
    ///
    /// ── WHY NOT SIMPLY PRICE WHAT THE SHEET SENT ──────────────────────────
    ///
    /// The sheet's parts are REFRESHED: `PartRow.record(spools:)` copies each
    /// part's `spoolCost`/`spoolWeight` off the spool on the shelf today. So
    /// pricing them priced the product at today's filament — and then
    /// `keepUntouched` put the stored parts back, with the price they were
    /// bought at, because those fields were not edited. A shop that opened a
    /// product after a roll went from 80 to 85 and pressed Save got a new
    /// price for nothing it did, and parts that no longer summed to the
    /// product's own `baseCost` (#1676; the Sep 50 → 13.74 incident's class).
    ///
    /// So: the sheet's parts are priced, and so are the parts it OPENED with
    /// (the baseline — refreshed the same way). Equal means nothing priced
    /// was touched, and the stored price stands, byte for byte. Different
    /// means something was: and then the price is worked out from the parts
    /// AS THEY WILL BE SAVED — the edit, with every untouched field put back
    /// as the book holds it — so the record agrees with itself.
    ///
    /// `opened` is nil for a new product: everything is an edit, priced as sent.
    static func productPriceFields(
        product: Product, parts: [JSONValue], opened: ProductSheet.Payload?,
        storedParts: JSONValue?,
        price: ([String: JSONValue]) async -> [String: JSONValue]?
    ) async -> [String: JSONValue] {
        guard let sent = await price(pricingInput(for: product, parts: parts)) else { return [:] }
        guard let opened else { return sent }
        let untouched = await price(pricingInput(for: opened.product, parts: opened.parts))
        if untouched == sent { return [:] }
        var kept = parts
        if case .array(let merged)? = RoundTrip.merge(.array(parts), baseline: .array(opened.parts),
                                                      stored: storedParts) {
            kept = merged
        }
        return await price(pricingInput(for: product, parts: kept)) ?? sent
    }

    /// Save a product, and its pictures.
    ///
    /// `pictures` is nil for a caller that is not editing them at all, which is
    /// not the same as an empty array — that means "this product now has none"
    /// and is how the last picture is removed. The two were one value in the
    /// first draft and a product with its last photo deleted came back with the
    /// photo still on it.
    ///
    /// `opened` is the product as the sheet opened it. The baseline below is
    /// drawn from it rather than from the row as this Mac last read it: every
    /// write reloads, so by Save the row on screen may already carry a change
    /// sync or the iPhone made, and against THAT an untouched field still
    /// holding the opened value reads as an edit and puts the old value back.
    /// Nil for a caller with no sheet, which takes the row as last read.
    func saveProduct(_ product: Product, pictures: [StagedPicture]? = nil,
                     unlinking removed: [String] = [],
                     parts: [JSONValue]? = nil,
                     tiers: [JSONValue]? = nil, docs: [JSONValue]? = nil,
                     unlinkingDocs droppedDocs: [String] = [],
                     opened sheetOpened: Product? = nil) async {
        moveProblem = nil
        guard permitted("inventory", "edit") else { return }
        // Whether a product is LISTED on the web store is the store's setting,
        // not the product's: `setOnWebStore` asks settings/edit, and the same
        // switch on the product sheet went round it through this save
        // (alpha.62 re-check, round 3). A new product starts listed.
        let stored = productRows.first { Self.recordId($0) == product.id }.flatMap(Self.asObject)
        let wasListed = stored?["storefrontHidden"] != .bool(true)
        if product.onWebStore != wasListed {
            guard permitted("settings", "edit") else { return }
        }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard product.hasAName else {
            moveProblem = words.callIt("mac.product_need_name"); return
        }
        let keys = await allLanguageKeys()

        // ── THE BYTES GO DOWN BEFORE THE RECORD DOES ──────────────────────
        //
        // A record naming a file that was never written is a broken picture on
        // every screen that draws the catalogue. A file written for a record
        // that was never saved is a few unreferenced kilobytes nobody sees. So
        // if one of the two has to fail, it is this one, first, where the
        // failure can still be reported instead of shipped.
        var staged = pictures
        // A turned picture goes to a NEW file (`ProductPhotos.target`) and
        // the record switches to it in the write below; the file it replaces
        // goes to the Trash with the removals — after the record, like them.
        // So until that write succeeds the original is exactly as it was.
        // Only this product's own files are ever trashed — never a file
        // another product's record names (`ProductPhotos.target`).
        let othersUse = pictureFilesOfOtherProducts(than: product.id)
        var removed = removed.filter {
            ProductPhotos.mayTouch($0, productId: product.id, othersUse: othersUse)
        }
        // What this save put on disk, to take away again if it fails.
        var written: [String] = []
        if staged != nil {
            for i in staged!.indices {
                guard let bytes = staged![i].bytes else { continue }
                do {
                    let target = ProductPhotos.target(existing: staged![i].path,
                                                      productId: product.id, imageId: staged![i].id,
                                                      othersUse: othersUse)
                    staged![i].path = try ProductPhotos.write(bytes, named: target.name, in: build)
                    written.append(staged![i].path)
                    if let old = target.unlink { removed.append(old) }
                    staged![i].bytes = nil
                } catch {
                    for name in written { ProductPhotos.discard(name, in: build) }
                    moveProblem = self.said(error)
                    return
                }
            }
        }

        // The picture fields, settled BEFORE the write opens.
        //
        // `StoreWriter.update` takes a synchronous closure and the shared rule
        // lives behind an actor, so the mirroring cannot happen inside it. That
        // is the right way round anyway: this is a pure transformation of a
        // record, and doing it here keeps the write itself to the one thing a
        // write should be.
        var pictureFields: [String: JSONValue] = [:]
        if let staged { pictureFields = await Self.pictureFields(staged, productId: product.id, engine: engine) }

        // ── WHAT AN UNTOUCHED SAVE WOULD WRITE ─────────────────────────────
        //
        // The stored row put through the sheet's own open→save mapping. What
        // the save still has equal to this was not edited, and goes back as
        // the book spells it (`RoundTrip`): a tier with a field of its own, a
        // document row the other app wrote, a part weighing 12.34567 g that
        // the form shows to four places.
        var baseline: [String: JSONValue]?
        var openedPayload: ProductSheet.Payload?
        var storedParts: JSONValue?
        if case .object(let stored)? = productRows.first(where: { Self.recordId($0) == product.id }) {
            let opened = Self.productOpened(stored, sheetOpened: sheetOpened, keys: keys, spools: spools,
                                                reclaimsTax: reclaimsTax)
            openedPayload = opened
            storedParts = stored["parts"]
            var b = opened.product.record(keys: keys)
            if staged != nil {
                for (key, value) in await Self.pictureFields(await self.pictures(of: product.id),
                                                             productId: product.id, engine: engine) {
                    b[key] = value
                }
            }
            if parts != nil { b["parts"] = .array(opened.parts) }
            if tiers != nil { b["priceTiers"] = .array(opened.tiers) }
            if docs != nil { b["docs"] = .array(opened.docs) }
            baseline = b
        }

        // ── THE PARTS, AND THE PRICE THEY MAKE ────────────────────────────
        //
        // A product's price is not typed anywhere: it is the calculator's
        // per-part cost summed over these, plus the components, plus the
        // margin, plus the shop's rounding. So the two are written together and
        // through the SHARED rule — which `renderer/inventory.js` prices with
        // too, because two apps computing this separately is two prices for one
        // product and the customer sees whichever app saved last.
        //
        // Settled before the write opens: `StoreWriter.update` takes a
        // synchronous closure and the rule lives behind an actor.
        var partFields: [String: JSONValue] = [:]
        var priced: [String: JSONValue] = [:]
        if let parts {
            partFields["parts"] = .array(parts)
            if let engine {
                let inventory = inventoryRows, settings = settingsDict, consumables = consumableRows
                priced = await Self.productPriceFields(
                    product: product, parts: parts, opened: openedPayload, storedParts: storedParts
                ) { input in
                    try? await engine.productPricingFields(.object(input), inventory: inventory,
                                                           settings: settings, consumables: consumables)
                }
            }
        }

        // ── WRITTEN EVEN WHEN THE LIST IS EMPTY ───────────────────────────
        //
        // Because removing the last tier has to actually remove it. Everything
        // else about a product is merged forward from the record that was
        // there, so an absent key means "the sheet is not editing this" — and
        // an empty list has to be a list, not an absence.
        var listFields: [String: JSONValue] = [:]
        if let tiers { listFields["priceTiers"] = .array(tiers) }
        if let docs { listFields["docs"] = .array(docs) }

        var undo: [ChangedRecord] = []
        do {
            // The async update: only this closure runs on the main actor.
            try await StoreWriter.updateAsync(build) { root in
                undo = []
                var rows = Self.rows(root, "products")
                var record = product.record(keys: keys)
                for (key, value) in pictureFields { record[key] = value }
                for (key, value) in partFields { record[key] = value }
                for (key, value) in listFields { record[key] = value }
                if let at = rows.firstIndex(where: { Self.recordId($0) == product.id }) {
                    guard case .object(let was) = rows[at] else { return }
                    undo.append(ChangedRecord(collection: "products", id: product.id, was: was))
                    record = Self.productRecord(written: record, baseline: baseline,
                                                priced: priced, over: was)
                    StoreWriter.stamp(&record)
                    rows[at] = .object(record)
                } else {
                    for (key, value) in priced { record[key] = value }
                    StoreWriter.stamp(&record)
                    rows.append(.object(record))
                }
                root["products"] = .array(rows)
                Self.sealUndo(&undo, in: root)
            }
            if !undo.isEmpty { registerMoveUndo(undo, named: words.callIt("mac.edit_product")) }
            // ONLY NOW. A file unlinked before the record is written is a file
            // the shop cannot get back if the write fails — and one unlinked
            // when the sheet was cancelled is one it never asked to lose.
            // To the Trash, remembering where: Undo on the product brings the
            // record back AND its pictures (`registerPicturesPutBack`, in the
            // same undo group as the record's).
            let trashed = removed.filter { !$0.isEmpty && !written.contains($0) }
                .compactMap { ProductPhotos.trash($0, in: build) }
            if !undo.isEmpty { registerPicturesPutBack(trashed, in: build) }
            for name in droppedDocs where !name.isEmpty {
                ProductDocs.delete(name, in: build)
            }
            editingProduct = nil
            Telemetry.feature(.productSaved, in: self)
            await load(source)
            // A price the shop just saved in the product sheet: a live web
            // store may follow it (see `CatalogPublisher.heldPrices`).
            noteExplicitPrice(product.id)
        } catch {
            // The record still names the original; the new files are nobody's.
            for name in written { ProductPhotos.discard(name, in: build) }
            moveProblem = self.said(error)
        }
    }

    /// A blank customer with an id in Khayt's own shape.
    ///
    /// `uid('CLI')` — prefix, base-36 milliseconds, three random base-36
    /// characters upper-cased. Matched so a customer written down here is
    /// indistinguishable from one written down in Khayt.
    static func newCustomer() -> Client {
        Client(id: uid("CLI"), createdAt: localDay())
    }

    // MARK: - The shop's saved messages

    /// Save a message template — a new one, or a correction to one it has.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// `MessageSheet` has always READ `waTemplates` and nothing on this Mac
    /// could write one. A shop whose book carries none opened the sheet to an
    /// empty picker and an empty box with nothing to explain it, and the only
    /// way to make a template was to open the other app. The templates are how
    /// a shop talks to its customers, so that is a gap, not a difference.
    ///
    /// Both fields are required, exactly as the other app requires them: a
    /// template with no name cannot be picked off a list, and one with no body
    /// sends nothing.
    ///
    /// `opened` is the template as the sheet opened it; what the shop did not
    /// change is kept as the book spells it (`RoundTrip`) — the body's own
    /// trailing newline, a milestone this build has no menu item for.
    func saveTemplate(id: String?, name: String, body: String,
                      milestone: String = "", lang: String = "",
                      opened: MessageTemplate?) async {
        writeProblem = nil
        // THE FIELDS BEFORE THE BOOK. What is wrong with the two strings is a
        // fact about the arguments, true whichever book is open, so the answer
        // does not depend on which one is. Nobody reaches these through the
        // sheet — Save is disabled until both are filled — but a caller that
        // does is told what it got wrong rather than where it would have gone.
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { writeProblem = words.callIt("wa.tpl_need_name"); return }
        guard !body.isEmpty else { writeProblem = words.callIt("wa.tpl_need_body"); return }
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        // `uid('WATPL')`, the other app's own shape, so a template made here
        // looks like one made there to anything that sorts or dedupes ids.
        let wanted = id ?? Self.uid("WATPL")
        await write(as: .person("settings", "edit")) { root in
            var rows = Self.rows(root, MessageTemplate.collection)
            // `milestone` and `lang` only when set: the WhatsApp milestone
            // updates read them (`lib/whatsapp-message.js:templateFor`), and a
            // plain saved message stays the shape the other app writes.
            let row = MessageTemplate(id: wanted, name: name, body: body,
                                      milestone: milestone, lang: lang).row
            if let at = rows.firstIndex(where: { Self.recordId($0) == wanted }) {
                // REPLACED IN PLACE, keeping its position. A corrected template
                // that jumps to the bottom of the list is one a shop has to
                // find again every time it fixes a typo.
                if case .object(let was) = rows[at] {
                    rows[at] = .object(Self.templateRow(
                        id: wanted, name: name, body: body, milestone: milestone, lang: lang,
                        over: was, opened: opened))
                } else {
                    rows[at] = row
                }
            } else {
                rows.append(row)
            }
            root[MessageTemplate.collection] = .array(rows)
        }
    }

    /// A template saved over the stored row `was`.
    ///
    /// Any other field the stored row carries is kept — a field this app does
    /// not edit is not this app's to drop — and so is any field the shop did
    /// not change, as the book spells it.
    nonisolated static func templateRow(id: String, name: String, body: String, milestone: String,
                            lang: String, over was: [String: JSONValue],
                            opened: MessageTemplate?) -> [String: JSONValue] {
        func laid(_ name: String, _ body: String, _ milestone: String,
                  _ lang: String) -> [String: JSONValue] {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .object(var next) = MessageTemplate(
                id: id, name: trimmedName, body: trimmedBody,
                milestone: milestone, lang: lang).row else { return was }
            for (key, value) in was where next[key] == nil
                && key != "milestone" && key != "lang" { next[key] = value }
            return next
        }
        let written = laid(name, body, milestone, lang)
        guard let opened else { return written }
        let baseline = laid(opened.name, opened.body, opened.milestone,
                            opened.milestone.isEmpty ? "" : opened.lang)
        return RoundTrip.keepUntouched(written: written, baseline: baseline, stored: was)
    }

    /// Take one off the list. An id nobody has is not an error.
    func deleteTemplate(_ id: String) async {
        writeProblem = nil
        guard permitted("settings", "edit") else { return }
        guard source.build != nil else { writeProblem = words.callIt("mac.move_sample"); return }
        await write(as: .person("settings", "edit")) { root in
            let rows = Self.rows(root, MessageTemplate.collection)
                .filter { Self.recordId($0) != id }
            root[MessageTemplate.collection] = .array(rows)
        }
    }
}
