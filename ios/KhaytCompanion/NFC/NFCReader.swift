import CoreNFC
import Foundation

/// NFC spool reader and writer. Requires `KhaytCompanion.entitlements` + paid Apple Developer account for hardware NFC.
final class NFCReader: NSObject, ObservableObject {
    @MainActor @Published var lastTag: NFCFilamentTag?
    @MainActor @Published var lastError: String?
    @MainActor @Published var isScanning = false
    @MainActor @Published var isWriting = false
    @MainActor @Published var writeSucceeded = false

    private enum Mode {
        case read
        case write(NFCNDEFMessage)
    }

    private var session: NFCTagReaderSession?
    private var mode: Mode = .read

    @MainActor
    var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    @MainActor
    func beginScan() {
        guard NFCTagReaderSession.readingAvailable else {
            lastError = L10n.tr("nfc.unavailable")
            return
        }
        lastTag = nil
        lastError = nil
        writeSucceeded = false
        isWriting = false
        mode = .read
        isScanning = true
        session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        session?.alertMessage = L10n.tr("nfc.read.prompt")
        session?.begin()
    }

    @MainActor
    func beginWrite(message: NFCNDEFMessage) {
        guard NFCTagReaderSession.readingAvailable else {
            lastError = L10n.tr("nfc.unavailable")
            return
        }
        lastError = nil
        writeSucceeded = false
        mode = .write(message)
        isWriting = true
        isScanning = false
        session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        session?.alertMessage = L10n.tr("nfc.write.prompt")
        session?.begin()
    }

    @MainActor
    func invalidate() {
        session?.invalidate()
        session = nil
        isScanning = false
        isWriting = false
    }

    @MainActor
    func clearLastTag() {
        lastTag = nil
        lastError = nil
    }

    @MainActor
    func clearWriteState() {
        lastError = nil
        writeSucceeded = false
        isWriting = false
    }

    @MainActor
    private func finishRead(session: NFCTagReaderSession, tag: NFCFilamentTag) {
        lastTag = tag
        lastError = nil
        isScanning = false
        session.alertMessage = L10n.tr("nfc.read.success")
        session.invalidate()
    }

    @MainActor
    private func finishWrite(session: NFCTagReaderSession) {
        writeSucceeded = true
        lastError = nil
        isWriting = false
        session.alertMessage = L10n.tr("nfc.write.success")
        session.invalidate()
    }
}

extension NFCReader: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            isScanning = false
            isWriting = false
            self.session = nil
            if let nfcError = error as? NFCReaderError,
               nfcError.code == .readerSessionInvalidationErrorUserCanceled {
                return
            }
            if (error as NSError).code != 200 {
                lastError = error.localizedDescription
            }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else {
            session.invalidate(errorMessage: L10n.tr("nfc.error.no_tag"))
            return
        }
        session.connect(to: tag) { [weak self] error in
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            guard let self else { return }
            switch self.mode {
            case .read:
                self.readPayload(from: tag, session: session)
            case .write(let message):
                self.writePayload(message, to: tag, session: session)
            }
        }
    }

    private func readPayload(from tag: NFCTag, session: NFCTagReaderSession) {
        let handle: (NFCNDEFMessage?, Error?) -> Void = { [weak self] message, error in
            self?.handleNDEF(message: message, error: error, session: session)
        }
        switch tag {
        case .miFare(let miFare):
            miFare.readNDEF(completionHandler: handle)
        case .iso7816(let iso):
            iso.readNDEF(completionHandler: handle)
        case .iso15693(let iso):
            iso.readNDEF(completionHandler: handle)
        case .feliCa(let feliCa):
            feliCa.readNDEF(completionHandler: handle)
        @unknown default:
            session.invalidate(errorMessage: L10n.tr("nfc.error.unsupported_tag"))
        }
    }

    private func writePayload(_ message: NFCNDEFMessage, to tag: NFCTag, session: NFCTagReaderSession) {
        let performWrite: (NFCNDEFTag) -> Void = { ndefTag in
            ndefTag.queryNDEFStatus { status, _, error in
                if let error {
                    session.invalidate(errorMessage: error.localizedDescription)
                    return
                }
                guard status == .readWrite else {
                    session.invalidate(errorMessage: L10n.tr("nfc.error.read_only"))
                    return
                }
                ndefTag.writeNDEF(message) { error in
                    if let error {
                        session.invalidate(errorMessage: error.localizedDescription)
                        return
                    }
                    Task { @MainActor in self.finishWrite(session: session) }
                }
            }
        }
        switch tag {
        case .miFare(let miFare):
            performWrite(miFare)
        case .iso7816(let iso):
            performWrite(iso)
        case .iso15693(let iso):
            performWrite(iso)
        case .feliCa(let feliCa):
            performWrite(feliCa)
        @unknown default:
            session.invalidate(errorMessage: L10n.tr("nfc.error.not_ndef"))
        }
    }

    private func handleNDEF(message: NFCNDEFMessage?, error: Error?, session: NFCTagReaderSession) {
        var allBytes: [UInt8] = []
        if let records = message?.records {
            for record in records {
                allBytes.append(contentsOf: record.payload)
                if record.typeNameFormat == .media,
                   let type = String(data: record.type, encoding: .utf8) {
                    let payload = [UInt8](record.payload)
                    if type == "application/json",
                       case .success(let tag) = NFCParser.parse(bytes: payload) {
                        Task { @MainActor in self.finishRead(session: session, tag: tag) }
                        return
                    }
                    if type == "application/opentag3d",
                       case .success(let tag) = NFCParser.parse(bytes: payload) {
                        Task { @MainActor in self.finishRead(session: session, tag: tag) }
                        return
                    }
                    if type == "application/vnd.openprinttag",
                       case .success(let tag) = NFCParser.parse(bytes: payload) {
                        Task { @MainActor in self.finishRead(session: session, tag: tag) }
                        return
                    }
                }
            }
        }
        if allBytes.isEmpty {
            session.invalidate(errorMessage: error?.localizedDescription ?? L10n.tr("nfc.error.read_failed"))
            return
        }
        switch NFCParser.parse(bytes: allBytes) {
        case .success(let tag):
            Task { @MainActor in self.finishRead(session: session, tag: tag) }
        case .failure(let err):
            session.invalidate(errorMessage: err.localizedDescription)
        }
    }
}
