import Foundation
import Testing
import SwiftUI
@testable import KhaytApp

/// §1's contrast table, re-measured here.
///
/// The spec's own "Still open" list asks for exactly this: *"Ratios in §1 are
/// measured against the live tokens and all clear 4.5:1 at small size, but they
/// were computed with the WCAG 2.x formula in a browser, not by your test
/// suite. Re-run yours before trusting the table."*
///
/// So these do not copy the spec's numbers and check them off. They compute the
/// ratios from the roles as the app actually resolves them, in both
/// appearances, and hold them to the floors the spec states. If a role moves,
/// this fails — which is the point, because §1's last paragraph says the steps
/// have to be re-checked whenever a ground or an ink does.
@MainActor
struct ContrastTests {

    /// WCAG 2.x relative luminance. Written out rather than imported so the
    /// measurement does not depend on the thing being measured.
    static func ratio(_ a: NSColor, on b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            guard let s = c.usingColorSpace(.sRGB) else { return 0 }
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(s.redComponent)
                 + 0.7152 * channel(s.greenComponent)
                 + 0.0722 * channel(s.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return ((max(x, y) + 0.05) / (min(x, y) + 0.05) * 100).rounded() / 100
    }

    /// Resolve a role in one appearance. An adaptive colour answers differently
    /// depending on what is drawing, so the appearance has to be made current —
    /// reading one outside a drawing context silently gives the light value and
    /// makes every dark assertion pass for the wrong reason.
    static func resolve(_ color: Color, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return out
    }

    /// Every content ground an ink can land on.
    static func grounds(dark: Bool) -> [(String, NSColor)] {
        [("surf", Self.resolve(Role.surf, dark: dark)),
         ("surf2", Self.resolve(Role.surf2, dark: dark)),
         ("surf3", Self.resolve(Role.surf3, dark: dark))]
    }

    @Test("every ink clears 4.5:1 on every content ground, in both appearances")
    func inksClearTheFloor() {
        // §1: "Nothing in the system is below 4.5:1 at small size on a content
        // surface." Including `ink3`, which carries the column heads, the
        // OFFLINE chip and the em dash that means "not recorded" — the most
        // semantically loaded mark in the app, and the one most likely to be
        // treated as decoration.
        let inks: [(String, Color)] = [("ink", Role.text), ("ink2", Role.text2),
                                       ("ink3", Role.text3), ("late", Role.late),
                                       ("warn", Role.warn), ("ok", Role.ok)]
        for dark in [false, true] {
            for (inkName, ink) in inks {
                let resolved = Self.resolve(ink, dark: dark)
                for (groundName, ground) in Self.grounds(dark: dark) {
                    let r = Self.ratio(resolved, on: ground)
                    #expect(r >= 4.5, Comment(rawValue: """
                        \(inkName) on \(groundName), \(dark ? "dark" : "light"): \
                        \(r):1 — under §1's 4.5 floor.
                        """))
                }
            }
        }
    }

    /// The binding case the spec names: a state tuned on white fails on
    /// `surf3` by about 0.7, and `surf3` is what chips and group bands use.
    @Test("a state colour is measured against surf3, the darkest content ground")
    func statesMeasuredAgainstSurf3() {
        for dark in [false, true] {
            let surf3 = Self.resolve(Role.surf3, dark: dark)
            for (name, role) in [("late", Role.late), ("warn", Role.warn), ("ok", Role.ok)] {
                let r = Self.ratio(Self.resolve(role, dark: dark), on: surf3)
                #expect(r >= 4.5, Comment(rawValue:
                    "\(name) on surf3, \(dark ? "dark" : "light"): \(r):1"))
            }
        }
    }

    @Test("the label on a brand or warn fill is not white by accident")
    func labelsOnFills() {
        // Light darkens the fill and keeps a white label; dark keeps the vivid
        // fill and flips the label to near-black. Hard-coding white passes in
        // light and fails at about 2.7:1 in dark — which is the bug this pair
        // of roles exists to prevent, and which this app had.
        for dark in [false, true] {
            let onAcc = Self.ratio(Self.resolve(Role.onAcc, dark: dark),
                                   on: Self.resolve(Role.accInk, dark: dark))
            #expect(onAcc >= 4.5, Comment(rawValue:
                "onAcc on accInk, \(dark ? "dark" : "light"): \(onAcc):1"))

            let onWarn = Self.ratio(Self.resolve(Role.onWarn, dark: dark),
                                    on: Self.resolve(Role.warn, dark: dark))
            #expect(onWarn >= 4.5, Comment(rawValue:
                "onWarn on warn, \(dark ? "dark" : "light"): \(onWarn):1"))

            // And the failure mode, asserted directly: white on the DARK
            // accent is what the spec says must not ship.
            if dark {
                let naive = Self.ratio(.white, on: Self.resolve(Role.accInk, dark: true))
                #expect(naive < 4.5, """
                    white on the dark accent now passes, so the onAcc role is no \
                    longer load-bearing — check the spec before deleting it
                    """)
            }
        }
    }

    /// Navy is a ground, and it is theme-invariant.
    @Test("everything mounted on navy is measured against navy")
    func navyIsItsOwnGround() {
        for dark in [false, true] {
            let navy = Self.resolve(Role.navy, dark: dark)
            for (name, ink) in [("onNavy", Role.onNavy), ("onNavy2", Role.onNavy2),
                                ("onNavy3", Role.onNavy3), ("lateOnNavy", Role.lateOnNavy)] {
                // Translucent whites composite over navy; resolve the composite
                // rather than the colour, or the ratio is of something that is
                // never drawn.
                let over = NSColor.blend(Self.resolve(ink, dark: dark), over: navy)
                let r = Self.ratio(over, on: navy)
                #expect(r >= 4.5, Comment(rawValue:
                    "\(name) on navy, \(dark ? "dark" : "light"): \(r):1"))
            }

            // And the trap, named in §1: the content-surface `late` on navy.
            let wrong = Self.ratio(Self.resolve(Role.late, dark: dark), on: navy)
            if !dark {
                #expect(wrong < 4.5, """
                    the content-surface `late` now clears on navy, which would \
                    make `lateOnNavy` redundant — re-read §1 before removing it
                    """)
            }
        }
    }

    /// §1's last paragraph: meeting a floor is not enough if two inks meet it
    /// at the same place, because then they are the same colour and the
    /// hierarchy the brief complains about is back.
    @Test("the three ink levels stay visibly apart")
    func inkStepsAreSeparated() {
        for (dark, floor) in [(false, 1.68), (true, 1.37)] {
            let one = Self.resolve(Role.text, dark: dark)
            let two = Self.resolve(Role.text2, dark: dark)
            let three = Self.resolve(Role.text3, dark: dark)
            let step = Self.ratio(two, on: three)
            #expect(step >= floor - 0.02, Comment(rawValue: """
                ink2 → ink3 in \(dark ? "dark" : "light") is \(step):1, under the \
                \(floor) §1 states. Two inks on the same floor are one ink.
                """))
            #expect(Self.ratio(one, on: two) > 1.2, "ink and ink2 have converged")
        }
    }

    /// A translucent tint is a ground too, and it composites differently over
    /// each surface beneath it.
    @Test("the accent tint is a measured ground")
    func accentTintIsAGround() {
        for dark in [false, true] {
            let under = Self.resolve(Role.sheet, dark: dark)
            let tint = NSColor.blend(Self.resolve(Role.accSoft, dark: dark), over: under)
            for (name, ink) in [("accInk", Role.accInk), ("ink3", Role.text3),
                                ("ink", Role.text)] {
                let r = Self.ratio(Self.resolve(ink, dark: dark), on: tint)
                #expect(r >= 4.5, Comment(rawValue: """
                    \(name) on the accent tint, \(dark ? "dark" : "light"): \(r):1 \
                    — a tint is a ground and joins the measured set.
                    """))
            }
        }
    }
}

extension NSColor {
    /// What a translucent colour actually looks like once it is drawn.
    static func blend(_ top: NSColor, over bottom: NSColor) -> NSColor {
        guard let t = top.usingColorSpace(.sRGB),
              let b = bottom.usingColorSpace(.sRGB) else { return top }
        let a = t.alphaComponent
        return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                       green: t.greenComponent * a + b.greenComponent * (1 - a),
                       blue: t.blueComponent * a + b.blueComponent * (1 - a),
                       alpha: 1)
    }
}
