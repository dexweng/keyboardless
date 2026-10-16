import AppKit

@MainActor enum Brand {
    static let ink = NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.052, alpha: 1)
    static let surface = NSColor(calibratedRed: 0.095, green: 0.095, blue: 0.090, alpha: 1)
    static let card = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.123, alpha: 1)
    static let paper = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.90, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.68, green: 0.68, blue: 0.64, alpha: 1)
    static let line = NSColor(calibratedWhite: 0.32, alpha: 1)
    static var logo: NSImage? { Bundle.main.url(forResource: "keyboardless-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
}

@MainActor final class ContourSidebar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Brand.paper.withAlphaComponent(0.08).setStroke()
        for index in 0..<9 {
            let inset = CGFloat(index) * 9
            let path = NSBezierPath()
            path.move(to: NSPoint(x: -35 + inset, y: 75))
            path.curve(to: NSPoint(x: 230, y: 170 + inset), controlPoint1: NSPoint(x: 80 + inset, y: 85), controlPoint2: NSPoint(x: 30 + inset, y: 240))
            path.lineWidth = 0.7; path.stroke()
        }
    }
}

@MainActor final class ActionButton: NSButton {
    var actionBlock: (() -> Void)?
    var navigationStyle = false
    var primaryStyle = false
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(40, (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width + 30 + (image == nil ? 0 : 24)), height: 36)
    }
    override func draw(_ dirtyRect: NSRect) {
        let selected = navigationStyle && state == .on
        let fill = primaryStyle || selected ? Brand.paper : (navigationStyle && !isHighlighted ? .clear : isHighlighted ? Brand.line : Brand.surface)
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        if !navigationStyle && !primaryStyle {
            Brand.line.setStroke(); let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            outline.lineWidth = 0.7; outline.stroke()
        }
        let color: NSColor = !isEnabled ? Brand.muted.withAlphaComponent(0.5) : primaryStyle || selected ? Brand.ink : Brand.paper
        let textFont = font ?? .systemFont(ofSize: 13, weight: .medium)
        let textSize = (title as NSString).size(withAttributes: [.font: textFont])
        var x: CGFloat = alignment == .left ? 14 : (bounds.width - textSize.width - (image == nil ? 0 : 26)) / 2
        if let icon = image {
            let copy = icon.copy() as! NSImage
            copy.isTemplate = false
            copy.lockFocus(); color.setFill(); NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop); copy.unlockFocus()
            let rect = NSRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18)
            copy.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 0.85 : 0.35)
            x += 26
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - textSize.height) / 2, width: max(0, bounds.width - x - 12), height: textSize.height), withAttributes: [.font: textFont, .foregroundColor: color, .paragraphStyle: paragraph])
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10); ring.lineWidth = 2; ring.stroke()
        }
    }
    init(_ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero); self.title = title; actionBlock = action
        target = self; self.action = #selector(invoke); bezelStyle = .rounded; font = .systemFont(ofSize: 13, weight: .medium)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?() }
}

@MainActor final class Waveform: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        Brand.paper.setFill()
        let count = 17, spacing: CGFloat = 5
        let start = (bounds.width - CGFloat(count) * spacing) / 2
        for index in 0..<count {
            let envelope = 0.25 + 0.75 * abs(sin(Double(index) * 1.7))
            let height = CGFloat(4 + min(1, max(0, level)) * 24 * envelope)
            NSBezierPath(roundedRect: NSRect(x: start + CGFloat(index) * spacing, y: (bounds.height - height) / 2,
                                            width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

@MainActor final class StatusPanel: NSPanel {
    let heading = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    private let time = NSTextField(labelWithString: "00:00")
    private let recordingHint = NSTextField(labelWithString: "")
    private let waveform = Waveform()
    private let actions = NSStackView()
    private let compact = NSStackView()
    private let expanded = NSStackView()
    private var dismissal: DispatchWorkItem?
    private var revision = Revision()
    private var anchor: NSRect?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        let root = NSView(); root.wantsLayer = true
        root.layer?.backgroundColor = Brand.ink.withAlphaComponent(0.97).cgColor
        root.layer?.cornerRadius = 24; root.layer?.borderWidth = 1
        root.layer?.borderColor = Brand.line.cgColor; contentView = root
        heading.font = .systemFont(ofSize: 14, weight: .medium); heading.textColor = Brand.paper
        detail.font = .systemFont(ofSize: 12); detail.textColor = Brand.muted
        time.textColor = Brand.paper
        recordingHint.textColor = Brand.muted
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        compact.orientation = .horizontal; compact.alignment = .centerY; compact.spacing = 10
        expanded.orientation = .vertical; expanded.alignment = .leading; expanded.spacing = 10
        actions.orientation = .horizontal; actions.spacing = 8
        for stack in [compact, expanded] {
            stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
                stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
            ])
        }
        waveform.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([waveform.widthAnchor.constraint(equalToConstant: 104), waveform.heightAnchor.constraint(equalToConstant: 30)])
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    func present(_ title: String, detail text: String, recording: Bool = false,
                 buttons: [(String, () -> Void)] = [], compactOnly: Bool = false, recordingHint hint: String? = nil) {
        dismissal?.cancel(); dismissal = nil; _ = revision.next()
        let small = recording || compactOnly || buttons.isEmpty && text.isEmpty
        clear(compact); clear(expanded); clear(actions)
        compact.isHidden = !small; expanded.isHidden = small
        heading.stringValue = title; detail.stringValue = text
        if recording {
            let cancel = ActionButton("取消錄音", action: buttons.first?.1 ?? {})
            cancel.title = "×"; cancel.bezelStyle = .circular; cancel.toolTip = "取消錄音 · Esc"
            compact.addArrangedSubview(cancel); compact.addArrangedSubview(waveform); compact.addArrangedSubview(time)
            if let hint {recordingHint.stringValue=hint;recordingHint.font = .systemFont(ofSize:12);compact.addArrangedSubview(recordingHint)}
            compact.setAccessibilityLabel(text)
            updateRecording(seconds: 0, level: 0)
        } else if small {
            compact.addArrangedSubview(heading)
        } else {
            expanded.addArrangedSubview(heading); expanded.addArrangedSubview(detail)
            for (label, block) in buttons { actions.addArrangedSubview(ActionButton(label, action: block)) }
            expanded.addArrangedSubview(actions)
        }
        if recording || !isVisible {
            anchor = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
        }
        let size = NSSize(width: small ? (recording && hint != nil ? 340 : 240) : 420, height: small ? 48 : 160)
        let screen = anchor ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 30, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
    func updateRecording(seconds: Double, level: Double) {
        time.stringValue = String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        waveform.level = level
        waveform.setAccessibilityLabel("錄音音量")
        time.setAccessibilityLabel("錄音時間 \(Int(seconds)) 秒")
    }
    func processing(_ title: String) { present(title, detail: "", compactOnly: true) }
    func finish() {
        present("✓  已送出貼上", detail: "", compactOnly: true)
        let current = revision.value
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision.accepts(current) else { return }
            self.orderOut(nil)
        }
        dismissal = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
    override func orderOut(_ sender: Any?) {
        dismissal?.cancel(); dismissal = nil; _ = revision.next(); super.orderOut(sender)
    }
}

@MainActor final class PopupHandler: NSObject {
    let callback: (Int) -> Void
    init(callback: @escaping (Int) -> Void) { self.callback = callback }
    @objc func changed(_ sender: NSPopUpButton) { callback(sender.indexOfSelectedItem) }
}
