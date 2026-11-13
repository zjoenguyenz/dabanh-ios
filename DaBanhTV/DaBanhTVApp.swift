import SwiftUI

/// Đá Banh for Apple TV (tvOS). Shares the playlist engine with the iOS app
/// (Channel / M3UParser / LeagueClassifier / PlaylistStore); only the shell
/// and the views are tvOS-specific (focus navigation with the Siri Remote).
@main
struct DaBanhTVApp: App {
    @StateObject private var store = PlaylistStore()

    var body: some Scene {
        WindowGroup {
            TVContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
