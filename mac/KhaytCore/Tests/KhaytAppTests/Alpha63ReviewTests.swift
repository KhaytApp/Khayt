import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The review before alpha.63: each finding, held.
@MainActor
struct Alpha63ReviewTests {

    // MARK: 1 — the owner PIN opens a large estimate, and is counted once

    @Test("the owner PIN quotes a model over a megabyte; the consent form stays refused")
    func ownerPinLargeBody() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.book.value = LanServerTests.quotingBook(bench.book.value)
        let big = String(repeating: "s", count: (1 << 20) + 4096)
        let owner = try await bench.post("/api/intake/estimate?name=cube.stl", json: big,
                                         headers: ["x-khayt-pin": "24682468"])
        #expect(owner.status == 200, Comment(rawValue: owner.text))
        // Not the intake form: the PIN never opened it, and a body over a
        // megabyte to it is refused before it is read.
        let submit = try await bench.post("/api/intake", json: #"{"name":"A"}"#,
                                          headers: ["x-khayt-pin": "24682468"])
        #expect(submit.status == 401, Comment(rawValue: submit.text))
        let port = bench.port
        let bigSubmit = await offPool {
            Alpha58SecurityTests.headOnly(port: port, path: "/api/intake", length: 2 << 20,
                                          extra: "X-Khayt-Pin: 24682468\r\n")
        }
        #expect(bigSubmit.hasPrefix("HTTP/1.1 413"), Comment(rawValue: bigSubmit))
    }

    @Test("a wrong PIN on a large body counts once, and the lockout answers 429")
    func wrongPinCountsOnce() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.book.value = LanServerTests.quotingBook(bench.book.value)
        let port = bench.port
        // Nine wrong PINs, refused from the head. Counted twice each, the
        // lockout (ten) would already be reached.
        for _ in 0..<9 {
            let wrong = await offPool {
                Alpha58SecurityTests.headOnly(port: port, path: "/api/intake/estimate?name=a.stl",
                                              length: 2 << 20, extra: "X-Khayt-Pin: 00000000\r\n")
            }
            #expect(wrong.hasPrefix("HTTP/1.1 401"), Comment(rawValue: wrong))
        }
        let stillOpen = try await bench.post("/api/intake/estimate?name=cube.stl",
                                             json: LanServerTests.stlBytes,
                                             headers: ["x-khayt-pin": "24682468"])
        #expect(stillOpen.status == 200, Comment(rawValue: stillOpen.text))
        // The right PIN cleared the count; ten wrong ones lock it.
        for _ in 0..<10 {
            _ = await offPool {
                Alpha58SecurityTests.headOnly(port: port, path: "/api/intake/estimate?name=a.stl",
                                              length: 2 << 20, extra: "X-Khayt-Pin: 00000000\r\n")
            }
        }
        let locked = try await bench.post("/api/intake/estimate?name=cube.stl",
                                          json: LanServerTests.stlBytes,
                                          headers: ["x-khayt-pin": "24682468"])
        #expect(locked.status == 429, "locked out reads as wait, not as a wrong PIN: \(locked.text)")
        let lockedLarge = await offPool {
            Alpha58SecurityTests.headOnly(port: port, path: "/api/intake/estimate?name=a.stl",
                                          length: 2 << 20, extra: "X-Khayt-Pin: 24682468\r\n")
        }
        #expect(lockedLarge.hasPrefix("HTTP/1.1 429"), Comment(rawValue: lockedLarge))
    }

    @Test("the owner's estimates do not spend a visitor's hourly allowance")
    func ownerNotRateLimited() async throws {
        let bench = try await LanServerTests.Bench(intakeToken: "tok-63")
        defer { bench.stop() }
        var book = LanServerTests.quotingBook(bench.book.value)
        if case .object(var settings)? = book["settings"], case .object(var lan)? = settings["lanApi"],
           case .object(var cfg)? = lan["intakeQuote"] {
            cfg["hourlyLimit"] = .number(1)
            lan["intakeQuote"] = .object(cfg)
            settings["lanApi"] = .object(lan)
            book["settings"] = .object(settings)
        }
        bench.book.value = book
        for _ in 0..<3 {
            let owner = try await bench.post("/api/intake/estimate?name=cube.stl", json: LanServerTests.stlBytes,
                                             headers: ["x-khayt-pin": "24682468"])
            #expect(owner.status == 200, Comment(rawValue: owner.text))
        }
        // A visitor from the same address still has their one.
        let first = try await bench.post("/api/intake/estimate?name=cube.stl", json: LanServerTests.stlBytes,
                                         headers: ["x-khayt-intake-token": "tok-63"])
        #expect(first.status == 200, Comment(rawValue: first.text))
        let second = try await bench.post("/api/intake/estimate?name=cube.stl", json: LanServerTests.stlBytes,
                                          headers: ["x-khayt-intake-token": "tok-63"])
        #expect(second.status == 429, Comment(rawValue: second.text))
    }
}
