import Foundation
import KhaytCore

/// The print's time-lapse as proof (signed frame 7b; the Mac's routes,
/// #2700). The video is on the printer; the MAC copies it into the job's
/// files when asked ("Keep as proof"). The phone asks and shows the answer:
/// it never talks to the printer, and never downloads the video itself.
struct JobTimelapse: Equatable, Sendable {
    enum State: String, Sendable { case none, available, kept, link }

    var state: State
    var bytes: Double?
    var maxBytes: Double?
    /// `over-budget` or `size-unknown`, with `link`.
    var reason: String?
    /// Where the printer serves the video, on the shop's network only.
    var url: URL?
    /// The Mac is copying it now.
    var copying: Bool

    /// How often, and for how long, the card asks while the Mac is copying.
    static let watchEvery = 5
    static let watchRounds = 120

    static let nothing = JobTimelapse(state: .none, bytes: nil, maxBytes: nil, reason: nil, url: nil, copying: false)

    /// From a `GET …/timelapse` (or a keep's 200/201) body. Anything that is
    /// not a 200-family answer with a state this build knows is "none": no
    /// card, never a guess.
    /// `signed`: the Mac signed this answer. Only then is its `url` kept.
    static func read(status: Int, body: Data, signed: Bool = false) -> JobTimelapse {
        guard (200...201).contains(status),
              case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body), o["ok"] == .bool(true),
              case .string(let raw)? = o["state"], let state = State(rawValue: raw) else { return .nothing }
        func number(_ key: String) -> Double? {
            if case .number(let n)? = o[key], n.isFinite, n >= 0 { return n }
            return nil
        }
        var reason: String?
        if case .string(let r)? = o["reason"] { reason = r }
        var url: URL?
        if signed, case .string(let text)? = o["url"] { url = lanURL(text) }
        return JobTimelapse(state: state, bytes: number("bytes"), maxBytes: number("maxBytes"), reason: reason, url: url,
                            copying: o["copying"] == .bool(true))
    }

    /// "Open on the printer" opens only a plain http(s) address on the
    /// shop's own network: a private or link-local address, or a `.local`
    /// name; no other scheme, no credentials in it. (And only from an answer
    /// the Mac signed: see `read`.)
    static func lanURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              isOnTheShopsNetwork(host) else { return nil }
        return url
    }

    static func isOnTheShopsNetwork(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if parts.count == 4, let a = parts[0], let b = parts[1], parts[2] != nil, parts[3] != nil,
           parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) {
            return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        // IPv6 link-local and unique-local, as a URL host writes them.
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return v6.hasPrefix("fe80:") || v6.hasPrefix("fc") && v6.contains(":") || v6.hasPrefix("fd") && v6.contains(":")
    }

    /// "34 MB", in the app's language and Western digits.
    static func megabytes(_ bytes: Double?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        // The Mac's megabytes (1,048,576 bytes): its 150 MB limit is 157,286,400 bytes.
        let mb = bytes / 1_048_576
        let figure = mb < 10 ? (mb * 10).rounded() / 10 : mb.rounded()
        return L10n.format("lapse.mb", figure.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)))
    }

    /// Whether the card shows at all.
    var shows: Bool { state != .none }

    var title: String {
        switch state {
        case .kept: return L10n.tr("lapse.kept.title")
        case .link: return L10n.tr("lapse.link.title")
        default: return L10n.tr("lapse.available.title")
        }
    }

    var sub: String {
        switch state {
        case .kept: return L10n.tr("lapse.kept.sub")
        case .link:
            if reason == "over-budget", let limit = Self.megabytes(maxBytes) { return L10n.format("lapse.link.over", limit) }
            return L10n.tr("lapse.link.unknown")
        default: return L10n.tr(copying ? "lapse.copying" : "lapse.available.sub")
        }
    }

    enum Kept: Equatable, Sendable {
        case done(JobTimelapse)
        case refused(String)
        /// No answer: the copy may still be running on the Mac.
        case noAnswer
    }

    /// An answer the Mac did not sign (#2700 signs them) is not believed as
    /// kept or as refused: it is "no answer", and the card asks the Mac what
    /// is true. A plain 404 from a computer without the route signs nothing.
    static func kept(status: Int, body: Data, signed: Bool = true) -> Kept {
        if !signed {
            let ours = (try? JSONDecoder().decode(JSONValue.self, from: body)) != nil
            return status == 404 && !ours ? .refused("not-offered") : .noAnswer
        }
        let read = Self.read(status: status, body: body, signed: true)
        if read.state == .kept || read.state == .link { return .done(read) }
        var reason = status == 404 ? "not-offered" : "unreachable"
        if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body), case .string(let r)? = o["reason"] { reason = r }
        return .refused(reason)
    }

    static func words(_ reason: String) -> String {
        let known: Set<String> = ["no-timelapse", "no-machine", "copying", "read-only", "cancelled", "not-saved",
                                  "printer-unreachable", "busy", "role-scope", "device-key-required", "not-offered"]
        return L10n.tr("lapse.why." + (known.contains(reason) ? reason : "unreachable"))
    }

    /// THE ROLE GATE for "Keep as proof", in one line: the Mac's
    /// `orders:write` (operator and up). The Mac checks it either way.
    static func mayKeep(role: String) -> Bool { DeviceRole.allows(role, "orders:write") }

    /// Asked only in reach of the Mac, never on the sample shop.
    static func asks(macInReach: Bool, sampleShop: Bool) -> Bool { macInReach && !sampleShop }
}

extension KhaytAPIClient {
    /// Whether the job has a time-lapse, as the Mac says. None with no
    /// answer, a computer without the route, or a role it refuses.
    func jobTimelapse(orderId: String) async -> JobTimelapse {
        guard let answer = await jobTimelapseAnswer(orderId: orderId) else { return .nothing }
        return JobTimelapse.read(status: answer.status, body: answer.body, signed: answer.signed)
    }

    /// "Keep as proof": the Mac copies the video and answers when it is done.
    /// A copy can outlast any wait the phone's requests allow (30 seconds for
    /// a whole request), so no answer is not a failure: the card then watches
    /// the Mac's own `copying` until it ends (`JobTimelapseCard`).
    func keepTimelapse(orderId: String) async -> JobTimelapse.Kept {
        guard let answer = await jobTimelapseAnswer(orderId: orderId, keep: true) else { return .noAnswer }
        return JobTimelapse.kept(status: answer.status, body: answer.body, signed: answer.signed)
    }
}
