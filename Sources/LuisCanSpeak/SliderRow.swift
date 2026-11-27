import AppKit

/// A labeled slider that lives inside a menu, like the volume slider in
/// Control Center. It calls `onChange` while you drag and `onRelease` once
/// you let go.
final class SliderRow: NSObject {
    let item = NSMenuItem()
    private let label: NSTextField
    private let format: (Double) -> String
    private let onChange: (Double) -> Void
    private let onRelease: () -> Void

    init(
        value: Double,
        range: ClosedRange<Double>,
        steps: Int,
        enabled: Bool = true,
        toolTip: String? = nil,
        format: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.format = format
        self.onChange = onChange
        self.onRelease = onRelease

        let width: CGFloat = 260
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 48))

        label = NSTextField(labelWithString: format(value))
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 28, width: width - 40, height: 17)
        view.addSubview(label)

        super.init()

        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(changed(_:)))
        slider.numberOfTickMarks = steps
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 3, width: width - 36, height: 24)
        slider.isEnabled = enabled
        view.addSubview(slider)
        if !enabled { label.textColor = .disabledControlTextColor }
        view.toolTip = toolTip
        label.toolTip = toolTip
        slider.toolTip = toolTip

        item.view = view
    }

    @objc private func changed(_ sender: NSSlider) {
        onChange(sender.doubleValue)
        label.stringValue = format(sender.doubleValue)
        if NSApp.currentEvent?.type == .leftMouseUp { onRelease() }
    }
}
