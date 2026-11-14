import Foundation
import Testing
@testable import KhaytCore

/// Every rule that takes the shop's settings is on one of two lists: handed
/// them without the logo and the library blocks (`KhaytEngine.ruleSettings`),
/// or handed them whole.
///
/// ── WHY A LIST ────────────────────────────────────────────────────────────
///
/// Settings carries a 0.7 MB logo and the library's bookkeeping, and a reload
/// used to hand all of it to JavaScript with each of some fifty rules
/// (`KhaytEngine+RuleSettings.swift`). Trimming is only right for a rule that
/// was READ and shown not to look at those keys or copy settings whole, and a
/// rule that draws a document or hands settings back must never be trimmed:
/// an invoice would lose its logo, or a save would write settings without it.
///
/// So nothing is trimmed by default, and nothing is left whole by accident. A
/// new engine function that takes `settings` fails here until it is put on a
/// list, and the list it goes on is a decision somebody made by reading the
/// JavaScript, not a default.
///
/// What this scans: every `func` in `KhaytEngine*.swift` with `settings` in
/// its signature that calls the JavaScript runtime. A rule handed the whole
/// BOOK (which has settings inside it) is not covered here.
struct RuleSettingsGuardTests {

    /// Read and shown safe: no module the rule can reach names `bizLogo`,
    /// `printLibrary` or `libraryGroups`, none walks or copies the settings
    /// object, and the answer is not settings to be saved. What each reads
    /// instead, from its JavaScript (Nov 12 2026):
    ///
    ///   contentLanguages, customerNames, catalogue   contentLangs
    ///   shopText             contentLangs, and the keys built from `base`
    ///                        (whole settings when `base` is a heavy key)
    ///   taxProfile           tax, enableVat, vatRate
    ///   riskWhen             printRisk
    ///   aiFeatures           ai
    ///   slicers, defaultSlicer   slicers, slicer, defaultSlicerId
    ///   chaseSwitches        paymentReminder, quoteFollowUp
    ///   lowStock, inventoryUnits, needsOrdering   lowStockThreshold
    ///   lowStockWarning      lowStockThreshold, telegram
    ///   nozzleWear           nozzleWear
    ///   dashboardFacts, lateOrders   mode, nozzleWear, lowStockThreshold
    ///   estimateMesh, estimateMeshes   estimator
    ///   duplicateNumbers     quotePrefix
    ///   overhead             overheadPerHour, fixedCosts
    ///   owedByOrder, billedAndPaidByOrder, orderFigures, revenueOutlook,
    ///   cashFlow, tradeRevenue   currency, exchangeRates, and the tax keys
    ///   kpis                 those, and defaultPackagingCost
    static let trimmed: Set<String> = [
        "aiFeatures", "applyJobEdit", "billedAndPaidByOrder", "cashFlow", "catalogue", "chaseSwitches",
        "contentLanguages", "customerNames", "dashboardFacts", "defaultSlicer", "duplicateNumbers",
        "estimateMesh", "estimateMeshes", "inventoryUnits", "kpis", "lateOrders", "lowStock",
        "lowStockWarning", "needsOrdering", "nozzleWear", "orderFigures", "orderNextSteps", "overhead",
        "owedByOrder", "revenueOutlook", "riskWhen", "shopText", "slicers", "taxProfile",
        "tradeRevenue",
    ]

    /// Must be handed the whole settings, and why.
    static let needsWhole: [String: String] = [
        "applySettings": "lib/settings-edit.js reads and writes bizLogo, and returns settings to save",
        "chooseTaxCountry": "lib/settings-edit.js; returns settings to save",
        "invoiceNumbering": "lib/settings-edit.js, the module that reads bizLogo; returns settings fields to save",
        "exchangeRates": "lib/settings-edit.js, the module that reads bizLogo; returns settings fields to save",
        "vatMarkFiled": "lib/vat-periods.js copies settings ({ ...s }) and returns the copy to save",
        "invoiceHtml": "draws a document",
        "creditNoteHtml": "draws a document",
        "ensureInvoiceNumber": "copies settings (Object.assign) and returns the copy to save, with the counter moved",
        "renumber": "copies settings and returns the copy to save",
        "undoRenumber": "copies settings and returns the copy to save",
        "pnlByPeriod": "on every reload, but lib/pnl-report.js is large and was not read to the end",
        "profitPerHour": "on every reload, but reaches 22 modules (storefront, product pricing); not read to the end",
    ]

    /// Handed the whole settings because nobody has read them for this yet.
    /// Not a claim that they need it. To move one to `trimmed`, read its
    /// JavaScript and everything that calls, as the note on `trimmed` says.
    static let notYetRead: Set<String> = [
        "newOrder", "vatFiledLater", "vatFiledOverlap", "vatFilingPeriods",
        "accountingPayload", "accountingRetryable", "accountingTestPayload", "accountingWouldPush",
        "aiAssistantRead", "aiAssistantRequest", "aiLibraryRead", "aiLibraryRequest",
        "aiLooseRead", "aiLooseRequest", "aiPictureRead", "aiPictureRequest", "aiPriceRead",
        "aiPriceRequest", "aiProviderOf", "aiQuoteRead", "aiQuoteRequest", "aiReplyRead",
        "aiReplyRequest", "aiSendsCustomerData", "aiSpend", "aiTakesImages", "alertEnable",
        "alertNoticeNames", "alertRoutes", "applyPrinterModel", "baseCurrency", "bnplCheckoutArgs",
        "breakEven", "buildReport", "carriersToShipWith", "cashDue", "changeCustomer",
        "clientNames", "clientRetention", "clientSources", "clientValue", "collectionTotals",
        "costPart", "costTrends", "csvPlan", "customerAltName", "customerMix", "customerName",
        "customerRecords", "customerRecordsState", "digestDue", "digestEmail", "digestSent",
        "documentNumber", "editJob", "editMachine", "editOrderDetails", "editSpool",
        "endOfDayFacts", "expenseCsv", "filamentReport", "fillCampaignTemplate", "followUpDue",
        "grossRaw", "inShopCurrency", "invoiceCsv", "invoiceNumberOwed", "invoiceRows",
        "invoiceSummary", "invoicesToChase", "leadTimeSnapshot", "linkedReprint", "locationPl",
        "loyalty", "machineProfit", "moveJob", "newWasteEntry", "ntfyRequest", "openOrders",
        "operatorPerformance", "operatorTime", "orderEmail", "outbound", "owedRaw",
        "partBreakdown", "partCost", "paymentOutbound", "platform", "platformFeeLines",
        "pluginAgreeUpdate", "pluginApplyIndex", "pluginPhoneRecord", "pluginRevertUpdate",
        "pluginRunnable", "pluginSetSwitch", "pluginUpdateFetches", "portalPayload",
        "portalRecordPayment", "portalRefresh", "portalUndoPayment", "powerByMachine",
        "priceComparables", "priceProduct", "printRateDefaults", "printRates", "printerAlerts",
        "productPricingFields", "productProfit", "quoteFunnel", "quotesToChase",
        "rawPriceComparables", "receivables", "recordPayment", "recordQcFailure",
        "recurringOrders", "reminderEmail", "reminderPlan", "restoreDeposit", "shoppingList",
        "smsAccount", "spoolColours", "statusGate", "statusGates", "stockRunway",
        "storefrontCatalog", "storefrontCount", "storefrontHeroPaths", "storefrontReview",
        "swapMinutes", "taxed", "topLists", "vatReturn", "webStoreLinePrices", "webStorePaidTotal",
        "webhookDeliveries", "webhookRedelivery", "whatsAppCloudMessage", "whatsAppUpdate",
        "zatcaAmounts", "zatcaReadiness",
    ]

    /// name -> does every function of that name use `ruleSettings`?
    static func scan() throws -> [String: [Bool]] {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("KhaytEngine") && $0.pathExtension == "swift" }
        var found: [String: [Bool]] = [:]
        let start = /^    (?:(?:public|private|internal|nonisolated|static|fileprivate) )*func (\w+)/
        for url in files {
            // Comments out first: a note that mentions `runtime.` is not a call.
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            var name: String?
            var body: [Substring] = []
            func close() {
                guard let name else { return }
                let text = body.joined(separator: "\n")
                let signature = text.split(separator: "{", maxSplits: 1).first.map(String.init) ?? text
                guard signature.contains(/\bsettings\b/), text.contains("runtime.") else { return }
                found[name, default: []].append(text.contains("ruleSettings("))
            }
            for line in lines {
                if let match = line.firstMatch(of: start) {
                    close()
                    name = String(match.output.1)
                    body = []
                }
                body.append(line)
            }
            close()
        }
        return found
    }

    @Test("every rule that takes settings is on exactly one list")
    func everyRuleHasChosen() throws {
        let found = try Self.scan()
        #expect(found.count > 150, "found only \(found.count) rules that take settings: the scan has rotted")
        let whole = Set(Self.needsWhole.keys).union(Self.notYetRead)
        #expect(Self.trimmed.isDisjoint(with: whole), "on both lists: \(Self.trimmed.intersection(whole).sorted())")
        #expect(Set(Self.needsWhole.keys).isDisjoint(with: Self.notYetRead))

        let unlisted = Set(found.keys).subtracting(Self.trimmed).subtracting(whole).sorted()
        #expect(unlisted.isEmpty, Comment(rawValue:
            "new rules that take settings: \(unlisted). Read the JavaScript each one runs. If it cannot read "
            + "bizLogo, printLibrary or libraryGroups and never copies settings whole, hand it "
            + "ruleSettings(settings) and add it to `trimmed`; otherwise add it to `needsWhole` with the reason."))
        let gone = Self.trimmed.union(whole).subtracting(found.keys).sorted()
        #expect(gone.isEmpty, "listed but no longer in the engine: \(gone)")
    }

    @Test("a rule is trimmed exactly when the list says so")
    func theCodeAgreesWithTheLists() throws {
        let found = try Self.scan()
        for (name, uses) in found {
            if Self.trimmed.contains(name) {
                #expect(uses.allSatisfy { $0 }, "\(name) is listed as trimmed but is handed the whole settings")
            } else {
                #expect(uses.allSatisfy { !$0 },
                        "\(name) uses ruleSettings but is not on the trimmed list: it was not shown safe")
            }
        }
    }

    @Test("no module in the bundle names a heavy key, except the four that are known to")
    func whoNamesTheHeavyKeys() throws {
        // The first half of the proof for every rule on `trimmed`: a module
        // cannot read `settings.bizLogo` by name without naming it. If this
        // list grows, the rules that can reach the new module have to be
        // read again.
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/JS")
        var naming: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where url.pathExtension == "js" && !url.lastPathComponent.hasPrefix("locale-") {
            let text = try String(contentsOf: url, encoding: .utf8)
            if KhaytEngine.heavySettings.contains(where: { text.contains($0) }) {
                naming.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        // `print-library-tier` only says the word in a comment.
        #expect(naming == ["print-library-tier", "settings-edit", "store", "store-secret-paths"])
    }
}
