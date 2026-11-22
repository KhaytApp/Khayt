import Foundation

public extension String {

    /// `encodeURIComponent`, exactly.
    ///
    /// Swift's `.alphanumerics` is NOT the same set and the difference is not
    /// cosmetic: it escapes `_`, and every shop id Khayt issues contains one.
    /// `shop_282eb…` went on the wire as `shop%5F282eb…`, khayt-cloud's route
    /// is `^/v1/shops/([A-Za-z0-9_\-]+)/store$`, and `%5F` matches nothing in
    /// that class — so every request 404'd, on the first real attempt.
    ///
    /// The Electron client builds the same paths with `encodeURIComponent` and
    /// has always worked, so this is that set and not a stricter one of my own:
    /// unreserved characters plus the marks JavaScript leaves alone.
    ///
    /// **A test on `URL.path` cannot see this.** `URL.path` DECODES, so an
    /// assertion that the path equals `/v1/shops/shop_282eb…/store` passes
    /// while the wire carries the escape. Assert on `absoluteString`.
    var uriComponent: String {
        addingPercentEncoding(withAllowedCharacters: Self.uriComponentAllowed) ?? self
    }

    /// `A-Z a-z 0-9 - _ . ! ~ * ' ( )` — the set `encodeURIComponent` leaves
    /// untouched, from the ECMAScript specification rather than from memory.
    static let uriComponentAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}
