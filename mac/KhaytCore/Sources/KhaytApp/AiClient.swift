import Foundation
import KhaytCore

/// The one place shop data leaves this Mac.
///
/// ── WHAT IS HERE AND WHAT DELIBERATELY IS NOT ─────────────────────────────
///
/// Here: a `URLSession` call, and opening the shop's sealed key.
///
/// Not here: which provider, how that provider spells a request, whether the
/// feature may run at all, how long to wait after a 429, or what sentence a
/// shop reads for a 401. Every one of those is `lib/` — `ai-providers`,
/// `ai-privacy`, `ai-tools` — and `main.js` drives its own transport from
/// exactly the same three. Two apps that disagree about what a 429 means is
/// the failure this shape exists to prevent, and it is the kind nobody notices
/// until a shop is told two different things on two machines.
///
/// ── THE KEY IS OPENED PER CALL AND NEVER HELD ─────────────────────────────
///
/// `settings.ai.apiKey` is sealed on disk — it is a registered path in
/// `lib/store-secret-paths.js`, so the store this syncs, backs up and exports
/// never carries it in the clear. It is opened here, handed to the request
/// builder, and goes out of scope. A cached copy would be a plaintext key
/// living as long as the app does, for no gain: this is a button a person
/// presses, not a poll.
@MainActor
enum AiClient {

    /// Sixty seconds, not thirty. `main.js` says why, and it is not arbitrary:
    /// the default model thinks before it answers and the thinking happens
    /// before the first byte, so a thirty-second ceiling — set when the default
    /// model did not think — aborts a good answer mid-flight, and the shop sees
    /// a network error for a request that was working.
    static let timeout: TimeInterval = 60

    /// Three, the same as the other app.
    static let attempts = 3

    enum Failure: Error, LocalizedError {
        /// The owner has not agreed to this feature. Not a network fault and
        /// not retryable — and the only outcome here that must never be
        /// softened into "try again".
        case notConsented
        case noKey
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .notConsented: return "AI_FEATURE_NOT_CONSENTED"
            case .noKey: return "No API key"
            case .refused(let why): return why
            }
        }
    }

    /// Draft the physical facts of a job from a description.
    ///
    /// Returns the model's draft, already validated by the shared rule. The
    /// caller turns it into a part — this does not, because the part depends on
    /// the shop's shelf and its tax position and those belong to the screen.
    static func draftQuote(_ description: String, shop: Shop) async throws -> JSONValue {
        guard let engine = shop.engine else { throw Failure.refused("no engine") }
        let settings = shop.settingsDict

        // Opened here, used once, never stored.
        var key = ""
        if case .object(let ai)? = settings["ai"], case .string(let sealed)? = ai["apiKey"],
           !sealed.isEmpty {
            key = (try? await Secrets.open(sealed, for: shop.source)) ?? ""
        }

        let request: KhaytEngine.AiRequest
        do {
            request = try await engine.aiQuoteRequest(
                settings: settings, description: description,
                materials: shop.inventoryRows, apiKey: key)
        } catch {
            // `buildRequest` throws for a missing key or model — a
            // CONFIGURATION fault the shop has to see, not something to retry.
            let said = String(describing: error)
            if said.contains("AI_FEATURE_NOT_CONSENTED") { throw Failure.notConsented }
            if said.contains("No API key") { throw Failure.noKey }
            throw Failure.refused(said)
        }

        let data = try await send(request, engine: engine)
        let read = try await engine.aiQuoteRead(settings: settings, response: data)
        guard read.ok, let draft = read.draft else {
            throw Failure.refused(read.problem ?? "no draft")
        }
        return draft
    }

    /// POST it, retrying only what the shared policy says is transient.
    private static func send(_ shaped: KhaytEngine.AiRequest,
                             engine: KhaytEngine) async throws -> JSONValue {
        guard let url = URL(string: shaped.url) else { throw Failure.refused("bad address") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        for (name, value) in shaped.headers { req.setValue(value, forHTTPHeaderField: name) }
        req.httpBody = try JSONEncoder().encode(shaped.body)

        var last = "AI request failed"
        for attempt in 0..<attempts {
            let body: Data
            let response: URLResponse
            do {
                (body, response) = try await URLSession.shared.data(for: req)
            } catch {
                // A network fault or a timeout — transient by nature, so it
                // retries like a 5xx does.
                last = error.localizedDescription
                if attempt + 1 >= attempts { throw Failure.refused(last) }
                try await pause(status: 0, attempt: attempt, retryAfter: nil, engine: engine)
                continue
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .object([:])
            }

            // The SHARED sentence, and the shared decision about whether this
            // is worth trying again.
            let parsed = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
            last = (try? await engine.aiHttpError(status: status, body: parsed)) ?? last
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
            let policy = try? await engine.aiRetry(status: status, attempt: attempt, retryAfter: after)
            guard policy?.retry == true, attempt + 1 < attempts else { throw Failure.refused(last) }
            try await Task.sleep(for: .milliseconds(Int(policy?.afterMs ?? 1000)))
        }
        throw Failure.refused(last)
    }

    private static func pause(status: Int, attempt: Int, retryAfter: String?,
                              engine: KhaytEngine) async throws {
        let policy = try? await engine.aiRetry(status: status, attempt: attempt, retryAfter: retryAfter)
        try await Task.sleep(for: .milliseconds(Int(policy?.afterMs ?? 1000)))
    }
}
