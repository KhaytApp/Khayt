import Foundation
import KhaytCore

/// Finding a printer that answers nothing where it used to.
///
/// ── WHY mDNS IS NOT ENOUGH, ON THIS SHOP'S OWN PRINTER ────────────────────
///
/// `findMovedPrinters` repairs a machine whose DHCP lease moved it, and it
/// works — given something to match against. It gets that from mDNS, browsing
/// for `_moonraker._tcp` and `_octoprint._tcp`.
///
/// A Snapmaker U1 advertises neither. Browsed on the bench LAN it was printing
/// on, the whole answer was nothing at all — while mDNS itself worked and
/// turned up a NAS and a laser printer. So the owner was shown "no printers on
/// the network" and the fix was a two-second edit nobody could find.
///
/// `lib/printer-sweep.js` was written for exactly this and wired nowhere: not
/// here, not in the other app, not in another module. This is the caller it
/// never had.
///
/// ── DELIBERATELY NARROW, AND NONE OF IT CONFIGURABLE ──────────────────────
///
/// A tool that sweeps a network is a tool that can be mistaken for an attack.
/// The rule bounds what is asked and this bounds how:
///
///   - only the /24 the machine was ALREADY configured on, nearest address
///     first, because a re-lease is almost always next door;
///   - only RFC1918 and link-local, checked per address against the same guard
///     every other outbound request in this app passes;
///   - only ports Khayt already speaks to, one short request each;
///   - a hard cap on how many addresses are tried at once, so this never looks
///     like a flood;
///   - and only when a machine is offline and mDNS has already found nothing.
enum PrinterSweep {

    /// How many addresses to ask at a time.
    ///
    /// Not a performance knob. Two hundred and fifty simultaneous connections
    /// from one host is what a scanner looks like; sixteen is what a program
    /// looking for one printer looks like, and on a /24 it still finishes in a
    /// few seconds.
    static let inFlight = 16

    /// How long one address gets. A printer on the same subnet answers in
    /// milliseconds; anything slower is a device that is not what we want.
    static let perHost: TimeInterval = 1.5

    /// The whole sweep's budget, whatever the arithmetic above suggests.
    static let overall: TimeInterval = 25

    /// Sweep the subnets of the machines given, and return what answered in
    /// the shape `planRelocations` already takes.
    ///
    /// `hosts` are the last-known addresses of the machines that are offline.
    /// Duplicated subnets are swept once: two printers that moved off the same
    /// router share every candidate.
    static func look(from hosts: [String], engine: KhaytEngine) async -> [JSONValue] {
        guard let probes = try? await engine.sweepProbes(), !probes.isEmpty else { return [] }

        // One candidate list per SUBNET, not per machine.
        var candidates: [String] = []
        var seen = Set<String>()
        for host in hosts {
            // ── THE GUARD, ON THE SEED, ONCE ──────────────────────────────
            //
            // `subnetOf` in the rule accepts any IPv4 — the module says in so
            // many words that RFC1918 is "enforced by the caller's existing
            // host guard", and this is that caller. Checking the SEED is
            // enough and is not a shortcut: every candidate is another address
            // in the seed's own /24, and a /24 never straddles the edge of
            // 10/8, 172.16/12 or 192.168/16. One guard call per machine rather
            // than two hundred and fifty-four.
            //
            // The same guard every other outbound request in this app passes,
            // rather than a second LAN test written in Swift — two spellings of
            // "is this a private address" is how one of them comes to be wrong.
            guard (try? await engine.printerHostAllowed(host)) == true else { continue }
            guard let list = try? await engine.sweepCandidates(lastKnownHost: host, limit: 254)
            else { continue }
            for address in list where !seen.contains(address) {
                seen.insert(address)
                candidates.append(address)
            }
        }
        guard !candidates.isEmpty else { return [] }

        let deadline = Date().addingTimeInterval(overall)
        var found: [JSONValue] = []
        var at = 0
        while at < candidates.count, Date() < deadline {
            let slice = Array(candidates[at..<min(at + inFlight, candidates.count)])
            at += slice.count
            // Each address, every protocol, concurrently within the batch.
            let answers = await withTaskGroup(of: (String, String, Int, Data)?.self) { group -> [(String, String, Int, Data)] in
                for address in slice {
                    for probe in probes {
                        group.addTask {
                            await ask(address, port: probe.port, path: probe.path, type: probe.type)
                        }
                    }
                }
                var out: [(String, String, Int, Data)] = []
                for await answer in group { if let answer { out.append(answer) } }
                return out
            }
            for (type, host, status, data) in answers {
                // The RULE decides whether this was a printer, from the body it
                // verified against a real U1 — not a guess made here.
                guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let record = try? await engine.identifySweep(type: type, host: host,
                                                                   status: status, body: body)
                else { continue }
                found.append(record)
            }
        }
        return found
    }

    /// One unauthenticated GET, refused unless the address is a LAN one.
    private static func ask(_ host: String, port: Int, path: String,
                            type: String) async -> (String, String, Int, Data)? {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = perHost
        request.httpMethod = "GET"
        // Says who is asking. A device owner reading a log should find a name,
        // not an anonymous probe.
        request.setValue("Khayt/mac (looking for a configured printer)",
                         forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        session.configuration.timeoutIntervalForRequest = perHost
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        // A body far larger than an info endpoint's is not one.
        guard data.count <= 64 * 1024 else { return nil }
        return (type, host, http.statusCode, data)
    }
}
