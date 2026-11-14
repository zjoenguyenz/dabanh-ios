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
    @State private var addonURL: String = TorrentSettings.addonURL
    @State private var rdToken: String = TorrentSettings.rdToken
    @State private var torboxToken: String = TorrentSettings.torboxToken
    @State private var subAddonURL: String = TorrentSettings.subAddonURL.isEmpty
        ? TorrentSettings.opensubtitlesDefault : TorrentSettings.subAddonURL
    @State private var savedTick = false
    @FocusState private var focusedField: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cài đặt")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(TorrentSettings.isConfigured
                         ? "Nguồn Torrent: đã cấu hình ✓"
                         : "Nguồn Torrent: chưa cấu hình — mục Phim Torrent cần ít nhất một mục dưới đây")
                        .font(.system(size: 21))
                        .foregroundStyle(TorrentSettings.isConfigured
                                         ? .green : .orange)
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

                HStack(spacing: 18) {
                    Button {
                        save()
                    } label: {
                        Text("Lưu cài đặt")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 15)
                            .background(Capsule().fill(JoeTheme.accentViolet.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    if savedTick {
                        Text("Đã lưu ✓")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                    }
                }

                Text("Trên Apple TV không có công tắc hầm trong app: đường truyền Việt Nam do profile Sing-box của hệ thống đảm nhiệm. Token chỉ lưu trong app này trên Apple TV của anh, không gửi đi đâu ngoài dịch vụ tương ứng.")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: 1200, alignment: .leading)
            }
            .padding(.leading, 44)
            .padding(.trailing, 52)
            .padding(.top, 36)
            .padding(.bottom, 40)
        }
        .onDisappear { save(silent: true) }
    }

    private func field(title: String, hint: String,
                       text: Binding<String>, id: String, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 24))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 13)
                .fill(Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(focusedField == id ? Color.white : Color.clear,
                              lineWidth: 2.5))
            .frame(maxWidth: 1250)
            .focused($focusedField, equals: id)
            .onSubmit { save() }
            Text(hint)
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: 1250, alignment: .leading)
        }
    }

    private func save(silent: Bool = false) {
        TorrentSettings.addonURL = addonURL.trimmingCharacters(in: .whitespaces)
        TorrentSettings.rdToken = rdToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.torboxToken = torboxToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.subAddonURL = subAddonURL.trimmingCharacters(in: .whitespaces)
        if !silent {
            savedTick = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                savedTick = false
            }
        }
    }
}
