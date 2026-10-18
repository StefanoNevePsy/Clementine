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
        case (.spreadsheet, _): return mode == .convert ? sheetConvert(excluding: sourceExt) : docTools()
        case (.presentation, _): return presentationOps(excluding: sourceExt)
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

    /// Opens the interactive waveform/timeline editor (one file at a time).
    private static func mediaEditor(_ title: String, _ symbol: String, _ mode: MediaEditMode) -> Operation {
        Operation(title: title, symbol: symbol, instant: true) { files, _, _ in
            await MainActor.run { for f in files.prefix(4) { MediaEditorWindow.show(f, mode: mode) } }
            return []
        }
    }

    /// Opens the photo editor on the selected images.
    private static func editor(_ title: String, _ symbol: String, _ tab: EditorTab) -> Operation {
        Operation(title: title, symbol: symbol, instant: true) { files, _, _ in
            await MainActor.run { ImageEditorWindow.open(files, tab: tab) }
            return []
        }
    }

    /// Opens the editor on a video frame; the drawn crop/rectangles are then applied to the whole video.
    private static func videoEditor(_ title: String, _ symbol: String, _ tab: EditorTab) -> Operation {
        Operation(title: title, symbol: symbol, instant: true) { files, _, _ in
            let url = files[0]
            let duration = FFmpeg.duration(of: url) ?? 0
            let frame = try await MediaTools.frameImage(url, at: min(1, duration / 2))
            await MainActor.run {
                let model = EditorModel(urls: [url], image: frame, tabs: [tab], initial: tab)
                model.onSave = { m in
                    let size = m.fullSize
                    func norm(_ r: CGRect) -> CGRect {
                        CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
                    }
                    if tab == .crop {
                        guard let c = m.crop else { return }
                        JobCenter.shared.run(title: "Ritaglia · \(url.lastPathComponent)") { job in
                            [try await MediaTools.crop(url, rect: norm(c), job: job)]
                        }
                    } else {
                        let rects = m.marks.filter { $0.kind == .solid || $0.kind == .blur }.map { (norm($0.rect), $0.kind == .solid) }
                        guard !rects.isEmpty else { return }
                        guard let v = ParamPrompt.ask(title: "Quando oscurare?", params: [
                            Param(key: "start", label: "Da (secondi o mm:ss) — lascia 0 e 0 per tutto il video", defaultValue: "0"),
                            Param(key: "end", label: "A (secondi o mm:ss)", defaultValue: "0")]) else { return }
                        JobCenter.shared.run(title: "Oscura · \(url.lastPathComponent)") { job in
                            [try await MediaTools.redact(url, rects: rects, start: v.seconds("start"), end: v.seconds("end"), job: job)]
                        }
                    }
                }
                ImageEditorWindow.show(model: model, title: "\(title) · \(url.lastPathComponent)")
            }
            return []
        }
    }

    static func timeList(_ raw: String?) -> [Double] {
        (raw ?? "").split(separator: ",").compactMap { part -> Double? in
            let t = part.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return ["v": t].seconds("v")
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
            editor("Ritaglia", "crop", .crop),
            editor("Regola", "slider.horizontal.3", .adjust),
            editor("Annota", "pencil.tip.crop.circle", .annotate),
            editor("Oscura", "eye.slash.circle", .redact),
            editor("Cornice", "photo.artframe", .frame),
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
            each("Modifica metadati", "tag",
                 params: [Param(key: "title", label: "Titolo", defaultValue: ""),
                          Param(key: "author", label: "Autore", defaultValue: ""),
                          Param(key: "description", label: "Descrizione", defaultValue: ""),
                          Param(key: "copyright", label: "Copyright", defaultValue: ""),
                          Param(key: "keywords", label: "Parole chiave", defaultValue: ""),
                          Param(key: "date", label: "Data (AAAA-MM-GG)", defaultValue: ""),
                          Param(key: "gps", label: "Rimuovere la posizione GPS? (sì/no)", defaultValue: "sì")]) { url, v, _ in
                try ImageTools.editMetadata(url, fields: v, removeGPS: (v["gps"] ?? "").lowercased().hasPrefix("s"))
            },
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
            mediaEditor("Taglia", "scissors", .trim),
            videoEditor("Ritaglia", "crop", .crop),
            videoEditor("Oscura", "eye.slash.circle", .redact),
            mediaEditor("Velocità", "speedometer", .speed),
            mediaEditor("Fotogrammi", "photo.stack", .frames),
            mediaEditor("Dividi", "square.split.2x1", .split),
            mediaEditor("Bleep", "exclamationmark.bubble", .bleep),
            each("Riduci a 720p", "rectangle.compress.vertical") { url, _, job in try await MediaTools.resize(url, height: 720, job: job) },
            each("Togli audio", "speaker.slash") { url, _, job in try await MediaTools.mute(url, job: job) },
            each("Estrai audio", "waveform") { url, _, job in try await MediaTools.extractAudio(url, job: job) },
            each("Togli metadati", "eye.slash") { url, _, job in try await MediaTools.stripMetadata(url, job: job) },
            info("Metadati", "info.circle") { await MediaTools.metadataText($0) },
        ]
        if many { ops.insert(combined("Unisci", "link") { urls, _, job in try await MediaTools.join(urls, job: job) }, at: 0) }
        return ops
    }

    static func audioTools(many: Bool) -> [Operation] {
        guard FFmpeg.isAvailable else { return [info("Metadati", "info.circle") { await MediaTools.metadataText($0) }] }
        var ops: [Operation] = [
            mediaEditor("Taglia", "scissors", .trim),
            mediaEditor("Bleep", "exclamationmark.bubble", .bleep),
            mediaEditor("Velocità", "speedometer", .speed),
            mediaEditor("Dividi", "square.split.2x1", .split),
            each("Normalizza", "slider.vertical.3") { url, _, job in
                try await MediaTools.audioFilter(url, filter: "loudnorm=I=-16:TP=-1.5:LRA=11", suffix: "-normalizzato", job: job)
            },
            each("Comprimi", "arrow.down.right.and.arrow.up.left",
                 params: [Param(key: "mb", label: "Dimensione finale (MB) — vuoto per usare la %", defaultValue: ""),
                          Param(key: "pct", label: "Oppure % della dimensione originale", defaultValue: "50")]) { url, v, job in
                try await MediaTools.compress(url, targetMB: v.double("mb"), percent: v.double("pct"), job: job)
            },
            each("Canali", "speaker.wave.2",
                 params: [Param(key: "layout", label: "Uscita: mono o stereo", defaultValue: "stereo"),
                          Param(key: "l", label: "Volume sinistro (%)", defaultValue: "100"),
                          Param(key: "r", label: "Volume destro (%)", defaultValue: "100")]) { url, v, job in
                try await MediaTools.channels(url, layout: (v["layout"] ?? "").lowercased().hasPrefix("m") ? "mono" : "stereo",
                                              left: v.double("l", 100), right: v.double("r", 100), job: job)
            },
            each("Togli silenzi", "waveform.path.badge.minus",
                 params: [Param(key: "db", label: "Soglia del silenzio (dB, es. -45)", defaultValue: "-45")]) { url, v, job in
                try await MediaTools.trimSilence(url, thresholdDB: v.double("db", -45), job: job)
            },
            each("Visualizza", "waveform.circle",
                 params: [Param(key: "style", label: "Stile: onda, barre o spettro", defaultValue: "onda"),
                          Param(key: "color", label: "Colore (esadecimale)", defaultValue: "#FF8A1F"),
                          Param(key: "format", label: "Formato: orizzontale o verticale", defaultValue: "orizzontale"),
                          Param(key: "bg", label: "Immagine di sfondo (percorso, facoltativo — trascinala qui)", defaultValue: "")]) { url, v, job in
                let bgPath = (v["bg"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                return try await MediaTools.visualizer(url, style: (v["style"] ?? "onda").lowercased(), color: v["color"] ?? "FF8A1F",
                                                       background: bgPath.isEmpty ? nil : URL(fileURLWithPath: bgPath),
                                                       portrait: (v["format"] ?? "").lowercased().hasPrefix("v"), job: job)
            },
            each("Riduci rumore", "waveform.badge.minus") { url, _, job in
                try await MediaTools.audioFilter(url, filter: "afftdn=nf=-25", suffix: "-pulito", job: job)
            },
            each("Modifica tag", "tag",
                 params: [Param(key: "title", label: "Titolo", defaultValue: ""),
                          Param(key: "artist", label: "Artista", defaultValue: ""),
                          Param(key: "album", label: "Album", defaultValue: ""),
                          Param(key: "date", label: "Anno", defaultValue: ""),
                          Param(key: "genre", label: "Genere", defaultValue: ""),
                          Param(key: "comment", label: "Commento", defaultValue: "")]) { url, v, job in
                try await MediaTools.setTags(url, tags: v, job: job)
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
            each("EPUB", "book") { url, _, _ in try await DocTools.convert(url, to: "epub") },
        ]
        if many { ops.insert(combined("Unisci", "doc.on.doc") { urls, _, _ in try PDFTools.merge(urls) }, at: 0) }
        return ops
    }

    static func pdfTools(many: Bool) -> [Operation] {
        var ops: [Operation] = [
            Operation(title: "Organizza", symbol: "square.grid.3x3", instant: true) { files, _, _ in
                await MainActor.run { PDFOrganizerWindow.show(files) }
                return []
            },
            each("Comprimi", "arrow.down.right.and.arrow.up.left") { url, _, _ in try PDFTools.compressQuartz(url) },
            each("Comprimi scansioni", "doc.viewfinder",
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
        if ext == "pages" {
            var ops = ["pdf", "docx", "epub", "txt", "rtf"].map { f in
            each(f.uppercased(), "doc.text") { url, _, _ in try await OfficeTools.convert(url, to: f) }
            }
            ops.append(each("Anteprima", "eye") { url, _, _ in try OfficeTools.iWorkPreview(url) })
            return ops
        }
        var ops = ["pdf", "docx", "epub", "txt", "rtf", "html", "md", "odt"].filter { $0 != ext }.map { f in
            each(f.uppercased(), f == "epub" ? "book" : "doc.text") { url, _, _ in try await DocTools.convert(url, to: f) }
        }
        if OfficeTools.appInstalled("com.apple.iWork.Pages"), ["docx", "doc", "rtf", "txt", "odt"].contains(ext) {
            ops.append(each("PAGES", "doc.richtext") { url, _, _ in try await OfficeTools.convert(url, to: "pages") })
        }
        return ops
    }

    static func sheetConvert(excluding ext: String) -> [Operation] {
        var formats = ["xlsx", "csv", "pdf", "html", "json"]
        if OfficeTools.appInstalled("com.apple.iWork.Numbers") { formats.append("numbers") }
        var ops = formats.filter { $0 != ext && !($0 == "csv" && ext == "tsv") }.map { f in
            each(f.uppercased(), "tablecells") { url, _, _ in try await SheetTools.convert(url, to: f) }
        }
        if ext == "numbers" { ops.append(each("Anteprima", "eye") { url, _, _ in try OfficeTools.iWorkPreview(url) }) }
        return ops
    }

    static func presentationOps(excluding ext: String) -> [Operation] {
        var ops = ["pdf", "pptx", "key"].filter { $0 != ext }.map { f in
            each(f.uppercased(), "play.rectangle") { url, _, _ in try await OfficeTools.convert(url, to: f) }
        }
        if ext == "key" {
            ops.append(each("Video", "film") { url, _, _ in try await OfficeTools.convert(url, to: "m4v") })
            ops.append(each("Anteprima", "eye") { url, _, _ in try OfficeTools.iWorkPreview(url) })
        }
        if ext == "pptx" { ops.append(each("TXT", "doc.plaintext") { url, _, _ in try OfficeTools.pptxText(url) }) }
        if ext == "key" { ops.append(each("TXT", "doc.plaintext") { url, _, _ in try await DocTools.convert(url, to: "txt") }) }
        return ops
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
         combined("Converti in ZIP", "doc.zipper") { urls, _, _ in
             // Re-pack any archive (RAR, 7z, TAR…) as ZIP.
             var outs: [URL] = []
             for u in urls {
                 let folder = try ArchiveTools.extract(u)
                 let zip = try ArchiveTools.zip([folder])
                 try? FileManager.default.removeItem(at: folder)
                 outs.append(zip)
             }
             return outs[0]
         },
         info("Contenuto", "list.bullet") { try ArchiveTools.list($0) }]
    }

    static func genericOps() -> [Operation] {
        [combined("ZIP", "doc.zipper") { urls, _, _ in try ArchiveTools.zip(urls) },
         zipOptions(),
         combined("TAR.GZ", "archivebox") { urls, _, _ in try ArchiveTools.tarGz(urls) }]
    }

    static func zipOptions() -> Operation {
        combined("ZIP con opzioni", "lock.doc",
                 params: [Param(key: "pw", label: "Password (facoltativa)", defaultValue: ""),
                          Param(key: "lvl", label: "Compressione: 0 = nessuna (veloce) … 9 = massima", defaultValue: "6")]) { urls, v, _ in
            try ArchiveTools.zip(urls, level: Int(v.double("lvl", 6)), password: v["pw"] ?? "")
        }
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
            zipOptions(),
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
