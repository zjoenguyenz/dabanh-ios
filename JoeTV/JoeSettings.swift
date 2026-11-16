import SwiftUI
import UIKit

/// Settings: ONLY the torrent/debrid credentials, exactly like
/// the Android app — the owner's own Torrentio URL and/or his
/// Real-Debrid / TorBox tokens, plus the OpenSubtitles addon.
/// Values live in this app's UserDefaults; token fields are
/// secure-entry and the saved state is shown masked.
///
/// Deliberately ABSENT on tvOS (owner brief, 2026-11-13):
/// - No tunnel switch — there is no keeper app on Apple TV;
///   routing is the OS-level Sing-box profile's job.
/// - No external-player picker — tvOS cannot hand playback to
///   VLC/MX the way Android can; shipping a dead control would
///   be worse than omitting it. Playback is AVPlayer everywhere.
struct JoeSettingsView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    /// v2.0.0 (UI-5): the design picker writes the same
    /// @AppStorage key the root reads; the Settings tree itself
    /// keeps ONE structure across themes (only token values
    /// change), so focus stays on the tapped chip through the
    /// switch — never stranded.
    @AppStorage("joeThemeID") private var themeIDRaw = JoeThemeID.sourceBoard.rawValue
    @State private var addonURL: String = TorrentSettings.addonURL
    @State private var rdToken: String = TorrentSettings.rdToken
    @State private var torboxToken: String = TorrentSettings.torboxToken
    @State private var subAddonURL: String = TorrentSettings.subAddonURL.isEmpty
        ? TorrentSettings.opensubtitlesDefault : TorrentSettings.subAddonURL
    @State private var tmdbKey: String = UserDefaults.standard.string(forKey: "tmdb_api_key") ?? ""
    @State private var savedTick = false
    @State private var probeResults: [SourceProbe.Result] = []
    @State private var probing = false
    /// Per-field guidance hints shown under a credential
    /// field after its "Nhập từ iPhone" button is pressed
    /// (1.9.2, item 7).
    @State private var inputHints: [String: String] = [:]
    /// KK route status for the tunnel-status row (item 5).
    @State private var kkStatus: KKRouteStatus = .idle
    @FocusState private var focusedField: String?
    @FocusState private var probeFocused: Bool
    @FocusState private var kkProbeFocused: Bool
    @FocusState private var themeChipFocused: String?

    private enum KKRouteStatus {
        case idle, probing, ok(ms: Int), down
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cài đặt")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(theme.text)
                    Text(TorrentSettings.isConfigured
                         ? "Nguồn Torrent: đã cấu hình ✓"
                         : "Nguồn Torrent: chưa cấu hình — mục Phim Torrent cần ít nhất một mục dưới đây")
                        .font(.system(size: 25))
                        .foregroundStyle(TorrentSettings.isConfigured
                                         ? JoeTheme.okGreen : .orange)
                }

                themeBlock

                tunnelStatusBlock

                field(title: "Link Torrentio của anh (tuỳ chọn)",
                      hint: "Dán nguyên link Torrentio đã gắn Real-Debrid/TorBox của anh. Để trống thì app tự dựng link từ token bên dưới.",
                      text: $addonURL, id: "addon", secure: false, allowsPaste: true)
                field(title: "Token Real-Debrid",
                      hint: "Mã tài khoản Real-Debrid của anh — dùng để giải link torrent và dựng Torrentio khi chưa có link ở trên.",
                      text: $rdToken, id: "rd", secure: true, allowsPaste: true)
                field(title: "Token TorBox",
                      hint: "Mã tài khoản TorBox của anh (nếu dùng TorBox thay Real-Debrid).",
                      text: $torboxToken, id: "tb", secure: true, allowsPaste: true)
                field(title: "Addon phụ đề (OpenSubtitles)",
                      hint: "Mặc định là OpenSubtitles v3 chính thức — app kiểm tra phụ đề Việt cho mỗi phim torrent.",
                      text: $subAddonURL, id: "sub", secure: false)
                field(title: "TMDB API Key",
                      hint: "Chỉ nhập khi anh muốn dùng key TMDB riêng thay cho key tích hợp sẵn trong app.",
                      text: $tmdbKey, id: "tmdb", secure: true)
                // C-13 / §7.8: the field starts empty on a fresh
                // install even though TMDB is already active via
                // the bundled key — v1.8's "Tuỳ chọn" hint made it
                // read as "not set up". Say which key is live.
                if !TMDBClient.apiKey.isEmpty {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(JoeTheme.okGreen)
                            .frame(width: 12, height: 12)
                        Text(tmdbKey.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "TMDB: đang dùng key tích hợp sẵn ✓"
                             : "TMDB: đang dùng key anh nhập ✓")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                    }
                }

                HStack(spacing: 14) {
                    if savedTick {
                        Text("Đã lưu ✓")
                            .font(.system(size: 25))
                            .foregroundStyle(JoeTheme.okGreen)
                    } else {
                        Text("Mọi thay đổi tự lưu ngay khi nhập — không cần bấm Lưu.")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.meta)
                    }
                }

                Text("Trên Apple TV không có công tắc hầm trong app: đường truyền Việt Nam do profile Sing-box của hệ thống đảm nhiệm. Token chỉ lưu trong app này trên Apple TV của anh, không gửi đi đâu ngoài dịch vụ tương ứng.")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
                    .frame(maxWidth: 1200, alignment: .leading)

                diagnosticsBlock

                signpostBlock

                // Hero forensics fix (2026-11-15): the real
                // bundle version, like the corner label — this
                // footer carried the same frozen "v2.0.0".
                Text("Joe TV v\(JoeRootView.appVersion)")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
            }
        }
        // CONVERGENCE (Team 7 D4 + spec item 3, 2026-11-15):
        // the JoeSettingsMoveTrap (enabled: focusedField ==
        // "addon") and the focus-hub consumer that used to sit
        // here are REMOVED. The trap's flips rebuilt the whole
        // settings ScrollView; its routing — UP from the first
        // field to the pills, DOWN to the second field — is
        // what geometric focus movement does on this
        // single-column layout unaided, and pill DOWN lands on
        // the first field geometrically.
        // 1.9.2 (Team 9 item 4): Menu in this SECTION returns
        // to the Phim section — the app's main menu — instead
        // of exiting the app (the owner's Android model).
        // Unconditional, on this section's own root.
        .onExitCommand { nav.section = .phim }
        // Item 5: the KK route probe runs when Settings opens.
        .task { await runKKProbe() }
        .onDisappear { save(silent: true) }
        .onChange(of: addonURL) { save() }
        .onChange(of: rdToken) { save() }
        .onChange(of: torboxToken) { save() }
        .onChange(of: subAddonURL) { save() }
        .onChange(of: tmdbKey) { save() }
    }

    /// The "Giao diện" row (v2.0.0, UI-5): three chips, one per
    /// design. The active design's chip wears the accent fill;
    /// tapping another switches the whole app immediately —
    /// this screen's own structure does not change, only its
    /// token values, so focus remains on the chip row.
    private var themeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Giao diện")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                ForEach(JoeThemeID.allCases, id: \.self) { id in
                    Button {
                        themeIDRaw = id.rawValue
                    } label: {
                        JoeChipLabel(title: id.pickerLabel,
                                     selected: themeIDRaw == id.rawValue)
                    }
                    .buttonStyle(.card)
                    .focused($themeChipFocused, equals: id.rawValue)
                }
            }
            Text("Đổi giao diện áp dụng ngay cho toàn app: trang chủ, trang phim, tìm kiếm và trình phát.")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1250, alignment: .leading)
        }
    }

    private func field(title: String, hint: String,
                       text: Binding<String>, id: String, secure: Bool,
                       allowsPaste: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(alignment: .center, spacing: 16) {
                Group {
                    if secure {
                        // v2.0.3: a secure field's own masked
                        // rendering drops out while focus moves
                        // or the page scrolls (tvOS redraws the
                        // secure text lazily), which made a saved
                        // token read as an empty field. The
                        // bullet row UNDER the field is painted
                        // from the stored string itself — always
                        // installed, same font and colour the
                        // chrome applies — so the masked state
                        // is stable in every focus/scroll state;
                        // the field's own dots coincide with it
                        // whenever the system does draw them.
                        // The value itself is never rendered —
                        // one bullet per stored character, capped.
                        ZStack(alignment: .leading) {
                            Text(String(repeating: "•",
                                        count: min(text.wrappedValue.count, 40)))
                                .allowsHitTesting(false)
                            SecureField("", text: text)
                        }
                    } else {
                        TextField("", text: text)
                    }
                }
                .textFieldStyle(.plain)
                // UI-6 defect D-22: field text is 31 pt at
                // every field site (the shared token).
                .font(.system(size: ThemeTokens.fieldTextSize))
                .joeFieldChrome(focused: focusedField == id)
                .focused($focusedField, equals: id)
                .onSubmit { save() }
                if allowsPaste {
                    iphoneInputButton(id: id)
                }
            }
            .frame(maxWidth: 1250, alignment: .leading)
            Text(hint)
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1250, alignment: .leading)
            if let inputHint = inputHints[id] {
                Text(inputHint)
                    .font(.system(size: 25))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 1250, alignment: .leading)
            }
        }
    }

    /// The credential-entry helper for a field (1.9.2, Team 9
    /// item 7, rewritten by TEAM 10-FIXUP-2). tvOS has NO
    /// pasteboard API — the pasteboard class is marked
    /// API_UNAVAILABLE on tvOS and build #16 failed
    /// compiling it — so the app
    /// cannot read the clipboard itself. The route tvOS does
    /// support is the iPhone keyboard: while a field is
    /// focused, the owner's iPhone offers the Apple TV
    /// keyboard (a notification appears on the iPhone), where
    /// he pastes the code he copied and the text lands in the
    /// field directly, saved by the fields' existing
    /// auto-save. This button therefore only focuses the
    /// field and shows the guidance hint under it — it does
    /// not, and must not claim to, paste anything itself.
    /// Typing a long token with the remote was the dead end
    /// that left torrent unconfigured on this device.
    private func iphoneInputButton(id: String) -> some View {
        Button {
            inputHints[id] = "Đã chọn ô nhập — mở bàn phím Apple TV trên iPhone của anh (thông báo hiện trên iPhone khi ô đang được chọn), dán mã vào đó, chữ sẽ tự vào ô này."
            focusedField = id
        } label: {
            JoePrimaryLabel(title: "Nhập từ iPhone")
        }
        .buttonStyle(.card)
        .focused($focusedField, equals: "paste|" + id)
    }

    /// Tunnel status row (1.9.2, Team 9 item 5): READ-ONLY —
    /// whether the Vietnam route is answering right now,
    /// probed through KKPhim with a short fuse when Settings
    /// opens and on demand. Display only: no switch, no
    /// control (routing stays the Sing-box profile's job, per
    /// this screen's standing rule). The copy labels the
    /// verdict as what it is — an inference from KK answering,
    /// not a read of the profile's actual state.
    @ViewBuilder
    private var tunnelStatusBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(kkStatusColor)
                    .frame(width: 16, height: 16)
                Text(kkStatusText)
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 1250, alignment: .leading)
            }
            Button {
                Task { await runKKProbe() }
            } label: {
                JoePrimaryLabel(title: "Kiểm tra lại")
            }
            .buttonStyle(.card)
            .focused($kkProbeFocused)
            .disabled(kkProbing)
        }
    }

    private var kkProbing: Bool {
        if case .probing = kkStatus { return true }
        return false
    }

    private var kkStatusColor: Color {
        switch kkStatus {
        case .ok: return JoeTheme.okGreen
        case .down: return JoeTheme.accentRed
        case .idle, .probing: return .white.opacity(0.4)
        }
    }

    private var kkStatusText: String {
        switch kkStatus {
        case .ok(let ms):
            return "Đường KKPhim: đang thông (~\(ms) ms) — đường Việt Nam đang tới được, hầm có vẻ đang bật"
        case .down:
            return "Đường KKPhim: không thông — kiểm tra profile hầm trên Apple TV"
        case .idle, .probing:
            return "Đang kiểm tra đường KKPhim…"
        }
    }

    private func runKKProbe() async {
        if kkProbing { return }
        kkStatus = .probing
        let r = await SourceProbe.probeKK()
        kkStatus = r.ok ? .ok(ms: r.millis) : .down
    }

    /// Source diagnostics (§7.9, board contract): one lightweight
    /// probe per provider, run ON THIS device, results rendered
    /// in place — the block exists so a dead route shows a named
    /// verdict on the TV instead of a silent spinner elsewhere.
    /// Focus stays on the button; result rows are not focusable.
    @ViewBuilder
    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Kiểm tra nguồn phim")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            Text("Đo từng nguồn phim ngay trên máy này.")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
            if probing {
                HStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text("Đang kiểm tra…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                }
            } else if !probeResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(probeResults.enumerated()), id: \.offset) { _, result in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(result.ok
                                      ? JoeTheme.okGreen
                                      : JoeTheme.accentRed)
                                .frame(width: 16, height: 16)
                            Text(result.name)
                                .font(.system(size: 29))
                                .foregroundStyle(theme.text)
                            Spacer()
                            Text("\(result.millis) ms")
                                .font(.system(size: 25))
                                .foregroundStyle(theme.meta)
                            Text(result.note)
                                .font(.system(size: 25))
                                .foregroundStyle(result.ok ? .white.opacity(0.7) : .orange)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(height: 60)
                    }
                }
            }
            Button {
                probing = true
                Task {
                    probeResults = await SourceProbe.run()
                    probing = false
                }
            } label: {
                JoePrimaryLabel(title: "Kiểm tra ngay")
            }
            .buttonStyle(.card)
            .focused($probeFocused)
            .disabled(probing)
        }
    }

    /// Phim load signposts (convergence spec 5d): the tail of
    /// the persisted LoadSignpost log, read-only. After any
    /// future stall the owner force-closes, relaunches, opens
    /// Settings and photographs this block — the last entries
    /// say where the load path stopped. No buttons, no writes.
    @ViewBuilder
    private var signpostBlock: some View {
        let entries = LoadSignpost.entries()
        VStack(alignment: .leading, spacing: 12) {
            Text("Nhật ký tải phim (chẩn đoán)")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            if entries.isEmpty {
                Text("Chưa có dữ liệu — mở trang Phim một lần rồi quay lại.")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
                    .frame(maxWidth: 1200, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.suffix(15).enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 1400, alignment: .leading)
                    }
                }
            }
        }
    }

    private func save(silent: Bool = false) {
        TorrentSettings.addonURL = addonURL.trimmingCharacters(in: .whitespaces)
        TorrentSettings.rdToken = rdToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.torboxToken = torboxToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.subAddonURL = subAddonURL.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(tmdbKey.trimmingCharacters(in: .whitespaces),
                                  forKey: "tmdb_api_key")
        if !silent {
            savedTick = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                savedTick = false
            }
        }
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeSettingsMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// first-field routing it powered is geometric on this layout.
