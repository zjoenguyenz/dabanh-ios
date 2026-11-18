import Foundation

/// Favourite TV channels — Idea 4 (live-TV channel side only).
///
/// One ordered list of channel keys in UserDefaults
/// ("joetv.tv.favourites.v1", JSON), insertion order = the
/// owner's own order: toggling a channel ON appends its key,
/// toggling OFF removes it. A key is group + "|" + title —
/// stable across playlist refreshes as long as the source
/// keeps the channel's name and group. A key whose channel
/// has vanished from the playlist is hidden by the view,
/// never deleted here, so the favourite returns on its own
/// if the channel comes back. Playlist data itself is never
/// touched. Loading is fail-soft: a missing or corrupt
/// payload loads as empty, never crashes.
final class ChannelFavouritesStore: ObservableObject {
    static let shared = ChannelFavouritesStore()

    /// Ordered favourite keys, insertion order.
    @Published private(set) var keys: [String]

    private static let defaultsKey = "joetv.tv.favourites.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            keys = decoded
        } else {
            keys = []
        }
    }

    static func key(for channel: Channel) -> String {
        channel.group + "|" + channel.title
    }

    func isFavourite(_ channel: Channel) -> Bool {
        keys.contains(Self.key(for: channel))
    }

    func toggle(_ channel: Channel) {
        let key = Self.key(for: channel)
        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
        } else {
            keys.append(key)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
