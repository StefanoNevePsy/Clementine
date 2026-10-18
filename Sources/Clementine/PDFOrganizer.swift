import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Visual page organizer: reorder by dragging, rotate, delete, insert pages from other PDFs.
final class PDFOrganizerModel: ObservableObject {
    struct Page: Identifiable {
        let id = UUID()
        let page: PDFPage
        var rotation: Int
        var thumbnail: NSImage
    }

    let source: URL
    @Published var pages: [Page] = []
    @Published var selection: Set<UUID> = []

    init(urls: [URL]) throws {
        source = urls[0]
        for url in urls { try append(url) }
    }

    func append(_ url: URL) throws {
        let doc = try PDFTools.open(url)
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i)?.copy() as? PDFPage else { continue }
            pages.append(Page(page: p, rotation: p.rotation, thumbnail: p.thumbnail(of: NSSize(width: 220, height: 220), for: .cropBox)))
        }
    }

    func rotate(_ ids: Set<UUID>, by degrees: Int) {
        for i in pages.indices where ids.contains(pages[i].id) {
            pages[i].rotation = (pages[i].rotation + degrees + 360) % 360
            pages[i].page.rotation = pages[i].rotation
            pages[i].thumbnail = pages[i].page.thumbnail(of: NSSize(width: 220, height: 220), for: .cropBox)
        }
    }

    func delete(_ ids: Set<UUID>) {
        pages.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func move(_ id: UUID, before target: UUID) {
        guard let from = pages.firstIndex(where: { $0.id == id }), let to = pages.firstIndex(where: { $0.id == target }), from != to else { return }
        let item = pages.remove(at: from)
        pages.insert(item, at: to)
    }

    func reverse() { pages.reverse() }

    func save() throws -> URL {
        let doc = PDFDocument()
        for (i, p) in pages.enumerated() { doc.insert(p.page, at: i) }
        let out = Output.url(for: source, ext: "pdf", suffix: "-organizzato")
        try PDFTools.save(doc, to: out)
        return out
    }

    /// Exports only the selected pages, in their current order.
    func extractSelection() throws -> URL {
        let doc = PDFDocument()
        for p in pages where selection.contains(p.id) { doc.insert(p.page, at: doc.pageCount) }
        let out = Output.url(for: source, ext: "pdf", suffix: "-selezione")
        try PDFTools.save(doc, to: out)
        return out
    }
}

final class PDFOrganizerWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PDFOrganizerWindow] = []

    @MainActor
    static func show(_ urls: [URL]) {
        do {
            let model = try PDFOrganizerModel(urls: urls)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Organizza · \(urls[0].lastPathComponent)"
            window.isReleasedWhenClosed = false
            window.center()
            let controller = PDFOrganizerWindow(window: window)
            window.delegate = controller
            window.contentView = NSHostingView(rootView: PDFOrganizerView(model: model) { [weak controller] in controller?.close() })
            open.append(controller)
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}

struct PDFOrganizerView: View {
    @ObservedObject var model: PDFOrganizerModel
    let close: () -> Void
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.rotate(model.selection, by: -90) } label: { Label("Ruota a sinistra", systemImage: "rotate.left") }
                    .disabled(model.selection.isEmpty)
                Button { model.rotate(model.selection, by: 90) } label: { Label("Ruota a destra", systemImage: "rotate.right") }
                    .disabled(model.selection.isEmpty)
                Button(role: .destructive) { model.delete(model.selection) } label: { Label("Elimina", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
                Button { model.reverse() } label: { Label("Inverti ordine", systemImage: "arrow.up.arrow.down") }
                Button { addPDF() } label: { Label("Aggiungi PDF…", systemImage: "plus") }
                Spacer()
                Text("\(model.pages.count) pagine").foregroundColor(.secondary)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 4) {
                            Image(nsImage: page.thumbnail)
                                .resizable().scaledToFit()
                                .frame(height: 170)
                                .shadow(radius: 2)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(model.selection.contains(page.id) ? Color.orange : Color.clear, lineWidth: 3))
                            Text("\(index + 1)").font(.caption)
                        }
                        .padding(4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                if model.selection.contains(page.id) { model.selection.remove(page.id) } else { model.selection.insert(page.id) }
                            } else {
                                model.selection = [page.id]
                            }
                        }
                        .onDrag {
                            dragging = page.id
                            return NSItemProvider(object: page.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: PageDropDelegate(target: page.id, model: model, dragging: $dragging))
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("Trascina le pagine per riordinarle. ⌘-clic per selezionarne più di una.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Chiudi") { close() }
                Button("Esporta selezione") { run { try model.extractSelection() } }
                    .disabled(model.selection.isEmpty)
                Button("Salva PDF") { run { try model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pages.isEmpty)
            }
            .padding(10)
        }
    }

    private func run(_ f: @escaping () throws -> URL) {
        do {
            let out = try f()
            NSWorkspace.shared.activateFileViewerSelecting([out])
            close()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func addPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { try model.append(url) } catch { NSAlert(error: error).runModal() }
        }
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: UUID
    let model: PDFOrganizerModel
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation { model.move(d, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
