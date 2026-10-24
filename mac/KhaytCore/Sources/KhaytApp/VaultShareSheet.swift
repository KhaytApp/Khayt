import SwiftUI
import KhaytCore

/// Making a private share link to one model or a selection.
///
/// ── WHAT THE SHOP DECIDES, AND WHAT IT IS TOLD ────────────────────────────
///
/// How many downloads, until when, and whether a password is needed. Each says
/// plainly what it does and does not do: a download limit counts downloads
/// through the link, it does not stop a file being copied once it is on
/// someone's computer, and a password helps only if it is long, because anyone
/// holding the link can try guesses offline. Saying so here is the promise the
/// share page makes too (`docs/api-contract.md` in khayt-cloud).
///
/// ── THE LINK ITSELF ───────────────────────────────────────────────────────
///
/// Shown once made, with Copy link and Send on WhatsApp. It is written LEFT TO
/// RIGHT in Arabic as well: it is an address, and a mirrored one cannot be
/// read back over the phone. The password is never put into the message.
///
/// ── ONLY THESE PEOPLE ─────────────────────────────────────────────────────
///
/// An optional email list (phase 2b): each person proves their address with
/// a code the cloud emails them before the page shows anything. Unlike the
/// note, the addresses are not sealed — the cloud must read them to send the
/// codes, and every device of the shop lists them — and the sheet says so
/// next to the field. The list is checked as it is typed (`VaultLinks.emailLock`).
///
/// ── WHEN KHAYT HAS TURNED THE SHOP'S LINKS OFF ───────────────────────────
///
/// A create answered 403 `links-disabled` replaces the form with a plain
/// explanation and takes Create away: trying again cannot work.
struct VaultShareSheet: View {
    let shop: Shop
    let request: VaultShareRequest

    @State private var limitDownloads = true
    @State private var downloads = 5
    @State private var perFile = false
    /// Days until the link ends; 0 for no end date.
    @State private var days = 7
    @State private var usePassword = false
    @State private var password = ""
    @State private var note = ""
    @State private var working = false
    @State private var problem: String?
    @State private var made: VaultLink?
    @State private var madePassword = false
    @State private var secretKept = true
    @State private var told: String?
    @State private var useLock = false
    @State private var lockText = ""
    @State private var madeLocked = false
    /// Set when the cloud said Khayt turned this shop's links off.
    @State private var turnedOff: String?

    private var words: Words { shop.words }

    /// `shown` opens the sheet on a link already made, `emails` with the email
    /// list on and filled, `linksOff` on the turned-off explanation: each for a
    /// photograph of that state, which the app itself reaches only through Create.
    init(shop: Shop, request: VaultShareRequest, shown: VaultLink? = nil, withPassword: Bool = false,
         emails: String? = nil, linksOff: Bool = false) {
        self.shop = shop; self.request = request
        _made = State(initialValue: shown)
        _madePassword = State(initialValue: withPassword)
        _usePassword = State(initialValue: withPassword && shown == nil)
        _useLock = State(initialValue: emails != nil && shown == nil)
        _lockText = State(initialValue: emails ?? "")
        _madeLocked = State(initialValue: emails != nil && shown != nil)
        _turnedOff = State(initialValue: linksOff ? shop.linkProblem(VaultClient.Failure.linksDisabled) : nil)
    }

    static let dayChoices = [1, 7, 30, 90, 0]

    private var endDate: Date? {
        days == 0 ? nil : Calendar.book.date(byAdding: .day, value: days, to: Date())
    }

    private var passwordOk: Bool { !usePassword || VaultCrypto.linkPasswordOk(password) }

    /// The email list as the cloud will get it, or why it cannot be sent.
    private var lockCheck: Result<[String], Error> {
        Result { try VaultLinks.emailLock(VaultLinks.emails(in: lockText)) }
    }

    private var lockOk: Bool {
        guard useLock else { return true }
        if case .success = lockCheck { return true }
        return false
    }

    /// Under the field: how many addresses, or what is wrong. Nothing while
    /// it is still empty (the explanation says what to do).
    private var lockStatus: (text: String, ok: Bool)? {
        guard useLock, !lockText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch lockCheck {
        case .success(let list): return (Shop.say(words, "mac.vl_lock_count", list.count), true)
        case .failure(let e): return (shop.linkProblem(e), false)
        }
    }

    private var heading: String {
        request.titles.count == 1 ? (request.titles.first ?? "")
            : Shop.say(words, "mac.vl_n_models", request.titles.count)
    }

    var body: some View {
        SheetFrame(width: 440) {
            VStack(alignment: .leading, spacing: 4) {
                Text(words.callIt("mac.vl_share_title")).font(.headline)
                Text(heading).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let made {
                result(made)
            } else if let turnedOff {
                Label {
                    Text(turnedOff).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "nosign").foregroundStyle(Khayt.attention)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Khayt.attention.opacity(0.1)))
            } else {
                form
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(words.callIt(made == nil && turnedOff == nil ? "common.cancel" : "common.close")) {
                    shop.sharingByLink = nil
                }
                    .keyboardShortcut(.cancelAction)
                if made == nil && turnedOff == nil {
                    Button(words.callIt("mac.vl_create")) { Task { await create() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !passwordOk || !lockOk)
                }
            }
        }
    }

    // MARK: - Before

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(words.callIt("mac.vl_limit_downloads"), isOn: $limitDownloads)
            if limitDownloads {
                Stepper(value: $downloads, in: 1...1000) {
                    Text(Shop.say(words, "mac.vl_downloads_n", downloads))
                }
                if request.recordIds.count > 1 {
                    Toggle(words.callIt("mac.vl_per_file"), isOn: $perFile)
                }
            }
            Text(words.callIt("mac.vl_downloads_explain"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 6) {
            Picker(words.callIt("mac.vl_ends"), selection: $days) {
                ForEach(Self.dayChoices, id: \.self) { d in
                    Text(d == 0 ? words.callIt("mac.vl_no_end") : Shop.say(words, "mac.vl_after_days", d)).tag(d)
                }
            }
            if let endDate {
                Text(words.callIt("mac.vl_ends_on", ["date": .string(words.say(endDate, .dateTime.day().month().year()))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Toggle(words.callIt("mac.vl_use_password"), isOn: $usePassword)
            if usePassword {
                SecureField(words.callIt("mac.vl_password_ph"), text: $password)
                    .textFieldStyle(.roundedBorder)
                Text(words.callIt("mac.vl_password_rule"))
                    .font(.caption)
                    .foregroundStyle(!password.isEmpty && !passwordOk ? Khayt.attention : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(words.callIt("mac.vl_password_explain"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Toggle(words.callIt("mac.vl_lock_toggle"), isOn: $useLock)
            if useLock {
                TextField(words.callIt("mac.vl_lock_ph"), text: $lockText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .autocorrectionDisabled()
                if let lockStatus {
                    Text(lockStatus.text)
                        .font(.caption)
                        .foregroundStyle(lockStatus.ok ? Color.secondary : Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(words.callIt("mac.vl_lock_explain"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            TextField(words.callIt("mac.vl_note_ph"), text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            Text(words.callIt("mac.vl_note_explain"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - After

    @ViewBuilder private func result(_ link: VaultLink) -> some View {
        Text(link.url)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            // An address reads left to right in every language.
            .environment(\.layoutDirection, .leftToRight)
        HStack {
            Button(words.callIt("mac.vl_copy_link")) {
                shop.copyLink(link)
                told = words.callIt("mac.copied")
            }
            Button(words.callIt("mac.vl_send_whatsapp")) {
                told = shop.sendLinkOnWhatsApp(link) ? nil : words.callIt("mac.vl_no_whatsapp")
            }
            Spacer()
        }
        if let told {
            Text(told).font(.caption).foregroundStyle(Khayt.done)
        }
        if madePassword {
            Text(words.callIt("mac.vl_password_separately"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        if madeLocked {
            Text(words.callIt("mac.vl_lock_made"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        if !secretKept {
            Text(words.callIt("mac.vl_not_kept"))
                .font(.callout).foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
        }
        Text(words.callIt("mac.vl_private_explain"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func create() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        working = true
        problem = nil
        defer { working = false }
        let options = VaultLinks.Options(maxDownloads: limitDownloads ? downloads : nil,
                                         perFile: limitDownloads && perFile,
                                         expiresAt: endDate,
                                         password: usePassword ? password : nil,
                                         note: note,
                                         emailLock: useLock ? VaultLinks.emails(in: lockText) : nil)
        switch await shop.makeShareLink(request, options: options) {
        case .made(let created):
            made = created.link
            secretKept = created.secretKept
            madePassword = usePassword
            madeLocked = useLock
            // The password has done its work; it is not kept, here or anywhere.
            password = ""
        case .refused(let why):
            problem = why
        case .turnedOff(let why):
            turnedOff = why
        }
    }
}
