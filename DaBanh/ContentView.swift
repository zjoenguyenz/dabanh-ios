import SwiftUI

/// Root screen, styled like a TV/streaming app: dark gradient, a
/// header with the live count, a swipeable featured rail of live
/// fixtures, league chips instead of a tab bar, and fixture cards
/// grouped by bucket (Đang đá / Sắp đá / Khác).
///
/// Redesign (2026-11-14, owner-approved spec): the bars and colours
/// are the ones he already knows — same header, same chips, same
/// near-black + green + red palette — and everything below them is
/// new. One card per fixture (sources grouped inside, see
/// FixtureEntry), no raw playlist titles anywhere, no search (he
/// never used it). All data wiring is unchanged: PlaylistStore
/// drives everything, and tapping any card presents PlayerView
/// full-screen with the store's source ladder.
struct ContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    /// The selected theme (theme-mu): classic below is the
    /// default and unchanged; the MU theme swaps the home for
    /// MUHomeView and the board for the MU match detail. All
    /// routing / presentation machinery is shared.
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.scenePhase) private var scenePhase
    /// FIX-127 (owner order 2026-11-20 — "làm 1 lần hoàn
    /// tất ngay"): ONE presentation route for the link board
    /// and the player, shown by ONE full-screen cover below. A
    /// fixture tap sets .board; a board pick flips the SAME
    /// cover to .playVN/.playEN in the same state change — no
    /// dismissal in between. The chain this replaces (board
    /// .sheet whose onDismiss ran a stored deferred-play
    /// closure that set a separate cover's item) measured a 29 s
    /// pick→player gap on device in 1.26 even though the
    /// stream URL was published instantly: the relay, not the
    /// playback, ate the time. Closing either screen clears
    /// the route through the cover's own dismissal.
    private enum Route {
        case board(FixtureEntry)
        case playVN(session: MatchPlaySession, channel: Channel)
        case playEN(session: MatchPlaySession, meta: NuvioMeta)
    }
    @State private var route: Route?
    /// Whether the single cover is up. Separate from `route`
    /// so a close (either screen's own dismiss()) leaves the
    /// route in place until the cover's onDismiss clears it —
    /// the outgoing screen stays rendered through its
    /// dismissal instead of blanking to the nil case.
    @State private var coverUp = false
    /// The Nuvio addon source: it leads the BLV Anh tab (the
    /// mirror's EN block stays below it as the fallback pool)
    /// and, since 1.20, feeds the Đức league tab's addon
    /// sections (owner order 2026-11-19) — its German live
    /// fixtures up top with the live sections, its Sky
    /// Bundesliga channels below the fixtures.
    @StateObject private var nuvio = NuvioAddonStore()
    /// The fixture the current player session was chosen from —
    /// the player's board-header slot renders its cluster.
    @State private var playerEntry: FixtureEntry?
    /// The diagnostic-log sheet (1.24, LOG RETRIEVAL LAW).
    @State private var showDiagLog = false
    /// The theme picker sheet (theme-mu), presented from the
    /// header pill (classic home) and the MU home's theme
    /// pill — both live in the root hierarchy, so the single
    /// body-level sheet attachment hosts them.
    @State private var showThemePicker = false
    /// The theme picker as opened from inside the board
    /// cover (the MU detail's theme button). FIX-MU-1 (F-1):
    /// the cover is a separate presentation context, so it
    /// carries its OWN state and its own sheet attachment in
    /// muDetailPanel — one binding must never feed two hosts,
    /// or the covered root host can queue a second
    /// presentation of the picker over the home.
    @State private var showThemePickerInCover = false

    private var liveChannels: [Channel] {
        store.channels.filter { LeagueClassifier.isLive($0) }
    }

    /// The English-commentary block (24/7 channels, no kickoffs), in
    /// the store's sorted order — shown only under its own chip,
    /// never inside the fixture tabs.
    private var enChannels: [Channel] {
        store.channels.filter { LeagueClassifier.isEN($0) }
    }

    /// Featured rail entries: live fixtures across every list (the
    /// store's live view already merges the leagues and the Hot
    /// group), one entry per fixture, state attached.
    private var featuredEntries: [FixtureEntry] {
        Array(store.entries(for: store.liveChannels).prefix(12))
    }

    /// The OTHER fixture entries claiming the same canonical pair
    /// + stamp date as `entry` — the competing clusters the
    /// Addendum-2 belonging rule reasons about (an English event
    /// folds only when exactly one candidate is inside its guard).
    private func competingChannels(for entry: FixtureEntry) -> [Channel] {
        guard let key = MatchMatching.pairKey(of: entry.channel),
              let kickoff = entry.channel.kickoff else { return [] }
        let dateKey = FixtureGrouping.stampDateKey(of: kickoff)
        return store.entries(for: store.channels).filter { other in
            other.id != entry.id
                && MatchMatching.pairKey(of: other.channel) == key
                && other.channel.kickoff.map {
                    FixtureGrouping.stampDateKey(of: $0) == dateKey
                } ?? false
        }.map(\.channel)
    }

    /// This fixture's matched English events (Addendum-2
    /// belonging, fail closed) — the board's EN section.
    private func enMetas(for entry: FixtureEntry) -> [NuvioMeta] {
        nuvio.matchedEvents(for: entry.channel,
                            competing: competingChannels(for: entry))
    }

    /// Open (or re-target) the single cover: every play entry
    /// point funnels through here — set the route, raise the
    /// cover. When the cover is already up (a board pick, an
    /// in-player Đổi nguồn swap) only the route changes: the
    /// cover's content swaps in place and nothing dismisses.
    private func present(_ newRoute: Route) {
        route = newRoute
        coverUp = true
    }

    /// Đổi nguồn pick of an English row, from either player:
    /// flip the route to the addon session for the meta. The
    /// fixture stays playerEntry — the swapped-to player is
    /// the same match, so its overlay keeps the same board.
    /// routeContent's .id makes the flip build a fresh
    /// PlayerView, the freshness the old dismiss→present
    /// relay provided, without the relay.
    private func swapToENMeta(_ meta: NuvioMeta) {
        let session = nuvio.session(for: meta)
        DiagLog.log("player", "route set: player — EN swap '\(meta.name)'")
        present(.playEN(session: session, meta: meta))
    }

    /// Đổi nguồn pick of a Vietnamese row the live session
    /// cannot serve in place (never published by it, or the
    /// pick was made from an English session): flip the route
    /// to a fresh session rotated to the chosen row — the
    /// link board's own entry path.
    private func swapToVNRow(_ channel: Channel) {
        guard let entry = playerEntry else { return }
        let session = ResolveHub.shared.session(
            for: store.rotatedSources(for: entry, chosen: channel))
        DiagLog.log("player",
                    "route set: player — VN swap '\(MatchTitle.clean(channel.title))'")
        present(.playVN(session: session, channel: channel))
    }

    /// Identity of the current player route, in the same
    /// terms routeContent keys its PlayerView .id by; nil on
    /// the board route and with no route set. FIX-127B: the
    /// orientation lock is driven from this value (see the
    /// onChange in body) so the lock follows the
    /// PRESENTATION, not the PlayerView instance — an
    /// in-place Đổi nguồn swap changes the key and
    /// re-asserts landscape, and only the cover's genuine
    /// dismissal widens the lock back to .all.
    private var playerRouteKey: String? {
        switch route {
        case .playVN(let session, _):
            return "vn:" + session.key
        case .playEN(let session, let meta):
            return "en:" + meta.id + ":" + session.key
        case .board(_):
            return nil
        case nil:
            return nil
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.08),
                         Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if themeStore.isMU {
                MUHomeView(
                    nuvio: nuvio,
                    onOpenFixture: { entry in
                        present(.board(entry))
                    },
                    onPlayVNChannel: { channel in
                        DiagLog.log("player",
                                    "tap: channel '\(MatchTitle.clean(channel.title))' — direct play")
                        playerEntry = nil
                        let session = ResolveHub.shared.session(for: store.sources(for: channel))
                        DiagLog.log("player",
                                    "route set: player — VN direct '\(MatchTitle.clean(channel.title))'")
                        present(.playVN(session: session, channel: channel))
                    },
                    onPlayENMeta: { meta in
                        playerEntry = nil
                        let session = nuvio.session(for: meta)
                        DiagLog.log("player",
                                    "route set: player — EN direct '\(meta.name)'")
                        present(.playEN(session: session, meta: meta))
                    },
                    onOpenThemePicker: { showThemePicker = true },
                    onShowLog: { showDiagLog = true })
            } else {
            VStack(spacing: 0) {
                header
                if let message = store.statusMessage, !store.channels.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                if !featuredEntries.isEmpty {
                    featuredRail
                }
                leagueChips
                leagueList
            }
            }

            if store.channels.isEmpty {
                loadingOverlay
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await store.start()
            // theme-mu: warm the shared wallpaper list early;
            // the MU surfaces read it, classic never paints it.
            Task { await MUWallpapers.refreshRemote() }
            // FIX-141: no launch preresolve and no launch
            // head-warm (DIAG-140-SMOOTH §5 directions 1+2 —
            // checking is scoped to the player now, and verdicts
            // persist across launches via VerdictDisk, so the
            // ambient launch drain the 1.40 log convicted is
            // gone, not rebuilt).
            // The BLV Anh tab's addon source loads alongside
            // (in-memory cache, TTL-gated on later visits).
            await nuvio.loadIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshIfStale() }
                Task { await nuvio.loadIfNeeded() }
            }
        }
        // FIX-127: the ONE cover for board + player (see the
        // Route state above). Its content is routeContent; a
        // route flip while it is up swaps the content in
        // place — no dismissal anywhere on a play path. A
        // close from inside (either screen's own dismiss())
        // drops coverUp; onDismiss then clears the route.
        // The sessions are captured into the route at tap
        // time (see the tap sites); the cover never calls the
        // hub itself, so a re-evaluation here cannot swap the
        // live player's session out from under it.
        .fullScreenCover(isPresented: $coverUp, onDismiss: {
            route = nil
            // FIX-127B: this dismissal is the ONLY genuine
            // close of board or player — the one place the
            // orientation lock widens back to .all. A route
            // flip never reaches here (the cover stays up).
            if themeStore.isMU {
                // FIX-147 (R2): MU — the portrait request
                // waits until no presentation transition is
                // in flight (OrientationHelper.lockWhenSettled).
                OrientationHelper.lockWhenSettled(.all, rotateTo: .portrait,
                                                  reason: "cover dismissed")
            } else {
                OrientationHelper.lock(.all, rotateTo: .portrait)
            }
        }) {
            routeContent
        }
        .onChange(of: playerRouteKey) { _, key in
            // FIX-127B: every arrival at a player route —
            // the first open and every in-place Đổi nguồn
            // swap — re-asserts the landscape lock, so the
            // lock's final state never depends on the
            // appear/disappear ordering of the swapped
            // PlayerView instances.
            if key != nil {
                if themeStore.isMU {
                    if MUFullscreenState.isActive {
                        // DB-20 (FIX-134): the MU player is in
                        // its button-driven fullscreen state —
                        // an in-place Đổi nguồn swap must not
                        // drop that landscape lock back to the
                        // free-rotation baseline, so re-assert
                        // it for the swapped-in player.
                        OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
                    } else {
                        // MU carries portrait + landscape player
                        // pages — rotation stays free (theme-mu).
                        OrientationHelper.lock(.all)
                    }
                } else {
                    OrientationHelper.lock(.landscape, rotateTo: .landscapeRight)
                }
            } else {
                // DB-20 (FIX-134): no player route is up —
                // a genuine close, or a flip back to the
                // board — so the fullscreen state dies with
                // its player and can never leak into the
                // next player open.
                MUFullscreenState.isActive = false
                // FIX-137 (DB-30/FL-402): the flip back to
                // the board must also restore portrait HERE —
                // before this, this branch made no orientation
                // call at all, so a landscape lock (classic) or
                // a landscape window (MU) survived under the
                // board until the whole cover was dismissed.
                // The cover's onDismiss repeats the same call
                // on a genuine close; both are the one widen.
                if themeStore.isMU {
                    // FIX-147 (R2): MU — this branch runs
                    // inside the route/surface teardown, with
                    // the fullscreen hosting possibly still
                    // being dismissed; the portrait request
                    // waits that out (lockWhenSettled).
                    OrientationHelper.lockWhenSettled(.all, rotateTo: .portrait,
                                                      reason: "player route ended")
                } else {
                    OrientationHelper.lock(.all, rotateTo: .portrait)
                }
            }
        }
        .sheet(isPresented: $showDiagLog) {
            DiagLogView()
        }
        .sheet(isPresented: $showThemePicker) {
            MUSettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
    }

    /// What the single cover shows for the current route.
    /// The player branches carry an explicit .id keyed to the
    /// session (and the meta), so a Đổi nguồn route flip
    /// builds a FRESH PlayerView — its @State starts over,
    /// exactly as when the old relay dismissed and
    /// re-presented — while a flip that changes nothing
    /// rebuilds nothing. The session key is the ladder's URLs
    /// in order, so a rotation to a different head is a
    /// different key.
    @ViewBuilder
    private var routeContent: some View {
        switch route {
        case .board(let entry):
            if themeStore.isMU {
                muDetailPanel(entry)
            } else {
                boardPanel(entry)
            }
        case .playVN(let session, _):
            PlayerView(
                session: session, headerEntry: playerEntry,
                enMetas: playerEntry.map { enMetas(for: $0) } ?? [],
                onSwitchEN: swapToENMeta,
                onSwitchVN: swapToVNRow)
                .id("vn:" + session.key)
        case .playEN(let session, let meta):
            PlayerView(
                session: session, headerEntry: playerEntry,
                enMetas: playerEntry.map { enMetas(for: $0) } ?? [],
                currentENMetaID: meta.id,
                onSwitchEN: swapToENMeta,
                onSwitchVN: swapToVNRow)
                .id("en:" + meta.id + ":" + session.key)
        case nil:
            Color.black.ignoresSafeArea()
        }
    }

    /// The link board wearing the panel it had as a sheet
    /// (FIX-127): the cover's background is clear, the list
    /// behind shows through dimmed, and the board itself —
    /// the unchanged MatchBoardView — sits in a rounded
    /// panel. Its own X button dismisses the cover, which
    /// clears the route (see the cover's onDismiss above).
    private func boardPanel(_ entry: FixtureEntry) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            MatchBoardView(
                entry: entry,
                enMetas: enMetas(for: entry),
                onPlayVN: { channel in
                    // DB-07: the pick anchor of the tap→play
                    // timeline (the tap, the board and the
                    // first frame each log their own line now).
                    DiagLog.log("player",
                                "tap: board pick '\(MatchTitle.clean(channel.title))' "
                                + "host=\(channel.streamURL?.host ?? "?")")
                    playerEntry = entry
                    let session = ResolveHub.shared.session(
                        for: store.rotatedSources(for: entry, chosen: channel))
                    // FIX-127: the route flip IS the
                    // presentation now — this line and
                    // PlayerView's "open:" line bracket the
                    // whole pick→player leg in the log.
                    DiagLog.log("player",
                                "route set: player — VN '\(MatchTitle.clean(channel.title))'")
                    present(.playVN(session: session, channel: channel))
                },
                onPlayEN: { meta in
                    DiagLog.log("player",
                                "tap: board pick EN '\(meta.name)'")
                    playerEntry = entry
                    let session = nuvio.session(for: meta)
                    DiagLog.log("player",
                                "route set: player — EN '\(meta.name)'")
                    present(.playEN(session: session, meta: meta))
                })
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 4)
                .padding(.top, 48)
                .padding(.bottom, 4)
        }
        .presentationBackground(.clear)
        // FIX-141: no board-open preresolve (the FIX-128
        // .onAppear pass that lived here is removed —
        // DIAG-140-SMOOTH §5 direction 2: checking is scoped
        // to the player; the tap starts from the persisted /
        // in-run verdicts and verification runs behind the
        // published pick).
    }


    /// The MU match detail wearing the board route (theme-mu):
    /// a full page in the cover (not the classic dimmed panel),
    /// with the board's own play closures — the same DiagLog
    /// lines, the same sessions, the same route flips.
    private func muDetailPanel(_ entry: FixtureEntry) -> some View {
        MUMatchDetailView(
            entry: entry,
            enMetas: enMetas(for: entry),
            onPlayVN: { channel in
                DiagLog.log("player",
                            "tap: board pick '\(MatchTitle.clean(channel.title))' "
                            + "host=\(channel.streamURL?.host ?? "?")")
                playerEntry = entry
                let session = ResolveHub.shared.session(
                    for: store.rotatedSources(for: entry, chosen: channel))
                DiagLog.log("player",
                            "route set: player — VN '\(MatchTitle.clean(channel.title))'")
                present(.playVN(session: session, channel: channel))
            },
            onPlayEN: { meta in
                DiagLog.log("player",
                            "tap: board pick EN '\(meta.name)'")
                playerEntry = entry
                let session = nuvio.session(for: meta)
                DiagLog.log("player",
                            "route set: player — EN '\(meta.name)'")
                present(.playEN(session: session, meta: meta))
            },
            onOpenThemePicker: { showThemePickerInCover = true })
        .sheet(isPresented: $showThemePickerInCover) {
            MUSettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // FIX-141: no board-open preresolve here either (see
        // the classic panel above).
    }

    /// The theme pill (theme-mu): palette icon + the current
    /// theme's name, in the header's mini-button chrome beside
    /// Log — the classic home's entry to the picker. (The MU
    /// home carries the design's own theme pill.)
    private var headerThemeButton: some View {
        Button {
            showThemePicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11, weight: .semibold))
                Text(themeStore.themeID.pillName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(BoardPalette.buttonText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(BoardPalette.buttonBG))
            .overlay(Capsule().stroke(BoardPalette.buttonBorder, lineWidth: 1))
        }
        .accessibilityLabel("Đổi giao diện")
    }

    // MARK: - Header

    /// The compact header (spec §0/§5.1-6): small logo +
    /// wordmark, clock, dabanh.tv, and the Làm mới / Kiểm tra
    /// link actions as the prototype's mini-buttons (same
    /// actions as before, shrunk chrome). The live count rides
    /// under the wordmark in the dim style.
    ///
    /// Portrait adaptation (owner ruling 2026-11-19: the iOS
    /// build is optimised for the portrait phone): the single
    /// row's ideal width is ~516 pt — wider than every portrait
    /// iPhone (375–430 pt) — so ViewThatFits takes the two-row
    /// arrangement in portrait (brand + clock on top; dabanh.tv,
    /// AirPlay and both mini-buttons below, ideal ~333 pt) and
    /// keeps the prototype's one row wherever it genuinely fits
    /// (landscape, iPad). Same elements, same actions, nothing
    /// dropped — the row simply wraps.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerSingleRow
            headerStacked
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// The prototype's one-row header (landscape / iPad widths).
    private var headerSingleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            headerBrand
            Spacer(minLength: 4)
            headerClock
            headerSiteLink
            headerRefreshButton
            headerCheckButton
            headerLogButton
            headerThemeButton
        }
    }

    /// The portrait two-row header: brand + clock above,
    /// dabanh.tv / AirPlay / the two actions below.
    private var headerStacked: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                headerBrand
                Spacer(minLength: 4)
                headerClock
                headerLogButton
                headerThemeButton
            }
            HStack(alignment: .center, spacing: 8) {
                headerSiteLink
                Spacer(minLength: 4)
                headerRefreshButton
                headerCheckButton
            }
        }
    }

    /// Logo disc + wordmark + the live/schedule count line.
    private var headerBrand: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle().fill(accentGreen)
                Image(systemName: "soccerball")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("ĐÁ BANH")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text("TV")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(BoardPalette.sky)
                }
                if liveChannels.count > 0 {
                    HStack(spacing: 4) {
                        PulsingDot()
                        Text("\(liveChannels.count) trận đang đá")
                            .font(.system(size: 10))
                            .foregroundStyle(BoardPalette.dimText)
                    }
                } else {
                    Text("\(store.channels.count) trận trong lịch")
                        .font(.system(size: 10))
                        .foregroundStyle(BoardPalette.dimText)
                }
            }
        }
    }

    /// The wall clock (device-local, 20 s tick).
    private var headerClock: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            Text(KickoffFormat.time.string(from: context.date))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BoardPalette.dimText)
        }
    }

    /// dabanh.tv link text + the AirPlay route picker disc.
    private var headerSiteLink: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("dabanh.tv")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BoardPalette.leagueText)

            RoutePickerView()
                .frame(width: 30, height: 30)
                .background(Circle().fill(BoardPalette.buttonBG))
        }
    }

    /// Làm mới — the prototype's mini-button.
    private var headerRefreshButton: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            HStack(spacing: 4) {
                if store.isLoading {
                    ProgressView().tint(BoardPalette.buttonText)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("Làm mới")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(BoardPalette.buttonText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(BoardPalette.buttonBG))
            .overlay(Capsule().stroke(BoardPalette.buttonBorder, lineWidth: 1))
        }
        .disabled(store.isLoading)
        .accessibilityLabel("Làm mới")
    }

    /// Kiểm tra link — manual link check (owner's request,
    /// 2026-11-13): fetch the newest list, re-probe every link
    /// from this phone, and republish the match screens without
    /// the dead ones.
    private var headerCheckButton: some View {
        Button {
            Task { await store.refreshAndValidate() }
        } label: {
            HStack(spacing: 4) {
                if store.isValidating {
                    ProgressView().tint(BoardPalette.buttonText)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("Kiểm tra link")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(BoardPalette.buttonText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(BoardPalette.buttonBG))
            .overlay(Capsule().stroke(BoardPalette.buttonBorder, lineWidth: 1))
        }
        .disabled(store.isLoading || store.isValidating)
        .accessibilityLabel("Kiểm tra link")
    }

    /// Log — opens the diagnostic-log sheet (1.24, LOG
    /// RETRIEVAL LAW: every app ships a way to get its log
    /// out). Same mini-button chrome as its neighbours.
    private var headerLogButton: some View {
        Button {
            showDiagLog = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                Text("Log")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(BoardPalette.buttonText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(BoardPalette.buttonBG))
            .overlay(Capsule().stroke(BoardPalette.buttonBorder, lineWidth: 1))
        }
        .accessibilityLabel("Log chẩn đoán")
    }

    // MARK: - Featured rail (live fixtures, swipe left for more)

    private var featuredRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("TRẬN NỔI BẬT")
                    .font(.caption.bold())
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal)
            .padding(.top, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(featuredEntries) { entry in
                        Button {
                            // DB-07: the tap anchor of the
                            // tap→play timeline in the log.
                            DiagLog.log("player",
                                        "tap: fixture '\(MatchTitle.clean(entry.channel.title))' from the list")
                            // A fixture tap opens its link board
                            // (spec §2.1); the board's row tap is
                            // what enters the player.
                            present(.board(entry))
                        } label: {
                            FeaturedCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                        // DB-03 carousel (owner ruling 2026-11-19):
                        // a card away from the front position sits
                        // slightly shrunk and dimmed; as it is
                        // dragged into the front position the
                        // transition interpolates it back up to the
                        // front box's full size ("bung lên bằng
                        // kích thước box đang nằm chính diện").
                        // Interactive scrollTransition — the effect
                        // tracks the scroll offset itself.
                        .scrollTransition { content, phase in
                            content
                                .scaleEffect(CGFloat(1 - abs(phase.value) * 0.08))
                                .opacity(1 - abs(phase.value) * 0.25)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            // One card at a time: the rail snaps each featured box
            // into the front position instead of free-scrolling.
            .scrollTargetBehavior(.viewAligned)
        }
    }

    // MARK: - League chips

    private var leagueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Final tab row (owner ruling 2026-11-19 14:38):
                // ENG · NHA · TBN · Ý · Đức · Pháp · Khác · Cúp EU
                // — ENG first, cups last; the ENG chip moves to
                // the front of this same row. The 🔴 Trực tiếp
                // and 🔥 Hot chips keep their places right after
                // ENG, ahead of the league pills.
                if !enChannels.isEmpty || nuvio.hasContent {
                    enChip
                }
                if !store.liveChannels.isEmpty {
                    liveChip
                }
                hotChip
                // FIX-134: the Highlight capsule (study §3.1 —
                // selected fill accentGreen, like the league
                // pills), riding its own selectedLeague value.
                highlightChip
                // League pill order: NHA · TBN · Ý · Đức · Pháp ·
                // Khác · Cúp EU — the cups pill goes LAST, after
                // Khác. This is a display order only: the League
                // rawValues are unchanged (cups stays 6) and
                // League.allCases is untouched, so PlaylistStore's
                // initial-tab pick keeps its existing behaviour.
                ForEach([League.england, .spain, .italy, .germany,
                         .france, .other, .cups]) { league in
                    let selected = store.selectedLeague == league.rawValue
                    let isCups = league == .cups
                    Button {
                        store.selectedLeague = league.rawValue
                    } label: {
                        // Pill content (owner ruling 2026-11-19):
                        // the league's small existing national-team
                        // crest beside the short tab label; the cups
                        // pill (tabCrestTeam == nil) stays text-only.
                        HStack(spacing: 5) {
                            if let team = league.tabCrestTeam,
                               let crestURL = Crests.url(forTeam: team) {
                                CrestImg(url: crestURL, size: 14)
                            }
                            Text(league.tabName)
                                .font(.subheadline.weight(selected ? .bold : .regular))
                                .foregroundStyle(
                                    selected
                                        ? (isCups ? BoardPalette.gold : .white)
                                        : (isCups ? BoardPalette.gold.opacity(0.75)
                                                  : .white.opacity(0.7)))
                        }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    selected
                                        ? (isCups ? BoardPalette.goldTabActiveBG : accentGreen)
                                        : (isCups ? BoardPalette.goldTabBG : Color.white.opacity(0.08)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// The 🔴 Trực tiếp chip: every match live right now across all
    /// leagues, same as the TV versions (owner sync request,
    /// 2026-11-13). Hidden when nothing is live.
    private var liveChip: some View {
        let selected = store.selectedLeague == PlaylistStore.liveTabValue
        return Button {
            store.selectedLeague = PlaylistStore.liveTabValue
        } label: {
            Text("🔴 Trực tiếp")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Color.red : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    /// The BLV Anh chip: shown when either of the tab's sources
    /// has content — the Nuvio addon's channels and fixtures
    /// (which lead the tab) or the mirror's English-commentary
    /// block ("EN · BLV Anh" group, the fallback pool below
    /// them). Hidden only when both are empty.
    private var enChip: some View {
        let selected = store.selectedLeague == LeagueClassifier.enTabValue
        return Button {
            store.selectedLeague = LeagueClassifier.enTabValue
        } label: {
            // Chip label only (owner ruling 2026-11-19: "để ENG
            // thôi") — text-only, no crest; the tab's in-tab copy
            // ("Kênh tiếng Anh" etc.) is unchanged.
            Text("ENG")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? accentGreen : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    /// The ▶ Highlight chip (FIX-134): the highlight tab's
    /// capsule in the classic chip row — same component as the
    /// league pills, selected fill accentGreen (study §3.1).
    private var highlightChip: some View {
        let selected = store.selectedLeague == HighlightStore.tabValue
        return Button {
            store.selectedLeague = HighlightStore.tabValue
        } label: {
            Text("▶ Highlight")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? accentGreen : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    /// The 🔥 Hot chip: matches the source sites themselves flag hot,
    /// fed by the backup mirror's "🔥 Hot" group (see PlaylistStore).
    private var hotChip: some View {
        let selected = store.selectedLeague == PlaylistStore.hotTabValue
        return Button {
            store.selectedLeague = PlaylistStore.hotTabValue
        } label: {
            Text("🔥 Hot")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Color.orange : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - League list (bucket sections, one card per fixture)

    private var leagueList: some View {
        if store.selectedLeague == PlaylistStore.liveTabValue {
            return AnyView(liveList)
        }
        if store.selectedLeague == PlaylistStore.hotTabValue {
            return AnyView(hotList)
        }
        if store.selectedLeague == LeagueClassifier.enTabValue {
            return AnyView(enList)
        }
        if store.selectedLeague == HighlightStore.tabValue {
            return AnyView(ClassicHighlightView())
        }
        if store.selectedLeague == League.cups.rawValue {
            return AnyView(cupsList)
        }
        if store.selectedLeague == League.germany.rawValue {
            return AnyView(leagueTabList(.germany, mergeHot: true,
                                         needles: ["Bundesliga"],
                                         channelHeader: "Kênh Bundesliga · Nuvio",
                                         includeAddon: true))
        }
        if store.selectedLeague == League.spain.rawValue {
            return AnyView(leagueTabList(.spain, mergeHot: false,
                                         needles: ["LaLiga", "La Liga"],
                                         channelHeader: "Kênh La Liga · Nuvio",
                                         includeAddon: true))
        }
        if store.selectedLeague == League.italy.rawValue {
            return AnyView(leagueTabList(.italy, mergeHot: false,
                                         needles: ["Calcio", "Serie A"],
                                         channelHeader: "Kênh Serie A · Nuvio",
                                         includeAddon: true))
        }
        if store.selectedLeague == League.france.rawValue {
            return AnyView(leagueTabList(.france, mergeHot: false,
                                         needles: ["Ligue 1", "Leauge 1"],
                                         channelHeader: "Kênh Ligue 1 · Nuvio",
                                         includeAddon: true))
        }
        if store.selectedLeague == League.other.rawValue {
            return AnyView(bucketList(
                channels: store.channels(in: .other).filter { !LeagueClassifier.isEN($0) },
                emptyText: "Chưa có kênh nào trong mục này."))
        }
        return AnyView(leagueTabList(.england, mergeHot: false,
                                     needles: nil, channelHeader: nil,
                                     includeAddon: false))
    }

    /// Trực tiếp: every live fixture as a big board, grouped
    /// strictly by its own competition (spec point 6 / §4.1):
    /// the main live section first (non-cup fixtures), then a
    /// cup rail per cup that has live fixtures — C1 in gold.
    private var liveList: some View {
        let entries = store.entries(for: store.liveChannels)
        let main = entries.filter { $0.competition?.isCup != true }
        return List {
            if entries.isEmpty {
                Text("Hiện không có trận nào đang đá. Các trận sắp tới nằm ở mục Hot và các giải.")
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !main.isEmpty {
                Section {
                    ForEach(main) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Đang đá", live: true)
                }
            }
            ForEach([CupKind.champions, .europa, .conference], id: \.self) { kind in
                let cupLive = entries.filter { $0.competition?.cupKind == kind }
                if !cupLive.isEmpty {
                    Section {
                        ForEach(cupLive) { entry in matchRow(entry) }
                    } header: {
                        cupSectionHeader(kind)
                    }
                }
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }

    /// A cup section head: C1 in the prototype's gold, C2/C3 in
    /// the standard head style.
    private func cupSectionHeader(_ kind: CupKind) -> some View {
        HStack(spacing: 6) {
            if kind == .champions {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(BoardPalette.gold)
            }
            Text(kind.fullLabel)
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(kind == .champions
                                 ? BoardPalette.goldHead
                                 : .white.opacity(0.6))
        }
        .listRowBackground(Color.clear)
    }

    private var hotList: some View {
        bucketList(channels: store.hotChannels,
                   emptyText: "Chưa có trận hot nào. Trang nguồn gắn cờ hot cho trận nào thì trận đó hiện ở đây.")
    }

    /// One country tab (spec §3.1, owner ruling 2026-11-19):
    /// the top-division block first — a labelled headline, then
    /// the usual live → upcoming → rest order, live fixtures as
    /// big boards — then the division-2 block under a SMALLER
    /// headline with its own live → upcoming → rest order, and
    /// the tab's Nuvio channel fold closing the tab, unchanged.
    /// A division-2 block with nothing in it renders no headline
    /// at all (no empty section, ever). Division filing is the
    /// §3 signal order on the entry's competition (S1 state >
    /// S3 both-clubs); a cup-identified fixture keeps its country
    /// filing here too (dual presence, §4.1) and files under the
    /// top block — it is not a league fixture of the lower
    /// division. The Đức tab additionally merges the Hot group's
    /// German fixtures (its 1.20 behaviour); the addon's live
    /// fixtures split by their own S2 string (a div-2 string
    /// files the addon row in the lower block).
    private func leagueTabList(_ league: League, mergeHot: Bool,
                               needles: [String]?, channelHeader: String?,
                               includeAddon: Bool) -> some View {
        let now = Date()
        var seen = Set<String>()
        var mirror = store.channels(in: league)
        if mergeHot {
            mirror += store.hotChannels.filter { $0.leagueRank == league.rawValue }
        }
        mirror = mirror.filter {
            !LeagueClassifier.isEN($0) && seen.insert($0.url).inserted
        }
        let entries = store.entries(for: mirror)
        func isLower(_ entry: FixtureEntry) -> Bool {
            if case .league(_, true) = entry.competition ?? .other(label: "") {
                return true
            }
            return false
        }
        let top = entries.filter { !isLower($0) }
        let lower = entries.filter { isLower($0) }
        func buckets(_ list: [FixtureEntry])
            -> (live: [FixtureEntry], upcoming: [FixtureEntry], rest: [FixtureEntry]) {
            (list.filter { $0.bucket(now: now) == 0 },
             list.filter { let b = $0.bucket(now: now); return b == 1 || b == 2 },
             list.filter { $0.bucket(now: now) == 3 })
        }
        let topB = buckets(top)
        let lowerB = buckets(lower)
        let addonLive = includeAddon ? nuvio.liveEvents(in: league) : []
        let addonLower = addonLive.filter {
            LeagueClassifier.competition(forAddonString: $0.competitionString)
                == .league(rank: league.rawValue, lower: true)
        }
        let addonLowerIDs = Set(addonLower.map(\.id))
        let addonTop = addonLive.filter { !addonLowerIDs.contains($0.id) }
        let addonChannels = (includeAddon && needles != nil)
            ? nuvio.standingChannels(matchingAny: needles ?? []) : []
        let hasLower = !lower.isEmpty || !addonLower.isEmpty

        return List {
            if mirror.isEmpty && addonLive.isEmpty && addonChannels.isEmpty {
                if nuvio.isLoading && includeAddon {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Đang tải kênh Nuvio…")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Text("Chưa có kênh nào trong mục này.")
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !top.isEmpty || !addonTop.isEmpty {
                headlineRow(CompetitionID.topHeadline(rank: league.rawValue), small: false)
            }
            if !topB.live.isEmpty {
                Section {
                    ForEach(topB.live) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Đang đá", live: true)
                }
            }
            if !addonTop.isEmpty {
                Section {
                    ForEach(addonTop) { entry in
                        addonRow(entry)
                    }
                } header: {
                    sectionHeader("Đang đá · Nuvio", live: true)
                }
            }
            if !topB.upcoming.isEmpty {
                Section {
                    ForEach(topB.upcoming) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Sắp đá", live: false)
                }
            }
            if !topB.rest.isEmpty {
                Section {
                    ForEach(topB.rest) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Khác", live: false)
                }
            }
            if hasLower {
                headlineRow(
                    CompetitionID.league(rank: league.rawValue, lower: true).divisionHeadline,
                    small: true)
                if !lowerB.live.isEmpty {
                    Section {
                        ForEach(lowerB.live) { entry in matchRow(entry) }
                    } header: {
                        sectionHeader("Đang đá", live: true)
                    }
                }
                if !addonLower.isEmpty {
                    Section {
                        ForEach(addonLower) { entry in
                            addonRow(entry)
                        }
                    } header: {
                        sectionHeader("Đang đá · Nuvio", live: true)
                    }
                }
                if !lowerB.upcoming.isEmpty {
                    Section {
                        ForEach(lowerB.upcoming) { entry in matchRow(entry) }
                    } header: {
                        sectionHeader("Sắp đá", live: false)
                    }
                }
                if !lowerB.rest.isEmpty {
                    Section {
                        ForEach(lowerB.rest) { entry in matchRow(entry) }
                    } header: {
                        sectionHeader("Khác", live: false)
                    }
                }
            }
            if !addonChannels.isEmpty, let channelHeader {
                Section {
                    ForEach(addonChannels) { entry in
                        addonRow(entry)
                    }
                } header: {
                    sectionHeader(channelHeader, live: false)
                }
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.refresh()
            if includeAddon { await nuvio.refresh() }
        }
    }

    /// A division headline row inside a country tab: full size
    /// for the top block, one step smaller for division 2
    /// (spec §3.1 — only the header shrinks, never the tiles).
    private func headlineRow(_ title: String, small: Bool) -> some View {
        Text(title)
            .font(.system(size: small ? 13 : 16, weight: .bold))
            .tracking(1)
            .foregroundStyle(small ? BoardPalette.dimText : BoardPalette.headText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: small ? 8 : 12, leading: 16, bottom: 2, trailing: 16))
    }

    /// The cups tab (spec §4): C1 / C2 / C3 sections in order,
    /// each with the live → upcoming → rest order — live fixtures
    /// as big boards, C1 in the gold variant. Fixtures arrive
    /// ONLY by positive identification (S1 matched slug / S2
    /// addon string); the addon events whose own string names a
    /// cup ride as addon rows inside their cup's section. A cup
    /// fixture also keeps its country-tab filing (dual presence).
    private var cupsList: some View {
        let entries = store.cupEntries
        let now = Date()
        return List {
            if entries.isEmpty && nuvioCupEvents.isEmpty {
                Text("Chưa có trận cúp châu Âu nào trong lịch. Các trận C1 / C2 / C3 hiện ở đây khi nguồn xác định được cúp.")
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach([CupKind.champions, .europa, .conference], id: \.self) { kind in
                let cupEntries = entries.filter { $0.competition?.cupKind == kind }
                let addonEvents = nuvioCupEvents.filter {
                    LeagueClassifier.competition(forAddonString: $0.competitionString)?.cupKind == kind
                }
                if !cupEntries.isEmpty || !addonEvents.isEmpty {
                    Section {
                        ForEach(cupEntries.filter { $0.bucket(now: now) == 0 }) { entry in
                            matchRow(entry)
                        }
                        ForEach(addonEvents.filter { $0.kind == .live }) { entry in
                            addonRow(entry)
                        }
                        ForEach(cupEntries.filter {
                            let b = $0.bucket(now: now); return b == 1 || b == 2
                        }) { entry in
                            matchRow(entry)
                        }
                        ForEach(addonEvents.filter { $0.kind == .upcoming }) { entry in
                            addonRow(entry)
                        }
                        ForEach(cupEntries.filter { $0.bucket(now: now) == 3 }) { entry in
                            matchRow(entry)
                        }
                    } header: {
                        cupSectionHeader(kind)
                    }
                }
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.refresh()
            await nuvio.refresh()
        }
    }

    /// The addon's cup events (S2): live + upcoming metas whose
    /// own competition string names a European cup.
    private var nuvioCupEvents: [NuvioMeta] {
        (nuvio.liveEvents + nuvio.upcomingEvents).filter {
            LeagueClassifier.competition(forAddonString: $0.competitionString)?.isCup == true
        }
    }

    /// The BLV Anh tab (owner order 2026-11-19): the Nuvio
    /// addon's content leads — live events, upcoming events,
    /// then its 24/7 football channels — and the mirror's
    /// English-commentary block stays BELOW as the fallback pool,
    /// so the tab still has channels when the addon is down.
    /// (The league tabs carry their own addon sections —
    /// see leagueTabList.)
    private var enList: some View {
        List {
            if !nuvio.hasContent && enChannels.isEmpty {
                if nuvio.isLoading {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Đang tải kênh Nuvio…")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Text("Chưa có kênh tiếng Anh nào trong danh sách.")
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !nuvio.liveEvents.isEmpty {
                Section {
                    ForEach(nuvio.liveEvents) { entry in
                        addonRow(entry)
                    }
                } header: {
                    sectionHeader("Đang đá · Nuvio", live: true)
                }
            }
            if !nuvio.upcomingEvents.isEmpty {
                Section {
                    ForEach(nuvio.upcomingEvents) { entry in
                        addonRow(entry)
                    }
                } header: {
                    sectionHeader("Sắp đá · Nuvio", live: false)
                }
            }
            if !nuvio.channels.isEmpty {
                Section {
                    ForEach(nuvio.channels) { entry in
                        addonRow(entry)
                    }
                } header: {
                    sectionHeader("Kênh 24/7 · Nuvio", live: false)
                }
            }
            if !enChannels.isEmpty {
                Section {
                    ForEach(enChannels) { channel in
                        Button {
                            DiagLog.log("player",
                                        "tap: channel '\(MatchTitle.clean(channel.title))' — direct play")
                            playerEntry = nil
                            let session = ResolveHub.shared.session(for: store.sources(for: channel))
                            DiagLog.log("player",
                                        "route set: player — VN direct '\(MatchTitle.clean(channel.title))'")
                            present(.playVN(session: session, channel: channel))
                        } label: {
                            ENChannelRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                } header: {
                    sectionHeader("Kênh tiếng Anh", live: false)
                }
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.refresh()
            await nuvio.refresh()
        }
    }

    /// One addon row of the BLV Anh tab. The session is vended
    /// by the addon store and captured into state at tap time,
    /// exactly like a playlist tap; the cover presents it.
    private func addonRow(_ entry: NuvioMeta) -> some View {
        Button {
            playerEntry = nil
            let session = nuvio.session(for: entry)
            DiagLog.log("player",
                        "route set: player — EN direct '\(entry.name)'")
            present(.playEN(session: session, meta: entry))
        } label: {
            NuvioEntryRow(entry: entry)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func bucketList(channels: [Channel], emptyText: String) -> some View {
        let now = Date()
        let entries = store.entries(for: channels)
        let live = entries.filter { $0.bucket(now: now) == 0 }
        let upcoming = entries.filter {
            let b = $0.bucket(now: now)
            return b == 1 || b == 2
        }
        let rest = entries.filter { $0.bucket(now: now) == 3 }

        return List {
            if channels.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !live.isEmpty {
                Section {
                    ForEach(live) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Đang đá", live: true)
                }
            }
            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Sắp đá", live: false)
                }
            }
            if !rest.isEmpty {
                Section {
                    ForEach(rest) { entry in matchRow(entry) }
                } header: {
                    sectionHeader("Khác", live: false)
                }
            }
            footerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }

    // MARK: - Shared rows

    private func matchRow(_ entry: FixtureEntry) -> some View {
        Button {
            // DB-07: the tap anchor of the tap→play timeline.
            DiagLog.log("player",
                        "tap: fixture '\(MatchTitle.clean(entry.channel.title))' from the list")
            // A fixture tap opens its link board (spec §2.1);
            // the board's row tap enters the player.
            present(.board(entry))
        } label: {
            MatchCard(entry: entry)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    private func sectionHeader(_ title: String, live: Bool) -> some View {
        HStack(spacing: 6) {
            if live {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            }
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(.white.opacity(0.6))
        }
        .listRowBackground(Color.clear)
    }

    private var footerRow: some View {
        Text("Đá Banh v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") • \(store.channels.count) trận")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .padding(.vertical, 8)
    }

    // MARK: - Loading / empty overlay (first load, or error with retry)

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            if store.isLoading {
                ProgressView().tint(.white)
            }
            Text(store.statusMessage ?? "Đang tải danh sách kênh…")
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !store.isLoading {
                Button("Thử lại") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentGreen)
            }
        }
        .padding()
    }
}

/// The diagnostic-log sheet (1.24): preview the log's tail,
/// send the file out through the iOS share sheet, or clear it.
/// The file itself is the deliverable (DiagLog in
/// PlaylistStore.swift) — this view only presents it.
private struct DiagLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Log trống." : text)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color.black)
            .navigationTitle("Log chẩn đoán")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: DiagLog.fileURL) {
                        Label("Gửi log", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Xoá log", role: .destructive) {
                        DiagLog.clear()
                        text = ""
                    }
                }
            }
            .onAppear { text = DiagLog.snapshot() }
        }
        .preferredColorScheme(.dark)
    }
}

/// Small red dot that pulses while matches are live.
private struct PulsingDot: View {
    @State private var faded = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(faded ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: faded)
            .onAppear { faded = true }
    }
}
