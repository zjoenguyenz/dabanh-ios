import SwiftUI

/// The general TV app for Apple TV — companion to the Đá Banh TV app, fed by
/// the owner's merged, self-updating playlist. Its design language is
/// deliberately different from the football app (warm cinema guide:
/// espresso palette, amber accents, group sidebar + logo grid) so the
/// two apps are never confused; only the player is shared.
@main
struct TVApp: App {
    @StateObject private var store = TVStore()

    var body: some Scene {
        WindowGroup {
            TVHomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
