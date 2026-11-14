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

    /// Fail-soft per rail, like the Android home: one dead
    /// provider never blanks the section.
    private func load() async {
        loading = true
        defer { loading = false }
        async let kkN = try? Providers.newest(Providers.KK, page: 1)
        async let f4kN = try? Providers.newest(Providers.F4K, page: 1)
        async let vsN = try? Providers.newest(Providers.VS, page: 1)
        async let kkS = try? Providers.listByType(Providers.KK, type: "phim-bo", page: 1)
        async let kkM = try? Providers.listByType(Providers.KK, type: "phim-le", page: 1)
        async let kkA = try? Providers.listByType(Providers.KK, type: "hoat-hinh", page: 1)
        async let f4kM = try? Providers.listByType(Providers.F4K, type: "phim-le", page: 1)
        async let vsS = try? Providers.listByType(Providers.VS, type: "phim-bo", page: 1)
        async let tpN = try? Providers.newest(Providers.TP, page: 1)
        async let tpL = try? Providers.listByType(Providers.TP, type: "phim-le", page: 1)
        async let tpS = try? Providers.listByType(Providers.TP, type: "phim-bo", page: 1)
        async let cr = try? Providers.listByType(Providers.KK, type: "phim-chieu-rap", page: 1)
        let (a, b, c, d, e, f, g, h, i, j, k, l) = await (kkN, f4kN, vsN, kkS, kkM, kkA, f4kM, vsS, tpN, tpL, tpS, cr)
        // A rail that failed this round keeps its previous data.
        if let a { kkNew = a }
        if let b { f4kNew = b }
        if let c { vsNew = c }
        if let d { kkSeries = d }
        if let e { kkMovies = e }
        if let f { kkAnime = f }
        if let g { f4kMovies = g }
        if let h { vsSeries = h }
        if let i { tpNew = i }
        if let j { tpMovies = j }
        if let k { tpSeries = k }
        if let l { chieuRap = l }
        // Genre / country rails (KK): fail-soft per rail, exactly
        // like the rails above — a failed fetch keeps its
        // previous data.
        for spec in Self.genreSpec {
            if let movies = try? await Providers.kkGenre(spec.slug, page: 1) {
                genreLists[spec.slug] = movies
            }
        }
        for spec in Self.countrySpec {
            if let movies = try? await Providers.kkCountry(spec.slug, page: 1) {
                countryLists[spec.slug] = movies
            }
        }
        // Dedicated Vietnam block: one large country fetch,
        // fail-soft like every other rail (keeps previous data).
        if let movies = try? await Providers.kkCountry("viet-nam", page: 1, limit: 48) {
            vietnamAll = movies
        }
        merged = Providers.mergeDedupe([kkNew, f4kNew, vsNew, tpNew])
        if hasData { loadedAt = Date() }
    }
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
