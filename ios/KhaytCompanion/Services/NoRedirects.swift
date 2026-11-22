import Foundation

/// A session delegate that refuses every redirect.
///
/// Requests to the shop's Mac carry the PIN in `x-khayt-pin`, and URLSession
/// copies a request's headers onto the request it follows a redirect with —
/// to whatever host the `Location` names. The Mac never redirects, so a 30x
/// on the shop's address is something else answering there, and following
/// it would hand that host the PIN. The Mac's own `NoRedirects` does the same.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
