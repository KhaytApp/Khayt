import Foundation
import Testing
@testable import KhaytCore

/// The Swift signer against the same published AWS vector the other app's
/// `test/s3-client.test.js` uses — the only way to know a signature is right
/// without a live bucket and a failed upload.
struct S3ClientTests {
    @Test("SigV4 reproduces the AWS get-vanilla published signature")
    func vector() throws {
        let auth = S3.sign(method: "GET", url: try #require(URL(string: "https://example.amazonaws.com/")),
                           headers: ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"],
                           payloadHash: S3.emptySHA256, region: "us-east-1", service: "service",
                           accessKeyId: "AKIDEXAMPLE",
                           secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                           amzDate: "20150830T123600Z")
        #expect(auth == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                + "SignedHeaders=host;x-amz-date, "
                + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test("the query string is signed")
    func query() throws {
        func sig(_ u: String) throws -> String {
            S3.sign(method: "GET", url: try #require(URL(string: u)),
                    headers: ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"],
                    payloadHash: S3.emptySHA256, region: "us-east-1", service: "service",
                    accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                    amzDate: "20150830T123600Z")
        }
        #expect(try sig("https://example.amazonaws.com/") != sig("https://example.amazonaws.com/?Param1=value1"))
    }

    @Test("object keys are the other app's, and a name with spaces or Arabic is encoded once")
    func keys() throws {
        #expect(S3.objectKey(prefix: "/shop-1/", id: "PF-1", filename: "Benchy.3mf") == "shop-1/print-files/PF-1/Benchy.3mf")
        #expect(S3.objectKey(prefix: "", id: "PF-1", filename: "a.stl") == "print-files/PF-1/a.stl")
        let c = S3Config(endpoint: "https://acc.r2.cloudflarestorage.com/", bucket: "lib",
                         accessKeyId: "k", secretAccessKey: "s")
        let r = try S3.request(c, method: "PUT", key: "print-files/PF-1/ملك عبدالعزيز.3mf", body: Data([1, 2]))
        #expect(r.url?.absoluteString.hasPrefix("https://acc.r2.cloudflarestorage.com/lib/print-files/PF-1/%D9%85") == true)
        #expect(r.url?.absoluteString.contains("%20") == true)
        #expect(r.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=k/") == true)
        #expect(r.value(forHTTPHeaderField: "x-amz-content-sha256") == S3.sha256Hex(Data([1, 2])))
    }
}

/// The other app's storage rules, run inside JavaScriptCore on the Mac.
struct CloudLibraryRulesTests {
    @Test("the provider table, an R2 endpoint, and the sidecar all come from the shared rules")
    func rules() async throws {
        let engine = try KhaytEngine()
        let providers = try await engine.storageProviders()
        #expect(providers.contains { $0.id == "r2" && $0.vars.first?.key == "account" })
        let r2 = try await engine.resolveEndpoint(provider: "r2", vars: ["account": "abc123"])
        #expect(r2.ok && r2.endpoint == "https://abc123.r2.cloudflarestorage.com" && r2.region == "auto")
        let missing = try await engine.resolveEndpoint(provider: "r2", vars: [:])
        #expect(!missing.ok && (missing.error ?? "").contains("Account ID"))
        // Byte for byte the other app's sidecar.
        let text = try await engine.sidecarText(size: 10, sha256: "ab", key: "k", provider: "p", at: "2026-09-24T00:00:00.000Z")
        #expect(text == #"{"v":1,"size":10,"sha256":"ab","key":"k","provider":"p","at":"2026-09-24T00:00:00.000Z"}"#)
        let side = try #require(try await engine.parseSidecar(text))
        #expect(side.key == "k" && side.size == 10)
        #expect(try await engine.parseSidecar(#"{"v":1,"size":0}"#) == nil, "an unusable sidecar is refused")
        #expect(try await engine.etagVerdict(etag: "d41d8cd98f00b204e9800998ecf8427e", md5: "d41d8cd98f00b204e9800998ecf8427e") == "match")
        #expect(try await engine.etagVerdict(etag: "abc-3", md5: "d41d8cd98f00b204e9800998ecf8427e") == "unusable")
    }
}
