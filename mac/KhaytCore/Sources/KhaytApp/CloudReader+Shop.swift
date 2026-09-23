import Foundation
import KhaytCore

/// Where the Mac's book keeps its cloud connection.
///
/// The one part of `CloudReader` that needs the Mac app — `Shop.cloudConnected`
/// decides whether the book is connected at all — so it stays here when the
/// rest of the reader moved to KhaytCore for the phone to share.
extension CloudReader {
    static func connection(_ settings: [String: JSONValue]) throws -> Connection {
        guard Shop.cloudConnected(settings), case .object(let cloud)? = settings["cloud"] else {
            throw Failure.notConnected
        }
        guard case .string(let url)? = cloud["url"], !url.isEmpty,
              case .string(let shop)? = cloud["shopId"], !shop.isEmpty else {
            throw Failure.notConnected
        }
        var token = ""
        if case .string(let t)? = cloud["token"] { token = t }
        return Connection(url: url, shopId: shop, storedToken: token)
    }
}
