import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Player page (v1.16): a CUSTOM player surface — an AVPlayerLayer
/// with the app's own control layer — embedded full-bleed, exactly
/// like the JTV app's player. One chrome only: close, title,
/// play/pause, AirPlay, PiP and the fit/fill toggle all live in one
/// control layer that fades together after 3.0 s of playing
/// (FIX-130 P-5, the web standard's delay, pause-aware) — but the
/// fade only ever starts once playback is actually ready (DB-05):
/// while a source is still loading, or the ladder is advancing
/// to the next one, the chrome — the close button included —
/// stays visible and tappable, so the viewer is never trapped
/// on a black screen with no exit.
///
/// Why not the system player (the design up to v1.15): the embedded
/// AVPlayerViewController draws its OWN top bar (close + title)
/// next to the app's floating chrome, so every tap showed two
/// close buttons side by side — the owner called it an eyesore and
/// ordered the surface unified with JTV's. AVKit also could not be
/// told to hide just its top bar.
///
/// Why embedded, not modal (the v1.2 lesson, still in force): when
/// PiP starts, iOS dismisses a modally presented player; the host's
/// viewDidAppear then looks exactly like "user closed the player"
/// and the whole page was torn down, killing the PiP stream
/// (owner's clip, 2026-11-12). Embedded, PiP opens in place.
///
/// Pinch-to-fill: a two-finger pinch toggles the layer's
/// videoGravity between resizeAspect (fit) and resizeAspectFill
/// (fill / "tràn viền"), as the owner asked for explicitly.
///
/// Sources + fallback (2026-11-13, synced with the tvOS player):
/// the page receives every source carrying the same match; when a
/// stream fails it advances to the next source automatically, and
/// only when all of them fail does it settle on a "no signal"
/// slate (which keeps its own always-visible close button — there
/// is no video to keep clean there).
///
/// Since 2026-11-19 the sources arrive through a MatchPlaySession
/// (Nuvio optimisation set, bottom of this file): candidates are
/// pre-flight-verified in parallel and publish progressively, so
/// the first source this page plays is already proven alive from
/// this phone, and sources verified later append to the ladder
/// while playback is under way.
///
/// Đổi nguồn (1.22): a fixture playback also carries a source
/// switch in the surface's control layer — the fixture's link
/// board as an overlay, the playing row marked; a Vietnamese
/// pick switches in place inside this session, an English pick
/// (a different session, vended by the addon store) cover-swaps
/// through the host. Design: screen 4 of the owner-approved
/// portrait preview; placement per the 1.21 portrait audit §5.
struct PlayerView: View {
    @ObservedObject var session: MatchPlaySession
    /// The fixture this playback was chosen from (1.21): its
    /// cluster renders in the board-header slot above the waiting
    /// slate (spec §2.4/§2.6) — the same MatchState the lists and
    /// the link board show, never a second truth. Optional: the
    /// pre-1.21 entry points (24/7 channels) pass nil.
    var headerEntry: FixtureEntry? = nil
    /// The fixture's folded English links (1.22), handed in by
    /// the host exactly as the link board receives them — the
    /// Đổi nguồn overlay's EN section. Empty when the fixture
    /// matched no English event (the section is then omitted,
    /// like the board's). Values, not the addon store itself:
    /// the host stays the store's single owner.
    var enMetas: [NuvioMeta] = []
    /// When this player IS an English (addon) session, the meta
    /// it is playing — the overlay marks that EN row "ĐANG
    /// PHÁT". Nil for a playlist session, whose playing row is
    /// marked by channel URL instead.
    var currentENMetaID: String? = nil
    /// Cover-swap requests for the switches this session cannot
    /// serve in place: an English pick (a different session),
    /// or a Vietnamese pick whose link this session never
    /// published. The host dismisses this cover and presents
    /// the other — the board's own dismissal-deferred pattern.
    var onSwitchEN: ((NuvioMeta) -> Void)? = nil
    var onSwitchVN: ((Channel) -> Void)? = nil
    @EnvironmentObject private var store: PlaylistStore
    /// The selected theme (theme-mu): the classic body below
    /// is byte-identical in behaviour; the MU theme swaps the
    /// slate/close chrome and hands the surface its MU chrome
    /// inputs. Playback machinery is shared, untouched.
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    /// FIX-130 (P-2): the rungs this page has already sat on.
    /// advance() walks the session's race order (see
    /// MatchPlaySession.advanceOrder) and must never hand the
    /// player a rung it already left — with a race order the
    /// walk is no longer monotonic in index, so the tried set
    /// is tracked explicitly instead of being implied by the
    /// index. Published rungs are append-only, so an index
    /// keeps naming the same rung for the page's whole life.
    @State private var triedRungs: Set<Int> = []
    @State private var switching = true
    /// The Đổi nguồn overlay (the fixture's link board in its
    /// in-player mode) is up over the playing surface.
    @State private var sourceBoardPresented = false

    /// The header entry re-read with the freshest matched state.
    private var liveHeaderEntry: FixtureEntry? {
        guard var entry = headerEntry else { return nil }
        entry.state = store.state(for: entry.channel)
        entry.competition = LeagueClassifier.competition(
            for: entry.channel, state: entry.state)
        return entry
    }

    /// The board-header slot: the fixture's cluster, shown above
    /// the waiting slate and on the no-signal slate.
    @ViewBuilder
    private var boardHeaderSlot: some View {
        if let liveHeaderEntry {
            BoardHeaderView(entry: liveHeaderEntry)
                .padding(.horizontal, 16)
                .padding(.top, 54)
        }
    }

    private var sources: [Channel] { session.sources }

    private var current: Channel? {
        sources.indices.contains(index) ? sources[index] : nil
    }

    /// Out of sources for good: the session has settled AND the
    /// player has walked past the last published source. While the
    /// session is still verifying, an empty tail is NOT exhaustion
    /// — more sources may still land (the waiting branch below).
    private var settledExhausted: Bool {
        !session.isResolving && index >= sources.count
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if settledExhausted {
                VStack {
                    if !themeStore.isMU {
                        boardHeaderSlot
                    }
                    if themeStore.isMU {
                        muNoSignal
                    } else {
                        noSignal
                    }
                }
                .onAppear {
                    DiagLog.log("player",
                                "no signal: ladder exhausted at #\(index) — "
                                + "'\(headerEntry.map { MatchTitle.clean($0.channel.title) } ?? session.key)'")
                }
                slateClose
            } else if let channel = current, channel.streamURL != nil {
                LivePlayerSurface(
                    channel: channel, onFail: advance,
                    onReady: {
                        switching = false
                        // DB-07: the first frame is up — warm
                        // behind it (see SourcePrewarmStore).
                        // FIX-141: only the next rung, deferred
                        // 5 s; a ready after a switch re-arms the
                        // warm for the new rung. Pure background
                        // work.
                        session.beginPrewarming(after: index)
                    },
                    onDefinitiveFail: { reason in
                        // FIX-129 (Item C): a DEFINITIVE player
                        // failure (see LivePlayerViewController's
                        // classifier) teaches the session: the
                        // URL is marked dead for the session and
                        // the hub, so no later merge, publish or
                        // tap hands it to a player again.
                        session.markPlayerDead(channel, reason: reason)
                    }, onClose: { dismiss() },
                    sourceIndex: index,
                    showsSourceSwitch: headerEntry != nil,
                    onSourceSwitch: {
                        DiagLog.log("player",
                                    "source switch: board opened at source #\(index)")
                        sourceBoardPresented = true
                    },
                    pipSuppressed: sourceBoardPresented,
                    muEnabled: themeStore.isMU,
                    muInfo: muPlayerInfo,
                    muSourcesVN: muChipSourcesVN,
                    muSourcesEN: enMetas,
                    muPlayingENID: currentENMetaID,
                    onMUSelectVN: { channel in switchToVN(channel) },
                    onMUSelectEN: { meta in switchToEN(meta) })
                    .id(index)
                    .ignoresSafeArea()
                if switching {
                    VStack {
                        Spacer()
                        HStack {
                            Text(index == 0 ? "Đang tải…" : "Đang chuyển nguồn khác…")
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.45), in: Capsule())
                            Spacer()
                        }
                        .padding(.leading, 14)
                        .padding(.bottom, 26)
                    }
                    .ignoresSafeArea()
                }
            } else if current != nil {
                // An unparseable URL counts as a failed source.
                Color.clear.onAppear { advance() }
            } else {
                // Past the last published source, but the session
                // is still verifying: wait on black with the
                // switching note instead of declaring the slate.
                // When the next verified source lands, this body
                // re-renders onto it at the same index; when the
                // session settles empty, settledExhausted takes over.
                VStack {
                    if !themeStore.isMU {
                        boardHeaderSlot
                    }
                    Spacer()
                    HStack {
                        Text(index == 0 ? "Đang tải…" : "Đang chuyển nguồn khác…")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.45), in: Capsule())
                        Spacer()
                    }
                    .padding(.leading, 14)
                    .padding(.bottom, 26)
                }
                .ignoresSafeArea()
                .onAppear {
                    // FIX-128: the waiting anchor — the player
                    // has walked past the published ladder but
                    // resolution is still running, so it holds
                    // for the next published batch instead of
                    // declaring signal loss (that slate requires
                    // settledExhausted: settled AND walked past).
                    DiagLog.log("player",
                                "player waiting: past the published ladder at "
                                + "#\(index), resolution still running — "
                                + "holding for the next batch")
                }
                slateClose
            }
        }
        .onAppear {
            DiagLog.log("player",
                        "open: '\(headerEntry.map { MatchTitle.clean($0.channel.title) } ?? current.map { MatchTitle.clean($0.title) } ?? session.key)' "
                        + "starting at source #\(index) (resolving=\(session.isResolving))")
            // FIX-130: the presentation anchor — how much
            // ladder the session already held at the moment
            // this page appeared, so a future log can split
            // tap→first-frame into presentation / head-choice /
            // per-rung load legs (the 1.26-era 29 s gap shape
            // becomes visible again if it ever returns).
            DiagLog.log("player",
                        "player presented: session has \(sources.count) source(s), starting #\(index)")
            if themeStore.isMU {
                // MU (theme-mu): the design carries a portrait
                // page AND a landscape layout, so rotation
                // stays free under MU; classic keeps its
                // landscape lock exactly as before.
                // DB-20 (FIX-134, REVIEW-134 F1): while the
                // button-driven fullscreen state is active this
                // appear assert must NOT widen the lock back to
                // .all — a Đổi nguồn swap replaces this view in
                // place, and SwiftUI gives no ordering
                // guarantee against ContentView's route-change
                // re-assert (the FIX-127B doctrine below), so
                // an unconditional .all here could land last
                // and drop the fullscreen lock mid-player.
                if MUFullscreenState.isActive {
                    OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
                } else {
                    OrientationHelper.lock(.all)
                }
            } else {
                OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
            }
        }
        .task {
            // The opened fixture is first in line for its FotMob
            // incidents (spec §1.2, board-open upgrade).
            if let headerEntry {
                await store.liveStates.ensureDetails(for: headerEntry.channel)
            }
        }
        .sheet(isPresented: $sourceBoardPresented) {
            // The Đổi nguồn overlay: the fixture's own link
            // board in its in-player mode — same rows, same
            // arrangement, the playing row marked. Its row
            // callbacks are the switches below, never a fresh
            // entry into the player. FIX-MU-5 (item E): under
            // an MU-family theme the board wears the MU sheet
            // language (MUBoardView) — same entries, same
            // selection, same callbacks; presentation only.
            if let liveHeaderEntry {
                if themeStore.isMU {
                    MUBoardView(
                        entry: liveHeaderEntry,
                        enMetas: enMetas,
                        onPlayVN: switchToVN,
                        onPlayEN: switchToEN,
                        playingChannelURL: current?.url,
                        playingENMetaID: currentENMetaID)
                        // FIX-133 (audit F17): the board's
                        // sheet carries the MU sheet language's
                        // presentation furniture — the same
                        // detents / drag indicator / 24 radius
                        // the detail source sheet presents
                        // with. MU branch only; the classic
                        // board's presentation is untouched.
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(24)
                } else {
                    MatchBoardView(
                        entry: liveHeaderEntry,
                        enMetas: enMetas,
                        onPlayVN: switchToVN,
                        onPlayEN: switchToEN,
                        inPlayerMode: true,
                        playingChannelURL: current?.url,
                        playingENMetaID: currentENMetaID)
                }
            }
        }
        .onDisappear {
            DiagLog.log("player", "close: player view gone at source #\(index)")
            session.endPrewarming()
            // FIX-127B: no orientation widen here. A Đổi
            // nguồn route flip replaces this view in place
            // inside the still-up cover, and SwiftUI gives
            // no ordering guarantee against the incoming
            // view's onAppear — an unconditional widen could
            // land last and leave the swapped-to player
            // portrait-capable. The lock now follows the
            // presentation: ContentView asserts landscape
            // from the route state and widens to .all only
            // in the cover's onDismiss (a genuine close).
        }
    }

    /// Đổi nguồn to a Vietnamese row: an in-place index set
    /// when this session carries the link — matched by URL,
    /// never by position (the session's ladder is the board's
    /// ladder rotated, and a published entry may be a
    /// Referer-repaired copy of the row's channel; the URL is
    /// the identity that survives both). Playback continues in
    /// the same session. A row this session never published
    /// (verified dead, or not published yet) has no position to
    /// set — the host re-presents a fresh session rotated to
    /// it, the board's own entry path.
    private func switchToVN(_ channel: Channel) {
        // FIX-139: an explicit in-player pick is one of the two
        // callers allowed to expire a stale pre-warm dead
        // verdict for the picked row (see SourcePrewarmStore).
        SourcePrewarmStore.shared.expireDeadIfPicked(channel.url)
        sourceBoardPresented = false
        if let position = session.sources.firstIndex(where: { $0.url == channel.url }) {
            if position != index {
                DiagLog.log("player",
                            "source switch VN in place: #\(index) -> #\(position) \(diagSourceTag(channel))")
                index = position
                switching = true
            } else {
                DiagLog.log("player",
                            "source switch VN: already playing \(diagSourceTag(channel))")
            }
        } else {
            DiagLog.log("player",
                        "source switch VN via host cover-swap: \(diagSourceTag(channel))")
            onSwitchVN?(channel)
        }
    }

    /// Đổi nguồn to an English row: the meta lives in a
    /// different session vended by the addon store, so the
    /// switch is the host's cover swap — except the meta
    /// already playing, which is a no-op beyond closing the
    /// overlay.
    private func switchToEN(_ meta: NuvioMeta) {
        sourceBoardPresented = false
        guard meta.id != currentENMetaID else {
            DiagLog.log("player",
                        "source switch EN: already playing '\(meta.name)'")
            return
        }
        DiagLog.log("player",
                    "source switch EN via host cover-swap: '\(meta.name)'")
        onSwitchEN?(meta)
    }

    /// The slate's own exit (no player surface exists there).
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel("Đóng")
        .padding(.leading, 14)
        .padding(.top, 10)
    }


    // MARK: - MU theme chrome inputs (theme-mu)

    /// The close control for the waiting / no-signal slates:
    /// classic keeps its 36 pt top-left disc; MU gets the
    /// design's 48 pt gold-ring close, top-right (G-5).
    @ViewBuilder
    private var slateClose: some View {
        if themeStore.isMU {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MUTokens.cream)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.35), in: Circle())
                        .overlay(Circle().stroke(MUTokens.gold, lineWidth: 1))
                }
                .accessibilityLabel("Đóng")
            }
            .padding(.trailing, 16)
            .padding(.top, 10)
        } else {
            closeButton
        }
    }

    /// The MU no-signal slate (the classic `noSignal` texts,
    /// in the MU type system).
    private var muNoSignal: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("MẤT TÍN HIỆU")
                .font(MUFont.display(30))
                .muDisplayTracking(30)
                .foregroundStyle(MUTokens.cream)
            Text("Tất cả các nguồn của trận này đều không phát được.")
                .font(MUFont.body(11))
                .foregroundStyle(MUTokens.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// The MU chrome's data for the surface: the playing
    /// channel's display name + commentary note, and the
    /// fixture's teams / crests / score / clock when this
    /// playback came from a fixture — all read from the same
    /// live header entry the classic board header renders.
    private var muPlayerInfo: MUPlayerInfo {
        let entry = liveHeaderEntry
        let isEN = currentENMetaID != nil
        var name = current.map { MatchTitle.clean($0.title) } ?? session.key
        if let entry, !isEN {
            name = muCommentatorName(MatchTitle.clean(entry.channel.title),
                                     group: entry.channel.group)
        }
        if isEN, let meta = enMetas.first(where: { $0.id == currentENMetaID }) {
            name = meta.competitionString ?? meta.channelHint ?? meta.displayName
        }
        var home: String?
        var away: String?
        var score: String?
        var clock: String?
        var status: String?
        if let entry {
            if let teams = entry.teams {
                home = teams.0
                away = teams.1
            }
            if let state = entry.state {
                if let h = state.scoreHome, let a = state.scoreAway {
                    score = "\(h):\(a)"
                }
                clock = state.minuteText ?? state.badgeText
                switch state.status {
                case .live: status = "Đang diễn ra"
                case .halfTime: status = "Nghỉ giữa hiệp"
                case .fullTime: status = "Đã kết thúc"
                case .pre: status = "Sắp diễn ra"
                case .postponed, .cancelled: status = "Hoãn"
                }
            } else if entry.isLive {
                clock = entry.liveBadgeText
                status = "Đang diễn ra"
            }
        }
        let title: String
        if let home, let away {
            title = "\(home) — \(away)"
        } else {
            title = name
        }
        return MUPlayerInfo(
            channelName: name,
            channelNote: "Tự động · Bình luận tiếng \(isEN ? "Anh" : "Việt")",
            homeName: home, awayName: away,
            homeCrest: entry?.crests?.0 ?? nil,
            awayCrest: entry?.crests?.1 ?? nil,
            scoreText: score, clockText: clock,
            isLive: entry?.state?.status.isLiveish ?? entry?.isLive ?? true,
            leagueText: entry?.competitionLabel,
            titleText: title.uppercased(),
            statusText: status)
    }

    /// The MU chip row's Vietnamese sources: the board's
    /// ladder for a fixture playback (board order — the row
    /// switches through switchToVN, in place when this
    /// session carries the link, via the host otherwise);
    /// the session's own published ladder for a direct
    /// channel play, where every chip is servable in place.
    private var muChipSourcesVN: [Channel] {
        if let headerEntry {
            return store.sources(for: headerEntry.channel)
        }
        return session.sources
    }

    private func advance() {
        // FIX-MU-5 (item A, Phát lại): the settings'
        // auto-backup switch gates ONLY this automatic walk.
        // Every AUTO failover funnels through advance() —
        // the item-failure path and the stall watchdog both
        // end in onFail, and the unparseable-URL branch calls
        // it directly — while manual switches (board picks,
        // the MU chips) set the index themselves and never
        // come through here. OFF: no walk — the index steps
        // past the ladder, landing on the waiting branch
        // while the session resolves and on the no-signal
        // slate once it settles, exactly as an exhausted
        // ladder does; the suppression is logged.
        guard MUPlaybackPrefs.autoBackup else {
            DiagLog.log("player",
                        "advance: suppressed — auto-backup OFF in settings; "
                        + "no failover walk from source #\(index)")
            triedRungs.insert(index)
            index = sources.count
            switching = true
            return
        }
        // Unconditional: the walk may land one past the last
        // published source. Each surface fires onFail once per
        // .id(index), so this cannot run away — with current
        // == nil the body re-renders into the waiting branch
        // while the session is still resolving, or the
        // settledExhausted slate once it settles.
        if let channel = current {
            DiagLog.log("player",
                        "advance: leaving source #\(index) \(diagSourceTag(channel))")
        } else {
            DiagLog.log("player",
                        "advance: past the published ladder at #\(index)")
        }
        // FIX-130 (P-2): the next rung is the first UNTRIED
        // rung in the session's failover order — the latency
        // race's order once it has settled, plain ladder order
        // before that (and for sessions that never race). The
        // picked head always started first (D-2); the race
        // orders only what is tried second, third, … When
        // every published rung has been tried, the walk lands
        // past the end, exactly where the old index+1 walk
        // ended: the waiting branch, or the slate once the
        // session settles.
        triedRungs.insert(index)
        let order = session.advanceOrder(in: sources)
        index = order.first(where: { !triedRungs.contains($0) }) ?? sources.count
        // DB-07: a source pre-warming proved dead while an
        // earlier rung played is skipped in place — the ladder
        // steps over it instantly instead of spending a player
        // load on it. Only the automatic advance skips: an
        // explicit board pick (switchToVN) always tries the
        // row the viewer chose.
        while let ch = current, session.isWarmedDead(ch.url) {
            DiagLog.log("player",
                        "advance: skipping pre-warm-dead source #\(index) \(diagSourceTag(ch))")
            triedRungs.insert(index)
            index = order.first(where: { !triedRungs.contains($0) }) ?? sources.count
        }
        switching = true
    }

    private var noSignal: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("MẤT TÍN HIỆU")
                .font(.title.bold())
                .tracking(3)
                .foregroundStyle(.white)
            Text("Tất cả các nguồn của trận này đều không phát được.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One-line source descriptor for DiagLog (DB-06): the cleaned
/// title plus the stream's host — never the full URL, because
/// stream URLs can carry tokens; the existing resolve lines in
/// this file set the same title-only style.
private func diagSourceTag(_ channel: Channel) -> String {
    let host = channel.streamURL?.host ?? URL(string: channel.url)?.host ?? "?"
    return "'\(MatchTitle.clean(channel.title))' host=\(host)"
}

/// SwiftUI wrapper around the custom live-player surface. Plays
/// immediately on appear; pauses and releases on dismantle. The
/// asset carries exactly the headers the entry itself declared
/// (#EXTVLCOPT).
struct LivePlayerSurface: UIViewControllerRepresentable {
    let channel: Channel
    let onFail: () -> Void
    let onReady: () -> Void
    /// FIX-129 (Item C): a DEFINITIVE failure of this surface's
    /// source, classified by the view controller (TLS/certificate
    /// invalid, or HTTP 403/404 in the item's access log), with a
    /// short reason tag. Optional: surfaces that pass nil keep
    /// the pre-FIX-129 behaviour exactly.
    var onDefinitiveFail: ((String) -> Void)? = nil
    let onClose: () -> Void
    /// This surface's rung on the ladder, for DiagLog lines.
    var sourceIndex: Int = 0
    /// Đổi nguồn (1.22): whether the surface shows the switch
    /// button in its control layer (fixture playbacks only —
    /// the page passes headerEntry != nil) and what a tap fires.
    var showsSourceSwitch: Bool = false
    var onSourceSwitch: () -> Void = {}
    /// While the switch overlay is up, auto-PiP is suppressed
    /// so the picture cannot leave inline under the board.
    var pipSuppressed: Bool = false
    /// MU theme chrome inputs (theme-mu): when muEnabled is
    /// false every one of these is ignored and the surface is
    /// the classic one, unchanged.
    var muEnabled: Bool = false
    var muInfo: MUPlayerInfo? = nil
    var muSourcesVN: [Channel] = []
    var muSourcesEN: [NuvioMeta] = []
    var muPlayingENID: String? = nil
    var onMUSelectVN: ((Channel) -> Void)? = nil
    var onMUSelectEN: ((NuvioMeta) -> Void)? = nil

    func makeUIViewController(context: Context) -> LivePlayerViewController {
        let controller = LivePlayerViewController()
        controller.channel = channel
        controller.sourceIndex = sourceIndex
        controller.onFail = onFail
        controller.onReady = onReady
        controller.onDefinitiveFail = onDefinitiveFail
        controller.onClose = onClose
        controller.showsSourceSwitch = showsSourceSwitch
        controller.onSourceSwitch = onSourceSwitch
        controller.pipSuppressed = pipSuppressed
        controller.isMUChrome = muEnabled
        controller.muInfo = muInfo
        controller.muSourcesVN = muSourcesVN
        controller.muSourcesEN = muSourcesEN
        controller.muPlayingENID = muPlayingENID
        controller.onMUSelectVN = onMUSelectVN
        controller.onMUSelectEN = onMUSelectEN
        return controller
    }

    func updateUIViewController(_ uiViewController: LivePlayerViewController, context: Context) {
        uiViewController.setPIPSuppressed(pipSuppressed)
        if uiViewController.isMUChrome {
            uiViewController.muInfo = muInfo
            uiViewController.muSourcesVN = muSourcesVN
            uiViewController.muSourcesEN = muSourcesEN
            uiViewController.muPlayingENID = muPlayingENID
            uiViewController.refreshMUChrome()
        }
    }

    static func dismantleUIViewController(_ uiViewController: LivePlayerViewController, coordinator: ()) {
        uiViewController.teardown()
    }

    static func asset(for channel: Channel) -> AVURLAsset {
        let url = channel.streamURL ?? URL(fileURLWithPath: "/dev/null")
        // The channel's declared headers; for addon (Nuvio)
        // streams the registry adds the rest of the declared
        // proxyHeaders set (Origin, …), with the channel's own
        // pair over it — so a Referer repaired by pre-flight is
        // the one the player sends. For a playlist channel this
        // is exactly the old behaviour: only the declared pair,
        // only when non-empty.
        let headers = NuvioStreamHeaders.playerHeaders(for: channel)
        if headers.isEmpty { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

/// The custom live surface: AVPlayerLayer + one fading control
/// layer (close + title on top; play/pause centred; LIVE badge,
/// AirPlay, PiP and fit/fill along the bottom). Mirrors the JTV
/// player's surface so both of the owner's apps feel identical.
final class LivePlayerViewController: UIViewController {
    var channel: Channel?
    /// This surface's rung on the ladder, for DiagLog lines.
    var sourceIndex = 0
    var onFail: (() -> Void)?
    var onReady: (() -> Void)?
    /// FIX-129 (Item C): fired (with a reason tag) when this
    /// surface's failure is DEFINITIVE — see
    /// definitiveFailureReason(for:) — just before onFail.
    var onDefinitiveFail: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// Đổi nguồn (1.22), vended by the surface like the other
    /// callbacks: whether the switch button joins the control
    /// layer, and what a tap fires. pipSuppressed is re-applied
    /// by the representable on every update (setPIPSuppressed).
    var showsSourceSwitch = false
    var onSourceSwitch: (() -> Void)?
    var pipSuppressed = false
    /// MU theme chrome state (theme-mu): set by the surface
    /// before the view loads when the MU theme is active; the
    /// MU control layer itself lives in MUPlayerChrome.swift.
    /// The classic chrome never reads any of it.
    var isMUChrome = false
    var muInfo: MUPlayerInfo?
    var muSourcesVN: [Channel] = []
    var muSourcesEN: [NuvioMeta] = []
    var muPlayingENID: String?
    var onMUSelectVN: ((Channel) -> Void)?
    var onMUSelectEN: ((NuvioMeta) -> Void)?
    var muChrome: MUChromeViews?
    /// The MU quality chip's rendition cap (0 = Tự động).
    var muQualityCap: Double = 0

    let videoView = PlayerLayerView()
    let controlsView = UIView()
    let closeButton = UIButton(type: .system)
    private let sourceSwitchButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    let playPauseButton = UIButton(type: .system)
    let spinner = UIActivityIndicatorView(style: .large)
    var pipButton = UIButton(type: .system)
    let fillButton = UIButton(type: .system)
    private let liveBadge = UILabel()

    var player: AVPlayer?
    /// FIX-129 (Item C): the playing item, kept so its access
    /// log can be read at failure time (the HTTP status of the
    /// request that failed lives there, not in item.error).
    var playerItem: AVPlayerItem?
    var pipController: AVPictureInPictureController?
    private var statusToken: NSKeyValueObservation?
    private var timeControlToken: NSKeyValueObservation?
    /// FIX-130 (P-3): the loadedTimeRanges observation feeding
    /// the stall watchdog's progress clock.
    private var progressToken: NSKeyValueObservation?
    private var failToken: NSObjectProtocol?
    private var firedFail = false
    private var firedReady = false
    private var firedPlaying = false
    private var hideTimer: Timer?
    /// FIX-130 (P-3): the stall watchdog (DB-11). AVPlayer has
    /// no stall event: a source that connects but never
    /// delivers playable data — and never flips its item to
    /// .failed — held this surface forever, at tap time and
    /// mid-ladder alike. The watchdog is a plain timer armed
    /// while timeControlStatus is .waitingToPlayAtSpecifiedRate
    /// and disarmed on .playing / .paused / teardown; ANY
    /// playback progress (loadedTimeRanges advancing, or the
    /// status reaching .playing) resets its clock (leader
    /// decision D-1). Thresholds: 6 s before the first frame,
    /// 10 s mid-play — mid-play live stalls self-heal more
    /// often, so they earn the longer leash.
    private var stallTimer: Timer?
    private var lastLoadedRangeEnd: TimeInterval = -1
    private var controlsVisible = true
    private var torn = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let channel else { return }
        DiagLog.log("player",
                    "try source #\(sourceIndex): \(diagSourceTag(channel))")

        // Audio session for background / PiP playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(asset: LivePlayerSurface.asset(for: channel))
        playerItem = item
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = AVMetadataIdentifier.commonIdentifierTitle
        titleItem.value = channel.title as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        self.player = player
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        if isMUChrome {
            // FIX-MU-5 (item A, Phát lại): the settings'
            // default quality is the MU player's STARTING
            // cap — the same bit-rate values the in-player
            // quality sheet applies (muQualityTapped); Tự
            // động (cap 0) leaves the item uncapped. The
            // in-player sheet can still change it live.
            muQualityCap = MUPlaybackPrefs.qualityCap
            item.preferredPeakBitRate = muQualityCap
            buildMUControls(channel: channel)
        } else {
            buildControls(channel: channel)
        }
        observe(item: item, player: player)
        setupRemoteCommands(channel: channel)
        player.play()
        // FIX-130 (P-3): arm the stall watchdog for the
        // pre-frame wait right away — the status KVO below
        // re-arms it on every entry into .waiting, but a load
        // that never leaves the initial waiting state must be
        // covered from the first second.
        armStallWatchdog()
        // DB-05: NO hide timer here. The chrome starts visible and
        // stays visible until the item is ready to play — the
        // fade clock starts in the ready handler below, and
        // scheduleControlsHide() itself refuses to run before
        // that, so no path can fade the close button out from
        // under a viewer who is still waiting for signal.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoView.frame = view.bounds
        controlsView.frame = view.bounds
        if isMUChrome {
            layoutMUChrome()
        }
    }

    /// FIX-141: own the rotation transition for the MU
    /// chrome (DIAG-140 §4.3, §5 direction 9). Before this,
    /// the MU layout derived its page purely from
    /// view.bounds at whatever layout pass happened to run,
    /// so a mid-transition pass could compute the portrait
    /// page on landscape bounds (or vice versa) and leave
    /// videoView.frame as the narrow strip the owner filmed,
    /// with no pass re-asserting the settled layout. Now:
    /// the transition is marked in flight on the chrome's
    /// state bag (muToggleFullscreen coalesces against it),
    /// the alongside animation lays the chrome out against
    /// the transition's FINAL size, and the completion
    /// clears the flag and re-asserts the settled layout
    /// through viewDidLayoutSubviews with the real final
    /// bounds. The classic (non-MU) surface is unaffected:
    /// the guard makes this a no-op when isMUChrome is false.
    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard isMUChrome, let mu = muChrome else { return }
        mu.transitionInFlight = true
        let started = coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.layoutMUChrome(targetSize: size)
        }, completion: { [weak self] _ in
            guard let self, let mu = self.muChrome else { return }
            mu.transitionInFlight = false
            // The settle re-assertion: one more layout pass
            // keyed to the real, settled bounds.
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        })
        if !started {
            // No coordinator animation could be scheduled:
            // still lay out against the target size and
            // clear the flag, so the chrome never sits in
            // the coalescing state with no transition to
            // complete it.
            layoutMUChrome(targetSize: size)
            mu.transitionInFlight = false
        }
    }

    // MARK: - Controls

    private func buildControls(channel: Channel) {
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controlsView)

        func roundButton(_ button: UIButton, _ systemName: String, _ action: Selector,
                         size: CGFloat = 40) {
            button.setImage(UIImage(systemName: systemName), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            button.layer.cornerRadius = size / 2
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: size).isActive = true
            button.heightAnchor.constraint(equalToConstant: size).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
        }

        // FIX-130 (P-5, leader decision D-3): the close button
        // adopts the web standard exactly — TOP-RIGHT, 52 pt,
        // safe-area respected (its constraints below anchor to
        // safeAreaLayoutGuide). It was 40 pt at top-left.
        roundButton(closeButton, "xmark", #selector(closeTapped), size: 52)
        controlsView.addSubview(closeButton)

        // The Đổi nguồn button (1.22): in the close button's
        // exact chrome, inside controlsView so it inherits the
        // 3 s fade and the tap-to-show behaviour. Only a
        // fixture playback has a board to switch among; the
        // surface is told via showsSourceSwitch. FIX-130 (P-5):
        // it now sits immediately LEFT of the close button —
        // the top-right corner belongs to close per the web
        // standard.
        if showsSourceSwitch {
            roundButton(sourceSwitchButton, "arrow.triangle.2.circlepath", #selector(sourceSwitchTapped))
            sourceSwitchButton.accessibilityLabel = "Đổi nguồn"
            controlsView.addSubview(sourceSwitchButton)
        }

        titleLabel.text = MatchTitle.clean(channel.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(titleLabel)

        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playPauseButton.layer.cornerRadius = 36
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        controlsView.addSubview(playPauseButton)

        liveBadge.text = "● TRỰC TIẾP"
        liveBadge.font = .systemFont(ofSize: 11, weight: .bold)
        liveBadge.textColor = .systemRed
        liveBadge.translatesAutoresizingMaskIntoConstraints = false

        let routePicker = AVRoutePickerView()
        routePicker.prioritizesVideoDevices = true
        routePicker.tintColor = .white
        routePicker.activeTintColor = .systemOrange
        routePicker.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        routePicker.layer.cornerRadius = 20
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.widthAnchor.constraint(equalToConstant: 40).isActive = true
        routePicker.heightAnchor.constraint(equalToConstant: 40).isActive = true

        roundButton(pipButton, "pip.enter", #selector(togglePiP))
        pipButton.isHidden = !AVPictureInPictureController.isPictureInPictureSupported()

        roundButton(fillButton, "arrow.up.left.and.arrow.down.right", #selector(toggleFill))

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottomRow = UIStackView(arrangedSubviews: [liveBadge, spacer, routePicker, pipButton, fillButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .center
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            // FIX-130 (P-5, D-3): close at top-RIGHT against
            // the safe area (the web standard's placement);
            // the title now runs from the safe area's leading
            // edge and truncates before the close button (or
            // the switch button beside it — see below).
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])
        if showsSourceSwitch {
            // The switch button rides immediately left of the
            // close button, and the title truncates before IT,
            // never under either button.
            NSLayoutConstraint.activate([
                sourceSwitchButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
                sourceSwitchButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceSwitchButton.leadingAnchor, constant: -12),
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            ])
        }

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
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
    }

    // MARK: - Observation (the old Coordinator's semantics, in place)

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // Read the status VALUE here and hop: the KVO handler is a
            // non-isolated context, the VC's state is main-actor
            // state (Swift 6).
            let status = item.status
            let itemError = item.error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if !firedReady {
                        firedReady = true
                        if let channel {
                            DiagLog.log("player",
                                        "source #\(sourceIndex) ready: \(diagSourceTag(channel))")
                        }
                        self.onReady?()
                        // DB-05: the fade clock starts only once
                        // playback is real — scheduleControlsHide
                        // arms it here, and FIX-130 (P-5) completes
                        // the arming at the .playing transition if
                        // the status has not flipped yet.
                        self.scheduleControlsHide()
                    }
                case .failed:
                    noteFailure(itemError)
                default:
                    break
                }
            }
        }
        failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error
            self?.noteFailure(error)
        }
        timeControlToken = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.refreshPlaybackUI(player) }
        }
        // FIX-130 (P-3): loadedTimeRanges advancing IS
        // playback progress — the watchdog's clock resets on
        // it (D-1), so a slow-but-alive live edge is never
        // advanced past while its buffer keeps growing.
        progressToken = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            let ranges = item.loadedTimeRanges
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let end = ranges.map { $0.timeRangeValue.end.seconds }
                    .filter { $0.isFinite }
                    .max() ?? -1
                if end > self.lastLoadedRangeEnd + 0.25 {
                    self.lastLoadedRangeEnd = end
                    self.notePlaybackProgress()
                }
            }
        }
    }

    private func fireFailOnce() {
        guard !firedFail else { return }
        firedFail = true
        DispatchQueue.main.async { self.onFail?() }
    }

    /// DB-06: write the failure (with AVFoundation's reason when
    /// it offers one) exactly once per surface, then run the
    /// page's fail path. Both failure signals (item status and
    /// the failed-to-end notification) funnel through here; the
    /// firedFail guard keeps it to a single line.
    private func noteFailure(_ error: Error?) {
        guard !firedFail else { return }
        disarmStallWatchdog()
        if let channel {
            DiagLog.log("player",
                        "source #\(sourceIndex) failed: \(diagSourceTag(channel))"
                        + (error.map { " — \($0.localizedDescription)" } ?? ""))
        }
        // FIX-129 (Item C): a definitive failure teaches the
        // session BEFORE the page advances, so the resolve
        // still running behind this player cannot merge the
        // same URL back onto the ladder (see markPlayerDead).
        if let reason = definitiveFailureReason(for: error) {
            onDefinitiveFail?(reason)
        }
        fireFailOnce()
    }

    /// FIX-129 (Item C): classify a PLAYER-observed failure as
    /// definitive, or not. Definitive means the URL itself is
    /// condemned for this app run — the failure cannot heal
    /// within the session:
    /// - HTTP 403 / 404, read from the item's ACCESS LOG
    ///   (AVPlayerItemAccessLogEvent.errorStatusCode — the most
    ///   recent error event at failure time): AVPlayerItem.error
    ///   does not carry the HTTP status, the access log does.
    /// - A TLS/certificate failure: NSURLErrorDomain secure-
    ///   connection codes (-1200…-1206: failed, bad date,
    ///   untrusted, unknown root, not yet valid, client cert
    ///   rejected/required), searched through the underlying-
    ///   error chain, with the stable localized text
    ///   ("…certificate…") as a fallback when the error arrives
    ///   wrapped in an AVFoundation domain.
    /// Everything else — timeouts, stalls, 5xx, generic network
    /// errors — returns nil and marks NOTHING (house doctrine:
    /// only definitive verdicts condemn).
    ///
    /// How this differs from pre-flight's KEPT-403: pre-flight's
    /// 403 is a bare probe's answer, which on this household's
    /// network can mean "the tunnel is off right now", so the
    /// source is kept (demoted, still playable). A 403 the
    /// PLAYER receives is a different observation: the source
    /// had already been published to the viewer — verified, or
    /// the instant head he picked — and the full playback
    /// request, with the channel's own headers and repaired
    /// Referer, was still refused (or the playlist is simply
    /// gone: 404). That verdict is about THIS URL as served to
    /// the player, and it condemns only that URL, for this
    /// session/run — pre-flight's kept-403 handling is
    /// untouched and still governs sources the player has not
    /// tried.
    private func definitiveFailureReason(for error: Error?) -> String? {
        if let events = playerItem?.errorLog()?.events {
            for event in events.reversed() where event.errorStatusCode != 0 {
                if event.errorStatusCode == 403 || event.errorStatusCode == 404 {
                    return "HTTP \(event.errorStatusCode)"
                }
                break // the newest error event is not a 403/404
            }
        }
        var current = error as NSError?
        var depth = 0
        while let ns = current, depth < 3 {
            if ns.domain == NSURLErrorDomain, (-1206 ... -1200).contains(ns.code) {
                return "TLS/certificate invalid"
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        if let text = error?.localizedDescription.lowercased(),
           text.contains("certificate") {
            return "TLS/certificate invalid"
        }
        return nil
    }

    // MARK: - Stall watchdog (FIX-130 P-3 — DB-11)

    /// Arm (or re-arm) the watchdog with the threshold for
    /// this surface's phase: 6 s before the first frame has
    /// ever played, 10 s once playback has flowed (D-1).
    private func armStallWatchdog() {
        stallTimer?.invalidate()
        let threshold: TimeInterval = firedPlaying ? 10 : 6
        stallTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            self?.stallWatchdogFired(threshold: threshold)
        }
    }

    private func disarmStallWatchdog() {
        stallTimer?.invalidate()
        stallTimer = nil
    }

    /// Playback progress (D-1): while the player is waiting,
    /// progress restarts the watchdog's clock from zero. While
    /// it is playing the watchdog is disarmed anyway, so
    /// progress there needs no bookkeeping.
    private func notePlaybackProgress() {
        guard player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        else { return }
        armStallWatchdog()
    }

    /// The watchdog expired: no playback progress inside the
    /// threshold. Log the stall, run the same definitive-
    /// classification attempt an explicit failure gets (a
    /// stall whose access log carries a 403/404 still teaches
    /// markPlayerDead), then fire the EXISTING fail path — so
    /// advance, skip and slate logic are reused untouched.
    private func stallWatchdogFired(threshold: TimeInterval) {
        guard !firedFail, !torn else { return }
        if let channel {
            DiagLog.log("player",
                        "stall: source #\(sourceIndex) \(diagSourceTag(channel)) "
                        + "— no playback progress in \(Int(threshold))s, advancing")
        }
        if let reason = definitiveFailureReason(for: playerItem?.error) {
            onDefinitiveFail?(reason)
        }
        fireFailOnce()
    }

    private func refreshPlaybackUI(_ player: AVPlayer) {
        switch player.timeControlStatus {
        case .playing:
            spinner.stopAnimating()
            // FIX-130 (P-3): reaching .playing IS progress —
            // the watchdog's clock is moot while frames flow.
            disarmStallWatchdog()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            if !firedPlaying {
                firedPlaying = true
                // DB-07: the tap→play timeline's last anchor —
                // frames are actually flowing (distinct from
                // .readyToPlay, which only promises them).
                if let channel {
                    DiagLog.log("player",
                                "playback started: source #\(sourceIndex) \(diagSourceTag(channel))")
                }
            }
            // Playback is (again) real: resume the normal fade.
            scheduleControlsHide()
        case .waitingToPlayAtSpecifiedRate:
            spinner.startAnimating()
            // FIX-130 (P-3): entering a wait (re)arms the
            // stall watchdog — pre-frame at 6 s, mid-play at
            // 10 s (armStallWatchdog picks by firedPlaying).
            armStallWatchdog()
            // DB-05: while the spinner runs — first load or a
            // mid-stream stall — the chrome stays up, close
            // button included; any pending fade is cancelled.
            keepControlsVisible()
        case .paused:
            spinner.stopAnimating()
            // FIX-130 (P-3): a paused player is not stalling —
            // the viewer chose the stillness.
            disarmStallWatchdog()
            // FIX-130 (P-5): pause forces the chrome visible
            // and kills any pending fade (the web's rule) — a
            // paused viewer keeps the controls, close included,
            // for as long as the pause lasts.
            keepControlsVisible()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        @unknown default:
            break
        }
    }

    // MARK: - Actions

    @objc func closeTapped() { onClose?() }

    @objc private func sourceSwitchTapped() {
        onSourceSwitch?()
        showControls()
    }

    /// Auto-PiP suppression (1.22): while the Đổi nguồn overlay
    /// is up, the picture must not leave inline under the board.
    /// The representable re-applies this on every update, so it
    /// tracks the overlay's presentation exactly.
    func setPIPSuppressed(_ suppressed: Bool) {
        let changed = suppressed != pipSuppressed
        pipSuppressed = suppressed
        pipController?.canStartPictureInPictureAutomaticallyFromInline = !suppressed
        // theme-mu (the P-3 standard, both themes): while a
        // sheet is open over the player the chrome must not
        // auto-hide under it; when the sheet closes the fade
        // re-arms through the usual guards (ready + playing).
        if changed {
            if suppressed {
                keepControlsVisible()
            } else {
                scheduleControlsHide()
            }
        }
    }

    @objc func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        refreshPlaybackUI(player)
        showControls()
    }

    @objc func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
        showControls()
    }

    @objc func toggleFill() {
        let layer = videoView.playerLayer
        layer.videoGravity = layer.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
        showControls()
    }

    /// Spread (scale > 1) fills the screen, pinch (scale < 1)
    /// returns to fit — the owner's thresholds from the AVKit era.
    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        let layer = videoView.playerLayer
        if gesture.scale > 1.12, layer.videoGravity != .resizeAspectFill {
            layer.videoGravity = .resizeAspectFill
        } else if gesture.scale < 0.88, layer.videoGravity != .resizeAspect {
            layer.videoGravity = .resizeAspect
        }
    }

    @objc func toggleControls() {
        // N-1 (REVIEW-125-LOOP1): before the first ready a tap
        // must never hide the chrome — the close button has to
        // stay reachable for the whole wait, even when the item
        // sits in one waiting state without a status change to
        // re-pin it. Pre-ready taps only show / keep visible.
        guard firedReady else {
            keepControlsVisible()
            return
        }
        controlsVisible.toggle()
        UIView.animate(withDuration: chromeFadeDuration) { self.controlsView.alpha = self.controlsVisible ? 1 : 0 }
        if controlsVisible { scheduleControlsHide() } else { hideTimer?.invalidate() }
    }

    /// FIX-133 (audit C5 + C14): the chrome fade is the
    /// design's 200 ms at every fade site below — and with
    /// Reduce Motion on there is no fade at all: the alpha
    /// lands instantly, the same gate the SwiftUI press
    /// scale already honours (Theme.swift MUPressButtonStyle).
    private var chromeFadeDuration: TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0 : 0.2
    }

    func showControls() {
        controlsVisible = true
        UIView.animate(withDuration: chromeFadeDuration) { self.controlsView.alpha = 1 }
        scheduleControlsHide()
    }

    /// DB-05: pin the chrome on screen — used whenever the
    /// player is waiting for signal (the spinner is running).
    func keepControlsVisible() {
        hideTimer?.invalidate()
        if !controlsVisible {
            controlsVisible = true
            UIView.animate(withDuration: chromeFadeDuration) { self.controlsView.alpha = 1 }
        }
    }

    func scheduleControlsHide() {
        hideTimer?.invalidate()
        // DB-05: the fade NEVER starts before the first ready —
        // before that the viewer is still waiting for signal and
        // the close button must stay. Every caller (show, toggle,
        // stall recovery) funnels through this one guard.
        guard firedReady else { return }
        // FIX-130 (P-5): pause-aware arming, mirroring the web
        // player's uiArmHide — the fade clock runs ONLY while
        // playback is actually flowing. Arming while paused
        // (e.g. showControls from a button tap on a paused
        // player) is a no-op; the .playing transition re-arms
        // through refreshPlaybackUI.
        guard player?.timeControlStatus == .playing else { return }
        // FIX-130 (P-5): 3.0 s, the web standard's hide delay
        // (was 3.5 s).
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            // The web checks paused again at fire time; a
            // pause that landed after arming keeps the chrome.
            guard self.player?.timeControlStatus == .playing else { return }
            self.controlsVisible = false
            UIView.animate(withDuration: chromeFadeDuration) { self.controlsView.alpha = 0 }
        }
    }

    // MARK: - Now Playing / remote commands (AVKit provided these)

    private func setupRemoteCommands(channel: Channel) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: MatchTitle.clean(channel.title),
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }
    }

    func teardown() {
        guard !torn else { return }
        torn = true
        hideTimer?.invalidate()
        disarmStallWatchdog()
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController = nil
        player?.pause()
        statusToken?.invalidate()
        statusToken = nil
        timeControlToken?.invalidate()
        timeControlToken = nil
        progressToken?.invalidate()
        progressToken = nil
        if let failToken {
            NotificationCenter.default.removeObserver(failToken)
            self.failToken = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        videoView.playerLayer.player = nil
        player = nil
        playerItem = nil
    }
}

extension LivePlayerViewController: AVPictureInPictureControllerDelegate {}

/// A plain view whose layer is the player layer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// SwiftUI wrapper around AVRoutePickerView, preferring video routes so
/// the car's AirPlay video destination (when the car offers one) appears.
/// Used by the channel-list header.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemOrange
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Match source resolution (Nuvio optimisation set, 2026-11-19)

/// The best variant a master playlist declares (RESOLUTION /
/// BANDWIDTH of its top #EXT-X-STREAM-INF entry). The Nuvio addon
/// corrects provider-claimed quality labels from the parsed master
/// playlist (research §3.6); this app displays no quality label
/// anywhere, so the parsed quality is spent where it can act: it
/// orders the verified batch of a match's ladder, best first. A
/// media playlist carries a single variant — nothing to parse —
/// and ranks below any parsed master, keeping its ladder order
/// among its peers.
struct ParsedQuality: Sendable, Comparable {
    let height: Int
    let bandwidth: Int

    static func < (lhs: ParsedQuality, rhs: ParsedQuality) -> Bool {
        (lhs.height, lhs.bandwidth) < (rhs.height, rhs.bandwidth)
    }

    /// Parse a master playlist body; nil when it declares no
    /// variants (a media playlist).
    static func parse(masterPlaylist body: String) -> ParsedQuality? {
        var best: ParsedQuality?
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            var height = 0
            if let r = line.range(of: "RESOLUTION=") {
                let token = line[r.upperBound...].prefix { $0 != "," }
                let parts = token.split(separator: "x")
                if parts.count == 2 { height = Int(parts[1]) ?? 0 }
            }
            var bandwidth = 0
            // Match BANDWIDTH / AVERAGE-BANDWIDTH at token
            // boundaries: "BANDWIDTH=" is a substring of
            // "AVERAGE-BANDWIDTH=", so a range(of:) search matches
            // the average value when it appears first and makes the
            // fallback unreachable. Split the attribute list (the
            // part after the "#EXT-X-STREAM-INF:" prefix) on ","
            // and match whole KEY= prefixes per token instead.
            // BANDWIDTH is primary; AVERAGE-BANDWIDTH is only the
            // fallback when no BANDWIDTH token is present.
            let attributeList = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? line
            var bandwidthValue: Int?
            var averageBandwidthValue: Int?
            for rawToken in attributeList.components(separatedBy: ",") {
                let token = rawToken.trimmingCharacters(in: .whitespaces)
                if token.hasPrefix("BANDWIDTH=") {
                    bandwidthValue = Int(token.dropFirst("BANDWIDTH=".count)) ?? 0
                } else if token.hasPrefix("AVERAGE-BANDWIDTH=") {
                    averageBandwidthValue = Int(token.dropFirst("AVERAGE-BANDWIDTH=".count)) ?? 0
                }
            }
            bandwidth = bandwidthValue ?? averageBandwidthValue ?? 0
            let q = ParsedQuality(height: height, bandwidth: bandwidth)
            if best == nil || q > best! { best = q }
        }
        return best
    }
}

/// What pre-flight learned about one candidate link. `verified`
/// carries the channel the player should use — the ladder entry
/// itself, unless the Referer-repair retry rewrote its referrer —
/// plus the parsed master-playlist quality when there was one.
/// `kept` means "not provably dead from this device": the source
/// is demoted behind every verified one, never dropped (see
/// SourcePreflight for the rules and the one deliberate deviation
/// from the plugin).
private enum PreflightOutcome: Sendable {
    case verified(Channel, ParsedQuality?)
    case kept(Channel)
    case dead
}

/// One-link pre-flight: the client port of the Nuvio addon's
/// verify-before-serve (research §3.1/§3.2), tuned to this app's
/// own measured doctrines (PlaylistStore.LinkProbe):
/// - Definitive death: HTTP 404/410, or HTTP 200 whose body is not
///   a playlist (fake-200 pages, empty bodies, variant-less and
///   segment-less stubs, takedown slates).
/// - 401/403 earns ONE retry with a repaired Referer derived from
///   the stream's own host; on success the repaired Referer is
///   written back into the channel, so the player sends it too
///   (LivePlayerSurface.asset already forwards channel.referrer).
///   A 403 that survives repair is KEPT but demoted, never
///   dropped: on this household's network a 403 can mean "the
///   tunnel is off right now" — the same reason the whole-list
///   validator never hides a link on 403. The plugin drops it;
///   the demotion is the deliberate local deviation.
/// - FIX-141: ONE shot, ≤3 s — no retry loop (DIAG-140-SMOOTH
///   §5 direction 3: the verifier takes the race's shape on the
///   publish path; the old 3-attempt loop made one hanging URL
///   cost 13.5 s). A transient failure (5xx, network error,
///   timeout) is answered from that single fetch: a network-level
///   failure counts as death only for a channel that should be
///   serving right now (live window or 24/7); a 5xx never
///   convicts on its own. Anything retry-shaped belongs to
///   background re-validation, never to a publish gate. The one
///   retry that survives is the Referer repair above: it is a
///   different request, not a repeat of a failed one.
/// Nonisolated, like LinkProbe: it touches no actor state.
private enum SourcePreflight {

    static func verify(_ ch: Channel, session: URLSession, deadline: Date) async -> PreflightOutcome {
        guard let url = ch.streamURL else { return .dead }
        // FIX-141: exactly one fetch (see the type doc). The
        // Referer-repair retry below is the sole second fetch,
        // and only while the session's deadline still allows it.
        switch await fetch(ch, url: url, referrer: ch.referrer, session: session) {
        case .ok(let quality):
            return .verified(ch, quality)
        case .unauthorized:
            // Referer repair: one retry with the Referer the
            // stream's own host implies. Skipped when that is
            // the Referer already sent (nothing to repair), and
            // skipped once the deadline has passed — a repair
            // that cannot land inside the publish window is
            // background work, not this path's.
            if let repaired = repairedReferer(for: url), repaired != ch.referrer,
               Date() < deadline {
                switch await fetch(ch, url: url, referrer: repaired, session: session) {
                case .ok(let quality):
                    let fixed = Channel(title: ch.title, logo: ch.logo, group: ch.group,
                                        url: ch.url, kickoff: ch.kickoff,
                                        leagueRank: ch.leagueRank,
                                        referrer: repaired, userAgent: ch.userAgent)
                    return .verified(fixed, quality)
                case .unauthorized, .transient, .other:
                    return .kept(ch)
                case .dead:
                    return .dead
                }
            }
            return .kept(ch)
        case .dead:
            return .dead
        case .other:
            return .kept(ch)
        case .transient(let networkLevel):
            if Task.isCancelled { return .kept(ch) }
            if networkLevel && mustBeServing(ch) { return .dead }
            return .kept(ch)
        }
    }

    private enum FetchResult {
        case ok(ParsedQuality?)
        case unauthorized
        case dead
        case transient(networkLevel: Bool)
        case other
    }

    /// One bounded fetch: status first, then at most the first
    /// 16 KB of body — a playlist's identity and its variant list
    /// live in its head, and a direct-media URL must never be
    /// downloaded whole just to prove it exists (the whole-list
    /// validator caps its read the same way, at 4 KB).
    private static func fetch(_ ch: Channel, url: URL, referrer: String, session: URLSession) async -> FetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3 // FIX-141: the one shot's cap (was 4)
        // The candidate's full header set: its declared pair,
        // plus — for addon (Nuvio) streams — the rest of the
        // behaviorHints.proxyHeaders set (Origin included) from
        // the registry. The explicit `referrer` argument (the
        // declared one, or the repaired one on the repair retry)
        // always wins. For a playlist channel the registry is
        // empty and this is exactly the old behaviour: the TV
        // default User-Agent when none is declared, a Referer
        // only when one is.
        for (field, value) in NuvioStreamHeaders.requestHeaders(for: ch, referrer: referrer) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch status {
            case 401, 403:
                return .unauthorized
            case 404, 410:
                return .dead
            case 500...599:
                return .transient(networkLevel: false)
            case 200:
                break // classify the body below
            default:
                return .other
            }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 16_384 { break }
            }
            return classify(body: buffer, url: ch.url)
        } catch {
            return .transient(networkLevel: true)
        }
    }

    private static func classify(body: Data, url: String) -> FetchResult {
        if body.isEmpty { return .dead }
        let text = String(decoding: body, as: UTF8.self)
        let path = url.split(separator: "?").first.map(String.init) ?? url
        guard path.lowercased().hasSuffix(".m3u8") else {
            // Direct-media URL: a non-empty 200 body is all the
            // proof available at this layer (same rule as the
            // whole-list validator).
            return .ok(nil)
        }
        guard text.contains("#EXTM3U") else { return .dead }
        // A playlist with neither variants nor segments is a stub
        // (placeholder / takedown slate), not a stream.
        guard text.contains("#EXT-X-STREAM-INF") || text.contains("#EXTINF") else { return .dead }
        if text.lowercased().contains("takedown") { return .dead }
        return .ok(ParsedQuality.parse(masterPlaylist: text))
    }

    /// The Referer a stream's own host implies: scheme://host[:port]/
    /// — the plugin's host-derived repair reduced to its portable
    /// core (its registry/regex chain encodes its own providers).
    private static func repairedReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var out = "\(scheme)://\(host)"
        if let port = url.port { out += ":\(port)" }
        return out + "/"
    }

    /// "Should be serving right now": inside the live window, or a
    /// channel with no kickoff at all (24/7 streams). Same test the
    /// whole-list validator applies.
    private static func mustBeServing(_ ch: Channel, now: Date = Date()) -> Bool {
        ch.kickoff == nil || LeagueClassifier.bucket(of: ch, now: now) == 0
    }
}

/// FIX-130 (P-2): one rung of the latency race — the web
/// board's probeOrder ported to a platform that can read the
/// answer. ONE bounded fetch of the playlist URL in
/// pre-flight's request shape (the channel's declared headers,
/// the registry's proxy headers), NO retries, NO Referer
/// repair, NO body classification: the only question is how
/// fast the host answers. Any HTTP response counts as an
/// answer (even a 403 — the web's opaque no-cors probe counts
/// it too, and ordering is all this lane produces; conviction
/// stays pre-flight's job). Returns the response time in
/// milliseconds, or nil when nothing answered inside the
/// 3 s cap (the request's own timeout enforces it).
/// Nonisolated, like SourcePreflight: it touches no actor
/// state.
private enum SourceRaceProbe {

    static func probe(_ ch: Channel, session: URLSession) async -> Int? {
        guard let url = ch.streamURL else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        for (field, value) in NuvioStreamHeaders.requestHeaders(for: ch, referrer: ch.referrer) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let started = Date()
        do {
            // bytes(for:) returns once the response headers are
            // in — that arrival IS the measurement; the body is
            // never read, and releasing the sequence cancels
            // the transfer.
            let (_, response) = try await session.bytes(for: request)
            guard response is HTTPURLResponse else { return nil }
            return Int(Date().timeIntervalSince(started) * 1000)
        } catch {
            return nil
        }
    }
}

/// One match's source-resolution session: verifies the store's
/// ladder in parallel and publishes the playable order
/// progressively — the client port of the Nuvio addon's progressive
/// publication (research §3.3), with its own numbers: quorum 3
/// verified, soft deadline 3 s, hard deadline 3 s. (FIX-141:
/// the deadlines were 6 s / 15 s — DIAG-140-SMOOTH §5 direction
/// 3 caps the whole publish path at the race's 3 s shape, so a
/// session's kept tail now lands at the same 3 s mark as its
/// soft publish; the quorum is unchanged.)
///
/// Publication contract (the player depends on it):
/// - Nothing publishes until the quorum, or every candidate has
///   settled, or the soft deadline passes with at least one
///   verified source.
/// - The first publish is the verified batch ordered by parsed
///   quality (best first). After that, publication is APPEND-ONLY:
///   the published prefix never moves, so a player already walking
///   the ladder is never disturbed by a late arrival.
/// - Kept (unverifiable but not provably dead) sources append
///   last, in ladder order, when resolution settles or the hard
///   deadline passes. Dead sources never publish.
/// - When nothing at all is playable, sources stays empty and
///   isResolving settles false — the player shows its slate.
@MainActor
final class MatchPlaySession: ObservableObject {
    @Published private(set) var sources: [Channel] = []
    @Published private(set) var isResolving = true

    let key: String
    private var resolveTask: Task<Void, Never>?
    private var started = false
    /// The ladder begin() received, kept for publishHeadNow():
    /// the hub hands a tap its session before the cover reads
    /// sources, and the head must be publishable from the
    /// ladder itself, not from anything verification produced.
    /// Publish-only state: run() verifies the ladder IT was
    /// handed at begin() and never reads this snapshot. A tap
    /// adopting this session in flight re-bases the snapshot
    /// to its own (rotated) ladder — see rebaseSnapshot(to:) —
    /// so the instant head is the tap's pick, not the head of
    /// whoever started the session (REVIEW-130-LOOP2 B-1).
    private var ladderSnapshot: [Channel] = []
    /// DB-07: a tap published the head unverified (see
    /// publishHeadNow) — run()'s publications append behind
    /// it from then on, exactly as after a verified publish.
    private var headPublished = false
    /// FIX-128: the "ladder first batch" DiagLog line fires
    /// once per session, at run()'s first publication.
    private var didLogFirstBatch = false
    /// FIX-128B: run() has made its FINAL publication (the
    /// one that appends the kept tail — including a final
    /// publication that lands ZERO rungs: every candidate
    /// dead, or the hard deadline empty-handed). Set inside
    /// publish(final:) at the moment of that publish, so it
    /// is already true while run() is still draining its
    /// task group afterwards. adoptSeed and publishHeadNow
    /// both refuse once this is set: after the final publish
    /// the ladder is settled, and nothing may be injected
    /// into it for noteResolved to mistake for this run's
    /// own result (REVIEW-128-LOOP1 F-1).
    private var didPublishFinal = false
    /// FIX-129 (Item C): URLs the PLAYER itself failed with a
    /// definitive error during this session (see
    /// markPlayerDead). run()'s publications never merge one
    /// back onto the ladder, and the settle writes them into
    /// the cache entry's dead set, so the condemnation outlives
    /// the session through ResolveHub.provenDead.
    private var playerDeadURLs: Set<String> = []
    /// FIX-130 (P-2): the latency race's result — the ladder's
    /// URLs ordered fastest-responder first (non-responders
    /// last, in ladder order), set once when the race settles.
    /// It annotates ONLY the order PlayerView.advance() walks
    /// (see advanceOrder(in:)): the picked head always starts
    /// (leader decision D-2, the conservative form), and
    /// run()'s publications are never re-ordered by it — the
    /// published prefix never moves (R-2).
    private var raceOrderURLs: [String]?
    private var raceTask: Task<Void, Never>?
    /// FIX-141: the deferred single-rung warm armed by
    /// beginPrewarming(after:) — see its doc. Cancelled and
    /// re-armed on every switch; cancelled for good by
    /// endPrewarming().
    private var prewarmTask: Task<Void, Never>?

    nonisolated private static let quorum = 3
    // FIX-141: both deadlines at the 3 s cap (were 6 s / 15 s).
    nonisolated private static let softDeadline: TimeInterval = 3
    nonisolated private static let hardDeadline: TimeInterval = 3

    init(key: String) {
        self.key = key
    }

    /// A session born complete (fresh resolve-cache hit): the
    /// cached ladder publishes instantly, with no network at all.
    static func cached(key: String, sources: [Channel]) -> MatchPlaySession {
        let session = MatchPlaySession(key: key)
        session.sources = sources
        session.isResolving = false
        session.started = true
        return session
    }

    /// FIX-128: a session born with a STALE resolve-cache
    /// ladder already published (the tvOS read path: a cached
    /// resolution is adopted, never discarded for age — see
    /// ResolveHub). The replayed ladder excludes every source
    /// the resolve that produced it proved dead (the cache
    /// write filters them), so the player starts on a
    /// previously-verified rung in the same state change as
    /// the tap; `beginRevalidation(ladder:)` then re-resolves
    /// behind it and run()'s publications merge into the
    /// replayed ladder exactly as behind an instant head (the
    /// published prefix never moves). The hub registers the
    /// session in its in-flight table before calling
    /// beginRevalidation, so the settle-time hub writes meet
    /// their identity guards satisfied.
    static func seeded(key: String, sources: [Channel]) -> MatchPlaySession {
        let session = MatchPlaySession(key: key)
        session.sources = sources
        session.headPublished = true
        session.started = true
        return session
    }

    /// FIX-128: replay a stale cached ladder into this
    /// session while it is still empty (a tap adopting an
    /// in-flight session whose verification has not published
    /// yet — the board-open pre-resolve in the 285 s case).
    /// The replay becomes the published prefix: this session's
    /// own publications merge behind it exactly as behind an
    /// instant head, so verification continues behind a ladder
    /// the player can already walk. No-op once anything has
    /// published — a live ladder is never re-based.
    /// FIX-128B: "anything has published" includes a final
    /// publish that landed ZERO rungs (sources stays empty,
    /// so the sources.isEmpty check alone cannot see it):
    /// the didPublishFinal gate is what refuses the seed
    /// while run() drains its task group after that publish.
    func adoptSeed(_ seed: [Channel]) {
        guard isResolving, !didPublishFinal, sources.isEmpty, !seed.isEmpty else { return }
        headPublished = true
        sources = seed
    }

    /// Starts the background re-resolution behind a seeded
    /// (stale-adopted) ladder. The current ladder is verified
    /// in full; nothing about the replayed prefix changes
    /// while it runs.
    func beginRevalidation(ladder: [Channel]) {
        ladderSnapshot = ladder
        guard !ladder.isEmpty else {
            // Unreachable through the hub (a stale entry's key
            // is its ladder's URLs, so a matching empty ladder
            // means an empty entry, which never takes the
            // stale path) — kept to begin()'s shape: an empty
            // ladder settles as a negative entry.
            isResolving = false
            ResolveHub.shared.noteResolved(key: key, sources: [], from: self)
            return
        }
        resolveTask = Task { [weak self] in
            await self?.run(ladder: ladder)
        }
    }

    func begin(ladder: [Channel]) {
        guard !started else { return }
        started = true
        ladderSnapshot = ladder
        guard !ladder.isEmpty else {
            isResolving = false
            ResolveHub.shared.noteResolved(key: key, sources: [], from: self)
            return
        }
        resolveTask = Task { [weak self] in
            await self?.run(ladder: ladder)
        }
    }

    /// Stops the verification where it stands (a superseded
    /// pre-resolve pass). Whatever already published stays
    /// published; a cancelled session never writes the cache.
    func cancel() {
        resolveTask?.cancel()
        raceTask?.cancel()
    }

    /// Whether this session's resolve task has been cancelled.
    /// Task cancellation is recorded synchronously by cancel()
    /// (on the main actor), so the hub can treat a cancelled
    /// in-flight session as absent before run() notices and
    /// forgets it itself.
    var isCancelled: Bool {
        resolveTask?.isCancelled ?? false
    }

    /// FIX-130B (REVIEW-130-LOOP2 B-1): re-base the snapshot
    /// to a TAP's ladder when the hub hands this in-flight
    /// session to that tap. FIX-130 (P-8) made the hub key
    /// order-insensitive, so a rotated tap ladder now ADOPTS
    /// the preresolve session instead of starting its own —
    /// and the snapshot still held the preresolve (unrotated)
    /// ladder, so publishHeadNow published the cluster's
    /// first channel instead of the viewer's pick. The
    /// snapshot is publishHeadNow-only state: run() captured
    /// its own ladder at begin() and never reads it, so
    /// re-basing moves no verification and no publication —
    /// it only decides WHICH rung the instant head takes, and
    /// the substitute / last-resort branches read the same
    /// snapshot, so they inherit the tap's order too. The hub
    /// calls this on the main actor immediately before
    /// publishHeadNow(), with no suspension point in between,
    /// so the pair is atomic against any other main-actor
    /// work.
    func rebaseSnapshot(to ladder: [Channel]) {
        ladderSnapshot = ladder
    }

    /// DB-07 (plan D): publish the ladder's head the moment a
    /// tap adopts this session — before any verification. The
    /// head of a tap's ladder is the row the viewer picked
    /// (callers rotate it to the front) and its URL is already
    /// final in the playlist data, so the player starts on it
    /// at once; verification keeps running behind it and its
    /// publications APPEND from here on (run()'s publish
    /// honours headPublished), so the playing rung never
    /// moves. If the head proves dead, the player's own fail
    /// path advances past it — and run() keeps a proven-dead
    /// head out of the cache entry, so the next open does not
    /// inherit it as a proven source.
    ///
    /// FIX-128: the head publish is FILTERED by the verdicts
    /// this app run already holds (the hub's proven-dead set,
    /// fed by every settled resolve, and the pre-warm store's
    /// dead set — both definitive-death only, see isKnownDead).
    /// A picked head already verdicted dead is never handed
    /// to the player to die on again: the first ladder rung
    /// not known dead publishes in its place (the pick's row
    /// stays on the board, marked by the verdicts there; the
    /// session's own verification still re-checks every rung
    /// behind, so a revived source returns through run()'s
    /// publications). FIX-130 (P-4): when EVERY rung is known
    /// dead, the pick still publishes — as the last-resort
    /// rung, with its own log line (see the branch below):
    /// a verdict is a demotion with a 30 s memory, never a
    /// veto at play time.
    ///
    /// FIX-128B: the head publish also refuses once run()
    /// has made its final publication (didPublishFinal): a
    /// session draining its task group after an empty final
    /// publish is settled, and an instant head injected in
    /// that window would be written into the cache by
    /// noteResolved as if it were the run's own result —
    /// the same F-1 window adoptSeed is gated against.
    func publishHeadNow() {
        guard isResolving, sources.isEmpty,
              let head = ladderSnapshot.first else { return }
        // FIX-130 (P-4): the didPublishFinal refusal gets a
        // voice. Together with the last-resort line below,
        // EVERY publishHeadNow outcome now logs — the silent
        // refusal (the 1.29 log's black waiting screen → slate,
        // twice in one run, with nothing in the log to say why)
        // is closed. The F-1 invariant itself is unchanged:
        // after the final publish, nothing is injected (R-1).
        guard !didPublishFinal else {
            DiagLog.log("player",
                        "instant head: refused — session already settled (final publish landed)")
            return
        }
        if isKnownDead(head) {
            // FIX-MU-5 (item A, Phát lại): with auto-backup
            // OFF there is no tap-time promotion either —
            // the viewer's pick publishes exactly as picked
            // (it then stands or falls on its own, and
            // advance() is gated the same way), and the
            // suppression is logged. Verification continues
            // behind it as for any instant head.
            if !MUPlaybackPrefs.autoBackup {
                headPublished = true
                sources = [head]
                DiagLog.log("player",
                            "instant head: picked source \(diagSourceTag(head)) "
                            + "already proven dead this run — auto-backup OFF, "
                            + "publishing the pick as chosen (no promotion)")
                return
            }
            guard let substitute = ladderSnapshot.first(where: { !isKnownDead($0) })
            else {
                // FIX-130 (P-4): the all-dead branch stops
                // being a silent veto. Web doctrine: a
                // known-dead verdict is a DEMOTION, never an
                // exclusion at play time — the pick publishes
                // anyway as the last-resort rung (verdicts
                // carry a 30 s TTL now, so "known dead" may
                // already be stale), and verification keeps
                // running behind it exactly as for any instant
                // head. This is the branch that today returns
                // BEFORE any publish, and didPublishFinal was
                // refused above — the F-1 seam is preserved.
                headPublished = true
                sources = [head]
                DiagLog.log("player",
                            "instant head: all rungs previously convicted — starting at the pick as last resort")
                return
            }
            headPublished = true
            sources = [substitute]
            DiagLog.log("player",
                        "instant head: picked source \(diagSourceTag(head)) "
                        + "already proven dead this run — starting at "
                        + "\(diagSourceTag(substitute)) instead, "
                        + "verification continues behind it")
            return
        }
        headPublished = true
        sources = [head]
        DiagLog.log("player",
                    "instant head: '\(MatchTitle.clean(head.title))' "
                    + "published unverified for the tap — verification continues behind it")
    }

    /// FIX-128: definitive death as this app run has already
    /// judged it — a settled resolve's verdict (the hub's
    /// proven-dead set) or a deep-warm verdict (the pre-warm
    /// store). Both sources convict on pre-flight's standard
    /// only (404/410, a fake-200 body, or a network failure
    /// while the source should be serving); a 403 that
    /// survived Referer repair is KEPT there, never dead, so
    /// the tunnel-off case is never filtered here.
    private func isKnownDead(_ ch: Channel) -> Bool {
        ResolveHub.shared.isProvenDead(ch.url)
            || SourcePrewarmStore.shared.isDead(ch.url)
    }

    /// DB-07: the first frame is up (the view calls this on
    /// every ready) — warm behind the playing rung in the
    /// shared pre-warm store. Pure background work; it never
    /// blocks or slows playback.
    ///
    /// FIX-141 (DIAG-140-SMOOTH §5 direction 4): the warm is
    /// capped to the ONE next rung the player would advance
    /// to — the rung after `index` in advanceOrder — instead
    /// of the old deep-warm of the whole rest of the ladder
    /// (~9 s of post-frame churn sharing the network with the
    /// playing stream in the 1.40 log). It is also DEFERRED:
    /// the warm fires 5 s after this call (the playback-
    /// stability window), so a rung that dies inside its stall
    /// watchdog and advances quickly never spends warm traffic
    /// at all. Every call re-arms: a switch cancels the pending
    /// warm and re-targets the new current rung's successor.
    /// When `index` is the last rung of the advance order there
    /// is nothing behind it to warm.
    func beginPrewarming(after index: Int) {
        let ladder = sources
        guard ladder.indices.contains(index) else { return }
        let order = advanceOrder(in: ladder)
        prewarmTask?.cancel()
        prewarmTask = nil
        guard let position = order.firstIndex(of: index),
              position + 1 < order.count else { return }
        let target = ladder[order[position + 1]]
        prewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self != nil else { return }
            SourcePrewarmStore.shared.warm(ladder: [target])
        }
    }

    /// The player closed: stop spending bandwidth on warm-ups
    /// that have not started yet — including the deferred
    /// FIX-141 warm, which may still be inside its 5 s window.
    func endPrewarming() {
        prewarmTask?.cancel()
        prewarmTask = nil
        SourcePrewarmStore.shared.cancelPending()
    }

    /// A source the pre-warmer proved dead (see
    /// SourcePrewarmStore): the player's automatic advance
    /// skips it without spending a player load on it.
    func isWarmedDead(_ url: String) -> Bool {
        SourcePrewarmStore.shared.isDead(url)
    }

    /// FIX-130 (P-2): the order PlayerView.advance() should
    /// walk `ladder` (the session's CURRENT published ladder)
    /// in: the race order first — fastest responder first —
    /// then any rung the race never ordered (a URL published
    /// after the race settled, or every rung when no race has
    /// completed), in ladder order. With no race result this
    /// is plain ladder order, exactly the pre-1.30 walk. The
    /// race annotates this order and nothing else: it never
    /// re-orders, replaces or delays a publication (R-2).
    func advanceOrder(in ladder: [Channel]) -> [Int] {
        guard let raceOrderURLs else { return Array(ladder.indices) }
        var order: [Int] = []
        var used = Set<Int>()
        for url in raceOrderURLs {
            if let i = ladder.firstIndex(where: { $0.url == url }),
               used.insert(i).inserted {
                order.append(i)
            }
        }
        for i in ladder.indices where !used.contains(i) {
            order.append(i)
        }
        return order
    }

    /// FIX-130 (P-2): the latency race itself — every rung of
    /// the ladder probed in parallel (SourceRaceProbe: one
    /// light fetch each, 3 s cap), the results kept as this
    /// session's failover order. Runs as a sibling task of
    /// run()'s verification: it never gates, delays or alters
    /// a publication, and it settles on its own even when
    /// verification finished long before. One DiagLog line at
    /// settle makes the order — and each rung's measured
    /// latency — attributable per session.
    private func runRace(ladder: [Channel]) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var results: [Int: Int] = [:]
        var answered = Set<Int>()
        await withTaskGroup(of: (Int, Int?).self) { group in
            for (i, ch) in ladder.enumerated() {
                group.addTask {
                    (i, await SourceRaceProbe.probe(ch, session: session))
                }
            }
            for await (i, ms) in group {
                if let ms {
                    results[i] = ms
                    answered.insert(i)
                }
            }
        }
        if Task.isCancelled { return }

        let ordered = ladder.indices.sorted { a, b in
            switch (results[a], results[b]) {
            case let (x?, y?):
                if x != y { return x < y }
                return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        raceOrderURLs = ordered.map { ladder[$0].url }
        let parts = ordered.map { i -> String in
            let host = ladder[i].streamURL?.host
                ?? URL(string: ladder[i].url)?.host ?? "?"
            return answered.contains(i)
                ? "\(host) \(results[i] ?? 0)ms"
                : "\(host) —"
        }
        DiagLog.log("player",
                    "probe: race order for "
                    + "'\(ladder.first.map { MatchTitle.clean($0.title) } ?? "?")' "
                    + "— \(parts.joined(separator: ", "))")
    }

    /// FIX-129 (Item C): the player failed this source with a
    /// DEFINITIVE error (TLS/certificate invalid, HTTP 403/404
    /// — classified in LivePlayerViewController). Until now a
    /// player failure taught the ladder nothing: in the 1.28
    /// device log the Castilla head died on an invalid
    /// certificate at 21:35:20Z and the resolve's first batch
    /// one second later merged the SAME URL back in place, and
    /// a second pick re-tried the same host for seconds. The
    /// mark lands in three places: this session's exclusion
    /// set (run()'s merge honours it — see publish(final:)),
    /// the hub's provenDead (so publishHeadNow filters the
    /// URL for later taps while the verdict is inside its
    /// 30 s TTL — FIX-130 P-4 — and this session's settle
    /// writes it into the cache entry's dead set), and one
    /// DiagLog line per URL.
    func markPlayerDead(_ ch: Channel, reason: String) {
        guard playerDeadURLs.insert(ch.url).inserted else { return }
        let host = ch.streamURL?.host ?? URL(string: ch.url)?.host ?? "?"
        DiagLog.log("player", "player-dead: \(host) — \(reason)")
        ResolveHub.shared.notePlayerDead(url: ch.url)
    }

    private func run(ladder: [Channel]) async {
        let total = ladder.count
        let hardDeadline = Date().addingTimeInterval(Self.hardDeadline)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3 // FIX-141 (was 6)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // FIX-130 (P-2): the latency race starts beside the
        // verification — a sibling task, never awaited here,
        // so publication timing is exactly what it was. A
        // one-rung ladder has nothing to order and is not
        // raced. (Born-complete cached sessions never run():
        // their ladder is already resolved, no race needed.)
        if total > 1 {
            raceTask = Task { [weak self] in
                await self?.runRace(ladder: ladder)
            }
        }

        var verified: [(Int, Channel, ParsedQuality?)] = []
        var kept: [(Int, Channel)] = []
        var deadURLs = Set<String>()
        var settled = 0
        var published = false
        var softPassed = false
        var finalPublished = false

        /// Publish per the contract above. `final` also appends
        /// the kept tail.
        func publish(final: Bool) {
            let ordered = verified.sorted { a, b in
                switch (a.2, b.2) {
                case let (qa?, qb?):
                    if qa != qb { return qa > qb }
                    return a.0 < b.0
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.0 < b.0
                }
            }.map { $0.1 }
            // Merge into the published ladder: a channel whose
            // URL is already on the ladder replaces that rung IN
            // PLACE — pre-flight's verified copy can carry a
            // repaired Referer the instant head went out without,
            // and dropping it on URL alone (the old dedup) left
            // the live ladder holding the unrepaired original.
            // The rung's position never changes; only genuinely
            // new URLs append behind.
            func merge(_ incoming: [Channel]) {
                for ch in incoming {
                    // FIX-129 (Item C): a URL the player has
                    // definitively condemned this session never
                    // merges back — neither as a replacement of
                    // its own rung (the Castilla shape: the
                    // instant head died on a certificate error
                    // and the first batch re-published the same
                    // URL in place) nor as an append. A rung
                    // already published stays published (the
                    // prefix never moves); the player has
                    // already advanced past it.
                    if self.playerDeadURLs.contains(ch.url) { continue }
                    if let rung = self.sources.firstIndex(where: { $0.url == ch.url }) {
                        self.sources[rung] = ch
                    } else {
                        self.sources.append(ch)
                    }
                }
            }
            if published || self.headPublished {
                // DB-07: with an instant head already published,
                // the verified batch appends behind it like any
                // later publication — the head rung never moves.
                merge(ordered)
            } else {
                self.sources = ordered
                published = true
            }
            if final {
                // FIX-128B: mark the settle as the kept tail
                // merges — publish() never suspends, so the
                // flag and the merge land atomically with
                // respect to any tap vending this session
                // while run() drains its task group below.
                self.didPublishFinal = true
                merge(kept.sorted { $0.0 < $1.0 }.map { $0.1 })
            }
            // FIX-128: the first-batch anchor of the resolve
            // timeline — the moment the first verified (or
            // kept-tail) publication lands on the ladder.
            if !self.didLogFirstBatch, !self.sources.isEmpty {
                self.didLogFirstBatch = true
                DiagLog.log("player",
                            "ladder first batch: \(self.sources.count) source(s) "
                            + "published for "
                            + "'\(ladder.first.map { MatchTitle.clean($0.title) } ?? "?")'")
            }
        }

        await withTaskGroup(of: (Int, PreflightOutcome?).self) { group in
            for (i, ch) in ladder.enumerated() {
                group.addTask {
                    (i, await SourcePreflight.verify(ch, session: session, deadline: hardDeadline))
                }
            }
            // The deadlines ride the same group as nil outcomes:
            // the soft tick at 3 s, the hard tick at 3 s
            // (FIX-141 — both ticks now land together; the soft
            // tick still publishes the verified batch first when
            // it is processed ahead of the hard tick).
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.softDeadline))
                return (-1, nil)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.hardDeadline))
                return (-2, nil)
            }
            for await (i, outcome) in group {
                if Task.isCancelled { break }
                if finalPublished { continue }
                switch (i, outcome) {
                case (-1, _):
                    softPassed = true
                    if !verified.isEmpty { publish(final: false) }
                case (-2, _):
                    publish(final: true)
                    finalPublished = true
                    group.cancelAll()
                case (_, .verified(let ch, let quality)?):
                    verified.append((i, ch, quality))
                    settled += 1
                    if settled == total {
                        publish(final: true)
                        group.cancelAll()
                    } else if verified.count >= Self.quorum || softPassed {
                        publish(final: false)
                    }
                case (_, .kept(let ch)?):
                    kept.append((i, ch))
                    settled += 1
                    if settled == total {
                        publish(final: true)
                        group.cancelAll()
                    }
                case (_, .dead?):
                    deadURLs.insert(ladder[i].url)
                    settled += 1
                    if settled == total {
                        publish(final: true)
                        group.cancelAll()
                    }
                default:
                    break
                }
            }
        }

        if Task.isCancelled {
            isResolving = false
            ResolveHub.shared.forgetInFlight(key: key, from: self)
            return
        }
        if !published { publish(final: true) }
        isResolving = false
        // DB-07: the live ladder keeps the instant head even
        // when pre-flight later proved it dead (the published
        // prefix never moves under a live player), but the
        // cache entry must not inherit a proven-dead source as
        // playable — the next open resolves it fresh instead.
        ResolveHub.shared.noteResolved(
            key: key,
            sources: sources.filter {
                !deadURLs.contains($0.url) && !playerDeadURLs.contains($0.url)
            },
            deadURLs: deadURLs.union(playerDeadURLs),
            verifiedURLs: Set(verified.map { $0.1.url }),
            from: self)
    }
}

/// One source's deep warm (DB-07, plan D): fetch the playlist,
/// descend a master playlist to its best variant's media
/// playlist, then pull the first segment's head — so the CDN
/// edge nearest this phone and the provider's session are warm
/// before the viewer ever switches to the source, and a source
/// that is provably dead at warm time is known before the
/// ladder spends a player load on it.
///
/// Death is judged at the top playlist only, on exactly
/// pre-flight's standard (HTTP 404/410, or a 200 whose body
/// is not a playlist / is a takedown slate); anything
/// transient — 5xx, 401/403 (the Referer-repair question is
/// pre-flight's, already settled for published sources),
/// network errors — never convicts. The variant and segment
/// fetches below the top playlist run for their warming value
/// only and never judge: a source can lose its top variant, or
/// its oldest segment to the sliding live window, while it
/// still plays.
/// Nonisolated, like SourcePreflight: it touches no actor
/// state.
private enum SourcePrewarmer {

    /// FIX-130 (P-1): the three honest warm outcomes. Until
    /// now warm() answered a Bool — "not dead" — and the store
    /// recorded every non-death as WARM and logged it "ready":
    /// in the 1.29 device log two of the three launch-warm
    /// "ready" verdicts were for v1.livestreambong.tv, the
    /// host whose certificate the player then died on. A
    /// network-level failure (TLS included) proves nothing
    /// about the source either way, so it is now its own
    /// outcome: the store records the source as merely COLD
    /// (never warm, never dead) and a later warm() may retry
    /// it. Only a playlist actually read earns `.verified`;
    /// `.dead` keeps exactly the definitive standard above,
    /// so `SourcePrewarmStore.isDead` semantics — and its
    /// consumers in advance() and isKnownDead — are untouched.
    enum Outcome: Sendable {
        case verified
        case unreachable(String)
        case dead
    }

    static func warm(_ ch: Channel, session: URLSession) async -> Outcome {
        guard let url = ch.streamURL else { return .dead }
        let head: (status: Int, body: Data)
        switch await fetch(ch, url: url, limit: 16_384, session: session) {
        case .networkError(let errorClass):
            return .unreachable(errorClass)
        case .response(let status, let body):
            head = (status, body)
        }
        switch head.status {
        case 404, 410: return .dead
        case 200: break
        default:
            // An HTTP answer that is neither a playlist nor a
            // definitive death (401/403/5xx): the playlist was
            // NOT read, so this is not a verification — the
            // source stays cold, exactly like a network error.
            return .unreachable("HTTP \(head.status)")
        }
        let path = ch.url.split(separator: "?").first.map(String.init) ?? ch.url
        guard path.lowercased().hasSuffix(".m3u8") else {
            // Direct-media URL: nothing structured to prime.
            return .verified
        }
        let text = String(decoding: head.body, as: UTF8.self)
        guard isPlaylist(text) else { return .dead }
        var mediaText = text
        var mediaBase = url
        if text.contains("#EXT-X-STREAM-INF"),
           let variant = bestVariantURL(in: text, base: url) {
            // The descent still runs — fetching the variant
            // playlist is most of the warming value — but its
            // answer never judges (see the death rule above):
            // a failed descent just ends the warm here. The
            // top playlist WAS read, so the warm is verified
            // either way.
            guard case .response(let mediaStatus, let mediaBody) =
                    await fetch(ch, url: variant, limit: 16_384, session: session),
                  mediaStatus == 200
            else { return .verified }
            let variantText = String(decoding: mediaBody, as: UTF8.self)
            guard isPlaylist(variantText) else { return .verified }
            mediaText = variantText
            mediaBase = variant
        }
        if let segment = firstSegmentURL(in: mediaText, base: mediaBase) {
            // Pulled for its warming value only: a 404/410
            // here judges nothing — the oldest segment of a
            // sliding live window can expire between the
            // playlist fetch and this one while the source
            // plays on.
            _ = await fetch(ch, url: segment, limit: 256 * 1024, session: session)
        }
        return .verified
    }

    private static func isPlaylist(_ text: String) -> Bool {
        text.contains("#EXTM3U")
            && (text.contains("#EXT-X-STREAM-INF") || text.contains("#EXTINF"))
            && !text.lowercased().contains("takedown")
    }

    /// One bounded fetch in pre-flight's shape: the channel's
    /// declared header set, a 4 s request timeout, at most
    /// `limit` bytes of body read. FIX-130 (P-1): a
    /// network-level failure is no longer collapsed into the
    /// same nil as every other non-answer — it carries its
    /// error class, so warm() can record the source as
    /// unreachable (cold) instead of certifying it "ready".
    private enum FetchOutcome {
        case response(status: Int, body: Data)
        case networkError(String)
    }

    private static func fetch(_ ch: Channel, url: URL, limit: Int,
                              session: URLSession) async -> FetchOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        for (field, value) in NuvioStreamHeaders.requestHeaders(for: ch, referrer: ch.referrer) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            var buffer = Data()
            if status == 200 {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count > limit { break }
                }
            }
            return .response(status: status, body: buffer)
        } catch {
            return .networkError(errorClass(error))
        }
    }

    /// A short, log-stable class for a network-level failure:
    /// the TLS family by name (the verdict class the 1.29 log
    /// needed — a certificate failure at warm time must read
    /// differently from a timeout), the common NSURLError
    /// shapes by name, anything else by domain + code.
    private static func errorClass(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            return "\(ns.domain) \(ns.code)"
        }
        switch ns.code {
        case -1206 ... -1200: return "TLS/certificate (NSURLError \(ns.code))"
        case -1001: return "timeout (NSURLError \(ns.code))"
        case -1003, -1004, -1006: return "host unreachable (NSURLError \(ns.code))"
        case -1005: return "connection lost (NSURLError \(ns.code))"
        case -1009: return "offline (NSURLError \(ns.code))"
        default: return "network (NSURLError \(ns.code))"
        }
    }

    /// The variant the player meets first when it opens a
    /// master playlist: the highest-BANDWIDTH #EXT-X-STREAM-INF
    /// entry (token-boundary attribute parsing, as in
    /// ParsedQuality.parse).
    private static func bestVariantURL(in text: String, base: URL) -> URL? {
        var best: (bandwidth: Int, uri: String)?
        var pendingBandwidth: Int?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let attributeList = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? line
                var bandwidth = 0
                for rawToken in attributeList.components(separatedBy: ",") {
                    let token = rawToken.trimmingCharacters(in: .whitespaces)
                    if token.hasPrefix("BANDWIDTH=") {
                        bandwidth = Int(token.dropFirst("BANDWIDTH=".count)) ?? 0
                    }
                }
                pendingBandwidth = bandwidth
            } else if !line.isEmpty, !line.hasPrefix("#"), let bw = pendingBandwidth {
                if best == nil || bw > best!.bandwidth { best = (bw, line) }
                pendingBandwidth = nil
            }
        }
        guard let uri = best?.uri else { return nil }
        return URL(string: uri, relativeTo: base)?.absoluteURL
    }

    /// The first segment a media playlist declares.
    private static func firstSegmentURL(in text: String, base: URL) -> URL? {
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
        return nil
    }
}

/// The shared pre-warm queue (DB-07, plan D): deep-warms match
/// sources in the background — from the moment a fixture's link
/// board opens (the viewer's intent is on screen) and continuing
/// inside the player behind the playing source. Priority is the
/// ladder's own order, re-based behind the playing rung when
/// the player asks; at most two warm fetches run at once, every
/// fetch is byte-capped, and the queue only ever touches
/// network state — playback is never blocked by it. A source it
/// proves dead is remembered for the hub's dead-verdict TTL
/// (ResolveHub.provenDeadTTL, 30 s — E1, AUDIT.md), so the
/// player's automatic advance can skip that rung instantly
/// (PlayerView.advance); an explicit board pick still tries
/// the row the viewer chose. FIX-139 (REVIEW-FULL WP3 item 5 /
/// WP6 verdict D3): the TTL expiry is BOUND to that explicit
/// pick — PR 2 expired the verdict lazily inside `state(of:)`,
/// so a plain board open / board render (which reads `state`
/// through `isDead` and `warm`) silently re-enabled a dead
/// host and re-probed it on every board open. Reads are now
/// pure: however old a verdict is, `state(of:)` / `isDead` /
/// `warm` keep honouring it, and only `expireDeadIfPicked` —
/// called from the tap entry (ResolveHub.session, isTap) and
/// from an in-player pick (PlayerView.switchToVN) — may drop
/// a verdict older than the TTL, after which the URL reads as
/// never convicted and a later warm() may warm it again.
/// Warmth is per app run: a source warmed once is not
/// re-fetched for later boards or sessions of the same fixture.
/// FIX-141: warm/dead states now also persist across launches
/// via VerdictDisk (restored in init, ≤30 min old — see the
/// horizon justification there); the FIX-139 read semantics
/// above are unchanged for IN-RUN verdicts — pure reads,
/// pick-bound expiry only. FIX-141 round 2: RESTORED verdicts
/// are the exception — `state(of:)` enforces the 30 min
/// horizon on read for a verdict still carrying its restored
/// stamp (see `restoredStamps`), exactly as ResolveHub's
/// restored tier does, so a restored verdict can never block
/// a since-revived rung for the whole app run.
@MainActor
final class SourcePrewarmStore {
    static let shared = SourcePrewarmStore()

    /// `.dead` carries the time of its verdict (E1), so the
    /// pick-bound expiry in `expireDeadIfPicked` can age it
    /// against the hub's TTL. FIX-139: `state(of:)` itself no
    /// longer expires anything on read (see the class doc).
    /// FIX-141: `.warm` carries its stamp too, so VerdictDisk
    /// can persist warmth with the age it must be judged by on
    /// restore (see the restore horizon there).
    private enum WarmState: Equatable { case warming, warm(Date), dead(Date) }
    private var states: [String: WarmState] = [:]
    /// FIX-141 round 2: the original stamp of every verdict
    /// restored from disk in init, keyed by URL. A stored
    /// state whose stamp still EQUALS its restored stamp is
    /// that restored verdict; any in-run write replaces the
    /// stamp, so equality is what tells the two tiers apart
    /// in `state(of:)`. Mirrors ResolveHub.restoredDead.
    private var restoredStamps: [String: Date] = [:]
    /// FIX-141 round 2: the restored tier's horizon from the
    /// original verdict stamp — restates VerdictDisk's
    /// prewarmHorizon (private to VerdictDisk) here, exactly
    /// as ResolveHub.restoredDeadHorizon restates the dead
    /// horizon; the two must stay equal.
    private static let restoredHorizon: TimeInterval = 30 * 60
    private var pending: [Channel] = []
    private var driver: Task<Void, Never>?
    private var driverToken: UUID?

    private init() {
        // FIX-141: restore the persisted warm/dead states
        // (VerdictDisk already dropped anything past its
        // 30 min horizon). A restored .dead keeps its original
        // stamp, so FIX-139's pick-bound expiry
        // (expireDeadIfPicked, aged against the hub's 30 s TTL)
        // expires it at the first explicit pick — exactly the
        // "a pick expires it" semantics the persisted tier is
        // specified to have. FIX-141 round 2: each restored
        // stamp is also recorded in restoredStamps, so
        // `state(of:)` can enforce the 30 min horizon ON READ
        // for the restored tier (a pick is no longer the only
        // escape — see state(of:)); inside the horizon, reads
        // honour the restored verdict as before.
        for (url, stored) in VerdictDisk.prewarmSlice() {
            let stamp = Date(timeIntervalSince1970: stored.stamp)
            restoredStamps[url] = stamp
            if stored.dead {
                states[url] = .dead(stamp)
            } else {
                states[url] = .warm(stamp)
            }
        }
    }

    /// FIX-141: the persistable slice of the store for
    /// VerdictDisk — settled warm/dead states with their
    /// stamps. `.warming` is in-flight, not a verdict, and is
    /// never persisted.
    func verdictSnapshot() -> [String: VerdictDisk.StoredWarm] {
        var out: [String: VerdictDisk.StoredWarm] = [:]
        for (url, state) in states {
            switch state {
            case .warm(let stamp):
                out[url] = VerdictDisk.StoredWarm(
                    dead: false, stamp: stamp.timeIntervalSince1970)
            case .dead(let stamp):
                out[url] = VerdictDisk.StoredWarm(
                    dead: true, stamp: stamp.timeIntervalSince1970)
            case .warming:
                break
            }
        }
        return out
    }

    func isDead(_ url: String) -> Bool {
        if case .dead? = state(of: url) { return true }
        return false
    }

    /// The URL's state as read now — a PURE read (FIX-139)
    /// for IN-RUN verdicts: it never mutates the store and
    /// never expires an in-run verdict, however old. Board-open
    /// / board-render callers (isDead, warm) therefore cannot
    /// re-enable a dead host as a side effect of merely being
    /// read. In-run expiry lives only in `expireDeadIfPicked`
    /// below.
    /// FIX-141 round 2 — the RESTORED-tier exception: a state
    /// still carrying its restored stamp (see restoredStamps)
    /// is judged against the 30 min restored horizon ON READ,
    /// mirroring ResolveHub.isProvenDead's restored tier: past
    /// the horizon (or future-dated) it is dropped on the spot
    /// — silently, with no VerdictDisk save scheduled; the next
    /// snapshot simply omits it — and the URL reads as never
    /// convicted, so advance() stops skipping it and warm()
    /// may re-warm it. `.warming` carries no stamp and never
    /// matches a restored verdict.
    private func state(of url: String) -> WarmState? {
        guard let state = states[url] else { return nil }
        if let restoredStamp = restoredStamps[url],
           state == .warm(restoredStamp) || state == .dead(restoredStamp) {
            let age = Date().timeIntervalSince(restoredStamp)
            if age < 0 || age > Self.restoredHorizon {
                states[url] = nil
                restoredStamps[url] = nil
                return nil
            }
        }
        return state
    }

    /// FIX-139: the ONLY expiry of a pre-warm dead verdict,
    /// and the explicit-pick bound on it — a dead verdict older
    /// than the hub's TTL (ResolveHub.provenDeadTTL) is dropped
    /// here, and this is called ONLY from the explicit pick /
    /// on-demand paths: ResolveHub.session(for:isTap:) for the
    /// tap's pick (the rotated ladder's head) and
    /// PlayerView.switchToVN for an in-player Đổi nguồn pick.
    /// A verdict inside its TTL is kept even for a pick (the
    /// pick itself still plays — publishHeadNow / switchToVN
    /// never let a verdict veto the viewer's row — it is only
    /// the RE-PROBE, via a later warm(), that the TTL gates).
    /// No timers, no sweeps, no read-side mutation.
    func expireDeadIfPicked(_ url: String) {
        if case .dead(let stampedAt)? = states[url],
           Date().timeIntervalSince(stampedAt) > ResolveHub.provenDeadTTL {
            states[url] = nil
        }
    }

    /// Enqueue a ladder for warming. `startingAfter` re-bases
    /// the priority: the rungs behind that URL go first (the
    /// order the ladder would advance through them), the
    /// earlier rungs after. Sources already warm, warming,
    /// proven dead or explicitly excluded are skipped; the
    /// pending queue is rebuilt in the newest priority order
    /// on every call, so a switch mid-warm re-prioritises
    /// what has not started yet.
    func warm(ladder: [Channel], startingAfter: String? = nil,
              excluding: Set<String> = []) {
        var ordered = ladder
        if let anchor = startingAfter,
           let i = ladder.firstIndex(where: { $0.url == anchor }) {
            ordered = Array(ladder[(i + 1)...]) + Array(ladder[..<i])
        }
        var seen = Set<String>()
        pending = ordered.filter { ch in
            !excluding.contains(ch.url)
                && state(of: ch.url) == nil
                && seen.insert(ch.url).inserted
        }
        startDriverIfNeeded()
    }

    /// The player closed: stop spending bandwidth. In-flight
    /// fetches are cancelled with the driver; sources left
    /// mid-warm fall back to unwarmed (a later board or
    /// session may warm them again), while warm and dead
    /// verdicts are kept.
    func cancelPending() {
        pending = []
        driver?.cancel()
    }

    private func startDriverIfNeeded() {
        guard driver == nil, !pending.isEmpty else { return }
        let token = UUID()
        driverToken = token
        driver = Task { [weak self] in
            await self?.runDriver(token: token)
        }
    }

    private func runDriver(token: UUID) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        var channelsByURL: [String: Channel] = [:]
        /// FIX-129 (Item B): when each in-flight warm started,
        /// for the ready line's elapsed time below.
        var startedAt: [String: Date] = [:]

        /// Pop the next source to warm, in queue order, and
        /// mark it in flight (the same nested-helper shape as
        /// MatchPlaySession.run's publish()).
        func takeNext() -> Channel? {
            guard !pending.isEmpty else { return nil }
            let ch = pending.removeFirst()
            channelsByURL[ch.url] = ch
            states[ch.url] = .warming
            // FIX-129 (Item B): a warm START line per source.
            // Until now the store logged only a proven death,
            // so a device log could not show that warming had
            // happened at all (the 1.28 log carries zero
            // prewarm lines); the start/ready pair below is
            // the evidence the next log is read against.
            startedAt[ch.url] = Date()
            DiagLog.log("player",
                        "prewarm: warming \(diagSourceTag(ch))")
            return ch
        }

        defer {
            session.invalidateAndCancel()
            // Sources left mid-warm by a cancellation are
            // unwarmed again, never half-marked.
            if Task.isCancelled {
                for url in states.filter({ $0.value == .warming }).map(\.key) {
                    states[url] = nil
                }
            }
            if driverToken == token {
                driver = nil
                driverToken = nil
                // A warm() that landed while this driver was
                // unwinding starts a fresh one.
                startDriverIfNeeded()
            }
        }

        await withTaskGroup(of: (String, SourcePrewarmer.Outcome).self) { group in
            var active = 0
            while active < 2, let ch = takeNext() {
                group.addTask { (ch.url, await SourcePrewarmer.warm(ch, session: session)) }
                active += 1
            }
            for await (url, outcome) in group {
                active -= 1
                if !Task.isCancelled {
                    switch outcome {
                    case .dead:
                        states[url] = .dead(Date())
                        VerdictDisk.scheduleSave() // FIX-141
                        if let ch = channelsByURL[url] {
                            DiagLog.log("player",
                                        "prewarm: source proven dead — the ladder will skip it: \(diagSourceTag(ch))")
                        }
                    case .verified:
                        states[url] = .warm(Date()) // FIX-141: stamped (was bare .warm)
                        VerdictDisk.scheduleSave() // FIX-141
                        if let ch = channelsByURL[url] {
                            // FIX-129 (Item B): the warm READY
                            // line (host + elapsed, via
                            // diagSourceTag) — the counterpart
                            // of the start line in takeNext().
                            // FIX-130 (P-1): it now fires ONLY
                            // for a verified warm — the top
                            // playlist was actually read. A
                            // network/TLS failure lands in the
                            // .unreachable branch below and can
                            // never be certified "ready" again.
                            let ms = startedAt[url].map {
                                Int(Date().timeIntervalSince($0) * 1000)
                            } ?? -1
                            DiagLog.log("player",
                                        "prewarm: ready \(diagSourceTag(ch)) in \(ms)ms")
                        }
                    case .unreachable(let errorClass):
                        // FIX-130 (P-1): neither warm nor
                        // dead — the state clears back to
                        // cold, so a later warm() may retry
                        // the source (warm()'s pending filter
                        // admits only stateless URLs), and the
                        // failure is on the log record with
                        // its class.
                        states[url] = nil
                        if let ch = channelsByURL[url] {
                            DiagLog.log("player",
                                        "prewarm: unreachable \(diagSourceTag(ch)) — \(errorClass)")
                        }
                    }
                }
                while active < 2, let ch = takeNext() {
                    group.addTask { (ch.url, await SourcePrewarmer.warm(ch, session: session)) }
                    active += 1
                }
            }
        }
    }
}

/// FIX-141: disk persistence for the verdict stores —
/// ResolveHub's resolve cache + proven-dead set and
/// SourcePrewarmStore's warm/dead states — so a launch or a
/// board open starts from the previous run's knowledge instead
/// of a cold re-verification drain (DIAG-140-SMOOTH §2.2/§5
/// direction 1: every verdict was in-memory only, and the
/// 1.40 log shows the identical drain repeated verbatim at
/// relaunch). One JSON file in Caches, written atomically,
/// mirroring PlaylistStore's invalid-urls.json pattern.
///
/// Restore horizons (applied at load, in the slices below):
/// - Resolve entries: 30 min. The owner's mirror republishes
///   the playlist every 30 min — beyond one republication the
///   ladder itself may have rotated, so an older entry is not
///   knowledge, it is archaeology. Inside the horizon the
///   entry's own TTL / stale-adoption machinery governs:
///   fresh entries replay instantly, stale ones are adopted
///   and revalidated behind the tap.
/// - Proven-dead: 10 min from the ORIGINAL stamp, restored
///   into ResolveHub's separate restored tier (the in-run
///   tier keeps its own 30 s TTL untouched). Long enough to
///   spare a relaunch the dead-host re-proofs, short enough
///   that a host which recovered is not convicted for long.
/// - Prewarm states: 30 min, the same republication cadence
///   as the resolve entries — warmth older than one playlist
///   generation says nothing about the current ladder.
///
/// Failure doctrine: ANY load failure — missing file, corrupt
/// or partial JSON, a version other than 1 — yields an empty
/// payload, never a crash; the app simply starts cold, as it
/// did before FIX-141. The payload is read from disk once per
/// launch and cached; saves are coalesced (see scheduleSave).
@MainActor
enum VerdictDisk {

    /// Field mirror of Channel, which is not Codable (it
    /// carries a `let id = UUID()`); conversion runs both
    /// ways through Channel's init.
    struct StoredChannel: Codable {
        var title: String
        var logo: String
        var group: String
        var url: String
        var kickoff: TimeInterval?
        var leagueRank: Int
        var referrer: String
        var userAgent: String

        init(_ ch: Channel) {
            title = ch.title
            logo = ch.logo
            group = ch.group
            url = ch.url
            kickoff = ch.kickoff?.timeIntervalSince1970
            leagueRank = ch.leagueRank
            referrer = ch.referrer
            userAgent = ch.userAgent
        }

        var channel: Channel {
            Channel(title: title, logo: logo, group: group, url: url,
                    kickoff: kickoff.map { Date(timeIntervalSince1970: $0) },
                    leagueRank: leagueRank,
                    referrer: referrer, userAgent: userAgent)
        }
    }

    struct StoredEntry: Codable {
        var key: String
        var sources: [StoredChannel]
        var verifiedURLs: [String]
        var storedAt: TimeInterval
        var ttl: TimeInterval
    }

    struct StoredWarm: Codable {
        var dead: Bool
        var stamp: TimeInterval
    }

    struct Payload: Codable {
        var version: Int
        var resolveEntries: [StoredEntry]
        /// url → verdict stamp, epoch seconds.
        var provenDead: [String: TimeInterval]
        var prewarm: [String: StoredWarm]
    }

    private static let resolveHorizon: TimeInterval = 30 * 60
    private static let deadHorizon: TimeInterval = 10 * 60
    private static let prewarmHorizon: TimeInterval = 30 * 60

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dabanh-verdicts.json")
    }

    private static var cachedPayload: Payload?
    private static var didLoad = false
    private static var pendingSave: Task<Void, Never>?

    private static var emptyPayload: Payload {
        Payload(version: 1, resolveEntries: [], provenDead: [:], prewarm: [:])
    }

    /// The payload, read from disk at most once per launch.
    /// Any failure yields the empty payload (see the type
    /// doc) — a cold start, never a crash.
    static func load() -> Payload {
        if didLoad { return cachedPayload ?? emptyPayload }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              decoded.version == 1 else {
            cachedPayload = emptyPayload
            return emptyPayload
        }
        cachedPayload = decoded
        return decoded
    }

    /// ResolveHub's restore slice: entries and dead verdicts
    /// inside their horizons (see the type doc), plus the
    /// count of restorable prewarm records — for the hub's
    /// one restore log line; the prewarm store restores its
    /// own slice separately.
    /// FIX-141 round 2: every age test here and in
    /// prewarmSlice requires the age to lie in [0, horizon] —
    /// a future-dated stamp (clock skew / corrupt-but-
    /// decodable file) reads as expired, never as fresh.
    static func resolveSlice(now: Date = Date())
        -> (entries: [StoredEntry], dead: [String: Date], warmCount: Int) {
        let payload = load()
        let entries = payload.resolveEntries.filter {
            (0...resolveHorizon).contains(
                now.timeIntervalSince(Date(timeIntervalSince1970: $0.storedAt)))
        }
        var dead: [String: Date] = [:]
        for (url, stamp) in payload.provenDead
        where (0...deadHorizon).contains(
            now.timeIntervalSince(Date(timeIntervalSince1970: stamp))) {
            dead[url] = Date(timeIntervalSince1970: stamp)
        }
        let warmCount = payload.prewarm.values.filter {
            (0...prewarmHorizon).contains(
                now.timeIntervalSince(Date(timeIntervalSince1970: $0.stamp)))
        }.count
        return (entries, dead, warmCount)
    }

    /// SourcePrewarmStore's restore slice: records inside
    /// the 30 min horizon, stamps still epoch seconds (the
    /// store converts).
    static func prewarmSlice(now: Date = Date()) -> [String: StoredWarm] {
        load().prewarm.filter {
            (0...prewarmHorizon).contains(
                now.timeIntervalSince(Date(timeIntervalSince1970: $0.stamp)))
        }
    }

    /// Coalesced save: cancel any pending save and start a
    /// new one that sleeps 1 s, then assembles the payload
    /// from the two stores' snapshots and writes it. Verdicts
    /// land in bursts (a settle writes an entry + several
    /// dead URLs at once); one write per burst is enough, and
    /// the write itself is a small JSON kept synchronous on
    /// the main actor — the invalid-urls.json precedent.
    static func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            writeNow()
        }
    }

    private static func writeNow() {
        let (entries, dead) = ResolveHub.shared.verdictSnapshot()
        let payload = Payload(
            version: 1,
            resolveEntries: entries,
            provenDead: dead.mapValues { $0.timeIntervalSince1970 },
            prewarm: SourcePrewarmStore.shared.verdictSnapshot())
        cachedPayload = payload
        didLoad = true
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Resolve cache + single-flight hub (research §3.4): concurrent
/// opens of the same fixture share one in-flight session; a fresh
/// cached ladder replays instantly with no network; a fixture that
/// resolved to nothing playable is negative-cached for ~30 s, so a
/// dead fixture is not re-scraped on every tap; a healthy
/// re-resolve doubles the entry's TTL (60 s floor, 10 min cap),
/// while an empty resolve collapses the entry to the 30 s negative
/// TTL. Capped at 200 entries (least-recently-used evicted).
/// FIX-141: the cache and the dead set now persist across
/// launches via VerdictDisk (DIAG-140-SMOOTH §5 direction 1 —
/// the in-memory-only design re-verified the world at every
/// cold start); restore horizons live in VerdictDisk. The
/// device remains the only vantage point that shares the
/// owner's network and tunnel — persistence only carries THIS
/// device's own verdicts forward.
///
/// FIX-128 (the tvOS tap-to-play read path, ported): a tap reads
/// this registry in the order the SAME in-flight session → fresh
/// cache → STALE cache → new resolve, and never pays full
/// verification for a fixture the registry already knows:
/// - A stale (TTL-expired) entry with a playable ladder is
///   ADOPTED, not discarded: the tap vends a session seeded with
///   the cached ladder — which already excludes every source
///   that resolve proved dead — and re-resolution runs behind
///   it, merging into the replayed ladder. The TTL now governs
///   only when the background re-resolve runs, never whether
///   the tap may use what is known. (Before FIX-128 the entry
///   was treated as absent past its TTL: the 1.27 device log's
///   Bayern tap, 285 s after the launch pre-resolve settled,
///   created a new session and re-paid the dead head + serial
///   failover in full.)
/// - Every settled resolve also feeds its proven-dead URLs
///   into an app-run dead set (provenDead below) that outlives
///   any single entry's TTL, so a later tap's head publish can
///   filter a source this run already convicted — the same
///   per-run doctrine SourcePrewarmStore keeps for its own
///   verdicts.
@MainActor
final class ResolveHub {
    static let shared = ResolveHub()

    private struct Entry {
        var sources: [Channel]
        var storedAt: Date
        var ttl: TimeInterval
        /// Last vend (fresh or stale) — the LRU eviction key.
        var lastUsed: Date
        /// FIX-128: the URLs of the entry's VERIFIED tier
        /// (the rest of `sources` is the kept/blind tail, plus
        /// possibly an instant head at rung 0). Recorded so a
        /// later tap's seed order can tell a verified pick
        /// from a merely-kept one without re-deriving tiers
        /// from positions the merge may have shifted.
        var verifiedURLs: Set<String>
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: MatchPlaySession] = [:]
    /// URLs a settled resolve proved definitively dead this
    /// app run (pre-flight's standard only — see
    /// MatchPlaySession.isKnownDead), each stamped with the
    /// time of its latest verdict. Outlives cache entries:
    /// a verdict must survive the TTL of the entry that
    /// produced it, or an expired entry resurrects its dead.
    /// FIX-130 (P-4): a verdict now also EXPIRES — 30 s after
    /// it was stamped (the web board's HEALTH_NEG_MS) the URL
    /// is retestable: publishHeadNow stops filtering it, so a
    /// host that recovered mid-run is not convicted until
    /// relaunch the way the pre-1.30 lifetime set held it.
    /// Expiry is lazy (on read, in isProvenDead) — no timers,
    /// no sweeps.
    private var provenDead: [String: Date] = [:]

    /// FIX-141: dead verdicts restored from disk (VerdictDisk),
    /// kept in a SEPARATE map so the in-run tier's 30 s
    /// lazy-expiry logic above is untouched. A restored verdict
    /// is honoured for 10 min from its ORIGINAL stamp (see
    /// VerdictDisk for the horizon justification) and dropped
    /// lazily past it, on read, exactly like the in-run tier.
    /// When noteResolved / notePlayerDead re-convicts a URL it
    /// lands in the in-run map as always; the persisted file
    /// carries the union of both maps.
    private var restoredDead: [String: Date] = [:]

    /// FIX-141: the restored tier's horizon from the original
    /// verdict stamp.
    private static let restoredDeadHorizon: TimeInterval = 10 * 60

    /// The dead-verdict memory: 30 s, mirroring the web
    /// board's health map.
    /// Internal (not private) so SourcePrewarmStore's verdicts
    /// expire on the same TTL (E1).
    static let provenDeadTTL: TimeInterval = 30

    /// Whether a settled resolve has already proven this URL
    /// dead during this app run — and the verdict is still
    /// inside its 30 s TTL. An expired verdict is dropped on
    /// the spot and the URL reads as never convicted.
    func isProvenDead(_ url: String) -> Bool {
        if let stampedAt = provenDead[url] {
            if Date().timeIntervalSince(stampedAt) > Self.provenDeadTTL {
                provenDead[url] = nil
            } else {
                return true
            }
        }
        // FIX-141: the restored tier — a verdict from a
        // previous run, inside its 10 min horizon from the
        // original stamp, lazily dropped past it.
        if let stampedAt = restoredDead[url] {
            if Date().timeIntervalSince(stampedAt) > Self.restoredDeadHorizon {
                restoredDead[url] = nil
                return false
            }
            return true
        }
        return false
    }

    /// FIX-129 (Item C): a PLAYER-observed definitive failure
    /// (TLS/certificate invalid, HTTP 403/404) joins the same
    /// app-run dead set a settled resolve feeds, so
    /// publishHeadNow filters the URL for every later tap —
    /// including taps of other fixtures whose ladders carry
    /// the same URL. Session-scoped in effect (the set is
    /// in-memory, per app run, like every verdict here).
    /// FIX-130 (P-4): the verdict is stamped, so it expires
    /// on the same 30 s TTL as a resolve's verdict.
    func notePlayerDead(url: String) {
        provenDead[url] = Date()
        VerdictDisk.scheduleSave() // FIX-141
    }
    private var preresolveTask: Task<Void, Never>?
    private var preresolveSessions: [MatchPlaySession] = []
    /// Sessions a tap has been handed (created by the tap, or a
    /// preresolve-created session the tap adopted via the
    /// single-flight table). A preresolve sweep never cancels
    /// these. Entries are dropped when the session leaves the
    /// in-flight table (noteResolved / forgetInFlight).
    private var tapAdopted: Set<ObjectIdentifier> = []

    private init() {
        restoreVerdictsFromDisk()
    }

    /// FIX-141: restore the persisted verdicts (VerdictDisk
    /// has already applied the restore horizons: resolve
    /// entries ≤30 min old, dead verdicts ≤10 min from their
    /// original stamp). Restored entries re-enter the cache
    /// with their original storedAt + TTL, so the hub's own
    /// fresh/stale machinery governs them from here exactly
    /// as if this run had produced them: a still-fresh entry
    /// replays instantly, a stale one is adopted and
    /// revalidated behind the tap.
    private func restoreVerdictsFromDisk() {
        let slice = VerdictDisk.resolveSlice()
        for stored in slice.entries {
            let stamp = Date(timeIntervalSince1970: stored.storedAt)
            cache[stored.key] = Entry(
                sources: stored.sources.map { $0.channel },
                storedAt: stamp, ttl: stored.ttl, lastUsed: stamp,
                verifiedURLs: Set(stored.verifiedURLs))
        }
        while cache.count > 200,
              let lru = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            cache[lru] = nil
        }
        restoredDead = slice.dead
        DiagLog.log("player",
                    "verdicts: restored \(slice.entries.count) resolve entries, "
                    + "\(slice.dead.count) dead, \(slice.warmCount) warm from disk")
    }

    /// FIX-141: the persistable slice of the hub for
    /// VerdictDisk — every cache entry (channels mirrored
    /// field-by-field; Channel itself is not Codable) and the
    /// dead set as the UNION of the in-run and restored maps
    /// (the later stamp wins where both hold a URL).
    func verdictSnapshot() -> (entries: [VerdictDisk.StoredEntry],
                               dead: [String: Date]) {
        let entries = cache.map { key, entry in
            VerdictDisk.StoredEntry(
                key: key,
                sources: entry.sources.map(VerdictDisk.StoredChannel.init),
                verifiedURLs: Array(entry.verifiedURLs),
                storedAt: entry.storedAt.timeIntervalSince1970,
                ttl: entry.ttl)
        }
        var dead = restoredDead
        for (url, stamp) in provenDead {
            dead[url] = max(dead[url] ?? .distantPast, stamp)
        }
        return (entries, dead)
    }

    /// Cache identity of a ladder: its URL MULTISET — the
    /// URLs sorted, so ORDER plays no part. FIX-130 (P-8):
    /// until now the key was the URLs in ladder order, so a
    /// board pick whose rotation differed from the preresolve
    /// ladder's order (the Castilla re-pick shape, PLAN-130
    /// §4 G-8) missed both the cache and the in-flight table
    /// and started a second session for the same fixture.
    /// Audited before the change: key(for:) has exactly one
    /// caller (session(for:isTap:) below); every other use of
    /// a session's key treats it as opaque identity — the
    /// noteResolved / forgetInFlight guards match on it, and
    /// ContentView's .id("vn:" + session.key) view identity
    /// changes value consistently for every caller at once.
    /// Order itself lives in the entry, not the key:
    /// tapSeedOrder re-derives the replay order from the
    /// entry + the pick, so identity and order stay separate.
    /// Two different fixtures never share a URL multiset; a
    /// refreshed playlist with different URLs is a different
    /// key and resolves fresh.
    static func key(for ladder: [Channel]) -> String {
        ladder.map(\.url).sorted().joined(separator: "\n")
    }
    /// The session for a ladder: the in-flight one if this fixture
    /// is already resolving (single-flight — a tap and a
    /// pre-resolve pass share it), else a born-complete session
    /// from a fresh cache entry, else a new session that starts
    /// verifying immediately.
    func session(for ladder: [Channel]) -> MatchPlaySession {
        session(for: ladder, isTap: true).session
    }

    /// FIX-128: the order a stale entry's ladder is replayed
    /// in for a tap whose pick is `pick` (the head of the
    /// tap's rotated ladder). Pick semantics, in order:
    /// - The pick is in the entry's VERIFIED tier → it leads
    ///   (it is both the viewer's choice and proven).
    /// - The pick is only in the kept/blind tail while the
    ///   entry holds verified rungs → the resolved order
    ///   stands (verified first): the player starts at the
    ///   first verified rung instead of paying the blind
    ///   pick's possible death — the same rule publishHeadNow
    ///   applies to a proven-dead pick, extended one tier:
    ///   unverified loses to verified when a verified
    ///   alternative is already known.
    /// - Nothing in the entry is verified → the pick leads
    ///   (among blind equals the choice rules, as the
    ///   instant head has always done).
    /// A pick absent from the entry (its URL rotated out of
    /// the playlist since) leaves the resolved order alone.
    private func tapSeedOrder(entry: Entry, pick: Channel?) -> [Channel] {
        let seed = entry.sources
        guard let pick,
              let i = seed.firstIndex(where: { $0.url == pick.url }) else { return seed }
        if entry.verifiedURLs.contains(pick.url) || entry.verifiedURLs.isEmpty {
            return [seed[i]] + seed.enumerated()
                .filter { $0.offset != i }
                .map { $0.element }
        }
        return seed
    }

    /// The hub's core lookup. `createdFresh` is true only when
    /// this call created and started a brand-new session — a
    /// single-flight hit and a born-complete cached session are
    /// both not fresh. Only the preresolve pass uses the flag, to
    /// track exactly the sessions it owns. A tap call (isTap)
    /// also marks the returned live session tap-adopted and
    /// drops it from the preresolve-owned list, so a later sweep
    /// can never cancel a session a player is using.
    ///
    /// FIX-128 read order for a tap: in-flight session → fresh
    /// cache entry → stale cache entry (seeded adoption with
    /// re-resolution behind) → new session. A pre-resolve call
    /// meeting a stale entry falls through to a fresh session —
    /// refreshing the entry is exactly the pass's job.
    private func session(for ladder: [Channel], isTap: Bool) -> (session: MatchPlaySession, createdFresh: Bool) {
        // FIX-139: a tap is the explicit pick / on-demand entry
        // — the one place a stale pre-warm dead verdict for the
        // pick (the rotated ladder's head) may expire, BEFORE
        // any publishHeadNow / isKnownDead read below consults
        // it. A pre-resolve call (isTap == false, board-open
        // intent) never expires a verdict here.
        if isTap, let pick = ladder.first {
            SourcePrewarmStore.shared.expireDeadIfPicked(pick.url)
        }
        let key = Self.key(for: ladder)
        if let live = inFlight[key] {
            if live.isCancelled {
                // A cancelled session remains in the table until
                // its run() notices and forgets it, but it will
                // settle empty, publish nothing further and write
                // no cache — treat it as absent: forget it with
                // the same bookkeeping as a self-noticed
                // cancellation and fall through to a fresh session.
                forgetInFlight(key: key, from: live)
            } else {
                if isTap {
                    noteTapAdoption(of: live)
                    DiagLog.log("player",
                                "resolve: tap adopted in-flight resolution for "
                                + "'\(ladder.first?.title ?? "?")' — "
                                + "\(live.sources.count) source(s) already published, "
                                + "still resolving behind the player")
                    // FIX-128: a still-empty in-flight session
                    // (the board-open pre-resolve a second old)
                    // is seeded with the stale cached ladder
                    // when one exists, so the player starts on
                    // previously-verified rungs while THIS
                    // session's verification continues behind
                    // the replay — the tap never waits for the
                    // young session's first batch when an older
                    // resolve already knows the fixture.
                    if live.sources.isEmpty, let entry = cache[key],
                       !entry.sources.isEmpty {
                        let seed = tapSeedOrder(entry: entry, pick: ladder.first)
                        live.adoptSeed(seed)
                        cache[key]?.lastUsed = Date()
                        DiagLog.log("player",
                                    "resolve: tap seeded in-flight resolution for "
                                    + "'\(ladder.first?.title ?? "?")' with the stale "
                                    + "ladder — \(seed.count) source(s) replayed "
                                    + "instantly, verification continues behind")
                    }
                    // FIX-130B (REVIEW-130-LOOP2 B-1): this
                    // session may have been started by a
                    // preresolve pass with ITS ladder — since
                    // P-8 the tap's rotated ladder shares the
                    // key and adopts it. Re-base the session's
                    // snapshot to the TAP's ladder first, so
                    // the instant head publishHeadNow is about
                    // to make is the viewer's pick. (Inert when
                    // a seed just landed or a batch already
                    // published: publishHeadNow then no-ops
                    // before ever reading the snapshot, and
                    // nothing else reads it.)
                    live.rebaseSnapshot(to: ladder)
                    // DB-07: the tap plays the head NOW, even
                    // while this shared session still verifies.
                    // (A no-op when the seed just landed: the
                    // replay already published a ladder.)
                    live.publishHeadNow()
                }
                return (live, false)
            }
        }
        if let entry = cache[key] {
            let age = Date().timeIntervalSince(entry.storedAt)
            cache[key]?.lastUsed = Date()
            if age < entry.ttl {
                if isTap {
                    DiagLog.log("player",
                                "resolve: tap adopted cached resolution for "
                                + "'\(ladder.first?.title ?? "?")' — "
                                + "\(entry.sources.count) source(s), entry age "
                                + "\(Int(age))s of \(Int(entry.ttl))s TTL")
                }
                return (MatchPlaySession.cached(key: key, sources: entry.sources), false)
            }
            if isTap, !entry.sources.isEmpty {
                // FIX-128: stale adoption — the tvOS read path.
                // The entry's ladder replays instantly (it
                // already excludes the sources its resolve
                // proved dead); a fresh resolve runs behind it
                // and merges in, and its settle rewrites the
                // entry with a doubled TTL. A stale NEGATIVE
                // entry (empty ladder) never takes this path:
                // there is nothing to replay, and re-resolving
                // from scratch is the correct answer for a
                // fixture that may have revived.
                let session = MatchPlaySession.seeded(
                    key: key, sources: tapSeedOrder(entry: entry, pick: ladder.first))
                inFlight[key] = session
                noteTapAdoption(of: session)
                DiagLog.log("player",
                            "resolve: tap adopted stale resolution for "
                            + "'\(ladder.first?.title ?? "?")' — "
                            + "\(entry.sources.count) source(s) replayed instantly, "
                            + "re-resolving behind (entry age \(Int(age))s, "
                            + "TTL was \(Int(entry.ttl))s)")
                session.beginRevalidation(ladder: ladder)
                return (session, true)
            }
        }
        DiagLog.log("player",
                    "resolve: new session for '\(ladder.first?.title ?? "?")' "
                    + "(\(ladder.count) sources)")
        let session = MatchPlaySession(key: key)
        inFlight[key] = session
        if isTap { noteTapAdoption(of: session) }
        session.begin(ladder: ladder)
        // DB-07: a fresh session for a tap publishes its head
        // unverified at once (see publishHeadNow); a pre-resolve
        // pass (isTap == false) keeps the verified-batch
        // contract untouched.
        if isTap { session.publishHeadNow() }
        return (session, true)
    }

    private func noteTapAdoption(of session: MatchPlaySession) {
        tapAdopted.insert(ObjectIdentifier(session))
        preresolveSessions.removeAll { $0 === session }
    }

    /// Pre-resolve the fixtures the first screen leads with (the
    /// client analogue of the addon's pre-warming, research §3.5):
    /// bounded to the first three ladders, started one at a time.
    /// A new call supersedes the previous pass — sessions it
    /// started are cancelled where they stand and no further
    /// fixtures start. Sessions begun by a tap are never touched.
    func preresolve(ladders: [[Channel]]) {
        preresolveTask?.cancel()
        // Cancel only sessions this pass owns: still resolving and
        // never handed to a tap. (Adopted sessions are also removed
        // from preresolveSessions at adoption time — the tapAdopted
        // check here is the second line of defence.)
        for session in preresolveSessions
        where session.isResolving && !tapAdopted.contains(ObjectIdentifier(session)) {
            session.cancel()
        }
        preresolveSessions = []
        let batch = Array(ladders.prefix(3))
        guard !batch.isEmpty else { return }
        preresolveTask = Task { [weak self] in
            for ladder in batch {
                if Task.isCancelled { return }
                guard let self else { return }
                // Track only sessions this pass created fresh: a
                // single-flight hit may be a tap's session (or a
                // cached replay), which this pass must never cancel.
                let result = self.session(for: ladder, isTap: false)
                if result.createdFresh {
                    self.preresolveSessions.append(result.session)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Called by a session when its resolution settles: leaves the
    /// in-flight table and writes the cache entry. Identity-guarded:
    /// a session that has been replaced in the in-flight table by a
    /// different session must not evict that replacement or
    /// overwrite its cache entry, so the write is dropped when
    /// `inFlight[key]` holds a different session object.
    func noteResolved(key: String, sources: [Channel], deadURLs: Set<String> = [],
                      verifiedURLs: Set<String> = [],
                      from session: MatchPlaySession) {
        if let live = inFlight[key] {
            guard live === session else { return }
            tapAdopted.remove(ObjectIdentifier(live))
        }
        inFlight[key] = nil
        // FIX-128: the resolve's death verdicts join the
        // app-run dead set BEFORE the entry is written, so
        // they outlive this entry's TTL (see provenDead).
        // FIX-130 (P-4): each verdict is stamped with this
        // settle's time — the set's 30 s TTL runs from the
        // latest verdict, so a re-conviction refreshes it.
        let verdictStamp = Date()
        for url in deadURLs {
            provenDead[url] = verdictStamp
        }
        let ttl: TimeInterval
        if sources.isEmpty {
            ttl = 30 // negative entry — see the type doc
        } else if let previous = cache[key] {
            ttl = min(previous.ttl * 2, 600)
        } else {
            ttl = 60
        }
        let now = Date()
        cache[key] = Entry(sources: sources, storedAt: now, ttl: ttl,
                           lastUsed: now, verifiedURLs: verifiedURLs)
        // FIX-128: LRU cap — evict least-recently-VENDED
        // entries (a fixture the viewer keeps returning to
        // keeps its verdicts; a one-off fixture's entry is
        // the first to go).
        while cache.count > 200,
              let lru = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            cache[lru] = nil
        }
        VerdictDisk.scheduleSave() // FIX-141
    }

    /// A cancelled session leaves the in-flight table without
    /// writing the cache, so the next open resolves it fresh.
    /// Identity-guarded: the entry — and its tap-adoption
    /// bookkeeping — is dropped only when the table still holds
    /// the session being forgotten; a stale session unwinding
    /// after a replacement took over its key must not evict the
    /// live replacement.
    func forgetInFlight(key: String, from session: MatchPlaySession) {
        guard let live = inFlight[key], live === session else { return }
        tapAdopted.remove(ObjectIdentifier(live))
        inFlight[key] = nil
    }
}
