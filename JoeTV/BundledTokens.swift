/// Bundled debrid token slots. The committed values are
/// EMPTY on purpose: the owner's real tokens are injected
/// at build time by the build-joetv workflow from the
/// RD_TOKEN, TORBOX_TOKEN and PREMIUMIZE_TOKEN Actions
/// secrets, so the tokens never live in this repository.
/// TorrentSettings falls back to these values when no token
/// has been typed in Settings — the owner ordered
/// (2026-11-14, extended 2026-11-16) that anything Muse
/// can fill in itself must never be left for him to type,
/// least of all with a TV remote, and never re-typed after
/// a reinstall. Premiumize joined as the third resolver on
/// the owner's order of 2026-11-16.
enum BundledTokens {
    static let rdToken = ""
    static let torboxToken = ""
    static let premiumizeToken = ""
}
