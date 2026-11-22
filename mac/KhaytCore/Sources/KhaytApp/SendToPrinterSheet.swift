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
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(slicesFirst ? (start ? "slicer.send_title" : "mac.slice_send_only")
                                                     : (start ? "mac.send_and_start" : "mac.send_only")),
                       action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || machine == nil || !(fit?.ok == true || slicesFirst)
                              || shop.slicingFor != nil)
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

    /// Asked again whenever the printer or the file changes.
    private func refit() async {
        slicesFirst = false
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
