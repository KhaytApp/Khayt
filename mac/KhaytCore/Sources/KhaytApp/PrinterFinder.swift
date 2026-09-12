import Foundation
import Network
import os
import KhaytCore

/// Finding a printer on the workshop network, so nobody types an IP address.
///
/// ── WHY BONJOUR AND NOT OUR OWN MULTICAST ─────────────────────────────────
///
/// Khayt has a dependency-free mDNS codec in `lib/mdns.js`, and the Electron app
/// uses it with a socket of its own. This app deliberately does not.
///
/// Local network privacy on macOS fails CLOSED on an IPC timing bug that Apple's
/// DTS has described in detail: multicast stops working after a reboot, the
/// denial is cached until the Mac restarts or somebody toggles the switch in
/// System Settings, and several copies of one app on a machine make it more
/// likely — which is the ordinary state of a Mac that builds this app. It is
/// fixed in macOS 26.5. This app's floor is 26.0, so shipping a raw multicast
/// socket would mean shipping a feature that silently stops for some shops and
/// cannot be diagnosed from inside the app.
///
/// `NWBrowser` asks `mDNSResponder` instead. That daemon already holds the
/// multicast group; the app only asks it what it has seen.
///
/// WHAT IS STILL SHARED IS THE PART THAT MATTERS. Deciding that a
/// `_moonraker._tcp` instance is a Klipper printer Khayt can talk to, which
/// catalog entry it is, and what to pre-select — that is
/// `lib/printer-discovery.js`, and this hands it the same PTR/SRV/TXT/A records
/// the codec would have produced.
@MainActor
final class PrinterFinder {

    /// One browser per service type, held while a scan runs.
    private var browsers: [NWBrowser] = []
    private var seen: [String: Found] = [:]

    private struct Found {
        let instance: String
        let service: String
        var host: String?
        var port: Int?
        var txt: [String: String]
    }

    /// Look for printers, for as long as the caller allows.
    ///
    /// Owner-initiated and time-boxed — never on a timer. A scan that runs in
    /// the background is a scan nobody consented to, and this one asks the
    /// system for permission the first time it runs.
    func find(for seconds: Double = 4, engine: KhaytEngine) async -> [KhaytEngine.FoundPrinter] {
        seen = [:]
        defer { stop() }

        // One browser per service type. Starting them is not async — a browser
        // reports through a handler — so there is nothing here to run in
        // parallel, and a task group only confused the isolation checker.
        for service in (try? await engine.discoveryServices()) ?? [] { browse(service) }
        try? await Task.sleep(for: .seconds(seconds))
        stop()

        // Resolving is a separate step: a browser reports that something EXISTS,
        // and its address has to be asked for.
        await resolveAll()
        return (try? await engine.printersFrom(records: records())) ?? []
    }

    private func browse(_ service: String) {
        // `_moonraker._tcp.local` in the shared list; NWBrowser wants the type
        // and the domain apart.
        let type = service.replacingOccurrences(of: ".local", with: "")
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.note(results, service: service) }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    private func note(_ results: Set<NWBrowser.Result>, service: String) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                // `dictionary` is already [String: String] on this platform;
                // an entry with no value is a flag, not a pair.
                for (key, value) in record.dictionary { txt[key] = value }
            }
            // The instance name in the shape `printer-discovery.js` expects.
            let instance = "\(name).\(service)"
            seen[instance] = Found(instance: instance, service: service,
                                   host: seen[instance]?.host, port: seen[instance]?.port,
                                   txt: txt)
        }
    }

    /// Ask for each instance's address.
    ///
    /// A Bonjour browse says a service is THERE; the address comes from
    /// resolving it, which is one short connection per device.
    private func resolveAll() async {
        await withTaskGroup(of: (String, String?, Int?).self) { group in
            for (key, found) in seen {
                group.addTask {
                    let type = found.service.replacingOccurrences(of: ".local", with: "")
                    let name = String(found.instance.dropLast(found.service.count + 1))
                    let (host, port) = await Self.resolve(name: name, type: type)
                    return (key, host, port)
                }
            }
            for await (key, host, port) in group {
                seen[key]?.host = host
                seen[key]?.port = port
            }
        }
    }

    private nonisolated static func resolve(name: String, type: String) async -> (String?, Int?) {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.service(name: name, type: type, domain: "local.", interface: nil)
            let connection = NWConnection(to: endpoint, using: .tcp)
            // Answered once, whichever way it goes: a continuation resumed twice
            // is a crash, and a browser that finds two printers would find it.
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (String?, Int?) -> Void = { host, port in
                let first = done.withLock { was -> Bool in
                    if was { return false }
                    was = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: (host, port))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        // `fe80::1%en0` — the interface is not part of the address.
                        let text = String("\(host)".split(separator: "%").first ?? "")
                        finish(text, Int(port.rawValue))
                    } else { finish(nil, nil) }
                case .failed, .cancelled:
                    finish(nil, nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            // A printer that advertises and will not answer must not hold the
            // scan open.
            Task {
                try? await Task.sleep(for: .seconds(3))
                finish(nil, nil)
            }
        }
    }

    /// What the system found, in the record shape the shared rule reads.
    ///
    /// PTR, SRV, TXT and A — exactly what `collectDevices` stitches together
    /// when the Electron app decodes real datagrams.
    private func records() -> [JSONValue] {
        var out: [JSONValue] = []
        for found in seen.values {
            guard let host = found.host, !host.isEmpty else { continue }
            let target = found.instance + ".target"
            out.append(.object(["name": .string(found.service), "type": .number(12),
                                "ptr": .string(found.instance)]))
            out.append(.object(["name": .string(found.instance), "type": .number(33),
                                "srv": .object(["port": .number(Double(found.port ?? 0)),
                                                "target": .string(target)])]))
            out.append(.object(["name": .string(found.instance), "type": .number(16),
                                "txt": .object(found.txt.mapValues { .string($0) })]))
            out.append(.object(["name": .string(target), "type": .number(1),
                                "a": .string(host)]))
        }
        return out
    }

    private func stop() {
        for browser in browsers { browser.cancel() }
        browsers = []
    }
}
