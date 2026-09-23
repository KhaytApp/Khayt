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

    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    private var machine: Machine? { shop.machines.first { $0.id == machineId } }

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
                if let fit, !fit.ok, let reason = reason(fit) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(start ? "mac.send_and_start" : "mac.send_only"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || machine == nil || fit?.ok != true)
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
            if let job { files = shop.slicedFiles(for: job) }
            file = files.first
            await refit()
        }
        .onChange(of: machineId) { _, _ in Task { await refit() } }
        .onChange(of: file) { _, _ in Task { await refit() } }
    }

    private func reason(_ fit: KhaytEngine.UploadFit) -> String? {
        switch fit.code {
        case "not_sliced": return shop.words.callIt("mac.send_not_sliced")
        case "wrong_kind": return shop.words.callIt("mac.send_wrong_kind", ["kind": .string(fit.kind ?? "")])
        case "unsupported": return shop.words.callIt("mac.send_unsupported")
        default: return nil
        }
    }

    /// Asked again whenever the printer or the file changes.
    private func refit() async {
        guard let file, let type = machine?.printerApi?.type, let engine = shop.engine else { fit = nil; return }
        var answer = try? await engine.printerUploadCheck(type: type, fileName: file.lastPathComponent)
        // Bambu passes the rule but is not spoken from this app yet.
        if answer?.ok == true, type == "bambu" {
            answer = KhaytEngine.UploadFit(ok: false, code: "unsupported", kind: nil)
        }
        fit = answer
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = shop.words.callIt("mac.send_choose_hint")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !files.contains(url) { files.insert(url, at: 0) }
        file = url
    }

    private func commit() {
        guard let file, !machineId.isEmpty else { return }
        let id = machineId
        let go = start
        shop.clearQuestion()
        Task { await shop.sendToPrinter(file, machineId: id, startPrint: go) }
    }
}
