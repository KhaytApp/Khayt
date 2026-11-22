import Foundation
import Testing
@testable import KhaytCore

/// Ready means loaded AND on the bed — one rule, so the inspector can no
/// longer say "Too big for every machine" over "Ready to start".
@Suite struct ModelReadinessTests {

    static let u1: JSONValue = .object(["x": .number(270), "y": .number(270), "z": .number(270)])
    static let small = ModelReadiness.bounds(x: 200, y: 200, z: 4.56)
    static let huge = ModelReadiness.bounds(x: 1141.57, y: 757.09, z: 207.37)

    @Test("too big is too big whatever is loaded")
    func tooBigWins() {
        #expect(ModelReadiness.state(bounds: Self.huge, bed: Self.u1, spoolsReady: true) == .tooBig)
        #expect(ModelReadiness.state(bounds: Self.huge, bed: Self.u1, spoolsReady: false) == .tooBig)
        #expect(ModelReadiness.state(bounds: Self.huge, bed: Self.u1, spoolsReady: nil) == .tooBig)
        #expect(!ModelReadiness.canStart(ModelReadiness.state(bounds: Self.huge, bed: Self.u1, spoolsReady: true)))
    }

    @Test("on the bed, the spools decide")
    func spoolsDecide() {
        #expect(ModelReadiness.state(bounds: Self.small, bed: Self.u1, spoolsReady: true) == .ready)
        #expect(ModelReadiness.state(bounds: Self.small, bed: Self.u1, spoolsReady: false) == .needsSwap)
        #expect(ModelReadiness.state(bounds: Self.small, bed: Self.u1, spoolsReady: nil) == .fits)
        #expect(ModelReadiness.canStart(.ready) && ModelReadiness.canStart(.readyTurned))
        #expect(!ModelReadiness.canStart(.needsSwap) && !ModelReadiness.canStart(.fits))
    }

    @Test("a quarter turn is still ready, and too tall never is")
    func turned() {
        let bed: JSONValue = .object(["x": .number(250), "y": .number(200), "z": .number(250)])
        let long = ModelReadiness.bounds(x: 190, y: 240, z: 10)
        #expect(ModelReadiness.state(bounds: long, bed: bed, spoolsReady: true) == .readyTurned)
        #expect(ModelReadiness.state(bounds: long, bed: bed, spoolsReady: nil) == .fitsTurned)
        let tall = ModelReadiness.bounds(x: 190, y: 240, z: 400)
        #expect(ModelReadiness.state(bounds: tall, bed: bed, spoolsReady: true) == .tooBig)
    }

    @Test("unknown is not a refusal: no bed or no mesh leaves the spools to answer")
    func unknown() {
        #expect(ModelReadiness.state(bounds: nil, bed: Self.u1, spoolsReady: true) == .ready)
        #expect(ModelReadiness.state(bounds: Self.huge, bed: nil, spoolsReady: true) == .ready)
        #expect(ModelReadiness.state(bounds: nil, bed: nil, spoolsReady: nil) == nil)
    }

    @Test("margin on price, and the floor only warns when the shop set one")
    func margin() {
        #expect(ModelMargin.onPrice(price: 200, cost: 50) == 0.75)
        #expect(ModelMargin.onPrice(price: 0, cost: 50) == nil)
        #expect(ModelMargin.belowFloor(0.30, floorPct: 35))
        #expect(!ModelMargin.belowFloor(0.40, floorPct: 35))
        #expect(!ModelMargin.belowFloor(0.10, floorPct: 0))
        #expect(!ModelMargin.belowFloor(0.10, floorPct: nil))
        #expect(!ModelMargin.belowFloor(nil, floorPct: 35))
    }
}
