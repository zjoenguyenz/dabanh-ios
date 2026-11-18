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
///
/// CANONICAL IDENTITY (v2.0.29, cluster C — owner defect, item 6
/// of the 2.0.28 test): the per-source keys above stay the
/// REOPEN identity, but progress is matched across sources by a
/// canonical identity derived from the title itself — the
/// app's own cross-provider film identity (the
/// Providers.sameFilm / filmKey discipline: normalized title
/// + year, ±1-year tolerance gated on the exact title match,
/// IMDb/TMDB id shortcuts) PLUS the
/// episode NUMBER (Providers.episodeNumber on the provider
/// side; the S:E tail of the torrent stream id on the torrent
/// side). saveProgress merges a save into its canonical twin
/// instead of stranding a second row, and the canonical
/// lookups (progressFor(matching:) / progressForTitle /
/// removeProgress(matching:)) find or clear that row from
/// either family's session. Pre-fix, episode 1 of a series
/// saved under "kk|<slug>|Tập 1" and episode 2 — KK empty, so
/// played through the detail's Torrent entry — saved under
/// "tor|<imdb>:1:2": two rows, and neither family's resume
/// lookup could see the other's position.
///
/// L6 (v2.0.31): canonical identity is per title+episode,
/// but the RAIL is per SERIES — the owner's rule is one
/// Continue Watching card per series, pointing at the
/// latest-watched episode. sameSeries + the folds in
/// saveProgress / coalesceProgress enforce it: a save for
/// any episode supersedes the stored row for a different
/// episode of the same series, and the load-time coalesce
/// applies the same fold to entries an older build left
/// side by side (the owner's Tập 01 + Tập 02 pair).
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
        // canonical identity bridges (v2.0.29, cluster C):
        // stamped by save call sites when the title's stable
        // ids are known; empty on every pre-2.0.29 entry and
        // on call sites that cannot know them — the canonical
        // match then falls back to normalized title + year.
        var imdbId = ""
        var tmdbId = ""

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

    // MARK: - Canonical identity (v2.0.29, cluster C)

    /// The episode NUMBER an entry addresses, per family:
    /// torrent series entries parse it from the stream id's
    /// "imdbId:season:episode" tail (the video LABEL is not
    /// used — it carries the episode's name, whose own digits
    /// would corrupt Providers.episodeNumber's last-run rule);
    /// everything else reads the stored episode name exactly
    /// as the failover hop matches episodes. -1 = no episode
    /// number (a movie / "Full" entry).
    static func episodeNumber(of e: Entry) -> Int {
        if e.kind == kindTor {
            let parts = e.streamId.split(separator: ":")
            if parts.count >= 3, let n = Int(String(parts[parts.count - 1])) {
                return n
            }
            if !e.ep.isEmpty { return Providers.episodeNumber(e.ep) }
            return -1
        }
        return Providers.episodeNumber(e.ep)
    }

    /// The season an entry addresses, when either family
    /// states one: the stream id's middle component on the
    /// torrent side, Providers.seasonNumber on the provider
    /// side (KK episode names are normally season-free — nil).
    static func seasonNumber(of e: Entry) -> Int? {
        if e.kind == kindTor {
            let parts = e.streamId.split(separator: ":")
            if parts.count >= 3, let s = Int(String(parts[parts.count - 2])) {
                return s
            }
            return nil
        }
        return Providers.seasonNumber(e.ep)
    }

    /// The IMDb id an entry carries: the stamped field when a
    /// call site knew it, else the torrent meta id itself
    /// (Torrentio/Cinemeta meta ids ARE IMDb ids).
    static func imdbId(of e: Entry) -> String {
        if !e.imdbId.isEmpty { return e.imdbId }
        return e.metaId.hasPrefix("tt") ? e.metaId : ""
    }

    /// Live/sports rows are never canonical progress: their
    /// "episodes" are events, and a title coincidence must
    /// never merge one into a film's row (or vice versa).
    private static func canonicalEligible(_ e: Entry) -> Bool {
        if e.key.hasPrefix("mf-event|") { return false }
        if e.metaType == "events" || e.metaType == "tv" { return false }
        return !e.title.isEmpty
    }

    /// Same-film test for two entries, mirroring
    /// Providers.sameFilm's discipline: a shared IMDb or TMDB
    /// id decides outright; otherwise the normalized titles
    /// must be exactly equal and the years equal, either side
    /// empty, or ±1 (the cross-catalogue year-variant
    /// tolerance, gated on the exact title match).
    private static func sameFilm(_ a: Entry, _ b: Entry) -> Bool {
        let ia = imdbId(of: a), ib = imdbId(of: b)
        if !ia.isEmpty && ia == ib { return true }
        if !a.tmdbId.isEmpty && a.tmdbId == b.tmdbId { return true }
        let ta = Providers.normalizeTitle(a.title)
        let tb = Providers.normalizeTitle(b.title)
        guard !ta.isEmpty && ta == tb else { return false }
        let ya = Providers.yearOf(a.year), yb = Providers.yearOf(b.year)
        if ya.isEmpty || yb.isEmpty || ya == yb { return true }
        if let x = Int(ya), let y = Int(yb), abs(x - y) == 1 { return true }
        return false
    }

    /// True when two entries are the same title + episode
    /// under the canonical identity, whatever source saved
    /// each of them.
    static func canonicalMatch(_ a: Entry, _ b: Entry) -> Bool {
        guard canonicalEligible(a), canonicalEligible(b) else { return false }
        guard sameFilm(a, b) else { return false }
        guard episodeNumber(of: a) == episodeNumber(of: b) else { return false }
        if let sa = seasonNumber(of: a), let sb = seasonNumber(of: b),
           sa != sb {
            return false
        }
        return true
    }

    /// v2.0.31 (L6): same SERIES, any episode — the owner's
    /// Continue Watching rule from his 2.0.29 test (two
    /// cards for one series, Tập 01 beside Tập 02): the
    /// rail holds ONE card per series, pointing at the
    /// latest-watched episode. canonicalMatch above folds
    /// the same episode across sources; this folds ACROSS
    /// episodes of one series. Both entries must carry an
    /// episode number — a movie (episode -1) never folds
    /// into a series row, and two movies never fold into
    /// each other — and the season gate is canonicalMatch's
    /// own, so two seasons of one show keep separate cards
    /// when both sides state their season.
    static func sameSeries(_ a: Entry, _ b: Entry) -> Bool {
        guard canonicalEligible(a), canonicalEligible(b) else { return false }
        guard episodeNumber(of: a) >= 0, episodeNumber(of: b) >= 0
        else { return false }
        guard sameFilm(a, b) else { return false }
        if let sa = seasonNumber(of: a), let sb = seasonNumber(of: b),
           sa != sb {
            return false
        }
        return true
    }

    /// Merge a canonical twin pair into ONE row. Progress
    /// fields always come from `incoming` (the live save /
    /// the newer entry). The surviving REOPEN identity is the
    /// provider side's whenever either side is a provider
    /// entry — its key/kind/slug/source/ep are what the Phim
    /// Continue Watching rails render and what the provider
    /// detail pages address — and the other side contributes
    /// every identity field the survivor lacks, so the merged
    /// row can still reopen through the torrent side too
    /// (metaId/streamId/metaBase ride along). Two provider
    /// entries (a failover hop) or two torrent entries keep
    /// the incoming side's identity, exactly as before.
    private static func mergedEntry(incoming: Entry, old: Entry) -> Entry {
        let incomingIsProvider = incoming.kind != kindTor
        let oldIsProvider = old.kind != kindTor
        var base: Entry
        let donor: Entry
        if oldIsProvider && !incomingIsProvider {
            base = old
            donor = incoming
            base.pos = incoming.pos
            base.dur = incoming.dur
            base.ts = incoming.ts
        } else {
            base = incoming
            donor = old
        }
        if base.slug.isEmpty { base.slug = donor.slug }
        if base.source.isEmpty { base.source = donor.source }
        if base.metaId.isEmpty { base.metaId = donor.metaId }
        if base.metaType.isEmpty { base.metaType = donor.metaType }
        if base.streamId.isEmpty { base.streamId = donor.streamId }
        if base.metaBase.isEmpty { base.metaBase = donor.metaBase }
        if base.background.isEmpty { base.background = donor.background }
        if base.desc.isEmpty { base.desc = donor.desc }
        if base.imdbId.isEmpty { base.imdbId = donor.imdbId }
        if base.tmdbId.isEmpty { base.tmdbId = donor.tmdbId }
        if base.poster.isEmpty { base.poster = donor.poster }
        if base.year.isEmpty { base.year = donor.year }
        return base
    }

    /// Resume lookup by ENTRY TEMPLATE (v2.0.29, cluster C):
    /// the exact per-source key first (unchanged behaviour),
    /// then the canonical title+episode twin — so a session
    /// starting on KK finds the position episode 2 accumulated
    /// on the torrent side, and vice versa.
    func progressFor(matching template: Entry) -> Entry? {
        if let exact = progressFor(key: template.key) { return exact }
        return progress().first { Self.canonicalMatch($0, template) }
    }

    /// The detail pages' "this title has progress" lookup
    /// (v2.0.29, cluster C): the historic slug+source match
    /// first, byte-identical semantics (the latest entry for
    /// the title on this provider, any episode); then a
    /// canonical film match — the latest entry for the same
    /// film from ANY source family, any episode, exactly the
    /// shape the historic predicate returned for its own
    /// provider. Lets a KK detail show "Xem tiếp" and
    /// preselect the episode for progress that only ever
    /// played through the Torrent entry.
    func progressForTitle(slug: String, provider: String,
                          title: String, year: String) -> Entry? {
        if let e = progress().first(where: {
            $0.slug == slug && $0.source == provider }) {
            return e
        }
        guard !title.isEmpty else { return nil }
        var probe = Entry()
        probe.title = title
        probe.year = year
        return progress().first {
            Self.canonicalEligible($0) && Self.sameFilm($0, probe)
        }
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
        // v2.0.29 (cluster C): fold the save into its
        // canonical twin when one is stored — the same-key
        // entry included, so identity fields merged in by an
        // earlier cross-source save survive a same-source
        // re-save. The twins leave the array; the merged row
        // is inserted once, under the surviving identity
        // (see mergedEntry).
        var merged = e
        let twins = progressEntries.filter {
            $0.key == e.key || Self.canonicalMatch($0, e)
        }
        for old in twins {
            merged = Self.mergedEntry(incoming: merged, old: old)
        }
        if !twins.isEmpty {
            let twinKeys = Set(twins.map { $0.key })
            progressEntries.removeAll { twinKeys.contains($0.key) }
        }
        progressEntries.removeAll { $0.key == merged.key }
        // v2.0.31 (L6): one row per series — this save is
        // the series' latest watching by construction (the
        // tick stamps ts as it saves), so any stored row
        // for a DIFFERENT episode of the same series is
        // superseded and leaves; the rail's single card
        // then points at the episode watched most
        // recently. Same-episode rows under other keys
        // were canonical twins and are already folded
        // above, so what this removes is strictly other
        // episodes.
        progressEntries.removeAll {
            $0.key != merged.key && Self.sameSeries($0, merged)
        }
        progressEntries.insert(merged, at: 0)
        progressEntries.sort { $0.ts > $1.ts }
        while progressEntries.count > Self.maxProgress { progressEntries.removeLast() }
        persist()
    }

    func removeProgress(key: String) {
        let before = progressEntries.count
        progressEntries.removeAll(where: { $0.key == key })
        if progressEntries.count != before { persist() }
    }

    /// Completion / removal by ENTRY TEMPLATE (v2.0.29,
    /// cluster C): removes the exact-key entry AND any
    /// canonical twin, so finishing an episode under one
    /// source clears the merged Continue Watching row
    /// whichever source's key it survives under. (The
    /// per-card long-press removal stays on removeProgress
    /// (key:) with the row's own key — unchanged.)
    func removeProgress(matching template: Entry) {
        let before = progressEntries.count
        progressEntries.removeAll {
            $0.key == template.key || Self.canonicalMatch($0, template)
        }
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
        // v2.0.17: Caches, NOT Application Support. On the
        // owner's Apple TV every write to Application Support
        // failed with "The folder … doesn't exist" (his
        // 2026-11-17 diagnostics photo: a screen of watchstore
        // write failures, so Continue Watching never reached
        // the disk), while every other store in this app —
        // JoeDetailCache, PhimRailCache — writes to Caches and
        // works. Same house pattern, same proven directory.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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
        coalesceProgress()
    }

    /// One-pass coalesce of progress entries already on disk
    /// that are canonical twins — the same film + episode an
    /// older build saved under two sources' keys (the owner's
    /// existing Continue Watching list is exactly this case).
    /// Newest entry wins the progress fields; identity fields
    /// union via mergedEntry. Idempotent, and persists only
    /// when a twin pair actually collapsed. Favorites are not
    /// progress and are never coalesced.
    private func coalesceProgress() {
        guard progressEntries.count > 1 else { return }
        var kept: [Entry] = []
        for e in progressEntries.sorted(by: { $0.ts > $1.ts }) {
            if let i = kept.firstIndex(where: { Self.canonicalMatch($0, e) }) {
                kept[i] = Self.mergedEntry(incoming: kept[i], old: e)
            } else if kept.contains(where: { Self.sameSeries($0, e) }) {
                // v2.0.31 (L6): a NEWER row for the same
                // series already stands (the walk is
                // newest-first) — this older episode's row
                // is superseded by it, exactly as a fresh
                // save would supersede it (see saveProgress).
                // The series' card survives on the newest
                // row with that row's own position intact;
                // nothing else about the older row is
                // carried over, because the card's meaning
                // is "the episode watched last, where it
                // stopped".
                continue
            } else {
                kept.append(e)
            }
        }
        if kept.count != progressEntries.count {
            progressEntries = kept
            persist()
        }
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
             metaBase, background, desc, imdbId, tmdbId
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
        imdbId = try c.decodeIfPresent(String.self, forKey: .imdbId) ?? ""
        tmdbId = try c.decodeIfPresent(String.self, forKey: .tmdbId) ?? ""
    }
}
