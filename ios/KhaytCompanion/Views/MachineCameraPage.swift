import SwiftUI
import UIKit

/// A printer's camera: a still frame, fetched from the printer on the shop's
/// Wi-Fi every few seconds while the page is open.
struct MachineCameraPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    let name: String
    let source: KhaytAPIClient.CameraSource

    @State private var frame: UIImage?
    @State private var problem: String?
    @State private var at: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(KhaytDesign.sunk)
                    if let frame {
                        Image(uiImage: frame)
                            .resizable().scaledToFit()
                            .rotationEffect(.degrees(Double(source.rotate)))
                            .scaleEffect(x: source.flipH ? -1 : 1, y: source.flipV ? -1 : 1)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else if problem == nil {
                        ProgressView()
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                if let problem { V2Note(text: problem, tone: KhaytDesign.attention) }
                if let at {
                    Text(L10n.format("camera.at", at.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale))))
                        .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                }
            }
            .padding(16)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // While the page is open; SwiftUI cancels the task when it closes.
            while !Task.isCancelled {
                await fetch()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func fetch() async {
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        do {
            let (bytes, response) = try await NoRedirects.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { problem = L10n.tr("camera.offline"); return }
            let verdict = await api.snapshotHeadersOK(status: http.statusCode,
                                                      contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                                      length: http.expectedContentLength)
            guard verdict.ok else {
                bytes.task.cancel()
                problem = L10n.tr(verdict.reason == "no_frame_yet" ? "camera.no_frame" : "camera.offline")
                return
            }
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 8 * 1024 * 1024 { bytes.task.cancel(); problem = L10n.tr("camera.offline"); return }
            }
            guard let image = UIImage(data: data) else { problem = L10n.tr("camera.offline"); return }
            frame = image
            problem = nil
            at = Date()
        } catch {
            if !Task.isCancelled { problem = L10n.tr("camera.offline") }
        }
    }
}

/// A session that follows no redirect — the rule refuses one (`redirect_refused`),
/// because a camera on the LAN must not be able to send the request elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
