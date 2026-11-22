import Foundation

/// The library models whose ONLY copy is in the vault, and what to offer
/// about them while the vault is over its plan (khayt-cloud #143).
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────
///
/// Free Up Space moves a model's bytes to the vault and leaves a `.cloud`
/// sidecar where the file was. While the vault is over its plan it is
/// read-only, and once the cloud sets `deleteAfter` the files over the limit
/// are deleted on that day. A model moved online then has no bytes anywhere:
/// not here, not in the vault. Only this Mac can name those models (the
/// cloud holds ciphertext and opaque keys), so only this Mac can warn.
///
/// Downloads keep working while read-only, so Bring Back still works, and
/// the offer is made for exactly the models at risk. Nothing here reads a
/// disk; the app hands it what it found in each model's own folder.
public enum VaultOnlyCopies {

    /// The `provider` a `.cloud` sidecar names, read without the engine —
    /// enough to COUNT. Bring Back still verifies size and SHA-256 through
    /// the engine before a byte is written. Nil for anything unreadable.
    public static func sidecarProvider(_ data: Data) -> String? {
        struct Side: Decodable { let provider: String? }
        guard let side = try? JSONDecoder().decode(Side.self, from: data) else { return nil }
        let p = (side.provider ?? "").trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    /// The provider the Mac writes for a model moved to the vault, and
    /// `VaultApply` writes for a model another device added.
    public static let vaultProvider = "vault"

    /// One file in a model's own folder, as the app found it.
    public struct Found: Sendable, Equatable {
        /// The model file's name (the sidecar's name without `.cloud`).
        public var name: String
        /// The sidecar's provider (`sidecarProvider`).
        public var provider: String?
        /// The model's bytes are beside the sidecar (a move interrupted
        /// between writing the sidecar and removing the file).
        public var bytesHere: Bool
        public init(name: String, provider: String?, bytesHere: Bool) {
            self.name = name; self.provider = provider; self.bytesHere = bytesHere
        }
    }

    /// Does this folder hold a model whose only copy is the vault's? A
    /// sidecar naming the vault, with no bytes beside it. When the record
    /// names its own file (`own`), only that file decides — a pack's other
    /// files do not.
    public static func onlyInVault(_ found: [Found], own: String? = nil) -> Bool {
        let relevant: [Found]
        if let own, !own.isEmpty, found.contains(where: { $0.name == own }) {
            relevant = found.filter { $0.name == own }
        } else {
            relevant = found
        }
        return relevant.contains { $0.provider == vaultProvider && !$0.bytesHere }
    }

    /// What the warning offers, in the lapse's own terms.
    public enum Offer: Equatable, Sendable {
        /// The cloud has set a deletion date: bring them back before it.
        case before(Date)
        /// Over, read-only, no date yet.
        case whileReadOnly
    }

    /// The offer for `count` models at risk, or nil when there is nothing to
    /// offer: not over, or no model whose only copy is the vault's.
    public static func offer(_ display: CloudPlans.Lapse.Display, count: Int) -> Offer? {
        guard count > 0 else { return nil }
        switch display {
        case .notOver: return nil
        case .readOnly: return .whileReadOnly
        case .deleting(_, let end, _, _): return .before(end)
        }
    }

    /// The models, a batch at a time: a library with hundreds moved online
    /// is brought back in pieces, each a progress step, rather than as one
    /// pass that says nothing until it ends.
    public static let batchSize = 10

    public static func batches<T>(_ items: [T], size: Int = batchSize) -> [[T]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    // MARK: - After deletion

    /// A record whose vault copy was purged (`VaultApply.Edit.purged` stamps
    /// `vaultPurgedAt` and drops `vaultFileId`) while this Mac held only the
    /// vault's sidecar: no bytes anywhere. Library Health says so as
    /// "deleted from the vault by the plan limit" — not a generic missing
    /// file, and with nothing to Locate.
    ///
    /// A record the vault holds again since (`vaultFileId` back) is not.
    public static func deletedByPlan(purgedAt: String?, vaultFileId: String?, found: [Found],
                                     own: String? = nil) -> Bool {
        guard !(purgedAt ?? "").isEmpty, (vaultFileId ?? "").isEmpty else { return false }
        return onlyInVault(found, own: own)
    }
}
