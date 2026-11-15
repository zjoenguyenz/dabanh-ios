/// Bundled TMDB key slot. The committed value is EMPTY on
/// purpose: the owner's real key is injected at build time by
/// the build-joetv workflow from the TMDB_API_KEY Actions
/// secret, so the key never lives in this repository.
/// TMDBClient falls back to this value when no key has been
/// typed in Settings — the owner ordered (2026-11-14) that
/// anything Muse can fill in itself must never be left for
/// him to type, least of all with a TV remote.
enum TMDBBundledKey {
    static let value = ""
}
