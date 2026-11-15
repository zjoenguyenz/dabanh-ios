import SwiftUI

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
    @State private var addonURL: String = TorrentSettings.addonURL
    @State private var rdToken: String = TorrentSettings.rdToken
    @State private var torboxToken: String = TorrentSettings.torboxToken
    @State private var subAddonURL: String = TorrentSettings.subAddonURL.isEmpty
        ? TorrentSettings.opensubtitlesDefault : TorrentSettings.subAddonURL
    @State private var tmdbKey: String = UserDefaults.standard.string(forKey: "tmdb_api_key") ?? ""
    @State private var savedTick = false
    @State private var probeResults: [SourceProbe.Result] = []
    @State private var probing = false
    @FocusState private var focusedField: String?
    @FocusState private var probeFocused: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cài đặt")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(TorrentSettings.isConfigured
                         ? "Nguồn Torrent: đã cấu hình ✓"
                         : "Nguồn Torrent: chưa cấu hình — mục Phim Torrent cần ít nhất một mục dưới đây")
                        .font(.system(size: 25))
                        .foregroundStyle(TorrentSettings.isConfigured
                                         ? JoeTheme.okGreen : .orange)
                }

                field(title: "Link Torrentio của anh (tuỳ chọn)",
                      hint: "Dán nguyên link Torrentio đã gắn Real-Debrid/TorBox của anh. Để trống thì app tự dựng link từ token bên dưới.",
                      text: $addonURL, id: "addon", secure: false)
                field(title: "Token Real-Debrid",
                      hint: "Mã tài khoản Real-Debrid của anh — dùng để giải link torrent và dựng Torrentio khi chưa có link ở trên.",
                      text: $rdToken, id: "rd", secure: true)
                field(title: "Token TorBox",
                      hint: "Mã tài khoản TorBox của anh (nếu dùng TorBox thay Real-Debrid).",
                      text: $torboxToken, id: "tb", secure: true)
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
                            .foregroundStyle(.white.opacity(0.7))
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
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Text("Trên Apple TV không có công tắc hầm trong app: đường truyền Việt Nam do profile Sing-box của hệ thống đảm nhiệm. Token chỉ lưu trong app này trên Apple TV của anh, không gửi đi đâu ngoài dịch vụ tương ứng.")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 1200, alignment: .leading)

                diagnosticsBlock

                signpostBlock
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
        .onDisappear { save(silent: true) }
        .onChange(of: addonURL) { save() }
        .onChange(of: rdToken) { save() }
        .onChange(of: torboxToken) { save() }
        .onChange(of: subAddonURL) { save() }
        .onChange(of: tmdbKey) { save() }
    }

    private func field(title: String, hint: String,
                       text: Binding<String>, id: String, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(.white)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 29))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(focusedField == id ? joeFocusViolet : Color.clear,
                              lineWidth: 4))
            .frame(maxWidth: 1250)
            .focused($focusedField, equals: id)
            .focusEffectDisabled(true)
            .onSubmit { save() }
            Text(hint)
                .font(.system(size: 25))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: 1250, alignment: .leading)
        }
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
                .foregroundStyle(.white)
            Text("Đo từng nguồn phim ngay trên máy này.")
                .font(.system(size: 25))
                .foregroundStyle(.white.opacity(0.7))
            if probing {
                HStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text("Đang kiểm tra…")
                        .font(.system(size: 29))
                        .foregroundStyle(.white)
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
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(result.millis) ms")
                                .font(.system(size: 25))
                                .foregroundStyle(.white.opacity(0.7))
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
                Text("Kiểm tra ngay")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(JoeTheme.accentViolet))
                    .overlay(JoeFocusRing(shape: Capsule()))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled(true)
            .focused($probeFocused)
            .scaleEffect(probeFocused ? 1.05 : 1.0)
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
                .foregroundStyle(.white)
            if entries.isEmpty {
                Text("Chưa có dữ liệu — mở trang Phim một lần rồi quay lại.")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
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

/// v1.5 focus outline colour (lighter violet) — the style law's
/// focus stroke; replaces the fields' old white focused stroke.
private let joeFocusViolet = Color(red: 0.72, green: 0.58, blue: 1.0)

// CONVERGENCE RECORD (2026-11-15): JoeSettingsMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// first-field routing it powered is geometric on this layout.
