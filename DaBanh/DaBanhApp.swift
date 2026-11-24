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
///
/// FIX-137 (DB-30/FL-402): the geometry update must request the
/// TARGET orientation itself — a mask holding only that one
/// orientation — not the allowed `mask`. The pre-fix code passed
/// `mask`, so `lock(.all, rotateTo: .portrait)` asked the scene to
/// rotate to ".all", which forces nothing: after the player closed
/// the window simply stayed in landscape. The mask for one
/// orientation is `1 << orientation.rawValue` (the documented
/// correspondence: portrait = 2, portraitUpsideDown = 4,
/// landscapeRight = 8, landscapeLeft = 16). Every call is written
/// to the diagnostic log (category "player") — before this fix the
/// orientation path logged nothing at all, so the on-device lock
/// sequence was unobservable.
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
        else {
            DiagLog.log("player",
                        "orientation lock: mask=\(mask.rawValue) "
                        + "rotateTo=\(orientation?.rawValue ?? -1) — no window scene")
            return
        }
        if let orientation, orientation != .unknown {
            let target = UIInterfaceOrientationMask(
                rawValue: 1 << UInt(orientation.rawValue))
            scene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: target)
            )
        }
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        DiagLog.log("player",
                    "orientation lock: mask=\(mask.rawValue) "
                    + "rotateTo=\(orientation?.rawValue ?? -1) "
                    + "now=\(scene.interfaceOrientation.rawValue)")
    }
}
