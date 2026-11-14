import Foundation

/// Watch progress ("Đang xem dở") + favorites ("Yêu thích") — a
/// direct port of the Android WatchStore (Joe TV v1.4/v1.5.1,
/// verified on device). One small JSON document in app-private
/// storage, rewritten whole on each mutation via temp file +
/// rename, so a kill mid-write can never corrupt the store.
///
/// Keys (stable per playable item / per title):
///   progress  KKPhim     "kk|<slug>|<episode name>"
///             Film4K.net "f4k|<slug>|<episode name>"
///             VSMOV      "vs|<slug>|<episode name>"
///             Torrent "tor|<stream id>" (meta id for a movie,
///                     metaId:S:E per series episode)
///   favorite  "kk|<slug>" · "f4k|<slug>" · "vs|<slug>"
///             Torrent "tor|<meta id>|<type>"
///
/// ADDENDUM RULE: an entry stores provider + slug + episode name +
/// position ONLY — never a stream URL. Resuming re-opens the
/// provider's detail and resolves the stream fresh at that moment
/// (stream URLs expire; a stored URL would be a dead URL).
final class WatchStore: ObservableObject {
    static let kindKK = "kk"
    static let kindF4K = "f4k"
    static let kindVS = "vsmov"
    static let kindTor = "torrent"

    private static let fileName = "watch-state.json"
    private static let maxProgress = 40
    private static let maxFavorites = 80
    /// Continue Watching rails show at most this many tiles.
    static let railCap = 20

    struct Entry: Codable, Identifiable, Hashable {
        var key = ""
        var kind = ""
        // progress
        var pos: Int64 = 0
        var dur: Int64 = 0
        var ts: Int64 = 0
        var ep = ""        // episode name (detail preselect)
        var epLabel = ""   // display line
        // reopen identity
        var title = ""
        var poster = ""
        var year = ""
        var slug = ""
        var source = ""    // provider code for movie entries
        // torrent identity
        var metaId = ""
        var metaType = ""
        var streamId = ""
        var metaBase = ""
        var background = ""
        var desc = ""

        var id: String { key }
        var posterURL: URL? { poster.isEmpty ? nil : URL(string: poster) }
        /// 0…1 watched fraction for the tile's progress bar.
        var fraction: Double {
            guard dur > 0 else { return 0 }
            return min(1, max(0, Double(pos) / Double(dur)))
        }
    }

    @Published private(set) var progressEntries: [Entry] = []
    @Published private(set) var favoriteEntries: [Entry] = []

    init() { reload() }

    // MARK: - Keys

    static func kkProgressKey(slug: String, epName: String) -> String { "kk|\(slug)|\(epName)" }
    static func f4kProgressKey(slug: String, epName: String) -> String { "f4k|\(slug)|\(epName)" }
    static func vsProgressKey(slug: String, epName: String) -> String { "vs|\(slug)|\(epName)" }
    static func torProgressKey(streamId: String) -> String { "tor|\(streamId)" }

    static func movieFavKey(provider: String, slug: String) -> String {
        switch provider {
        case Providers.F4K: return "f4k|\(slug)"
        case Providers.VS: return "vs|\(slug)"
        default: return "kk|\(slug)"
        }
    }

    static func torFavKey(metaId: String, type: String) -> String { "tor|\(metaId)|\(type)" }

    // MARK: - Progress

    func progress() -> [Entry] {
        progressEntries.sorted { $0.ts > $1.ts }
    }

    func progressFor(key: String) -> Entry? {
        progressEntries.first { $0.key == key }
    }

    func saveProgress(_ e: Entry) {
        guard !e.key.isEmpty else { return }
        var doc = load()
        doc.progress.removeAll { $0.key == e.key }
        doc.progress.insert(e, at: 0)
        doc.progress.sort { $0.ts > $1.ts }
        while doc.progress.count > Self.maxProgress { doc.progress.removeLast() }
        store(doc)
    }

    func removeProgress(key: String) {
        var doc = load()
        if doc.progress.removeAll(where: { $0.key == key }) > 0 { store(doc) }
    }

    // MARK: - Favorites

    func favorites() -> [Entry] { favoriteEntries }

    func isFavorite(key: String) -> Bool {
        favoriteEntries.contains { $0.key == key }
    }

    /// Returns the NEW state (true = now a favorite).
    @discardableResult
    func toggleFavorite(_ e: Entry) -> Bool {
        var doc = load()
        let was = doc.favorites.removeAll { $0.key == e.key } > 0
        if !was {
            doc.favorites.insert(e, at: 0)
            while doc.favorites.count > Self.maxFavorites { doc.favorites.removeLast() }
        }
        store(doc)
        return !was
    }

    func removeFavorite(key: String) {
        var doc = load()
        if doc.favorites.removeAll(where: { $0.key == key }) > 0 { store(doc) }
    }

    // MARK: - Persistence

    private struct Doc: Codable {
        var progress: [Entry] = []
        var favorites: [Entry] = []
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.fileName)
    }

    private func load() -> Doc {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Doc.self, from: data) else {
            // A corrupt store must never break the app: start empty.
            return Doc()
        }
        return doc
    }

    private func store(_ doc: Doc) {
        defer { reload(from: doc) }
        guard let data = try? JSONEncoder().encode(doc) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func reload(from doc: Doc? = nil) {
        let d = doc ?? load()
        progressEntries = d.progress
        favoriteEntries = d.favorites
    }

    // MARK: - Helpers

    /// Milliseconds → "12:34" (or "1:02:34" past an hour).
    static func fmtClock(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    static func filterKinds(_ entries: [Entry], _ kinds: [String]) -> [Entry] {
        entries.filter { kinds.contains($0.kind) }
    }
}
