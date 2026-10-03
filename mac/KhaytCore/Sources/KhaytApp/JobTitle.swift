import Foundation

/// What a job is CALLED on screen, when its project is not a name.
///
/// ── A HASH IS NOT A TITLE ─────────────────────────────────────────────────
///
/// A job logged from a printer's own history can arrive with a project like
/// `d0de11b4e5a09b4119ca41bdab22300d` — the printer's id for the task, not
/// anything a person called it — and the jobs table drew that as the job's
/// name (alpha.57 review). The book is left exactly as it is: this is the
/// DISPLAY only, and nothing here writes. A shop that names the job sees its
/// name again at once.
///
/// In order: the library model a part was printed from (its title is what the
/// shop calls it), then the file the printer printed, then a part's own name,
/// and only then "Untitled print". Each candidate is skipped if it is a hash
/// too — the printer that sent a hash for the task often sent one for the
/// file.
enum JobTitle {
    /// 32, 40 or 64 hex digits — an MD5, SHA-1 or SHA-256 — and nothing else.
    /// Case-insensitive. A name that merely CONTAINS hex ("cafe", "Bed 2") is
    /// a name.
    static func looksLikeHash(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [32, 40, 64].contains(t.count) else { return false }
        return t.allSatisfy(\.isHexDigit)
    }

    /// The title to draw. `fileTitle` looks a library id up; `untitled` is
    /// the shop's own words for a print with no name.
    static func shown(project: String, parts: [Order.Part],
                      fileTitle: (String) -> String?, untitled: String) -> String {
        guard looksLikeHash(project) else { return project }
        func usable(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, !looksLikeHash(s) else { return nil }
            return s
        }
        for part in parts {
            if let id = part.printFileId, let title = usable(fileTitle(id)) { return title }
        }
        for part in parts {
            // The file as the printer knows it, without the folder it sat in
            // on the printer or the slicer's extension.
            // And without a hash the printer put IN FRONT of the slicer's
            // name (`withoutHashPrefix`).
            if let ref = usable(part.fileRef) {
                let leaf = (ref as NSString).lastPathComponent
                let bare = Self.withoutHashPrefix(Self.dropExtension(leaf))
                if let name = usable(bare) { return name }
            }
        }
        for part in parts {
            if let name = usable(part.name) { return name }
        }
        return untitled
    }

    /// `<32 hex>_PLA_4h29m` → `PLA_4h29m`: a printer that names its uploads
    /// by hash puts the hash IN FRONT of the slicer's name, and "d0de11…"
    /// leading a title is no better than the bare hash. Only a whole 32, 40
    /// or 64-digit run followed by a separator is taken off; anything that
    /// merely starts with hex letters ("cafe_stand") is a name.
    static func withoutHashPrefix(_ name: String) -> String {
        for length in [64, 40, 32] where name.count > length {
            let head = name.prefix(length)
            let next = name[name.index(name.startIndex, offsetBy: length)]
            guard head.allSatisfy(\.isHexDigit), "_- ".contains(next) else { continue }
            let rest = name.dropFirst(length).drop { "_- ".contains($0) }
            return String(rest).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// `Benchy.gcode.3mf` → `Benchy`: a sliced plate often carries two.
    static func dropExtension(_ name: String) -> String {
        var out = name
        let known = ["gcode", "3mf", "bgcode", "gco", "g", "stl", "obj", "step", "stp"]
        while let dot = out.lastIndex(of: "."), dot != out.startIndex,
              known.contains(out[out.index(after: dot)...].lowercased()) {
            out = String(out[..<dot])
        }
        return out
    }
}

extension Shop {
    /// A job's title as the screens draw it — see `JobTitle`. Display only.
    func shownTitle(of job: Order) -> String {
        JobTitle.shown(project: job.project, parts: job.parts,
                       fileTitle: { id in self.files.first { $0.id == id }?.title },
                       untitled: words.callIt("mac.untitled_print"))
    }
}
