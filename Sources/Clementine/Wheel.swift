import AppKit

/// Shows the radial menu of formats/tools around the pointer and runs the chosen operation.
final class WheelController {
    static let shared = WheelController()

    private var panel: WheelPanel?
    private var view: WheelView?
    private var files: [URL] = []
    private var mode: WheelMode = .convert
    private var hideWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private(set) var isVisible = false

    static let size: CGFloat = 460

    func show(files: [URL], at point: NSPoint, mode: WheelMode, dragDriven: Bool) {
        guard !files.isEmpty else { return }
        hideWork?.cancel()
        self.files = files
        self.mode = mode
        if panel == nil {
            let p = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.hidesOnDeactivate = false
            let v = WheelView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
            p.contentView = v
            panel = p
            view = v
        }
        reload()

        // Keep the wheel fully on screen.
        var origin = NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - Self.size)
            origin.y = min(max(origin.y, f.minY), f.maxY - Self.size)
        }
        panel?.setFrameOrigin(origin)
        view?.clickMode = !dragDriven
        if dragDriven {
            panel?.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(view)
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
        isVisible = true
    }

    func setMode(_ newMode: WheelMode) {
        guard isVisible, newMode != mode else { return }
        mode = newMode
        reload()
    }

    private func reload() {
        let ops = Catalog.operations(for: files, mode: mode)
        let kinds = Set(files.map(FileKind.of))
        let title = files.count == 1 ? files[0].lastPathComponent : "\(files.count) file"
        let subtitle = kinds.count == 1 ? kinds.first!.label : "Selezione mista"
        view?.configure(operations: ops, mode: mode, title: title, subtitle: subtitle)
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        if let m = WheelMode.from(flags) { setMode(m) }
    }

    /// Called when the mouse is released anywhere. If nothing was dropped on the wheel, close it.
    func dragEnded() {
        guard isVisible, view?.clickMode == false else { return }
        scheduleHide(after: 0.4)
    }

    func scheduleHide(after delay: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        isVisible = false
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    func choose(_ op: Operation, files dropped: [URL]? = nil) {
        let targets = (dropped?.isEmpty == false) ? dropped! : files
        hide()
        // Let the drag session finish before showing any dialog.
        Task { @MainActor in Self.execute(op, on: targets) }
    }

    @MainActor
    static func execute(_ op: Operation, on files: [URL]) {
        guard let values = ParamPrompt.ask(title: op.title, params: op.params) else { return }
        if op.instant {
            Task {
                do { _ = try await op.run(files, values, nil) } catch { _ = await MainActor.run { NSAlert(error: error).runModal() } }
            }
            return
        }
        let title = files.count == 1 ? "\(op.title) · \(files[0].lastPathComponent)" : "\(op.title) · \(files.count) file"
        JobCenter.shared.run(title: title) { job in try await op.run(files, values, job) }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Draws the wheel and handles both drag-and-drop and click/keyboard selection.
final class WheelView: NSView {
    private var operations: [Operation] = []
    private var mode: WheelMode = .convert
    private var title = ""
    private var subtitle = ""
    private var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            needsDisplay = true
            if highlighted != nil { Prefs.tick() }
        }
    }
    var clickMode = false

    private let inner: CGFloat = 92
    private let outer: CGFloat = 214
    private var centerPoint: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func configure(operations: [Operation], mode: WheelMode, title: String, subtitle: String) {
        self.operations = operations
        self.mode = mode
        self.title = title
        self.subtitle = subtitle
        highlighted = nil
        needsDisplay = true
    }

    // MARK: Geometry

    private var step: CGFloat { 360 / CGFloat(max(operations.count, 1)) }

    /// Segment 0 starts at 12 o'clock, going clockwise.
    private func angles(_ i: Int) -> (CGFloat, CGFloat) {
        (90 - CGFloat(i) * step, 90 - CGFloat(i + 1) * step)
    }

    private enum Hit: Equatable { case segment(Int), tab(WheelMode), center, none }

    private func tabRect(_ m: WheelMode) -> NSRect {
        let i = CGFloat(WheelMode.allCases.firstIndex(of: m)!)
        let w: CGFloat = 52, h: CGFloat = 20
        return NSRect(x: centerPoint.x - 1.5 * w - 3 + i * (w + 3), y: centerPoint.y - 44, width: w, height: h)
    }

    private func hit(_ p: NSPoint) -> Hit {
        for m in WheelMode.allCases where tabRect(m).insetBy(dx: -2, dy: -4).contains(p) { return .tab(m) }
        let dx = p.x - centerPoint.x, dy = p.y - centerPoint.y
        let r = hypot(dx, dy)
        if r < inner { return .center }
        if r > outer + 16 || operations.isEmpty { return .none }
        var a = atan2(dy, dx) * 180 / .pi
        if a < 0 { a += 360 }
        var rel = 90 - a
        while rel < 0 { rel += 360 }
        return .segment(min(Int(rel / step), operations.count - 1))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = centerPoint
        let accent = NSColor(calibratedRed: 1, green: 0.54, blue: 0.12, alpha: 1)

        // Ring background with shadow.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: operations.count > 12 ? 14 : 17, weight: .medium)
        for (i, op) in operations.enumerated() {
            let (a0, a1) = angles(i)
            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: outer - 3, startAngle: a0, endAngle: a1, clockwise: true)
            path.appendArc(withCenter: c, radius: inner + 3, startAngle: a1, endAngle: a0, clockwise: false)
            path.close()
            if highlighted == i {
                accent.setFill()
                path.fill()
            }
            // Divider line.
            let rad = a0 * .pi / 180
            let line = NSBezierPath()
            line.move(to: NSPoint(x: c.x + cos(rad) * (inner + 6), y: c.y + sin(rad) * (inner + 6)))
            line.line(to: NSPoint(x: c.x + cos(rad) * (outer - 6), y: c.y + sin(rad) * (outer - 6)))
            NSColor.separatorColor.setStroke()
            line.lineWidth = 1
            if operations.count > 1 { line.stroke() }

            // Icon + label at the middle of the segment.
            let mid = (a0 + a1) / 2 * .pi / 180
            let r = (inner + outer) / 2
            let p = NSPoint(x: c.x + cos(mid) * r, y: c.y + sin(mid) * r)
            let fg: NSColor = highlighted == i ? .white : .labelColor
            if let img = NSImage(systemSymbolName: op.symbol, accessibilityDescription: op.title)?
                .withSymbolConfiguration(symbolConfig) {
                let tinted = tint(img, fg)
                tinted.draw(in: NSRect(x: p.x - tinted.size.width / 2, y: p.y + 2, width: tinted.size.width, height: tinted.size.height))
            }
            let font = NSFont.systemFont(ofSize: operations.count > 12 ? 9.5 : 11, weight: .semibold)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: para]
            let maxW = min(92, 2 * r * sin(step / 2 * .pi / 180) - 6)
            let rect = NSRect(x: p.x - maxW / 2, y: p.y - 28, width: maxW, height: 28)
            (op.title as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }

        if operations.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            ("Nessuna opzione per questo file" as NSString).draw(at: NSPoint(x: c.x - 90, y: c.y + outer - 60), withAttributes: attrs)
        }

        // Center disc.
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: NSRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)).stroke()

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: NSRect(x: c.x - inner + 14, y: c.y + 14, width: (inner - 14) * 2, height: 18),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .paragraphStyle: para,
                                                  .foregroundColor: NSColor.labelColor])
        (subtitle as NSString).draw(in: NSRect(x: c.x - inner + 14, y: c.y - 4, width: (inner - 14) * 2, height: 16),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .paragraphStyle: para,
                                                     .foregroundColor: NSColor.secondaryLabelColor])
        for m in WheelMode.allCases {
            let r = tabRect(m)
            let pill = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            (m == mode ? accent : NSColor.quaternaryLabelColor).setFill()
            pill.fill()
            (m.label as NSString).draw(in: r.offsetBy(dx: 0, dy: -3),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .paragraphStyle: para,
                                                        .foregroundColor: m == mode ? NSColor.white : NSColor.labelColor])
        }
    }

    private func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        let img = image.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: Drag & drop

    private func trackDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        WheelController.shared.modifiersChanged(NSEvent.modifierFlags)
        let p = convert(sender.draggingLocation, from: nil)
        switch hit(p) {
        case .segment(let i): highlighted = i; return .copy
        case .tab(let m): highlighted = nil; WheelController.shared.setMode(m); return .generic
        default: highlighted = nil; return .generic
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { trackDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { trackDrag(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard case .segment(let i) = hit(p), i < operations.count else {
            WheelController.shared.hide()
            return false
        }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        WheelController.shared.choose(operations[i], files: urls)
        return true
    }

    // MARK: Click & keyboard

    override func mouseMoved(with event: NSEvent) {
        guard clickMode else { return }
        if case .segment(let i) = hit(convert(event.locationInWindow, from: nil)) { highlighted = i } else { highlighted = nil }
    }

    override func mouseDown(with event: NSEvent) {
        switch hit(convert(event.locationInWindow, from: nil)) {
        case .segment(let i): WheelController.shared.choose(operations[i])
        case .tab(let m): WheelController.shared.setMode(m)
        case .center: break
        case .none: WheelController.shared.hide()
        }
    }

    override func keyDown(with event: NSEvent) {
        let n = operations.count
        switch event.keyCode {
        case 53: WheelController.shared.hide()                                   // esc
        case 36, 76: if let h = highlighted, h < n { WheelController.shared.choose(operations[h]) }   // return
        case 124, 125: if n > 0 { highlighted = ((highlighted ?? -1) + 1) % n }  // right/down
        case 123, 126: if n > 0 { highlighted = ((highlighted ?? 0) - 1 + n) % n } // left/up
        case 48:                                                                  // tab: next mode
            let all = WheelMode.allCases
            WheelController.shared.setMode(all[(all.firstIndex(of: mode)! + 1) % all.count])
        default: super.keyDown(with: event)
        }
    }
}
