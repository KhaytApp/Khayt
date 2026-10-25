import Foundation

/// A model page a shop saved from its browser, on its way into the library.
///
/// ── THE WHOLE ROUTE, AND WHERE IT CAN BE TRUSTED ──────────────────────────
///
/// The "Save to Khayt" browser extension reads the page the shop is looking at
/// (Printables, MakerWorld, Thingiverse, …) and hands it to the browser's
/// NATIVE MESSAGING — the one channel a web page cannot reach. On Safari the
/// other end is `KhaytSafari.appex` inside Khayt.app; on Chrome, Edge, Brave
/// and Firefox it is the small host program beside the app. Both write the
/// save as one JSON file into an inbox in the app group's container, and the
/// app reads the inbox and files the page as a library record.
///
/// NOTHING in that message is the shop's word. It is what a web page said
/// about itself, read by a script, and a hostile page says whatever it likes.
/// So the message is checked HERE, the same way by the three programs that
/// touch it — the extension's own end checks it before writing a file, and the
/// app checks the file again before it reads a field — and this is the list of
/// what survives:
///
/// - addresses are `https` with a host and no user name or password in them,
///   and at most 2,048 characters;
/// - every text is a single line (the description keeps its line breaks), with
///   control characters taken out and a length cap of its own;
/// - at most 20 tags and 20 file links;
/// - the whole message at most 64 KB.
///
/// Anything else is refused whole rather than trimmed into something the page
/// did not say. Nothing from it is ever opened, run or fetched except the
/// cover picture, which the app fetches over https with a size cap and only
/// keeps when it decodes as a picture (`Shop.fetchWebCover`).
public enum WebSave {

    /// The message format. A newer extension sending `v: 2` is refused rather
    /// than half-read — it says something this build cannot know it means.
    public static let version = 1

    // MARK: - Caps

    public static let maxMessageBytes = 64 * 1024
    public static let maxURL = 2_048
    public static let maxTitle = 200
    public static let maxCreator = 120
    public static let maxLicence = 120
    public static let maxDescription = 1_000
    public static let maxTag = 40
    public static let maxTags = 20
    public static let maxFiles = 20
    public static let maxFileName = 200

    /// How long after a save a downloaded model file is still taken to belong
    /// to it — the window in which the browser's download is offered to the
    /// saved record (Chrome's downloads API, or Safari's ~/Downloads watch).
    public static let attachWindow: TimeInterval = 10 * 60

    // MARK: - The sites

    /// The model sites the extension has a reader for. Anything else is
    /// `web`, read from the page's own JSON-LD and Open Graph.
    public enum Site: String, CaseIterable, Codable, Sendable {
        case printables, makerworld, thingiverse, thangs, cults3d, myminifactory, web

        /// The site's own name. A brand, so the same in every language.
        public var displayName: String {
            switch self {
            case .printables: "Printables"
            case .makerworld: "MakerWorld"
            case .thingiverse: "Thingiverse"
            case .thangs: "Thangs"
            case .cults3d: "Cults3D"
            case .myminifactory: "MyMiniFactory"
            case .web: ""
            }
        }

        /// The site an address belongs to, by its host alone.
        public static func of(host raw: String?) -> Site {
            var host = (raw ?? "").lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
            if under("printables.com") { return .printables }
            if under("makerworld.com") || under("makerworld.com.cn") { return .makerworld }
            if under("thingiverse.com") { return .thingiverse }
            if under("thangs.com") { return .thangs }
            if under("cults3d.com") { return .cults3d }
            if under("myminifactory.com") { return .myminifactory }
            return .web
        }
    }

    // MARK: - What a save is

    /// One model file the page links to.
    public struct FileLink: Codable, Equatable, Hashable, Sendable {
        public var url: String
        public var name: String

        public init(url: String, name: String) {
            self.url = url
            self.name = name
        }
    }

    /// The page, as the extension read it and as this module let it through.
    public struct Page: Codable, Equatable, Sendable {
        /// The page's canonical address — what a second save of the same model
        /// is recognised by (`identity`).
        public var url: String
        public var site: Site
        /// The model's title on the page. Becomes the record's `name`, which is
        /// a TITLE, never a file name.
        public var title: String
        public var creator: String
        /// As the page said it: `CC BY-NC-SA 4.0`, `Standard Digital File
        /// License`. The app translates only what `ModelLicence.fromFile` can.
        public var licence: String
        public var description: String
        public var tags: [String]
        public var cover: String?
        public var files: [FileLink]

        public init(url: String, site: Site, title: String, creator: String = "", licence: String = "",
                    description: String = "", tags: [String] = [], cover: String? = nil,
                    files: [FileLink] = []) {
            self.url = url; self.site = site; self.title = title; self.creator = creator
            self.licence = licence; self.description = description; self.tags = tags
            self.cover = cover; self.files = files
        }
    }

    /// A downloaded file the browser says came from a saved page.
    public struct Attach: Codable, Equatable, Sendable {
        /// The saved page it belongs to.
        public var page: String
        /// Where the browser put it, on this Mac. A path, checked by the app
        /// before it is read: a model file kind, under the user's home.
        public var path: String
        public var name: String

        public init(page: String, path: String, name: String) {
            self.page = page; self.path = path; self.name = name
        }
    }

    public enum Kind: String, Codable, Sendable { case save, attach }

    /// One file in the inbox.
    public struct Entry: Codable, Equatable, Sendable {
        public var v: Int
        /// Made by the writer of the file, never taken from the page.
        public var id: String
        public var kind: Kind
        /// ISO-8601, when the writer received it.
        public var at: String
        /// `safari`, `chrome`, `edge`, `brave`, `firefox` — which inbox writer.
        public var browser: String
        public var page: Page?
        public var attach: Attach?

        public init(id: String, kind: Kind, at: String, browser: String, page: Page? = nil, attach: Attach? = nil) {
            self.v = WebSave.version; self.id = id; self.kind = kind; self.at = at
            self.browser = browser; self.page = page; self.attach = attach
        }
    }

    /// Why a message was not let through. Said back to the extension as its
    /// raw value, so the popup can say which.
    public enum Refusal: String, Error, Equatable, Sendable {
        case tooLarge = "too-large"
        case notJSON = "not-json"
        case badVersion = "bad-version"
        case badKind = "bad-kind"
        case badURL = "bad-url"
        case noTitle = "no-title"
        case badPath = "bad-path"
    }

    // MARK: - Checking

    /// The extension's message, as the native end receives it — a JSON object
    /// (`{v, kind, page}` or `{v, kind, attach}`) — checked and given an id.
    public static func entry(fromMessage message: Any?, id: String, at: String,
                             browser: String) throws(Refusal) -> Entry {
        guard let message, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { throw .notJSON }
        return try entry(fromMessageData: data, id: id, at: at, browser: browser)
    }

    /// The same, from the message's bytes (the Chromium host reads them off
    /// its standard input).
    public static func entry(fromMessageData data: Data, id: String, at: String,
                             browser: String) throws(Refusal) -> Entry {
        guard data.count <= maxMessageBytes else { throw .tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let o = object as? [String: Any] else { throw .notJSON }
        guard (o["v"] as? NSNumber)?.intValue == version else { throw .badVersion }
        let browserName = line(browser, max: 20).lowercased()
        switch o["kind"] as? String {
        case Kind.save.rawValue:
            return Entry(id: id, kind: .save, at: at, browser: browserName,
                         page: try page(o["page"] as? [String: Any]))
        case Kind.attach.rawValue:
            return Entry(id: id, kind: .attach, at: at, browser: browserName,
                         attach: try attach(o["attach"] as? [String: Any]))
        default:
            throw .badKind
        }
    }

    /// An inbox file, read back and checked again: the app trusts the file no
    /// more than the page — anything that can write the group's container can
    /// write one.
    public static func entry(fromInboxFile data: Data) throws(Refusal) -> Entry {
        guard data.count <= maxMessageBytes * 2 else { throw .tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let o = object as? [String: Any] else { throw .notJSON }
        guard (o["v"] as? NSNumber)?.intValue == version else { throw .badVersion }
        guard let id = o["id"] as? String, isEntryId(id) else { throw .notJSON }
        let at = line(o["at"] as? String ?? "", max: 40)
        // Re-checked through the message path, so there is one set of rules.
        var message: [String: Any] = ["v": version]
        message["kind"] = o["kind"]
        message["page"] = o["page"]
        message["attach"] = o["attach"]
        guard let again = try? JSONSerialization.data(withJSONObject: message) else { throw .notJSON }
        return try entry(fromMessageData: again, id: id, at: at, browser: o["browser"] as? String ?? "")
    }

    /// The shape of an id this module made: `WS-` and a UUID. A file named
    /// anything else in the inbox is not one of ours, and its id is never
    /// used to build a path.
    public static func isEntryId(_ id: String) -> Bool {
        guard id.hasPrefix("WS-"), id.count == 39 else { return false }
        return UUID(uuidString: String(id.dropFirst(3))) != nil
    }

    public static func newEntryId() -> String { "WS-" + UUID().uuidString }

    static func page(_ o: [String: Any]?) throws(Refusal) -> Page {
        guard let o else { throw .notJSON }
        guard var url = https(o["url"]) else { throw .badURL }
        // The page's claim of its own address (canonical, og:url) counts only
        // on the site the tab was showing. A page elsewhere claiming to be a
        // Printables model is saved as the page it is — the tab's address —
        // and never matches, or overwrites, the shop's record of that model.
        if let tab = https(o["tabUrl"]),
           registrable(URL(string: tab)?.host) != registrable(URL(string: url)?.host) {
            url = tab
        }
        let title = line(o["title"] as? String ?? "", max: maxTitle)
        guard !title.isEmpty else { throw .noTitle }
        var tags: [String] = []
        var seen = Set<String>()
        for case let raw as String in (o["tags"] as? [Any] ?? []).prefix(maxTags * 2) {
            let tag = line(raw.hasPrefix("#") ? String(raw.dropFirst()) : raw, max: maxTag)
            let key = tag.lowercased()
            guard !tag.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            tags.append(tag)
            if tags.count == maxTags { break }
        }
        var files: [FileLink] = []
        var seenFiles = Set<String>()
        for case let f as [String: Any] in (o["files"] as? [Any] ?? []).prefix(maxFiles * 2) {
            guard let u = https(f["url"]), !seenFiles.contains(u) else { continue }
            seenFiles.insert(u)
            var name = line(f["name"] as? String ?? "", max: maxFileName)
            if name.isEmpty { name = URL(string: u)?.lastPathComponent ?? "" }
            files.append(FileLink(url: u, name: line(name, max: maxFileName)))
            if files.count == maxFiles { break }
        }
        // The site is worked out from the address, never taken from the
        // message: a page on example.com calling itself Printables is web.
        let site = Site.of(host: URL(string: url)?.host)
        return Page(url: url, site: site, title: title,
                    creator: line(o["creator"] as? String ?? "", max: maxCreator),
                    licence: line(o["licence"] as? String ?? "", max: maxLicence),
                    description: text(o["description"] as? String ?? "", max: maxDescription),
                    tags: tags, cover: https(o["cover"]), files: files)
    }

    /// The part of a host a site owns: `www.printables.com` → `printables.com`,
    /// `shop.example.co.uk` → `example.co.uk` (a two-letter country ending
    /// under a generic second level counts as one suffix; the extension's
    /// `registrable` is the same rule). An address is itself.
    static func registrable(_ host: String?) -> String {
        var h = (host ?? "").lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h = String(h.dropLast()) }
        if h.isEmpty || h.contains(":") || h.allSatisfy({ $0.isNumber || $0 == "." }) { return h }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        let second = labels[labels.count - 2], tld = labels[labels.count - 1]
        let generic: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go"]
        let keep = tld.count == 2 && generic.contains(second) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    static func attach(_ o: [String: Any]?) throws(Refusal) -> Attach {
        guard let o else { throw .notJSON }
        guard let page = https(o["page"]) else { throw .badURL }
        let path = o["path"] as? String ?? ""
        guard path.hasPrefix("/"), path.count <= 1_024, !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              isModelFile(path) else { throw .badPath }
        var name = line(o["name"] as? String ?? "", max: maxFileName)
        if name.isEmpty { name = (path as NSString).lastPathComponent }
        return Attach(page: page, path: path, name: name)
    }

    // MARK: - Addresses

    /// An https address with a host, no credentials, no control characters and
    /// at most `maxURL` long — or nil. The fragment is dropped: it is a place
    /// on the page, not a different page.
    public static func https(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURL,
              trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }),
              var parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        parts.fragment = nil
        return parts.string
    }

    /// What tells two saves of one model apart from two models: the site and
    /// the model's own number where the site has one in its address, and
    /// otherwise the host and path with the locale and trailing slash taken
    /// off. The query is dropped — it is tracking and sorting, never the model.
    ///
    /// `printables.com/model/123-dragon` and `/model/123-dragon-v2` are the
    /// same model renamed; `makerworld.com/en/models/88` and
    /// `/zh/models/88-x` are one model in two languages.
    public static func identity(of raw: String) -> String {
        guard let url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              var host = url.host?.lowercased() else { return raw.lowercased() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path
        func number(_ pattern: String) -> String? {
            guard let r = path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let digits = path[r].filter(\.isNumber)
            return digits.isEmpty ? nil : String(digits)
        }
        let site = Site.of(host: host)
        switch site {
        case .printables: if let n = number(#"/model/\d+"#) { return "printables:\(n)" }
        case .makerworld: if let n = number(#"/models/\d+"#) { return "makerworld:\(n)" }
        case .thingiverse: if let n = number(#"/thing:\d+"#) { return "thingiverse:\(n)" }
        case .myminifactory: if let n = number(#"-\d+/?$"#) { return "myminifactory:\(n)" }
        case .thangs: if let n = number(#"-\d+/?$"#) { return "thangs:\(n)" }
        case .cults3d, .web: break
        }
        var segments = path.split(separator: "/").map(String.init)
        // A leading language segment (`/en/`, `/fr-FR/`) is the same page.
        if let first = segments.first, first.range(of: #"^[a-z]{2}(-[A-Za-z]{2})?$"#, options: .regularExpression) != nil,
           segments.count > 1 {
            segments.removeFirst()
        }
        return site == .web
            ? host + "/" + segments.joined(separator: "/")
            : site.rawValue + ":" + segments.joined(separator: "/").lowercased()
    }

    // MARK: - Files

    /// The model kinds a download may be attached as — what the library files
    /// (`LibraryImport.kinds` is the full list; this is the subset a model
    /// site hands out), and the archives they come in.
    public static let modelKinds: Set<String> = ["3mf", "stl", "obj", "step", "stp", "zip", "7z", "rar",
                                                  "gcode", "bgcode", "f3d", "blend", "ply", "amf"]

    public static func isModelFile(_ path: String) -> Bool {
        modelKinds.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: - Text

    /// One line: control characters and line breaks become spaces, runs of
    /// white space one space, trimmed and cut at `max` characters.
    public static func line(_ raw: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for scalar in raw.unicodeScalars {
            // White space (tabs and line breaks too) is one space; any other
            // control is dropped where it stood, so "Dra‮gon" is "Dragon".
            if scalar.properties.isWhitespace || (scalar.value < 0x20 && scalar != "\u{0}") {
                space = !out.isEmpty
                continue
            }
            if isControl(scalar) { continue }
            if space { out.append(" "); space = false }
            out.append(scalar)
        }
        return String(String(out).prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// Several lines: as `line`, but a line break survives (at most two in a
    /// row, so a page cannot pad the record with blank space).
    public static func text(_ raw: String, max: Int) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { line($0, max: max) }
        var out: [String] = []
        for l in lines {
            if l.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(l)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return String(out.joined(separator: "\n").prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// C0, DEL, C1, and the bidirectional controls a page could use to make a
    /// title read backwards (U+202A–U+202E, U+2066–U+2069). Zero-width joiners
    /// stay — Arabic and emoji need them.
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: true
        default: false
        }
    }
}
