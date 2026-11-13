import Foundation

/// Playlist loading, mirroring the Android app's behaviour:
/// - On launch: show the disk cache immediately (if present and > 100
///   bytes), then fetch the remote playlist.
/// - A successful fetch replaces the list AND rewrites the cache.
/// - A failed fetch keeps the current list; with nothing loaded yet it
///   surfaces a retry message instead.
/// - Auto-refresh: every 15 minutes — a foreground timer plus a
///   refresh-on-foreground when the data is older than 15 minutes
///   (the Android app does the staleness check in onResume).
/// - First load only: open on the Hot tab when it has a live match,
///   else the highest-priority league with a live match right now;
///   fall back to Ngoại Hạng Anh (Android setData).
///
/// Two sources are fetched on every refresh, GitHub first (owner's
/// rule, 2026-11-13 — all of his apps read from his own GitHub):
/// - Primary: the mirror in the owner's GitHub repo, whose workflow
///   auto-scans and republishes the whole list (origin leagues +
///   scraped extras + the 🔥 Hot group) every 30 minutes and keeps
///   the last good file if the origin dies.
/// - Fallback: the origin site (thtt.pages.dev), used only when
///   GitHub cannot be reached at all. It has no 🔥 Hot group, so the
///   Hot tab then keeps whatever it already had.
@MainActor
final class PlaylistStore: ObservableObject {

    /// Origin site — since 2026-11-13 only the fallback, used when
    /// the GitHub mirror cannot be reached at all.
    static let playlistURL = URL(string: "https://thtt.pages.dev/tttt.m3u")!
    /// The PRIMARY source (owner's own GitHub repo): a scheduled
    /// workflow auto-scans and republishes the full playlist there
    /// every 30 minutes, and a failed scan never overwrites the last
    /// good file — so this link is both fresher and harder to kill
    /// than the origin.
    static let backupPlaylistURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tttt.m3u")!
    /// group-title the mirror's scraper gives its hot rail.
    static let hotGroupName = "🔥 Hot"
    /// selectedLeague value meaning "the Hot tab" (league rawValues
    /// are 1, 2, 3, 4 and 9, so 0 is free).
    static let hotTabValue = 0
    /// selectedLeague value meaning "the Trực tiếp (live) tab" — every
    /// match in its live window right now, across all leagues and the
    /// Hot group. Added at the owner's request (2026-11-13): browsing
    /// league by league gave him no way to see at a glance what is
    /// live. The iOS UI does not render this tab yet; the tvOS UI does.
    static let liveTabValue = -1
    private static let autoRefreshInterval: TimeInterval = 15 * 60

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var hotChannels: [Channel] = []

    /// Unfiltered lists as parsed. The published lists above are these
    /// minus proven-dead links and minus .flv entries (AVPlayer cannot
    /// play FLV at all, so on Apple platforms they are dead weight;
    /// the Android app keeps them — ExoPlayer plays FLV fine).
    private var rawChannels: [Channel] = []
    private var rawHotChannels: [Channel] = []
    /// URLs proven unplayable FROM THIS DEVICE (see validateLinks).
    /// Persisted so a cold start opens already clean, and re-probed
    /// after every refresh so a revived link returns on its own.
    private var invalidURLs: Set<String> = []
    private var validating = false
    /// Bumped when the crest map is swapped for a fresher remote copy,
    /// so crest-reading views re-render with the new badges.
    @Published private(set) var crestsRevision = 0
    @Published private(set) var isLoading = false
    /// True while a link-validation pass runs (automatic or manual);
    /// the "Kiểm tra link" button spins on it.
    @Published private(set) var isValidating = false
    @Published var statusMessage: String?
    @Published var selectedLeague: Int = League.england.rawValue

    private(set) var lastFetch: Date?
    private var loadedOnce = false
    private var didPickInitialTab = false
    private var fetching = false
    private var autoRefreshTask: Task<Void, Never>?

    private var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlist.m3u")
    }

    private var mirrorCacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirror.m3u")
    }

    private var invalidFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("invalid-urls.json")
    }

    private func loadInvalidSet() {
        guard let data = try? Data(contentsOf: invalidFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        invalidURLs = Set(list)
    }

    private func saveInvalidSet() {
        let list = Array(invalidURLs)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: invalidFileURL, options: .atomic)
        }
    }

    var isStale: Bool {
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) > Self.autoRefreshInterval
    }

    func channels(in league: League) -> [Channel] {
        channels.filter { $0.leagueRank == league.rawValue }
    }

    /// Every channel whose match is in its live window right now
    /// (classifier bucket 0), merged from the league lists and the Hot
    /// group, deduplicated by URL, in the standard live-first order.
    var liveChannels: [Channel] {
        let now = Date()
        var seen = Set<String>()
        var live: [Channel] = []
        for channel in channels + hotChannels {
            guard LeagueClassifier.bucket(of: channel, now: now) == 0 else { continue }
            if seen.insert(channel.url).inserted {
                live.append(channel)
            }
        }
        return LeagueClassifier.sorted(live)
    }

    // MARK: - Lifecycle

    /// Called once from the root view's .task: cache first, remote second,
    /// then the 15-minute auto-refresh loop for as long as the app lives.
    func start() async {
        loadCache()
        scheduleValidation()
        await refresh()
        // Crest coverage updates ride the same GitHub mirror as the
        // playlist: fetch once per launch, swap in if fresher.
        Task {
            if await Crests.refreshRemote() { crestsRevision += 1 }
        }
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.autoRefreshInterval))
                guard let self else { return }
                if self.isStale { await self.refresh() }
            }
        }
    }

    /// Android onResume rule: coming back to the app with a list older
    /// than 15 minutes triggers a refresh.
    func refreshIfStale() async {
        if loadedOnce && isStale { await refresh() }
    }

    // MARK: - Loading

    private func loadCache() {
        loadInvalidSet()
        // GitHub-first, same order as the live fetch: the mirror cache
        // is the main list (leagues + Hot + extras in one file).
        if let text = readCache(mirrorCacheFileURL) {
            let parsed = M3UParser.parse(text)
            if !parsed.isEmpty {
                setData(parsed)
                setHot(parsed)
                return
            }
        }
        if let text = readCache(cacheFileURL) {
            let parsed = M3UParser.parse(text)
            if !parsed.isEmpty { setData(parsed) }
        }
    }

    private func readCache(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 100 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func refresh() async {
        if fetching { return } // one fetch at a time, like Android
        fetching = true
        isLoading = true
        defer {
            fetching = false
            isLoading = false
        }
        do {
            // GitHub mirror first (the primary since 2026-11-13): one
            // file carries the leagues, the extras and the Hot group.
            let (data, parsed) = try await fetchPlaylist(from: Self.backupPlaylistURL)
            try? data.write(to: mirrorCacheFileURL, options: .atomic)
            setData(parsed)
            setHot(parsed)
        } catch {
            // GitHub unreachable: fall back to the origin site before
            // giving up, and say so on screen when it saves us. The
            // origin has no Hot group, so the Hot tab keeps its list.
            do {
                let (data, parsed) = try await fetchPlaylist(from: Self.playlistURL)
                try? data.write(to: cacheFileURL, options: .atomic)
                setData(parsed)
                statusMessage = "Đang dùng nguồn dự phòng."
            } catch {
                if !loadedOnce {
                    statusMessage = "Không tải được danh sách kênh. Kiểm tra mạng rồi thử lại."
                } else {
                    statusMessage = "Chưa làm mới được — đang dùng danh sách cũ."
                }
            }
        }
        pickInitialTabIfNeeded()
        scheduleValidation()
    }

    /// One playlist fetch + validation: the text must decode and parse
    /// to at least one channel, otherwise the source counts as failed
    /// (an error page or an empty file must never replace a good list).
    private func fetchPlaylist(from url: URL) async throws -> (Data, [Channel]) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Same user agent the Android app sends; some CDNs expect it.
        request.setValue("Mozilla/5.0 (Linux; Android 14; TV)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let parsed = M3UParser.parse(text)
        if parsed.isEmpty { throw URLError(.zeroByteResource) }
        return (data, parsed)
    }

    private func setData(_ parsed: [Channel]) {
        rawChannels = parsed
        publishFiltered()
        lastFetch = Date()
        loadedOnce = true
        statusMessage = nil
    }

    /// The Hot tab's list: the mirror's "🔥 Hot" group only, put
    /// through the same live-first sorting as every other list.
    private func setHot(_ parsed: [Channel]) {
        rawHotChannels = parsed.filter { $0.group == Self.hotGroupName }
        publishFiltered()
    }

    /// The single gate every display list flows through: raw entries
    /// minus proven-dead links minus .flv (unplayable on AVPlayer).
    private func publishFiltered() {
        channels = LeagueClassifier.sorted(rawChannels.filter(isDisplayable))
        hotChannels = LeagueClassifier.sorted(rawHotChannels.filter(isDisplayable))
    }

    private func isDisplayable(_ ch: Channel) -> Bool {
        if invalidURLs.contains(ch.url) { return false }
        return !Self.isFLV(ch.url)
    }

    static func isFLV(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".flv")
    }

    /// The player's fallback ladder for a tapped channel: every
    /// displayable channel carrying the same match, tapped one first
    /// (the tvOS UI builds the same ladder; the store owns it so the
    /// iOS player gets it too).
    func sources(for ch: Channel) -> [Channel] {
        let key = MatchTitle.fixtureKey(ch.title)
        if key.isEmpty { return [ch] }
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [ch] + channels + hotChannels {
            if MatchTitle.fixtureKey(candidate.title) == key,
               seen.insert(candidate.url).inserted {
                out.append(candidate)
                if out.count >= 8 { break }
            }
        }
        return out.isEmpty ? [ch] : out
    }

    /// First load only: land on the Hot tab when it has a live match,
    /// else the highest-priority league with a live match right now;
    /// fall back to Ngoại Hạng Anh. Runs at the end of the first
    /// refresh so the Hot list is already known when deciding.
    private func pickInitialTabIfNeeded() {
        guard !didPickInitialTab, loadedOnce else { return }
        didPickInitialTab = true
        // Both platforms open on the Trực tiếp tab whenever anything
        // is live (owner's request, 2026-11-13) — that is what he
        // turns the TV on for, and iOS gained the same live chip in
        // 1.7 to stay in sync with the TV versions.
        if !liveChannels.isEmpty {
            selectedLeague = Self.liveTabValue
            return
        }
        let now = Date()
        if hotChannels.contains(where: { LeagueClassifier.bucket(of: $0, now: now) == 0 }) {
            selectedLeague = Self.hotTabValue
            return
        }
        var pick = League.england.rawValue
        for league in League.allCases {
            let hasLive = channels.contains {
                $0.leagueRank == league.rawValue && LeagueClassifier.bucket(of: $0, now: now) == 0
            }
            if hasLive { pick = league.rawValue; break }
        }
        selectedLeague = pick
    }

    // MARK: - Link validation (owner's request, 2026-11-13)

    /// The device's own vantage point is the only one that shares the
    /// owner's network and tunnel, so the app itself re-checks the
    /// list: after every load it probes each link in the background
    /// and hides the ones that are definitively unplayable HERE, so
    /// dead links never reach the match screens. The mirror repo runs
    /// the vantage-independent half of the same job (404s + filler).

    private func scheduleValidation() {
        Task { await validateLinks(reset: false) }
    }

    /// The "Kiểm tra link" button: force-fetch the newest playlist,
    /// then re-probe EVERYTHING from scratch (the hidden set is
    /// cleared first, so a link that died under a dead tunnel gets a
    /// fair second chance) and republish the match screens.
    func refreshAndValidate() async {
        await refresh()
        // refresh() schedules its own background pass; wait it out so
        // the from-scratch pass below is the one that runs.
        while validating {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await validateLinks(reset: true)
        let hidden = invalidURLs.count
        statusMessage = hidden > 0
            ? "Đã kiểm tra xong: ẩn \(hidden) link chết."
            : "Đã kiểm tra xong: không có link chết."
    }

    private func validateLinks(reset: Bool) async {
        if validating { return }
        validating = true
        isValidating = true
        defer {
            validating = false
            isValidating = false
        }
        if reset {
            invalidURLs = []
            saveInvalidSet()
            publishFiltered()
        }
        let now = Date()
        var seen = Set<String>()
        var pool: [Channel] = []
        for ch in rawChannels + rawHotChannels where seen.insert(ch.url).inserted {
            if !Self.isFLV(ch.url) { pool.append(ch) }
        }
        // Live-window and always-on channels first — they are what
        // the home screen leads with; the rest follow in a second wave.
        let liveWave = pool.filter { isLiveScope($0, now: now) }
        let restWave = pool.filter { !isLiveScope($0, now: now) }
        await probeWave(liveWave, now: now)
        await probeWave(restWave, now: now)
    }

    /// "Should be serving right now": inside the live window, or a
    /// channel with no kickoff at all (24/7 streams).
    private func isLiveScope(_ ch: Channel, now: Date) -> Bool {
        ch.kickoff == nil || LeagueClassifier.bucket(of: ch, now: now) == 0
    }

    private func probeWave(_ wave: [Channel], now: Date) async {
        if wave.isEmpty { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        var validNow: Set<String> = []
        var invalidNow: Set<String> = []
        let chunkSize = 20
        var idx = 0
        while idx < wave.count {
            let chunk = Array(wave[idx..<min(idx + chunkSize, wave.count)])
            let results = await withTaskGroup(of: (String, Bool).self) { group in
                for ch in chunk {
                    let scope = isLiveScope(ch, now: now)
                    group.addTask {
                        (ch.url, await LinkProbe.isValid(ch, mustBeServing: scope, session: session))
                    }
                }
                var acc: [(String, Bool)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for (url, ok) in results {
                if ok { validNow.insert(url) } else { invalidNow.insert(url) }
            }
            idx += chunkSize
        }
        let before = invalidURLs
        invalidURLs.subtract(validNow)
        invalidURLs.formUnion(invalidNow)
        if invalidURLs != before {
            saveInvalidSet()
            publishFiltered()
        }
    }
}

/// One-link probe. Definitive failure = HTTP 404/410, or HTTP 200 with
/// a body that is not a stream (empty, or an .m3u8 without #EXTM3U).
/// Other HTTP statuses keep the link (403 may be the tunnel being off
/// right now; 5xx is transient). A network-level failure (connect,
/// timeout) counts only when the channel should be serving right now —
/// a room for a future match may simply not exist yet.
private enum LinkProbe {

    static func isValid(_ ch: Channel, mustBeServing: Bool, session: URLSession) async -> Bool {
        guard let url = URL(string: ch.url) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            ch.userAgent.isEmpty ? "Mozilla/5.0 (Linux; Android 14; TV)" : ch.userAgent,
            forHTTPHeaderField: "User-Agent")
        if !ch.referrer.isEmpty {
            request.setValue(ch.referrer, forHTTPHeaderField: "Referer")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 || status == 410 { return false }
            guard status == 200 else { return true }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 4096 { break }
            }
            if buffer.isEmpty { return false }
            if PlaylistStore.isFLV(ch.url) { return true }
            let path = ch.url.split(separator: "?").first.map(String.init) ?? ch.url
            if path.lowercased().hasSuffix(".m3u8") {
                return String(decoding: buffer.prefix(1024), as: UTF8.self).contains("#EXTM3U")
            }
            return true
        } catch {
            return !mustBeServing
        }
    }
}
