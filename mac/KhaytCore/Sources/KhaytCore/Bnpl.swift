import Foundation

/// Carrying Khayt's Tabby / Tamara requests (`lib/bnpl-requests.js`).
///
/// ── WHY THIS IS SO SMALL ───────────────────────────────────────────────────
///
/// What is sent and what an answer means are the shared module's: the body of
/// a checkout, which host a Saudi Tabby key belongs on, that Tamara's
/// "approved" needs an authorise and Tabby's "AUTHORIZED" a capture, which
/// figure is captured. The desktop's main process carries the very same plans
/// (`lib/main/payment-links.js`). This only asks the plan what to send, sends
/// it with the shop's key, and hands the answer back until the plan says it is
/// over — so the two apps cannot drift into two ideas of "paid".
///
/// Portable (Foundation only): the phone could carry it too.
public enum BnplClient {

    /// One round trip. The default is `URLSession.shared`; tests pass a stub,
    /// because there are no sandbox keys and no test may reach a provider.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Run `flow` to its result. `key` is the shop's key, already opened from
    /// the book — never anything typed into a window. The plan's own checks
    /// (an unknown provider, an id that could change the URL) come first, and
    /// a missing key is said after them, as the desktop says it.
    public static func run(_ flow: String, args: JSONValue, key: String, engine: KhaytEngine,
                           fetch: Fetch) async throws -> BnplResult {
        var replies: [BnplReply] = []
        var step = try await engine.bnplPlan(flow: flow, args: args, replies: replies)
        if let result = step.result { return result }
        guard !key.isEmpty else { return BnplResult(ok: false, error: "No API key configured") }
        while let request = step.request {
            do {
                replies.append(try await send(request, key: key, fetch: fetch))
            } catch {
                // A network failure, said as the desktop says one: the link is
                // left as it was and the next look tries again.
                return BnplResult(ok: false, error: error.localizedDescription)
            }
            step = try await engine.bnplPlan(flow: flow, args: args, replies: replies)
            if let result = step.result { return result }
        }
        return BnplResult(ok: false, error: "No result")
    }

    static func send(_ plan: BnplRequest, key: String, fetch: Fetch) async throws -> BnplReply {
        guard let url = URL(string: plan.url), url.scheme == "https" else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: (plan.timeoutMs ?? 15000) / 1000)
        request.httpMethod = plan.method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = plan.body { request.httpBody = try JSONValue.encode(body) }
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `res.json().catch(() => ({}))`: an answer that is not JSON is empty.
        let parsed = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        return BnplReply(ok: (200..<300).contains(status), status: status, data: parsed)
    }
}

/// One answer from a provider, as the plan reads it.
public struct BnplReply: Sendable, Equatable {
    public let ok: Bool
    public let status: Int
    public let data: JSONValue
    public init(ok: Bool, status: Int, data: JSONValue) {
        self.ok = ok; self.status = status; self.data = data
    }
    var json: JSONValue {
        .object(["ok": .bool(ok), "status": .number(Double(status)), "data": data])
    }
}

/// What `KhaytBnplRequests.plan` says next: a request to send, or the result.
public struct BnplStep: Decodable, Sendable {
    public let request: BnplRequest?
    public let result: BnplResult?
}

public struct BnplRequest: Decodable, Sendable, Equatable {
    public let method: String
    public let url: String
    public let body: JSONValue?
    public let timeoutMs: Double?
}

/// The end of a flow. One shape for the three: a checkout fills `url` and the
/// id to follow; a check fills `state`, `remoteStatus` and `step`; a capture
/// fills `captured`.
public struct BnplResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var status: Int?
    public var error: String?
    public var url: String?
    public var checkoutId: String?
    public var paymentId: String?
    public var orderId: String?
    public var state: String?
    public var remoteStatus: String?
    public var step: String?
    public var captured: Bool?

    public init(ok: Bool, status: Int? = nil, error: String? = nil, url: String? = nil,
                checkoutId: String? = nil, paymentId: String? = nil, orderId: String? = nil,
                state: String? = nil, remoteStatus: String? = nil, step: String? = nil,
                captured: Bool? = nil) {
        self.ok = ok; self.status = status; self.error = error; self.url = url
        self.checkoutId = checkoutId; self.paymentId = paymentId; self.orderId = orderId
        self.state = state; self.remoteStatus = remoteStatus; self.step = step; self.captured = captured
    }

    /// A provider's status is a string by its docs; anything else is read as
    /// absent rather than failing the whole answer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return String(n) }
            return nil
        }
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        status = (try? c.decodeIfPresent(Double.self, forKey: .status)).flatMap { $0.map { Int($0) } }
        error = text(.error)
        url = text(.url)
        checkoutId = text(.checkoutId)
        paymentId = text(.paymentId)
        orderId = text(.orderId)
        state = text(.state)
        remoteStatus = text(.remoteStatus)
        step = text(.step)
        captured = try? c.decodeIfPresent(Bool.self, forKey: .captured)
    }

    var json: JSONValue {
        (try? JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(self))) ?? .object(["ok": .bool(ok)])
    }
}
