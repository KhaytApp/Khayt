import Foundation
import SwiftUI
import KhaytCore

/// The camera on a printer, on the Mac.
///
/// ── WHY THIS EXISTS AND DID NOT ──────────────────────────────────────────
///
/// Khayt has shown a printer's camera since 3.0. This app carried the settings
/// through untouched and never drew one, and `lib/machine-edit.js` said why:
/// the webcam "belongs with the polling that app does not do yet". That reason
/// expired — this app polls, watches, alerts, draws a band off live readings
/// and now records what a finished print used. The camera was the most visible
/// thing left.
///
/// ── A STILL, NOT A STREAM, AND THAT IS A CHOICE ──────────────────────────
///
/// An MJPEG stream is a multipart response that never ends. A browser consumes
/// one by putting it in an `<img>`; AppKit has no equivalent, so showing one
/// here means parsing multipart boundaries out of a `URLSession` byte stream by
/// hand and holding a connection open per visible machine. A shop floor with
/// five printers is five permanent connections for a picture that changes every few
/// seconds anyway.
///
/// So this refetches the SNAPSHOT on a timer. It is what
/// `snapshotUrlFor` is for — the module refuses to hand back a stream URL for
/// exactly this reason, because buffering a stream as a "snapshot" accumulates
/// memory until the request times out.
///
/// ── EVERY DECISION IS THE SHARED MODULE'S ────────────────────────────────
///
/// Where a camera might live, what the owner typed normalised against the
/// printer's host, whether a response is an image, and WHICH HOST may be
/// fetched from at all. None of it is re-derived here. The last one is a
/// security rule rather than a convenience: see `assertWebcamHost`.
@MainActor
@Observable
final class Camera {

    /// What the tile is showing.
    enum Frame: Equatable {
        case none
        case picture(Data)
        /// The camera answered and has no frame — warming up, or busy. NOT a
        /// fault, and drawn differently from one.
        case waiting
        case failed(String)
    }

    private(set) var frames: [String: Frame] = [:]
    private var task: Task<Void, Never>?

    /// How often a still is refetched. A print changes slowly; a camera tile is
    /// for "is it still going and does the plate look right", not for watching
    /// a nozzle move.
    static let every: Duration = .seconds(5)

    func start(shop: Shop) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sweep(shop: shop)
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sweep(shop: Shop) async {
        for machine in shop.machines {
            if Task.isCancelled { return }
            guard machine.hasCamera else { frames[machine.id] = .none; continue }
            frames[machine.id] = await Self.fetch(machine, shop: shop)
        }
    }

    /// One still, or why there is not one.
    static func fetch(_ machine: Machine, shop: Shop,
                      get: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Frame {
        guard let engine = shop.engine else { return .none }
        guard machine.hasCamera, let cam = machine.webcam else { return .none }

        // The printer's own record, as the shared rules want it: the host it
        // is pinned to, and the type that decides which credential header goes
        // with a snapshot. The key travels SEALED and is opened at the moment
        // it is sent, never held — the same rule the poller follows.
        guard let api = await shop.printerApiRow(machine) else { return .failed("no printer") }

        // ── AN RTSP CAMERA IS FETCHED A DIFFERENT WAY ────────────────────
        //
        // Not every camera serves a JPEG. The Buddy3D that sits beside a Prusa
        // CORE One has RTSP and nothing else — no HTTP server at all — so there
        // is no snapshot URL to ask for and the printer cannot help, because it
        // is a separate device that never sees the frames.
        //
        // The address lives in `streamUrl` with `streamType: "rtsp"` rather
        // than in `snapshotUrl`, because `snapshotUrlFor` in the shared module
        // says plainly that a snapshot URL is never a stream — buffering one as
        // a still is how you accumulate memory until the request times out.
        // This does not buffer it: `RtspSession` decodes a single keyframe and
        // hangs up.
        if cam.streamType == "rtsp", let feed = cam.streamUrl, !feed.isEmpty {
            do {
                // The same host rule as everything else. An address in the book
                // arrived by restore or by sync and was not necessarily chosen
                // by the person sitting here.
                try await engine.assertWebcamHost(feed, printerApi: api)
            } catch {
                return .failed("refused")
            }
            guard let session = try? RtspSession(url: feed) else { return .failed("bad address") }
            do { return .picture(try await session.still()) }
            catch Rtsp.Failure.refused(404) {
                // The camera is there and has not been told to publish locally.
                // A Buddy3D answers exactly this until "RTSP stream on local
                // network" is switched on in the Prusa app, and that is a thing
                // the shop can fix — so it is not "unreachable".
                return .waiting
            }
            catch { return .failed("unreachable") }
        }


        // No RTSP, so this is an ordinary HTTP still — and it needs an address.
        guard let still = cam.snapshotUrl, !still.isEmpty else { return .none }

        // ── THE PIN, ASKED EVERY TIME ────────────────────────────────────
        //
        // Not at setup, not once per session: before every request. A snapshot
        // URL is stored in the book, and a book arrives by restore and by cloud
        // sync — so the URL on the record was not necessarily chosen by the
        // person sitting in front of this Mac.
        do {
            try await engine.assertWebcamHost(still, printerApi: api)
        } catch {
            return .failed("refused")
        }

        guard let url = URL(string: still) else { return .failed("bad address") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "GET"
        // The credential the printer's own adapters send. It reaches the
        // printer and nowhere else — which is only true BECAUSE the host was
        // pinned above, and is why these two steps are never separated.
        if let headers = try? await engine.webcamAuthHeaders(printerApi: api) {
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        }

        do {
            // ── THE REDIRECT IS REFUSED BEFORE IT IS FOLLOWED ────────────
            //
            // `URLSession` follows redirects on its own, so a permitted address
            // answering 302 with a `Location:` anywhere at all was fetched WITH
            // THE PRINTER'S CREDENTIAL ATTACHED — the `X-Api-Key` for OctoPrint
            // and PrusaLink, the access code for Bambu. The host check happens
            // before the request and never saw the second hop.
            //
            // This used to be checked AFTER the response came back, and a
            // comment here said `URLSession` "does not offer the before". It
            // does: `willPerformHTTPRedirection` on a task delegate is asked
            // before the second request is made, and returning nil stops it.
            // Checking afterwards refuses the PICTURE, which was never the
            // asset at risk — by then the key has already been handed to
            // whoever answered.
            //
            // It matters more since a camera became allowed to be its own
            // device: the printer's credential now travels to a host that is
            // not the printer, and a redirect is the way back out of the
            // allow-list from there. Electron's proxy has always passed
            // `redirect: 'manual'` in all three of its fetches. This is that,
            // and it makes `checkSnapshotHeaders`' own `redirect_refused` rule
            // reachable for the first time on this app — it could not fire
            // while the 3xx was being consumed by `URLSession`.
            let (data, response) = try await (get ?? {
                try await URLSession.shared.data(for: $0, delegate: RefuseRedirects.shared)
            })(request)

            let http = response as? HTTPURLResponse
            let refusal = try? await engine.checkSnapshot(
                status: http?.statusCode ?? 0,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                contentLength: data.count)
            if let refusal {
                // A camera with nothing to show is not a camera that is broken.
                return refusal == "no_frame_yet" ? .waiting : .failed(refusal)
            }
            return .picture(data)
        } catch {
            return .failed("unreachable")
        }
    }
}

/// A machine's camera, as the shop floor draws it.
struct CameraTile: View {
    let frame: Camera.Frame
    let webcam: Machine.Webcam?
    var height: CGFloat = 120
    /// For the two states that say something. Optional so a preview can draw
    /// the tile without a book.
    var words: Words?

    var body: some View {
        ZStack {
            switch frame {
            case .picture(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        // The owner's own orientation. A camera zip-tied to a
                        // gantry is rarely the right way up, and a picture the
                        // shop has to tilt its head for is one it stops reading.
                        .rotationEffect(.degrees(Double(webcam?.rotate ?? 0)))
                        .scaleEffect(x: (webcam?.flipH ?? false) ? -1 : 1,
                                     y: (webcam?.flipV ?? false) ? -1 : 1)
                } else {
                    // Bytes that are not an image the system can decode. The
                    // module's content-type check already refused the obvious
                    // cases; this is the one it cannot see.
                    Placeholder(note: words?.callIt("mac.cam_unreachable"))
                }
            case .waiting:
                // Warming up, not broken — and it says which, in words. A
                // registered camera that has not captured a frame is the state
                // a shop hits the moment it plugs one in.
                Placeholder(note: words?.callIt("mac.cam_no_frame"))
            case .failed:
                Placeholder(note: words?.callIt("mac.cam_unreachable"))
            case .none:
                Placeholder(note: nil)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// A tile with no picture in it.
    ///
    /// NOT `Khayt.ground`, which is what the first version used and what the
    /// card behind it is already painted — so the tile had no edges and a
    /// camera warming up read as a gap in the layout rather than as a camera.
    /// A surface and a hairline give it a shape, and the words say which of the
    /// two nothings this is.
    private struct Placeholder: View {
        let note: String?
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator)
                VStack(spacing: 6) {
                    Drawn(mark: .machines, size: 26).foregroundStyle(.tertiary)
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
    }
}

/// Refuses every HTTP redirect, so a request cannot be bounced somewhere the
/// host check never saw.
///
/// `nil` from `willPerformHTTPRedirection` means "do not follow": the 3xx is
/// delivered as the response, which is what `checkSnapshotHeaders` already
/// knows to call `redirect_refused`. The alternative — re-checking the new
/// host here and following when it passes — was rejected: this delegate would
/// then hold the printer's credential and the allow-list rule, which are two
/// things that live in the engine, and the value of a camera that redirects is
/// not worth a second copy of that decision.
///
/// One shared instance. A `URLSessionTaskDelegate` is retained by the task for
/// its lifetime and this one holds nothing, so making a new one per frame would
/// allocate once a second per machine to no purpose.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefuseRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
