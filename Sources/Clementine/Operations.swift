import AppKit
import UniformTypeIdentifiers

// MARK: - File kinds

enum FileKind: String {
    case image, video, audio, pdf, document, subtitle, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Packages like .pages are directories but documents.
            if !["pages", "numbers", "key"].contains(url.pathExtension.lowercased()) { return .folder }
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt", "vtt": return .subtitle
        case "pdf": return .pdf
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz": return .archive
        case "svg", "webp", "avif", "heic", "heif": return .image
        case "mkv", "webm", "avi", "wmv", "flv", "m4v", "mov", "mp4", "mpg", "mpeg", "3gp", "ts": return .video
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aif", "aiff", "wma", "aac", "caf": return .audio
        case "txt", "md", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "pages", "epub", "xml", "webarchive": return .document
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .document }
        return .other
    }

    var label: String {
        switch self {
        case .image: return "Immagine"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Documento"
        case .subtitle: return "Sottotitoli"
        case .archive: return "Archivio"
        case .folder: return "Cartella"
        case .other: return "File"
        }
    }
}

// MARK: - Operations

enum WheelMode: String, CaseIterable {
    case convert, tools, actions

    var label: String {
        switch self {
        case .convert: return "Converti"
        case .tools: return "Strumenti"
        case .actions: return "Azioni"
        }
    }

    /// Shift = convert, Shift+Option = tools, Shift+Control = actions.
    static func from(_ flags: NSEvent.ModifierFlags) -> WheelMode? {
        if flags.contains(.control) { return .actions }
        if flags.contains(.option) { return .tools }
        if flags.contains(.shift) { return .convert }
        return nil
    }
}

struct Param {
    let key: String
    let label: String
    let defaultValue: String
}

typealias ParamValues = [String: String]

extension Dictionary where Key == String, Value == String {
    func double(_ key: String, _ fallback: Double = 0) -> Double {
        guard let raw = self[key]?.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces) else { return fallback }
        return Double(raw) ?? fallback
    }
    /// Accepts seconds ("75", "75.5") or timestamps ("1:15", "00:01:15.5").
    func seconds(_ key: String, _ fallback: Double = 0) -> Double {
        guard let raw = self[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return fallback }
        let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

struct Operation {
    let title: String
    let symbol: String           // SF Symbol name
    var params: [Param] = []
    /// When true the op receives all files at once (merge, zip…), otherwise it runs once per file.
    var combinesFiles = false
    /// Instant actions don't create a progress job.
    var instant = false
    let run: (_ files: [URL], _ values: ParamValues, _ job: Job?) async throws -> [URL]
}

struct ClementineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Output naming

enum Output {
    /// A non-existing URL next to `source`, e.g. "photo.jpg" -> "photo.png" or "photo (2).png".
    static func url(for source: URL, ext: String, suffix: String = "") -> URL {
        let dir = writableDirectory(near: source)
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    static func folder(for source: URL, suffix: String) -> URL {
        let dir = writableDirectory(near: source)
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// Saves next to the original; falls back to Downloads if that folder is read-only.
    private static func writableDirectory(near source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? dir
    }
}

// MARK: - Parameter prompt

enum ParamPrompt {
    /// Shows a small dialog asking for parameters; returns nil if cancelled.
    @MainActor
    static func ask(title: String, params: [Param]) -> ParamValues? {
        if params.isEmpty { return [:] }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Avvia")
        alert.addButton(withTitle: "Annulla")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var fields: [(String, NSTextField)] = []
        for p in params {
            let label = NSTextField(labelWithString: p.label)
            let field = NSTextField(string: p.defaultValue)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(field)
            fields.append((p.key, field))
        }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(params.count) * 50)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = fields.first?.1

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var values: ParamValues = [:]
        for (key, field) in fields { values[key] = field.stringValue }
        return values
    }

    @MainActor
    static func showText(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Chiudi")
        alert.addButton(withTitle: "Copia")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
