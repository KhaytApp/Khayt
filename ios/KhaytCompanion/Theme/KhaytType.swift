import SwiftUI
import UIKit

/// The design's typeface — Space Grotesk (`design/ios-v2/`), bundled and
/// registered in Info.plist (`UIAppFonts`).
///
/// Every size scales with Dynamic Type through `relativeTo:`. Space Grotesk
/// has no Arabic; iOS falls back to its Arabic system face for those glyphs on
/// its own, which is what the design's `'Space Grotesk', 'IBM Plex Sans
/// Arabic', system-ui` stack does on the web.
enum KhaytType {
    static func postScriptName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "SpaceGroteskLight-Bold"
        case .semibold: return "SpaceGroteskLight-SemiBold"
        case .medium: return "SpaceGroteskLight-Medium"
        default: return "SpaceGroteskLight-Regular"
        }
    }

    /// Navigation titles in the design's face, set once at launch.
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let large = UIFont(name: postScriptName(.bold), size: 32) {
            appearance.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)]
        }
        if let inline = UIFont(name: postScriptName(.semibold), size: 17) {
            appearance.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        let edge = UINavigationBarAppearance(); edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = appearance.largeTitleTextAttributes
        edge.titleTextAttributes = appearance.titleTextAttributes
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }
}

extension Font {
    /// Space Grotesk at `size`, scaling with Dynamic Type like `style`.
    static func khayt(_ size: CGFloat, _ weight: Font.Weight = .regular,
                      relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(KhaytType.postScriptName(weight), size: size, relativeTo: style)
    }
}
