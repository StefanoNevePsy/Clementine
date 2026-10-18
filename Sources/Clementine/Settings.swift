import SwiftUI
import ServiceManagement

/// User preferences (stored in UserDefaults).
enum Prefs {
    static var defaults: UserDefaults { .standard }

    static var imageQuality: Double {
        let v = defaults.double(forKey: "imageQuality")
        return v == 0 ? 0.85 : v
    }

    /// x264 CRF: lower = better quality, bigger files.
    static var videoCRF: Int {
        let v = defaults.integer(forKey: "videoCRF")
        return v == 0 ? 23 : v
    }

    static var feedback: Bool { defaults.object(forKey: "feedback") as? Bool ?? true }

    static func tick() {
        guard feedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        NSSound(named: "Tink")?.play()
    }
}

struct SettingsView: View {
    @AppStorage("imageQuality") private var imageQuality = 0.85
    @AppStorage("videoCRF") private var videoCRF = 23
    @AppStorage("feedback") private var feedback = true
    @AppStorage("autoCheckUpdates") private var autoCheck = true
    @AppStorage("autoInstallUpdates") private var autoInstall = false
    @ObservedObject private var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Conversione") {
                VStack(alignment: .leading) {
                    Text("Qualità immagini (JPEG/HEIC/WebP): \(Int(imageQuality * 100))%")
                    Slider(value: $imageQuality, in: 0.4...1)
                }
                VStack(alignment: .leading) {
                    Text("Qualità video: \(qualityLabel)")
                    Slider(value: Binding(get: { Double(34 - videoCRF) }, set: { videoCRF = 34 - Int($0) }), in: 4...16, step: 1)
                    Text("Più a destra = qualità migliore e file più grandi.").font(.caption).foregroundColor(.secondary)
                }
            }
            Section("Ruota") {
                Toggle("Suono e vibrazione del trackpad quando passi su un'opzione", isOn: $feedback)
                Text("⇧ formati · ⇧⌥ strumenti · ⇧⌃ azioni — premi il tasto anche mentre stai già trascinando.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Avvio") {
                Toggle("Apri Clementine all'accesso", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Aggiornamenti") {
                Toggle("Controlla automaticamente le nuove versioni", isOn: $autoCheck)
                Toggle("Installa senza chiedere (quando non ci sono lavori in corso)", isOn: $autoInstall)
                    .disabled(!autoCheck)
                HStack {
                    Text("Versione \(updater.currentVersion)")
                    if !updater.status.isEmpty { Text("· \(updater.status)").foregroundColor(.secondary) }
                    Spacer()
                    Button("Controlla ora") { updater.check(userInitiated: true) }.disabled(updater.busy)
                }
                Button("Guida rapida e scorciatoie") { GuideWindow.show() }
            }
            Section("Strumenti esterni") {
                LabeledContent("ffmpeg", value: FFmpeg.isAvailable ? "disponibile" : "non trovato — brew install ffmpeg")
                LabeledContent("Pages / Numbers / Keynote", value: iWorkStatus)
                LabeledContent("LibreOffice", value: OfficeTools.soffice != nil ? "disponibile" : "non installato (facoltativo)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
    }

    private var qualityLabel: String {
        switch videoCRF {
        case ...19: return "altissima"
        case 20...22: return "alta"
        case 23...25: return "media"
        default: return "compatta"
        }
    }

    private var iWorkStatus: String {
        let apps = [("Pages", "com.apple.iWork.Pages"), ("Numbers", "com.apple.iWork.Numbers"), ("Keynote", "com.apple.iWork.Keynote")]
        let installed = apps.filter { OfficeTools.appInstalled($0.1) }.map(\.0)
        return installed.isEmpty ? "non installati" : installed.joined(separator: ", ")
    }
}
