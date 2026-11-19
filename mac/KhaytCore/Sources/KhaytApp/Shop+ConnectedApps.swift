import SwiftUI
import KhaytCore

/// Slicer plugins paired with this Mac (Khayt for OrcaSlicer), pairing a new
/// one, and removing one.
///
/// A connector pairs without the PIN: it asks while the owner has clicked
/// Pair a slicer, the owner sees the same 6-digit number on both screens and
/// approves (`LanConnectorPairing`). Its key opens `/api/connectors/*` only.
/// Approving and removing take the same staff-lock permission as pairing a
/// phone (settings, edit): an owner or manager.
extension Shop {
    func refreshConnectedApps() {
        connectedApps = lanDeviceStore.list().filter { $0.kind == LanDevices.kindConnector }
    }

    func openConnectorPairing() {
        guard permitted("settings", "edit") else { return }
        lanConnectorPairing.open()
    }

    func closeConnectorPairing() {
        lanConnectorPairing.close()
    }

    /// Enrol the plugin that asked, under the PIN the server holds now, so a
    /// PIN change signs it out with the phones.
    func approveConnector() async {
        guard permitted("settings", "edit") else { return }
        // REFUSED when the PIN will not unseal, never enrolled under "". The
        // store makes room under the PIN it is given, so "" took every phone
        // off, and the connector, keyed to a PIN nothing uses, could never
        // connect either (beta.38 review).
        let pin: String
        do { pin = try await Secrets.open(lanConfig.pin, for: source) }
        catch { lanConnectorPairing.refuse(.pinUnreadable); return }
        let store = lanDeviceStore
        let now = Date()
        try? lanConnectorPairing.approve { asked in
            // `approve` only hands over a revealed request; never enrol without a key.
            guard let pluginPublic = asked.pluginPublic else { throw CancellationError() }
            try store.admitConnector(pluginPublic: pluginPublic, serverKey: asked.serverKey,
                                     deviceId: asked.deviceId, name: asked.name, pin: pin, now: now)
        }
        refreshConnectedApps()
    }

    func denyConnector() {
        lanConnectorPairing.deny()
    }

    func removeConnector(_ id: String) {
        guard permitted("settings", "edit") else { return }
        lanDeviceStore.remove(id)
        refreshConnectedApps()
    }
}

/// Settings → Online, under Paired phones. Figma Qqxg4imtKVgC3TfNGcRGOk,
/// page 14 (frames A–C).
struct ConnectedApps: View {
    let shop: Shop
    @State private var removing: LanDevices.Listed?

    var body: some View {
        LabeledContent(shop.words.callIt("mac.apps_title")) {
            if shop.connectedApps.isEmpty {
                Text(shop.words.callIt("mac.apps_none")).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(shop.connectedApps) { app in
                        HStack(spacing: 8) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(verbatim: Self.name(app.name, shop.words)).lineLimit(1).truncationMode(.middle)
                                Text(shop.words.callIt("mac.phones_seen", ["date": .string(
                                    shop.words.say(app.lastSeenAt, .dateTime.day().month(.abbreviated).year()))]))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(shop.words.callIt("mac.apps_remove") + "\u{2026}") { removing = app }
                                .controlSize(.small)
                                .disabled(!shop.lockAllows("settings", "edit"))
                        }
                    }
                }
            }
        }
        PairASlicer(shop: shop)
        Text(shop.words.callIt("mac.apps_hint"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .task { shop.refreshConnectedApps() }
            .askFirst($removing,
                      title: { shop.words.callIt("mac.apps_remove_q", ["name": .string(Self.name($0.name, shop.words))]) },
                      message: { _ in shop.words.callIt("mac.apps_remove_note") },
                      confirm: shop.words.callIt("mac.apps_remove"),
                      cancel: shop.words.callIt("common.cancel")) { app in
                shop.removeConnector(app.id)
            }
    }

    static func name(_ name: String, _ words: Words) -> String {
        name.isEmpty ? words.callIt("mac.apps_unnamed") : name
    }
}

/// "Pair a slicer": the window, the request waiting for the owner with its
/// check number, and how the last window ended.
struct PairASlicer: View {
    let shop: Shop

    private var reachable: Bool { PairAPhone.pretendReachable || (shop.lanURL != nil && shop.lanRunning?.bindLan == true) }

    var body: some View {
        let window = shop.lanConnectorPairing
        let mayApprove = shop.lockAllows("settings", "edit")
        VStack(alignment: .leading, spacing: 6) {
            // Before the plugin reveals its key there is no number, so nothing
            // to compare and nothing to approve: the sheet keeps waiting.
            if let asked = window.pending, let check = asked.check {
                Text(shop.words.callIt("mac.apps_ask", ["name": .string(ConnectedApps.name(asked.name, shop.words))]))
                    .font(.headline)
                Text(shop.words.callIt("mac.apps_ask_from", [
                    "app": .string(asked.app.isEmpty ? "?" : asked.app),
                    "version": .string(asked.version),
                    "address": .string(asked.address)]))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: LanConnectorPairing.spaced(check))
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("connector-check")
                Text(shop.words.callIt("mac.apps_check"))
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text(shop.words.callIt("mac.apps_may"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Button(shop.words.callIt("mac.apps_deny")) { shop.denyConnector() }
                        .disabled(!mayApprove)
                        .accessibilityIdentifier("connector-deny")
                    Button(shop.words.callIt("mac.apps_approve")) { Task { await shop.approveConnector() } }
                        // No default action: Return in Settings at the wrong
                        // moment must not approve a request that has just
                        // appeared (beta.38 review).
                        .disabled(!mayApprove)
                        .accessibilityIdentifier("connector-approve")
                }
            } else if let deadline = window.deadline {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(shop.words.callIt("mac.apps_waiting", ["time": .string(
                            PairAPhone.clock(window.remaining() ?? 0, locale: shop.words.locale))]))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button(shop.words.callIt("common.close")) { shop.closeConnectorPairing() }
                        .controlSize(.small)
                }
                Text(shop.words.callIt("mac.apps_pair_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = shop.lanURL {
                    Text(verbatim: url)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Color.clear.frame(height: 0)
                    .task(id: deadline) {
                        while let left = window.remaining(), !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(left))
                        }
                        guard !Task.isCancelled else { return }
                        _ = window.isOpen()
                    }
            } else {
                HStack {
                    Button(shop.words.callIt("mac.apps_pair")) { shop.openConnectorPairing() }
                        .disabled(!mayApprove || !reachable)
                        .accessibilityIdentifier("connector-pair-open")
                    Spacer(minLength: 0)
                }
                if let said = Self.outcome(window.lastClosed, words: shop.words) {
                    Text(said).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: window.lastClosed) { _, closed in
            if case .paired? = closed { shop.refreshConnectedApps() }
        }
    }

    static func outcome(_ closed: LanConnectorPairing.Closed?, words: Words) -> String? {
        switch closed {
        case .paired(let name)?: return words.callIt("mac.pair_done", ["name": .string(ConnectedApps.name(name, words))])
        case .timedOut?: return words.callIt("mac.apps_timed_out")
        case .offersUsed?: return words.callIt("mac.apps_offers_used")
        case .serverStopped?: return words.callIt("mac.pair_server_stopped")
        case .pinUnreadable?: return words.callIt("mac.apps_pin_unreadable")
        case .byOwner?, nil: return nil
        }
    }
}

extension Shop {
    /// What `lib/connector-price.js` prices a sliced plate with: the shop's
    /// settings (currency, margin, packaging, quote-sheet material), its
    /// shelf, its printer presets (matched by the slicer's printer preset
    /// name) and its overhead by the print hour, as the public quote passes it.
    var slicePriceContext: JSONValue {
        .object([
            "settings": .object(settingsDict),
            "inventory": .array(inventoryRows),
            "printers": .array(presetRows),
            "overheadPerHour": .number(overheadPerHour),
        ])
    }
}
