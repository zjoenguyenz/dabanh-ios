import Foundation
import Network

/// In-app loopback HLS proxy — the tvOS answer to the Android
/// player's PngPrefixDataSource. AVPlayer has no custom
/// data-source API, so streams whose segments are disguised or
/// header-gated are played through 127.0.0.1:
///
///   • VSMOV segments are PNG files in front of MPEG-TS
///     (0x47 sync at byte 499) — Media3 resyncs, AVPlayer won't.
///   • Tủ Phim Gold segments carry a ~637-byte PNG prefix in
///     front of MPEG-TS (same class).
///   • Film4K segments carry a 67-byte PNG prefix in front of
///     fMP4, subtitles included.
///   • CacheVideo answers 403 unless the playlist AND segment
///     requests carry its Referer/User-Agent.
///
/// The proxy fetches the playlist with the candidate's headers,
/// rewrites every media URI (variant playlists, segment lines,
/// EXT-X-MEDIA / EXT-X-KEY / EXT-X-MAP URI attributes) to
/// itself, then fetches each resource with the same headers and
/// strips the disguise prefix before AVPlayer sees a byte.
/// Clean resources pass through untouched (the strip only fires
/// on a PNG signature). Loopback HTTP is ATS-exempt, and nothing
/// here ever leaves the device.
final class JoeProxy {
    static let shared = JoeProxy()

    private struct Route {
        var url: String
        var headers: [String: String]
        var isPlaylist: Bool
    }

    private var listener: NWListener?
    private var port: UInt16 = 0
    private let readySem = DispatchSemaphore(value: 0)
    private var routes: [String: Route] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "joe.proxy", attributes: .concurrent)
    private let session = URLSession(configuration: .default)

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent. Called lazily by playlistURL(for:) and once
    /// from the app root so the port is warm before any play tap.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        guard let l = try? NWListener(using: .tcp, on: .any) else { return }
        listener = l
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = l.port { self.port = p.rawValue }
                self.readySem.signal()
            case .failed, .cancelled:
                self.lock.lock()
                if self.listener === l { self.listener = nil }
                self.lock.unlock()
                self.readySem.signal()
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.start(queue: queue)
    }

    // MARK: - Registration

    /// Register an upstream playlist and return the loopback URL
    /// AVPlayer should open, or nil when the proxy is not up
    /// (the caller then falls back to the direct URL).
    func playlistURL(for upstream: String, headers: [String: String]) -> URL? {
        start()
        if port == 0 {
            _ = readySem.wait(timeout: .now() + 3)
        }
        guard port != 0 else { return nil }
        let local = register(upstream, headers: headers, isPlaylist: true)
        return URL(string: local)
    }

    private func register(_ upstream: String, headers: [String: String],
                          isPlaylist: Bool) -> String {
        let token = UUID().uuidString
        lock.lock()
        routes[token] = Route(url: upstream, headers: headers, isPlaylist: isPlaylist)
        lock.unlock()
        return "http://127.0.0.1:\(port)/\(isPlaylist ? "p" : "s")/\(token)"
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty,
                  let head = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = head.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ").map(String.init)
            guard parts.count >= 2 else {
                self.respond(conn, status: 400, type: "text/plain", body: Data())
                return
            }
            let path = parts[1]
            let token = path.components(separatedBy: "/").last ?? ""
            self.lock.lock()
            let route = self.routes[token]
            self.lock.unlock()
            guard let route else {
                self.respond(conn, status: 404, type: "text/plain", body: Data())
                return
            }
            self.serve(conn, route: route)
        }
    }

    private func serve(_ conn: NWConnection, route: Route) {
        guard let url = URL(string: route.url) else {
            respond(conn, status: 400, type: "text/plain", body: Data())
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (k, v) in route.headers { request.setValue(v, forHTTPHeaderField: k) }
        if route.headers["User-Agent"] == nil {
            request.setValue(JoeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let sem = DispatchSemaphore(value: 0)
        var payload = Data()
        var contentType = "application/octet-stream"
        var ok = false
        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            defer { sem.signal() }
            guard let self, let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            if route.isPlaylist {
                guard let text = String(data: data, encoding: .utf8) else { return }
                let base = http.url ?? url
                let rewritten = self.rewritePlaylist(text, base: base,
                                                     headers: route.headers)
                payload = Data(rewritten.utf8)
                contentType = "application/vnd.apple.mpegurl"
            } else {
                payload = Self.stripDisguise(data)
                contentType = http.mimeType
                    ?? Self.guessType(route.url)
            }
            ok = true
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 35)
        if ok {
            respond(conn, status: 200, type: contentType, body: payload)
        } else {
            respond(conn, status: 502, type: "text/plain", body: Data())
        }
    }

    private func respond(_ conn: NWConnection, status: Int, type: String, body: Data) {
        let reason = status == 200 ? "OK" : "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Playlist rewriting

    private func rewritePlaylist(_ body: String, base: URL,
                                 headers: [String: String]) -> String {
        var out: [String] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                out.append(rewriteTagLine(line, base: base, headers: headers))
            } else if let abs = URL(string: line, relativeTo: base)?.absoluteURL {
                let isPl = abs.absoluteString.contains(".m3u8")
                out.append(register(abs.absoluteString, headers: headers,
                                    isPlaylist: isPl))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Rewrite the URI="…" attribute of a tag line (EXT-X-MEDIA,
    /// EXT-X-KEY, EXT-X-MAP, EXT-X-I-FRAME-STREAM-INF…).
    private func rewriteTagLine(_ line: String, base: URL,
                                headers: [String: String]) -> String {
        guard let open = line.range(of: "URI=\"") else { return line }
        let rest = line[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return line }
        let uri = String(rest[..<close])
        guard let abs = URL(string: uri, relativeTo: base)?.absoluteURL else {
            return line
        }
        let isPl = abs.absoluteString.contains(".m3u8")
        let local = register(abs.absoluteString, headers: headers, isPlaylist: isPl)
        return line.replacingCharacters(in: open.upperBound..<close, with: local)
    }

    // MARK: - Segment cleaning

    /// Strip a disguise prefix from a media resource. Only a PNG
    /// signature triggers surgery; the payload start is found by
    /// its own signature — MPEG-TS (0x47 sync repeating every
    /// 188 bytes), an fMP4 "ftyp" box, or a WebVTT header. When
    /// no payload signature is found the bytes pass through
    /// untouched: the cleaner never destroys data it cannot
    /// identify.
    static func stripDisguise(_ data: Data) -> Data {
        let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > pngSig.count,
              data.prefix(pngSig.count).elementsEqual(pngSig) else { return data }
        let bytes = [UInt8](data)
        let limit = min(bytes.count, 16384)
        // MPEG-TS: sync byte 0x47 repeating at +188 and +376.
        if bytes.count > 376 {
            var i = 0
            while i + 376 < limit {
                if bytes[i] == 0x47 && bytes[i + 188] == 0x47
                    && bytes[i + 376] == 0x47 {
                    return Data(bytes[i...])
                }
                i += 1
            }
        }
        // fMP4: the first box is <size>"ftyp" — payload starts
        // 4 bytes before the "ftyp" signature.
        if let idx = find([0x66, 0x74, 0x79, 0x70], in: bytes, limit: limit),
           idx >= 4 {
            return Data(bytes[(idx - 4)...])
        }
        // WebVTT subtitles: payload starts at the "WEBVTT" magic.
        if let idx = find([0x57, 0x45, 0x42, 0x56, 0x54, 0x54],
                          in: bytes, limit: limit) {
            return Data(bytes[idx...])
        }
        return data
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8],
                             limit: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        let last = min(limit, bytes.count) - needle.count
        guard last >= 0 else { return nil }
        for i in 0...last {
            if bytes[i] == needle[0]
                && Array(bytes[i..<(i + needle.count)]) == needle {
                return i
            }
        }
        return nil
    }

    private static func guessType(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "application/vnd.apple.mpegurl" }
        if lower.contains(".ts") { return "video/mp2t" }
        if lower.contains(".m4s") { return "video/iso.segment" }
        if lower.contains(".mp4") { return "video/mp4" }
        if lower.contains(".vtt") { return "text/vtt" }
        if lower.contains(".aac") { return "audio/aac" }
        return "application/octet-stream"
    }
}
