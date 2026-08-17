import SwiftUI

/// Compact value chip (type, frequency, Q, gain). `isEnabled` is visual only
/// unless `action` is set, in which case a disabled pill does not receive taps.
struct ValuePill: View {
    let value: String
    var isEnabled: Bool = true
    var isSelected: Bool = false
    var minWidth: CGFloat? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let chip = Text(value)
            .font(MenuChrome.bodyFont)
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: minWidth, minHeight: 22)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            }
            .opacity(isEnabled ? 1 : MenuChrome.permissionLockedOpacity)

        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
        } else {
            chip
        }
    }

    private var fillOpacity: Double {
        if !isEnabled { return 0.05 }
        if isSelected { return 0.18 }
        return 0.10
    }
}
