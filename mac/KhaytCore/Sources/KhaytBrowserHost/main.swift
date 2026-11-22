import AppKit
import Darwin
import Foundation
import KhaytWebSave

// ── THE BROWSER HOST: SAVE TO KHAYT FOR CHROME, EDGE, BRAVE, VIVALDI, FIREFOX ─
//
// Chromium browsers and Firefox reach a native program through NATIVE
// MESSAGING: the browser starts this executable, writes a message to its
// standard input — a 32-bit length, then that many bytes of UTF-8 JSON — and
// reads the answer back the same way (`NativeMessaging`). Only an extension
// named in the host manifest's `allowed_origins` (Chromium) or
// `allowed_extensions` (Firefox) can start it; a web page cannot.
//
// It does exactly what the Safari extension's handler does, through the same
// function (`WebInbox.reply`): checks the message (`WebSave`), puts it in the
// app group's inbox and waits a few seconds for the app's answer. It never
// opens the book, never fetches anything, never launches the app, and reads
// nothing but its standard input and the inbox's answer folder.
//
// It lives at Khayt.app/Contents/MacOS/khayt-browser-host, so `Bundle.main` is
// the app and its Info.plist names the group; it is signed into that group by
// `make-app.sh`. Khayt writes the host manifests pointing here from Settings ▸
// Preferences ▸ Browser extension, never on its own (`BrowserHosts`).

func parentPath() -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    guard n > 0 else { return "" }
    return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The inbox. A DEBUG build may be pointed at a throwaway folder for the
/// end-to-end test; a release build only ever uses the app group's.
func inbox() -> URL? {
    #if DEBUG
    if let dir = ProcessInfo.processInfo.environment["KHAYT_WEBINBOX_DIR"], dir.hasPrefix("/") {
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    #endif
    return WebInbox.directory()
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let browser = NativeMessaging.browser(arguments: Array(CommandLine.arguments.dropFirst()), parentPath: parentPath())
let dir = inbox()

// One message per `sendNativeMessage`; a `connectNative` port may send more,
// so read until the browser closes the pipe.
while true {
    let message: Data
    do {
        message = try NativeMessaging.readMessage { n in (try? input.read(upToCount: n)) ?? Data() }
    } catch .closed {
        break
    } catch {
        // A length that lies, or a message cut short: answered once, and the
        // stream is not read further — it can no longer be trusted.
        output.write(NativeMessaging.frame(WebInbox.Result(id: "", state: .invalid,
                                                           reason: WebSave.Refusal.tooLarge.rawValue).message))
        break
    }
    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "app.khayt.mac").isEmpty
    output.write(NativeMessaging.frame(WebInbox.reply(toMessageData: message, browser: browser, inbox: dir,
                                                      appRunning: running)))
}
exit(0)
