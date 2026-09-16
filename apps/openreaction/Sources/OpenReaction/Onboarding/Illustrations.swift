import AppKit
import OpenReactionCore
import SwiftUI

/// Whether to draw System Settings the way macOS 26 does (floating inset
/// sidebar, rounder corners) or the way macOS 14 and 15 do (flush sidebar).
private var drawsTahoeChrome: Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
}

/// Native-drawn sketch of System Settings: Privacy & Security is selected, the
/// OpenReaction row is found and its switch turns on, with a pointer moving
/// through the steps. Static (final state, no pointer) with Reduce Motion.
/// No Apple artwork is used; shapes only suggest the real pane.
struct SettingsPaneIllustration: View {
    let kind: PermissionKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: CaseIterable {
        case start, sidebar, row, switchOn, hold
    }

    var body: some View {
        Group {
            if reduceMotion {
                SettingsPaneDrawing(kind: kind, phase: .hold, showsPointer: false)
            } else {
                PhaseAnimator(Phase.allCases) { phase in
                    SettingsPaneDrawing(kind: kind, phase: phase, showsPointer: true)
                } animation: { phase in
                    switch phase {
                    case .start: .easeInOut(duration: 0.3).delay(0.2)
                    case .sidebar: .easeInOut(duration: 0.7).delay(0.6)
                    case .row: .easeInOut(duration: 0.7).delay(0.5)
                    case .switchOn: .spring(duration: Brand.Motion.expressive, bounce: 0.2).delay(0.5)
                    case .hold: .linear(duration: 0.01).delay(1.8)
                    }
                }
            }
        }
        .frame(width: SettingsPaneDrawing.size.width, height: SettingsPaneDrawing.size.height)
        .accessibilityElement()
        .accessibilityLabel("Illustration: in System Settings, choose Privacy & Security, then \(kind.title), and switch on OpenReaction.")
    }
}

private struct SettingsPaneDrawing: View {
    static let size = CGSize(width: 340, height: 210)

    let kind: PermissionKind
    let phase: SettingsPaneIllustration.Phase
    let showsPointer: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private let tahoe = drawsTahoeChrome
    private let sidebarWidth: CGFloat = 104
    private let selectedSidebarRow = 4
    private let listTop: CGFloat = 72
    private let rowHeight: CGFloat = 32
    private var ourRow: Int { 2 }

    private var sidebarSelected: Bool { phase != .start }
    private var rowFound: Bool { phase == .row || phase == .switchOn || phase == .hold }
    private var switchedOn: Bool { phase == .switchOn || phase == .hold }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: tahoe ? 18 : 10, style: .continuous)
                .fill(windowFill)
                .overlay {
                    RoundedRectangle(cornerRadius: tahoe ? 18 : 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(highContrast ? 0.5 : 0.15), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            sidebar
            content
                .opacity(sidebarSelected ? 1 : 0.35)
            if showsPointer {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.black)
                    .shadow(color: .white, radius: 0.5)
                    .shadow(color: .white, radius: 0.5)
                    .position(pointerPosition)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ZStack(alignment: .topLeading) {
            if tahoe {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sidebarFill)
                    .frame(width: sidebarWidth - 8, height: Self.size.height - 12)
                    .offset(x: 6, y: 6)
            } else {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(sidebarFill)
                    .frame(width: sidebarWidth, height: Self.size.height)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1, height: Self.size.height)
                    .offset(x: sidebarWidth)
            }
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill([Color(nsColor: .systemRed), Color(nsColor: .systemYellow), Color(nsColor: .systemGreen)][index].opacity(0.85))
                        .frame(width: 8, height: 8)
                }
            }
            .offset(x: 16, y: 16)

            ForEach(0..<8, id: \.self) { index in
                sidebarRow(index)
                    .offset(x: tahoe ? 12 : 8, y: sidebarRowY(index) - 8)
            }
        }
    }

    private func sidebarRowY(_ index: Int) -> CGFloat { 48 + CGFloat(index) * 20 }

    @ViewBuilder private func sidebarRow(_ index: Int) -> some View {
        let selected = index == selectedSidebarRow && sidebarSelected
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(selected ? Color.white.opacity(0.9) : Color.primary.opacity(0.22))
                .frame(width: 10, height: 10)
            if index == selectedSidebarRow {
                Text("Privacy & Security")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Capsule()
                    .fill(Color.primary.opacity(bar))
                    .frame(width: [44, 36, 52, 40, 0, 30, 46, 38][index], height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(width: tahoe ? sidebarWidth - 20 : sidebarWidth - 16, height: 16)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: tahoe ? 8 : 5, style: .continuous).fill(Color.accentColor)
            }
        }
    }

    // MARK: Content

    private var content: some View {
        let left = sidebarWidth + 14
        let width = Self.size.width - left - 14
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.4))
                Text(kind.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .fixedSize()
            }
            .offset(x: left, y: 12)

            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Color.primary.opacity(bar)).frame(width: width - 20, height: 5)
                Capsule().fill(Color.primary.opacity(bar)).frame(width: width * 0.6, height: 5)
            }
            .offset(x: left, y: 40)

            RoundedRectangle(cornerRadius: tahoe ? 12 : 8, style: .continuous)
                .fill(groupFill)
                .overlay {
                    RoundedRectangle(cornerRadius: tahoe ? 12 : 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(highContrast ? 0.4 : 0.08), lineWidth: 1)
                }
                .frame(width: width, height: rowHeight * 3)
                .offset(x: left, y: listTop)

            ForEach(0..<3, id: \.self) { index in
                listRow(index, width: width)
                    .offset(x: left, y: listTop + CGFloat(index) * rowHeight)
            }

            HStack(spacing: 0) {
                Text("+").frame(width: 16, height: 14)
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 10)
                Text("−").frame(width: 16, height: 14)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 4).fill(groupFill))
            .offset(x: left, y: listTop + rowHeight * 3 + 8)
        }
    }

    @ViewBuilder private func listRow(_ index: Int, width: CGFloat) -> some View {
        let isOurs = index == ourRow
        HStack(spacing: 8) {
            if isOurs, let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 16, height: 16)
            }
            if isOurs {
                Text("OpenReaction")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .fixedSize()
            } else {
                Capsule().fill(Color.primary.opacity(bar)).frame(width: index == 0 ? 60 : 48, height: 5)
            }
            Spacer(minLength: 0)
            MiniSwitch(isOn: isOurs ? switchedOn : index == 0, scale: 0.8)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: rowHeight)
        .overlay {
            if isOurs && rowFound {
                RoundedRectangle(cornerRadius: tahoe ? 9 : 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(2)
            }
        }
    }

    // MARK: Pointer

    private var pointerPosition: CGPoint {
        let left = sidebarWidth + 14
        let width = Self.size.width - left - 14
        let rowY = listTop + CGFloat(ourRow) * rowHeight + rowHeight / 2
        switch phase {
        case .start: return CGPoint(x: Self.size.width * 0.55, y: Self.size.height - 12)
        case .sidebar: return CGPoint(x: 64, y: sidebarRowY(selectedSidebarRow) + 6)
        case .row: return CGPoint(x: left + 70, y: rowY + 6)
        case .switchOn, .hold: return CGPoint(x: left + width - 18, y: rowY + 6)
        }
    }

    // MARK: Colors

    private var highContrast: Bool { contrast == .increased }
    private var bar: Double { highContrast ? 0.3 : 0.14 }
    private var isDark: Bool { colorScheme == .dark }
    private var windowFill: Color { Color(white: isDark ? 0.14 : 0.97) }
    private var sidebarFill: Color { Color(white: isDark ? 0.2 : (tahoe ? 0.92 : 0.9)) }
    private var groupFill: Color { Color(white: isDark ? 0.19 : 1) }
}

/// A small macOS-style switch drawn with shapes.
struct MiniSwitch: View {
    let isOn: Bool
    var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                .padding(1.5)
        }
        .frame(width: 26 * scale, height: 15 * scale)
        .accessibilityHidden(true)
    }
}

/// A slice of the menu bar with the OpenReaction icon and an arrow pointing at it.
struct MenuBarIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudged = false

    var body: some View {
        VStack(spacing: Brand.Space.s4) {
            HStack(spacing: Brand.Space.s16) {
                Spacer(minLength: 0)
                ForEach([18.0, 14.0], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.25)).frame(width: width, height: 12)
                }
                Image(nsImage: AppResources.menuBarImage())
                    .renderingMode(.template)
                    .foregroundStyle(Brand.textPrimary)
                    .padding(4)
                    .background(Brand.accentSubtle, in: RoundedRectangle(cornerRadius: Brand.Radius.small, style: .continuous))
                ForEach([22.0, 42.0], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.25)).frame(width: width, height: 12)
                }
                Text("9:41").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.textSecondary)
            }
            .padding(.horizontal, Brand.Space.s16)
            .frame(height: 30)
            .cardSurface(radius: Brand.Radius.control)

            HStack(spacing: Brand.Space.s16) {
                Spacer(minLength: 0)
                // Keeps the arrow under the icon: two spacer-sized bars to its right.
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.accentText)
                    .offset(y: nudged ? -4 : 0)
                Color.clear.frame(width: 22 + 42 + 30 + Brand.Space.s16 * 3, height: 1)
            }
            .padding(.horizontal, Brand.Space.s16)
        }
        .frame(width: 400)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { nudged = true }
        }
        .accessibilityElement()
        .accessibilityLabel("OpenReaction's icon in the menu bar")
    }
}
