import SwiftUI
import AppKit
import KhaytCore

/// Converting several 3MFs for one printer at once — the desktop's batch panel
/// (`renderer/converter.js` `runBatch`).
///
/// The same rules, file by file: a model from another ecosystem is saved as a
/// Generic 3MF rather than retargeted into an incoherent one, and the colour
/// choice — merge into the printer's slots, Full Spectrum or band-swap — is
/// offered only for a printer that mixes, and applied only to a file with more
/// colours than heads. The files land in one folder the shop picks and in the
/// library, as a single conversion does.
struct BatchConvertSheet: View {
    static let width: CGFloat = 480

    let shop: Shop
    let request: Shop.BatchConvertRequest

    @State private var targetId = ""
    @State private var colourMode = "merge"
    @State private var status: [String: Bool] = [:]
    @State private var running = false
    @State private var finished = false
    @State private var started = false

    private var words: Words { shop.words }
    private var target: KhaytEngine.PrinterProfile? { shop.printerProfiles.first { $0.id == targetId } }
    /// A printer that mixes in hardware: the colour choice applies.
    private var colourCapable: Bool { target?.supportsMixedFilament == true && (target?.maxColors ?? 0) >= 2 }

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(words.callIt("conv.title")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(words.callIt("conv.batch_target")).foregroundStyle(.secondary)
                    Picker("", selection: $targetId) {
                        ForEach(shop.printerProfiles) { p in Text(p.name).tag(p.id) }
                        Divider()
                        Text(words.callIt("mac.standard_3mf")).tag("")
                    }
                    .labelsHidden()
                    .disabled(running)
                }
            }
            if colourCapable {
                let heads: [String: JSONValue] = ["n": .string(Money.quantity(Double(target?.maxColors ?? 4), decimals: 0))]
                Picker(words.callIt("conv.batch_colour"), selection: $colourMode) {
                    Text(words.callIt("conv.batch_colour_merge", heads)).tag("merge")
                    Text(words.callIt("conv.batch_colour_fs", heads)).tag("fs")
                    Text(words.callIt("conv.batch_colour_band")).tag("band")
                }
                .pickerStyle(.radioGroup)
                .disabled(running)
            }
            if !targetId.isEmpty {
                Text(words.callIt("conv.batch_cross_note")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(request.files) { file in
                    HStack(spacing: 6) {
                        Image(systemName: status[file.id].map { $0 ? "checkmark.circle" : "xmark.circle" } ?? "doc")
                            .foregroundStyle(status[file.id] == false ? Khayt.attention : .secondary)
                        Text(file.title).lineLimit(1)
                        Spacer()
                        if status[file.id] == false {
                            Text(words.callIt("conv.batch_fail")).font(.caption).foregroundStyle(Khayt.attention)
                        }
                    }
                    .font(.callout)
                }
            }
        } footer: {
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(words.callIt(finished ? "common.done" : "common.cancel")) { shop.pendingBatchConvert = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                if !finished {
                    Button(words.callIt("conv.batch_run", ["n": .string(Money.quantity(Double(request.files.count), decimals: 0))]),
                           action: run)
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || shop.converting)
                }
            }
        }
        .task {
            guard !started else { return }
            started = true
            targetId = request.targetId ?? ""
        }
    }

    private func run() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = words.callIt("conv.batch_dest_folder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        running = true
        let files = request.files
        let id = targetId.isEmpty ? nil : targetId
        let mode = colourCapable ? colourMode : ""
        Task {
            _ = await shop.convertBatch(files, targetId: id, colourMode: mode, into: folder) { fileId, ok in
                status[fileId] = ok
            }
            running = false
            finished = true
        }
    }
}
