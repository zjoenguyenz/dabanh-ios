import Foundation

/// One TMDB cast entry for the detail screen's "Diễn viên" row.
struct TMDBCastMember: Identifiable {
    var id: Int
    var name: String
    var character: String
    var photoURL: String
}

/// One playable title in a person's filmography (idea 20) or
/// one part of a movie collection / franchise (idea 21). The
/// identity is the (type, tmdbId) pair, matching the string-id
/// conventions used across this client.
struct TMDBCreditTitle: Identifiable {
    var tmdbId: String      // string form, matching TMDBInfo-era conventions in this file
    var type: String        // "movie" | "tv"
    var title: String
    var year: String
    var posterURL: String   // w500 URL or ""
    var character: String   // "" for collection parts
    var id: String { type + "|" + tmdbId }
}

/// The TMDB enrichment for one title: a wide backdrop, a
/// (Vietnamese) overview and the top-billed cast. Every field is
/// optional in effect — an empty value simply means the detail
/// screen keeps using the provider's own art and text.
struct TMDBInfo {
    var backdropURL: String = ""
    var overview: String = ""
    var cast: [TMDBCastMember] = []
    /// v2.0.19 (Ultra port): the record's TMDB vote average
    /// (the IMDb-style rating pill/badges) and its title-logo
    /// art URL (w500, transparent PNG) — both fail-soft.
    var voteAverage: Double = 0
    var logoURL: String = ""
    /// Idea 21: the franchise this movie belongs to, from the
    /// detail root's "belongs_to_collection" (movies only;
    /// absent/null → 0 / ""). Drives the detail screen's
    /// franchise strip via fetchCollection.
    var collectionId: Int = 0
    var collectionName: String = ""
}

/// Minimal TMDB client for the optional enrichment on the movie
/// detail screen. The API key is the owner's own, resolved in
/// this order: a key saved in Settings (UserDefaults
/// "tmdb_api_key") wins; otherwise the bundled key injected at
/// build time (TMDBBundledKey, written by the build workflow
/// from the TMDB_API_KEY Actions secret) is used, so a fresh
/// install is enriched with zero typing. Only when BOTH are
/// empty is the client inert and the detail screen exactly the
/// provider-only screen. Fully fail-soft: no throws, a
/// failed credits call keeps the detail data already fetched,
/// and only a failed detail call returns nil.
enum TMDBClient {
    /// v2.0.8 (P2e): ONE explicit short timeout for every
    /// TMDB call. Pre-fix every call rode JoeHTTP's 25 s
    /// default, so a slow TMDB taxed the detail screen's
    /// enrichment chain endlessly; 8 s is the budget, applied
    /// at every JoeHTTP call site in this client. Fail-soft
    /// behaviour (try? → nil/[]) is unchanged, and TMDB calls
    /// deliberately carry no SourceHealth wrapping.
    private static let callTimeout: TimeInterval = 8

    static var apiKey: String {
        let saved = (UserDefaults.standard.string(forKey: "tmdb_api_key") ?? "")
            .trimmingCharacters(in: .whitespaces)
        // A key typed in Settings wins; otherwise the bundled
        // key injected at build time (TMDBBundledKey) is used,
        // so a fresh install has TMDB art with zero typing.
        return saved.isEmpty ? TMDBBundledKey.value : saved
    }

    /// Stage 1 (v2.0.1): the TMDB detail call alone —
    /// backdrop (w1280) + overview. Split from the credits
    /// call so the detail screen can publish the backdrop the
    /// moment THIS call returns, instead of the backdrop
    /// waiting behind the cast fetch (the Android FIX2
    /// decoupling: TMDB work never serialises behind itself).
    /// nil on no key, no id, or a failed detail call.
    static func fetchInfo(tmdbId: String, type: String) async -> TMDBInfo? {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return nil }
        let kind = (type == "tv") ? "tv" : "movie"
        let cacheKey = kind + "|" + tmdbId
        cacheLock.lock()
        if let hit = infoCache[cacheKey] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)?api_key=\(key)&language=vi-VN",
            timeout: callTimeout)
        else { return nil }

        var info = TMDBInfo()
        let backdropPath = JSON.str(root, "backdrop_path")
        if !backdropPath.isEmpty {
            info.backdropURL = "https://image.tmdb.org/t/p/w1280" + backdropPath
        }
        info.overview = JSON.str(root, "overview")
        info.voteAverage = JSON.double(root, "vote_average")
        // Idea 21: the franchise identity rides the SAME detail
        // call (no extra round-trip) — "belongs_to_collection"
        // is a nested object on movie records, absent/null on
        // TV records and standalone films.
        if let collection = JSON.obj(root, "belongs_to_collection") {
            info.collectionId = JSON.int(collection, "id")
            info.collectionName = JSON.str(collection, "name")
        }
        // 2.0.25 (3c): the logo is SPLIT from this call —
        // fetchInfo returns without awaiting fetchLogo, so
        // the backdrop/overview/rating no longer wait a full
        // extra TMDB round-trip. logoURL stays "" here (and
        // in the cached payload); consumers that need the
        // logo fetch it in parallel via fetchLogo, which has
        // its own cache.
        cacheLock.lock(); infoCache[cacheKey] = info; cacheLock.unlock()
        return info
    }

    // MARK: - Ultra enrichment (v2.0.19): logo + rating caches

    private static var infoCache: [String: TMDBInfo] = [:]
    private static var logoCache: [String: String] = [:]
    private static var ratingCache: [String: Double] = [:]
    private static var personCreditsCache: [Int: [TMDBCreditTitle]] = [:]
    private static var collectionCache: [Int: [TMDBCreditTitle]] = [:]
    private static let cacheLock = NSLock()

    /// The title's logo art (TMDB /images): Vietnamese first,
    /// then English, then language-neutral — best vote inside
    /// each language. Returns the w500 URL or "" (fail-soft,
    /// cached either way).
    static func fetchLogo(tmdbId: String, type: String) async -> String {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return "" }
        let kind = (type == "tv") ? "tv" : "movie"
        let cacheKey = kind + "|" + tmdbId
        cacheLock.lock()
        if let hit = logoCache[cacheKey] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        var result = ""
        if let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)/images?api_key=\(key)&include_image_language=vi,en,null",
            timeout: callTimeout) {
            let logos = JSON.arr(root, "logos") ?? []
            func pick(_ lang: String?) -> String {
                var best = ""
                var bestVote = -1.0
                for l in logos {
                    let iso = JSON.str(l, "iso_639_1")
                    let matches = lang == nil ? iso.isEmpty : iso == lang
                    guard matches else { continue }
                    let v = JSON.double(l, "vote_average")
                    if v > bestVote { bestVote = v; best = JSON.str(l, "file_path") }
                }
                return best
            }
            result = pick("vi")
            if result.isEmpty { result = pick("en") }
            if result.isEmpty { result = pick(nil) }
            if result.isEmpty, let first = logos.first {
                result = JSON.str(first, "file_path")
            }
            if !result.isEmpty {
                result = "https://image.tmdb.org/t/p/w500" + result
            }
        }
        cacheLock.lock(); logoCache[cacheKey] = result; cacheLock.unlock()
        return result
    }

    /// Synchronous cache-only rating read (v2.0.21): the
    /// vote average a previous fetchInfo/rating already
    /// resolved for this identity, or nil. NEVER touches the
    /// network — PosterCard's Ultra IMDb badge reads this, so
    /// a card can never stall its poster (or flood the shared
    /// JoeHTTP session) behind a per-card TMDB fetch.
    static func cachedRating(tmdbId: String, type: String) -> Double? {
        guard !tmdbId.isEmpty else { return nil }
        let kind = (type == "tv") ? "tv" : "movie"
        let cacheKey = kind + "|" + tmdbId
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = ratingCache[cacheKey] {
            return hit > 0 ? hit : nil
        }
        if let info = infoCache[cacheKey], info.voteAverage > 0 {
            return info.voteAverage
        }
        return nil
    }

    /// The record's vote average for card badges (nil when
    /// unknown) — one detail call per identity, cached.
    static func rating(tmdbId: String, type: String) async -> Double? {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return nil }
        let kind = (type == "tv") ? "tv" : "movie"
        let cacheKey = kind + "|" + tmdbId
        cacheLock.lock()
        if let hit = ratingCache[cacheKey] {
            cacheLock.unlock()
            return hit > 0 ? hit : nil
        }
        cacheLock.unlock()
        if let info = await fetchInfo(tmdbId: tmdbId, type: type) {
            cacheLock.lock()
            ratingCache[cacheKey] = info.voteAverage
            cacheLock.unlock()
            return info.voteAverage > 0 ? info.voteAverage : nil
        }
        return nil
    }

    /// Stage 2 (v2.0.1): the credits call alone — top-billed
    /// cast. Fail-soft: [] on any failure, so a dead credits
    /// call simply leaves the screen without a cast row.
    static func fetchCast(tmdbId: String, type: String) async -> [TMDBCastMember] {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return [] }
        let kind = (type == "tv") ? "tv" : "movie"

        guard let credits = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)/credits?api_key=\(key)",
            timeout: callTimeout)
        else { return [] }
        return (JSON.arr(credits, "cast") ?? []).prefix(12).map { member in
            let profilePath = JSON.str(member, "profile_path")
            return TMDBCastMember(
                id: JSON.int(member, "id"),
                name: JSON.str(member, "name"),
                character: JSON.str(member, "character"),
                photoURL: profilePath.isEmpty
                    ? "" : "https://image.tmdb.org/t/p/w185" + profilePath)
        }
    }

    /// Backdrop by title search (v2.0.1 — the Android
    /// TmdbApi.searchBackdrop parity): for a film whose
    /// payload carries no TMDB id, or whose record has no
    /// backdrop. One /search/multi call per query name —
    /// origin name first, the Vietnamese name as fallback —
    /// accepting only results that carry a backdrop_path,
    /// whose normalized title matches either of the film's
    /// names, and whose year matches when both years are
    /// known. Returns the w1280 URL or nil; fail-soft.
    static func searchBackdrop(name: String, origin: String,
                               year: String) async -> String? {
        let key = apiKey
        guard !key.isEmpty else { return nil }
        var queries: [String] = []
        for q in [origin, name] {
            let t = q.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !queries.contains(t) { queries.append(t) }
        }
        let wantNames = [Providers.normalizeTitle(name),
                         Providers.normalizeTitle(origin)]
        let wantYear = Providers.yearOf(year)
        for q in queries {
            guard let root = try? await JoeHTTP.getJSON(
                "https://api.themoviedb.org/3/search/multi?api_key=\(key)&language=vi-VN&query=\(JoeHTTP.qenc(q))&include_adult=false",
                timeout: callTimeout)
            else { continue }
            for item in JSON.arr(root, "results") ?? [] {
                let backdropPath = JSON.str(item, "backdrop_path")
                if backdropPath.isEmpty { continue }
                let candidates = ["title", "name", "original_title", "original_name"]
                    .map { Providers.normalizeTitle(JSON.str(item, $0)) }
                guard candidates.contains(where: {
                    !$0.isEmpty && wantNames.contains($0)
                }) else { continue }
                let release = JSON.str(item, "release_date")
                let dateStr = release.isEmpty
                    ? JSON.str(item, "first_air_date") : release
                let itemYear = Providers.yearOf(dateStr)
                if !wantYear.isEmpty, !itemYear.isEmpty,
                   itemYear != wantYear { continue }
                return "https://image.tmdb.org/t/p/w1280" + backdropPath
            }
        }
        return nil
    }

    /// The title's IMDB id, via TMDB's external_ids — the id
    /// Torrentio streams are indexed by. This is the bridge of
    /// the Phim player's substitution rung (owner law, v1.9):
    /// when every Phim link for a title is dead, the SAME title
    /// is found on the torrent side by this id, never by title
    /// text. Key resolution is fetch()'s (Settings-saved key,
    /// else the bundled key); fail-soft exactly like fetch() —
    /// nil on no key, no id, or a bad body.
    static func imdbId(tmdbId: String, type: String) async -> String? {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return nil }
        let kind = (type == "tv") ? "tv" : "movie"
        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)/external_ids?api_key=\(key)",
            timeout: callTimeout)
        else { return nil }
        let id = JSON.str(root, "imdb_id")
        return id.isEmpty ? nil : id
    }

    /// The reverse bridge (v2.0.28, FIX4 fix 3 face c): a
    /// torrent meta's id IS its IMDb id (the Cinemeta/Stremio
    /// protocol id TorMeta carries), and TMDB's /find resolves
    /// it straight back to the TMDB identity — the lookup the
    /// torrent detail never made, which is why torrent titles
    /// showed no cast at all. The caller's type picks the
    /// preferred results array; the other is tried second, so
    /// a movie/series mislabel cannot strand the lookup.
    /// Returns the TMDB id + kind ("movie" / "tv"); fail-soft
    /// nil on no key, a non-IMDb id, or no match.
    static func findByImdb(_ imdbId: String, type: String)
        async -> (tmdbId: String, type: String)? {
        let key = apiKey
        guard !key.isEmpty, imdbId.hasPrefix("tt") else { return nil }
        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/find/\(imdbId)?api_key=\(key)&external_source=imdb_id",
            timeout: callTimeout)
        else { return nil }
        let arrays = (type == "series" || type == "tv")
            ? ["tv_results", "movie_results"]
            : ["movie_results", "tv_results"]
        for arrayKey in arrays {
            guard let first = JSON.arr(root, arrayKey)?.first
            else { continue }
            let id = JSON.int(first, "id")
            if id > 0 {
                return (String(id), arrayKey == "tv_results" ? "tv" : "movie")
            }
        }
        return nil
    }

    /// Strict identity search (v2.0.5 — the Android FIX5
    /// step-3 parity the tvOS ladder never had): find the
    /// film's TMDB entry by title when NO provider record
    /// carries any id at all. Acceptance is deliberately
    /// strict — the backdrop hunt above can afford "year
    /// matches when both years are known", an identity
    /// cannot: the normalised title must match EXACTLY (one
    /// of the film's two names against one of the hit's
    /// title fields — the sameFilm normalisation discipline)
    /// AND the hit's year must equal the film's year
    /// exactly. An unknown film year skips the search
    /// entirely (never guess an identity). Origin name is
    /// queried first (TMDB indexes original titles best),
    /// the Vietnamese name second. Returns the TMDB id +
    /// kind ("movie" / "tv") or nil; fail-soft throughout.
    static func searchIdentity(name: String, originName: String,
                               year: String) async -> (tmdbId: String, type: String)? {
        let key = apiKey
        let wantYear = Providers.yearOf(year)
        guard !key.isEmpty, !wantYear.isEmpty else { return nil }
        var queries: [String] = []
        for q in [originName, name] {
            let t = q.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !queries.contains(t) { queries.append(t) }
        }
        let wantNames = [Providers.normalizeTitle(name),
                         Providers.normalizeTitle(originName)]
            .filter { !$0.isEmpty }
        guard !queries.isEmpty, !wantNames.isEmpty else { return nil }
        for q in queries {
            guard let root = try? await JoeHTTP.getJSON(
                "https://api.themoviedb.org/3/search/multi?api_key=\(key)&language=vi-VN&query=\(JoeHTTP.qenc(q))&include_adult=false",
                timeout: callTimeout)
            else { continue }
            for item in JSON.arr(root, "results") ?? [] {
                let mediaType = JSON.str(item, "media_type")
                guard mediaType == "movie" || mediaType == "tv"
                else { continue }
                let candidates = ["title", "name", "original_title", "original_name"]
                    .map { Providers.normalizeTitle(JSON.str(item, $0)) }
                guard candidates.contains(where: {
                    !$0.isEmpty && wantNames.contains($0)
                }) else { continue }
                let release = JSON.str(item, "release_date")
                let dateStr = release.isEmpty
                    ? JSON.str(item, "first_air_date") : release
                guard Providers.yearOf(dateStr) == wantYear
                else { continue }
                let id = JSON.int(item, "id")
                guard id > 0 else { continue }
                return (String(id), mediaType)
            }
        }
        return nil
    }

    /// The title's poster_path (v2.0.5): the image pipeline's
    /// TMDB poster fallback leg builds the w500 URL from it
    /// ("https://image.tmdb.org/t/p/w500" + path — the house
    /// poster size). Same detail endpoint fetchInfo reads,
    /// minus the language pin (a path is language-free).
    /// Fail-soft: nil on no key, no id, a failed call, or no
    /// poster on record.
    static func posterPath(tmdbId: String, type: String) async -> String? {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return nil }
        let kind = (type == "tv") ? "tv" : "movie"
        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)?api_key=\(key)",
            timeout: callTimeout)
        else { return nil }
        let path = JSON.str(root, "poster_path")
        return path.isEmpty ? nil : path
    }

    // MARK: - Filmography + franchise (ideas 20 + 21)

    /// One TMDBCreditTitle from a raw credit/part record:
    /// title/year/poster follow the same field rules as the
    /// rest of this client (movie "title" vs TV "name", year =
    /// first 4 chars of the release/air date, w500 poster).
    private static func creditTitle(_ item: [String: Any], type: String,
                                    character: String) -> TMDBCreditTitle {
        let dateStr = JSON.str(item, "release_date").isEmpty
            ? JSON.str(item, "first_air_date")
            : JSON.str(item, "release_date")
        let posterPath = JSON.str(item, "poster_path")
        return TMDBCreditTitle(
            tmdbId: String(JSON.int(item, "id")),
            type: type,
            title: JSON.str(item, type == "tv" ? "name" : "title"),
            year: String(dateStr.prefix(4)),
            posterURL: posterPath.isEmpty
                ? "" : "https://image.tmdb.org/t/p/w500" + posterPath,
            character: character)
    }

    /// Idea 20 (actor page): a person's combined filmography —
    /// the "cast" side of /person/{id}/combined_credits,
    /// movies and TV only, deduped by (type, tmdbId) keeping
    /// the first occurrence, sorted by popularity descending.
    /// Fail-soft: [] on no key, a bad id, or a failed call;
    /// cached per personId.
    static func fetchPersonCredits(personId: Int) async -> [TMDBCreditTitle] {
        let key = apiKey
        guard !key.isEmpty, personId > 0 else { return [] }
        cacheLock.lock()
        if let hit = personCreditsCache[personId] {
            cacheLock.unlock(); return hit
        }
        cacheLock.unlock()

        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/person/\(personId)/combined_credits?api_key=\(key)&language=vi-VN",
            timeout: callTimeout)
        else { return [] }

        var seen = Set<String>()
        var scored: [(title: TMDBCreditTitle, popularity: Double)] = []
        for item in JSON.arr(root, "cast") ?? [] {
            let mediaType = JSON.str(item, "media_type")
            guard mediaType == "movie" || mediaType == "tv" else { continue }
            let credit = creditTitle(item, type: mediaType,
                                     character: JSON.str(item, "character"))
            guard seen.insert(credit.id).inserted else { continue }
            scored.append((credit, JSON.double(item, "popularity")))
        }
        let result = scored
            .sorted { $0.popularity > $1.popularity }
            .map { $0.title }
        cacheLock.lock(); personCreditsCache[personId] = result; cacheLock.unlock()
        return result
    }

    /// Idea 21 (franchise strip): the parts of a movie
    /// collection, oldest first (parts with no year last).
    /// Fail-soft: [] on no key, a bad id, or a failed call;
    /// cached per collection id.
    static func fetchCollection(id: Int) async -> [TMDBCreditTitle] {
        let key = apiKey
        guard !key.isEmpty, id > 0 else { return [] }
        cacheLock.lock()
        if let hit = collectionCache[id] {
            cacheLock.unlock(); return hit
        }
        cacheLock.unlock()

        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/collection/\(id)?api_key=\(key)&language=vi-VN",
            timeout: callTimeout)
        else { return [] }

        let result = (JSON.arr(root, "parts") ?? [])
            .map { creditTitle($0, type: "movie", character: "") }
            .sorted { a, b in
                if a.year.isEmpty { return false }
                if b.year.isEmpty { return true }
                return a.year < b.year
            }
        cacheLock.lock(); collectionCache[id] = result; cacheLock.unlock()
        return result
    }
}
