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

    /// The root model — the member that is the mesh, and the one member whose
    /// LAYOUT the rule still has to see.
    ///
    /// A 3MF's `<build>` block lists where each object sits on the bed. It is a
    /// line per object at the end of a file that is otherwise triangles, and
    /// re-placing those items is how a conversion keeps the plates centred when
    /// the target bed is a different size. Passing this member by name alone
    /// meant the rule had nothing to read and the conversion failed outright —
    /// so the block crosses on its own, and comes back on its own.
    static func isRootModel(_ name: String) -> Bool {
        name.lowercased().hasSuffix("3d/3dmodel.model")
    }

    /// Where `<build>…</build>` sits in a root model's bytes.
    ///
    /// Bytes rather than text on purpose: the block is spliced back in at
    /// exactly the range it was taken from, so four hundred megabytes of mesh
    /// are never decoded into a String to have one line changed. Nil when the
    /// file has no build block (`<build/>`, or a CAD export that has none),
    /// which is a file with no layout to re-tile rather than a failure.
    static func buildBlockRange(in data: Data) -> Range<Data.Index>? {
        var from = data.startIndex
        while let open = data.range(of: Data("<build".utf8), in: from..<data.endIndex) {
            // `<buildinfo` is not `<build`. The element name ends at a space or
            // at the closing angle bracket, and nothing else counts.
            let after = open.upperBound
            if after < data.endIndex,
               data[after] == UInt8(ascii: ">") || data[after] == UInt8(ascii: " ")
                || data[after] == UInt8(ascii: "\n") || data[after] == UInt8(ascii: "\r")
                || data[after] == UInt8(ascii: "\t") {
                guard let close = data.range(of: Data("</build>".utf8), in: after..<data.endIndex)
                else { return nil }
                return open.lowerBound..<close.upperBound
            }
            from = after
        }
        return nil
    }

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
            } else if isRootModel(entry.name),
                      let data = try? Zip.data(of: entry, in: source, limit: .max),
                      let range = buildBlockRange(in: data),
                      let block = String(data: Data(data[range]), encoding: .utf8) {
                // The mesh still does not cross. Its layout does, on its own —
                // kilobytes of it, out of a member that may be hundreds of
                // megabytes. Read again at the splice rather than held here,
                // because holding it would put the whole mesh alongside the
                // engine for the length of the call, which is the cost this
                // design exists to avoid.
                member["build"] = .string(block)
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
            } else if let block = member.buildBlock {
                // A re-tiled layout, put back exactly where it came from. The
                // triangles either side of it are the bytes that were there.
                guard let entry = byName[member.name],
                      var data = try? Zip.data(of: entry, in: source, limit: .max),
                      let range = buildBlockRange(in: data) else {
                    throw Failure.unreadable("\(member.name)'s plate layout would not go back in")
                }
                data.replaceSubrange(range, with: Data(block.utf8))
                out.append(.init(member.name, data))
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
