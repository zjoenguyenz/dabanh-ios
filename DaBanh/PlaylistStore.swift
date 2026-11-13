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
    /// Bumped when the crest map is swapped for a fresher remote copy,
    /// so crest-reading views re-render with the new badges.
    @Published private(set) var crestsRevision = 0
    @Published private(set) var isLoading = false
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
        channels = LeagueClassifier.sorted(parsed)
        lastFetch = Date()
        loadedOnce = true
        statusMessage = nil
    }

    /// The Hot tab's list: the mirror's "🔥 Hot" group only, put
    /// through the same live-first sorting as every other list.
    private func setHot(_ parsed: [Channel]) {
        hotChannels = LeagueClassifier.sorted(
            parsed.filter { $0.group == Self.hotGroupName })
    }

    /// First load only: land on the Hot tab when it has a live match,
    /// else the highest-priority league with a live match right now;
    /// fall back to Ngoại Hạng Anh. Runs at the end of the first
    /// refresh so the Hot list is already known when deciding.
    private func pickInitialTabIfNeeded() {
        guard !didPickInitialTab, loadedOnce else { return }
        didPickInitialTab = true
        #if os(tvOS)
        // tvOS opens on the Trực tiếp tab whenever anything is live
        // (owner's request, 2026-11-13) — that is what he turns the
        // TV on for. The iOS tab bar has no live tab, so iOS keeps
        // the Hot-first rule below.
        if !liveChannels.isEmpty {
            selectedLeague = Self.liveTabValue
            return
        }
        #endif
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
}
