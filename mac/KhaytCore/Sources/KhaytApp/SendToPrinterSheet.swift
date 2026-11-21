import SwiftUI
import AppKit
import KhaytCore

/// Send a sliced file to a printer, and start it.
///
/// Opens on the job's own machine and its newest sliced plate, because that is
/// the send a shop means nine times in ten: the job is assigned, the plate was
/// sliced into the model's folder a minute ago. Anything else on disk can be
/// chosen instead. Whether the printer can run the file is asked of the shared
/// rule before a byte goes — a model that was never sliced, or a 3MF offered
/// to a Klipper machine, is refused here with the reason, not on the printer.
///
/// A MODEL is offered too — the job's own, or one chosen — and is sliced with
/// the shop's default slicer before it is sent, as the desktop's "Slice &
/// print" does (`Shop.sliceAndSend`). Whether a file is a model is the upload
/// rule's `not_sliced`, not a list of extensions here.
struct SendToPrinterSheet: View {
    static let width: CGFloat = 440

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var machineId = ""
    @State private var files: [URL] = []
    @State private var file: URL?
    @State private var start = true
    @State private var fit: KhaytEngine.UploadFit?
    @State private var started = false
    /// The chosen file is a model, and the shop has a slicer to slice it with.
    @State private var slicesFirst = false
    /// The shared rule's findings for this file on this printer (C8).
    @State private var findings: [KhaytEngine.SendFinding] = []

    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    /// Only one the sheet offers: a retired or under-service printer the job
    /// still names is not a printer to send to.
    private var machine: Machine? { shop.sendablePrinters.first { $0.id == machineId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.send_title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            if shop.sendablePrinters.isEmpty {
                Text(shop.words.callIt("mac.send_no_printers"))
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(shop.words.callIt("mac.send_printer")).foregroundStyle(.secondary)
                        Picker("", selection: $machineId) {
                            ForEach(shop.sendablePrinters) { m in Text(m.name).tag(m.id) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text(shop.words.callIt("mac.send_file")).foregroundStyle(.secondary)
                        HStack {
                            Picker("", selection: $file) {
                                if files.isEmpty { Text(shop.words.callIt("mac.send_no_files")).tag(URL?.none) }
                                ForEach(files, id: \.self) { u in Text(u.lastPathComponent).tag(URL?.some(u)) }
                            }
                            .labelsHidden()
                            Button(shop.words.callIt("mac.send_choose")) { choose() }
                        }
                    }
                }
                Toggle(shop.words.callIt("mac.send_start"), isOn: $start)
                if slicesFirst, let slicer = shop.defaultSlicer {
                    Label(shop.words.callIt("mac.send_will_slice", ["name": .string(slicer.name)]),
                          systemImage: "square.stack.3d.up")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let fit, !fit.ok, let reason = reason(fit) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Checked against this printer (page 23, frames 1 and 1b). A
                // model that is sliced on the way is checked after slicing,
                // not here: there is no sliced file to read yet.
                if !slicesFirst, let machine {
                    SendChecksRows(findings: findings, fits: nil, printer: machine.name,
                                   bounds: nil, bed: Self.bed(machine), words: shop.words)
                }
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(Self.sendKey(slicesFirst: slicesFirst, start: start, findings: findings)),
                       action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || machine == nil || !(fit?.ok == true || slicesFirst)
                              || shop.slicingFor != nil
                              // A stop, not a warning: the button stays off.
                              || (!slicesFirst && SendChecks.holds(findings))
                              || !shop.printerAllows("send"))
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .task {
            guard !started else { return }
            started = true
            // The job's machine when it has a connection, else the first that does.
            if let own = job?.machineId, shop.sendablePrinters.contains(where: { $0.id == own }) { machineId = own }
            else { machineId = shop.sendablePrinters.first?.id ?? "" }
            // The sliced plates first — the send meant nine times in ten —
            // then the job's models, which are sliced on the way.
            if let job {
                files = shop.slicedFiles(for: job)
                for model in shop.modelFiles(for: job) where !files.contains(model) { files.append(model) }
            }
            file = files.first
            await refit()
        }
        .onChange(of: machineId) { _, _ in Task { await refit() } }
        .onChange(of: file) { _, _ in Task { await refit() } }
    }

    private func reason(_ fit: KhaytEngine.UploadFit) -> String? {
        switch fit.code {
        case "not_sliced":
            // A model with no slicer to slice it: say where to set one.
            return shop.words.callIt(shop.defaultSlicer == nil ? "slicer.no_config" : "mac.send_not_sliced")
        case "wrong_kind": return shop.words.callIt("mac.send_wrong_kind", ["kind": .string(fit.kind ?? "")])
        case "unsupported": return shop.words.callIt("mac.send_unsupported")
        default: return nil
        }
    }

    /// The button's words: "Send anyway" when the checks found something to
    /// look at and nothing that holds the send.
    static func sendKey(slicesFirst: Bool, start: Bool, findings: [KhaytEngine.SendFinding]) -> String {
        if slicesFirst { return start ? "slicer.send_title" : "mac.slice_send_only" }
        if SendChecks.asksAnyway(findings) { return "mac.send_anyway" }
        return start ? "mac.send_and_start" : "mac.send_only"
    }

    /// What is loaded, for the checks: what the printer itself reported on
    /// its last poll (a Snapmaker U1's `print_task_config`) when it reported
    /// anything, else what the shop recorded on the machine.
    static func loaded(live: [KhaytEngine.LoadedSlot]?, record: JSONValue?) -> JSONValue? {
        guard let live, !live.isEmpty else { return record }
        return .array(live.map { .object(["slot": .number(Double($0.slot)), "hex": .string($0.hex), "material": .string($0.material)]) })
    }

    static func bed(_ machine: Machine) -> KhaytEngine.SendFinding.Size? {
        guard let bed = machine.bed else { return nil }
        return .init(x: bed.x, y: bed.y, z: bed.z)
    }

    /// The shared rule's findings for this file on this printer. Nothing is
    /// assumed: a file whose text cannot be read, or a printer with nothing
    /// recorded as loaded, simply has fewer findings.
    private func recheck() async {
        guard let file, let machine, let engine = shop.engine,
              let row = shop.machineRows.first(where: { Shop.asObject($0)?["id"] == .string(machine.id) }) else {
            findings = []; return
        }
        let asked = (file, machine.id)
        let text = await SendChecks.gcodeText(file)
        let loaded = Self.loaded(live: shop.printers.readings[machine.id]?.status?.loaded, record: Shop.asObject(row)?["loaded"])
        let found = (try? await engine.sendChecks(fileName: file.lastPathComponent, gcodeText: text, bounds: nil,
                                                  machine: row, loaded: loaded)) ?? []
        // The answer to a question the sheet has stopped asking is dropped.
        guard asked.0 == self.file, asked.1 == machineId else { return }
        findings = found
    }

    /// Asked again whenever the printer or the file changes.
    private func refit() async {
        slicesFirst = false
        await recheck()
        guard let file, let type = machine?.printerApi?.type, let engine = shop.engine else { fit = nil; return }
        var answer = try? await engine.printerUploadCheck(type: type, fileName: file.lastPathComponent)
        // Bambu passes the rule but is not spoken from this app yet.
        if answer?.ok == true, type == "bambu" {
            answer = KhaytEngine.UploadFit(ok: false, code: "unsupported", kind: nil)
        }
        fit = answer
        // A model goes through the slicer first — to any printer that takes
        // G-code, which `sliceAndSend` asks again before it slices.
        if answer?.ok == false, answer?.code == "not_sliced", type != "bambu", shop.defaultSlicer != nil {
            slicesFirst = true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = shop.words.callIt(shop.defaultSlicer == nil ? "mac.send_choose_hint" : "mac.send_choose_hint_model")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !files.contains(url) { files.insert(url, at: 0) }
        file = url
    }

    private func commit() {
        guard let file, !machineId.isEmpty else { return }
        let id = machineId
        let go = start
        shop.clearQuestion()
        // The job goes with it, so the job records the machine that ran it.
        let jobId = subject.id
        if slicesFirst {
            Task { await shop.sliceAndSend(file, machineId: id, startPrint: go, jobId: jobId) }
        } else {
            Task { await shop.sendToPrinter(file, machineId: id, startPrint: go, jobId: jobId) }
        }
    }
}
