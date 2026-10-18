import SwiftUI

/// In-app quick guide with all gestures and shortcuts.
struct GuideView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let keys: [String]
        let text: String
    }

    private let wheel: [Row] = [
        Row(keys: ["⇧", "trascina"], text: "Ruota dei formati: rilascia il file sul formato voluto"),
        Row(keys: ["⇧", "⌥", "trascina"], text: "Ruota degli strumenti: comprimi, taglia, annota, oscura, metadati…"),
        Row(keys: ["⇧", "⌃", "trascina"], text: "Ruota delle azioni: AirDrop, copia percorso, Terminale, sposta, ZIP"),
        Row(keys: ["Tab"], text: "Passa alla ruota successiva (quando è aperta col mouse)"),
        Row(keys: ["←", "→"], text: "Scegli l'opzione precedente o successiva"),
        Row(keys: ["↩"], text: "Conferma"),
        Row(keys: ["esc"], text: "Chiudi la ruota"),
    ]

    private let editors: [Row] = [
        Row(keys: ["spazio"], text: "Riproduci / pausa"),
        Row(keys: ["←", "→"], text: "Sposta il cursore di un secondo"),
        Row(keys: ["⌫"], text: "Elimina il tratto, il punto o l'annotazione selezionata"),
        Row(keys: ["↩"], text: "Salva copia"),
    ]

    private let general: [Row] = [
        Row(keys: ["⌘", ","], text: "Impostazioni"),
        Row(keys: ["⌘", "Q"], text: "Esci da Clementine"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Text("🍊").font(.system(size: 40))
                    VStack(alignment: .leading) {
                        Text("Guida rapida").font(.title.bold())
                        Text("Puoi premere i tasti anche mentre stai già trascinando i file.")
                            .foregroundColor(.secondary)
                    }
                }
                section("La ruota", wheel)
                section("Finestre di modifica (taglia, bip, dividi, foto)", editors)
                section("Generali", general)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Buono a sapersi").font(.headline)
                    bullet("I risultati vengono salvati accanto all'originale, che non viene mai modificato.")
                    bullet("Con più file trascinati insieme l'operazione vale per tutti; alcune li combinano (unisci, collage, ZIP).")
                    bullet("Se la ruota non compare nel Finder: Impostazioni di Sistema → Privacy e sicurezza → Accessibilità → attiva Clementine.")
                    bullet("Pages, Numbers e Keynote: con le app di Apple installate il risultato è identico all'originale; senza, viene recuperato il testo.")
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 620)
    }

    private func section(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(row.keys, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                    Text(row.text)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

enum GuideWindow {
    private static var window: NSWindow?

    @MainActor
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Guida rapida di Clementine"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: GuideView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
