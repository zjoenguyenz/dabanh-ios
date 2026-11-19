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
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedChannel: Channel?
    @State private var selectedSession: MatchPlaySession?
    /// The Nuvio addon source for the BLV Anh tab (its content
    /// leads the tab; the mirror's EN block stays below it as
    /// the fallback pool). Owned here — it feeds no other tab.
    @StateObject private var nuvio = NuvioAddonStore()
    @State private var selectedAddon: NuvioMeta?
    @State private var selectedAddonSession: MatchPlaySession?

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
    /// group), one entry per fixture.
    private var featuredEntries: [FixtureEntry] {
        Array(FixtureEntry.group(store.liveChannels).prefix(12))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.08),
                         Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

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

            if store.channels.isEmpty {
                loadingOverlay
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await store.start()
            // Pre-resolve the fixtures the first screen leads with
            // (the featured rail), so the likeliest first tap opens
            // on already-verified sources. ResolveHub bounds the
            // pass to three fixtures and shares any session a tap
            // asks for while it runs (single-flight).
            await MainActor.run {
                ResolveHub.shared.preresolve(
                    ladders: featuredEntries.prefix(3).map { store.sources(for: $0.channel) })
            }
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
        .fullScreenCover(item: $selectedChannel, onDismiss: { selectedSession = nil }) { _ in
            // The session was captured at tap time (see the tap
            // sites); the cover never calls the hub itself, so a
            // re-evaluation here cannot swap the live player's
            // session out from under it.
            if let selectedSession {
                PlayerView(session: selectedSession)
            }
        }
        .fullScreenCover(item: $selectedAddon, onDismiss: { selectedAddonSession = nil }) { _ in
            // Same tap-time capture as the playlist cover above:
            // the addon store vended the session at the tap; the
            // cover only presents it.
            if let selectedAddonSession {
                PlayerView(session: selectedAddonSession)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(accentGreen)
                Image(systemName: "soccerball")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Đá Banh")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                if liveChannels.count > 0 {
                    HStack(spacing: 6) {
                        PulsingDot()
                        Text("\(liveChannels.count) trận đang đá")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                } else {
                    Text("\(store.channels.count) trận trong lịch")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer()

            RoutePickerView()
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.10)))

            Button {
                Task { await store.refresh() }
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    if store.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .disabled(store.isLoading)
            .accessibilityLabel("Làm mới")

            // Manual link check (owner's request, 2026-11-13): fetch
            // the newest list, re-probe every link from this phone,
            // and republish the match screens without the dead ones.
            Button {
                Task { await store.refreshAndValidate() }
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    if store.isValidating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark.shield")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .disabled(store.isLoading || store.isValidating)
            .accessibilityLabel("Kiểm tra link")
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
                            selectedSession = ResolveHub.shared.session(for: store.sources(for: entry.channel))
                            selectedChannel = entry.channel
                        } label: {
                            FeaturedCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - League chips

    private var leagueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !store.liveChannels.isEmpty {
                    liveChip
                }
                hotChip
                if !enChannels.isEmpty || nuvio.hasContent {
                    enChip
                }
                ForEach(League.allCases) { league in
                    let selected = store.selectedLeague == league.rawValue
                    Button {
                        store.selectedLeague = league.rawValue
                    } label: {
                        Text(league.name)
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
            Text("BLV Anh")
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
        return AnyView(leagueBucketList)
    }

    private var liveList: some View {
        bucketList(channels: store.liveChannels,
                   emptyText: "Hiện không có trận nào đang đá. Các trận sắp tới nằm ở mục Hot và các giải.")
    }

    private var hotList: some View {
        bucketList(channels: store.hotChannels,
                   emptyText: "Chưa có trận hot nào. Trang nguồn gắn cờ hot cho trận nào thì trận đó hiện ở đây.")
    }

    private var leagueBucketList: some View {
        let league = League(rawValue: store.selectedLeague) ?? .england
        // The EN block lives under its own chip only — keep its
        // channels out of the league lists (they are all rank 9, so
        // without this they pile into the Khác tab as pseudo-fixtures).
        return bucketList(channels: store.channels(in: league).filter { !LeagueClassifier.isEN($0) },
                          emptyText: "Chưa có kênh nào trong mục này.")
    }

    /// The BLV Anh tab (owner order 2026-11-19): the Nuvio
    /// addon's content leads — live events, upcoming events,
    /// then its 24/7 football channels — and the mirror's
    /// English-commentary block stays BELOW as the fallback pool,
    /// so the tab still has channels when the addon is down.
    /// Nothing from the addon appears in any other tab: these
    /// sections render only here, fed by the addon store, never
    /// by the playlist store the other tabs read.
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
                            selectedSession = ResolveHub.shared.session(for: store.sources(for: channel))
                            selectedChannel = channel
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
            selectedAddonSession = nuvio.session(for: entry)
            selectedAddon = entry
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
        let entries = FixtureEntry.group(channels)
        let live = entries.filter { LeagueClassifier.bucket(of: $0.channel, now: now) == 0 }
        let upcoming = entries.filter {
            let b = LeagueClassifier.bucket(of: $0.channel, now: now)
            return b == 1 || b == 2
        }
        let rest = entries.filter { LeagueClassifier.bucket(of: $0.channel, now: now) == 3 }

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
            selectedSession = ResolveHub.shared.session(for: store.sources(for: entry.channel))
            selectedChannel = entry.channel
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
        Text("Đá Banh v1.13 • \(store.channels.count) trận")
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
