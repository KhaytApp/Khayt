import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// Telling a printer what to do.
///
/// The Mac app could watch seven protocols and touch none of them. These pin
/// the shapes it sends — which come from `lib/printer-commands.js`, not from
/// Swift — and the guards around the socket.
@MainActor
struct PrinterControlTests {

    static func engine() throws -> KhaytEngine { try KhaytEngine() }

    /// Each protocol spells this differently, and the differences are the
    /// corrections the shared module carries.
    @Test("the request for each protocol is the shared module's, not a Swift copy")
    func shapes() async throws {
        let e = try Self.engine()

        let moonraker = try await e.printerCommand(type: "moonraker", command: "pause")
        #expect(moonraker.method == "POST")
        #expect(moonraker.path == "/printer/print/pause")

        // OctoPrint TOGGLES when the action is omitted, so "pause" and "resume"
        // would become the same button. The action is always explicit.
        let octoPause = try await e.printerCommand(type: "octoprint", command: "pause")
        let octoResume = try await e.printerCommand(type: "octoprint", command: "resume")
        #expect(octoPause.path == "/api/job")
        #expect(octoPause.body != octoResume.body, "pause and resume send the same body")

        // PrusaLink keys its endpoints by the running job's id.
        #expect(try await e.printerCommandNeedsJobId(type: "prusalink"))
        #expect(try await e.printerCommandNeedsJobId(type: "moonraker") == false)
        let prusa = try await e.printerCommand(type: "prusalink", command: "cancel", jobId: "7")
        #expect(prusa.method == "DELETE")
        #expect(prusa.path?.contains("7") == true, "the job id is not in the path")
    }

    /// "Bambu requires Bambu Connect for remote job control" is a sentence a
    /// shop can act on. A request that failed obscurely is not.
    @Test("a protocol that cannot be told anything says so")
    func unsupported() async throws {
        let e = try Self.engine()
        let bambu = try await e.printerCommand(type: "bambu", command: "pause")
        #expect(bambu.unsupported?.isEmpty == false)
        #expect(bambu.path == nil, "built a request for a protocol that has none")

        let nothing = try await e.printerCommand(type: "", command: "pause")
        #expect(nothing.unsupported?.isEmpty == false)
    }

    /// Cancel is the one that cannot be taken back by pressing the other button.
    @Test("only cancelling is destructive")
    func destructive() {
        #expect(PrinterControl.Verb.cancel.isDestructive)
        #expect(!PrinterControl.Verb.pause.isDestructive)
        #expect(!PrinterControl.Verb.resume.isDestructive)
        #expect(PrinterControl.Verb.allCases.count == 3)
    }

    // ── DROPPING ONE OBJECT ────────────────────────────────────────────────

    @Test("the plate is read into objects, excluded and what is left")
    func plate() async throws {
        let e = try Self.engine()
        let reply: [String: JSONValue] = ["result": .object(["status": .object([
            "exclude_object": .object([
                "objects": .array([.object(["name": .string("A")]),
                                   .object(["name": .string("B")]),
                                   .object(["name": .string("C")])]),
                "excluded_objects": .array([.string("B")]),
                "current_object": .string("A"),
            ]),
        ])])]
        let plate = try await e.plate(reply)
        #expect(plate.supported)
        #expect(plate.remaining == ["A", "C"], "an object already dropped was offered again")
        #expect(plate.current == "A")
    }

    /// A printer that cannot do this is a setting to change — a different
    /// sentence from "nothing is printing", and the screen says each.
    @Test("a printer without the module is told apart from an empty plate")
    func unsupportedPlate() async throws {
        let e = try Self.engine()
        let none = try await e.plate(["result": .object(["status": .object([:])])])
        #expect(!none.supported)

        let empty = try await e.plate(["result": .object(["status": .object([
            "exclude_object": .object(["objects": .array([]),
                                       "excluded_objects": .array([])]),
        ])])])
        #expect(empty.supported)
        #expect(empty.remaining.isEmpty)
    }

    /// THE GUARD THE WHOLE FEATURE RESTS ON. The name goes inside a G-code
    /// script and comes out of a sliced file — a stranger's file, if downloaded.
    /// Nothing is escaped; a name the printer did not just report is refused.
    @Test("a name the printer did not report is refused")
    func injection() async throws {
        let e = try Self.engine()
        let reply: [String: JSONValue] = ["result": .object(["status": .object([
            "exclude_object": .object([
                "objects": .array([.object(["name": .string("A")]),
                                   .object(["name": .string("B")])]),
                "excluded_objects": .array([]),
            ]),
        ])])]
        for attack in ["A\nM104 S300", "A; G28", "A ", "", "Nonexistent"] {
            let out = try await e.excludeObject(attack, plate: reply)
            #expect(out.path == nil, "built a command for \(attack.debugDescription)")
        }
        let ok = try await e.excludeObject("A", plate: reply)
        #expect(ok.path?.contains("EXCLUDE_OBJECT") == true)
    }

    /// Said by the rule, not by the screen, so the warning and the behaviour
    /// cannot come apart.
    @Test("dropping an object is not reversible, and the rule says so")
    func notReversible() async throws {
        #expect(try await Self.engine().excludeIsReversible() == false)
    }

    // ── THE SOCKET ─────────────────────────────────────────────────────────

    /// The Duet flavour the poller learned is keyed on the ADDRESS. Its local
    /// is called `base64` and holds no encoding — a lookup that encoded it
    /// would look right and match nothing, which is what this caught.
    @Test("the remembered Duet flavour is looked up the way it is stored")
    func duetFlavourKey() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/PrinterWatch.swift"), encoding: .utf8)
        #expect(source.contains("duetFlavours[base.absoluteString]"),
                "the lookup no longer matches how the poller stores it")
        #expect(!source.contains("base64EncodedString()] ?? \"\""),
                "the flavour key is being encoded again")
    }

    /// It reaches a LAN device on the shop's behalf, so a 302 must not be able
    /// to move a `cancel` onto a different address — the same rule the poller
    /// follows, and the reason its host check is reused rather than repeated.
    @Test("commands go through the same host guard and refuse redirects")
    func guards() throws {
        let control = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/PrinterControl.swift"), encoding: .utf8)
        #expect(control.contains("PrinterWatch.baseURL"), "no host allowlist on the command path")
        #expect(!control.contains("URLSession.shared"), "a session that follows redirects")

        let watch = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/PrinterWatch.swift"), encoding: .utf8)
        let send = watch[watch.range(of: "static func send(")!.lowerBound...]
        let body = String(send.prefix(2200))
        #expect(body.contains("Refusal.redirected"), "send does not refuse a redirect")
    }

    /// The key is opened at the moment it is sent and never held, and an unset
    /// one is sent as NOTHING — `main.js` records sending the literal string
    /// "undefined" as a header value.
    @Test("an unset API key is not sent")
    func noJunkKey() throws {
        let control = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/PrinterControl.swift"), encoding: .utf8)
        #expect(control.contains("Secrets.open"), "the sealed key is never opened")
        #expect(control.contains("else { return \"\" }"), "an unset key is not sent as empty")
    }
}
