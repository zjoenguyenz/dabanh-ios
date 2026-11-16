import Foundation
import CryptoKit

/// Disk cache of parsed detail payloads (v2.0.1 — the tvOS
/// expression of the Android v2.3 DetailCache, device-proven
/// on the Sony in §ANDROID-V23-BACKDROP-FIX2).
///
/// One JSON file per film in the caches directory, keyed by
/// the MD5 of "provider|slug", holding an envelope
/// {v: app build number, t: saved-at epoch seconds,
/// d: the full parsed Detail}. A version mismatch is a miss,
/// so no payload ever crosses an app upgrade; the TTL is
/// 24 h; total size is pruned oldest-first to ~8 MB on every
/// write. Fail-soft throughout: any read / parse / write
/// problem is a miss or a skipped write, never an error.
///
/// The flow it serves (JoeMovieDetail.load): on a first open
/// a hit paints the FULL detail immediately; the fresh fetch
/// then runs as a background refresh — repaint only when the
/// payload fingerprint changed, and a failed refresh never
/// errors over the cache-filled screen. Stream URLs are NOT
/// part of the fingerprint and are never trusted from the
/// cache at play time: the player's ladder re-fetches the
/// detail fresh on every tap (the standing fresh-resolution
/// rule), so a cached payload can only ever paint the page.
enum JoeDetailCache {
    private struct Envelope: Codable {
        var v: Int
        var t: Double
        var d: Detail
    }

    private static let ttl: TimeInterval = 24 * 3600
    private static let capBytes = 8 * 1024 * 1024

    private static var appBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private static var directory: URL? {
        guard let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("detailcache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(provider: String, slug: String) -> URL? {
        let digest = Insecure.MD5.hash(data: Data((provider + "|" + slug).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(hex + ".json")
    }

    static func read(provider: String, slug: String) -> Detail? {
        guard let url = fileURL(provider: provider, slug: slug),
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.v == appBuild,
              Date().timeIntervalSince1970 - env.t < ttl
        else { return nil }
        return env.d
    }

    /// Async read (v2.0.8, P7): the existing read's file I/O
    /// + JSONDecoder work runs in a detached task, off the
    /// caller's executor, so a view-driven caller no longer
    /// pays the synchronous decode on its own thread. The
    /// sync read above stays for any other callers; the
    /// envelope, TTL, cap, prune and fingerprint are
    /// untouched.
    static func readAsync(provider: String, slug: String) async -> Detail? {
        await Task.detached {
            JoeDetailCache.read(provider: provider, slug: slug)
        }.value
    }

    static func write(_ detail: Detail, provider: String, slug: String) {
        guard let url = fileURL(provider: provider, slug: slug) else { return }
        let env = Envelope(v: appBuild,
                           t: Date().timeIntervalSince1970, d: detail)
        guard let data = try? JSONEncoder().encode(env) else { return }
        // .atomic writes via a temp file renamed into place.
        guard (try? data.write(to: url, options: .atomic)) != nil
        else { return }
        prune()
    }

    /// Oldest-first prune to the size cap, on every write.
    private static func prune() {
        guard let dir = directory,
              let files = try? FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys:
                    [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for f in files {
            let values = try? f.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            entries.append((f, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        if total <= capBytes { return }
        for entry in entries.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= capBytes { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    /// Fingerprint of everything the detail screen renders or
    /// playback identity keys on (the Android samePayload
    /// rule): all movie fields, content, metaLine, categories,
    /// server names and episode NAMES. Stream URLs (m3u8 /
    /// embed) are deliberately EXCLUDED — they rotate between
    /// fetches without the film changing, and repainting on
    /// every rotation would flicker for nothing.
    static func fingerprint(_ d: Detail) -> String {
        let m = d.movie
        var parts: [String] = [
            m.provider, m.slug, m.name, m.originName, m.poster, m.thumb,
            m.year, m.type, m.episodeCurrent, m.quality, m.lang,
            m.categories.joined(separator: ","),
            m.country, m.time, m.episodeTotal, String(m.chieurap),
            m.imdbId, m.tmdbId, m.tmdbType, String(m.tmdbSeason),
            d.content, d.metaLine, d.categories
        ]
        for s in d.servers {
            parts.append(s.name)
            parts.append(contentsOf: s.episodes.map { $0.name })
        }
        return parts.joined(separator: "\u{1}")
    }
}
