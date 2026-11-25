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
///
/// FIX-139: the supported-orientations set must be updated
/// BEFORE the geometry request (Apple TN3192). The pre-fix
/// code called `requestGeometryUpdate` first and
/// `setNeedsUpdateOfSupportedInterfaceOrientations()` only
/// afterwards, so at player exit the system still held the
/// `.landscape` supported set and the FIX-137 portrait-only
/// geometry request was rejected. That rejection was also
/// invisible: no `errorHandler` was passed, so the failure
/// left no trace in the log. The set update now runs first
/// (and still runs when no rotation target is given, for a
/// mask-only change), and an `errorHandler` writes any
/// rejection to the diagnostic log (category "player").
@MainActor
enum OrientationHelper {
    /// FIX-147 (R2): bumped by every lock — a deferred
    /// request (lockWhenSettled) that finds a newer lock
    /// has been made since never acts.
    private static var lockGeneration = 0

    static func lock(_ mask: UIInterfaceOrientationMask,
                     rotateTo orientation: UIInterfaceOrientation? = nil) {
        lockGeneration += 1
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
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        if let orientation, orientation != .unknown {
            let target = UIInterfaceOrientationMask(
                rawValue: 1 << UInt(orientation.rawValue))
            scene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: target)
            ) { error in
                DiagLog.log("player",
                            "orientation geometry update rejected: \(error)")
            }
        }
        DiagLog.log("player",
                    "orientation lock: mask=\(mask.rawValue) "
                    + "rotateTo=\(orientation?.rawValue ?? -1) "
                    + "now=\(scene.interfaceOrientation.rawValue)")
    }
    /// FIX-147 (R2, Finding 3) — the MU close path's
    /// portrait request, for the two ContentView points
    /// that end a player surface (the cover's onDismiss
    /// and the route-to-nil branch).
    ///
    /// A geometry request is judged against the TOPMOST
    /// presented controller, and while a presentation
    /// transition is in flight the supported set collapses
    /// to the current orientation — the convicted
    /// "Requested: portrait; Supported: landscapeRight"
    /// rejection, issued from inside a route/surface-driven
    /// teardown while the fullscreen hosting (or the cover)
    /// was still being dismissed. So:
    ///   1. the mask widens NOW, exactly as lock() does
    ///      (lock(mask) — no rotation target yet);
    ///   2. the rotation request is issued only once no
    ///      controller in the window's presentation chain
    ///      is being presented or dismissed: each in-flight
    ///      transition is waited out on its own
    ///      coordinator's completion (or the next main-
    ///      queue turn for an unanimated one), at most 6
    ///      hops, then the request goes out regardless (and
    ///      says so);
    ///   3. a window already in the target orientation gets
    ///      no request at all (there is nothing to turn);
    ///   4. a newer lock() made in the meantime (a player
    ///      re-opened) cancels it.
    /// One-shot per call; no periodic work.
    static func lockWhenSettled(_ mask: UIInterfaceOrientationMask,
                                rotateTo orientation: UIInterfaceOrientation,
                                reason: String) {
        lock(mask)
        let generation = lockGeneration
        DispatchQueue.main.async {
            settledAttempt(mask, orientation, reason, generation, hop: 0)
        }
    }

    private static func settledAttempt(_ mask: UIInterfaceOrientationMask,
                                       _ orientation: UIInterfaceOrientation,
                                       _ reason: String,
                                       _ generation: Int,
                                       hop: Int) {
        guard generation == lockGeneration else {
            DiagLog.log("player",
                        "orientation settled request (\(reason)): superseded by a newer lock — dropped")
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        if scene.interfaceOrientation == orientation {
            DiagLog.log("player",
                        "orientation settled request (\(reason)): already "
                        + "\(orientation.rawValue) — no request")
            return
        }
        var inFlight: UIViewController?
        var vc = scene.keyWindow?.rootViewController
        while let current = vc {
            if current.isBeingPresented || current.isBeingDismissed
                || current.transitionCoordinator != nil {
                inFlight = current
                break
            }
            vc = current.presentedViewController
        }
        if let busy = inFlight, hop < 6 {
            let next = {
                DispatchQueue.main.async {
                    settledAttempt(mask, orientation, reason, generation, hop: hop + 1)
                }
            }
            DiagLog.log("player",
                        "orientation settled request (\(reason)): waiting out "
                        + "\(type(of: busy))'s transition (hop \(hop))")
            if let coordinator = busy.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { _ in next() }
            } else {
                next()
            }
            return
        }
        if inFlight != nil {
            DiagLog.log("player",
                        "orientation settled request (\(reason)): still in flight "
                        + "after 6 hops — requesting anyway")
        }
        lock(mask, rotateTo: orientation)
    }
}
