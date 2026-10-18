import SwiftUI
import AppKit

/// A small always-on-top window holding files, so you can drag them out later (e.g. into another app).
final class FloatingShelf: ObservableObject {
    static let shared = FloatingShelf()
    @Published var files: [URL] = []
    private var panel: NSPanel?

    func add(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
        show()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        if files.isEmpty { panel?.orderOut(nil) }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 260),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "File fluttuanti"
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ShelfView())
            if let f = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: f.maxX - 240, y: f.maxY - 300))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

struct ShelfView: View {
    @ObservedObject var shelf = FloatingShelf.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(shelf.files, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 28, height: 28)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.caption)
                        Spacer()
                        Button { shelf.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundColor(.secondary)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                }
                Text("Trascina un file fuori per usarlo").font(.caption2).foregroundColor(.secondary)
            }
            .padding(8)
        }
        .frame(width: 220, height: 260)
    }
}
