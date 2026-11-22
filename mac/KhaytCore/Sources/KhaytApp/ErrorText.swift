import Foundation

/// AN ERROR, AS A SENTENCE A SHOP CAN READ.
///
/// `String(describing:)` on an error from Foundation (a URL request, a file
/// write) is NSError's debug dump: domain, code and the whole userInfo, with
/// every URL in it. The Online pane once showed one: a cancelled Google token
/// request as six lines of `NSErrorFailingURLKey=…`. It had no spaces to wrap at,
/// so it also pushed the pane wider than the Settings window and cut "Stop Using
/// the Vault" off at the edge.
///
/// So: the error's own description when it has one; Foundation's short,
/// system-localized text ("cancelled", "The Internet connection appears to be
/// offline.") for an error from Cocoa; and the Swift value only for Khayt's
/// own errors, whose case names are what they have always said.
enum ErrorText {
    /// Domains whose errors are Foundation's, not Khayt's.
    static let systemDomains: Set<String> = [
        NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSMachErrorDomain,
    ]

    static func plain(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        let ns = error as NSError
        if systemDomains.contains(ns.domain) || error is URLError || error is CocoaError {
            return ns.localizedDescription
        }
        return String(describing: error)
    }
}
