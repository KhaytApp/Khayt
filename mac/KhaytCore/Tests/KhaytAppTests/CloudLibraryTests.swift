import Foundation
import CryptoKit
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// A bucket in memory that can be told to lie — the only way to prove the one
/// destructive step (freeing space deletes the local copy) waits for proof.
final class FakeBucket: @unchecked Sendable {
    enum Lie { case none, shortSize, wrongEtag, noEtagWrongBody, dropsPut }
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    var lie = Lie.none
    private(set) var puts = 0

    func object(_ path: String) -> Data? { lock.withLock { objects[path] } }
    func remove(_ path: String) { _ = lock.withLock { objects.removeValue(forKey: path) } }

    var fetch: S3.Fetch {
        { [self] request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let url = request.url!
            func answer(_ code: Int, _ data: Data = Data(), _ headers: [String: String] = [:]) -> (Data, URLResponse) {
                (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
            }
            return lock.withLock {
                switch method {
                case "PUT":
                    puts += 1
                    if lie != .dropsPut { objects[path] = request.httpBody ?? Data() }
                    return answer(200)
                case "HEAD":
                    guard let d = objects[path] else { return answer(404) }
                    let md5 = Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
                    let size = lie == .shortSize ? d.count - 1 : d.count
                    var h = ["Content-Length": String(size)]
                    switch lie {
                    case .wrongEtag: h["ETag"] = "\"00000000000000000000000000000000\""
                    case .noEtagWrongBody: h["ETag"] = "\"abc-2\""
                    default: h["ETag"] = "\"\(md5)\""
                    }
                    return answer(200, Data(), h)
                case "GET":
                    guard var d = objects[path] else { return answer(404) }
                    if lie == .noEtagWrongBody, !d.isEmpty { d[0] ^= 0xFF }
                    return answer(200, d)
                case "DELETE":
                    objects.removeValue(forKey: path)
                    return answer(204)
                default: return answer(400)
                }
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct CloudLibraryTests {
    let config = S3Config(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "lib",
                          accessKeyId: "k", secretAccessKey: "s")

    func model(_ bytes: Int = 4096) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cl-\(UUID().uuidString)/PF-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Benchy.3mf")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    @Test("an honest bucket: uploaded once, proved, and a second call does not upload again")
    func honest() async throws {
        let bucket = FakeBucket()
        CloudLibrary.fetch = bucket.fetch
        let engine = try KhaytEngine()
        let url = try model()
        let proved = try await CloudLibrary.ensureInBucket(.bucket(config), key: "print-files/PF-1/Benchy.3mf", file: url, engine: engine)
        #expect(proved.size == 4096)
        #expect(bucket.object("/lib/print-files/PF-1/Benchy.3mf") == (try Data(contentsOf: url)))
        try await CloudLibrary.ensureInBucket(.bucket(config), key: "print-files/PF-1/Benchy.3mf", file: url, engine: engine)
        #expect(bucket.puts == 1, "already there with the right size and hash: skipped")
    }

    @Test("a bucket that lies is caught: short size, wrong hash, a lost PUT, a corrupt copy behind an unusable etag",
          arguments: [FakeBucket.Lie.shortSize, .wrongEtag, .dropsPut, .noEtagWrongBody])
    func lies(_ lie: FakeBucket.Lie) async throws {
        let bucket = FakeBucket()
        bucket.lie = lie
        CloudLibrary.fetch = bucket.fetch
        let engine = try KhaytEngine()
        let url = try model()
        await #expect(throws: (any Error).self) {
            try await CloudLibrary.ensureInBucket(.bucket(config), key: "print-files/PF-1/Benchy.3mf", file: url, engine: engine)
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "nothing here touches the local file")
    }

    @Test("brought back byte for byte, the sidecar gone; a corrupt copy is refused and the sidecar kept")
    func roundTrip() async throws {
        let bucket = FakeBucket()
        CloudLibrary.fetch = bucket.fetch
        let engine = try KhaytEngine()
        let url = try model()
        let original = try Data(contentsOf: url)
        let key = "print-files/PF-1/Benchy.3mf"
        let proved = try await CloudLibrary.ensureInBucket(.bucket(config), key: key, file: url, engine: engine)
        let text = try await engine.sidecarText(size: proved.size, sha256: proved.sha256, key: key,
                                                provider: config.endpoint, at: "2026-09-24T00:00:00.000Z")
        try Data(text.utf8).write(to: CloudLibrary.sidecar(for: url))
        try FileManager.default.removeItem(at: url)

        let c = CloudLibrary.Config(remote: .bucket(config), prefix: "", backsUp: true, provider: "r2", tier: .object([:]), tierEnabled: true)
        // Corrupt in the bucket: refused, nothing written, the note kept.
        bucket.lie = .noEtagWrongBody
        await #expect(throws: (any Error).self) { try await CloudLibrary.bringBack(url, config: c, engine: engine) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: CloudLibrary.sidecar(for: url).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!leftovers.contains { $0.contains(".part-") })

        bucket.lie = .none
        try await CloudLibrary.bringBack(url, config: c, engine: engine)
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: CloudLibrary.sidecar(for: url).path))
    }

    @Test("plain HTTP only to this Mac or the shop's own network")
    func httpsOnly() throws {
        func ok(_ endpoint: String) -> Bool {
            let c = S3Config(endpoint: endpoint, bucket: "b", accessKeyId: "k", secretAccessKey: "s")
            return (try? S3.request(c, method: "GET", key: "x", body: nil)) != nil
        }
        #expect(ok("https://s3.eu-central-1.amazonaws.com"))
        #expect(!ok("http://s3.eu-central-1.amazonaws.com"))
        #expect(!ok("http://example.com:9000"))
        #expect(ok("http://192.168.1.20:9000"))
        #expect(ok("http://10.0.0.5:9000"))
        #expect(ok("http://localhost:9000"))
        #expect(ok("http://nas.local:9000"))
        #expect(!ok("http://172.40.0.1:9000"))
        #expect(!ok("ftp://192.168.1.20"))
    }
}
