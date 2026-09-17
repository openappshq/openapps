import MacPaperCore
import SwiftUI

/// History: what reached a desktop, newest first, one entry per look.
/// Clicking one loads it (live apply takes it back to the desktop);
/// the x forgets it; Clear forgets all.
struct HistorySection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            if model.historyList.isEmpty {
                Text("Nothing applied yet. Every look that reaches the desktop lands here.")
                    .font(Brand.body(13))
                    .foregroundStyle(Brand.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PanelList(count: model.historyList.count) {
                    ForEach(model.historyList) { entry in
                        HistoryRow(model: model, entry: entry)
                        if entry.id != model.historyList.last?.id {
                            Rectangle().fill(Brand.Panel.hairline).frame(height: 1)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear history") { model.clearHistory() }
                        .buttonStyle(PanelLinkButtonStyle())
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let model: AppModel
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            Button {
                model.load(entry.wallpaper)
            } label: {
                HStack(spacing: Brand.Space.s12) {
                    DocumentThumbnail(model: model, wallpaper: entry.wallpaper, selected: entry.wallpaper == model.draft)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Recipe.defaultName(for: entry.wallpaper))
                            .font(Brand.body(13, weight: 600))
                            .foregroundStyle(Brand.Panel.textPrimary)
                            .lineLimit(1)
                        Text("\(entry.appliedAt.formatted(.relative(presentation: .named))) · seed \(entry.wallpaper.seedText)")
                            .font(Brand.mono(11))
                            .foregroundStyle(Brand.Panel.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Recipe.defaultName(for: entry.wallpaper)), applied \(entry.appliedAt.formatted(.relative(presentation: .named)))")
            .accessibilityHint("Loads it and applies it again")
            Button {
                model.toggleFavoriteOf(entry.wallpaper)
            } label: {
                Image(systemName: model.favorites.contains(entry.wallpaper) ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.favorites.contains(entry.wallpaper) ? Brand.Panel.accent : Brand.Panel.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.favorites.contains(entry.wallpaper) ? "Remove from the library" : "Save to the library")
            Button {
                model.removeHistory(entry)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Panel.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget")
        }
        .frame(height: PanelLayout.listRowHeight)
    }
}
