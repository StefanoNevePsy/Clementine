import AppKit

/// Watches system-wide file drags: holding ⇧ while dragging a file opens the wheel under the pointer.
final class DragMonitor {
    private var monitors: [Any] = []
    private var changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount

    func start() {
        add(.leftMouseDown) { [weak self] _ in
            self?.changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        }
        add(.leftMouseDragged) { [weak self] event in self?.dragged(event) }
        add(.leftMouseUp) { _ in WheelController.shared.dragEnded() }
        add(.flagsChanged) { event in WheelController.shared.modifiersChanged(event.modifierFlags) }
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
    }

    private func dragged(_ event: NSEvent) {
        let wheel = WheelController.shared
        if wheel.isVisible {
            wheel.modifiersChanged(event.modifierFlags)
            return
        }
        guard let mode = WheelMode.from(event.modifierFlags) else { return }
        // A new drag session bumps the drag pasteboard; ignore stale contents from earlier drags.
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != changeCountAtMouseDown,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        wheel.show(files: urls, at: NSEvent.mouseLocation, mode: mode, dragDriven: true)
    }
}
