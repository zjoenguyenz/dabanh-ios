import SwiftUI

/// The general TV app for Apple TV — companion to the Đá Banh TV app, fed by
/// the owner's merged, self-updating playlist. Same launcher design language:
/// dark teal glass, group rails, native tvOS player.
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
