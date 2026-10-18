import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var jobs = JobCenter.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(targeted ? .orange : .secondary.opacity(0.5))
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.orange.opacity(targeted ? 0.12 : 0.04)))
                VStack(spacing: 8) {
                    Text("🍊").font(.system(size: 48))
                    Text("Trascina qui i file").font(.title2.bold())
                    Text("Oppure, ovunque nel Finder: trascina tenendo premuto ⇧ (Maiusc).")
                        .foregroundColor(.secondary)
                    Text("⇧⌥ = strumenti · ⇧⌃ = azioni")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Scegli file…") { AppDelegate.shared?.pickFiles() }
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.center)
                .padding()
            }
            .frame(minHeight: 200)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                loadURLs(providers) { urls in
                    let mods = NSEvent.modifierFlags
                    WheelController.shared.show(files: urls, at: NSEvent.mouseLocation,
                                                mode: WheelMode.from(mods) ?? .convert, dragDriven: false)
                }
                return true
            }

            if !FFmpeg.isAvailable {
                Label("ffmpeg non trovato: i formati video/audio avanzati (MKV, WebM, MP3, FLAC…) non sono disponibili. Installa con: brew install ffmpeg",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }

            if !jobs.jobs.isEmpty {
                JobListView()
            }
        }
        .padding(20)
    }

    private func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { completion(urls) } }
    }
}
