import Foundation

/// Store for the TV app: one merged playlist (the owner's self-updating
/// combined list), parsed with the shared M3UParser and presented grouped,
/// preserving the file's own group order. Cache-first, then remote, with a
/// 30-minute auto-refresh while the app lives.
///
/// v2.0 adds the house link-health standard (the owner's approved
/// method, proven in the Đá Banh apps): after every load the app
/// re-probes each link FROM THIS DEVICE in the background and hides
/// the ones that are definitively unplayable here, so dead links
/// never reach the channel rails. The hidden set is persisted, so a
/// cold start opens already clean, and every refresh re-probes, so a
/// revived link returns on its own. The "Kiểm tra link" rail action
/// (refreshAndValidate) force-fetches the newest list and re-probes
/// everything from scratch.
@MainActor
final class TVStore: ObservableObject {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/data-582047/main/582047.m3u")!
    private static let autoRefreshInterval: TimeInterval = 30 * 60

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var isLoading = false
    @Published var statusMessage: String?

    /// URLs proven unplayable FROM THIS DEVICE (see validateLinks).
    /// Published so the rails re-render the moment a pass lands.
    @Published private(set) var invalidURLs: Set<String> = []
    /// True while a link-validation pass runs (automatic or manual);
    /// the rail's "Kiểm tra link" row spins on it.
    @Published private(set) var isValidating = false

    private var lastFetch: Date?
    private var fetching = false
    private var validating = false
    private var autoRefreshTask: Task<Void, Never>?
    /// The group the owner is currently browsing (reported by the
    /// view); the validation pass probes it first.
    private var priorityGroup: String?

    /// Group names in first-appearance order (the file is pre-sorted so the
    /// most-watched groups come first).
    var groups: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for channel in channels where !channel.group.isEmpty {
            if seen.insert(channel.group).inserted {
                ordered.append(channel.group)
            }
        }
        return ordered
    }

    func channels(in group: String) -> [Channel] {
        channels.filter { $0.group == group }
    }

    /// The display gate: a group's channels minus proven-dead links
    /// and minus .flv entries (AVPlayer cannot play FLV at all).
    func visibleChannels(in group: String) -> [Channel] {
        channels(in: group).filter(isDisplayable)
    }

    /// Groups that still have at least one visible channel, in file
    /// order — a group whose links all died leaves the screen whole.
    var visibleGroups: [String] {
        groups.filter { !visibleChannels(in: $0).isEmpty }
    }

    private func isDisplayable(_ ch: Channel) -> Bool {
        if invalidURLs.contains(ch.url) { return false }
        return !LinkProbe.isFLV(ch.url)
    }

    var isStale: Bool {
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) > Self.autoRefreshInterval
    }

    private var cacheFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("tv582047.m3u")
    }

    private var invalidFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("tv-invalid-urls.json")
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

    /// The view reports the group the owner is browsing so the next
    /// validation pass probes that group first.
    func noteSelectedGroup(_ group: String?) {
        priorityGroup = group
    }

    func start() async {
        loadInvalidSet()
        loadCache()
        if !channels.isEmpty { scheduleValidation() }
        await refresh()
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.autoRefreshInterval))
                guard let self else { return }
                if self.isStale { await self.refresh() }
            }
        }
    }

    func refreshIfStale() async {
        if isStale { await refresh() }
    }

    private func loadCache() {
        guard channels.isEmpty,
              let text = try? String(contentsOf: cacheFileURL, encoding: .utf8)
        else { return }
        let parsed = M3UParser.parse(text)
        if !parsed.isEmpty { channels = parsed }
    }

    func refresh() async {
        guard !fetching else { return }
        fetching = true
        isLoading = true
        defer {
            fetching = false
            isLoading = false
        }
        do {
            var request = URLRequest(url: Self.sourceURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = String(data: data, encoding: .utf8), data.count > 1000 else {
                throw URLError(.badServerResponse)
            }
            let parsed = M3UParser.parse(text)
            guard !parsed.isEmpty else { throw URLError(.badServerResponse) }
            channels = parsed
            lastFetch = Date()
            statusMessage = nil
            try? text.write(to: cacheFileURL, atomically: true, encoding: .utf8)
            scheduleValidation()
        } catch {
            if channels.isEmpty {
                statusMessage = "Không tải được danh sách. Kiểm tra mạng rồi bấm Làm mới."
            }
        }
    }

    // MARK: - Link validation (the house standard, as in PlaylistStore)

    /// The device's own vantage point is the only one that shares the
    /// owner's network and tunnel, so the app itself re-checks the
    /// list: after every load it probes each link in the background
    /// and hides the ones that are definitively unplayable HERE.

    private func scheduleValidation() {
        Task { await validateLinks(reset: false) }
    }

    /// The "Kiểm tra link" action: force-fetch the newest playlist,
    /// then re-probe EVERYTHING from scratch (the hidden set is
    /// cleared first, so a link that died under a dead tunnel gets a
    /// fair second chance) and republish the rails.
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
        }
        let now = Date()
        // Probe order: the group the owner is browsing first, then the
        // rest in file order. Deduplicated by URL; .flv entries are
        // skipped (unplayable in AVPlayer, already hidden).
        var seen = Set<String>()
        var pool: [Channel] = []
        func addToPool(_ list: [Channel]) {
            for ch in list where seen.insert(ch.url).inserted {
                if !LinkProbe.isFLV(ch.url) { pool.append(ch) }
            }
        }
        if let priorityGroup {
            addToPool(channels(in: priorityGroup))
        }
        addToPool(channels)

        let chunkSize = 24
        var idx = 0
        while idx < pool.count {
            let chunk = Array(pool[idx..<min(idx + chunkSize, pool.count)])
            let results = await withTaskGroup(of: (String, Bool).self) { group in
                for ch in chunk {
                    let serving = isLiveScope(ch, now: now)
                    group.addTask {
                        let verdict = await LinkProbe.probe(
                            url: ch.url, referrer: ch.referrer, userAgent: ch.userAgent)
                        // The tier rule, exactly as in PlaylistStore:
                        // HTTP-definitive death hides in any case; a
                        // network-level failure hides only when the
                        // channel should be serving right now; every
                        // other outcome keeps the link.
                        let hide: Bool
                        switch verdict {
                        case .httpDead:
                            hide = true
                        case .unreachable:
                            hide = serving
                        case .alive, .indeterminate:
                            hide = false
                        }
                        return (ch.url, hide)
                    }
                }
                var acc: [(String, Bool)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            var validNow: Set<String> = []
            var invalidNow: Set<String> = []
            for (url, hide) in results {
                if hide { invalidNow.insert(url) } else { validNow.insert(url) }
            }
            let before = invalidURLs
            invalidURLs.subtract(validNow)
            invalidURLs.formUnion(invalidNow)
            if invalidURLs != before {
                saveInvalidSet()
            }
            idx += chunkSize
        }
    }

    /// "Should be serving right now": inside the live window, or a
    /// channel with no kickoff at all (24/7 streams).
    private func isLiveScope(_ ch: Channel, now: Date) -> Bool {
        ch.kickoff == nil || LeagueClassifier.bucket(of: ch, now: now) == 0
    }
}
