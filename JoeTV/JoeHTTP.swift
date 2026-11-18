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
/// CONVERGENCE (Team 6 census A21/D, 2026-11-15): every fetch
/// carries a bound on its TOTAL duration, not just the idle
/// gap between packets — URLSession.shared (whose resource
/// timeout is the platform default of days) bounded nothing
/// end-to-end, and a slow-drip peer could hold a "12 s" call
/// open indefinitely. The 2026-11-15 form enforced the bound
/// with one dedicated session per timeout value
/// (timeoutIntervalForResource equal to the call's timeout).
///
/// FIX4 (HTTP consolidation — owner-approved build item,
/// 2026-11-18): the per-timeout sessions are GONE. They each
/// kept their own connection pool, so the same provider host
/// was pooled once per timeout class (12/18/25/30…) and a
/// connection warmed by a 12 s search leg could not be reused
/// by the 25 s detail leg behind it — repeated fresh
/// handshakes across the fetch paths, on the owner's own
/// measurement the app's dominant start-latency cost. Every
/// data fetch now rides ONE shared session (below): a single
/// pool with keep-alive reuse across provider legs, TMDB,
/// subtitles, SourceHealth budgets, the debrid API and the
/// player artwork. The Team 6 total-duration bound survives
/// exactly, enforced in fetch() instead of by session
/// configuration: each fetch races its own deadline and the
/// loser is cancelled (see fetch). The configuration still
/// resolves to the shared URLCache, so poster caching is
/// unchanged. (Images keep their own profile in
/// JoeImagePipeline — see the FIX4 report's session
/// inventory for why.)
enum JoeHTTP {
    static let userAgent =
        "Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// The one shared data session (FIX4 consolidation):
    /// the house per-host cap of 6 (v2.0.8 Phase 7's
    /// deliberate choice, kept), waitsForConnectivity so a
    /// fetch fired during a tunnel/network flap waits for
    /// the route instead of failing instantly (always
    /// bounded by the call's own deadline in fetch), and
    /// session-level timeout envelopes that sit BEHIND the
    /// per-call bounds fetch enforces — the request (idle)
    /// ceiling matches the family's largest common class,
    /// the resource ceiling is the family's outer backstop.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Phase 0 (v2.0.8): the one fetch path — same requests,
    /// same throws as before, plus a per-task delegate that
    /// collects URLSessionTaskMetrics and logs the phases
    /// per host through PerfLog.
    ///
    /// FIX4: the call's timeout is applied to the request
    /// centrally (its idle bound — data(for:) callers did
    /// not all set it; the per-timeout session's config used
    /// to supply it silently), and the fetch races the
    /// shared-session task against the call's own deadline:
    /// the first finisher decides — the data, the fetch's
    /// own error, or the deadline's URLError.timedOut, the
    /// same error the old resource timeout produced. The
    /// loser is cancelled and DRAINED, so its error can
    /// never escape over the winner's result; caller
    /// cancellation cancels the group, and with it the
    /// fetch, exactly as the direct call behaved (the
    /// findAlternatives 12 s envelope depends on that).
    private static func fetch(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let collector = JoeMetricsCollector()
        do {
            let (data, response) = try await withThrowingTaskGroup(
                of: (Data, URLResponse).self
            ) { group in
                group.addTask {
                    try await sharedSession.data(for: request, delegate: collector)
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                // The drain: next() yields the remaining
                // child's value (loop), nil once no children
                // remain (stop), or throws its error, which
                // try? turns into the stop case. Both
                // optionals are unwrapped deliberately — a
                // single-level unwrap would spin forever on
                // the no-children nil.
                do {
                    guard let first = try await group.next() else {
                        throw URLError(.unknown)
                    }
                    group.cancelAll()
                    while let pending = try? await group.next(),
                          pending != nil {}
                    return first
                } catch {
                    group.cancelAll()
                    while let pending = try? await group.next(),
                          pending != nil {}
                    throw error
                }
            }
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
