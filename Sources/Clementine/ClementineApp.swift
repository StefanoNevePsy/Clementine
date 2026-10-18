import SwiftUI
import AppKit

@main
struct ClementineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Clementine", systemImage: "circle.hexagongrid.fill") {
            MenuContent()
        }
        Window("Clementine", id: "main") {
            MainView()
                .frame(minWidth: 460, minHeight: 360)
        }
        .defaultSize(width: 520, height: 420)
        Settings {
            SettingsView()
        }
    }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Apri Clementine") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Scegli file da convertire…") { AppDelegate.shared?.pickFiles() }
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Impostazioni…") }.keyboardShortcut(",")
        } else {
            Button("Impostazioni…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }.keyboardShortcut(",")
        }
        Divider()
        Text("Trascina un file tenendo ⇧ per aprire la ruota")
        Text("⇧⌥ strumenti · ⇧⌃ azioni")
        Text(FFmpeg.isAvailable ? "ffmpeg: disponibile" : "ffmpeg: non trovato (vedi README)")
        Divider()
        Button("Esci") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    let dragMonitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        dragMonitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files opened via Finder "Open With" or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        WheelController.shared.show(files: urls, at: NSEvent.mouseLocation, mode: .convert, dragDriven: false)
    }

    func pickFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        WheelController.shared.show(files: panel.urls, at: NSEvent.mouseLocation, mode: .convert, dragDriven: false)
    }
}
