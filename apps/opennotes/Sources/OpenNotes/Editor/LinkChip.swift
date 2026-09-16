import SwiftUI

/// The small chip over a link the pointer rests on: the host or the file
/// name, and the gesture that opens it. Nothing is fetched to make it.
struct LinkChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Brand.mono(10, medium: true))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
            Text("⌘click")
                .font(Brand.mono(9))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link: \(label). ⌘-click opens it")
    }
}
