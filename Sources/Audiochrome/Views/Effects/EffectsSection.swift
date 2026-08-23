import AppKit
import AudiochromeCore
import SwiftUI

/// Collapsible device-effects list. Delete this file with the rest of `Views/Effects`
/// when the experiment is done.
enum EffectsSectionMetrics {
    static let rowSpacing: CGFloat = 2

    static var listedCount: Int { DeviceEffects.listedKinds.count }

    static func expandedBodyHeight() -> CGFloat {
        let count = listedCount
        guard count > 0 else { return 0 }
        return CGFloat(count) * MenuChrome.iconRowHeight
            + CGFloat(max(0, count - 1)) * rowSpacing
    }

    @MainActor
    static func height(progress: CGFloat) -> CGFloat {
        guard EffectsFeature.isEnabled, listedCount > 0 else { return 0 }
        return MenuChrome.otherProfilesSectionVerticalPadding
            + MenuChrome.sectionRowHeight
            + max(0, progress) * expandedBodyHeight()
            + MenuChrome.otherProfilesSectionVerticalPadding
    }
}

struct EffectsSection: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    let identityKey: String
    @Binding var progress: CGFloat

    private var effects: DeviceEffects {
        appState.effects(forIdentity: identityKey)
    }

    private var isDeviceEnabled: Bool {
        appState.config.mapping(forIdentity: identityKey).enabled
    }

    var body: some View {
        if EffectsFeature.isEnabled, !DeviceEffects.listedKinds.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ControlCenterRow(
                    title: "Effects",
                    style: .disclosure,
                    trailing: progress > 0.5 ? .chevronDown : .chevronRight
                ) {
                    let target: CGFloat = progress < 0.5 ? 1 : 0
                    popoverChrome.animatingDisclosure {
                        progress = target
                    }
                }

                VStack(alignment: .leading, spacing: EffectsSectionMetrics.rowSpacing) {
                    ForEach(DeviceEffects.listedKinds) { kind in
                        EffectRow(
                            kind: kind,
                            isOn: effects.isEnabled(kind),
                            isPaused: effects.isEnabled(kind) && !isDeviceEnabled,
                            presetTitle: presetTitle(for: kind)
                        ) {
                            appState.setEffectEnabled(
                                !effects.isEnabled(kind),
                                kind: kind,
                                forIdentity: identityKey
                            )
                        } onEdit: {
                            openEditor(kind)
                        }
                    }
                }
                .frame(height: progress * EffectsSectionMetrics.expandedBodyHeight(), alignment: .top)
                .clipped()
                .opacity(progress)
                .allowsHitTesting(progress > 0.98)
            }
            .padding(.vertical, MenuChrome.otherProfilesSectionVerticalPadding)
        }
    }

    private func openEditor(_ kind: EffectKind) {
        appState.beginEditEffect(kind, forIdentity: identityKey)
        popoverChrome.present(.effectsEditor)
    }

    private func presetTitle(for kind: EffectKind) -> String {
        switch kind {
        case .crossfeed: return effects.crossfeed.selectedPreset.title
        case .subharmonic: return effects.subharmonic.selectedPreset.title
        }
    }
}

private struct EffectRow: View {
    let kind: EffectKind
    let isOn: Bool
    var isPaused: Bool = false
    let presetTitle: String
    let onToggle: () -> Void
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
                .padding(.horizontal, MenuChrome.highlightInset)

            HStack(spacing: 0) {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        EffectMarkView(kind: kind, isOn: isOn, isPaused: isPaused)
                        Text(kind.title)
                            .font(MenuChrome.bodyFont)
                            .fontWeight(.regular)
                            .foregroundStyle(isOn ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .padding(.leading, MenuChrome.contentInset)
                    .padding(.trailing, isOn ? 10 : MenuChrome.contentInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.title)
                .accessibilityValue(isOn ? "On" : "Off")

                if isOn {
                    Button(action: onEdit) {
                        HStack(spacing: 10) {
                            Text(presetTitle)
                                .font(MenuChrome.bodyFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            EditIcon()
                                .frame(width: 22, height: 22)
                        }
                        .padding(.trailing, MenuChrome.contentInset)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(presetTitle)")
                }
            }
        }
        .frame(height: MenuChrome.iconRowHeight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .focusEffectDisabled()
    }
}

/// EQ-profile-style row used by Crossfeed and Subharmonic preset lists.
struct EffectPresetRow: View {
    let kind: EffectKind
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
                    .padding(.horizontal, MenuChrome.highlightInset)

                HStack(spacing: 10) {
                    EffectMarkView(kind: kind, isOn: isSelected)
                    Text(title)
                        .font(MenuChrome.bodyFont)
                        .fontWeight(.regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, MenuChrome.contentInset)
            }
            .frame(height: MenuChrome.iconRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

/// Gray plate when off; white plate + dark ink when on;
/// dark gray plate + light ink when on but the device toggle is off.
struct EffectMarkView: View {
    let kind: EffectKind
    let isOn: Bool
    var isPaused: Bool = false
    var size: CGFloat = MenuChrome.listIconSize

    var body: some View {
        ZStack {
            Circle()
                .fill(plate)
                .padding(0.5)
            glyph
                .foregroundStyle(ink)
                .padding(2.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .crossfeed:
            TransferShape()
                .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        case .subharmonic:
            ArrowWaveLeftDownShape()
                .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }
    }

    private var plate: Color {
        if isOn, isPaused {
            return MenuChrome.pausedMarkPlate
        }
        if isOn {
            return Color.white
        }
        return Color(nsColor: .labelColor).opacity(0.16)
    }

    private var ink: Color {
        if isOn, isPaused {
            return MenuChrome.pausedMarkInk
        }
        return Color(nsColor: .labelColor)
    }
}

/// Tabler `transfer` (24×24).
struct TransferShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(20, 10))
        path.addLine(to: pt(4, 10))
        path.addLine(to: pt(9.5, 4))
        path.move(to: pt(4, 14))
        path.addLine(to: pt(20, 14))
        path.addLine(to: pt(14.5, 20))
        return path
    }
}

/// Tabler `arrow-wave-left-down` (24×24).
struct ArrowWaveLeftDownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(7, 14))
        path.addLine(to: pt(3, 14))
        path.addLine(to: pt(3, 10))
        path.move(to: pt(21, 12))
        path.addCurve(to: pt(17, 14), control1: pt(20.113, 13.284), control2: pt(18.52, 14.033))
        path.addCurve(to: pt(13, 12), control1: pt(15.48, 14.033), control2: pt(13.887, 13.284))
        path.addCurve(to: pt(9, 10), control1: pt(12.113, 10.716), control2: pt(10.52, 9.967))
        path.addCurve(to: pt(5, 12), control1: pt(7.48, 9.967), control2: pt(6, 11))
        path.addLine(to: pt(3, 14))
        return path
    }
}
