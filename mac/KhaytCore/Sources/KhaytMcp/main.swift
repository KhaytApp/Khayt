import Foundation

/// The pipe, and nothing else.
///
/// Everything that decides an answer is in `Server`, which is pure — this file
/// only moves bytes, so the protocol can be tested by handing `Server` a
/// dictionary rather than by spawning a process and hoping.
///
/// ── LINE-DELIMITED JSON, WHICH IS WHAT MCP'S STDIO TRANSPORT IS ───────────
///
/// One JSON object per line, in and out, UTF-8. No framing headers — that is
/// the Language Server Protocol, which MCP is often confused with and does not
/// copy here.
///
/// ── AND NOTHING IS EVER PRINTED TO STDOUT THAT IS NOT A RESPONSE ──────────
///
/// stdout IS the protocol. A stray `print` — a warning, a progress line, a
/// debug dump — lands in the middle of the stream and the host drops the
/// connection with a parse error that names nothing. Diagnostics go to stderr,
/// which hosts log and ignore.
func note(_ said: String) {
    FileHandle.standardError.write(Data("khayt-mcp: \(said)\n".utf8))
}

let storeURL = Library.storeURL()
let library: Library
do {
    library = try Library.read(from: storeURL)
    note("\(library.models.count) model(s) from \(storeURL.path)")
} catch {
    // A shop that has never opened Khayt has no book, and that is not a crash:
    // the host would show a server that failed to start rather than a server
    // with nothing to say. An empty library answers every question honestly.
    note("no book at \(storeURL.path) — \(error.localizedDescription)")
    library = Library(models: [])
}
let server = Server(library: library)

while let line = readLine(strippingNewline: true) {
    let tidy = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tidy.isEmpty else { continue }
    guard let data = tidy.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        note("could not read a line as JSON")
        continue
    }
    guard let response = server.answer(to: request) else { continue }
    guard let out = try? JSONSerialization.data(withJSONObject: response) else { continue }
    FileHandle.standardOutput.write(out)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
