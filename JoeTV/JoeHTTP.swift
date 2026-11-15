import Foundation

/// Minimal HTTP helper for the provider clients — the Swift twin of
/// the Android app's TvData.httpGet: one desktop-class User-Agent,
/// generous timeouts, body returned as parsed JSON or raw text.
/// All provider traffic rides the device's default route (on Apple
/// TV that is whatever the owner's Sing-box profile decides); there
/// is no in-app tunnel on tvOS.
///
/// CONVERGENCE (Team 6 census A21/D, 2026-11-15): every fetch now
/// rides a dedicated session whose configuration carries
/// timeoutIntervalForResource EQUAL to the call's timeout, so a
/// call's TOTAL duration is bounded — not just the idle gap
/// between packets. URLSession.shared (whose resource timeout is
/// the platform default of days) bounded nothing end-to-end: a
/// slow-drip peer could hold a "12 s" call open indefinitely.
/// Sessions are cached per timeout value; the configuration
/// still resolves to the shared URLCache, so poster caching is
/// unchanged.
enum JoeHTTP {
    static let userAgent =
        "Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    private static let sessionLock = NSLock()
    private static var sessions: [Int: URLSession] = [:]

    /// The configured session for a call class: idle timeout AND
    /// total (resource) timeout both equal the call's timeout.
    static func session(timeout: TimeInterval) -> URLSession {
        let key = Int(timeout.rounded())
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let s = sessions[key] { return s }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let s = URLSession(configuration: config)
        sessions[key] = s
        return s
    }

    /// Raw fetch for call sites that must do their own status /
    /// body handling (TorrentClient's debrid API): same bounded
    /// sessions as getData, no status policy applied here.
    static func data(for request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        try await session(timeout: timeout).data(for: request)
    }

    static func getData(_ urlString: String, timeout: TimeInterval = 25) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/html, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session(timeout: timeout).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func getText(_ urlString: String, timeout: TimeInterval = 25) async throws -> String {
        let data = try await getData(urlString, timeout: timeout)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    static func getJSON(_ urlString: String, timeout: TimeInterval = 25) async throws -> [String: Any] {
        let data = try await getData(urlString, timeout: timeout)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }
        return root
    }

    /// Strict query-value encoding (unreserved characters only), so
    /// Vietnamese search terms survive exactly like URLEncoder's
    /// UTF-8 output did on Android.
    static func qenc(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
