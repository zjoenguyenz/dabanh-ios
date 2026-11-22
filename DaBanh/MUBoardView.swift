import SwiftUI

/// The in-player source board in MU sheet language
/// (FIX-MU-5, item E — audit #188): when an MU-family theme
/// is active, PlayerView's "Tất cả nguồn" sheet presents
/// THIS board instead of the classic navy MatchBoardView.
/// Presentation only — it is fed the SAME entry, metas and
/// switch callbacks as the classic board's in-player mode,
/// in the same order (VN group first), with the playing
/// row marked; a row tap fires the same switch the classic
/// row's tap fires, and the host closes the sheet through
/// those callbacks exactly as before. The board's own
/// background duties (the pre-warm re-base behind the
/// playing row, the FotMob-incidents priority) are the
/// classic in-player board's, carried verbatim.
struct MUBoardView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    let entry: FixtureEntry
    let enMetas: [NuvioMeta]
    let onPlayVN: (Channel) -> Void
    let onPlayEN: (NuvioMeta) -> Void
    var playingChannelURL: String? = nil
    var playingENMetaID: String? = nil

    private var ladder: [Channel] { store.sources(for: entry.channel) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("CHỌN NGUỒN PHÁT")
                    .font(MUFont.display(24))
                    .muDisplayTracking(24)
                    .foregroundStyle(MUTokens.cream)
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MUTokens.cream)
                        .frame(width: 44, height: 44)
                        .background(MUPressedBackground(Circle(), MUTokens.bg))
                        .overlay(Circle().stroke(MUTokens.border, lineWidth: 1))
                }
                .buttonStyle(MUPressButtonStyle())
                .accessibilityLabel("Đóng")
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    groupHeader("Tiếng Việt", right: "Ưu tiên · \(ladder.count) nguồn")
                    VStack(spacing: 8) {
                        ForEach(ladder) { channel in
                            vnRow(channel)
                        }
                    }
                    if !enMetas.isEmpty {
                        groupHeader("Tiếng Anh", right: "English · \(enMetas.count) nguồn")
                        VStack(spacing: 8) {
                            ForEach(enMetas) { meta in
                                enRow(meta)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MUTokens.card.ignoresSafeArea())
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(MUTokens.sheetBorder, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .task {
            // The classic in-player board's duties, verbatim:
            // deep-warm re-based behind the playing row, and
            // first in line for the fixture's FotMob incidents.
            await MainActor.run {
                SourcePrewarmStore.shared.warm(
                    ladder: ladder, startingAfter: playingChannelURL,
                    excluding: Set(playingChannelURL.map { [$0] } ?? []))
            }
            await store.liveStates.ensureDetails(for: entry.channel)
        }
    }

    private func groupHeader(_ title: String, right: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(MUFont.body(13, .medium))
                .foregroundStyle(MUTokens.cream)
            Spacer(minLength: 8)
            Text(right)
                .font(MUFont.body(10))
                .foregroundStyle(MUTokens.secondary)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func vnRow(_ channel: Channel) -> some View {
        let isPlaying = channel.url == playingChannelURL
        let name = muCommentatorName(MatchTitle.clean(channel.title), group: channel.group)
        return Button {
            onPlayVN(channel)
        } label: {
            boardRow(name: name,
                     note: isPlaying ? "Đang phát" : "Bình luận tiếng Việt",
                     isPlaying: isPlaying)
        }
        .buttonStyle(MUPressButtonStyle())
    }

    private func enRow(_ meta: NuvioMeta) -> some View {
        let isPlaying = meta.id == playingENMetaID
        let name = meta.competitionString ?? meta.channelHint ?? meta.displayName
        return Button {
            onPlayEN(meta)
        } label: {
            boardRow(name: name,
                     note: isPlaying ? "Đang phát" : "Bình luận tiếng Anh",
                     isPlaying: isPlaying)
        }
        .buttonStyle(MUPressButtonStyle())
    }

    /// One board row in the MU detail rows' geometry
    /// (min-height 60, padding 8v/12h, gap 10, radius 12,
    /// badge 35×32): the playing row wears the design's
    /// selected state (maroon fill, gold border, gold
    /// check); every other row keeps the play affordance.
    private func boardRow(name: String, note: String, isPlaying: Bool) -> some View {
        HStack(spacing: 10) {
            Text(muBadgeText(name))
                .font(MUFont.body(11, .bold))
                .foregroundStyle(MUTokens.bg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 35, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(MUTokens.cream)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(MUFont.body(13, .semibold))
                    .foregroundStyle(isPlaying ? MUTokens.gold : MUTokens.cream)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Text(note)
                    .font(MUFont.body(10))
                    .foregroundStyle(MUTokens.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPlaying {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MUTokens.gold)
            } else {
                Image(systemName: "play.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(MUTokens.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .background(
            MUPressedBackground(
                RoundedRectangle(cornerRadius: 12),
                isPlaying ? MUTokens.selectedFill : MUTokens.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isPlaying ? MUTokens.gold : MUTokens.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
