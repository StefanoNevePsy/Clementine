import AppKit

/// Self-updater: checks the latest GitHub release, downloads Clementine.zip, swaps the app bundle and relaunches.
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "StefanoNevePsy/Clementine"
    @Published var status = ""
    @Published var busy = false
    private var timer: Timer?

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
        let page: URL
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var autoCheck: Bool { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
    static var autoInstall: Bool { UserDefaults.standard.bool(forKey: "autoInstallUpdates") }

    /// Checks shortly after launch, then every 6 hours.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if Self.autoCheck { self?.check(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            if Self.autoCheck { self?.check(userInitiated: false) }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        status = "Controllo aggiornamenti…"
        Task {
            do {
                let release = try await fetchLatest()
                await MainActor.run {
                    self.busy = false
                    if Self.isNewer(release.version, than: self.currentVersion) {
                        self.status = "Disponibile la versione \(release.version)"
                        self.offer(release, userInitiated: userInitiated)
                    } else {
                        self.status = "Clementine è aggiornata (\(self.currentVersion))"
                        if userInitiated { Self.alert("Clementine è aggiornata", "Hai già l'ultima versione (\(self.currentVersion)).") }
                    }
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "Controllo non riuscito"
                    if userInitiated { Self.alert("Impossibile controllare gli aggiornamenti", error.localizedDescription) }
                }
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clementine/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ClementineError(code == 404
                ? "Nessuna release pubblica trovata. Se l'archivio GitHub è privato, l'aggiornamento automatico non può vederlo."
                : "GitHub ha risposto con il codice \(code).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == "Clementine.zip" }),
              let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { throw ClementineError("La release più recente non contiene Clementine.zip") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", zipURL: download, page: page)
    }

    /// Numeric comparison of dotted versions ("1.0.10" > "1.0.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @MainActor
    private func offer(_ release: Release, userInitiated: Bool) {
        if Self.autoInstall && !userInitiated {
            // Don't interrupt running conversions.
            guard !JobCenter.shared.jobs.contains(where: { $0.state == .running }) else { return }
            install(release)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "È disponibile Clementine \(release.version)"
        alert.informativeText = "Hai la versione \(currentVersion). Vuoi aggiornare adesso? Clementine si riavvierà da sola."
        alert.addButton(withTitle: "Aggiorna ora")
        alert.addButton(withTitle: "Più tardi")
        alert.addButton(withTitle: "Novità…")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    // MARK: Installing

    @MainActor
    func install(_ release: Release) {
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") {
            Self.alert("Sposta Clementine in Applicazioni",
                       "macOS sta eseguendo Clementine da una posizione temporanea. Trascinala nella cartella Applicazioni e riaprila: poi gli aggiornamenti funzioneranno.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            Self.alert("Impossibile aggiornare", "Non ho i permessi per scrivere in \(appURL.deletingLastPathComponent().path).")
            return
        }
        busy = true
        status = "Scaricamento della versione \(release.version)…"
        Task {
            do {
                let newApp = try await download(release)
                try await MainActor.run { try self.swapAndRelaunch(newApp: newApp, oldApp: appURL) }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "Aggiornamento non riuscito"
                    Self.alert("Aggiornamento non riuscito", error.localizedDescription)
                }
            }
        }
    }

    private func download(_ release: Release) async throws -> URL {
        let (tmpZip, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClementineError("Download non riuscito") }
        let dir = Workspace.tempDir()
        try ArchiveTools.shell("/usr/bin/ditto", ["-x", "-k", tmpZip.path, dir.path])
        let app = dir.appendingPathComponent("Clementine.app")
        // Sanity checks: same bundle identifier and an intact signature.
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw ClementineError("Il pacchetto scaricato non è Clementine")
        }
        try ArchiveTools.shell("/usr/bin/codesign", ["--verify", "--deep", app.path])
        return app
    }

    /// A tiny helper script waits for us to quit, replaces the bundle and reopens it.
    @MainActor
    private func swapAndRelaunch(newApp: URL, oldApp: URL) throws {
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        OLD="\(oldApp.path)"
        BACKUP="$OLD.old"
        rm -rf "$BACKUP"
        mv "$OLD" "$BACKUP" && /usr/bin/ditto "\(newApp.path)" "$OLD" && rm -rf "$BACKUP" || { rm -rf "$OLD"; mv "$BACKUP" "$OLD"; }
        /usr/bin/xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        /usr/bin/open "$OLD"
        rm -rf "\(newApp.deletingLastPathComponent().path)"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        try p.run()
        status = "Riavvio…"
        NSApp.terminate(nil)
    }

    @MainActor
    static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
