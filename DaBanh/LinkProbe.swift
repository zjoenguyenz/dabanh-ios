import Foundation

/// One-link probe — the shared verdict engine behind the apps'
/// device-side link validation (the owner's approved method,
/// 2026-11-13: pull the list, check every link FROM THIS DEVICE,
/// and only then put matches on screen).
///
/// Extracted from PlaylistStore.swift, which keeps its own private
/// copy for the Đá Banh targets; this file is compiled ONLY into the
/// TV target (see project.yml), where TVStore uses it. The verdict
/// semantics are identical to PlaylistStore.LinkProbe.isValid:
///
/// - .httpDead — definitively unplayable: HTTP 404/410, or HTTP 200
///   whose body is not a stream (empty, or an .m3u8 whose first
///   bytes lack #EXTM3U). Hides in any case.
/// - .unreachable — the request itself failed (connect, timeout,
///   DNS). Not proof of death on its own: the caller applies the
///   tier rule and hides it only when the channel should be serving
///   right now (a room for a future match may simply not exist yet).
/// - .indeterminate — any other HTTP status. 403 may just be the
///   tunnel being off right now and 5xx is transient, so this never
///   hides a link.
/// - .alive — HTTP 200 with a plausible stream body.
enum LinkProbe {

    enum Verdict {
        case alive
        case httpDead
        case unreachable
        case indeterminate
    }

    /// Shared ephemeral session with the same timeouts PlaylistStore
    /// configures for its probe waves (8 s session request timeout;
    /// each request below also carries the same 6 s timeout).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    /// Probes ONE stream URL, sending exactly the headers the entry
    /// itself declares (referrer / userAgent): some CDNs refuse the
    /// stream without them, and an uninvited Referer is never
    /// invented (measurement on Android: it turns other hosts'
    /// segment fetches into 403).
    static func probe(url urlString: String, referrer: String, userAgent: String) async -> Verdict {
        guard let url = URL(string: urlString) else { return .httpDead }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            userAgent.isEmpty ? "Mozilla/5.0 (Linux; Android 14; TV)" : userAgent,
            forHTTPHeaderField: "User-Agent")
        if !referrer.isEmpty {
            request.setValue(referrer, forHTTPHeaderField: "Referer")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 || status == 410 { return .httpDead }
            guard status == 200 else { return .indeterminate }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 4096 { break }
            }
            if buffer.isEmpty { return .httpDead }
            if isFLV(urlString) { return .alive }
            let path = urlString.split(separator: "?").first.map(String.init) ?? urlString
            if path.lowercased().hasSuffix(".m3u8") {
                return String(decoding: buffer.prefix(1024), as: UTF8.self).contains("#EXTM3U")
                    ? .alive
                    : .httpDead
            }
            return .alive
        } catch {
            return .unreachable
        }
    }

    /// True for .flv stream URLs. AVPlayer cannot play FLV at all, so
    /// the stores hide such entries from display and skip them when
    /// probing (same rule as PlaylistStore.isFLV).
    static func isFLV(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".flv")
    }
}
