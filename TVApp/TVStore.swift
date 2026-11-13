import Foundation

/// Store for the TV app: one merged playlist (the owner's self-updating
/// combined list), parsed with the shared M3UParser and presented grouped,
/// preserving the file's own group order. Cache-first, then remote, with a
/// 30-minute auto-refresh while the app lives.
@MainActor
final class TVStore: ObservableObject {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/data-582047/main/582047.m3u")!
    private static let autoRefreshInterval: TimeInterval = 30 * 60

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var isLoading = false
    @Published var statusMessage: String?

    private var lastFetch: Date?
    private var fetching = false
    private var autoRefreshTask: Task<Void, Never>?

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

    var isStale: Bool {
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) > Self.autoRefreshInterval
    }

    private var cacheFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("tv582047.m3u")
    }

    func start() async {
        loadCache()
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
        } catch {
            if channels.isEmpty {
                statusMessage = "Không tải được danh sách. Kiểm tra mạng rồi bấm Làm mới."
            }
        }
    }
}
