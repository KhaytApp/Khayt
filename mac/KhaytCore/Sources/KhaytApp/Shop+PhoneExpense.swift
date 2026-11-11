import AppKit
import Foundation
import KhaytCore

/// A paired phone filing an expense with its receipt: `POST /api/expense`.
///
/// The phone writes an expense with no photo into the book itself. One WITH a
/// photographed receipt it sends here, because the receipt is a file the desk
/// keeps and the record only points at — and the Mac did not serve the route,
/// so with a Mac as the host, photographing a till slip and pressing Save
/// failed (the Nov 10 2026 review). The desktop has served it all along
/// (`lib/lan-server.js`); this is the same route, by the same rules:
///
///  - the receipt is a JPEG, PNG or PDF by its own first bytes, never by what
///    the request says it is, and at most 6 MB;
///  - the file is written FIRST. If that fails no expense is made, so there is
///    never a row pointing at a receipt that does not exist;
///  - the record is `lib/expense-book.js newExpense`, the rule the Mac's own
///    Add Expense uses, so the category, the tax and the day are read alike.
///
/// The receipt is filed in `receipts/` beside the book and the record holds
/// that RELATIVE path, so the book never carries this computer's folders.
/// A SIGNED, enrolled phone only, as for a job photo.
enum ExpenseReceipt {
    /// The receipt itself.
    static let maxBytes = 6 * 1_048_576
    /// The request: the receipt as base64 inside JSON, and room for the rest.
    static let maxBody = (maxBytes * 4 + 2) / 3 + 8192

    /// "jpg", "png" or "pdf" by the file's first bytes; nil for anything else.
    static func kind(of data: Data) -> String? {
        let magic: [(String, [UInt8])] = [
            ("jpg", [0xFF, 0xD8, 0xFF]),
            ("png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            ("pdf", [0x25, 0x50, 0x44, 0x46]),
        ]
        for (ext, bytes) in magic where data.count >= bytes.count && Array(data.prefix(bytes.count)) == bytes {
            return ext
        }
        return nil
    }

    /// A name that cannot leave its folder or meet another.
    static func filename(_ ext: String) -> String {
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let tail = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "receipt-\(stamp)-\(tail).\(ext)"
    }

    static func folder(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "receipts")
    }

    /// The file a record's `receiptPath` names, when it is on this computer:
    /// `receipts/<name>` beside the book (this app, and the desktop's attached
    /// receipts), or the whole path the desktop writes for a phone's photo.
    /// Nil when it is not here — a receipt filed on another computer.
    static func file(for receiptPath: String, storeURL: URL) -> URL? {
        let path = receiptPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let fm = FileManager.default
        if path.hasPrefix("/") {
            // A whole path is only ever one the desktop wrote for a phone's
            // photo, and it writes those into a folder named `receipts`.
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().lastPathComponent == "receipts" else { return nil }
            return isAReceipt(url) ? url : nil
        }
        // Relative: only ever inside `receipts/`, and never up out of it.
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "receipts", !parts[1].hasPrefix("."), !parts[1].contains("..") else { return nil }
        let url = folder(for: storeURL).appending(path: parts[1])
        return isAReceipt(url) ? url : nil
    }

    /// What a receipt can be: the three kinds this app and the desktop write.
    static let kinds: Set<String> = ["jpg", "jpeg", "png", "pdf"]

    /// A picture or a PDF that is really a file.
    ///
    /// THE PATH COMES FROM THE BOOK, and an expense is something a phone with
    /// the LAN PIN, a sync peer or a second computer can write. The paperclip
    /// hands the file to `NSWorkspace.open`, so a record naming an app, a
    /// `.command` or `.terminal` file, or a folder would have had the Mac open
    /// it at one click (beta.34 pre-release review). Only a regular file of a
    /// receipt's kind is opened, judged after links are followed.
    static func isAReceipt(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath()
        guard kinds.contains(real.pathExtension.lowercased()) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

extension Shop {
    /// An HTTP status and a JSON body: `{"ok":true,"entry":{…}}` or
    /// `{"ok":false,"error":…}` in the desktop's words for the same refusal.
    func phoneAddExpense(_ body: Data) async -> (Int, String) {
        func refuse(_ status: Int, _ error: String) -> (Int, String) {
            (status, Self.expenseJson(["ok": .bool(false), "error": .string(error)]))
        }
        guard let build = source.build, canWrite, let engine else { return refuse(409, "This Mac cannot write its book right now") }
        guard case .object(let raw)? = try? JSONValue.decode(JSONValue.self, from: body) else {
            return refuse(400, "Invalid expense payload")
        }
        guard let amount = Self.plainNumber(raw["amount"]), amount > 0 else { return refuse(400, "Amount is required") }

        var receiptPath: String?
        var written: URL?
        if case .string(let b64)? = raw["receiptBase64"], !b64.isEmpty {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                  let ext = ExpenseReceipt.kind(of: data) else {
                return refuse(415, "Receipt must be a JPEG, PNG or PDF")
            }
            guard data.count <= ExpenseReceipt.maxBytes else { return refuse(413, "Receipt too large") }
            let folder = ExpenseReceipt.folder(for: build.storeURL)
            let name = ExpenseReceipt.filename(ext)
            do {
                // A CUSTOMER'S OR SUPPLIER'S PAPER: this user's only.
                try PrivateFile.makeFolder(folder)
                try PrivateFile.write(data, to: folder.appending(path: name))
            } catch {
                return refuse(500, "The receipt could not be saved")
            }
            written = folder.appending(path: name)
            receiptPath = "receipts/" + name
        }

        var input: [String: JSONValue] = ["amount": .number(amount)]
        for key in ["category", "note", "orderId", "locationId", "date", "receiptRef"] {
            if case .string(let s)? = raw[key] { input[key] = .string(String(s.prefix(key == "note" ? 500 : 128))) }
        }
        if let vat = Self.plainNumber(raw["vatAmount"]) { input["vatAmount"] = .number(vat) }
        if let receiptPath { input["receiptPath"] = .string(receiptPath) }

        var entry: JSONValue = .null
        do {
            // lock: system — a paired phone's expense; the LAN route takes a signed enrolled device only.
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let made = try await engine.newExpense(input, id: Self.uid("EXP"), today: Self.today())
                guard var record = made.expense, case .object(var fields) = record else {
                    throw MoveRefused(sentence: "Amount is required")
                }
                StoreWriter.stamp(&fields)
                record = .object(fields)
                var rows = Self.rows(root, "expenses")
                rows.insert(record, at: 0)
                root["expenses"] = .array(rows)
                entry = record
            }
        } catch {
            // No expense, so no receipt left behind either.
            if let written { try? FileManager.default.removeItem(at: written) }
            return refuse(500, self.said(error))
        }
        await load(source)
        return (201, Self.expenseJson(["ok": .bool(true), "entry": entry]))
    }

    /// Open an expense's receipt in whatever opens that kind of file, or say
    /// that it is not on this computer.
    func openReceipt(_ receiptPath: String) {
        spendProblem = nil
        guard let build = source.build,
              let url = ExpenseReceipt.file(for: receiptPath, storeURL: build.storeURL),
              NSWorkspace.shared.open(url) else {
            spendProblem = words.callIt("exp.receipt_open_failed"); return
        }
    }

    private static func expenseJson(_ object: [String: JSONValue]) -> String {
        (try? String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self))
            ?? #"{"ok":false,"error":"encode"}"#
    }
}

extension LanServer {
    /// The expense route, judged from the request line alone, under either name.
    nonisolated static func isExpenseUpload(method: String, target: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        var path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/v1/") { path = "/api" + path.dropFirst(3) }
        return path == "/api/expense"
    }
}
