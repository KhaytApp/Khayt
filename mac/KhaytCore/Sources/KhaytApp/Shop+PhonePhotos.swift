import Foundation
import KhaytCore

/// A paired phone adding a photo to a job: `POST /api/orders/{id}/photos`.
///
/// The phone showed a job's photos (`printLog[].printPhotos[]`, the inline
/// 240px thumb) and could not add one: the full-size copy lives only in
/// `order-photos/` beside the book, on the computer that took it, so a photo
/// the phone wrote into the record itself would be a thumb with no file, and
/// Portfolio would draw a cell nobody can open. Here the phone sends the JPEG
/// and THIS Mac does what its own Add Photo does (`OrderPhoto.encode`, then
/// `attachJobPhoto`): both sizes, the other app's filename, the file before
/// the record, the record stamped.
///
/// The route takes a SIGNED, enrolled phone only (`LanServer`), as the
/// printer route does; an API token cannot reach it. The Mac's staff lock is
/// about the person at THIS Mac and is not asked.
extension Shop {
    /// An HTTP status and a JSON body: `{"ok":true,"index":n,"filename":…}`
    /// or `{"ok":false,"reason":…}`.
    func phoneAddJobPhoto(_ jobId: String, _ data: Data) async -> (Int, String) {
        func refuse(_ status: Int, _ reason: String) -> (Int, String) {
            (status, Self.photoJson(["ok": .bool(false), "reason": .string(reason)]))
        }
        guard let build = source.build, canWrite, let folder = photoFolder else { return refuse(409, "read-only") }
        guard let job = orderRow(jobId) else { return refuse(404, "not-found") }
        guard !data.isEmpty, data.count <= OrderPhoto.maxBytes else { return refuse(413, "too-large") }
        guard let made = OrderPhoto.encode(data) else { return refuse(415, "not-an-image") }
        let index = OrderPhoto.nextIndex(job)
        // lock: system — a paired phone's photo; the LAN route takes a signed enrolled device only.
        if let problem = await attachJobPhoto(made, jobId: jobId, build: build, folder: folder,
                                                gate: .system("a paired phone's photo, over the signed LAN route")) {
            return (500, Self.photoJson(["ok": .bool(false), "reason": .string("write-failed"),
                                         "message": .string(problem)]))
        }
        await load(source)
        // The record as written: its position is the index in its filename.
        var filename: JSONValue = .null
        if case .object(let o)? = orderRow(jobId), case .array(let photos)? = o["printPhotos"],
           photos.indices.contains(index), case .object(let p) = photos[index] {
            filename = p["filename"] ?? .null
        }
        return (201, Self.photoJson(["ok": .bool(true), "index": .number(Double(index)), "filename": filename]))
    }

    private static func photoJson(_ object: [String: JSONValue]) -> String {
        (try? String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self))
            ?? #"{"ok":false,"reason":"encode"}"#
    }
}

extension LanServer {
    /// `/api/orders/{id}/photos` → the job id (already percent-decoded by the
    /// server). Nil for any other shape.
    nonisolated static func jobPhotoPath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "orders",
              parts[4] == "photos", !parts[3].isEmpty else { return nil }
        return String(parts[3])
    }

    /// The photo route, judged from the request line alone, under either name.
    nonisolated static func isJobPhotoUpload(method: String, target: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        var path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/v1/") { path = "/api" + path.dropFirst(3) }
        return jobPhotoPath(path.removingPercentEncoding ?? path) != nil
    }
}
