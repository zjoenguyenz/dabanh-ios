import SwiftUI
import UIKit

@main
struct DaBanhApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PlaylistStore()
    /// The selected theme (theme-mu): classic by default,
    /// persisted in UserDefaults; injected app-wide so the
    /// header pill, the MU surfaces and the player all read
    /// the one selection.
    @StateObject private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(themeStore)
                .preferredColorScheme(.dark)
        }
    }
}

/// Holds the app-wide orientation lock. The player page narrows it to
/// landscape while it is on screen; everything else leaves it open.
/// MainActor-isolated (Swift 6): the lock is UI state, only ever
/// touched from the main actor.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Sets the orientation lock and, when a rotation target is given, asks
/// the active scene to rotate to it (iOS 16+ geometry update; the app
/// targets iOS 17).
@MainActor
enum OrientationHelper {
    static func lock(_ mask: UIInterfaceOrientationMask,
                     rotateTo orientation: UIInterfaceOrientation? = nil) {
        AppDelegate.orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        if orientation != nil {
            scene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            )
        }
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
