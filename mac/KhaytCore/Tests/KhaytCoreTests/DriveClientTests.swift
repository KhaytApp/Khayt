import Foundation
import Testing
@testable import KhaytCore

/// A Google in memory: the token endpoint, the Drive API and the resumable
/// upload, answering as Google documents them.
final class FakeGoogle: @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: (name: String, parent: String?, key: String?, data: Data, folder: Bool, trashed: Bool)] = [:]
    var refreshes = 0
    var nextId = 1
    var uploads: [String: String] = [:]   // upload URL → file id

    func md5(_ d: Data) -> String {
        Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    var fetch: S3.Fetch {
        { [self] r in
            let url = r.url!
            func answer(_ code: Int, _ json: Any = [String: Any](), headers: [String: String] = [:]) -> (Data, URLResponse) {
                ((try? JSONSerialization.data(withJSONObject: json)) ?? Data(),
                 HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
            }
            return lock.withLock {
                let s = url.absoluteString
                if s == DriveClient.tokenURL {
                    refreshes += 1
                    return answer(200, ["access_token": "at-\(refreshes)", "expires_in": 3600])
                }
                if r.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer at-") != true,
                   uploads[s] == nil { return answer(401) }
                if let id = uploads[s] {                                  // the resumable body
                    files[id]!.data = r.httpBody ?? Data()
                    return answer(200, ["id": id])
                }
                let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                let q = c.queryItems?.first { $0.name == "q" }?.value ?? ""
                if c.path == "/drive/v3/files", r.httpMethod == "GET" {
                    let live = files.filter { !$0.value.trashed }
                    let hit: (String, (name: String, parent: String?, key: String?, data: Data, folder: Bool, trashed: Bool))?
                    if q.contains("khaytKey") {
                        hit = live.first { f in f.value.key.map { q.contains("value='\($0)'") } ?? false }.map { ($0.key, $0.value) }
                    } else {
                        hit = live.first { $0.value.folder && q.contains("name='\($0.value.name)'") }.map { ($0.key, $0.value) }
                    }
                    guard let (id, f) = hit else { return answer(200, ["files": []]) }
                    return answer(200, ["files": [["id": id, "size": String(f.data.count), "md5Checksum": md5(f.data)]]])
                }
                let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
                if c.path == "/drive/v3/files", r.httpMethod == "POST" {             // make the folder
                    let id = "F\(nextId)"; nextId += 1
                    files[id] = (body["name"] as? String ?? "", nil, nil, Data(), true, false)
                    return answer(200, ["id": id])
                }
                if c.path == "/upload/drive/v3/files", r.httpMethod == "POST" {      // start a new upload
                    let id = "M\(nextId)"; nextId += 1
                    let key = (body["appProperties"] as? [String: String])?["khaytKey"]
                    files[id] = (body["name"] as? String ?? "", (body["parents"] as? [String])?.first, key, Data(), false, false)
                    let loc = "https://upload.example/session/\(id)"
                    uploads[loc] = id
                    return answer(200, headers: ["Location": loc])
                }
                if c.path.hasPrefix("/drive/v3/files/"), let id = c.path.split(separator: "/").last.map(String.init) {
                    if r.httpMethod == "PATCH" { files[id]?.trashed = (body["trashed"] as? Bool) ?? false; return answer(200, ["id": id]) }
                    if c.queryItems?.contains(where: { $0.name == "alt" }) == true, let f = files[id] {
                        return (f.data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                }
                return answer(404)
            }
        }
    }
}

import CryptoKit

struct DriveClientTests {
    @Test("PKCE S256 reproduces RFC 7636's own example")
    func pkceVector() {
        #expect(DriveClient.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pair = DriveClient.pkce()
        #expect(pair.verifier.count >= 43 && DriveClient.challenge(for: pair.verifier) == pair.challenge)
    }

    @Test("the consent URL asks for drive.file only, offline, with a fresh consent and PKCE")
    func consentURL() throws {
        let url = DriveClient.authorizeURL(clientId: " abc.apps.googleusercontent.com ", redirectURI: "http://127.0.0.1:5000/callback",
                                           challenge: "CH", state: "ST")
        let items = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            .map { ($0.name, $0.value ?? "") })
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(items["client_id"] == "abc.apps.googleusercontent.com")
        #expect(items["access_type"] == "offline" && items["prompt"] == "consent")
        #expect(items["code_challenge"] == "CH" && items["code_challenge_method"] == "S256" && items["state"] == "ST")
    }

    @Test("a round trip: folder made once, tagged upload, found by key, MD5 as the etag, downloaded, trashed")
    func roundTrip() async throws {
        let google = FakeGoogle()
        let drive = DriveClient(.init(clientId: "c", refreshToken: "r"), fetch: google.fetch)
        let data = Data((0..<10_000).map { UInt8($0 % 253) })
        try await drive.put("print-files/PF-1/Benchy.3mf", data: data)
        let head = try #require(try await drive.head("print-files/PF-1/Benchy.3mf"))
        #expect(head.size == data.count)
        #expect(head.etag == google.md5(data), "the tiering rule proves a Drive upload by this")
        #expect(try await drive.get("print-files/PF-1/Benchy.3mf") == data)
        #expect(try await drive.head("print-files/PF-2/other.stl") == nil)
        try await drive.put("print-files/PF-2/other.stl", data: Data([1, 2, 3]))
        #expect(google.files.values.filter(\.folder).count == 1, "one app folder, found again rather than made twice")
        #expect(google.refreshes == 1, "the access token is kept until it nears expiry")
        try await drive.delete("print-files/PF-1/Benchy.3mf")
        #expect(try await drive.head("print-files/PF-1/Benchy.3mf") == nil)
        #expect(google.files.values.contains { $0.trashed && $0.key == "print-files/PF-1/Benchy.3mf" },
                "to Drive's trash, not gone")
    }

    @Test("a key with a quote in it cannot break out of the query")
    func quoting() {
        #expect(DriveClient.quoted("it's") == #"'it\'s'"#)
        #expect(DriveClient.quoted(#"a\b"#) == #"'a\\b'"#)
    }
}
