import SwiftUI
import AppKit

final class Job: ObservableObject, Identifiable {
    enum State { case running, done, failed }
    let id = UUID()
    let title: String
    @Published var progress: Double? = nil   // nil = indeterminate
    @Published var state: State = .running
    @Published var message: String = ""
    @Published var outputs: [URL] = []

    init(title: String) { self.title = title }

    /// Thread-safe progress update (0...1), callable from background work.
    func report(_ value: Double?, _ text: String? = nil) {
        DispatchQueue.main.async {
            self.progress = value.map { min(max($0, 0), 1) }
            if let text { self.message = text }
        }
    }
}

/// Keeps track of running conversions and shows a small floating progress window.
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    @Published var jobs: [Job] = []
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Runs `work` in the background, tracking progress, and reveals the outputs in Finder.
    func run(title: String, work: @escaping (Job) async throws -> [URL]) {
        let job = Job(title: title)
        jobs.insert(job, at: 0)
        if jobs.count > 30 { jobs.removeLast(jobs.count - 30) }
        showPanel()
        Task.detached(priority: .userInitiated) {
            do {
                let outs = try await work(job)
                await MainActor.run {
                    job.outputs = outs
                    job.state = .done
                    job.progress = 1
                    job.message = outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) file creati"
                    if !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs) }
                    self.scheduleHide()
                }
            } catch {
                await MainActor.run {
                    job.state = .failed
                    job.message = error.localizedDescription
                    self.scheduleHide(after: 8)
                }
            }
        }
    }

    private func showPanel() {
        hideWork?.cancel()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
                            backing: .buffered, defer: false)
            p.title = "Clementine"
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: JobListView().padding(10).frame(width: 340, height: 220))
            panel = p
        }
        if let screen = NSScreen.main, let p = panel {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 20, y: f.minY + 20))
        }
        panel?.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: Double = 4) {
        guard !jobs.contains(where: { $0.state == .running }) else { return }
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func clear() { jobs.removeAll { $0.state != .running } }
}

struct JobListView: View {
    @ObservedObject var center = JobCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Lavori").font(.headline)
                Spacer()
                Button("Svuota") { center.clear() }.buttonStyle(.borderless)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(center.jobs) { JobRow(job: $0) }
                }
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                switch job.state {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                }
                Text(job.title).lineLimit(1)
                Spacer()
                if job.state == .done, !job.outputs.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } label: {
                        Image(systemName: "magnifyingglass")
                    }.buttonStyle(.borderless).help("Mostra nel Finder")
                }
            }
            if job.state == .running, let p = job.progress {
                ProgressView(value: p)
            }
            if !job.message.isEmpty {
                Text(job.message).font(.caption).foregroundColor(job.state == .failed ? .red : .secondary)
                    .lineLimit(3)
            }
        }
    }
}
