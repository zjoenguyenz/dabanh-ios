import AVFoundation
import AVKit
import UIKit

/// The data the MU player chrome paints (theme-mu): the
/// playing channel's name + commentary note, and — for a
/// fixture playback — the fixture's teams, crests, score and
/// clock, all from the SAME MatchState the boards show.
/// Computed by PlayerView from its live header entry; nil
/// fields simply hide their element (a 24/7 channel play has
/// no score chip, an unscored fixture shows "VS").
struct MUPlayerInfo {
    var channelName: String
    var channelNote: String
    var homeName: String?
    var awayName: String?
    var homeCrest: URL?
    var awayCrest: URL?
    var scoreText: String?
    var clockText: String?
    var isLive: Bool
    var leagueText: String?
    var titleText: String
    var statusText: String?
}

/// sRGB colour from a 0xRRGGBB token (the UIKit twin of
/// MatchViews.boardColor).
private func muUIColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// The UIKit rendering of MURawPalette.current (FIX-MU-5,
/// item G): the same raw table MUTokens renders, so the
/// player chrome follows the active MU palette (drawing /
/// MU Wally) exactly as the SwiftUI surfaces do. Computed
/// per access; the chrome is built once per presentation
/// and the theme cannot change while it is up.
private enum MUUIColor {
    static var bg: UIColor { muUIColor(MURawPalette.current.bg) }
    static var card: UIColor { muUIColor(MURawPalette.current.card) }
    static var red: UIColor { muUIColor(MURawPalette.current.red) }
    static var gold: UIColor { muUIColor(MURawPalette.current.gold) }
    static var cream: UIColor { muUIColor(MURawPalette.current.cream) }
    static var scoreBright: UIColor { muUIColor(MURawPalette.current.scoreBright) }
    static var secondary: UIColor { muUIColor(MURawPalette.current.secondary) }
    static var border: UIColor {
        muUIColor(MURawPalette.current.border,
                  alpha: CGFloat(MURawPalette.current.borderAlpha))
    }
    static var selectedFill: UIColor { muUIColor(MURawPalette.current.selectedFill) }
    static var panelAlt: UIColor { muUIColor(MURawPalette.current.panelAlt) }
}

/// The MU chrome's view refs, held by the view controller in
/// one box (extensions cannot add stored properties).
/// @MainActor (FIX-MU-4): every stored view is created by a
/// main-actor-isolated UIKit initializer, so the box itself
/// is main-actor isolated — it is built and touched only
/// from LivePlayerViewController (a UIViewController, hence
/// main-actor) methods and handlers.
@MainActor
final class MUChromeViews {
    let nameLabel = UILabel()
    let noteLabel = UILabel()
    let miniScore = UIView()
    let miniHomeCrest = UIImageView()
    let miniHomeAbbr = UILabel()
    let miniAwayAbbr = UILabel()
    let miniScoreLabel = UILabel()
    let miniClock = UILabel()
    var homeCrestURL: URL?
    let rewindButton = UIButton(type: .system)
    let volumeButton = UIButton(type: .system)
    let livePill = UIView()
    let livePillLabel = UILabel()
    /// The pill's leading dot as a real 4×4 view (FIX-133,
    /// audit A15) — it was a bullet text glyph, which is
    /// neither 4×4 nor separated by the drawn 5 pt gap.
    let livePillDot = UIView()
    let leagueLabel = UILabel()
    let titleLabel = UILabel()
    let statusLabel = UILabel()
    let timeLabel = UILabel()
    let liveStateLabel = UILabel()
    /// The broadcast glyph before "Đang ở LIVE" (#137).
    let liveStateIcon = UIImageView()
    /// The invisible 44 pt hit target over the icon +
    /// "Đang ở LIVE" label (FIX-133, audit B29): the drawn
    /// element was a passive label; the spec's timeline row
    /// carries a 44-high LIVE action that returns playback
    /// to the live edge.
    let liveStateButton = UIButton(type: .system)
    let progressTrack = UIView()
    let progressFill = UIView()
    let progressKnob = UIView()
    let qualityButton = UIButton(type: .system)
    let audioButton = UIButton(type: .system)
    let fillButton = UIButton(type: .system)
    let moreButton = UIButton(type: .system)
    let sourceLabel = UILabel()
    let allSourcesButton = UIButton(type: .system)
    let chipsScroll = UIScrollView()
    let chipsStack = UIStackView()
    /// The portrait page's footer hint (FIX-MU-3, finding
    /// 7): plain 9 pt text under the chips row, min-height
    /// 30. Portrait only — hidden in the landscape layout.
    let footerLabel = UILabel()
    /// The orientation the chips were last built for
    /// (FIX-MU-3, finding 9): chip font is 11 portrait /
    /// 10 landscape, so a rotation rebuilds the chips.
    var landscape = false
    /// FIX-141: a rotation transition (viewWillTransition)
    /// is in flight for this chrome. Set by the view
    /// controller's transition override in PlayerView.swift,
    /// read by muToggleFullscreen, and cleared in the
    /// transition's completion. FIX-142: the completion
    /// now does bookkeeping only (the settle layout pass
    /// is deleted), and a toggle fired mid-transition is
    /// no longer dropped — it flips pendingToggle below.
    var transitionInFlight = false
    /// FIX-142: the pending-toggle parity bit. A
    /// fullscreen toggle fired while a rotation
    /// transition is in flight flips this bit instead of
    /// being dropped (FIX-141's coalescing ate genuine
    /// taps, DIAG-142); when the transition settles, the
    /// completion runs ONE fresh toggle if the bit is
    /// set. Two mid-flight taps cancel out (parity, not
    /// a counter), so geometry requests never stack
    /// (DIAG-140's disease) and no tap is ever eaten.
    var pendingToggle = false
    /// FIX-141: the last (page, size) pair layoutMUChrome
    /// wrote to DiagLog — layout passes log only when the
    /// chosen page or the size used changes, so the strip
    /// class (DIAG-140 §4.4) becomes observable without a
    /// line per pass.
    var lastLoggedLayoutPage: String?
    var lastLoggedLayoutSize: CGSize?
    /// FIX-143: the orientation the PRESENTATION layer
    /// (fonts + kern, chip spacing + rebuild, scrim /
    /// footer / source-label visibility) was last applied
    /// for — true = landscape, false = portrait, nil =
    /// never applied. While a rotation transition is in
    /// flight the presentation is DEFERRED (the elements
    /// ride the turn at their old presentation — DIAG-143
    /// Option B); finishMURotation applies it at settle,
    /// where this flag is compared against the settled
    /// page. Deliberately separate from `landscape` above:
    /// that flag is the GEOMETRY page and follows the live
    /// bounds on every pass, in flight or not.
    var presentationLandscape: Bool?
    /// FIX-143: a chip rebuild was requested while a
    /// transition was in flight (a content refresh) and
    /// deferred — chips are never rebuilt mid-flight
    /// (DIAG-143 §2.3); the settle presentation honours
    /// this bit even when the page itself did not change.
    var chipsDirty = false
    /// FIX-143 (§3.1): layout passes counted while a
    /// transition is in flight — reset by
    /// viewWillTransition, incremented per in-flight pass
    /// by layoutMUChrome; the per-pass in-flight log line
    /// carries the count as its pass index.
    var inFlightPassCount = 0
    /// FIX-144 (Option A): the fullscreen presentation's
    /// scratch state for THIS surface — where the player
    /// view lived in the SwiftUI host before it was moved
    /// into the presented fullscreen controller, so the
    /// dismissal can restore it exactly (KSPlayer's
    /// originalSuperView / originalFrame pair; the view
    /// is frame-based in the host, so there are no
    /// constraints to save — SwiftUI owns that layout and
    /// re-asserts it on its next pass regardless).
    weak var hostOriginalSuperview: UIView?
    var hostOriginalIndex = 0
    var hostOriginalFrame: CGRect = .zero
    /// FIX-144 gate Round 1 (F-A3): the view's
    /// autoresizing mask in the host slot — ENTER sets
    /// the flexible mask the fullscreen fill needs, so
    /// the slot's own mask is part of what the dismissal
    /// (and the present-refusal rollback) restores.
    var hostOriginalAutoresizingMask: UIView.AutoresizingMask = []
    /// FIX-144 gate Round 1 (B-4): teardown landed
    /// while THIS surface's own fullscreen flight was
    /// still driving — the release is deferred, not
    /// executed against a running transition, and the
    /// flight's completion services it (see
    /// releaseMUFullscreenHostingForTeardown).
    var releasePendingAfterFlight = false
    /// FIX-144: a fullscreen presentation / dismissal
    /// driven by the toggle is in flight and OWNS the
    /// turn — it set transitionInFlight above, and its
    /// completion calls finishMURotation. While this is
    /// set, viewWillTransition (which still fires: the
    /// window rotates under the presentation) must not
    /// run a second, competing settle for the same turn.
    var fullscreenDriving = false
    /// FIX-144: "Tất cả nguồn" was tapped while the
    /// fullscreen presentation was up — the SwiftUI
    /// board sheet stacks on the cover, UNDER the
    /// presentation, so the tap exits fullscreen first
    /// and the dismissal's completion opens the board
    /// once the player view is home. A fresh enter
    /// (a parity-serviced toggle) cancels the request.
    var openBoardAfterExit = false
    let scrimTop = UIView()
    let scrimBottom = UIView()
    var chipButtons: [UIButton] = []
}

/// DB-20 (FIX-134): whether the MU player is currently in
/// its button-driven fullscreen state — entered via the
/// fullscreen action below, which narrows the orientation
/// lock to landscape until the user exits fullscreen again.
/// The MU baseline stays free rotation (lock .all); this
/// flag is the ONLY record of the temporary narrowing, and
/// ContentView reads it on a player-route change so an
/// in-place Đổi nguồn swap re-asserts the landscape lock
/// instead of silently dropping it back to .all.
/// @MainActor, like MUChromeViews and OrientationHelper:
/// it is written only from the player view controller's
/// handlers and read/written only from ContentView's
/// main-actor SwiftUI closures — no cross-actor access, so
/// no data race is possible under Swift 6.
@MainActor
enum MUFullscreenState {
    static var isActive = false
    /// FIX-144 (Option A): the live fullscreen
    /// presentation, if one is up — the controller the
    /// toggle's ENTER decision presented and the EXIT
    /// decision dismisses, and the controller a successor
    /// surface (an in-place source swap replaces the
    /// player VC wholesale) adopts instead of presenting
    /// a second one. Weak: the presentation itself keeps
    /// the controller alive; these records must never
    /// resurrect a dead one.
    static weak var presentedController: MUFullscreenViewController?
    /// FIX-144: the surface currently hosted inside the
    /// presented controller — identity-checked by the
    /// teardown release and the successor adoption, so
    /// the two are order-independent.
    static weak var hostedController: LivePlayerViewController?
}

/// FIX-144 (Option A): the presented fullscreen
/// controller — KSPlayer's PlayerFullScreenViewController
/// mapped onto this app. It exists to OWN the fullscreen
/// transition: the whole existing player view is moved
/// into it, and the interface rotation becomes the
/// presentation's own rotation instead of an in-place
/// rotation of the page hosting the player (DIAG-144).
/// It declares the landscape orientation itself (the
/// decision's OrientationHelper.lock has already narrowed
/// the app-wide mask to match — the two agree by
/// construction); KSPlayer's controller returns `.all`
/// and lets its global carry the narrowing, which is the
/// one deliberate mapping difference, noted here.
final class MUFullscreenViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { false }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

/// FIX-144 (Option A): the transition animator — a
/// transcription of KSPlayer's PlayerTransitionAnimator
/// (Sources/KSPlayerUI/View/PlayerTransitionAnimator.swift,
/// read first-hand at the DIAG-143 study's commit), mapped
/// onto this app's frame-based player view:
/// - KSPlayer's player view is constraint-managed; it
///   captures and reactivates the view's frame constraints
///   around the flight. This app's player view is
///   frame-based inside the SwiftUI host and inside the
///   fullscreen controller (frame + flexible autoresizing),
///   so there are no app-owned constraints to capture —
///   those branches are omitted, and the restore below is
///   the superview + index restore only.
/// - KSPlayer computes the flight's start centre from the
///   original superview's centre in window coordinates,
///   re-expressed through a `reverse` point flip when the
///   from-controller's view carries the rotation
///   transform. That flip's body lives in KSPlayer's core
///   module, distributed as a binary framework — not
///   public source, so it is NOT transcribed blind. It is
///   also unnecessary here: this player view FILLS its
///   original superview (the surface fills the cover), so
///   the point in question is the screen centre, which a
///   quarter-turn maps to the transition container's
///   centre under either flip formula. The centre logic
///   below substitutes the container's centre for the
///   flipped point — provably the same value for a
///   full-bleed view.
/// - Where KSPlayer's guard on the from-controller's
///   transform returns without completing the transition
///   (a wedged presentation if the controller were ever
///   missing), this transcription falls back to identity
///   so the transition always completes.
/// The duration is 0.25 s (DIAG-144 §3's "~0.25 s class",
/// inside §4's ≤0.30 s criterion; KSPlayer uses 0.3 s) and
/// the curve is KSPlayer's easeInOut. During the flight
/// the ONE moving object is the player view, driven by
/// transform + center only — no layout pass is animated;
/// the layout inside it happened once, at the final
/// bounds, before the flight (see animateTransition).
final class MUFullscreenTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isDismiss: Bool
    private let originalSuperview: UIView
    private let animationView: UIView
    private let fromCenter: CGPoint
    /// FIX-144 gate Round 1 (B-3): the surface that
    /// owns the flying view, held weakly. A source swap
    /// landing INSIDE the 0.25 s flight tears that
    /// surface down; the completion must then NOT put
    /// its view back into the live presentation (the
    /// successor's adopted view is what belongs there).
    private weak var owner: LivePlayerViewController?

    init(originalSuperview: UIView, animationView: UIView, isDismiss: Bool = false,
         owner: LivePlayerViewController? = nil) {
        self.originalSuperview = originalSuperview
        self.animationView = animationView
        self.isDismiss = isDismiss
        self.owner = owner
        fromCenter = originalSuperview.superview?.convert(originalSuperview.center, to: nil) ?? .zero
        super.init()
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.25
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let animationSuperView = animationView.superview
        let animationViewIndex = animationSuperView?.subviews.firstIndex(of: animationView) ?? 0
        let initSize = animationView.frame.size
        guard let presentedView = transitionContext.view(forKey: isDismiss ? .from : .to) else {
            // FIX-144 gate Round 1 (B-1): a transition
            // that is never completed wedges UIKit AND
            // both hosting flags (no present/dismiss
            // completion ever fires to clear them). The
            // transition ALWAYS completes — as failed,
            // so UIKit restores the pre-transition state
            // and the hosting completions still run.
            transitionContext.completeTransition(false)
            return
        }
        if isDismiss {
            originalSuperview.layoutIfNeeded()
            presentedView.bounds = originalSuperview.bounds
            presentedView.removeFromSuperview()
        } else {
            if let viewController = transitionContext.viewController(forKey: .to) {
                presentedView.frame = transitionContext.finalFrame(for: viewController)
            }
        }
        presentedView.layoutIfNeeded()
        transitionContext.containerView.addSubview(animationView)
        animationView.translatesAutoresizingMaskIntoConstraints = true
        let transform = transitionContext.viewController(forKey: .from)?.view.transform ?? .identity
        animationView.transform = CGAffineTransform(
            scaleX: initSize.width / animationView.frame.size.width,
            y: initSize.height / animationView.frame.size.height)
            .concatenating(transform)
        let toCenter = transitionContext.containerView.center
        let startCenter = transform == .identity ? fromCenter : toCenter
        animationView.center = isDismiss ? toCenter : startCenter
        UIView.animate(withDuration: transitionDuration(using: transitionContext),
                       delay: 0, options: .curveEaseInOut) {
            self.animationView.transform = .identity
            self.animationView.center = self.isDismiss ? startCenter : toCenter
        } completion: { _ in
            // FIX-144 gate Round 1 (B-1/B-3): honour a
            // cancelled transition, and re-insert the
            // flying view into its flight superview ONLY
            // if the surface that owns it is still alive
            // and not torn down — a mid-flight source
            // swap must not resurrect the dead surface's
            // view into the presentation the successor
            // has adopted.
            let cancelled = transitionContext.transitionWasCancelled
            let ownerLive = self.owner.map { owner in !owner.isTorn } ?? false
            if !cancelled, ownerLive {
                animationSuperView?.insertSubview(self.animationView, at: animationViewIndex)
            }
            if !self.isDismiss, !cancelled {
                transitionContext.containerView.addSubview(presentedView)
            }
            transitionContext.completeTransition(!cancelled)
        }
    }
}

/// The Manchester United player chrome (theme-mu): the
/// design's player pages, built inside the EXISTING live
/// player view controller when the MU theme is active. The
/// portrait layout is the design's page (channel header,
/// mini-score chip, the video block, then the title / time /
/// toolbar / source block below it); the landscape layout is
/// the design's full-bleed cover. ALL playback machinery —
/// the player, its observations, the stall watchdog, the
/// failover callbacks, the 3.0 s pause-aware auto-hide — is
/// the classic surface's own, shared untouched: this file
/// only builds and lays out a different control layer inside
/// the same fading controlsView.
extension LivePlayerViewController {

    // MARK: - Build

    func buildMUControls(channel: Channel) {
        // The MU portrait page paints on ink, not pure black
        // (the landscape page is covered by the video itself).
        view.backgroundColor = MUUIColor.bg
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controlsView)

        let mu = MUChromeViews()
        muChrome = mu

        // Close: 48×48 circle, gold 1 pt ring, ALWAYS top
        // right (deviation G-5 — the MU spec's size; classic
        // keeps its 52 pt button on its own path).
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = MUUIColor.cream
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        closeButton.layer.cornerRadius = 24
        closeButton.layer.borderWidth = 1
        closeButton.layer.borderColor = MUUIColor.gold.cgColor
        closeButton.accessibilityLabel = "Đóng"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        controlsView.addSubview(closeButton)

        // Centre play/pause: the design's cream disc with an
        // ink glyph (64 portrait / 56 landscape — the frame
        // and radius are set in layoutMUChrome). FIX-MU-5
        // (#128): the transport glyph sizes are the spec's —
        // play 28, rewind 22, volume 23 — applied as the
        // preferred symbol configuration of the buttons'
        // IMAGE VIEWS, so the size survives the shared
        // code's play/pause image swaps (a plain setImage
        // would reset a configuration baked into the image).
        // FIX-MU-6: the configuration lives on the image
        // view — UIButton has no such member (run #84).
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.imageView?.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 28)
        playPauseButton.tintColor = MUUIColor.bg
        playPauseButton.backgroundColor = MUUIColor.cream
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        controlsView.addSubview(playPauseButton)

        // Landscape scrims (hidden in the portrait layout).
        for scrim in [mu.scrimTop, mu.scrimBottom] {
            scrim.isUserInteractionEnabled = false
            controlsView.addSubview(scrim)
        }
        let topGradient = CAGradientLayer()
        topGradient.colors = [UIColor.black.withAlphaComponent(0.55).cgColor,
                              UIColor.clear.cgColor]
        topGradient.name = "muScrimTop"
        mu.scrimTop.layer.addSublayer(topGradient)
        let bottomGradient = CAGradientLayer()
        bottomGradient.colors = [UIColor.clear.cgColor,
                                 UIColor.black.withAlphaComponent(0.65).cgColor]
        bottomGradient.name = "muScrimBottom"
        mu.scrimBottom.layer.addSublayer(bottomGradient)

        // Header: channel name + the quality/commentary note.
        mu.nameLabel.font = MUFont.uiBody(17, .semibold)
        mu.nameLabel.textColor = MUUIColor.cream
        mu.nameLabel.lineBreakMode = .byTruncatingTail
        controlsView.addSubview(mu.nameLabel)
        mu.noteLabel.font = MUFont.uiBody(10)
        // FIX-MU-5 (#118): the note wears gold (the audit's
        // reading of the drawing), in both orientations.
        mu.noteLabel.textColor = MUUIColor.gold
        mu.noteLabel.lineBreakMode = .byTruncatingTail
        controlsView.addSubview(mu.noteLabel)

        // Mini-score chip.
        mu.miniScore.backgroundColor = MUUIColor.card
        mu.miniScore.layer.cornerRadius = 6
        mu.miniScore.layer.borderWidth = 1
        mu.miniScore.layer.borderColor = MUUIColor.border.cgColor
        controlsView.addSubview(mu.miniScore)
        // FIX-MU-5 (#122): the mini-score chip carries the
        // HOME crest only — the away crest is not drawn.
        for crest in [mu.miniHomeCrest] {
            crest.contentMode = .scaleAspectFit
            mu.miniScore.addSubview(crest)
        }
        for abbr in [mu.miniHomeAbbr, mu.miniAwayAbbr] {
            abbr.font = MUFont.uiBody(11, .semibold)
            abbr.textColor = MUUIColor.cream
            mu.miniScore.addSubview(abbr)
        }
        // FIX-MU-5 (#123): the score label is semibold (600).
        mu.miniScoreLabel.font = MUFont.uiBody(11, .semibold)
        mu.miniScoreLabel.textColor = MUUIColor.bg
        mu.miniScoreLabel.backgroundColor = MUUIColor.cream
        mu.miniScoreLabel.textAlignment = .center
        mu.miniScoreLabel.layer.cornerRadius = 3
        mu.miniScoreLabel.clipsToBounds = true
        mu.miniScore.addSubview(mu.miniScoreLabel)
        mu.miniClock.font = MUFont.uiBody(11, .semibold)
        mu.miniClock.textColor = MUUIColor.gold
        mu.miniScore.addSubview(mu.miniClock)

        // Transport side buttons: dark translucent discs.
        for (button, icon, label) in [
            (mu.rewindButton, "gobackward.10", "Tua lại 10 giây"),
            (mu.volumeButton, "speaker.wave.2.fill", "Tắt / bật tiếng"),
        ] {
            button.setImage(UIImage(systemName: icon), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            button.layer.cornerRadius = 22
            button.accessibilityLabel = label
            controlsView.addSubview(button)
        }
        mu.rewindButton.addTarget(self, action: #selector(muRewindTapped), for: .touchUpInside)
        mu.volumeButton.addTarget(self, action: #selector(muVolumeTapped), for: .touchUpInside)
        // FIX-MU-5 (#128): the spec's transport glyph sizes
        // (rewind 22, volume 23) as preferred symbol
        // configurations on the buttons' image views
        // (FIX-MU-6 — UIButton itself has no such member;
        // the image view's configuration survives the
        // shared code's mute/volume image swaps).
        mu.rewindButton.imageView?.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 22)
        mu.volumeButton.imageView?.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 23)

        // Lower block: LIVE pill + league eyebrow, title,
        // status, time row, progress, toolbar, sources.
        mu.livePill.backgroundColor = MUUIColor.red
        mu.livePill.layer.cornerRadius = 6
        controlsView.addSubview(mu.livePill)
        mu.livePillLabel.font = MUFont.uiBody(10, .bold)
        mu.livePillLabel.textColor = MUUIColor.cream
        mu.livePillLabel.text = "LIVE"
        mu.livePill.addSubview(mu.livePillLabel)
        // FIX-133 (A15): the drawn dot — 4×4, cream, with a
        // 5 pt gap to the label (laid out in
        // layoutEyebrowRow).
        mu.livePillDot.backgroundColor = MUUIColor.cream
        mu.livePillDot.layer.cornerRadius = 2
        mu.livePill.addSubview(mu.livePillDot)
        mu.leagueLabel.font = MUFont.uiBody(10, .semibold)
        mu.leagueLabel.textColor = MUUIColor.gold
        controlsView.addSubview(mu.leagueLabel)
        mu.titleLabel.font = MUFont.uiDisplay(32)
        mu.titleLabel.textColor = MUUIColor.scoreBright
        mu.titleLabel.lineBreakMode = .byTruncatingTail
        mu.titleLabel.adjustsFontSizeToFitWidth = true
        mu.titleLabel.minimumScaleFactor = 0.6
        controlsView.addSubview(mu.titleLabel)
        mu.statusLabel.font = MUFont.uiBody(11)
        mu.statusLabel.textColor = MUUIColor.secondary
        mu.statusLabel.lineBreakMode = .byTruncatingTail
        controlsView.addSubview(mu.statusLabel)
        mu.timeLabel.font = MUFont.uiBody(10)
        mu.timeLabel.textColor = MUUIColor.secondary
        controlsView.addSubview(mu.timeLabel)
        mu.liveStateLabel.font = MUFont.uiBody(10, .medium)
        mu.liveStateLabel.textColor = MUUIColor.cream
        controlsView.addSubview(mu.liveStateLabel)
        // FIX-MU-5 (#137): the broadcast glyph sits before
        // "Đang ở LIVE", tinted with the label.
        mu.liveStateIcon.image = UIImage(
            systemName: "antenna.radiowaves.left.and.right")
        mu.liveStateIcon.tintColor = MUUIColor.cream
        mu.liveStateIcon.contentMode = .scaleAspectFit
        mu.liveStateIcon.isHidden = true
        controlsView.addSubview(mu.liveStateIcon)
        // FIX-133 (B29): the LIVE action's hit target —
        // transparent, framed over the icon + label in
        // layoutTimeRow, hidden unless the surface is live
        // (refreshMUChrome drives it).
        mu.liveStateButton.accessibilityLabel = "Về trực tiếp"
        mu.liveStateButton.addTarget(self, action: #selector(muLiveEdgeTapped), for: .touchUpInside)
        mu.liveStateButton.isHidden = true
        controlsView.addSubview(mu.liveStateButton)
        mu.progressTrack.backgroundColor = MUUIColor.border
        mu.progressTrack.layer.cornerRadius = 2
        controlsView.addSubview(mu.progressTrack)
        mu.progressFill.backgroundColor = MUUIColor.red
        mu.progressFill.layer.cornerRadius = 2
        controlsView.addSubview(mu.progressFill)
        mu.progressKnob.backgroundColor = MUUIColor.red
        mu.progressKnob.layer.cornerRadius = 6
        controlsView.addSubview(mu.progressKnob)

        configureMUChip(mu.qualityButton, icon: "slider.horizontal.3", title: "Tự động")
        mu.qualityButton.addTarget(self, action: #selector(muQualityTapped), for: .touchUpInside)
        controlsView.addSubview(mu.qualityButton)
        configureMUChip(mu.audioButton, icon: "captions.bubble", title: "Âm thanh")
        mu.audioButton.addTarget(self, action: #selector(muAudioTapped), for: .touchUpInside)
        controlsView.addSubview(mu.audioButton)
        configureMUChip(mu.fillButton, icon: "arrow.up.left.and.arrow.down.right", title: nil)
        // DB-20 (FIX-134): this expand icon is a fullscreen
        // (rotate) control now, not the classic fill/fit
        // toggle — fill/fit stays reachable by pinch
        // (PlayerView.swift handlePinch), untouched.
        mu.fillButton.accessibilityLabel = "Toàn màn hình"
        mu.fillButton.addTarget(self, action: #selector(muToggleFullscreen), for: .touchUpInside)
        controlsView.addSubview(mu.fillButton)
        configureMUChip(mu.moreButton, icon: "ellipsis", title: nil)
        // FIX-MU-5 (#141): the ••• button opens the MU More
        // sheet (its old direct-PiP action lives on inside
        // the sheet as one of its rows).
        mu.moreButton.accessibilityLabel = "Thêm"
        mu.moreButton.addTarget(self, action: #selector(muMoreTapped), for: .touchUpInside)
        controlsView.addSubview(mu.moreButton)

        mu.sourceLabel.font = MUFont.uiBody(11)
        mu.sourceLabel.textColor = MUUIColor.secondary
        mu.sourceLabel.text = "Nguồn phát · Việt trước"
        controlsView.addSubview(mu.sourceLabel)
        mu.allSourcesButton.setTitle("Tất cả nguồn ›", for: .normal)
        mu.allSourcesButton.titleLabel?.font = MUFont.uiBody(11, .medium)
        mu.allSourcesButton.setTitleColor(MUUIColor.gold, for: .normal)
        mu.allSourcesButton.addTarget(self, action: #selector(muAllSourcesTapped), for: .touchUpInside)
        mu.allSourcesButton.isHidden = !showsSourceSwitch
        controlsView.addSubview(mu.allSourcesButton)

        mu.chipsScroll.showsHorizontalScrollIndicator = false
        controlsView.addSubview(mu.chipsScroll)
        mu.chipsStack.axis = .horizontal
        mu.chipsStack.spacing = 8
        mu.chipsStack.alignment = .fill
        mu.chipsScroll.addSubview(mu.chipsStack)

        // Footer hint (portrait page only): the design's
        // plain explanatory line under the source chips.
        // The mock's right-side illustration notice is NOT
        // carried over (mock notices stay out of the app).
        mu.footerLabel.font = MUFont.uiBody(9)
        mu.footerLabel.textColor = MUUIColor.secondary
        mu.footerLabel.text = "Chạm để hiện · Tự ẩn sau 3 giây"
        mu.footerLabel.lineBreakMode = .byTruncatingTail
        controlsView.addSubview(mu.footerLabel)

        spinner.color = .white
        view.addSubview(spinner)
        spinner.startAnimating()

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = !pipSuppressed
        }

        refreshMUChrome()
    }

    /// One toolbar chip (h44, radius 10, panel-alt fill).
    private func configureMUChip(_ button: UIButton, icon: String, title: String?) {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: icon)
        config.imagePadding = 6
        config.baseForegroundColor = MUUIColor.cream
        config.baseBackgroundColor = MUUIColor.panelAlt
        config.cornerStyle = .fixed
        config.background.cornerRadius = 10
        config.background.strokeColor = MUUIColor.border
        config.background.strokeWidth = 1
        if let title {
            config.title = title
            config.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { attributes in
                    var out = attributes
                    out.font = MUFont.uiBody(12, .medium)
                    return out
                }
        }
        button.configuration = config
    }

    // MARK: - Data refresh

    /// Re-paint the chrome's data from the surface's current
    /// MU inputs (called at build and on every representable
    /// update — the fixture's state moves while the player
    /// sits open, and the chrome follows it).
    func refreshMUChrome() {
        guard let mu = muChrome, let info = muInfo else { return }
        mu.nameLabel.text = info.channelName
        mu.noteLabel.text = info.channelNote
        if let home = info.homeName, let away = info.awayName {
            mu.miniScore.isHidden = false
            mu.miniHomeAbbr.text = Self.abbreviation(home)
            mu.miniAwayAbbr.text = Self.abbreviation(away)
            mu.miniScoreLabel.text = info.scoreText ?? "VS"
            mu.miniClock.text = info.clockText ?? ""
            loadMUCrest(info.homeCrest, into: mu.miniHomeCrest)
        } else {
            mu.miniScore.isHidden = true
        }
        mu.livePill.isHidden = !info.isLive
        // FIX-MU-5 (#132): the pill carries the live minute
        // when the refresh data has one — the clock text IS
        // the minute string ("67'") for a live fixture; any
        // other clock wording (half-time, a badge) keeps the
        // plain LIVE form.
        mu.livePillLabel.text = Self.livePillText(clock: info.clockText)
        // FIX-133 (A15): the pill label carries the spec's
        // .05em tracking in EVERY form (the eyebrow's kern
        // pattern, applied where the text lands).
        applyMUKern(mu.livePillLabel, factor: 0.05)
        // FIX-133 (B29): the LIVE action exists only while
        // the surface is live.
        mu.liveStateButton.isHidden = !info.isLive
        mu.leagueLabel.text = info.leagueText
        // Spec TYPE (FIX-MU-3, finding 10): the eyebrow
        // carries .15em tracking. Its font never changes
        // after build, so the kern is applied here, where
        // its text lands.
        applyMUKern(mu.leagueLabel, factor: 0.15)
        mu.titleLabel.text = info.titleText
        mu.statusLabel.text = info.statusText
        mu.timeLabel.text = info.clockText ?? ""
        mu.liveStateLabel.text = info.isLive ? "Đang ở LIVE" : ""
        // FIX-MU-5 (#137): the broadcast glyph rides with
        // the live-state label; layoutTimeRow reserves its
        // width only while it is visible.
        mu.liveStateIcon.isHidden = !info.isLive
        updateMUQualityTitle()
        rebuildMUChips()
        view.setNeedsLayout()
    }

    /// FIX-MU-5 (#132): "LIVE · 67'" when the clock text is
    /// a live minute (digits + the trailing apostrophe the
    /// feeds render), else the plain "LIVE". (FIX-133, A15:
    /// the leading dot the drawing shows in BOTH forms is
    /// the pill's own 4×4 dot view now, not a glyph in this
    /// string — the minute form used to drop it entirely.)
    private static func livePillText(clock: String?) -> String {
        if let clock, clock.hasSuffix("'"),
           clock.contains(where: \.isNumber) {
            return "LIVE · \(clock)"
        }
        return "LIVE"
    }

    /// A team's 3-letter chip abbreviation, derived from its
    /// display name: one word → its first 3 letters; several
    /// words → the first word's initial + the last word's
    /// first two (Man Utd → MUN, Real Madrid → RMA).
    static func abbreviation(_ name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        guard let first = words.first else { return "" }
        if words.count == 1 {
            return String(first.prefix(3)).uppercased()
        }
        let last = words[words.count - 1]
        return (String(first.prefix(1)) + String(last.prefix(2))).uppercased()
    }

    /// FIX-MU-7 (run #85, FL-395 third variant): the crest
    /// slot is no longer passed as a key path — a
    /// ReferenceWritableKeyPath into the @MainActor
    /// MUChromeViews is not Sendable, so capturing it in
    /// the dataTask completion and re-using it inside the
    /// main-actor closure was a Swift 6 sending error
    /// ("sending 'slot' risks causing data races"). The
    /// function has exactly one call site (the mini home
    /// crest; the away crest was removed in FIX-MU-5
    /// #122), so it addresses homeCrestURL directly and
    /// no key path ever crosses an isolation boundary.
    /// Dedupe + staleness semantics are unchanged.
    private func loadMUCrest(_ url: URL?, into imageView: UIImageView) {
        guard let mu = muChrome else { return }
        guard mu.homeCrestURL != url else { return }
        mu.homeCrestURL = url
        imageView.image = nil
        guard let url else { return }
        URLSession.shared.dataTask(with: url) { [weak self, weak imageView] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, let imageView,
                      self.muChrome?.homeCrestURL == url else { return }
                imageView.image = image
            }
        }.resume()
    }

    /// Letter tracking for the UIKit chrome (spec TYPE,
    /// FIX-MU-3 finding 10): display titles kern −.015em,
    /// the league eyebrow +.15em — the same tracking the
    /// SwiftUI surfaces apply via `.tracking`. The kern is
    /// baked into an attributed string built from the
    /// label's CURRENT font and colour, so callers invoke
    /// this AFTER setting the label's font (the layouts do
    /// for the title, whose size differs per orientation;
    /// refreshMUChrome does for the eyebrow, whose font is
    /// fixed at build). Rebuilt on every call, so text
    /// updates never lose the tracking: the plain string is
    /// read back off the label itself.
    private func applyMUKern(_ label: UILabel, factor: CGFloat) {
        guard let text = label.text, !text.isEmpty else {
            label.attributedText = nil
            return
        }
        let font = label.font ?? MUFont.uiBody(10)
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: label.textColor ?? MUUIColor.cream,
                .kern: factor * font.pointSize,
            ])
    }

    private func updateMUQualityTitle() {
        guard let mu = muChrome else { return }
        let title = muQualityCap == 0 ? "Tự động" : (muQualityCap >= 5_000_000 ? "1080p" : "720p")
        var config = mu.qualityButton.configuration
        config?.title = title
        mu.qualityButton.configuration = config
    }

    /// The source chip row: Vietnamese sources first (the
    /// session's board ladder, in board order), English
    /// after — the playing one in the design's selected
    /// state (maroon fill, gold border, check).
    private func rebuildMUChips() {
        guard let mu = muChrome else { return }
        // FIX-143 (§2.3): chips are NEVER rebuilt while a
        // rotation transition is in flight — the rebuild
        // destroys and recreates every chip button, the
        // single most violent mid-turn swap DIAG-143
        // convicted. A rebuild requested mid-flight (a
        // content refresh) is deferred via chipsDirty and
        // lands in finishMURotation's settle presentation.
        if mu.transitionInFlight {
            mu.chipsDirty = true
            return
        }
        for button in mu.chipButtons {
            mu.chipsStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        mu.chipButtons = []
        var tag = 0
        for channel in muSourcesVN {
            let name = muCommentatorName(MatchTitle.clean(channel.title), group: channel.group)
            let selected = channel.url == self.channel?.url
            let button = makeMUChip(title: "\(name) · Việt", selected: selected, tag: tag)
            tag += 1
            mu.chipsStack.addArrangedSubview(button)
            mu.chipButtons.append(button)
        }
        for meta in muSourcesEN {
            let name = meta.competitionString ?? meta.channelHint ?? meta.displayName
            let selected = muPlayingENID != nil && meta.id == muPlayingENID
            let button = makeMUChip(title: "\(name) · Anh", selected: selected, tag: 1000 + tag)
            tag += 1
            mu.chipsStack.addArrangedSubview(button)
            mu.chipButtons.append(button)
        }
        view.setNeedsLayout()
    }

    private func makeMUChip(title: String, selected: Bool, tag: Int) -> UIButton {
        let button = UIButton(type: .system)
        // Spec TYPE (FIX-MU-3, finding 9): player sources
        // 11 portrait / 10 landscape, weight 400.
        let chipFontSize: CGFloat = muChrome?.landscape == true ? 10 : 11
        var config = UIButton.Configuration.filled()
        config.title = (selected ? "✓ " : "") + title
        config.baseForegroundColor = selected ? MUUIColor.cream : MUUIColor.secondary
        config.baseBackgroundColor = selected ? MUUIColor.selectedFill : MUUIColor.panelAlt
        config.cornerStyle = .fixed
        config.background.cornerRadius = 10
        config.background.strokeColor = selected ? MUUIColor.gold : MUUIColor.border
        config.background.strokeWidth = 1
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 11)
        config.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { attributes in
                var out = attributes
                out.font = MUFont.uiBody(chipFontSize)
                return out
            }
        button.configuration = config
        button.tag = tag
        button.addTarget(self, action: #selector(muChipTapped(_:)), for: .touchUpInside)
        return button
    }

    // MARK: - Layout

    /// Frame layout for both MU player pages. The video
    /// layer's frame is set here (portrait: the design's
    /// video block; landscape: full-bleed) — viewDidLayoutSubviews
    /// routes here whenever the MU chrome is active, so a
    /// rotation reflows between the two pages live.
    ///
    /// FIX-142: this again computes from the view's LIVE
    /// bounds — the single pre-FIX-141 authority. The
    /// FIX-141 target-size variant (an explicit size
    /// parameter, fed by viewWillTransition's alongside
    /// block) was convicted in DIAG-142 of fighting the
    /// live-bounds passes the system drives during its
    /// rotation animation; it is deleted outright, not
    /// kept as an option — one layout authority, keyed
    /// to live bounds. The geometry below is byte-for-byte
    /// the former body: the old no-arg form fed it exactly
    /// this bounds (origin .zero, the view's live size).
    ///
    /// FIX-143 (Option B): the pass is now TWO layers.
    /// GEOMETRY (the page functions: frames from bounds)
    /// runs on every pass, as always. PRESENTATION (page
    /// fonts + kern rebuild, chip spacing + rebuild,
    /// scrim / footer / source-label visibility —
    /// applyMUPresentation) applies immediately on passes
    /// outside a transition, exactly as in 1.42, but is
    /// DEFERRED while a rotation transition is in flight:
    /// in 1.42 those writes fired inside the flip pass as
    /// model-layer writes outside any animation block, so
    /// the new page's composition teleported in mid-turn
    /// while the canvas was still rotating (DIAG-143's
    /// conviction — the rotation was two motions, not
    /// one). Deferred, the elements ride the turn at
    /// their old presentation and update once, at rest,
    /// in finishMURotation's settle pass.
    func layoutMUChrome() {
        guard let mu = muChrome else { return }
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        let safe = view.safeAreaInsets
        let isLandscape = bounds.width > bounds.height
        // FIX-141: layout observability — one DiagLog line
        // when the chosen page or the size used changes
        // versus the last logged pair (see MUChromeViews).
        let page = isLandscape ? "landscape" : "portrait"
        if mu.lastLoggedLayoutPage != page
            || mu.lastLoggedLayoutSize != bounds.size {
            mu.lastLoggedLayoutPage = page
            mu.lastLoggedLayoutSize = bounds.size
            DiagLog.log("player",
                        "mu layout: page=\(page) "
                        + "size=\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))")
        }
        // The GEOMETRY page flag follows the live bounds on
        // every pass, in flight or not (the FIX-139 toggle
        // decision reads this flag — its timing is part of
        // that proven path and does not change).
        if mu.landscape != isLandscape {
            mu.landscape = isLandscape
        }
        if !mu.transitionInFlight {
            applyMUPresentation(mu, isLandscape: isLandscape)
        }
        if bounds.height >= bounds.width {
            layoutMUPortrait(mu, bounds: bounds, safe: safe)
        } else {
            layoutMULandscape(mu, bounds: bounds, safe: safe)
        }
        spinner.center = CGPoint(x: videoView.frame.midX, y: videoView.frame.midY)
        // FIX-143 (§3.1/§3.2): while a transition is in
        // flight, EVERY pass logs — no dedupe — carrying
        // the pass index, the live bounds, the safe-area
        // insets THIS pass saw (the B-5 inset-phase suspect
        // becomes decidable), the chosen page and the
        // picture's own frame; the first in-flight pass
        // also logs the layer line.
        if mu.transitionInFlight {
            mu.inFlightPassCount += 1
            DiagLog.log("player",
                        "mu layout (in flight #\(mu.inFlightPassCount)): page=\(page) "
                        + "bounds=\(muFmtRect(bounds)) "
                        + "safe=\(muFmtInsets(safe)) "
                        + "video=\(muFmtRect(videoView.frame))")
            if mu.inFlightPassCount == 1 {
                logMULayerLine(context: "first in-flight pass")
            }
        }
    }

    /// FIX-143: the PRESENTATION layer of the MU pages —
    /// page fonts + the title's kern rebuild, the chips'
    /// spacing + rebuild, and the scrim / footer /
    /// source-label visibility. Split out of the page
    /// functions (where 1.42 interleaved these writes with
    /// the frame math) so a rotation transition can defer
    /// them to the settle: layoutMUChrome calls this on
    /// every pass outside a transition, and
    /// finishMURotation's settle pass calls it (through
    /// layoutMUChrome) once the turn has landed. The
    /// writes are exactly 1.42's, in 1.42's values — the
    /// settled pages do not change; only their timing
    /// during a turn does. (layoutMiniScore's font writes
    /// stay in the geometry layer deliberately: its font
    /// size is 11 on BOTH pages, so those writes are
    /// value-identical across the flip and cannot
    /// teleport; its frames depend on the intrinsic sizes
    /// those fonts produce, in the same pass.)
    private func applyMUPresentation(_ mu: MUChromeViews, isLandscape: Bool) {
        if isLandscape {
            mu.scrimTop.isHidden = false
            mu.scrimBottom.isHidden = false
            mu.footerLabel.isHidden = true
            mu.sourceLabel.isHidden = true
            mu.nameLabel.font = MUFont.uiBody(14, .semibold)
            mu.noteLabel.font = MUFont.uiBody(9)
            mu.titleLabel.font = MUFont.uiDisplay(25)
            applyMUKern(mu.titleLabel, factor: -0.015)
            mu.statusLabel.font = MUFont.uiBody(9)
        } else {
            mu.scrimTop.isHidden = true
            mu.scrimBottom.isHidden = true
            mu.footerLabel.isHidden = false
            mu.sourceLabel.isHidden = false
            mu.nameLabel.font = MUFont.uiBody(17, .semibold)
            mu.noteLabel.font = MUFont.uiBody(10)
            mu.titleLabel.font = MUFont.uiDisplay(32)
            applyMUKern(mu.titleLabel, factor: -0.015)
            // 1.42's portrait page never wrote
            // statusLabel.font (frame only) — preserved.
        }
        // Chips: the spacing + rebuild land only when the
        // applied presentation's orientation changes, or
        // when a rebuild was deferred mid-flight. (FIX-MU-3
        // finding 9: the chip font differs per orientation,
        // 11 portrait / 10 landscape — makeMUChip reads the
        // geometry flag, which layoutMUChrome has already
        // set to this same page. FIX-133 D17: the spacing
        // is set with the rebuild so layoutChips' width
        // accounting always agrees with the stack itself.)
        if mu.presentationLandscape != isLandscape || mu.chipsDirty {
            mu.presentationLandscape = isLandscape
            mu.chipsStack.spacing = isLandscape ? 12 : 8
            rebuildMUChips()
            mu.chipsDirty = false
        }
    }

    /// FIX-143 (§3.2): the picture layer's own numbers —
    /// videoView.frame, its backing player layer's frame
    /// (PlayerLayerView's layer IS the AVPlayerLayer, so
    /// the two must track) and the video gravity — logged
    /// at the fullscreen toggle, at the first in-flight
    /// layout pass and at the settle, so the picture's
    /// geometry is observable DURING a transition for the
    /// first time (in 1.42 nothing logged it at all).
    func logMULayerLine(context: String) {
        let layer = videoView.playerLayer
        DiagLog.log("player",
                    "mu layer (\(context)): video=\(muFmtRect(videoView.frame)) "
                    + "layer=\(muFmtRect(layer.frame)) "
                    + "videorect=\(muFmtRect(layer.videoRect)) "
                    + "gravity=\(layer.videoGravity.rawValue)")
    }

    /// Compact rect spelling for the FIX-143 log lines:
    /// "x,y WxH", points rounded.
    func muFmtRect(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x.rounded())),\(Int(rect.origin.y.rounded())) "
            + "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    /// Compact insets spelling for the FIX-143 log lines:
    /// "top,left,bottom,right", points rounded.
    func muFmtInsets(_ insets: UIEdgeInsets) -> String {
        "\(Int(insets.top.rounded())),\(Int(insets.left.rounded())),"
            + "\(Int(insets.bottom.rounded())),\(Int(insets.right.rounded()))"
    }

    private func layoutMUPortrait(_ mu: MUChromeViews, bounds: CGRect, safe: UIEdgeInsets) {
        // FIX-143: GEOMETRY ONLY — the scrim/footer
        // visibility and the header fonts this function
        // used to write live in applyMUPresentation now,
        // so a rotation transition can defer them to the
        // settle instead of teleporting them mid-turn.
        let w = bounds.width
        let pad: CGFloat = 16
        let top = safe.top

        // Header row (56): name + note left, close top-right.
        mu.nameLabel.frame = CGRect(x: pad, y: top + 4, width: w - pad - 48 - 24, height: 22)
        mu.noteLabel.frame = CGRect(x: pad, y: top + 28, width: w - pad - 48 - 24, height: 14)
        closeButton.frame = CGRect(x: w - pad - 48, y: top + 4, width: 48, height: 48)

        // Mini-score chip under the header (absent for a
        // direct channel play — the video then moves up).
        let chipH: CGFloat = mu.miniScore.isHidden ? 0 : 32
        let chipY = top + 56 + 16
        layoutMiniScore(mu, x: pad, y: chipY, height: 32, crest: 23, fontSize: 11)

        // Video block: the spec's 390×276 at y159 on the
        // reference screen — top = chip bottom + 8, height
        // keeps the design's ratio.
        let videoY = chipY + chipH + (mu.miniScore.isHidden ? 0 : 8)
        var videoH = w * 276.0 / 390.0
        // F-1 (REVIEW-MU2-LOOP2): the fixed stack below the
        // video (block heights 279 + inter-block gaps 86,
        // summed from the walk below — FIX-MU-3 findings
        // 6+7 folded in: the source-area margin is the
        // spec's 8, and the stack now ends with the footer's
        // 30) overflows short viewports — on a 375×667 screen
        // the source header lands at y≈634 and the chips row
        // at y≈686–730, off-screen and unreachable (the page
        // has no scroll container). When the full stack would
        // pass the bottom safe edge, compress: cap the video
        // height first, then tighten the inter-block gaps.
        // At the 390×844 reference the stack ends at y800
        // against a limit of 810, so nothing compresses and
        // the spec geometry (videoY 159, height 276, every
        // gap) is reproduced exactly.
        var gapScale: CGFloat = 1
        let lowerFixed: CGFloat = 20 + 40 + 15 + 14 + 28 + 44 + 44 + 44 + 30
        let lowerGaps: CGFloat = 19 + 9 + 8 + 12 + 6 + 8 + 8 + 8 + 8
        let bottomLimit = bounds.height - safe.bottom
        let stackOverflow = videoY + videoH + lowerFixed + lowerGaps - bottomLimit
        if stackOverflow > 0 {
            // Cap the video, keeping 8 pt of air above the
            // bottom edge; the video height floors at 120.
            let cut = max(0, min(stackOverflow + 8, videoH - 120))
            videoH -= cut
            let remaining = videoY + videoH + lowerFixed + lowerGaps - bottomLimit
            if remaining > 0 {
                gapScale = max(0.35, (lowerGaps - remaining) / lowerGaps)
            }
        }
        videoView.frame = CGRect(x: 0, y: videoY, width: w, height: videoH)
        layoutTransport(mu, centre: CGPoint(x: w / 2, y: videoY + videoH / 2),
                        playSize: 64, sideSize: 44, gap: 32)

        // Lower block (gaps scale only under the F-1
        // compression above; at gapScale 1 the advances are
        // the original literals).
        var y = videoY + videoH + 19 * gapScale
        layoutEyebrowRow(mu, x: pad, y: y, width: w - pad * 2, titleSize: 32)
        y += 20 + 9 * gapScale
        mu.titleLabel.frame = CGRect(x: pad, y: y, width: w - pad * 2, height: 40)
        y += 40 + 8 * gapScale
        mu.statusLabel.frame = CGRect(x: pad, y: y, width: w - pad * 2, height: 15)
        y += 15 + 12 * gapScale
        layoutTimeRow(mu, x: pad, y: y, width: w - pad * 2)
        y += 14 + 6 * gapScale
        layoutProgress(mu, x: pad, y: y, width: w - pad * 2)
        y += 28 + 8 * gapScale
        layoutToolbar(mu, x: pad, y: y, width: w - pad * 2)
        // FIX-MU-3 (finding 6): the source area's margin-top
        // is the spec's 8, not 14.
        y += 44 + 8 * gapScale
        layoutSourceHeader(mu, x: pad, y: y, width: w - pad * 2)
        y += 44 + 8 * gapScale
        layoutChips(mu, x: pad, y: y, width: w - pad * 2)
        // FIX-MU-3 (finding 7): the footer hint under the
        // chips — plain 9 pt text, min-height 30.
        y += 44 + 8 * gapScale
        mu.footerLabel.frame = CGRect(x: pad, y: y, width: w - pad * 2, height: 30)
    }

    private func layoutMULandscape(_ mu: MUChromeViews, bounds: CGRect, safe: UIEdgeInsets) {
        // FIX-143: GEOMETRY ONLY — the scrim/footer
        // visibility and the page fonts this function used
        // to write live in applyMUPresentation now (see
        // layoutMUPortrait's note).
        let w = bounds.width
        let h = bounds.height
        let insetX = safe.left + 12
        let contentW = w - insetX * 2

        videoView.frame = bounds
        mu.scrimTop.frame = CGRect(x: 0, y: 0, width: w, height: 110)
        mu.scrimBottom.frame = CGRect(x: 0, y: h - 170, width: w, height: 170)
        for scrim in [mu.scrimTop, mu.scrimBottom] {
            scrim.layer.sublayers?.first?.frame = scrim.bounds
        }

        // Header top-left; close top-right (spec: y12).
        mu.nameLabel.frame = CGRect(x: insetX, y: 12, width: w - insetX * 2 - 60, height: 19)
        mu.noteLabel.frame = CGRect(x: insetX, y: 33, width: w - insetX * 2 - 60, height: 12)
        closeButton.frame = CGRect(x: w - insetX - 48, y: 12, width: 48, height: 48)

        layoutMiniScore(mu, x: insetX, y: 73, height: 28, crest: 20, fontSize: 11)
        // Spec (FIX-MU-3, finding 8): transport top 109 —
        // play 56, so the transport centre sits at y 137.
        layoutTransport(mu, centre: CGPoint(x: w / 2, y: 109 + 28),
                        playSize: 56, sideSize: 44, gap: 36)

        // Bottom block, built up from the bottom edge:
        // sources row, progress row, then title | toolbar.
        let bottom = h - safe.bottom - 7
        let chipsY = bottom - 44
        layoutChips(mu, x: insetX + 106, y: chipsY, width: contentW - 106)
        mu.allSourcesButton.frame = CGRect(x: insetX, y: chipsY, width: 94, height: 44)
        let progressY = chipsY - 12 - 28
        layoutProgress(mu, x: insetX, y: progressY, width: contentW)
        let timeY = progressY - 4 - 14
        layoutTimeRow(mu, x: insetX, y: timeY, width: contentW)
        let rowY = timeY - 10 - 62
        // Title block (left half).
        layoutEyebrowRow(mu, x: insetX, y: rowY, width: contentW / 2 - 12, titleSize: 25)
        mu.titleLabel.frame = CGRect(x: insetX, y: rowY + 26, width: contentW / 2 - 12, height: 30)
        mu.statusLabel.frame = CGRect(x: insetX, y: rowY + 58, width: contentW / 2 - 12, height: 12)
        // Toolbar (right half, right-aligned).
        layoutToolbar(mu, x: insetX + contentW / 2 + 12, y: rowY + 9, width: contentW / 2 - 12)
    }

    private func layoutMiniScore(_ mu: MUChromeViews, x: CGFloat, y: CGFloat,
                                 height: CGFloat, crest: CGFloat, fontSize: CGFloat) {
        guard !mu.miniScore.isHidden else { return }
        let pad: CGFloat = 7
        let gap: CGFloat = 7
        // FIX-135 (DB-21): the five subviews are children of
        // miniScore, so their frames are PLATE-LOCAL — cx starts
        // at pad and every y is measured from the plate's own
        // top. (Before, the frames were computed in controlsView
        // coordinates, displacing the whole content row by the
        // plate's own origin and leaving the plate empty.)
        var cx = pad
        let crestY = (height - crest) / 2
        mu.miniHomeCrest.frame = CGRect(x: cx, y: crestY, width: crest, height: crest)
        cx += crest + gap
        mu.miniHomeAbbr.font = MUFont.uiBody(fontSize, .semibold)
        let homeW = mu.miniHomeAbbr.intrinsicContentSize.width
        mu.miniHomeAbbr.frame = CGRect(x: cx, y: 0, width: homeW, height: height)
        cx += homeW + gap
        // FIX-MU-5 (#123): semibold (600), as at build.
        mu.miniScoreLabel.font = MUFont.uiBody(fontSize, .semibold)
        let scoreW = mu.miniScoreLabel.intrinsicContentSize.width + 12
        mu.miniScoreLabel.frame = CGRect(x: cx, y: (height - 20) / 2, width: scoreW, height: 20)
        cx += scoreW + gap
        let awayW = mu.miniAwayAbbr.intrinsicContentSize.width
        mu.miniAwayAbbr.frame = CGRect(x: cx, y: 0, width: awayW, height: height)
        cx += awayW + gap
        // FIX-MU-5 (#122): no away crest segment — the clock
        // follows the away abbreviation directly.
        mu.miniClock.font = MUFont.uiBody(fontSize, .semibold)
        let clockW = mu.miniClock.intrinsicContentSize.width
        mu.miniClock.frame = CGRect(x: cx, y: 0, width: clockW, height: height)
        cx += clockW + pad
        mu.miniScore.frame = CGRect(x: x, y: y, width: cx, height: height)
    }

    private func layoutTransport(_ mu: MUChromeViews, centre: CGPoint,
                                 playSize: CGFloat, sideSize: CGFloat, gap: CGFloat) {
        playPauseButton.frame = CGRect(x: centre.x - playSize / 2, y: centre.y - playSize / 2,
                                       width: playSize, height: playSize)
        playPauseButton.layer.cornerRadius = playSize / 2
        let sideY = centre.y - sideSize / 2
        mu.rewindButton.frame = CGRect(x: centre.x - playSize / 2 - gap - sideSize,
                                       y: sideY, width: sideSize, height: sideSize)
        mu.volumeButton.frame = CGRect(x: centre.x + playSize / 2 + gap,
                                       y: sideY, width: sideSize, height: sideSize)
    }

    private func layoutEyebrowRow(_ mu: MUChromeViews, x: CGFloat, y: CGFloat,
                                  width: CGFloat, titleSize: CGFloat) {
        // FIX-133 (A15): the pill's width accounting carries
        // the dot view now — 8 inset + 4 dot + 5 gap + the
        // label + 8 inset (was: the label + 16, with a bullet
        // glyph of uncontrolled size inside the text).
        let pillW = mu.livePillLabel.intrinsicContentSize.width + 16 + 4 + 5
        mu.livePill.frame = CGRect(x: x, y: y, width: mu.livePill.isHidden ? 0 : pillW, height: 20)
        mu.livePillDot.frame = CGRect(x: 8, y: 8, width: 4, height: 4)
        mu.livePillLabel.frame = CGRect(x: 8 + 4 + 5, y: 0, width: pillW - 16 - 4 - 5, height: 20)
        let leagueX = x + (mu.livePill.isHidden ? 0 : pillW + 8)
        mu.leagueLabel.frame = CGRect(x: leagueX, y: y, width: max(0, x + width - leagueX), height: 20)
    }

    private func layoutTimeRow(_ mu: MUChromeViews, x: CGFloat, y: CGFloat, width: CGFloat) {
        let liveW = mu.liveStateLabel.intrinsicContentSize.width
        // FIX-MU-5 (#137): the broadcast glyph (14 + a 5 gap)
        // is reserved in front of the label only while it is
        // visible — hidden, the row is byte-for-byte the old
        // accounting.
        let iconW: CGFloat = mu.liveStateIcon.isHidden ? 0 : 14 + 5
        mu.timeLabel.frame = CGRect(x: x, y: y, width: width - liveW - iconW - 10, height: 14)
        let liveX = x + width - liveW - iconW
        mu.liveStateIcon.frame = CGRect(x: liveX, y: y, width: 14, height: 14)
        mu.liveStateLabel.frame = CGRect(x: liveX + iconW, y: y, width: liveW, height: 14)
        // FIX-133 (B29): the LIVE action's 44-high hit
        // target, centred on the 14-high row, spanning
        // exactly the icon + label it activates.
        mu.liveStateButton.frame = CGRect(x: liveX, y: y - 15,
                                          width: iconW + liveW, height: 44)
    }

    /// The progress bar: these are live streams with no
    /// seekable position, so the bar renders the live edge —
    /// the red fill runs to the end, knob at the edge.
    private func layoutProgress(_ mu: MUChromeViews, x: CGFloat, y: CGFloat, width: CGFloat) {
        let barY = y + 12
        mu.progressTrack.frame = CGRect(x: x, y: barY, width: width, height: 4)
        mu.progressFill.frame = CGRect(x: x, y: barY, width: width, height: 4)
        mu.progressKnob.frame = CGRect(x: x + width - 12, y: barY - 4, width: 12, height: 12)
    }

    private func layoutToolbar(_ mu: MUChromeViews, x: CGFloat, y: CGFloat, width: CGFloat) {
        let h: CGFloat = 44
        let iconW: CGFloat = 44
        let gap: CGFloat = 7
        let flexW = (width - iconW * 2 - gap * 3) / 2
        mu.qualityButton.frame = CGRect(x: x, y: y, width: flexW, height: h)
        mu.audioButton.frame = CGRect(x: x + flexW + gap, y: y, width: flexW, height: h)
        mu.fillButton.frame = CGRect(x: x + flexW * 2 + gap * 2, y: y, width: iconW, height: h)
        mu.moreButton.frame = CGRect(x: x + flexW * 2 + gap * 2 + iconW + gap, y: y, width: iconW, height: h)
    }

    private func layoutSourceHeader(_ mu: MUChromeViews, x: CGFloat, y: CGFloat, width: CGFloat) {
        // FIX-143: the source label's visibility is
        // presentation (applyMUPresentation); only its
        // frame is geometry and stays here.
        mu.sourceLabel.frame = CGRect(x: x, y: y, width: width - 120, height: 44)
        mu.allSourcesButton.frame = CGRect(x: x + width - 120, y: y, width: 120, height: 44)
    }

    private func layoutChips(_ mu: MUChromeViews, x: CGFloat, y: CGFloat, width: CGFloat) {
        mu.chipsScroll.frame = CGRect(x: x, y: y, width: width, height: 44)
        // FIX-133 (D17): the gap in this accounting is the
        // stack's own spacing (8 portrait / 12 landscape),
        // never a second literal that can drift from it.
        let gap = mu.chipsStack.spacing
        var totalW: CGFloat = 0
        for button in mu.chipButtons {
            let w = button.intrinsicContentSize.width
            button.frame = CGRect(x: 0, y: 0, width: w, height: 44)
            totalW += w + gap
        }
        mu.chipsStack.frame = CGRect(x: 0, y: 0, width: max(0, totalW - gap), height: 44)
        mu.chipsScroll.contentSize = CGSize(width: max(0, totalW - gap), height: 44)
    }

    // MARK: - Actions

    @objc func muChipTapped(_ sender: UIButton) {
        // Tags (see rebuildMUChips): VN chips carry their
        // ladder index; EN chips carry 1000 + the shared
        // build counter, which had already counted the VN
        // chips — so the EN index subtracts both back out.
        if sender.tag < 1000 {
            guard muSourcesVN.indices.contains(sender.tag) else { return }
            onMUSelectVN?(muSourcesVN[sender.tag])
        } else {
            let enIndex = sender.tag - 1000 - muSourcesVN.count
            guard muSourcesEN.indices.contains(enIndex) else { return }
            onMUSelectEN?(muSourcesEN[enIndex])
        }
        showControls()
    }

    @objc func muAllSourcesTapped() {
        // FIX-144: the board is a SwiftUI sheet on the
        // player cover — while the fullscreen presentation
        // is up it would stack UNDER it (presentation
        // stacking follows the view-controller tree, and
        // the cover sits below the presented controller).
        // Exit fullscreen first; the dismissal's completion
        // opens the board once the player view is home.
        // Mid-flight taps ride the parity queue like any
        // toggle (see openBoardAfterExit on MUChromeViews).
        if MUFullscreenState.presentedController != nil, let mu = muChrome {
            mu.openBoardAfterExit = true
            muToggleFullscreen()
            return
        }
        onSourceSwitch?()
        showControls()
    }

    /// FIX-133 (audit B29): the timeline LIVE action — a
    /// tap on "Đang ở LIVE" returns playback to the live
    /// edge (the end of the item's seekable window), the
    /// real-playback form of the mock's "LIVE restores".
    @objc func muLiveEdgeTapped() {
        guard let item = playerItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else {
            showControls()
            return
        }
        player?.seek(to: CMTimeAdd(range.start, range.duration))
        showControls()
    }

    @objc func muRewindTapped() {
        guard let item = playerItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else {
            showControls()
            return
        }
        let current = item.currentTime()
        let target = CMTimeMaximum(range.start,
                                   CMTimeSubtract(current, CMTime(seconds: 10, preferredTimescale: 600)))
        if CMTimeCompare(target, current) < 0 {
            player?.seek(to: target)
        }
        showControls()
    }

    @objc func muVolumeTapped() {
        guard let player else { return }
        player.isMuted.toggle()
        muChrome?.volumeButton.setImage(
            UIImage(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
            for: .normal)
        showControls()
    }

    /// DB-20 (FIX-134): the MU fullscreen action — rotate by
    /// orientation lock, the step the MU branch never had
    /// (DIAG-133 §3–§4: both MU "fullscreen" entries used to
    /// run the classic fill/fit toggle, which never rotates
    /// the portrait page). Entering (currently portrait)
    /// narrows the lock to landscape with the exact call the
    /// classic branch uses; the geometry update rotates the
    /// UI and layoutMUChrome reflows to the landscape page
    /// on the new bounds. Exiting (currently landscape)
    /// rotates back to the portrait page AND reopens the
    /// lock to MU's free-rotation baseline. The current side
    /// comes from the same tracked flag layoutMUChrome keeps
    /// (mu.landscape), falling back to its own bounds test —
    /// no new persistent state beyond MUFullscreenState,
    /// which ContentView needs for its route-change guard.
    /// `MUFullscreenState.isActive` is still WRITTEN here as
    /// that record, but it is not the decision source.
    ///
    /// FIX-139: this restores the 1.35 decision source — the
    /// LIVE LAYOUT — in place of the FIX-137 decision by
    /// `MUFullscreenState.isActive`. That flag is flipped
    /// optimistically, before the rotation it requests has
    /// actually happened, so when a geometry update was
    /// rejected (see FIX-139 in DaBanhApp.swift) the flag and
    /// the window disagreed: the flag said "not fullscreen"
    /// while the window stayed landscape, the next tap read
    /// the flag and chose ENTER again, and the player could
    /// never return to portrait — one rejected rotation
    /// became a self-sustaining landscape lock-out (WP4 of
    /// the full review). Deciding from the live layout makes
    /// the toggle follow the window as it actually is. The
    /// live interface orientation, the layout flag and the
    /// chosen direction are logged with every toggle so the
    /// device log can convict any residual mismatch.
    @objc func muToggleFullscreen() {
        // FIX-143 (§3.2): the picture layer's numbers at
        // the toggle itself. Pure instrumentation — the
        // FIX-142 queue and the FIX-139 decision below are
        // untouched.
        logMULayerLine(context: "toggle")
        // FIX-142: a toggle fired while a rotation
        // transition is in flight is QUEUED, not dropped.
        // FIX-141's coalescing discarded it outright (no
        // second lock/geometry request until the in-flight
        // transition settled), which ate the corrective
        // tap a viewer fires mid-rotation (DIAG-142). Now
        // the tap flips the pendingToggle parity bit on
        // the chrome's state bag, and the transition's
        // completion (finishMURotation, PlayerView.swift)
        // runs ONE fresh toggle through the FIX-139
        // decision below — two mid-flight taps cancel
        // (parity, not a counter), so requests still
        // never stack (DIAG-140's disease). The FIX-139
        // decision below is untouched and runs as before
        // once no transition is in flight.
        if let mu = muChrome, mu.transitionInFlight {
            mu.pendingToggle.toggle()
            DiagLog.log("player",
                        "mu fullscreen toggle: queued (transition in flight) "
                        + "state=\(playbackStateName)")
            showControls()
            return
        }
        let isLandscape = muChrome?.landscape ?? (view.bounds.width > view.bounds.height)
        let live = view.window?.windowScene?.interfaceOrientation
        DiagLog.log("player",
                    "mu fullscreen toggle: interface=\(live?.rawValue ?? -1) "
                    + "layoutLandscape=\(isLandscape) "
                    + "direction=\(isLandscape ? "exit" : "enter") "
                    + "state=\(playbackStateName)")
        if isLandscape {
            MUFullscreenState.isActive = false
            OrientationHelper.lock(.all, rotateTo: .portrait)
        } else {
            MUFullscreenState.isActive = true
            OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
        }
        showControls()
        // FIX-144 (Option A): the FIX-139 decision above is
        // unchanged — it still decides the direction from
        // the live layout, still writes the state record,
        // still makes the same lock requests. What carries
        // the decision out is new: the fullscreen
        // presentation that hosts this player. The sync is
        // idempotent — it presents on an enter decision
        // with no presentation up, dismisses on an exit
        // decision with one up, and does nothing when the
        // hosting already matches the decision (a toggle
        // decided from a physically rotated page has no
        // presentation to move).
        syncMUFullscreenHosting()
    }

    // MARK: - Fullscreen hosting (FIX-144, Option A)

    /// FIX-144: reconcile the fullscreen presentation with
    /// the state the FIX-139 decision just wrote. Called
    /// at the end of every unqueued toggle (a queued
    /// toggle is serviced later by a fresh toggle through
    /// finishMURotation, which lands here the same way).
    func syncMUFullscreenHosting() {
        guard isMUChrome, let mu = muChrome else { return }
        if MUFullscreenState.isActive {
            guard MUFullscreenState.presentedController == nil else { return }
            beginMUFullscreenPresentation(mu)
        } else {
            guard MUFullscreenState.presentedController != nil else { return }
            beginMUFullscreenDismissal(mu)
        }
    }

    /// The presenter for the fullscreen controller: this
    /// surface's topmost ancestor — the cover's hosting
    /// controller, which outlives every surface swap (a
    /// presentation anchored on a surface would be
    /// dismissed automatically when that surface is
    /// dismantled, stranding the successor).
    private func muFullscreenPresenter() -> UIViewController {
        var top: UIViewController = self
        while let parent = top.parent { top = parent }
        return top
    }

    /// ENTER: save the host slot, move the WHOLE player
    /// view into a fresh fullscreen controller and present
    /// it — KSPlayer's updateUI(isFullScreen:) mapped to
    /// this app's frame-based view (its edge-pin
    /// constraints are the frame + flexible autoresizing
    /// set here; there are no app-owned constraints to
    /// deactivate). The AVPlayer, its item, the session
    /// and every observation stay exactly where they are:
    /// only the view changes parent. The presentation's
    /// completion runs the FIX-143 settle
    /// (finishMURotation) at the hosted landscape rest.
    private func beginMUFullscreenPresentation(_ mu: MUChromeViews) {
        guard let host = view.superview else { return }
        mu.hostOriginalSuperview = host
        mu.hostOriginalIndex = host.subviews.firstIndex(of: view) ?? host.subviews.count
        mu.hostOriginalFrame = view.frame
        mu.hostOriginalAutoresizingMask = view.autoresizingMask
        // A fresh enter cancels a board request left over
        // from an earlier exit path (the viewer's latest
        // act was this toggle).
        mu.openBoardAfterExit = false
        mu.transitionInFlight = true
        mu.inFlightPassCount = 0
        mu.fullscreenDriving = true
        let fsVC = MUFullscreenViewController()
        fsVC.modalPresentationStyle = .fullScreen
        fsVC.modalPresentationCapturesStatusBarAppearance = true
        fsVC.transitioningDelegate = self
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fsVC.view.addSubview(view)
        view.frame = fsVC.view.bounds
        MUFullscreenState.presentedController = fsVC
        MUFullscreenState.hostedController = self
        DiagLog.log("player",
                    "mu fullscreen hosting: presenting (host slot "
                    + "\(muFmtRect(mu.hostOriginalFrame)))")
        // FIX-144 gate restarted Round 1 (B-8): this
        // completion captures self STRONGLY, on purpose.
        // It is the ONLY service point for a teardown
        // release deferred during the flight; with a weak
        // capture, a surface SwiftUI deallocates inside
        // the 0.25 s window (ladder exhaustion, no
        // successor) would take the completion with it
        // and strand the presented controller on screen
        // with no living owner. The retention is bounded:
        // UIKit holds the handler only until it fires —
        // and drops it unrun on a refused present, where
        // the rollback below has already restored the
        // surface — so it cannot form a cycle: nothing on
        // the surface retains the handler.
        muFullscreenPresenter().present(fsVC, animated: true) {
            guard let mu = self.muChrome else { return }
            mu.fullscreenDriving = false
            // FIX-144 gate Round 1 (B-4): a teardown
            // that landed during this flight deferred
            // its release to this completion — service
            // it instead of settling a dead surface.
            if mu.releasePendingAfterFlight {
                mu.releasePendingAfterFlight = false
                self.releaseMUFullscreenHostingForTeardown()
                return
            }
            // FIX-144 gate Round 1 (B-3): if a successor
            // adopted the presentation mid-flight, the
            // hosting already landed on ITS surface (the
            // adoption applied the full presentation);
            // this flight's settle must not run on the
            // old one.
            guard MUFullscreenState.hostedController === self else {
                DiagLog.log("player",
                            "mu fullscreen hosting: present completion "
                            + "on a superseded surface — settle skipped")
                return
            }
            self.finishMURotation()
        }
        // FIX-144 gate Round 1 (B-2): present() can be
        // refused (the presenter is already presenting
        // or mid-transition) — a no-op whose completion
        // never runs. An accepted presentation has its
        // presentingViewController set synchronously, so
        // a missing one here IS the refusal. Roll the
        // whole enter back: the view returns to its host
        // slot (picture never lost), the records are
        // nilled, and the settle runs — the state record
        // still says fullscreen, but the FIX-139 decision
        // re-reads the LIVE layout, so the next toggle
        // re-attempts the enter from the truth.
        if fsVC.presentingViewController == nil {
            MUFullscreenState.presentedController = nil
            if MUFullscreenState.hostedController === self {
                MUFullscreenState.hostedController = nil
            }
            let index = min(mu.hostOriginalIndex, host.subviews.count)
            host.insertSubview(view, at: index)
            view.frame = mu.hostOriginalFrame
            view.autoresizingMask = mu.hostOriginalAutoresizingMask
            mu.fullscreenDriving = false
            DiagLog.log("player",
                        "mu fullscreen hosting: present REFUSED — "
                        + "enter rolled back to the host slot")
            finishMURotation()
        }
    }

    /// EXIT: dismiss the fullscreen controller; the
    /// animator restores the player view into the
    /// controller's view at the end of the flight, and
    /// this completion then restores it HOME — the saved
    /// superview, index and frame (KSPlayer's dismissal
    /// completion) — before the FIX-143 settle runs at the
    /// restored portrait rest.
    private func beginMUFullscreenDismissal(_ mu: MUChromeViews) {
        guard let fsVC = MUFullscreenState.presentedController else { return }
        mu.transitionInFlight = true
        mu.inFlightPassCount = 0
        mu.fullscreenDriving = true
        DiagLog.log("player", "mu fullscreen hosting: dismissing")
        fsVC.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            let mu = self.muChrome
            mu?.fullscreenDriving = false
            // The records are retired only if they still
            // name THIS presentation. If they were
            // re-pointed (a teardown release, or a
            // successor's fresh presentation), this
            // completion owns nothing — and the trip is
            // LOGGED, not silent (gate Round 1, B-5).
            guard MUFullscreenState.presentedController === fsVC else {
                DiagLog.log("player",
                            "mu fullscreen hosting: dismiss completion "
                            + "for a superseded presentation — records kept")
                return
            }
            MUFullscreenState.presentedController = nil
            if MUFullscreenState.hostedController === self {
                MUFullscreenState.hostedController = nil
            }
            // A surface torn down mid-dismissal (source
            // swap inside the flight) restores nothing:
            // its view is discarded with it, and no
            // settle or board service runs on the dead.
            if self.isTorn {
                DiagLog.log("player",
                            "mu fullscreen hosting: dismissed under "
                            + "a torn surface — restore skipped")
                return
            }
            // Restore the view HOME — the saved superview,
            // index, frame and autoresizing mask
            // (KSPlayer's dismissal completion) — before
            // the FIX-143 settle runs at the restored
            // portrait rest.
            if let host = mu?.hostOriginalSuperview {
                let index = min(mu?.hostOriginalIndex ?? host.subviews.count,
                                host.subviews.count)
                host.insertSubview(self.view, at: index)
                self.view.frame = mu?.hostOriginalFrame ?? self.view.frame
                self.view.autoresizingMask = mu?.hostOriginalAutoresizingMask ?? []
            }
            self.finishMURotation()
            if let mu, mu.openBoardAfterExit {
                mu.openBoardAfterExit = false
                self.onSourceSwitch?()
                self.showControls()
            }
        }
    }

    /// FIX-144: a surface born while the fullscreen
    /// presentation is up — an in-place source advance or
    /// chip switch replaces this controller wholesale
    /// (the surface is keyed by rung), under the still-
    /// presented fullscreen controller — adopts the
    /// hosting: the previous surface's view is vacated
    /// and this surface's view moves into the presented
    /// controller in its place, at the hosted landscape
    /// rest (the layout the move triggers applies the
    /// full geometry + presentation, the same cut the
    /// in-place swap made inside the rotated window in
    /// 1.43). If the swap lands inside a flight, the
    /// move is still safe: the animator's completion
    /// will not re-insert the torn predecessor's view
    /// over this one (gate Round 1, B-3). Called from
    /// viewDidAppear; a no-op in every other state.
    func adoptMUFullscreenHostingIfNeeded() {
        guard isMUChrome, let mu = muChrome else { return }
        guard MUFullscreenState.isActive,
              MUFullscreenState.hostedController !== self else { return }
        // FIX-144 gate Round 1 (B-4): teardown-before-
        // adopt ordering — the previous surface's
        // teardown release already retired the
        // presentation before this successor appeared.
        // The adoption then IS a fresh enter from this
        // surface's own host slot, so the two orderings
        // converge on the same end state. (If that
        // present is refused, the B-2 rollback inside
        // the enter keeps the picture in the host.)
        guard let fsVC = MUFullscreenState.presentedController else {
            DiagLog.log("player",
                        "mu fullscreen hosting: successor found no "
                        + "presentation up — re-presenting")
            beginMUFullscreenPresentation(mu)
            return
        }
        guard let host = view.superview, host !== fsVC.view else { return }
        // Sweep whatever the previous surface left in
        // the fullscreen view — its own view, or a dead
        // predecessor's (whose controller record has
        // already nilled): the presented view hosts
        // exactly ONE player view, this surface's.
        for subview in fsVC.view.subviews where subview !== view {
            subview.removeFromSuperview()
        }
        mu.hostOriginalSuperview = host
        mu.hostOriginalIndex = host.subviews.firstIndex(of: view) ?? host.subviews.count
        mu.hostOriginalFrame = view.frame
        mu.hostOriginalAutoresizingMask = view.autoresizingMask
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fsVC.view.addSubview(view)
        view.frame = fsVC.view.bounds
        MUFullscreenState.hostedController = self
        DiagLog.log("player",
                    "mu fullscreen hosting: adopted by source "
                    + "#\(sourceIndex) (in-place swap under the presentation)")
    }

    /// FIX-144: teardown of the HOSTED surface with no
    /// successor adopting (the player is closing, or the
    /// ladder ran out under it) releases the presentation
    /// with it — the view is being discarded either way.
    /// If a successor already adopted, the record names
    /// it, not this surface, and this is a no-op; if the
    /// successor has NOT adopted yet, its adoption finds
    /// no presentation up and re-presents (gate Round 1,
    /// B-4) — the two orderings converge. MUFullscreenState
    /// .isActive is NOT touched — ContentView owns its
    /// reset on a genuine close, as before.
    func releaseMUFullscreenHostingForTeardown() {
        guard MUFullscreenState.hostedController === self,
              let fsVC = MUFullscreenState.presentedController else { return }
        // FIX-144 gate Round 1 (B-4): never dismiss
        // against a transition this surface is still
        // driving — the records would be nilled while
        // UIKit may still complete the presentation,
        // leaving an on-screen controller no record
        // names. Defer: the flight's completion services
        // the release (and if a successor adopts first,
        // the record no longer names this surface and
        // the deferred release no-ops).
        if let mu = muChrome, mu.fullscreenDriving {
            mu.releasePendingAfterFlight = true
            DiagLog.log("player",
                        "mu fullscreen hosting: teardown during "
                        + "a flight — release deferred to its completion")
            return
        }
        MUFullscreenState.hostedController = nil
        MUFullscreenState.presentedController = nil
        DiagLog.log("player",
                    "mu fullscreen hosting: released at teardown "
                    + "(source #\(sourceIndex))")
        fsVC.dismiss(animated: false)
    }

    /// FIX-144: the controller the MU action sheets
    /// (More / Quality / Audio) present from. While the
    /// fullscreen presentation is up, a sheet presented
    /// from THIS controller would stack under it —
    /// presentation stacking follows the view-controller
    /// tree, and this controller sits in the cover's tree
    /// below the presented controller, wherever its view
    /// currently lives. The sheets therefore present from
    /// the fullscreen controller while it is up, and from
    /// this controller otherwise (the 1.43 behaviour).
    private func muSheetPresenter() -> UIViewController {
        MUFullscreenState.presentedController ?? self
    }

    /// Quality: a real rendition cap on the player item
    /// (AVPlayerItem.preferredPeakBitRate) — Tự động lifts
    /// it, 1080p / 720p cap the peak bit rate.
    /// FIX-MU-5 (#141): the ••• button's More sheet — the
    /// design's overflow menu, following the quality/audio
    /// pattern (action sheet, controls pinned while it is
    /// up, the popover delegate re-arms on an iPad
    /// outside-tap dismissal). Every row rehoused here runs
    /// the same action its own control runs — including PiP,
    /// which the ••• button used to toggle directly.
    @objc func muMoreTapped() {
        keepControlsVisible()
        let sheet = UIAlertController(title: nil, message: nil,
                                      preferredStyle: .actionSheet)
        if showsSourceSwitch {
            sheet.addAction(UIAlertAction(title: "Nguồn phát", style: .default) { [weak self] _ in
                self?.onSourceSwitch?()
                self?.showControls()
            })
        }
        sheet.addAction(UIAlertAction(title: "Chất lượng", style: .default) { [weak self] _ in
            self?.muQualityTapped()
        })
        sheet.addAction(UIAlertAction(title: "Âm thanh & phụ đề", style: .default) { [weak self] _ in
            self?.muAudioTapped()
        })
        sheet.addAction(UIAlertAction(title: "Toàn màn hình", style: .default) { [weak self] _ in
            self?.muToggleFullscreen()
        })
        sheet.addAction(UIAlertAction(title: "Hình trong hình", style: .default) { [weak self] _ in
            self?.togglePiP()
        })
        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel) { [weak self] _ in
            self?.showControls()
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = muChrome?.moreButton ?? closeButton
            popover.sourceRect = (muChrome?.moreButton ?? closeButton).bounds
            popover.delegate = self
        }
        muSheetPresenter().present(sheet, animated: true)
    }

    @objc func muQualityTapped() {
        keepControlsVisible()
        let sheet = UIAlertController(title: "Chất lượng", message: nil, preferredStyle: .actionSheet)
        let options: [(String, Double)] = [("Tự động", 0), ("1080p", 6_000_000), ("720p", 2_200_000)]
        for (label, cap) in options {
            let action = UIAlertAction(
                title: muQualityCap == cap ? "✓ \(label)" : label,
                style: .default
            ) { [weak self] _ in
                guard let self else { return }
                self.muQualityCap = cap
                self.playerItem?.preferredPeakBitRate = cap
                self.updateMUQualityTitle()
                self.showControls()
            }
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel) { [weak self] _ in
            self?.showControls()
        })
        sheet.popoverPresentationController?.sourceView = muChrome?.qualityButton
        // F-2: an iPad outside-tap dismissal runs no action
        // handler — the presentation delegate below releases
        // the keepControlsVisible pin on that path too.
        sheet.popoverPresentationController?.delegate = self
        muSheetPresenter().present(sheet, animated: true)
    }

    /// Audio / subtitles: the item's own media selection
    /// groups, when the stream carries them (many live
    /// streams carry a single audio and no subtitles — the
    /// sheet then says so instead of inventing options).
    @objc func muAudioTapped() {
        guard let item = playerItem else { return }
        keepControlsVisible()
        let asset = item.asset
        let sheet = UIAlertController(title: "Âm thanh / Phụ đề", message: nil, preferredStyle: .actionSheet)
        var added = false
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible), !group.options.isEmpty {
            for option in group.options {
                let selected = item.currentMediaSelection.selectedMediaOption(in: group) == option
                sheet.addAction(UIAlertAction(
                    title: (selected ? "✓ " : "") + "Tiếng: \(option.displayName)",
                    style: .default
                ) { [weak self] _ in
                    item.select(option, in: group)
                    self?.showControls()
                })
                added = true
            }
        }
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible), !group.options.isEmpty {
            sheet.addAction(UIAlertAction(title: "Phụ đề: Tắt", style: .default) { [weak self] _ in
                item.select(nil, in: group)
                self?.showControls()
            })
            for option in group.options {
                let selected = item.currentMediaSelection.selectedMediaOption(in: group) == option
                sheet.addAction(UIAlertAction(
                    title: (selected ? "✓ " : "") + "Phụ đề: \(option.displayName)",
                    style: .default
                ) { [weak self] _ in
                    item.select(option, in: group)
                    self?.showControls()
                })
                added = true
            }
        }
        if !added {
            sheet.message = "Luồng này không có tuỳ chọn âm thanh / phụ đề."
        }
        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel) { [weak self] _ in
            self?.showControls()
        })
        sheet.popoverPresentationController?.sourceView = muChrome?.audioButton
        // F-2: same popover-dismissal pin release as the
        // quality sheet (see muQualityTapped).
        sheet.popoverPresentationController?.delegate = self
        muSheetPresenter().present(sheet, animated: true)
    }
}

/// F-2 (REVIEW-MU2-LOOP2): the MU quality/audio sheets pin
/// the chrome via keepControlsVisible() while they are
/// open, and on iPhone every exit runs an action handler
/// that calls showControls() to re-arm the fade. On iPad
/// the sheets are popovers, and an outside tap dismisses
/// them WITHOUT running any action handler — the pin
/// would hold the chrome over the playing video until the
/// next unrelated interaction. This dismissal hook
/// releases the pin on the interactive-dismissal path
/// too, through the very same re-arm the iPhone exits
/// use: showControls() funnels into scheduleControlsHide,
/// whose firedReady / .playing guards make a redundant
/// call (e.g. after an action handler already re-armed)
/// a no-op.
extension LivePlayerViewController: UIPopoverPresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        showControls()
    }
}

/// FIX-144 (Option A): the fullscreen controller's
/// transitioning delegate — KSPlayer's player view vends
/// its PlayerTransitionAnimator the same way. The
/// animator is built on the surface's saved host
/// superview (the centre reference) and this controller's
/// own root view (the one moving object). Without a saved
/// host (no enter ran), no animator is vended and the
/// presentation falls back to the system default.
extension LivePlayerViewController: UIViewControllerTransitioningDelegate {
    /// FIX-144 gate Round 1 (B-3): the delegate sits on
    /// the surface that PRESENTED the fullscreen
    /// controller, but after a source swap the HOSTED
    /// surface is a successor — the animator must fly
    /// the HOSTED surface's view (and restore toward
    /// ITS saved host slot), never the presenter's
    /// vacated one. Both vending paths therefore resolve
    /// the hosted surface first and fall back to self
    /// (the no-swap case, where the two are identical).
    private func muAnimator(isDismiss: Bool) -> UIViewControllerAnimatedTransitioning? {
        let host = MUFullscreenState.hostedController ?? self
        guard let mu = host.muChrome, let original = mu.hostOriginalSuperview else { return nil }
        return MUFullscreenTransitionAnimator(originalSuperview: original,
                                              animationView: host.view, isDismiss: isDismiss,
                                              owner: host)
    }

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        muAnimator(isDismiss: false)
    }

    func animationController(forDismissed dismissed: UIViewController)
        -> UIViewControllerAnimatedTransitioning? {
        muAnimator(isDismiss: true)
    }
}
