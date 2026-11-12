import SwiftUI
import AppKit
import KhaytCore

// MARK: - The environment log (Settings › Operations)

/// The workshop's temperature and humidity: log a reading, see the last fifty
/// and the temperature line over the last twenty — the other app's
/// "Environment Log" card, from the same rule (`lib/env-log.js`).
///
/// Saved as it is logged, like the locations and staff above it, not part of
/// the pane's Save bar: a reading is a record, not a setting.
///
/// Plain text fields for the two figures, because blank is not zero — a
/// reading of humidity alone must not log the room at 0 °C.
struct EnvironmentLogSection: View {
    let shop: Shop

    @State private var temperature = ""
    @State private var humidity = ""
    @State private var machineId = ""
    @State private var notes = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var view: KhaytEngine.EnvLogView?
    @State private var deleting: KhaytEngine.EnvReading?

    private var words: Words { shop.words }

    var body: some View {
        Section {
            Text(words.callIt("mac.env_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(words.callIt("mac.env_temp")) {
                TextField("", text: $temperature, prompt: Text(verbatim: "22"))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(words.callIt("mac.env_humidity")) {
                TextField("", text: $humidity, prompt: Text(verbatim: "45"))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            Picker(words.callIt("mac.env_machine"), selection: $machineId) {
                Text(words.callIt("mac.env_room")).tag("")
                ForEach(shop.machines.filter { !$0.isRetired }) { m in
                    Text(verbatim: m.name).tag(m.id)
                }
            }
            LabeledContent(words.callIt("mac.env_notes")) {
                TextField("", text: $notes).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            HStack {
                Button(words.callIt("logEnvironment")) { Task { await log() } }
                    .disabled(!shop.mayEditEnvLog || busy
                              || (temperature.trimmingCharacters(in: .whitespaces).isEmpty
                                  && humidity.trimmingCharacters(in: .whitespaces).isEmpty))
                if busy { ProgressView().controlSize(.small) }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let trend = view?.trend {
                VStack(alignment: .leading, spacing: 4) {
                    Text(words.callIt("mac.env_trend", ["n": .number(Double(trend.readings.count))]))
                        .font(.caption).foregroundStyle(.secondary)
                    TemperatureLine(readings: trend.readings, min: trend.min, max: trend.max)
                        .stroke(Khayt.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(maxWidth: 260)
                        .frame(height: 44)
                    Text(verbatim: degrees(trend.min) + " – " + degrees(trend.max))
                        .font(.caption2).monospacedDigit().foregroundStyle(Khayt.faint)
                }
            }

            if let recent = view?.recent {
                if recent.isEmpty {
                    Text(words.callIt("mac.env_none"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(recent) { reading in row(reading) }
                }
            }
        } header: {
            Text(words.callIt("envLogs"))
        }
        .task(id: shop.envLogRows) { await reload() }
        .confirmationDialog(words.callIt("mac.env_delete_q"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(words.callIt("common.delete"), role: .destructive) {
                guard let id = deleting?.id else { return }
                deleting = nil
                Task { await shop.deleteEnvReading(id) }
            }
        }
    }

    private func row(_ reading: KhaytEngine.EnvReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: when(reading.timestamp))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)
            Text(verbatim: reading.temperature.map(degrees) ?? "—")
                .monospacedDigit().frame(width: 64, alignment: .trailing)
            Text(verbatim: reading.humidity.map { number($0) + "%" } ?? "—")
                .monospacedDigit().frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: machineName(reading.machineId)).font(.callout)
                if !reading.notes.isEmpty {
                    Text(verbatim: reading.notes).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(role: .destructive) { deleting = reading } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(words.callIt("common.delete"))
                .accessibilityLabel(words.callIt("common.delete"))
                .disabled(!shop.mayEditEnvLog)
        }
    }

    private func machineName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return words.callIt("mac.env_room") }
        return shop.machines.first { $0.id == id }?.name ?? id
    }

    private func number(_ v: Double) -> String {
        v.formatted(.number.locale(words.locale).precision(.fractionLength(0...1)))
    }
    private func degrees(_ v: Double) -> String { number(v) + "°C" }

    private func when(_ stamp: String) -> String {
        guard let ms = JSDate.parse(stamp) else { return stamp }
        return words.say(Date(timeIntervalSince1970: ms / 1000), Date.FormatStyle(date: .abbreviated, time: .shortened))
    }

    private func reload() async {
        guard let engine = shop.engine else { return }
        view = try? await engine.envLogView(shop.envLogRows)
    }

    private func log() async {
        busy = true; defer { busy = false }
        problem = await shop.logEnvironment(temperature: temperature, humidity: humidity,
                                            machineId: machineId.isEmpty ? nil : machineId, notes: notes)
        if problem == nil {
            temperature = ""; humidity = ""; notes = ""
        }
    }
}

/// The temperature over the readings, as a line between the lowest and the
/// highest — the other app's sparkline. Scaled to its own range, as that one
/// is, so the caption under it gives the two ends.
private struct TemperatureLine: Shape {
    let readings: [Double]
    let min: Double
    let max: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard readings.count >= 2 else { return p }
        let range = (max - min) == 0 ? 1 : (max - min)
        for (i, t) in readings.enumerated() {
            let x = rect.minX + rect.width * Double(i) / Double(readings.count - 1)
            let y = rect.maxY - rect.height * (t - min) / range
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// MARK: - Closure dates (Settings › Operations, in the pane's draft)

/// `settings.holidays`: the days the shop is closed, `YYYY-MM-DD` in the
/// book's calendar. Part of the Operations draft, saved with its Save bar
/// through `lib/settings-edit.js`, which cleans the list with the shared
/// reader (`lib/working-week.js holidays`).
struct HolidaysSection: View {
    let shop: Shop
    @Binding var holidays: [String]
    @State private var picked = Date()

    var body: some View {
        Section {
            HStack {
                DatePicker("", selection: $picked, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.calendar, Calendar.book)
                    .environment(\.locale, shop.words.locale)
                Button(shop.words.callIt("set.add_holiday")) {
                    let day = Shop.localDay(picked)
                    if !holidays.contains(day) { holidays = (holidays + [day]).sorted() }
                }
            }
            if holidays.isEmpty {
                Text(shop.words.callIt("mac.holidays_none")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(holidays, id: \.self) { day in
                    HStack {
                        Text(verbatim: Self.say(day, shop.words)).monospacedDigit()
                        Spacer()
                        Button(role: .destructive) { holidays.removeAll { $0 == day } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(shop.words.callIt("common.delete"))
                        .accessibilityLabel(shop.words.callIt("common.delete"))
                    }
                }
            }
        } header: {
            Text(shop.words.callIt("set.holidays"))
        } footer: {
            Text(shop.words.callIt("mac.holidays_hint"))
        }
    }

    /// `2026-09-23` as the shop reads a date, in the book's calendar.
    static func say(_ day: String, _ words: Words) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.book.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return day }
        return words.say(date, Date.FormatStyle(date: .complete, time: .omitted))
    }
}

// MARK: - This month's AI spend (Settings › Assistant)

/// What the shop's own key has spent this month, per feature — the other
/// app's "This month's AI usage" panel, from `lib/ai-usage.js summarize` over
/// `settings.aiUsage`, which this Mac already records into. Nothing is shown
/// in a month with no calls, as there.
struct AiSpendSection: View {
    let shop: Shop
    @State private var spend: KhaytEngine.AiSpend?

    var body: some View {
        Group {
            if let spend, !spend.rows.isEmpty {
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text(shop.words.callIt("set.ai_spend_feature"))
                            Text(shop.words.callIt("set.ai_spend_calls")).gridColumnAlignment(.trailing)
                            Text(shop.words.callIt("set.ai_spend_cost")).gridColumnAlignment(.trailing)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(spend.rows, id: \.task) { row in
                            GridRow {
                                Text(row.labelKey.map { shop.words.callIt($0) } ?? row.task)
                                Text(verbatim: shop.words.numeral(row.calls)).monospacedDigit()
                                Text(verbatim: row.cost).monospacedDigit()
                            }
                        }
                    }
                    Text(shop.words.callIt("set.ai_spend_note") + " " + shop.words.callIt("set.ai_spend_device")
                         + (spend.estimated ? " " + shop.words.callIt("set.ai_spend_unknown_model") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    HStack {
                        Text(shop.words.callIt("set.ai_spend"))
                        Spacer()
                        Text(verbatim: spend.total).monospacedDigit()
                    }
                }
            }
        }
        .task(id: shop.settingsValue) {
            guard let engine = shop.engine else { return }
            spend = try? await engine.aiSpend(settings: shop.settingsDict, now: Date())
        }
    }
}

// MARK: - The shop's web address (Settings › Online)

/// The shop's own name for its public pages (`/v1/shops/{id}/slug`). The id
/// keeps working either way; a name is an extra address. The cloud owns the
/// rules — reserved words, names already taken — so its sentence is shown.
struct ShopSlugSettings: View {
    let shop: Shop

    @State private var slug = ""
    @State private var saved: String?
    @State private var busy = false
    @State private var problem: String?
    @State private var note: String?

    private var mayWrite: Bool { shop.lockAllows("settings", "edit") && shop.cloudRoleCanWrite }

    var body: some View {
        if Shop.cloudConnected(shop.settingsDict) {
            Section(shop.words.callIt("cloud.slug_label")) {
                LabeledContent(shop.words.callIt("cloud.slug_label")) {
                    TextField("", text: $slug, prompt: Text(shop.words.callIt("cloud.slug_ph")))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .autocorrectionDisabled()
                        .disabled(!mayWrite || busy)
                }
                HStack {
                    Button(shop.words.callIt("common.save")) { Task { await save() } }
                        .disabled(!mayWrite || busy
                                  || slug.trimmingCharacters(in: .whitespaces).lowercased() == (saved ?? ""))
                    if busy { ProgressView().controlSize(.small) }
                }
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Text(shop.words.callIt("cloud.slug_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let (c, t) = await shop.vaultSession() else { return }
        // Not fatal: the field simply starts empty, as on the other app.
        if let got = try? await CloudShopPages.slug(c, token: t, fetch: Shop.plansFetch) {
            saved = got.slug
            slug = got.slug ?? ""
        }
    }

    private func save() async {
        let name = slug.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { problem = shop.words.callIt("cloud.slug_empty"); return }
        guard let (c, t) = await shop.vaultSession() else { return }
        busy = true; defer { busy = false }
        do {
            let got = try await CloudShopPages.setSlug(name, c, token: t, fetch: Shop.plansFetch) ?? name
            saved = got; slug = got
            problem = nil
            note = shop.words.callIt("cloud.slug_saved")
        } catch let r as CloudShopPages.Refusal where !r.error.isEmpty {
            problem = r.error; note = nil
        } catch {
            problem = shop.words.callIt("cloud.slug_failed"); note = nil
        }
    }
}

// MARK: - The web store's visitors and reviews (the Web Store sheet)

/// Views → carts → orders, the conversion and the products people wanted —
/// the other app's "Storefront insights", from `lib/storefront-insights.js`.
/// Best effort, as there: a failure reads as no activity, never as an error.
struct StorefrontInsightsSection: View {
    let shop: Shop
    @State private var insights: KhaytEngine.StorefrontInsights?
    @State private var loaded = false

    var body: some View {
        Section(shop.words.callIt("store.insights")) {
            if let s = insights, !s.empty {
                HStack(spacing: 18) {
                    stat(shop.words.numeral(s.views), "store.ins_views")
                    stat(shop.words.numeral(s.carts), "store.ins_carts")
                    stat(shop.words.numeral(s.orders), "store.ins_orders")
                    stat(s.conversionPct.formatted(.number.locale(shop.words.locale).precision(.fractionLength(0...1))) + "%",
                         "store.ins_conv")
                }
                ForEach(s.top) { item in
                    HStack {
                        Text(verbatim: item.name)
                        Spacer()
                        Text(verbatim: shop.words.numeral(item.orders) + " " + shop.words.callIt("store.ins_orders")
                             + " · " + shop.words.numeral(item.carts) + " " + shop.words.callIt("store.ins_carts"))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else if loaded {
                Text(shop.words.callIt("store.insights_empty")).font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
    }

    private func stat(_ value: String, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: value).font(.body.weight(.semibold)).monospacedDigit()
            Text(shop.words.callIt(key)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        defer { loaded = true }
        guard let engine = shop.engine, let (c, t) = await shop.vaultSession(),
              let stats = try? await CloudShopPages.storefrontStats(c, token: t, fetch: Shop.plansFetch)
        else { return }
        insights = try? await engine.storefrontInsights(stats)
    }
}

/// The reviews customers left on the shop's public review page, the average
/// the storefront prints, the link to send, and — for the owner — each review
/// with a way to remove it. The other app's Storefront dialog, same calls.
///
/// The list is owner-only on the cloud, so anyone else sees the average and
/// the link and is told why there is no list, rather than an empty one that
/// reads as "no reviews".
struct CustomerReviewsSection: View {
    let shop: Shop

    @State private var summary: CloudShopPages.Summary?
    @State private var rows: [KhaytEngine.ReviewRow]?
    @State private var link = ""
    @State private var problem: String?
    @State private var copied = false
    @State private var deleting: KhaytEngine.ReviewRow?

    private var words: Words { shop.words }
    private var mayDelete: Bool { shop.cloudIsOwner && shop.lockAllows("settings", "edit") }

    var body: some View {
        Section {
            Text(words.callIt("store.reviews_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !link.isEmpty {
                Text(verbatim: link).font(.caption.monospaced()).textSelection(.enabled)
                Button(words.callIt(copied ? "store.copied" : "store.review_link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !shop.cloudIsOwner {
                Text(words.callIt("mac.rv_owner_only")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let rows {
                if rows.isEmpty {
                    Text(words.callIt("store.reviews_none")).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { review in row(review) }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } header: {
            HStack {
                Text(words.callIt("store.reviews"))
                if let summary, summary.count > 0 {
                    Text(verbatim: "★ " + RatingTrendCard.oneDecimal(summary.average)
                         + " (" + words.numeral(summary.count) + ")")
                        .foregroundStyle(Khayt.brand).monospacedDigit()
                }
            }
        }
        .task { await load() }
        .confirmationDialog(words.callIt("store.review_delete_q"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(words.callIt("common.delete"), role: .destructive) {
                guard let id = deleting?.id else { return }
                deleting = nil
                Task { await remove(id) }
            }
        }
    }

    private func row(_ review: KhaytEngine.ReviewRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: String(repeating: "★", count: review.stars)
                 + String(repeating: "☆", count: max(0, 5 - review.stars)))
                .foregroundStyle(Khayt.brand)
                .accessibilityLabel(words.numeral(review.stars) + "/5")
            VStack(alignment: .leading, spacing: 2) {
                if !review.comment.isEmpty {
                    Text(verbatim: review.comment).fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: (review.name.isEmpty ? words.callIt("store.review_anon") : review.name)
                     + (review.day.isEmpty ? "" : " · " + HolidaysSection.say(review.day, words))
                     + " · " + words.callIt(review.verified ? "store.review_verified" : "store.review_unverified"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if mayDelete {
                Button(words.callIt("common.delete"), role: .destructive) { deleting = review }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func load() async {
        guard let engine = shop.engine, let (c, t) = await shop.vaultSession() else { return }
        link = (try? await engine.reviewLink(baseUrl: c.url, shopId: c.shopId)) ?? ""
        summary = await CloudShopPages.reviewSummary(c, token: t, fetch: Shop.plansFetch)
        guard shop.cloudIsOwner else { return }
        do {
            let raw = try await CloudShopPages.reviews(c, token: t, fetch: Shop.plansFetch)
            rows = try await engine.reviewRows(raw)
            problem = nil
        } catch {
            // Say why. A blank space here reads as "no reviews", which is the
            // one thing it must not be mistaken for.
            problem = words.callIt("store.reviews_load_failed") + " — " + said(error)
        }
    }

    private func remove(_ id: String) async {
        guard let (c, t) = await shop.vaultSession() else { return }
        do {
            try await CloudShopPages.deleteReview(id, c, token: t, fetch: Shop.plansFetch)
            await load()
        } catch {
            problem = said(error)
        }
    }

    private func said(_ error: Error) -> String {
        if let r = error as? CloudShopPages.Refusal, !r.error.isEmpty { return r.error }
        return ErrorText.plain(error)
    }
}
