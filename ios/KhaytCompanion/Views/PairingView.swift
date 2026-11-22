import SwiftUI
import UIKit

/// Pairing, as `design/ios-v2/` draws it: three steps, each one screen.
///
/// 1. **Which shop?** — the Macs announcing themselves on this Wi-Fi, each
///    saying whether it can hand over its book. Typing an address is a quiet
///    link at the bottom, for the shops discovery cannot serve.
/// 2. **The owner PIN** — for the shop just picked.
/// 3. **Copying the shop's book** — what landed, itemised, and what did not.
///    A Mac that does not serve the book skips this step: there is nothing to
///    itemise, and the phone is paired all the same.
struct PairingView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient

    enum Step { case find, manual, code, approved, notPaired, pin, pull }
    /// Why pairing by number stopped (frame "Pair 3 · Denied or ran out").
    enum NotPaired: Equatable { case denied, expired, busy, refused, unreachable }

    @State private var step: Step = .find
    @StateObject private var browser = ShopBrowser()
    @State private var resolving: String?
    @State private var showCloudSignIn = false
    @State private var isConnecting = false
    @State private var pinRefused = false
    @State private var pinTooShort = false
    @State private var failure: String?
    @State private var summary: PairingSummary?
    @State private var sampleFailure: String?
    @FocusState private var pinFocused: Bool
    /// Pairing by number (C1): the offer the Mac made and this phone checked.
    @State private var ticket: KhaytAPIClient.CodePairTicket?
    @State private var notPaired: NotPaired = .expired
    /// The Mac has no pairing by number (404/405/pairing-upgrade): the PIN
    /// step says so, and pairs as the owner, as before (D-P1).
    @State private var olderMac = false
    /// Each attempt, so an old attempt's poll can never finish a new one.
    @State private var attempt = 0
    /// Whether this screen is still up, read by a cancel that comes back
    /// after it went away (a reference, so the answer sees the truth).
    @State private var presence = Presence()
    final class Presence { var shown = false }

    var body: some View {
        ZStack {
            KhaytDesign.ground.ignoresSafeArea()
            Group {
                switch step {
                case .find: findStep
                case .manual: manualStep
                case .code: codeStep
                case .approved: approvedStep
                case .notPaired: notPairedStep
                case .pin: pinStep
                case .pull: pullStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .sheet(isPresented: $showCloudSignIn) { CloudSignInSheet() }
        .onAppear { presence.shown = true }
        .onDisappear { presence.shown = false; giveUpTheNumber() }
        // Approved on the Mac, then the app was closed before Continue: the
        // enrolment is live, so pick up at the approved screen, not Find.
        .onAppear {
            if settings.pairedByCode, settings.device != nil, !settings.isPaired { step = .approved }
        }
        #if DEBUG
        // `-KhaytPairStep pin`: open on the PIN step, for a screenshot.
        .onAppear {
            if UserDefaults.standard.string(forKey: "KhaytPairStep") == "pin" {
                if settings.host.isEmpty { settings.host = "192.168.1.42" }
                step = .pin
            }
            // `-KhaytPairStep code|approved|denied|older`: the pairing-by-number
            // screens with sample data, for comparing against the frames.
            if let shot = PairShot(rawValue: UserDefaults.standard.string(forKey: "KhaytPairStep") ?? "") {
                if settings.host.isEmpty { settings.host = "192.168.1.42" }
                shot.apply(step: &step, notPaired: &notPaired, olderMac: &olderMac, sample: &sampleCheck,
                           role: &sampleRole)
            }
        }
        #endif
        // Signing in to the cloud IS setting up: the phone takes the shop from
        // there and can pair with the Mac later, from Settings.
        .onChange(of: api.cloud) { _, session in
            if session != nil { settings.isPaired = true }
        }
    }

    // MARK: - 1. Which shop?

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("KhaytMark")
                .resizable().scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            title(L10n.tr("pair.find.title"))
            lead(L10n.tr("pair.find.body"))
            if settings.signedOutByMac {
                V2Note(text: L10n.tr("pair.signed_out"), tone: KhaytDesign.attention)
                    .padding(.top, 14)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    searchingRow
                    shopList
                }
            }
            .scrollIndicators(.hidden)
            .padding(.top, 22)

            quietLink(L10n.tr("pair.manual")) { step = .manual }
            foot(L10n.tr("pair.manual.why"))
            quietLink(L10n.tr("pair.use_cloud")) { showCloudSignIn = true }
                .padding(.top, 10)
            foot(L10n.tr("pair.use_cloud.footer"))
            quietLink(L10n.tr("pair.sample")) {
                do { try api.openSampleShop() } catch { sampleFailure = error.localizedDescription }
            }
            .padding(.top, 10)
            foot(sampleFailure ?? L10n.tr("pair.sample.footer"))
        }
        // Scoped to this step: browsing holds a network assertion, and there
        // is no reason to hold it while somebody types a PIN.
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var searchingRow: some View {
        HStack(spacing: 9) {
            if browser.isSearching {
                ProgressView().controlSize(.mini).tint(KhaytDesign.brand)
            }
            eyebrow(L10n.tr("pair.searching"))
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var shopList: some View {
        if let failure = browser.failure {
            // Said as what it usually is. "No shops found" for a refused
            // permission sends somebody to reboot a router that is fine.
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("pair.browse.failed"))
                    .font(.khayt(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(failure).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                Text(L10n.tr("pair.browse.permission")).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
        } else if browser.shops.isEmpty {
            Text(L10n.tr(browser.isSearching ? "pair.browse.looking" : "pair.browse.none"))
                .font(.khayt(13, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
        } else {
            ForEach(browser.shops) { shop in
                Button { Task { await choose(shop) } } label: { shopCard(shop) }
                    .buttonStyle(.plain)
                    .disabled(resolving != nil)
            }
        }
    }

    /// A shop that can hand over its book earns the green rail: it is the one
    /// the phone can keep working with away from the desk.
    private func shopCard(_ shop: ShopBrowser.Shop) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.name)
                    .font(.khayt(16, .medium, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                Text(L10n.tr(shop.servesBook ? "pair.shop.offline" : "pair.shop.needs_mac"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(shop.servesBook ? KhaytDesign.done : KhaytDesign.note)
            }
            Spacer(minLength: 8)
            if resolving == shop.id {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .padding(.vertical, 15).padding(.leading, 18).padding(.trailing, 16)
        .frame(minHeight: 64)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) {
            if shop.servesBook { Rectangle().fill(KhaytDesign.done).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    private func choose(_ shop: ShopBrowser.Shop) async {
        resolving = shop.id
        defer { resolving = nil }
        guard let found = await browser.resolve(shop) else {
            // Discovery said it was there and the connection disagreed — a Mac
            // that went to sleep between the two, most likely. The typed
            // address is the way on, rather than a list that does not respond.
            step = .manual
            return
        }
        settings.host = found.host
        settings.port = Int(found.port)
        settings.shopLabel = shop.name
        settings.serviceName = shop.id
        goToCode()
    }

    // MARK: - 1b. The Mac's address

    // ── THE TYPED ADDRESS STAYS ──────────────────────────────────────────
    //
    // Not as a fallback for when discovery is flaky, but because there are
    // shops it cannot serve at all: the Electron desktop does not advertise
    // itself, and a network with Bonjour blocked between its wireless and wired
    // sides is common in buildings wired by somebody else.
    @State private var portText = ""

    private var manualStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.manual.title"))
            lead(L10n.tr("pair.manual.body"))
                .padding(.bottom, 22)
            fieldLabel(L10n.tr("pair.manual.host"))
            // An address or a name: `192.168.1.42` or `studio-mac.local`.
            TextField("192.168.1.42", text: $settings.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .modifier(BigField())
            fieldLabel(L10n.tr("pair.manual.port")).padding(.top, 14)
            TextField("3219", text: $portText)
                .keyboardType(.numberPad)
                .modifier(BigField())
                .onAppear { portText = String(settings.port) }
                .onChange(of: portText) { _, v in if let p = PhoneCalculator.wholeNumber(v), (1...65535).contains(p) { settings.port = p } }
            Spacer(minLength: 18)
            primary(L10n.tr("pair.continue"), disabled: !settings.isConfigured) {
                if settings.shopLabel.trimmingCharacters(in: .whitespaces).isEmpty {
                    settings.shopLabel = settings.host
                }
                settings.serviceName = ""
                goToCode()
            }
            secondary(L10n.tr("pair.back")) { step = .find }
        }
    }

    // MARK: - 2. Pairing by a number the Mac approves (C1, frames 254:3/17/31)

    // ── THE NUMBER IS THE CHECK, NOT A SECRET ──────────────────────────────
    //
    // The phone shows the six digits only once the Mac's signed offer checks
    // out against this phone's own commitment (`CodePairing.accept`); the Mac
    // shows the same six from the same inputs. A person approving on the Mac
    // compares them, so something else on the Wi-Fi asking at the same moment
    // is told apart. Nothing typed, no PIN kept; the Mac gives the role.

    private func goToCode() {
        attempt += 1
        ticket = nil
        olderMac = false
        failure = nil
        step = .code
        let mine = attempt
        Task { await startCode(mine) }
    }

    private func startCode(_ mine: Int) async {
        let started = await api.startCodePairing(name: settings.nameToSend)
        guard mine == attempt, step == .code else { return }
        switch started {
        case .number(let t): ticket = t
        case .unsupported:
            // A phone that has paired with this Mac by number does not fall
            // back to the PIN because something answered "no such route":
            // that is how a host on the Wi-Fi would ask for the owner PIN.
            if settings.pairedByCode, settings.macIdentityKey != nil { return stop(.refused) }
            olderMac = true; goToPin()
        case .closed: stop(.expired)
        case .busy: stop(.busy)
        case .refused: stop(.refused)
        case .unreachable: stop(.unreachable)
        }
    }

    private func stop(_ why: NotPaired) {
        ticket = nil
        notPaired = why
        step = .notPaired
        CompanionHaptics.warning()
    }

    /// Asks the Mac every two seconds while the number is on screen. A poll
    /// that does not get through is asked again; the Mac's own window decides
    /// when the number runs out.
    private func waitForTheMac(_ t: KhaytAPIClient.CodePairTicket, _ mine: Int) async {
        while !Task.isCancelled, mine == attempt, step == .code {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, mine == attempt, step == .code else { return }
            let state = await api.pollCodePairing(t)
            // Cancel, Start again or the PIN may have been chosen while the
            // Mac was asked: their choice stands, not this answer.
            guard !Task.isCancelled, mine == attempt, step == .code else { return }
            switch state {
            case .waiting, .unreachable: continue
            case .denied: return stop(.denied)
            case .expired, .unknown: return stop(.expired)
            case .approved:
                let done = await api.finishCodePairing(t, markPaired: false) {
                    !Task.isCancelled && mine == attempt && step == .code
                }
                guard !Task.isCancelled, mine == attempt, step == .code else { return }
                if done {
                    CompanionHaptics.success()
                    ticket = nil            // used: leaving the number now cancels nothing
                    step = .approved
                } else {
                    stop(.refused)
                }
                return
            }
        }
    }

    // ── GIVING THE NUMBER UP (#2631) ───────────────────────────────────────
    //
    // Cancel, Use the PIN or leaving the screen tells the Mac, so it stops
    // showing a number nobody is looking at. The ticket is taken first, so the
    // poll and a second call find nothing to give up. If the Mac had ALREADY
    // approved (409 "approved"), the approval stands (the Mac does not undo
    // it): the phone finishes it, as the poll would have a moment later, and
    // shows it when the screen is still up.
    private func giveUpTheNumber() {
        guard let t = ticket else { return }
        ticket = nil
        attempt += 1
        let presence = presence
        Task { @MainActor in
            guard await api.cancelCodePairing(t) == .approved else { return }
            let shown = presence.shown
            let done = await api.finishCodePairing(t, markPaired: !shown)
            if done, shown, presence.shown {
                CompanionHaptics.success()
                step = .approved
            }
        }
    }

    /// "481 207": the check number in two groups, as the Mac shows it.
    nonisolated static func grouped(_ check: String) -> String {
        guard check.count == 6 else { return check }
        return String(check.prefix(3)) + " " + String(check.suffix(3))
    }

    #if DEBUG
    @State private var sampleCheck: String?
    @State private var sampleRole: String?
    #else
    private var sampleCheck: String? { nil }
    private var sampleRole: String? { nil }
    #endif

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.code.title"))
            lead(L10n.tr("pair.code.body"))
                .padding(.bottom, 22)
            VStack(spacing: 10) {
                if let check = ticket?.check ?? sampleCheck {
                    Text(Self.grouped(check))
                        .font(.khayt(44, .bold, relativeTo: .largeTitle))
                        .monospacedDigit()
                        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                        .foregroundStyle(KhaytDesign.ink)
                        .accessibilityLabel(check.map { String($0) }.joined(separator: " "))
                } else {
                    ProgressView().frame(height: 52)
                }
                Text(L10n.format("pair.code.device", settings.nameToSend, appVersion))
                    .font(.khaytMono(11.5))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            HStack(spacing: 8) {
                Circle().fill(KhaytDesign.brand).frame(width: 7, height: 7)
                Text(L10n.tr(ticket == nil && sampleCheck == nil ? "pair.code.starting" : "pair.code.waiting"))
                    .font(.khayt(13.5, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.ink)
            }
            .padding(.top, 16)
            foot(L10n.tr("pair.code.foot")).padding(.top, 8)
            Spacer(minLength: 18)
            centredLink(L10n.tr("pair.code.use_pin")) { giveUpTheNumber(); attempt += 1; olderMac = false; goToPin() }
            tonal(L10n.tr("pair.code.cancel")) { giveUpTheNumber(); attempt += 1; step = .find }
        }
        .task(id: ticket?.offer.pairId) {
            if let t = ticket { await waitForTheMac(t, attempt) }
        }
        // Any other way off the number (the cloud sign-in, the sample shop,
        // the app taking the screen away) gives it up too.
        .onDisappear { giveUpTheNumber() }
    }

    private var role: String { sampleRole ?? settings.effectiveRole }

    private var approvedStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.approved.title"))
            lead(L10n.tr("pair.approved.body"))
                .padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("role.\(role)"))
                    .font(.khayt(19, .semibold, relativeTo: .title3))
                    .foregroundStyle(KhaytDesign.ink)
                    .padding(.bottom, 2)
                ForEach(L10n.tr("role.\(role).can").components(separatedBy: "\n"), id: \.self) { line in
                    Text("· " + line)
                        .font(.khayt(13.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            foot(L10n.tr("pair.approved.foot")).padding(.top, 12)
            Spacer(minLength: 18)
            primary(L10n.tr("pair.approved.continue"), busy: isConnecting) {
                Task { await afterApproval() }
            }
        }
    }

    /// A manager or owner phone takes the book now, as the PIN flow does; a
    /// floor phone keeps none (D-P6 a) and goes straight in.
    private func afterApproval() async {
        guard settings.mayHoldBook else { settings.isPaired = true; return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let book = try CompanionBook.inSharedContainer()
            _ = try await api.pullBook(into: book)
            summary = await api.fetchPairingSummary()
        } catch {
            summary = nil
        }
        if summary != nil { step = .pull } else { settings.isPaired = true }
    }

    private var notPairedStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.not.title"))
                .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("pair.not.\(Self.key(notPaired)).title"))
                    .font(.khayt(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(notPaired == .denied || notPaired == .refused ? KhaytDesign.late : KhaytDesign.ink)
                Text(L10n.tr("pair.not.\(Self.key(notPaired)).body"))
                    .font(.khayt(13.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            Spacer(minLength: 18)
            primary(L10n.tr("pair.not.again")) { goToCode() }
            centredLink(L10n.tr("pair.code.use_pin")) { olderMac = false; goToPin() }
                .padding(.top, 8)
        }
    }

    nonisolated static func key(_ why: NotPaired) -> String {
        switch why {
        case .denied: return "denied"
        case .expired: return "expired"
        case .busy: return "busy"
        case .refused: return "refused"
        case .unreachable: return "unreachable"
        }
    }

    // MARK: - 2b. The owner PIN

    private func goToPin() {
        settings.pin = ""
        pinRefused = false
        pinTooShort = false
        failure = nil
        step = .pin
    }

    private var pinStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(settings.shopLabel.isEmpty ? settings.host : settings.shopLabel)
                .padding(.bottom, 10)
            title(L10n.tr(olderMac ? "pair.older.title" : "pair.pin.title"))
            lead(L10n.tr(olderMac ? "pair.older.body" : "pair.pin.body"))
                .padding(.bottom, 22)
            SecureField("••••••••", text: $settings.pin)
                .pinEntry()
                .focused($pinFocused)
                .font(.khayt(26, .semibold, relativeTo: .title))
                .khaytTracking(8)
                .padding(.horizontal, 18)
                .frame(minHeight: 64)
                .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(pinRefused ? KhaytDesign.late : KhaytDesign.hairline, lineWidth: 1))
                .onChange(of: settings.pin) { _, _ in pinRefused = false; pinTooShort = false; failure = nil }
                .onAppear { pinFocused = true }
            if pinTooShort {
                Text(L10n.tr("pair.pin.too_short"))
                    .font(.khayt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.attention)
                    .padding(.top, 10)
            } else if pinRefused {
                Text(L10n.tr("pair.pin.wrong"))
                    .font(.khayt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.late)
                    .padding(.top, 10)
            } else if let failure {
                Text(failure)
                    .font(.khayt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.late)
                    .padding(.top, 10)
            }
            foot(L10n.tr(olderMac ? "pair.older.foot" : "pair.pin.foot")).padding(.top, 10)
            if !olderMac {
                fieldLabel(L10n.tr("pair.phone_name")).padding(.top, 18)
                TextField(ConnectionSettings.defaultPhoneName, text: $settings.phoneName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .modifier(BigField())
                foot(L10n.tr("pair.phone_name.foot"))
            }
            Spacer(minLength: 18)
            primary(L10n.tr(olderMac ? "pair.older.pair" : "pair.connect"), busy: isConnecting,
                    disabled: settings.pin.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || isConnecting) {
                Task { await connect() }
            }
            secondary(L10n.tr("pair.back")) { step = .find }
        }
    }

    private func connect() async {
        // The owner PIN pairs as the owner: a number pairing left over from
        // before must not make this a floor phone.
        settings.pairedByCode = false
        isConnecting = true
        defer { isConnecting = false }
        do {
            _ = try await api.validatePairing()
        } catch KhaytAPIError.unauthorized {
            pinRefused = true
            CompanionHaptics.warning()
            return
        } catch KhaytAPIError.pinTooShort {
            pinTooShort = true
            CompanionHaptics.warning()
            return
        } catch {
            failure = error.localizedDescription
            CompanionHaptics.warning()
            return
        }

        // ── ENROL NOW, WHILE THE MAC'S PAIRING WINDOW IS OPEN ────────────
        //
        // The native Mac takes a new phone only while its owner has clicked
        // "Pair a phone"; a phone paired outside that window would run on the
        // PIN alone, sent on every request. So enrol here, and say what to do
        // when the window is shut. A Mac or desktop without the route (404)
        // or a failed try is not fatal: the phone enrols later by itself.
        // Enrolled, the phone lets the typed PIN go: its requests are signed.
        let result = await api.enrolWithTypedPin(name: settings.nameToSend)
        if result == .closed || result == .locked {
            failure = L10n.tr(result == .closed ? "pair.window_closed" : "pair.window_locked")
            CompanionHaptics.warning()
            return
        }

        // ── AND THEN ASK FOR THE BOOK, BUT DO NOT INSIST ─────────────────
        //
        // Pairing has succeeded by this line. The book is what lets this phone
        // keep working away from the Mac, so it is taken at the one moment the
        // shop is certainly on the same Wi-Fi with the PIN just typed. It must
        // NOT be able to fail the pairing: the Electron desktop does not serve
        // `/api/store`, and a phone that refused to pair with the app the shop
        // actually runs would be worse than one that cannot work offline.
        do {
            let book = try CompanionBook.inSharedContainer()
            _ = try await api.pullBook(into: book)
            summary = await api.fetchPairingSummary()
        } catch {
            summary = nil
        }
        CompanionHaptics.success()
        if summary != nil {
            step = .pull
        } else {
            settings.isPaired = true
        }
    }

    // MARK: - 3. Copying the shop's book

    private var pullStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.pull.title"))
            lead(L10n.tr("pair.pull.body"))
                .padding(.bottom, 22)
            if let summary {
                VStack(spacing: 0) {
                    pullRow(L10n.tr("pair.pull.settings"), value: summary.settings ? "✓" : "—",
                            tone: summary.settings ? KhaytDesign.done : KhaytDesign.note)
                    pullRow(L10n.tr("pair.pull.open_orders"), value: summary.openOrders.formatted(.number.locale(L10n.locale)))
                    pullRow(L10n.tr("pair.pull.newest_finished"), value: summary.newestFinished.formatted(.number.locale(L10n.locale)),
                            tone: summary.finishedWindowed ? KhaytDesign.attention : KhaytDesign.ink)
                    pullRow(L10n.tr("tab.clients"), value: summary.clients.formatted(.number.locale(L10n.locale)))
                    pullRow(L10n.tr("tab.inventory"), value: summary.inventory.formatted(.number.locale(L10n.locale)))
                    pullRow(L10n.tr("tab.machines"), value: summary.machines.formatted(.number.locale(L10n.locale)), last: true)
                }
                .background(KhaytDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                if summary.omittedAnything {
                    foot(L10n.tr("pair.pull.foot")).padding(.top, 12)
                }
            }
            Spacer(minLength: 18)
            primary(L10n.tr("pair.finish")) { settings.isPaired = true }
        }
    }

    private func pullRow(_ label: String, value: String, tone: Color = KhaytDesign.ink, last: Bool = false) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(KhaytDesign.done)
                .frame(width: 22, height: 22)
                .background(KhaytDesign.done.opacity(0.14), in: Circle())
            Text(label)
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.khayt(14.5, .semibold, relativeTo: .subheadline).monospacedDigit())
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.khayt(28, .semibold, relativeTo: .largeTitle))
            .tracking(-0.5)
            .foregroundStyle(KhaytDesign.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func lead(_ text: String) -> some View {
        Text(text)
            .font(.khayt(14.5, relativeTo: .subheadline))
            .foregroundStyle(KhaytDesign.note)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
    }

    private func foot(_ text: String) -> some View {
        Text(text)
            .font(.khayt(12, relativeTo: .caption))
            .foregroundStyle(KhaytDesign.note)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.horizontal, 2)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .khaytTracking(1.05)
            .foregroundStyle(KhaytDesign.note)
    }

    private func fieldLabel(_ text: String) -> some View {
        eyebrow(text).padding(.bottom, 7)
    }

    private func quietLink(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).font(.khayt(15, .medium, relativeTo: .body))
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(KhaytDesign.note)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func primary(_ text: String, busy: Bool = false, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(KhaytDesign.onBrand) } else { Text(text) }
            }
            .font(.khayt(17, .semibold, relativeTo: .headline))
            .foregroundStyle(KhaytDesign.onBrand)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(KhaytDesign.brand.opacity(disabled && !busy ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// A centred text link in the brand colour ("Use the owner PIN instead").
    private func centredLink(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.brand)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The frame's light-filled button (Cancel while waiting for the Mac).
    private func tonal(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.brand)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(KhaytDesign.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private func secondary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }
}

/// The pairing-by-number screens with sample data (`-KhaytPairStep …`),
/// DEBUG only, for comparing the built screens with the signed-off frames.
enum PairShot: String {
    case code, approved, viewer, denied, expired, busy, older

    func apply(step: inout PairingView.Step, notPaired: inout PairingView.NotPaired, olderMac: inout Bool,
               sample: inout String?, role: inout String?) {
        switch self {
        case .code: step = .code; sample = "481207"
        case .approved: step = .approved; role = "operator"
        case .viewer: step = .approved; role = "viewer"
        case .denied: step = .notPaired; notPaired = .denied
        case .expired: step = .notPaired; notPaired = .expired
        case .busy: step = .notPaired; notPaired = .busy
        case .older: step = .pin; olderMac = true
        }
    }
}

/// The design's 56pt input: surface fill, hairline border, a large value.
private struct BigField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.khayt(17, .medium, relativeTo: .body))
            .foregroundStyle(KhaytDesign.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }
}
