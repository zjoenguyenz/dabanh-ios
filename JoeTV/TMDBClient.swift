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
            "https://api.themoviedb.org/3/\(kind)/\(tmdbId)/external_ids?api_key=\(key)")
        else { return nil }
        let id = JSON.str(root, "imdb_id")
        return id.isEmpty ? nil : id
    }
}
