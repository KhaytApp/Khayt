import Foundation
import Testing
import AppKit
import SwiftUI
@testable import KhaytApp

/// The palette, and the rule that nothing may go round it.
@MainActor
struct PaletteTests {

    // MARK: - Contrast

    /// WCAG relative luminance, so a colour can be checked rather than admired.
    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
             + 0.7152 * channel(c.greenComponent)
             + 0.0722 * channel(c.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Resolve one of the palette's dynamic colours in a named appearance.
    static func resolved(_ color: Color, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return out
    }

    /// EVERY colour, in BOTH appearances, against EVERY SURFACE IT SITS ON.
    ///
    /// 4.5:1 is the AA threshold for body text, and these are used on text —
    /// "3 late", "Not sent — trying again", a nozzle warning. SwiftUI's own
    /// `.green` is 2.4:1 on white, which is why they were not left as they were.
    ///
    /// ── IT USED TO MEASURE AGAINST WHITE ──────────────────────────────────
    ///
    /// White, and `#1E1E1E` for dark. Neither is a surface this app draws on:
    /// the ground is a warm off-white and cards are lifted above it, so every
    /// figure here flattered itself by a fraction of a point — and the first
    /// time the card surface moved, `late` fell to 4.25:1 against it and this
    /// test said nothing, because it was still asking about white.
    ///
    /// A palette is only legible against the things it is actually drawn on.
    @Test("every palette colour is legible on every surface, in both appearances")
    func contrastHolds() {
        // The three grounds a coloured label is ever drawn on, plus white and
        // the system window colour, which are what a sheet and an alert use.
        let surfaces: [(String, Color)] = [
            ("the card surface", Khayt.surface),
            ("the screen ground", Khayt.ground),
            ("a recessed strip", Khayt.recessed),
        ]
        let text: [(String, Color)] = [
            ("cyan", Khayt.cyan), ("hot", Khayt.hot), ("done", Khayt.done),
            ("attention", Khayt.attention), ("late", Khayt.late), ("note", Khayt.note),
        ]

        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            for (surfaceName, surface) in surfaces {
                let ground = Self.resolved(surface, dark: dark)
                for (name, colour) in text {
                    let ratio = Self.contrast(Self.resolved(colour, dark: dark), ground)
                    #expect(ratio >= 4.5,
                            "\(name) is \(String(format: "%.2f", ratio)):1 on \(surfaceName), \(appearance)")
                }
                // `marked` is held to 3:1, the threshold for a graphical
                // element. It is only ever `star.fill` and never text.
                let marked = Self.contrast(Self.resolved(Khayt.marked, dark: dark), ground)
                #expect(marked >= 3,
                        "marked is \(String(format: "%.2f", marked)):1 on \(surfaceName), \(appearance)")
            }
        }
    }

    /// A card has to be visible AGAINST the screen it sits on, and the line
    /// round it visible against both. These are not text, so the bar is the
    /// eye's rather than AA's — but "no difference at all" is a card that is
    /// not a card.
    @Test("the surfaces are told apart from each other")
    func surfacesSeparate() {
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let surface = Self.resolved(Khayt.surface, dark: dark)
            let ground = Self.resolved(Khayt.ground, dark: dark)
            let recessed = Self.resolved(Khayt.recessed, dark: dark)
            #expect(Self.contrast(surface, ground) >= 1.06,
                    "a card is invisible against the screen in \(appearance)")
            #expect(Self.contrast(ground, recessed) >= 1.04,
                    "a recessed strip is invisible against the ground in \(appearance)")
        }
    }

    /// Two colours that mean opposite things have to be tellable apart.
    ///
    /// `hot` is printing — the thing going well — and `late` is an invoice
    /// nobody has paid. They appear on the same dashboard. Warming `hot` to a
    /// burnt orange moved it toward the red, and "distinguishable" is not a
    /// thing to decide by looking once.
    @Test("the heat colour and the alarm colour are not the same colour")
    func heatIsNotAlarm() {
        for dark in [false, true] {
            let hot = Self.resolved(Khayt.hot, dark: dark)
            let late = Self.resolved(Khayt.late, dark: dark)
            let apart = Self.distance(hot, late)
            let where_ = dark ? "dark" : "light"
            #expect(apart >= 25,
                    "hot and late are \(String(format: "%.0f", apart)) apart in \(where_) — a shop cannot tell a printing job from an overdue invoice")
        }
    }

    /// Rough perceptual distance, enough to catch two colours that have drifted
    /// into each other. Not CIEDE2000 — `lib/color-mix.js` is where that lives,
    /// and this is a guard rail rather than a colour science claim.
    static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        let dr = (x.redComponent - y.redComponent) * 255
        let dg = (x.greenComponent - y.greenComponent) * 255
        let db = (x.blueComponent - y.blueComponent) * 255
        // Weighted toward green, which the eye is most sensitive to.
        return (2 * dr * dr + 4 * dg * dg + 3 * db * db).squareRoot()
    }

    /// Light and dark are actually different values, in the right direction.
    ///
    /// A dynamic colour that returns the same thing twice is a static colour
    /// with extra machinery, and it is the failure mode that looks fine until
    /// somebody switches appearance.
    @Test("each colour is lighter in dark appearance than in light")
    func theyActuallyAdapt() {
        for (name, color) in [("cyan", Khayt.cyan), ("hot", Khayt.hot), ("done", Khayt.done),
                              ("attention", Khayt.attention), ("late", Khayt.late),
                              ("note", Khayt.note), ("marked", Khayt.marked)] {
            let light = Self.luminance(Self.resolved(color, dark: false))
            let dark = Self.luminance(Self.resolved(color, dark: true))
            #expect(dark > light, "\(name) does not lighten for dark appearance")
        }
    }

    /// The cyan IS the icon's cyan, in dark appearance where it is used unaltered.
    ///
    /// Pinned because the whole argument for this colour is that it came from
    /// the app's own mark rather than from taste, and a value nudged later
    /// quietly breaks that.
    @Test("the brand cyan is the colour of the letter in the icon")
    func cyanMatchesTheIcon() {
        let cyan = Self.resolved(Khayt.cyan, dark: true)
        let icon = NSColor(hex: 0x2BCDE4)
        #expect(abs(cyan.redComponent - icon.redComponent) < 0.005)
        #expect(abs(cyan.greenComponent - icon.greenComponent) < 0.005)
        #expect(abs(cyan.blueComponent - icon.blueComponent) < 0.005)
    }

    // MARK: - The system's accent wins

    /// "If people set their accent color setting to a value other than
    /// multicolor, the system applies their chosen color … replacing your
    /// accent color." So the tint must be nil whenever they have chosen.
    ///
    /// `AppleAccentColor` is ABSENT for multicolour and 0–7 for a choice, and 0
    /// is red — so a reader using `integer(forKey:)` would treat multicolour as
    /// a deliberate choice of red and never apply the app's colour at all.
    @Test("the app's colour steps aside for a chosen system accent")
    func systemAccentWins() {
        let key = "AppleAccentColor"
        let restore = UserDefaults.standard.object(forKey: key)
        defer {
            if let restore { UserDefaults.standard.set(restore, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(Khayt.systemAccentIsChosen == false)
        #expect(Khayt.appTint != nil, "with no chosen accent the app should wear its own")

        // 0 is red, and is exactly the value a naive integer read cannot tell
        // from "not set".
        UserDefaults.standard.set(0, forKey: key)
        #expect(Khayt.systemAccentIsChosen == true)
        #expect(Khayt.appTint == nil, "a chosen accent must not be overridden")

        UserDefaults.standard.set(4, forKey: key)
        #expect(Khayt.appTint == nil)
    }

    // MARK: - Nothing goes round it

    /// THE GUARD.
    ///
    /// The palette only means anything if it is the only source of colour.
    /// Before it existed, `.orange` sat on a printer alert, a sync retry and a
    /// lost-edits warning — three unrelated things wearing one colour, which is
    /// the first thing the HIG's colour guidance says not to do.
    ///
    /// `.accentColor`, `.primary`, `.secondary`, `.tertiary` and the materials
    /// are not colours in this sense: they are the system's own semantic roles
    /// and they adapt on their own.
    @Test("no screen picks a raw system colour of its own")
    func noRawColours() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") && $0 != "Palette.swift" }

        // A hue picked by name, where a meaning was wanted.
        let banned = ["Color.red", "Color.green", "Color.orange", "Color.yellow",
                      "Color.purple", "Color.pink", "Color.blue", "Color.mint",
                      "Color.teal", "Color.indigo", "Color.brown",
                      ".foregroundStyle(.red)", ".foregroundStyle(.green)",
                      ".foregroundStyle(.orange)", ".foregroundStyle(.yellow)",
                      ".foregroundStyle(.blue)", ".foregroundStyle(.purple)",
                      "AnyShapeStyle(.red)", "AnyShapeStyle(.green)",
                      "AnyShapeStyle(.orange)", "AnyShapeStyle(.blue)"]

        for file in files.sorted() {
            let source = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                // A colour named inside a comment is prose about the palette,
                // which several of these files legitimately contain.
                let code = text.components(separatedBy: "//").first ?? text
                for token in banned where code.contains(token) {
                    Issue.record(Comment(rawValue:
                        "\(file) picks \(token) — say what it MEANS with Khayt.…\n  \(code.trimmingCharacters(in: .whitespaces))"))
                }
            }
        }
    }
}
