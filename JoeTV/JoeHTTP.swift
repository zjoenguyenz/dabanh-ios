import Foundation
import os

/// v2.0.8 Phase 0 — performance marks. Every user-visible wait
/// the fix plan attacks (detail open, Play tap) leaves a named
/// mark here, and every JoeHTTP fetch logs its measured phases
/// per host, so the plan's before/after comparisons read from
/// the unified log (subsystem com.luun.nguyen.joetv, category
/// "perf") instead of from impressions. HOSTS ONLY are logged —
/// never paths or queries: Torrentio URLs carry debrid tokens
/// in the path, and no token may ever reach a log.
enum PerfLog {
    static let logger = Logger(subsystem: "com.luun.nguyen.joetv", category: "perf")

    /// A named point-in-time mark on a user-visible path
    /// (detail.*, play.* — see PHASE0-BASELINE.md).
    static func mark(_ label: String, _ detail: String = "") {
        logger.log("JOEPERF \(label, privacy: .public) \(detail, privacy: .public)")
    }

    /// One HTTP call's URLSessionTaskMetrics phases, in ms
    /// (-1 = phase absent; absent DNS/connect phases on a call
    /// are the signature of a reused connection — T2 §1.2).
    static func http(host: String, status: Int, bytes: Int,
                     metrics: URLSessionTaskMetrics?) {
        guard let tx = metrics?.transactionMetrics.last else {
            logger.log("JOEPERF http host=\(host, privacy: .public) status=\(status) bytes=\(bytes) metrics=none")
            return
        }
        func ms(_ a: Date?, _ b: Date?) -> Int {
            guard let a, let b else { return -1 }
            return Int(b.timeIntervalSince(a) * 1000)
        }
        let reused = tx.domainLookupStartDate == nil && tx.connectStartDate == nil
        logger.log("JOEPERF http host=\(host, privacy: .public) status=\(status) bytes=\(bytes) dns=\(ms(tx.domainLookupStartDate, tx.domainLookupEndDate)) connect=\(ms(tx.connectStartDate, tx.connectEndDate)) tls=\(ms(tx.secureConnectionStartDate, tx.secureConnectionEndDate)) ttfb=\(ms(tx.requestStartDate, tx.responseStartDate)) download=\(ms(tx.responseStartDate, tx.responseEndDate)) reused=\(reused)")
    }
}

/// Collects one task's metrics for PerfLog (Phase 0). A fresh
/// instance per call; URLSession retains it until the task ends.
private final class JoeMetricsCollector: NSObject, URLSessionTaskDelegate {
    var metrics: URLSessionTaskMetrics?
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }
}

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
        // v2.0.8 Phase 7: the per-host connection cap is set
        // DELIBERATELY (T3 connection discipline) — 6 is the
        // platform default, now an explicit choice for this
        // catalogue+resolver session family instead of an
        // inherited accident. (Images run their own profile in
        // JoeImagePipeline.)
        config.httpMaximumConnectionsPerHost = 6
        let s = URLSession(configuration: config)
        sessions[key] = s
        return s
    }

    /// Phase 0 (v2.0.8): the one fetch path — same sessions,
    /// same requests, same throws as before, plus a per-task
    /// delegate that collects URLSessionTaskMetrics and logs
    /// the phases per host through PerfLog.
    private static func fetch(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let collector = JoeMetricsCollector()
        do {
            let (data, response) = try await session(timeout: timeout).data(for: request, delegate: collector)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            PerfLog.http(host: request.url?.host ?? "?", status: status,
                         bytes: data.count, metrics: collector.metrics)
            return (data, response)
        } catch {
            PerfLog.http(host: request.url?.host ?? "?", status: -1,
                         bytes: 0, metrics: collector.metrics)
            throw error
        }
    }

    /// Raw fetch for call sites that must do their own status /
    /// body handling (TorrentClient's debrid API): same bounded
    /// sessions as getData, no status policy applied here.
    static func data(for request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        try await fetch(request, timeout: timeout)
    }

    static func getData(_ urlString: String, timeout: TimeInterval = 25) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/html, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request, timeout: timeout)
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
