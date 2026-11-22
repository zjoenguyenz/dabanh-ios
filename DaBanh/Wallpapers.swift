import Foundation

/// Manchester United background wallpapers for the MU theme
/// (theme-mu, 2026-11-22): the iOS port of the tvOS loader
/// (~/workspace/dabanh-tvos/DaBanh/Wallpapers.swift). The URL
/// list refreshes from the owner's GitHub mirror at launch and
/// is disk-cached — a background is added or dropped by
/// pushing one JSON file, never by rebuilding the app. Mirrors
/// Crests.swift's load / cache / refresh shape.
///
/// iOS difference from the tvOS original: there is NO bundled
/// baseline in this target (the leader's "bundled-none"
/// ruling) — before the first successful refresh the list is
/// empty and the MU surfaces fall back to the design's
/// featured base colour + gradient. Wallpaper entries are
/// remote URLs — no bundle growth.
enum MUWallpapers {

    /// The live-updating copy, republished with the playlist mirror.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/wallpapers.json")!

    private static var cachedRemoteURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpapers-remote.json")
    }

    // MARK: - Payload

    private struct Payload: Codable {
        let teams: [String: Team]
    }

    private struct Team: Codable {
        let name: String?
        let images: [ImageEntry]
    }

    private struct ImageEntry: Codable {
        let url: String
        let w: Int?
        let h: Int?
        let kind: String?
        let source: String?
    }

    /// Decode one payload into the MU image URLs, in file
    /// order. The sanity guard mirrors the tvOS original: a
    /// payload with fewer than 10 MU images is not a real
    /// wallpapers file and is rejected whole.
    private static func decode(_ data: Data) -> [URL]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let team = payload.teams["manchester united"],
              team.images.count >= 10
        else { return nil }
        let urls = team.images.compactMap { URL(string: $0.url) }
        guard urls.count >= 10 else { return nil }
        return urls
    }

    private static func loadURLs() -> [URL] {
        if let data = try? Data(contentsOf: cachedRemoteURL),
           let urls = decode(data) {
            return urls
        }
        return []
    }

    /// The live list, behind a lock box: refreshRemote swaps it
    /// from the main actor while views read it from wherever
    /// they render. (Swift 6 language mode: a bare mutable
    /// static var is not concurrency-safe; the box keeps every
    /// read safe — same pattern as Crests.MapBox and the tvOS
    /// loader's ListBox.)
    private final class ListBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [URL]
        init(_ value: [URL]) { self.value = value }
        func get() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ newValue: [URL]) {
            lock.lock(); value = newValue; lock.unlock()
        }
    }

    private static let listBox = ListBox(loadURLs())

    private(set) static var urls: [URL] {
        get { listBox.get() }
        set { listBox.set(newValue) }
    }

    /// MU image URLs, in file order.
    static func images() -> [URL] {
        urls
    }

    /// The artwork the MU surfaces lead with (the featured
    /// card + the match-detail hero): the viewer's persisted
    /// Hình nền choice (FIX-MU-5, item A — UserDefaults
    /// `dabanh-mu-wallpaper`) when it is set AND still
    /// present in the list, else the shared list's first
    /// image. Nil when no list has loaded yet — the surfaces
    /// then paint the design's fallback (featured base
    /// #261A1C + the featured gradient).
    static func heroImage() -> URL? {
        if let raw = UserDefaults.standard.string(forKey: "dabanh-mu-wallpaper"),
           let chosen = URL(string: raw), urls.contains(chosen) {
            return chosen
        }
        return urls.first
    }

    /// Fetch the mirror's wallpapers.json; when it differs from
    /// what the app is using, cache it for the next launch and
    /// swap it in for this one. Returns true when the list changed.
    @MainActor
    static func refreshRemote() async -> Bool {
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL),
              let fresh = decode(data),
              fresh != urls
        else { return false }
        try? data.write(to: cachedRemoteURL, options: .atomic)
        urls = fresh
        return true
    }
}
