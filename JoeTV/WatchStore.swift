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
///             Tủ Phim    "tp|<slug>|<episode name>"
///             Torrent "tor|<stream id>" (meta id for a movie,
///                     metaId:S:E per series episode)
///   favorite  "kk|<slug>" · "f4k|<slug>" · "vs|<slug>"
///             "tp|<slug>"
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
    static let kindTP = "tp"
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
    static func tpProgressKey(slug: String, epName: String) -> String { "tp|\(slug)|\(epName)" }
    static func torProgressKey(streamId: String) -> String { "tor|\(streamId)" }

    static func movieFavKey(provider: String, slug: String) -> String {
        switch provider {
        case Providers.F4K: return "f4k|\(slug)"
        case Providers.VS: return "vs|\(slug)"
        // C-6: Tủ Phim has its OWN prefix — pre-v1.9 it fell into
        // the kk| default, so a TP title and a KK title sharing a
        // slug shared one favourite state.
        case Providers.TP: return "tp|\(slug)"
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

    // 1.9.2 (Team 9 item 3): mutations mutate the IN-MEMORY
    // published state — the arrays loaded once at init are the
    // single truth, and persist() writes them out whole. The
    // pre-fix shape re-loaded the entire Doc from disk inside
    // EVERY mutation, and load() swallowed every failure —
    // missing file, unreadable data, ANY decode error — into
    // an empty Doc: one failed round-trip made the next
    // mutation rewrite the file from an empty base, evicting
    // everything the owner had saved (on device: favouriting
    // a second film erased the first). That path no longer
    // exists.

    func saveProgress(_ e: Entry) {
        guard !e.key.isEmpty else { return }
        progressEntries.removeAll { $0.key == e.key }
        progressEntries.insert(e, at: 0)
        progressEntries.sort { $0.ts > $1.ts }
        while progressEntries.count > Self.maxProgress { progressEntries.removeLast() }
        persist()
    }

    func removeProgress(key: String) {
        let before = progressEntries.count
        progressEntries.removeAll(where: { $0.key == key })
        if progressEntries.count != before { persist() }
    }

    /// Owner reset (v2.0.7): clear the WHOLE opened-movies
    /// history at once — every Continue Watching entry, all
    /// providers and torrent alike (both tabs read this one
    /// array). removeProgress above is the per-card long-press
    /// route; this is the Settings button's route, for a rail
    /// that filled up with accidentally opened films.
    /// Favorites are NOT progress and are never touched here.
    /// Same mutation discipline as every other write:
    /// in-memory first, then persist() writes the whole Doc.
    func clearAllProgress() {
        guard !progressEntries.isEmpty else { return }
        progressEntries.removeAll()
        persist()
    }

    // MARK: - Favorites

    func favorites() -> [Entry] { favoriteEntries }

    func isFavorite(key: String) -> Bool {
        favoriteEntries.contains { $0.key == key }
    }

    /// Returns the NEW state (true = now a favorite).
    @discardableResult
    func toggleFavorite(_ e: Entry) -> Bool {
        let was = favoriteEntries.contains { $0.key == e.key }
        favoriteEntries.removeAll { $0.key == e.key }
        if !was {
            favoriteEntries.insert(e, at: 0)
            while favoriteEntries.count > Self.maxFavorites { favoriteEntries.removeLast() }
        }
        persist()
        return !was
    }

    func removeFavorite(key: String) {
        let before = favoriteEntries.count
        favoriteEntries.removeAll(where: { $0.key == key })
        if favoriteEntries.count != before { persist() }
    }

    // MARK: - Persistence

    private struct Doc: Codable {
        var progress: [Entry] = []
        var favorites: [Entry] = []

        init(progress: [Entry] = [], favorites: [Entry] = []) {
            self.progress = progress
            self.favorites = favorites
        }

        private enum DocKeys: String, CodingKey {
            case progress, favorites
        }

        /// Tolerant like Entry's reader below: a missing array
        /// decodes as empty instead of failing the whole Doc.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DocKeys.self)
            progress = try c.decodeIfPresent([Entry].self, forKey: .progress) ?? []
            favorites = try c.decodeIfPresent([Entry].self, forKey: .favorites) ?? []
        }
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.fileName)
    }

    /// Cold load, at init only. A file that EXISTS but cannot
    /// be read or decoded is preserved verbatim as
    /// watch-state.unreadable.json and the loss is signposted
    /// into the Settings diagnostics (1.9.2, Team 9 item 3) —
    /// pre-fix it silently decoded as an empty store and the
    /// next mutation destroyed the evidence along with the
    /// data. A MISSING file is the ordinary first-run case
    /// and stays silent.
    private func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            progressEntries = []
            favoriteEntries = []
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Doc.self, from: data) else {
            preserveUnreadable()
            LoadSignpost.log("watchstore unreadable — preserved as watch-state.unreadable.json, starting empty")
            progressEntries = []
            favoriteEntries = []
            return
        }
        progressEntries = doc.progress
        favoriteEntries = doc.favorites
    }

    private func preserveUnreadable() {
        let dest = fileURL.deletingLastPathComponent()
            .appendingPathComponent("watch-state.unreadable.json")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: fileURL, to: dest)
    }

    /// Write the in-memory state out whole (temp file +
    /// rename, so a kill mid-write can never corrupt the
    /// store). A write failure is signposted, not swallowed
    /// (1.9.2, Team 9 item 3): the in-memory state stays
    /// correct for the session either way, and the Settings
    /// signpost log says the disk half failed.
    private func persist() {
        let doc = Doc(progress: progressEntries, favorites: favoriteEntries)
        guard let data = try? JSONEncoder().encode(doc) else {
            LoadSignpost.log("watchstore encode failed — state kept in memory only")
            return
        }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            LoadSignpost.log("watchstore write failed: \(error.localizedDescription)")
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                LoadSignpost.log("watchstore fallback write failed: \(error.localizedDescription)")
            }
        }
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

/// Tolerant decoding for Entry (1.9.2, Team 9 item 3): every
/// field is read with decodeIfPresent and falls back to the
/// declared default, mirroring the Android reader's per-field
/// tolerance (optString with defaults). Swift's SYNTHESIZED
/// Decodable ignores declared defaults — one key missing from
/// an older build's file (fields were added across builds:
/// the torrent CW fields metaBase/metaType among them) failed
/// the WHOLE Doc decode, and the old load() turned that into
/// an empty store. With this reader, a file from any older or
/// newer build decodes field by field and can never fail
/// wholesale. (In an extension so Entry's memberwise
/// initializer — used across the app — survives; encoding
/// stays synthesized.)
extension WatchStore.Entry {
    private enum EntryKeys: String, CodingKey {
        case key, kind, pos, dur, ts, ep, epLabel, title, poster,
             year, slug, source, metaId, metaType, streamId,
             metaBase, background, desc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: EntryKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        pos = try c.decodeIfPresent(Int64.self, forKey: .pos) ?? 0
        dur = try c.decodeIfPresent(Int64.self, forKey: .dur) ?? 0
        ts = try c.decodeIfPresent(Int64.self, forKey: .ts) ?? 0
        ep = try c.decodeIfPresent(String.self, forKey: .ep) ?? ""
        epLabel = try c.decodeIfPresent(String.self, forKey: .epLabel) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        poster = try c.decodeIfPresent(String.self, forKey: .poster) ?? ""
        year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        metaId = try c.decodeIfPresent(String.self, forKey: .metaId) ?? ""
        metaType = try c.decodeIfPresent(String.self, forKey: .metaType) ?? ""
        streamId = try c.decodeIfPresent(String.self, forKey: .streamId) ?? ""
        metaBase = try c.decodeIfPresent(String.self, forKey: .metaBase) ?? ""
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
    }
}
