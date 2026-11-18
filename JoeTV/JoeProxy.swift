import Foundation
import Network
import CryptoKit

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
/// Playlists are fetched whole (they must be rewritten);
/// segments STREAM — the prefix is stripped on the fly and
/// bytes flow to AVPlayer as they arrive (latency round:
/// store-and-forwarding an 11–66 MB Film4K segment before
/// byte one was the largest tvOS start cost in the audit).
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
    private var routes: [String: Route] = [:]
    /// Route-table bound (C-16): pre-v1.9 routes were never
    /// evicted — an unbounded slow leak over a long session.
    /// Oldest registrations are evicted past the cap.
    private static let maxRoutes = 512
    private var routeOrder: [String] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "joe.proxy", attributes: .concurrent)
    private let session = URLSession(configuration: .default)
    /// Streaming session for segment routes (latency round):
    /// a delegate session on its own serial queue, so segment
    /// bytes can be forwarded as they arrive instead of
    /// store-and-forwarded whole (see serve()). The session
    /// retains its delegate; the delegate's proxy reference
    /// is weak, and the proxy is a process-lifetime singleton,
    /// so the session is deliberately never invalidated.
    private let streamDelegate = StreamDelegate()
    private let streamQueue: OperationQueue
    private let streamSession: URLSession

    private init() {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "joe.proxy.stream"
        streamQueue = q
        streamSession = URLSession(configuration: .default,
                                   delegate: streamDelegate,
                                   delegateQueue: q)
        streamDelegate.proxy = self
    }

    // MARK: - Lifecycle

    /// Idempotent. Called lazily by playlistURL(for:) and once
    /// from the app root so the port is warm before any play tap.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        // Conformance (Team 4): LOOPBACK ONLY. The pre-v1.9
        // listener accepted connections on every interface — an
        // unauthenticated relay reachable by the whole LAN. This
        // proxy exists solely for this device's own AVPlayer.
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: .any) else { return }
        listener = l
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                if let p = l.port { self.port = p.rawValue }
                self.lock.unlock()
            case .failed, .cancelled:
                self.lock.lock()
                if self.listener === l { self.listener = nil }
                self.lock.unlock()
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
    ///
    /// This function NEVER waits (hard gate G-EXIT-4): it is
    /// called from play-tap handlers that can run on the main
    /// thread, and the pre-v1.9 version blocked on a semaphore
    /// for up to 3 s waiting for the listener — on the owner's
    /// TV that class of main-thread block froze the whole
    /// device (his report, 2026-11-15). The app root warms
    /// start() at launch, so the port is normally ready; when
    /// it is not, nil + the direct-URL fallback is always the
    /// right trade.
    func playlistURL(for upstream: String, headers: [String: String]) -> URL? {
        start()
        lock.lock()
        let p = port
        lock.unlock()
        guard p != 0 else { return nil }
        let local = register(upstream, headers: headers, isPlaylist: true)
        return URL(string: local)
    }

    private func register(_ upstream: String, headers: [String: String],
                          isPlaylist: Bool) -> String {
        // v2.0.27 (idea 23): the token is a DETERMINISTIC hash of
        // (upstream, headers, kind) instead of a fresh UUID, so
        // the dwell-warmed proxy URL for a VS/TP title is the
        // SAME string the play tap mints later — StreamWarmer's
        // take(url:) compares absolute strings, and a random
        // token made every dwell warm of a proxy entry a
        // guaranteed miss. Re-registering the same upstream
        // refreshes the identical Route and moves the token to
        // the LRU tail instead of appending a duplicate.
        let token = Self.stableToken(upstream: upstream,
                                     headers: headers,
                                     isPlaylist: isPlaylist)
        lock.lock()
        routes[token] = Route(url: upstream, headers: headers, isPlaylist: isPlaylist)
        routeOrder.removeAll { $0 == token }
        routeOrder.append(token)
        while routeOrder.count > Self.maxRoutes {
            routes[routeOrder.removeFirst()] = nil
        }
        let p = port
        lock.unlock()
        return "http://127.0.0.1:\(p)/\(isPlaylist ? "p" : "s")/\(token)"
    }

    private static func stableToken(upstream: String,
                                    headers: [String: String],
                                    isPlaylist: Bool) -> String {
        var material = upstream + "\n" + (isPlaylist ? "p" : "s")
        for key in headers.keys.sorted() {
            material += "\n" + key + "=" + (headers[key] ?? "")
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
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
        // Playlists are small and must be rewritten whole
        // before AVPlayer sees them — they keep the bounded
        // store-and-forward path. SEGMENTS stream (below):
        // Film4K's are 11–66 MB each, and store-and-forward
        // made AVPlayer wait for a whole segment before byte
        // one (audit §1.3: tvOS ≈11.5 s median start vs
        // ≈5.1 s direct — the single largest tvOS start cost).
        if route.isPlaylist {
            servePlaylist(conn, route: route, url: url)
        } else {
            startStream(conn, route: route, url: url)
        }
    }

    private func servePlaylist(_ conn: NWConnection, route: Route, url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (k, v) in route.headers { request.setValue(v, forHTTPHeaderField: k) }
        if route.headers["User-Agent"] == nil {
            request.setValue(JoeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let startedAt = Date()
        let sem = DispatchSemaphore(value: 0)
        var payload = Data()
        var ok = false
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            defer { sem.signal() }
            guard let self, let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                self?.recordProxySample(
                    url: route.url, stage: .playlist,
                    seconds: Date().timeIntervalSince(startedAt),
                    outcome: (error as? URLError)?.code == .timedOut
                        ? .timeout : .instantFail)
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let base = http.url ?? url
            let rewritten = self.rewritePlaylist(text, base: base,
                                                 headers: route.headers)
            payload = Data(rewritten.utf8)
            ok = true
            self.recordProxySample(
                url: route.url, stage: .playlist,
                seconds: Date().timeIntervalSince(startedAt),
                outcome: .success)
        }
        task.resume()
        // This wait is confined to the proxy's own concurrent
        // queue (connections are started and handled there) —
        // it can never run on the main thread or the MainActor,
        // which is the path G-EXIT-4 governs. It exists only to
        // give the synchronous respond-after-fetch shape a bound.
        // Serve-wait 35 s → 90 s (LATENCY-AUDIT §6 stopgap —
        // the real fix for segments is the streaming path;
        // this bound now only guards playlists).
        _ = sem.wait(timeout: .now() + 90)
        if ok {
            respond(conn, status: 200, type: "application/vnd.apple.mpegurl",
                    body: payload)
        } else {
            respond(conn, status: 502, type: "text/plain", body: Data())
        }
    }

    // MARK: - Segment streaming

    /// State of one in-flight streamed segment fetch. All
    /// mutation happens on the stream session's serial
    /// delegate queue (registration included — see
    /// startStream), so no lock is needed.
    private final class StreamState {
        let conn: NWConnection
        let url: URL
        let startedAt = Date()
        var buffer = Data()
        var offset: Int?
        var headSent = false
        var closed = false
        init(conn: NWConnection, url: URL) {
            self.conn = conn
            self.url = url
        }
    }

    /// The streaming session's delegate: a pure forwarder —
    /// state lives in StreamState, logic in the proxy's
    /// stream* methods.
    private final class StreamDelegate: NSObject, URLSessionDataDelegate {
        weak var proxy: JoeProxy?
        var states: [Int: StreamState] = [:]

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let st = states[dataTask.taskIdentifier] else {
                completionHandler(.cancel)
                return
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                proxy?.streamRefused(st)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            guard let st = states[dataTask.taskIdentifier] else { return }
            proxy?.streamAppend(st, data: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let st = states.removeValue(forKey: task.taskIdentifier)
            else { return }
            proxy?.streamComplete(st, error: error)
        }
    }

    private func startStream(_ conn: NWConnection, route: Route, url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (k, v) in route.headers { request.setValue(v, forHTTPHeaderField: k) }
        if route.headers["User-Agent"] == nil {
            request.setValue(JoeHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let st = StreamState(conn: conn, url: url)
        let task = streamSession.dataTask(with: request)
        // Registration is enqueued on the same serial queue
        // the delegate callbacks arrive on, BEFORE resume() —
        // so no callback for this task can be processed ahead
        // of its state existing.
        streamQueue.addOperation { [weak self] in
            self?.streamDelegate.states[task.taskIdentifier] = st
        }
        task.resume()
    }

    /// Upstream refused (non-2xx) before a single byte was
    /// forwarded: answer 502 exactly like the old path did.
    private func streamRefused(_ st: StreamState) {
        guard !st.closed else { return }
        st.closed = true
        recordProxySample(url: st.url.absoluteString, stage: .segment,
                          seconds: Date().timeIntervalSince(st.startedAt),
                          outcome: .instantFail)
        respond(st.conn, status: 502, type: "text/plain", body: Data())
    }

    private func streamAppend(_ st: StreamState, data: Data) {
        guard !st.closed else { return }
        if st.headSent {
            st.conn.send(content: data, completion: .contentProcessed { _ in })
            return
        }
        st.buffer.append(data)
        streamDecide(st)
    }

    /// Once the payload offset is provable (streamOffset) AND
    /// enough stripped bytes are in hand to type the payload,
    /// send the head and everything buffered past the prefix;
    /// later chunks flow straight through. The response is
    /// close-delimited (no Content-Length — the length is
    /// unknowable while streaming; Connection: close + the
    /// final isComplete send frame the body).
    private func streamDecide(_ st: StreamState) {
        if st.offset == nil {
            guard let off = Self.streamOffset(forHead: st.buffer) else { return }
            st.offset = off
        }
        guard let off = st.offset else { return }
        // detectContentType reads up to byte 188 of the
        // payload (its TS sync check) — hold the head until
        // that much stripped data exists. A body that ends
        // sooner is finished whole by streamComplete instead.
        guard st.buffer.count >= off + 189 else { return }
        let head = Data(st.buffer.dropFirst(off).prefix(512))
        // Conformance (Team 4), unchanged: the Content-Type
        // comes from the DETECTED payload, never the upstream
        // response — disguised segments arrive typed
        // image/png, and serving that to AVPlayer is a
        // guaranteed failure.
        let type = Self.detectContentType(head, url: st.url.absoluteString)
        var responseHead = "HTTP/1.1 200 OK\r\n"
        responseHead += "Content-Type: \(type)\r\n"
        responseHead += "Connection: close\r\n\r\n"
        st.conn.send(content: Data(responseHead.utf8),
                     completion: .contentProcessed { _ in })
        let body = Data(st.buffer.dropFirst(off))
        st.buffer = Data()
        st.headSent = true
        if !body.isEmpty {
            st.conn.send(content: body, completion: .contentProcessed { _ in })
        }
        // The segment stage's health sample is its time to
        // first byte — the quantity the audit's envelopes are
        // built from — taken at the moment AVPlayer gets it.
        recordProxySample(url: st.url.absoluteString, stage: .segment,
                          seconds: Date().timeIntervalSince(st.startedAt),
                          outcome: .success)
    }

    private func streamComplete(_ st: StreamState, error: Error?) {
        guard !st.closed else { return }
        st.closed = true
        if let error {
            if st.headSent {
                // Bytes already flowed and the first-byte
                // sample stands (the host DID answer). Close;
                // AVPlayer treats the truncated segment as a
                // failure and the director's ladder owns what
                // happens next.
                st.conn.cancel()
            } else {
                recordProxySample(
                    url: st.url.absoluteString, stage: .segment,
                    seconds: Date().timeIntervalSince(st.startedAt),
                    outcome: (error as? URLError)?.code == .timedOut
                        ? .timeout : .instantFail)
                respond(st.conn, status: 502, type: "text/plain", body: Data())
            }
            return
        }
        if st.headSent {
            st.conn.send(content: nil, contentContext: .defaultMessage,
                         isComplete: true,
                         completion: .contentProcessed { _ in st.conn.cancel() })
            return
        }
        // The whole body arrived before the streaming
        // decision could fire (a small resource: a subtitle,
        // a key, a tiny segment) — answer through the classic
        // whole-body path, byte-identical to the
        // pre-streaming proxy.
        let payload = Self.stripDisguise(st.buffer)
        let type = Self.detectContentType(payload, url: st.url.absoluteString)
        recordProxySample(url: st.url.absoluteString, stage: .segment,
                          seconds: Date().timeIntervalSince(st.startedAt),
                          outcome: .success)
        respond(st.conn, status: 200, type: type, body: payload)
    }

    /// The streaming twin of stripDisguise: given the bytes
    /// buffered so far, return the payload offset when it is
    /// PROVABLY the offset stripDisguise would choose for the
    /// finished body — or nil when more bytes must arrive
    /// before that is decidable.
    ///
    /// Equivalence: stripDisguise (1) passes non-PNG bodies
    /// through untouched — decidable from the first 8 bytes;
    /// (2) for PNG bodies scans the first 16 KB for an
    /// MPEG-TS sync triple and returns the FIRST — a triple
    /// at offset i is confirmable the moment bytes i…i+376
    /// are in hand, and every earlier offset has by then been
    /// scanned and rejected, so the first confirmable triple
    /// is final; (3) only when NO triple exists in the window
    /// does it fall to the ftyp / WebVTT searches — those
    /// verdicts are deferred here until the whole window has
    /// arrived, exactly so the precedence can never flip.
    private static func streamOffset(forHead buffer: Data) -> Int? {
        let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard buffer.count >= pngSig.count else { return nil }
        let bytes = [UInt8](buffer)
        guard bytes.prefix(pngSig.count).elementsEqual(pngSig) else { return 0 }
        let limit = min(bytes.count, 16384)
        if bytes.count > 376 {
            var i = 0
            while i + 376 < limit {
                if bytes[i] == 0x47 && bytes[i + 188] == 0x47
                    && bytes[i + 376] == 0x47 {
                    return i
                }
                i += 1
            }
        }
        guard bytes.count >= 16384 else { return nil }
        if let idx = find([0x66, 0x74, 0x79, 0x70], in: bytes, limit: limit),
           idx >= 4 {
            return idx - 4
        }
        if let idx = find([0x57, 0x45, 0x42, 0x56, 0x54, 0x54],
                          in: bytes, limit: limit) {
            return idx
        }
        return 0
    }

    // MARK: - SourceHealth attribution

    /// The provider family a proxied URL belongs to, read off
    /// its host — the route table carries no provider field.
    /// Only hosts that really flow through this proxy are
    /// attributed (audit §5.1); anything else (an RD CDN
    /// host, say) is not recorded. KK never appears here:
    /// its candidates play direct, unproxied.
    private static func healthProvider(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased()
        else { return nil }
        if host == "streamvsmov.com" || host.hasSuffix(".streamvsmov.com") {
            return Providers.VS
        }
        if host.hasSuffix("blogcdn.site") || host.hasSuffix("cachevideo.com") {
            return Providers.TP
        }
        if host.hasSuffix("tiktokcdn.com") || host.hasSuffix("film4k.net") {
            return Providers.F4K
        }
        return nil
    }

    fileprivate func recordProxySample(url: String, stage: SourceHealth.Stage,
                                       seconds: Double,
                                       outcome: SourceHealth.Outcome) {
        guard let provider = Self.healthProvider(for: url) else { return }
        SourceHealth.record(provider: provider, stage: stage, url: url,
                            seconds: seconds, outcome: outcome)
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

    /// Content-Type from the payload's OWN signature (Team 4
    /// conformance). Runs on the STRIPPED bytes, so it sees the
    /// real payload start: MPEG-TS sync, an fMP4 "ftyp" box, a
    /// WebVTT header, or a playlist. Falls back to the URL
    /// extension guess — never to the upstream response's type.
    static func detectContentType(_ data: Data, url: String) -> String {
        if data.starts(with: [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]) {
            return "application/vnd.apple.mpegurl"  // "#EXTM3U"
        }
        if data.count > 188, data[0] == 0x47, data[188] == 0x47 {
            return "video/mp2t"
        }
        if data.count > 8,
           data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 {
            return "video/mp4"  // "ftyp" at box offset 4
        }
        if data.starts(with: [0x57, 0x45, 0x42, 0x56, 0x54, 0x54]) {
            return "text/vtt"  // "WEBVTT"
        }
        return guessType(url)
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
