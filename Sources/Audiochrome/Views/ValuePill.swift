import AppKit
import SwiftUI

/// Compact value chip. Every pill is a fixed width that fits `20,000`.
/// Number pills become a select-all field on click.
struct ValuePill: View {
    private let display: String
    private var isEnabled: Bool
    private var isSelected: Bool
    private var action: (() -> Void)?
    private var expands: Bool
    private var number: Binding<Double>?
    private var numberRange: ClosedRange<Double>?
    private var format: ((Double) -> String)?

    static let height: CGFloat = 22
    static let standardWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: MenuChrome.bodyFontSize, weight: .regular)
        let text = ("20,000" as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 16
    }()

    init(
        _ value: String,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        expands: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.display = value
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.action = action
        self.expands = expands
        self.number = nil
        self.numberRange = nil
        self.format = nil
    }

    init(
        number: Binding<Double>,
        in range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        isEnabled: Bool = true
    ) {
        self.display = format(number.wrappedValue)
        self.isEnabled = isEnabled
        self.isSelected = false
        self.action = nil
        self.expands = false
        self.number = number
        self.numberRange = range
        self.format = format
    }

    var body: some View {
        let chip = chipContent
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(width: expands ? nil : Self.standardWidth, height: Self.height)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            }

        Group {
            if let action {
                Button(action: action) { chip }
                    .buttonStyle(.plain)
            } else {
                chip
            }
        }
        .frame(maxWidth: expands ? .infinity : nil)
        .fixedSize(horizontal: !expands, vertical: true)
    }

    @ViewBuilder
    private var chipContent: some View {
        if let number, let numberRange, let format {
            PillNumberField(
                value: number,
                range: numberRange,
                format: format,
                isEnabled: isEnabled
            )
            .frame(width: Self.standardWidth, height: Self.height)
        } else {
            Text(display)
                .font(MenuChrome.bodyFont)
                .foregroundStyle(labelColor)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var labelColor: some ShapeStyle {
        if !isEnabled { return AnyShapeStyle(.secondary) }
        if action != nil, !isSelected { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(.primary)
    }

    private var fillOpacity: Double {
        if !isEnabled { return 0.05 }
        if action != nil, !isSelected { return 0.05 }
        return 0.10
    }
}

/// Borderless field that selects all on click so a new number replaces the value.
private struct PillNumberField: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, range: range, format: format)
    }

    func makeNSView(context: Context) -> PillNumberNSTextField {
        let field = PillNumberNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: MenuChrome.bodyFontSize, weight: .regular)
        field.stringValue = format(value)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        context.coordinator.applyTextColor(isEnabled: isEnabled)
        return field
    }

    func updateNSView(_ field: PillNumberNSTextField, context: Context) {
        context.coordinator.value = $value
        context.coordinator.range = range
        context.coordinator.format = format
        context.coordinator.applyTextColor(isEnabled: isEnabled)
        if field.currentEditor() == nil, field.stringValue != format(value) {
            field.stringValue = format(value)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PillNumberNSTextField, context: Context) -> CGSize? {
        CGSize(width: ValuePill.standardWidth, height: ValuePill.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<Double>
        var range: ClosedRange<Double>
        var format: (Double) -> String
        weak var field: PillNumberNSTextField?

        init(value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) {
            self.value = value
            self.range = range
            self.format = format
        }

        func applyTextColor(isEnabled: Bool) {
            field?.textColor = isEnabled ? .labelColor : .secondaryLabelColor
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            commit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commit()
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                field?.stringValue = format(value.wrappedValue)
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        private func commit() {
            guard let field else { return }
            if let parsed = Self.parseNumber(field.stringValue) {
                let next = min(range.upperBound, max(range.lowerBound, parsed))
                value.wrappedValue = next
                field.stringValue = format(next)
            } else {
                field.stringValue = format(value.wrappedValue)
            }
        }

        static func parseNumber(_ raw: String) -> Double? {
            let cleaned = raw
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00a0}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(cleaned)
        }
    }
}

private final class PillNumberNSTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VerticallyCenteredTextFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let cell = VerticallyCenteredTextFieldCell(textCell: "")
        cell.isBordered = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.isEditable = true
        cell.isSelectable = true
        cell.alignment = .center
        cell.usesSingleLineMode = true
        cell.wraps = false
        cell.isScrollable = true
        cell.lineBreakMode = .byTruncatingTail
        cell.focusRingType = .none
        self.cell = cell
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ValuePill.standardWidth, height: ValuePill.height)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { selectAllText() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        selectAllText()
    }

    private func selectAllText() {
        guard let editor = currentEditor() else { return }
        editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
    }
}

/// NSTextField draws a hair high in a short capsule; center the title and field editor.
final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let textHeight = attributedStringValue.size().height
        return NSRect(
            x: rect.minX,
            y: rect.minY + (rect.height - textHeight) / 2,
            width: rect.width,
            height: textHeight
        )
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        titleRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: titleRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}
