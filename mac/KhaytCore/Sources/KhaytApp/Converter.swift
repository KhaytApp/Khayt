import Foundation
import KhaytCore

/// Converting a 3MF for another printer, without Electron.
///
/// ── THE SPLIT, AND WHY ────────────────────────────────────────────────────
///
/// `lib/mf-convert.js` decides what a converted file should contain. It cannot
/// open or write one here: `zip-read` and `zip-write` are built on Node's zlib,
/// which does not exist in JavaScriptCore. So this does the two ends — `Zip`
/// reads, `ZipWrite` writes — and asks the shared rule the question in the
/// middle, which is the only part that is a decision rather than plumbing.
///
/// ── WHAT CROSSES INTO THE ENGINE, AND WHAT MUST NOT ───────────────────────
///
/// Only the small members. A 3MF's configs are a few kilobytes of JSON and XML
/// and are the only things a conversion rewrites; its mesh is up to four
/// hundred megabytes and passes through untouched. Handing that to
/// JavaScriptCore would copy it twice for nothing, so a large member crosses as
/// its NAME and its size alone, and is copied byte-for-byte out of the source
/// file at the end — still compressed, never inflated.
///
/// That is also what makes the guarantee cheap to keep: geometry this app never
/// decodes is geometry it cannot corrupt.
@MainActor
enum Converter {

    /// Above this, a member is passed by name rather than by content.
    ///
    /// Four megabytes clears every `Metadata/*.config` seen in the wild by a
    /// wide margin — the largest in this shop's library is 46 kB — and refuses
    /// meshes, which begin at hundreds of kilobytes and run to hundreds of
    /// megabytes.
    static let inlineLimit = 4 << 20

    enum Failure: Error, CustomStringConvertible, Equatable {
        case notOurs
        case unreadable(String)
        case refused(String)
        case needsTheMesh

        var description: String {
            switch self {
            case .notOurs: return "Another app has this book open."
            case .unreadable(let why): return "Could not read the 3MF: \(why)"
            case .refused(let why): return why
            case .needsTheMesh:
                // Said plainly rather than half-done. Full Spectrum and
                // band-swap rewrite the paint codec inside the mesh itself,
                // which means the whole mesh would have to cross into the
                // engine — the one thing this design exists to avoid.
                return "That colour option rewrites the model itself, which this app cannot do yet. "
                     + "Convert it in Khayt, or choose a plain retarget."
            }
        }
    }

    struct Result: Sendable {
        let url: URL
        /// What the shared rule said it did, for the window to show.
        let report: JSONValue?
    }

    /// Convert `source` for a target printer and write the result to `into`.
    static func convert(_ source: URL, into destination: URL,
                        options: [String: JSONValue], engine: KhaytEngine) async throws -> Result {
        // Paint plans need the mesh in the engine, and the mesh does not go
        // there. Refused UP FRONT rather than after a long read that produces
        // a file quietly missing its colours.
        if truthy(options["fullSpectrum"]) || truthy(options["bandSwap"]) {
            throw Failure.needsTheMesh
        }

        let entries: [Zip.Entry]
        do { entries = try Zip.entries(of: source) }
        catch { throw Failure.unreadable(String(describing: error)) }
        guard !entries.isEmpty else { throw Failure.unreadable("it holds nothing") }

        // What the engine is told about each member: everything small enough to
        // decide about, and nothing else.
        var described: [JSONValue] = []
        for entry in entries {
            var member: [String: JSONValue] = [
                "name": .string(entry.name),
                "size": .number(Double(entry.size)),
            ]
            if entry.size <= inlineLimit, let data = try? Zip.data(of: entry, in: source),
               let text = String(data: data, encoding: .utf8) {
                member["data"] = .string(text)
            }
            described.append(.object(member))
        }

        let planned = try await engine.convertMembers(described, options: options)
        guard planned.ok, let members = planned.members else {
            throw Failure.refused(planned.error ?? "the converter refused it")
        }

        // Rebuild. A member the plan rewrote is written from its new text; every
        // other one is copied out of the source, which is how geometry survives
        // a conversion byte for byte.
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ZipWrite.Member] = []
        for member in members {
            if let text = member.text {
                out.append(.init(member.name, Data(text.utf8)))
            } else if let entry = byName[member.name] {
                guard let data = try? Zip.data(of: entry, in: source, limit: .max) else {
                    throw Failure.unreadable("\(member.name) would not come back out")
                }
                out.append(.init(member.name, data))
            } else {
                // The plan named a member the source does not have, which is a
                // rule inventing a file. Better to stop than to write a 3MF
                // with a hole where one is expected.
                throw Failure.refused("the conversion asked for \(member.name), which is not in the file")
            }
        }

        do { try ZipWrite.archive(out).write(to: destination) }
        catch { throw Failure.unreadable(String(describing: error)) }
        return Result(url: destination, report: planned.report)
    }

    private static func truthy(_ value: JSONValue?) -> Bool {
        if case .bool(true) = value { return true }
        return false
    }
}
