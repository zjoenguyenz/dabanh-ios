import Foundation

/// One TMDB cast entry for the detail screen's "Diễn viên" row.
struct TMDBCastMember: Identifiable {
    var id: Int
    var name: String
    var character: String
    var photoURL: String
}

/// The TMDB enrichment for one title: a wide backdrop, a
/// (Vietnamese) overview and the top-billed cast. Every field is
/// optional in effect — an empty value simply means the detail
/// screen keeps using the provider's own art and text.
struct TMDBInfo {
    var backdropURL: String = ""
    var overview: String = ""
    var cast: [TMDBCastMember] = []
}

/// Minimal TMDB client for the optional enrichment on the movie
/// detail screen. The API key is the owner's own, stored in
/// UserDefaults under "tmdb_api_key" (set in Settings); with no
/// key the client is inert and the detail screen is exactly the
/// provider-only v1.5 screen. Fully fail-soft: no throws, a
/// failed credits call keeps the detail data already fetched,
/// and only a failed detail call returns nil.
enum TMDBClient {
    static var apiKey: String {
        let saved = (UserDefaults.standard.string(forKey: "tmdb_api_key") ?? "")
            .trimmingCharacters(in: .whitespaces)
        // A key typed in Settings wins; otherwise the bundled
        // key injected at build time (TMDBBundledKey) is used,
        // so a fresh install has TMDB art with zero typing.
        return saved.isEmpty ? TMDBBundledKey.value : saved
    }

    static func fetch(tmdbId: String, type: String) async -> TMDBInfo? {
        let key = apiKey
        guard !key.isEmpty, !tmdbId.isEmpty else { return nil }
        let kind = (type == "tv") ? "tv" : "movie"

        guard let root = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)?api_key=\(key)&language=vi-VN")
        else { return nil }

        var info = TMDBInfo()
        let backdropPath = JSON.str(root, "backdrop_path")
        if !backdropPath.isEmpty {
            info.backdropURL = "https://image.tmdb.org/t/p/w1280" + backdropPath
        }
        info.overview = JSON.str(root, "overview")

        if let credits = try? await JoeHTTP.getJSON(
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)/credits?api_key=\(key)") {
            info.cast = (JSON.arr(credits, "cast") ?? []).prefix(12).map { member in
                let profilePath = JSON.str(member, "profile_path")
                return TMDBCastMember(
                    id: JSON.int(member, "id"),
                    name: JSON.str(member, "name"),
                    character: JSON.str(member, "character"),
                    photoURL: profilePath.isEmpty
                        ? "" : "https://image.tmdb.org/t/p/w185" + profilePath)
            }
        }
        return info
    }
}
