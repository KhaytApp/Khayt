import AppKit
import SwiftUI
import KhaytCore

/// `KHAYT_SNAPSHOT_SUCCESS=1`: Machine profit with "Prints" and "Came out
/// right", for the five printers of Figma page 25, frame 5. A made-up report
/// (the frame's own figures), in memory; nothing is read from a book or written.
extension Snapshot {

    static func captureSuccessRate(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        await settle()
        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "success-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        func machine(_ id: String, _ name: String, _ colour: String, jobs: Int, hours: Double, net: Double) -> String {
            let revenue = net / 0.9
            return #"{"machineId":"\#(id)","name":"\#(name)","color":"\#(colour)","jobs":\#(jobs),"revenue":\#(revenue),"materialCost":\#(revenue * 0.1),"#
                + #""linkedExpenses":0,"maintenance":0,"net":\#(net),"marginPct":\#(net > 0 ? 90 : 0),"hours":\#(hours),"measured":\#(jobs),"targetHoursPerDay":8,"utilisationPct":\#(min(120, hours / 2.4))}"#
        }
        let rows = [machine("M1", "Old Ender", "#8E8E93", jobs: 14, hours: 61, net: 1240), machine("M2", "Workshop U1", "#0A84FF", jobs: 41, hours: 212, net: 6880),
                    machine("M3", "Bench CORE One", "#FF9F0A", jobs: 29, hours: 148, net: 4310), machine("M4", "Resin Saturn", "#BF5AF2", jobs: 2, hours: 9, net: 310),
                    machine("M5", "New Bambu", "#30D158", jobs: 3, hours: 0, net: 0)]
        let text = #"{"rows":["# + rows.joined(separator: ",")
            + #"],"totals":{"jobs":89,"revenue":14155,"materialCost":1415,"linkedExpenses":0,"maintenance":0,"net":12740,"hours":430,"measured":89}}"#
        guard let report = try? JSONDecoder().decode(KhaytEngine.MachineProfitReport.self, from: Data(text.utf8)) else {
            FileHandle.standardError.write(Data("success scene: the sample report did not decode\n".utf8)); return
        }
        func row(_ id: String, _ finished: Int, _ failed: Int, _ cancelled: Int, _ unknown: Int) -> KhaytEngine.SuccessRow {
            let decided = finished + failed
            return .init(machineId: id, finished: finished, failed: failed, cancelled: cancelled, unknown: unknown,
                         rate: decided > 0 ? Double(finished) / Double(decided) : nil, enough: decided >= 5)
        }
        let success = [row("M1", 11, 3, 1, 0), row("M2", 39, 2, 0, 0), row("M3", 25, 0, 4, 0), row("M4", 1, 1, 0, 0), row("M5", 0, 0, 0, 3)]
        var percents: [String: Int] = [:]
        if let engine = shop.engine {
            for r in success { if let p = try? await engine.successPercent(r.rate) { percents[r.machineId] = p } }
        }
        var page = MachineProfitPage(shop: shop, report: report)
        page.success = success
        page.successPercent = percents
        // The rows only: the page's own scroll view photographs blank.
        shot("machines", width: 1100, page.rows(report))
        shot("machines-narrow", width: 820, page.rows(report))
    }
}
