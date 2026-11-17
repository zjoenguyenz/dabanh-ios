/// Bundled TMDB key slot for the Top Shelf extension. The
/// committed value is EMPTY on purpose: the owner's real key
/// is injected at build time by the build-joetv workflow from
/// the TMDB_API_KEY Actions secret (the same secret that fills
/// the app target's TMDBKey.swift — the extension is a separate
/// target and cannot see that file, so it carries its own
/// slot). The key never lives in this repository. With an
/// empty value the extension's fallback simply stays inert,
/// exactly like TMDBClient in the app.
enum TMDBShelfKey {
    static let value = ""
}
