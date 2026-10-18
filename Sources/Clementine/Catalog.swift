import AppKit
import CoreImage

/// Which operations the wheel offers for a given set of files and mode.
enum Catalog {
    static func operations(for files: [URL], mode: WheelMode) -> [Operation] {
        guard let first = files.first else { return [] }
        if mode == .actions { return actions() }
        let kinds = Set(files.map(FileKind.of))
        // Mixed selections: only offer things that work on everything.
        if kinds.count > 1 {
            var ops = genericOps()
            if kinds.isSubset(of: [.image, .pdf]) {
                ops.insert(combined("Un solo PDF", "doc.on.doc") { urls, _, _ in try PDFTools.merge(urls) }, at: 0)
            }
            return ops
        }
        let kind = kinds.first!
        let sourceExt = first.pathExtension.lowercased()
        switch (kind, mode) {
        case (.image, .convert): return imageConvert(excluding: sourceExt, many: files.count > 1)
        case (.image, .tools): return imageTools(many: files.count > 1)
        case (.video, .convert): return mediaConvert(["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3", "m4a", "wav"], excluding: sourceExt)
        case (.video, .tools): return videoTools(many: files.count > 1)
        case (.audio, .convert): return mediaConvert(["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"], excluding: sourceExt)
        case (.audio, .tools): return audioTools(many: files.count > 1)
        case (.pdf, .convert): return pdfConvert(many: files.count > 1)
        case (.pdf, .tools): return pdfTools(many: files.count > 1)
        case (.document, _): return mode == .convert ? docConvert(excluding: sourceExt) : docTools()
        case (.subtitle, _): return subtitleOps(excluding: sourceExt)
        case (.archive, _): return archiveOps()
        default: return genericOps()
        }
    }

    // MARK: Helpers

    private static func each(_ title: String, _ symbol: String, params: [Param] = [],
                             _ f: @escaping (URL, ParamValues, Job?) async throws -> URL) -> Operation {
        Operation(title: title, symbol: symbol, params: params) { files, values, job in
            var outs: [URL] = []
            for (i, file) in files.enumerated() {
                if files.count > 1 { job?.report(Double(i) / Double(files.count), "\(i + 1)/\(files.count): \(file.lastPathComponent)") }
                outs.append(try await f(file, values, job))
            }
            return outs
        }
    }

    private static func eachMany(_ title: String, _ symbol: String, params: [Param] = [],
                                 _ f: @escaping (URL, ParamValues, Job?) async throws -> [URL]) -> Operation {
        Operation(title: title, symbol: symbol, params: params) { files, values, job in
            var outs: [URL] = []
            for file in files { outs += try await f(file, values, job) }
            return outs
        }
    }

    private static func combined(_ title: String, _ symbol: String, params: [Param] = [],
                                 _ f: @escaping ([URL], ParamValues, Job?) async throws -> URL) -> Operation {
        Operation(title: title, symbol: symbol, params: params, combinesFiles: true) { files, values, job in
            [try await f(files, values, job)]
        }
    }

    private static func info(_ title: String, _ symbol: String, _ f: @escaping (URL) async throws -> String) -> Operation {
        Operation(title: title, symbol: symbol, instant: true) { files, _, _ in
            var parts: [String] = []
            for file in files { parts.append("— \(file.lastPathComponent) —\n" + (try await f(file))) }
            let text = parts.joined(separator: "\n\n")
            await MainActor.run { ParamPrompt.showText(title: title, text: text) }
            return []
        }
    }

    // MARK: Images

    static func imageConvert(excluding ext: String, many: Bool) -> [Operation] {
        let normalized = ["jpeg": "jpg", "tif": "tiff", "heif": "heic"][ext] ?? ext
        var formats = ["jpg", "png", "heic", "webp", "tiff", "gif", "bmp", "pdf"]
        if FFmpeg.isAvailable { formats.append("avif") } else { formats.removeAll { $0 == "webp" } }
        var ops = formats.filter { $0 != normalized }.map { f in
            each(f.uppercased(), "photo") { url, _, _ in try await ImageTools.convert(url, to: f) }
        }
        if many {
            ops.append(combined("Un solo PDF", "doc.on.doc") { urls, _, _ in try PDFTools.merge(urls) })
        }
        return ops
    }

    static func imageTools(many: Bool) -> [Operation] {
        var ops: [Operation] = [
            each("Comprimi", "arrow.down.right.and.arrow.up.left",
                 params: [Param(key: "kb", label: "Dimensione massima (KB) — lascia vuoto per usare la %", defaultValue: ""),
                          Param(key: "pct", label: "Oppure % della dimensione originale", defaultValue: "50")]) { url, v, _ in
                try ImageTools.compress(url, targetKB: v.double("kb"), percent: v.double("pct"))
            },
            each("Ridimensiona", "arrow.up.left.and.down.right.magnifyingglass",
                 params: [Param(key: "max", label: "Lato lungo massimo (px) — vuoto per usare la %", defaultValue: "1920"),
                          Param(key: "pct", label: "Oppure scala in %", defaultValue: "")]) { url, v, _ in
                try await ImageTools.resize(url, percent: v.double("pct"), maxSide: v.double("max"))
            },
            each("Ruota 90°", "rotate.right") { url, _, _ in
                try await ImageTools.transform(url, suffix: "-ruotata") { $0.oriented(.right) }
            },
            each("Rifletti", "arrow.left.and.right.righttriangle.left.righttriangle.right") { url, _, _ in
                try await ImageTools.transform(url, suffix: "-riflessa") { $0.oriented(.upMirrored) }
            },
            each("Bianco e nero", "circle.lefthalf.filled") { url, _, _ in
                try await ImageTools.transform(url, suffix: "-bn") { $0.applyingFilter("CIPhotoEffectNoir") }
            },
            each("Migliora auto", "wand.and.stars") { url, _, _ in
                try await ImageTools.transform(url, suffix: "-migliorata") { img in
                    img.autoAdjustmentFilters().reduce(img) { (acc: CIImage, f: CIFilter) -> CIImage in
                        f.setValue(acc, forKey: kCIInputImageKey)
                        return f.outputImage ?? acc
                    }
                }
            },
            each("Rimuovi sfondo", "person.crop.rectangle") { url, _, _ in try await ImageTools.removeBackground(url) },
            each("Togli metadati", "eye.slash") { url, _, _ in try await ImageTools.stripMetadata(url) },
            info("Metadati", "info.circle") { ImageTools.metadataText($0) },
            info("Leggi QR", "qrcode.viewfinder") { try ImageTools.readQR($0) },
            info("Testo (OCR)", "text.viewfinder") { try ImageTools.ocr($0) },
        ]
        if many {
            ops.append(combined("Collage", "square.grid.2x2",
                                params: [Param(key: "cols", label: "Colonne", defaultValue: "3")]) { urls, v, _ in
                try await ImageTools.collage(urls, columns: Int(v.double("cols", 3)))
            })
        }
        return ops
    }

    // MARK: Video & audio

    static func mediaConvert(_ formats: [String], excluding ext: String) -> [Operation] {
        let native = ["mp4", "mov", "m4a"]
        return formats.filter { $0 != ext && (FFmpeg.isAvailable || native.contains($0)) }.map { f in
            each(f.uppercased(), ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"].contains(f) ? "waveform" : "film") { url, _, job in
                try await MediaTools.convert(url, to: f, job: job)
            }
        }
    }

    static func videoTools(many: Bool) -> [Operation] {
        guard FFmpeg.isAvailable else {
            return [each("Fotogramma", "camera", params: [Param(key: "t", label: "Istante (secondi o mm:ss)", defaultValue: "0")]) { url, v, _ in
                try await MediaTools.snapshot(url, at: v.seconds("t"))
            }, info("Metadati", "info.circle") { await MediaTools.metadataText($0) }]
        }
        var ops: [Operation] = [
            each("Comprimi", "arrow.down.right.and.arrow.up.left",
                 params: [Param(key: "mb", label: "Dimensione finale (MB) — vuoto per usare la %", defaultValue: ""),
                          Param(key: "pct", label: "Oppure % della dimensione originale", defaultValue: "40")]) { url, v, job in
                try await MediaTools.compress(url, targetMB: v.double("mb"), percent: v.double("pct"), job: job)
            },
            each("Taglia", "scissors",
                 params: [Param(key: "start", label: "Inizio (secondi o mm:ss)", defaultValue: "0"),
                          Param(key: "end", label: "Fine (secondi o mm:ss)", defaultValue: "0:30")]) { url, v, job in
                try await MediaTools.trim(url, start: v.seconds("start"), end: v.seconds("end"), job: job)
            },
            each("Ritaglia", "crop",
                 params: [Param(key: "r", label: "Proporzioni (es. 16:9, 1:1, 9:16)", defaultValue: "9:16")]) { url, v, job in
                try await MediaTools.crop(url, ratio: v["r"] ?? "", job: job)
            },
            each("Velocità", "speedometer",
                 params: [Param(key: "f", label: "Fattore (0.5 = rallenta, 2 = doppia)", defaultValue: "1.5")]) { url, v, job in
                try await MediaTools.speed(url, factor: v.double("f", 1), job: job)
            },
            each("Riduci a 720p", "rectangle.compress.vertical") { url, _, job in try await MediaTools.resize(url, height: 720, job: job) },
            each("Togli audio", "speaker.slash") { url, _, job in try await MediaTools.mute(url, job: job) },
            each("Estrai audio", "waveform") { url, _, job in try await MediaTools.extractAudio(url, job: job) },
            each("Fotogramma", "camera", params: [Param(key: "t", label: "Istante (secondi o mm:ss)", defaultValue: "0")]) { url, v, _ in
                try await MediaTools.snapshot(url, at: v.seconds("t"))
            },
            eachMany("Dividi", "square.split.2x1",
                     params: [Param(key: "s", label: "Durata di ogni parte (secondi o mm:ss)", defaultValue: "60")]) { url, v, job in
                try await MediaTools.split(url, segmentSeconds: v.seconds("s"), job: job)
            },
            each("Togli metadati", "eye.slash") { url, _, job in try await MediaTools.stripMetadata(url, job: job) },
            info("Metadati", "info.circle") { await MediaTools.metadataText($0) },
        ]
        if many { ops.insert(combined("Unisci", "link") { urls, _, job in try await MediaTools.join(urls, job: job) }, at: 0) }
        return ops
    }

    static func audioTools(many: Bool) -> [Operation] {
        guard FFmpeg.isAvailable else { return [info("Metadati", "info.circle") { await MediaTools.metadataText($0) }] }
        var ops: [Operation] = [
            each("Normalizza", "slider.vertical.3") { url, _, job in
                try await MediaTools.audioFilter(url, filter: "loudnorm=I=-16:TP=-1.5:LRA=11", suffix: "-normalizzato", job: job)
            },
            each("Taglia", "scissors",
                 params: [Param(key: "start", label: "Inizio (secondi o mm:ss)", defaultValue: "0"),
                          Param(key: "end", label: "Fine (secondi o mm:ss)", defaultValue: "0:30")]) { url, v, job in
                try await MediaTools.trim(url, start: v.seconds("start"), end: v.seconds("end"), job: job)
            },
            each("Comprimi", "arrow.down.right.and.arrow.up.left",
                 params: [Param(key: "mb", label: "Dimensione finale (MB) — vuoto per usare la %", defaultValue: ""),
                          Param(key: "pct", label: "Oppure % della dimensione originale", defaultValue: "50")]) { url, v, job in
                try await MediaTools.compress(url, targetMB: v.double("mb"), percent: v.double("pct"), job: job)
            },
            each("Bleep", "exclamationmark.bubble",
                 params: [Param(key: "start", label: "Inizio censura (secondi o mm:ss)", defaultValue: "0"),
                          Param(key: "end", label: "Fine censura", defaultValue: "1")]) { url, v, job in
                try await MediaTools.bleep(url, start: v.seconds("start"), end: v.seconds("end"), job: job)
            },
            each("Mono", "speaker.wave.1") { url, _, job in
                try await MediaTools.audioFilter(url, filter: "pan=mono|c0=0.5*c0+0.5*c1", suffix: "-mono", job: job)
            },
            each("Stereo", "speaker.wave.2") { url, _, job in
                try await MediaTools.audioFilter(url, filter: "pan=stereo|c0=c0|c1=c0", suffix: "-stereo", job: job)
            },
            each("Velocità", "speedometer",
                 params: [Param(key: "f", label: "Fattore (0.5 = rallenta, 2 = doppia)", defaultValue: "1.25")]) { url, v, job in
                try await MediaTools.speed(url, factor: v.double("f", 1), job: job)
            },
            each("Riduci rumore", "waveform.badge.minus") { url, _, job in
                try await MediaTools.audioFilter(url, filter: "afftdn=nf=-25", suffix: "-pulito", job: job)
            },
            each("Titolo/Artista", "pencil",
                 params: [Param(key: "title", label: "Titolo", defaultValue: ""),
                          Param(key: "artist", label: "Artista", defaultValue: "")]) { url, v, job in
                try await MediaTools.setTitle(url, title: v["title"] ?? "", artist: v["artist"] ?? "", job: job)
            },
            each("Togli metadati", "eye.slash") { url, _, job in try await MediaTools.stripMetadata(url, job: job) },
            info("Metadati", "info.circle") { await MediaTools.metadataText($0) },
        ]
        if many { ops.insert(combined("Unisci", "link") { urls, _, job in try await MediaTools.join(urls, job: job) }, at: 0) }
        return ops
    }

    // MARK: PDF

    static func pdfConvert(many: Bool) -> [Operation] {
        var ops: [Operation] = [
            eachMany("PNG", "photo") { url, _, _ in try await PDFTools.toImages(url, ext: "png", dpi: 150) },
            eachMany("JPG", "photo") { url, _, _ in try await PDFTools.toImages(url, ext: "jpg", dpi: 150) },
            each("TXT", "doc.plaintext") { url, _, _ in try PDFTools.text(url) },
            each("DOCX", "doc.richtext") { url, _, _ in try await DocTools.convert(url, to: "docx") },
            each("RTF", "doc.richtext") { url, _, _ in try await DocTools.convert(url, to: "rtf") },
        ]
        if many { ops.insert(combined("Unisci", "doc.on.doc") { urls, _, _ in try PDFTools.merge(urls) }, at: 0) }
        return ops
    }

    static func pdfTools(many: Bool) -> [Operation] {
        var ops: [Operation] = [
            each("Comprimi", "arrow.down.right.and.arrow.up.left",
                 params: [Param(key: "dpi", label: "Risoluzione (DPI): 72 piccolo, 110 medio, 150 buono", defaultValue: "110"),
                          Param(key: "q", label: "Qualità JPEG (0-100)", defaultValue: "60")]) { url, v, _ in
                try PDFTools.compress(url, dpi: v.double("dpi", 110), quality: v.double("q", 60) / 100)
            },
            eachMany("Dividi pagine", "square.split.2x1") { url, _, _ in try PDFTools.split(url) },
            each("Estrai/riordina", "list.number",
                 params: [Param(key: "p", label: "Pagine nell'ordine voluto (es. 3,1,2 oppure 1-5, 8)", defaultValue: "1-")]) { url, v, _ in
                try PDFTools.extract(url, pages: v["p"] ?? "")
            },
            each("Ruota 90°", "rotate.right") { url, _, _ in try PDFTools.rotate(url, degrees: 90) },
            each("Proteggi", "lock",
                 params: [Param(key: "pw", label: "Password", defaultValue: "")]) { url, v, _ in
                try PDFTools.protect(url, password: v["pw"] ?? "")
            },
            each("Togli metadati", "eye.slash") { url, _, _ in try PDFTools.stripMetadata(url) },
            info("Metadati", "info.circle") { PDFTools.metadataText($0) },
        ]
        if many { ops.insert(combined("Unisci", "doc.on.doc") { urls, _, _ in try PDFTools.merge(urls) }, at: 0) }
        return ops
    }

    // MARK: Documents, subtitles, archives

    static func docConvert(excluding ext: String) -> [Operation] {
        ["pdf", "docx", "txt", "rtf", "html", "md", "odt"].filter { $0 != ext }.map { f in
            each(f.uppercased(), "doc.text") { url, _, _ in try await DocTools.convert(url, to: f) }
        }
    }

    static func docTools() -> [Operation] {
        [info("Statistiche", "number") { try DocTools.stats($0) },
         combined("Unisci in PDF", "doc.on.doc") { urls, _, _ in
             let merged = NSMutableAttributedString()
             for u in urls {
                 merged.append(try DocTools.read(u))
                 merged.append(NSAttributedString(string: "\n\n"))
             }
             let out = Output.url(for: urls[0], ext: "pdf", suffix: "-unito")
             try await MainActor.run { try DocTools.pdf(from: merged, to: out) }
             return out
         }]
    }

    static func subtitleOps(excluding ext: String) -> [Operation] {
        var ops = ["srt", "vtt"].filter { $0 != ext }.map { f in
            each(f.uppercased(), "captions.bubble") { url, _, _ in try SubtitleTools.convert(url, to: f) }
        }
        ops.append(each("Sposta tempi", "clock.arrow.2.circlepath",
                        params: [Param(key: "s", label: "Secondi (negativi per anticipare)", defaultValue: "1.5")]) { url, v, _ in
            try SubtitleTools.shift(url, seconds: v.double("s"))
        })
        ops.append(each("Solo testo", "doc.plaintext") { url, _, _ in try SubtitleTools.toText(url) })
        return ops
    }

    static func archiveOps() -> [Operation] {
        [each("Estrai", "archivebox") { url, _, _ in try ArchiveTools.extract(url) },
         info("Contenuto", "list.bullet") { try ArchiveTools.list($0) }]
    }

    static func genericOps() -> [Operation] {
        [combined("ZIP", "doc.zipper") { urls, _, _ in try ArchiveTools.zip(urls) },
         combined("TAR.GZ", "archivebox") { urls, _, _ in try ArchiveTools.tarGz(urls) }]
    }

    // MARK: Actions

    static func actions() -> [Operation] {
        func instant(_ title: String, _ symbol: String, _ f: @escaping @MainActor ([URL]) -> Void) -> Operation {
            Operation(title: title, symbol: symbol, instant: true) { files, _, _ in
                await MainActor.run { f(files) }
                return []
            }
        }
        return [
            instant("AirDrop", "airplayaudio") { files in
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: files)
            },
            instant("Copia", "doc.on.clipboard") { files in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(files as [NSURL])
            },
            instant("Copia percorso", "link") { files in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            },
            instant("Sposta in…", "folder") { files in moveOrCopy(files, move: true) },
            instant("Copia in…", "plus.rectangle.on.folder") { files in moveOrCopy(files, move: false) },
            instant("Terminale", "terminal") { files in
                let dir = FileKind.of(files[0]) == .folder ? files[0] : files[0].deletingLastPathComponent()
                NSWorkspace.shared.open([dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            },
            instant("Mostra", "magnifyingglass") { files in NSWorkspace.shared.activateFileViewerSelecting(files) },
            instant("Fluttua", "pin") { files in FloatingShelf.shared.add(files) },
            combined("ZIP", "doc.zipper") { urls, _, _ in try ArchiveTools.zip(urls) },
        ]
    }

    @MainActor
    private static func moveOrCopy(_ files: [URL], move: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = move ? "Sposta qui" : "Copia qui"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var done: [URL] = []
        for f in files {
            let dest = dir.appendingPathComponent(f.lastPathComponent)
            do {
                if move { try FileManager.default.moveItem(at: f, to: dest) } else { try FileManager.default.copyItem(at: f, to: dest) }
                done.append(dest)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
    }
}
