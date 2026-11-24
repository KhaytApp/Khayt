import AppKit
import SwiftUI
import KhaytCore

/// `KHAYT_SNAPSHOT_PROOF=1`: the job page's "Keep as proof" card in the five
/// states of Figma page 25, frame 3, on the sample book, in memory. Nothing
/// is written, and no printer is asked anything.
extension Snapshot {

    static func captureProofCard(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        await settle()
        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "proof-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        let machine = shop.machines.first { $0.id == "MACH-u1" }?.id ?? shop.machines.first?.id ?? "MACH-u1"
        var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 21; parts.hour = 14; parts.minute = 10
        let at = Calendar.book.date(from: parts)
        let found = Shop.TimelapseProof.found(bytes: 42_000_000, machineId: machine, at: at)
        func card(_ proof: Shop.TimelapseProof, copying: TimelapseProgress? = nil, problem: String? = nil) -> some View {
            TimelapseProofCard(shop: shop, jobId: "snapshot", pretend: (proof, copying, problem))
        }
        shot("states", width: 680, VStack(alignment: .leading, spacing: 14) {
            card(found)
            card(found, copying: TimelapseProgress(got: 18_000_000, total: 42_000_000))
            card(.kept(bytes: 42_000_000, machineId: machine, at: at, filename: nil))
            card(.stays(bytes: 310_000_000, maxBytes: 150_000_000, reason: "over-budget", machineId: machine))
            card(found, problem: shop.words.callIt("mac.proof_offline"))
            card(.stays(bytes: nil, maxBytes: nil, reason: "size-unknown", machineId: machine))
        }.padding(20))
    }
}
