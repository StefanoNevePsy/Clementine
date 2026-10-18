import AppKit
import PDFKit
import Quartz

// MARK: - PDF

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ClementineError("Impossibile aprire il PDF \(url.lastPathComponent)") }
        if doc.isLocked { throw ClementineError("Il PDF è protetto da password") }
        return doc
    }

    static func save(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url) else { throw ClementineError("Impossibile salvare il PDF") }
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let result = PDFDocument()
        for url in urls {
            if FileKind.of(url) == .image {
                if let page = PDFPage(image: NSImage(cgImage: try ImageTools.load(url), size: .zero)) {
                    result.insert(page, at: result.pageCount)
                }
                continue
            }
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
        }
        let out = Output.url(for: urls[0], ext: "pdf", suffix: "-unito")
        try save(result, to: out)
        return out
    }

    static func split(_ url: URL) throws -> [URL] {
        let doc = try open(url)
        let folder = Output.folder(for: url, suffix: "-pagine")
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            try save(single, to: folder.appendingPathComponent(String(format: "%@-%03d.pdf", base, i + 1)))
        }
        return [folder]
    }

    /// Pages spec like "1-3, 5, 8-" (1-based). Keeps pages in the given order (so it also reorders).
    static func extract(_ url: URL, pages spec: String) throws -> URL {
        let doc = try open(url)
        let indices = parsePages(spec, count: doc.pageCount)
        guard !indices.isEmpty else { throw ClementineError("Nessuna pagina valida in \"\(spec)\"") }
        let result = PDFDocument()
        for i in indices {
            if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        let out = Output.url(for: url, ext: "pdf", suffix: "-pagine")
        try save(result, to: out)
        return out
    }

    static func parsePages(_ spec: String, count: Int) -> [Int] {
        var result: [Int] = []
        for part in spec.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 1, let n = Int(bounds[0]) {
                if n >= 1 && n <= count { result.append(n - 1) }
            } else if bounds.count == 2 {
                let a = Int(bounds[0]) ?? 1, b = Int(bounds[1]) ?? count
                let lo = max(1, min(a, b)), hi = min(count, max(a, b))
                if lo <= hi {
                    let range = Array(lo...hi).map { $0 - 1 }
                    result += a <= b ? range : range.reversed()
                }
            }
        }
        return result
    }

    static func rotate(_ url: URL, degrees: Int) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + degrees + 360) % 360 }
        }
        let out = Output.url(for: url, ext: "pdf", suffix: "-ruotato")
        try save(doc, to: out)
        return out
    }

    static func toImages(_ url: URL, ext: String, dpi: Double) async throws -> [URL] {
        let doc = try open(url)
        let folder = doc.pageCount > 1 ? Output.folder(for: url, suffix: "-immagini") : url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var single: URL?
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = dpi / 72
            let size = NSSize(width: box.width * scale, height: box.height * scale)
            let thumb = page.thumbnail(of: size, for: .mediaBox)
            var rect = NSRect(origin: .zero, size: thumb.size)
            guard let cg = thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            let dest = doc.pageCount > 1
                ? folder.appendingPathComponent(String(format: "%@-%03d.%@", base, i + 1, ext))
                : Output.url(for: url, ext: ext)
            try await ImageTools.write(cg, to: dest, quality: 0.9)
            single = dest
        }
        return doc.pageCount > 1 ? [folder] : [single].compactMap { $0 }
    }

    static func text(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = Output.url(for: url, ext: "txt")
        try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Re-renders each page as a JPEG at lower resolution: big savings on scanned PDFs.
    /// Lossless-ish compression through macOS's own "Reduce File Size" Quartz filter (keeps text selectable).
    static func compressQuartz(_ url: URL) throws -> URL {
        let doc = try open(url)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else { throw ClementineError("Filtro di compressione di macOS non disponibile") }
        let out = Output.url(for: url, ext: "pdf", suffix: "-compresso")
        let ok = doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        guard ok else { throw ClementineError("Compressione non riuscita") }
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before, before > 0 {
            try? FileManager.default.removeItem(at: out)
            throw ClementineError("Il PDF è già ottimizzato: prova la modalità \"scansioni\" con DPI più bassi")
        }
        return out
    }

    static func compress(_ url: URL, dpi: Double, quality: Double) throws -> URL {
        let doc = try open(url)
        let result = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = dpi / 72
            let thumb = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            var rect = NSRect(origin: .zero, size: thumb.size)
            guard let cg = thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let jpeg = ImageTools.data(cg, ext: "jpg", quality: quality),
                  let img = NSImage(data: jpeg) else { continue }
            img.size = box.size
            if let newPage = PDFPage(image: img) { result.insert(newPage, at: result.pageCount) }
        }
        let out = Output.url(for: url, ext: "pdf", suffix: "-compresso")
        try save(result, to: out)
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let out = Output.url(for: url, ext: "pdf", suffix: "-senza-metadati")
        try save(doc, to: out)
        return out
    }

    static func metadataText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "PDF non leggibile." }
        var lines = ["Pagine: \(doc.pageCount)", "Protetto: \(doc.isEncrypted ? "sì" : "no")"]
        for (k, v) in doc.documentAttributes ?? [:] { lines.append("\(k): \(v)") }
        return lines.joined(separator: "\n")
    }

    static func protect(_ url: URL, password: String) throws -> URL {
        guard !password.isEmpty else { throw ClementineError("Inserisci una password") }
        let doc = try open(url)
        let out = Output.url(for: url, ext: "pdf", suffix: "-protetto")
        let ok = doc.write(to: out, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
        guard ok else { throw ClementineError("Impossibile salvare il PDF") }
        return out
    }
}

// MARK: - Text documents

enum DocTools {
    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "txt" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if ext == "md", let md = try? NSAttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return md
            }
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        if ext == "pdf" {
            return NSAttributedString(string: try PDFTools.open(url).string ?? "")
        }
        if ext == "epub" { return try EpubTools.read(url) }
        if ["pages", "key", "numbers"].contains(ext) { return try IWorkReader.attributed(url) }
        if ["pptx", "xlsx"].contains(ext) {
            throw ClementineError("Usa la conversione dedicata per questo formato")
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let text = try read(url)
        let out = Output.url(for: url, ext: ext)
        let range = NSRange(location: 0, length: text.length)
        switch ext {
        case "txt":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try markdown(from: text).write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try await MainActor.run { try pdf(from: text, to: out) }
        case "epub":
            try EpubTools.write(text, title: url.deletingPathExtension().lastPathComponent, to: out)
        default:
            let type: NSAttributedString.DocumentType
            switch ext {
            case "docx": type = .officeOpenXML
            case "rtf": type = .rtf
            case "html": type = .html
            case "odt": type = .openDocument
            case "doc": type = .docFormat
            default: throw ClementineError("Formato \(ext) non supportato")
            }
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: out)
        }
        return out
    }

    /// Paginates via the print system into a PDF file.
    @MainActor
    static func pdf(from text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)   // A4
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ClementineError("Creazione del PDF non riuscita") }
    }

    /// Simple rich text → Markdown (bold/italic/links).
    static func markdown(from text: NSAttributedString) -> String {
        var md = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            var chunk = (text.string as NSString).substring(with: range)
            if let font = attrs[.font] as? NSFont, !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { chunk = "**\(chunk)**" }
                if traits.contains(.italic) { chunk = "*\(chunk)*" }
            }
            if let link = attrs[.link] { chunk = "[\(chunk)](\(link))" }
            md += chunk
        }
        return md
    }

    static func stats(_ url: URL) throws -> String {
        let s = try read(url).string
        let words = s.split { $0.isWhitespace || $0.isNewline }.count
        let lines = s.components(separatedBy: .newlines).count
        return "Parole: \(words)\nCaratteri: \(s.count)\nRighe: \(lines)\nTempo di lettura: ~\(max(1, words / 200)) min"
    }
}

// MARK: - Subtitles

enum SubtitleTools {
    static func convert(_ url: URL, to ext: String) throws -> URL {
        var text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        if ext == "vtt" {
            text = text.replacingOccurrences(of: #"(\d{2}:\d{2}:\d{2}),(\d{3})"#, with: "$1.$2", options: .regularExpression)
            text = "WEBVTT\n\n" + text
        } else {
            text = text.replacingOccurrences(of: #"^WEBVTT.*\n+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(\d{2}:\d{2}:\d{2})\.(\d{3})"#, with: "$1,$2", options: .regularExpression)
            // Number the cues, as SRT requires.
            let blocks = text.components(separatedBy: "\n\n").filter { $0.contains("-->") }
            text = blocks.enumerated().map { i, b in
                let lines = b.split(separator: "\n", omittingEmptySubsequences: false).drop { !$0.contains("-->") }
                return "\(i + 1)\n" + lines.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        }
        let out = Output.url(for: url, ext: ext)
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Shifts every timestamp by `seconds` (can be negative).
    static func shift(_ url: URL, seconds: Double) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(\d{2}):(\d{2}):(\d{2})([,.])(\d{3})"#)
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            func n(_ i: Int) -> Double { Double(ns.substring(with: m.range(at: i))) ?? 0 }
            var t = max(0, n(1) * 3600 + n(2) * 60 + n(3) + n(5) / 1000 + seconds)
            let h = Int(t / 3600); t -= Double(h * 3600)
            let mnt = Int(t / 60); t -= Double(mnt * 60)
            let s = Int(t), ms = Int(((t - Double(s)) * 1000).rounded())
            result += String(format: "%02d:%02d:%02d%@%03d", h, mnt, s, ns.substring(with: m.range(at: 4)), min(ms, 999))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        let out = Output.url(for: url, ext: url.pathExtension, suffix: "-sincronizzato")
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func toText(_ url: URL) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.contains("-->") && Int(t) == nil && t != "WEBVTT"
        }
        let out = Output.url(for: url, ext: "txt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - Archives

enum ArchiveTools {
    static func shell(_ tool: String, _ args: [String], cwd: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ClementineError("Operazione non riuscita: \(msg.prefix(300))")
        }
    }

    /// ZIP with compression level 0-9 and optional password (classic ZipCrypto, opens everywhere).
    static func zip(_ urls: [URL], level: Int = 6, password: String = "") throws -> URL {
        let name = urls.count == 1 ? urls[0].lastPathComponent : "Archivio"
        let out = Output.url(for: urls[0].deletingLastPathComponent().appendingPathComponent(name), ext: "zip")
        var args = ["-r", "-q", "-y", "-\(min(max(level, 0), 9))"]
        if !password.isEmpty { args += ["-P", password] }
        args += [out.path] + urls.map { $0.lastPathComponent } + ["-x", "*.DS_Store", "-x", "__MACOSX/*"]
        try shell("/usr/bin/zip", args, cwd: urls[0].deletingLastPathComponent())
        return out
    }

    static func tarGz(_ urls: [URL]) throws -> URL {
        let name = urls.count == 1 ? urls[0].lastPathComponent : "Archivio"
        let base = urls[0].deletingLastPathComponent().appendingPathComponent(name)
        let out = Output.url(for: base, ext: "tar.gz")
        try shell("/usr/bin/tar", ["-czf", out.path] + urls.map { $0.lastPathComponent }, cwd: urls[0].deletingLastPathComponent())
        return out
    }

    static func extract(_ url: URL) throws -> URL {
        let folder = Output.folder(for: url.deletingPathExtension(), suffix: "")
        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            try shell("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
        } else if ["tar", "gz", "tgz", "bz2", "xz"].contains(ext) {
            try shell("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
        } else {
            // RAR / 7z: macOS's bsdtar (libarchive) reads many of these.
            do { try shell("/usr/bin/tar", ["-xf", url.path, "-C", folder.path]) } catch {
                throw ClementineError("Formato non supportato da macOS. Per RAR/7z installa: brew install unar")
            }
        }
        return folder
    }

    static func list(_ url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-tf", url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
