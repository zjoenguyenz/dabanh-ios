import SwiftUI

/// Section data stores, owned once by the app shell. In v1.1 the
/// Phim and Torrent homes kept their rails in view @State, so
/// every section switch destroyed them and the owner watched a
/// full reload spinner each time he came back. The stores load
/// once, keep the data across switches, and only re-fetch when
/// the snapshot is older than 15 minutes (silently, behind the
/// cached rails).

@MainActor
final class PhimStore: ObservableObject {
    static let genreSpec: [(slug: String, title: String)] = [("hanh-dong","💥 Hành Động"),("kinh-di","👻 Kinh Dị"),("hai-huoc","😂 Hài Hước"),("vien-tuong","🚀 Viễn Tưởng"),("tinh-cam","❤️ Tình Cảm"),("hinh-su","🕵️ Hình Sự"),("phieu-luu","🧭 Phiêu Lưu"),("co-trang","🏯 Cổ Trang")]
    static let countrySpec: [(slug: String, title: String)] = [("han-quoc","🇰🇷 Hàn Quốc"),("trung-quoc","🇨🇳 Trung Quốc"),("au-my","🌎 Âu Mỹ")]

    @Published var merged: [Movie] = []
    @Published var kkNew: [Movie] = []
    @Published var kkSeries: [Movie] = []
    @Published var kkMovies: [Movie] = []
    @Published var kkAnime: [Movie] = []
    @Published var f4kNew: [Movie] = []
    @Published var f4kMovies: [Movie] = []
    @Published var vsNew: [Movie] = []
    @Published var vsSeries: [Movie] = []
    @Published var tpNew: [Movie] = []
    @Published var tpMovies: [Movie] = []
    @Published var tpSeries: [Movie] = []
    @Published var chieuRap: [Movie] = []
    @Published var genreLists: [String: [Movie]] = [:]
    @Published var countryLists: [String: [Movie]] = [:]
    /// Dedicated Vietnam block (owner order 2026-11-14): one
    /// 48-item country fetch, split by the KK items' `type`
    /// field — the owner never has to search for Vietnamese films.
    @Published var vietnamAll: [Movie] = []
    var vietnamSeries: [Movie] { vietnamAll.filter { $0.type == "series" } }
    var vietnamSingle: [Movie] { vietnamAll.filter { $0.type == "single" } }
    @Published var loading = false

    private var loadedAt: Date?
    private var loadTask: Task<Void, Never>?

    var hasData: Bool { !merged.isEmpty || !kkNew.isEmpty }

    func loadIfNeeded() {
        if loading { return }
        if let loadedAt, hasData,
           Date().timeIntervalSince(loadedAt) < 900 { return }
        loadTask = Task { await load() }
    }

    /// v1.8: PROGRESSIVE per-rail publish. v1.7 awaited all 12
    /// rails (plus 12 more sequential fetches) before assigning
    /// ANYTHING, so one stalled provider froze the whole home on
    /// the spinner — the owner's "load đứng luôn screen". Now
    /// every fetch streams its result back and the rail appears
    /// the moment IT lands; a failed fetch keeps previous data.
    private func load() async {
        loading = true
        defer { loading = false }
        struct Job {
            let key: String
            let fetch: () async -> [Movie]?
        }
        var jobs: [Job] = [
            Job(key: "kkNew") { try? await Providers.newest(Providers.KK, page: 1) },
            Job(key: "f4kNew") { try? await Providers.newest(Providers.F4K, page: 1) },
            Job(key: "vsNew") { try? await Providers.newest(Providers.VS, page: 1) },
            Job(key: "tpNew") { try? await Providers.newest(Providers.TP, page: 1) },
            Job(key: "kkSeries") { try? await Providers.listByType(Providers.KK, type: "phim-bo", page: 1) },
            Job(key: "kkMovies") { try? await Providers.listByType(Providers.KK, type: "phim-le", page: 1) },
            Job(key: "kkAnime") { try? await Providers.listByType(Providers.KK, type: "hoat-hinh", page: 1) },
            Job(key: "f4kMovies") { try? await Providers.listByType(Providers.F4K, type: "phim-le", page: 1) },
            Job(key: "vsSeries") { try? await Providers.listByType(Providers.VS, type: "phim-bo", page: 1) },
            Job(key: "tpMovies") { try? await Providers.listByType(Providers.TP, type: "phim-le", page: 1) },
            Job(key: "tpSeries") { try? await Providers.listByType(Providers.TP, type: "phim-bo", page: 1) },
            Job(key: "chieuRap") { try? await Providers.listByType(Providers.KK, type: "phim-chieu-rap", page: 1) },
            Job(key: "vietnam") { try? await Providers.kkCountry("viet-nam", page: 1, limit: 48) },
        ]
        for spec in Self.genreSpec {
            jobs.append(Job(key: "genre:" + spec.slug) {
                try? await Providers.kkGenre(spec.slug, page: 1) })
        }
        for spec in Self.countrySpec {
            jobs.append(Job(key: "country:" + spec.slug) {
                try? await Providers.kkCountry(spec.slug, page: 1) })
        }
        await withTaskGroup(of: (String, [Movie]?).self) { group in
            for job in jobs {
                group.addTask { (job.key, await job.fetch()) }
            }
            for await (key, movies) in group {
                guard let movies else { continue }
                applyRail(key, movies)
            }
        }
        if hasData { loadedAt = Date() }
    }

    private func applyRail(_ key: String, _ movies: [Movie]) {
        switch key {
        case "kkNew": kkNew = movies; refreshMerged()
        case "f4kNew": f4kNew = movies; refreshMerged()
        case "vsNew": vsNew = movies; refreshMerged()
        case "tpNew": tpNew = movies; refreshMerged()
        case "kkSeries": kkSeries = movies
        case "kkMovies": kkMovies = movies
        case "kkAnime": kkAnime = movies
        case "f4kMovies": f4kMovies = movies
        case "vsSeries": vsSeries = movies
        case "tpMovies": tpMovies = movies
        case "tpSeries": tpSeries = movies
        case "chieuRap": chieuRap = movies
        case "vietnam": vietnamAll = movies
        default:
            if key.hasPrefix("genre:") {
                genreLists[String(key.dropFirst(6))] = movies
            } else if key.hasPrefix("country:") {
                countryLists[String(key.dropFirst(8))] = movies
            }
        }
    }

    private func refreshMerged() {
        merged = Providers.mergeDedupe([kkNew, f4kNew, vsNew, tpNew])
    }

    /// Manual retry for the home's error state (a failed load
    /// leaves loadedAt nil, so loadIfNeeded runs again).
    func retry() { loadIfNeeded() }
}

struct TorGenreRail {
    var type: String
    var genre: String
    var title: String
    var metas: [TorMeta] = []
}

@MainActor
final class TorHomeStore: ObservableObject {
    static let genreSpec: [(type: String, genre: String, title: String)] = [("movie","Action","💥 Hành Động"),("movie","Horror","👻 Kinh Dị"),("movie","Comedy","😂 Hài Hước"),("movie","Science Fiction","🚀 Viễn Tưởng"),("movie","Thriller","😱 Giật Gân"),("movie","Drama","🎭 Chính Kịch"),("series","Drama","🎭 Chính Kịch"),("series","Comedy","😂 Hài Hước"),("series","Crime","🕵️ Tội Phạm"),("series","Science Fiction","🚀 Viễn Tưởng")]

    @Published var catalogs: [TorCatalog] = []
    @Published var rails: [String: [TorMeta]] = [:]
    @Published var genreRails: [TorGenreRail] = []
    @Published var loading = false

    private var loadedAt: Date?

    var hasData: Bool { !catalogs.isEmpty }

    func loadIfNeeded() {
        if loading { return }
        if let loadedAt, hasData,
           Date().timeIntervalSince(loadedAt) < 900 { return }
        Task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let base = TorrentSettings.effectiveBase ?? TorrentSettings.cinemeta
        let cats = await TorrentClient.discoverCatalogs(addonBase: base)
        if !cats.isEmpty { catalogs = cats }
        for cat in catalogs {
            if let metas = try? await TorrentClient.fetchCatalog(cat) {
                rails[cat.id + "|" + cat.type] = metas
            }
        }
        // Genre rails: fail-soft per rail — a throw/empty just
        // omits that rail; kept rails stay in spec order.
        var fetchedRails: [TorGenreRail] = []
        for spec in Self.genreSpec {
            if let metas = try? await TorrentClient.fetchGenreCatalog(type: spec.type, genre: spec.genre),
               !metas.isEmpty {
                fetchedRails.append(TorGenreRail(type: spec.type, genre: spec.genre, title: spec.title, metas: metas))
            }
        }
        genreRails = fetchedRails
        if hasData { loadedAt = Date() }
    }
}
