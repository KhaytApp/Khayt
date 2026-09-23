import Foundation
import KhaytCore

/// Sending a sliced file to a printer, and optionally starting it.
///
/// This app could poll a printer, pause it and skip an object on it, and could
/// not hand it a file: a Mac shop sliced a job and then walked a USB stick
/// over, or went to the printer's own page. The Electron app could send to
/// four kinds of printer. The request each one is asked is now
/// `lib/printer-upload.js`, shared; this is the Mac's wire, over the same
/// address guard and redirect refusal as every other request to a printer.
///
/// OctoPrint, Moonraker and PrusaLink speak HTTP and are sent from here. Bambu
/// needs FTPS and MQTT, which this app does not speak yet; it is refused with
/// that said, rather than failing somewhere obscure.
@MainActor
enum PrinterSend {

    enum Problem: LocalizedError, Equatable {
        case noConnection
        case unsupported(String)
        case notSliced
        case wrongKind(String)
        case bambuNotYet

        var errorDescription: String? {
            switch self {
            case .noConnection: "This machine has no printer connection set up."
            case .unsupported(let type): "Sending a file to \(type.isEmpty ? "this printer" : type) is not supported yet."
            case .notSliced: "That file has to be sliced first."
            case .wrongKind(let kind): "This printer cannot run a .\(kind) file."
            case .bambuNotYet: "Sending to a Bambu printer is done from the Windows and Linux app for now."
            }
        }
    }

    struct Sent: Equatable {
        let remoteName: String
        let started: Bool
    }

    /// Send `file` to `machine`. `key` is the machine's API key, OPENED — the
    /// caller opens it at the moment of sending and holds it nowhere else.
    static func send(_ file: URL, to machine: Machine, key: String, startPrint: Bool,
                     engine: KhaytEngine, now: Date = Date(),
                     fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> Sent {
        guard let type = machine.printerApi?.type, !type.isEmpty else { throw Problem.noConnection }
        let fit = try await engine.printerUploadCheck(type: type, fileName: file.lastPathComponent)
        guard fit.ok else {
            switch fit.code {
            case "not_sliced": throw Problem.notSliced
            case "wrong_kind": throw Problem.wrongKind(fit.kind ?? file.pathExtension)
            default: throw Problem.unsupported(type)
            }
        }
        if type == "bambu" { throw Problem.bambuNotYet }
        let name = try await engine.printerUploadName(fileName: file.lastPathComponent, now: now)
        guard let request = try await engine.printerUploadRequest(type: type, apiKey: key, name: name,
                                                                  startPrint: startPrint)
        else { throw Problem.unsupported(type) }
        let base = try await PrinterWatch.baseURL(machine, engine: engine)
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        var headers = request.headers
        let body: Data
        if request.body.kind == "multipart", let part = request.body.file {
            let boundary = "khayt-" + UUID().uuidString
            body = multipart(file: bytes, name: name, part: part,
                             fields: request.body.fields ?? [], boundary: boundary)
            headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        } else {
            body = bytes
        }
        try await PrinterWatch.upload(base, path: request.path, method: request.method,
                                      headers: headers, body: body, fetch: fetch)
        return Sent(remoteName: name, started: startPrint)
    }

    /// `multipart/form-data`, the file part first and then each field in
    /// order — the order Electron's FormData has always sent them in.
    static func multipart(file: Data, name: String, part: KhaytEngine.UploadRequest.FilePart,
                          fields: [[String]], boundary: String) -> Data {
        var out = Data()
        func line(_ s: String) { out.append(Data((s + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"\(part.field)\"; filename=\"\(name)\"")
        line("Content-Type: \(part.contentType)")
        line("")
        out.append(file)
        line("")
        for field in fields where field.count == 2 {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(field[0])\"")
            line("")
            line(field[1])
        }
        line("--\(boundary)--")
        return out
    }

    /// The files in a folder that look sliced — what a job's model folder
    /// offers to send. Newest first: the plate sliced last is the one meant.
    static func slicedFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let found = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let sliced = found.filter { url in
            let n = url.lastPathComponent.lowercased()
            return n.hasSuffix(".gcode") || n.hasSuffix(".bgcode") || n.hasSuffix(".gcode.3mf")
                || n.hasSuffix(".gco")
        }
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return sliced.sorted { date($0) > date($1) }
    }
}
