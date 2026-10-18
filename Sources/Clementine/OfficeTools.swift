import AppKit

// MARK: - Temporary workspace helpers

enum Workspace {
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func unzip(_ url: URL) throws -> URL {
        let dir = tempDir()
        try ArchiveTools.shell("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
        return dir
    }

    /// Zips the *contents* of `dir` into `out`. When `mimetypeFirst`, stores "mimetype" uncompressed first (EPUB rule).
    static func zipContents(of dir: URL, to out: URL, mimetypeFirst: Bool = false) throws {
        try? FileManager.default.removeItem(at: out)
        if mimetypeFirst {
            try ArchiveTools.shell("/usr/bin/zip", ["-X", "-0", "-q", out.path, "mimetype"], cwd: dir)
            try ArchiveTools.shell("/usr/bin/zip", ["-X", "-r", "-9", "-q", out.path, ".", "-x", "mimetype"], cwd: dir)
        } else {
            try ArchiveTools.shell("/usr/bin/zip", ["-X", "-r", "-q", out.path, "."], cwd: dir)
        }
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - iWork & Microsoft Office through installed apps

enum OfficeTools {
    enum Family { case text, spreadsheet, presentation }

    static func family(of url: URL) -> Family {
        switch url.pathExtension.lowercased() {
        case "numbers", "xlsx", "xls", "ods", "csv", "tsv": return .spreadsheet
        case "key", "pptx", "ppt", "odp": return .presentation
        default: return .text
        }
    }

    static func appInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static let soffice: String? = {
        let candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// AppleScript export format names per iWork app.
    private static func iWorkFormat(_ ext: String, family: Family) -> String? {
        switch (family, ext) {
        case (_, "pdf"): return "PDF"
        case (.text, "docx"): return "Microsoft Word"
        case (.text, "epub"): return "EPUB"
        case (.text, "txt"): return "unformatted text"
        case (.text, "rtf"): return "formatted text"
        case (.text, "pages"): return "Pages"
        case (.spreadsheet, "xlsx"): return "Microsoft Excel"
        case (.spreadsheet, "csv"): return "CSV"
        case (.spreadsheet, "numbers"): return "Numbers"
        case (.presentation, "pptx"): return "Microsoft PowerPoint"
        case (.presentation, "key"): return "Keynote"
        case (.presentation, "m4v"): return "QuickTime movie"
        default: return nil
        }
    }

    private static func iWorkApp(_ family: Family) -> (name: String, id: String) {
        switch family {
        case .text: return ("Pages", "com.apple.iWork.Pages")
        case .spreadsheet: return ("Numbers", "com.apple.iWork.Numbers")
        case .presentation: return ("Keynote", "com.apple.iWork.Keynote")
        }
    }

    static func canConvert(_ url: URL, to ext: String) -> Bool {
        let fam = family(of: url)
        return (appInstalled(iWorkApp(fam).id) && iWorkFormat(ext, family: fam) != nil) || soffice != nil
    }

    /// Converts using Pages/Numbers/Keynote (preferred) or LibreOffice.
    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let fam = family(of: url)
        let app = iWorkApp(fam)
        let out = Output.url(for: url, ext: ext)
        if appInstalled(app.id), let format = iWorkFormat(ext, family: fam) {
            let script = """
            tell application "\(app.name)"
                set theDoc to open (POSIX file "\(escape(url.path))")
                export theDoc to (POSIX file "\(escape(out.path))") as \(format)
                close theDoc saving no
            end tell
            """
            try runAppleScript(script)
            return out
        }
        if let soffice {
            let dir = Workspace.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try ArchiveTools.shell(soffice, ["--headless", "--convert-to", ext, "--outdir", dir.path, url.path])
            guard let produced = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first else {
                throw ClementineError("LibreOffice non ha prodotto alcun file")
            }
            try FileManager.default.moveItem(at: produced, to: out)
            return out
        }
        throw ClementineError("Per convertire questo file serve \(app.name) (gratis sul Mac App Store) oppure LibreOffice.")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func runAppleScript(_ source: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if msg.contains("-1743") {
                throw ClementineError("Consenti a Clementine di controllare l'app in Impostazioni di Sistema → Privacy e sicurezza → Automazione.")
            }
            throw ClementineError("Conversione non riuscita: \(msg.prefix(300))")
        }
    }

    /// Without iWork: the preview image embedded in Pages/Numbers/Keynote packages.
    static func iWorkPreview(_ url: URL) throws -> URL {
        let dir = try Workspace.unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["QuickLook/Preview.pdf", "preview.jpg", "QuickLook/Thumbnail.jpg", "preview-web.jpg"] {
            let src = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                let out = Output.url(for: url, ext: src.pathExtension, suffix: "-anteprima")
                try FileManager.default.copyItem(at: src, to: out)
                return out
            }
        }
        throw ClementineError("Nessuna anteprima trovata nel documento")
    }

    /// Plain text from PowerPoint slides (no app needed).
    static func pptxText(_ url: URL) throws -> URL {
        let dir = try Workspace.unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slidesDir = dir.appendingPathComponent("ppt/slides")
        let files = (try? FileManager.default.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil)) ?? []
        let slides = files.filter { $0.pathExtension == "xml" }.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
        }
        var text = ""
        for (i, s) in slides.enumerated() {
            let xml = (try? String(contentsOf: s, encoding: .utf8)) ?? ""
            let paragraphs = xml.components(separatedBy: "</a:p>").map { p in
                XMLText.values(of: "a:t", in: p).joined()
            }.filter { !$0.isEmpty }
            text += "— Diapositiva \(i + 1) —\n" + paragraphs.joined(separator: "\n") + "\n\n"
        }
        let out = Output.url(for: url, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

/// Tiny regex-based XML text extraction (enough for Office text runs).
enum XMLText {
    static func values(of tag: String, in xml: String) -> [String] {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))(?:\\s[^>]*)?>([^<]*)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { unescape(ns.substring(with: $0.range(at: 1))) }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - EPUB

enum EpubTools {
    /// Reads an EPUB's chapters (in spine order) into one attributed string.
    static func read(_ url: URL) throws -> NSAttributedString {
        let dir = try Workspace.unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = firstMatch(#"full-path="([^"]+)""#, in: container) else { throw ClementineError("EPUB non valido") }
        let opfURL = dir.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        let base = opfURL.deletingLastPathComponent()

        var manifest: [String: String] = [:]
        let itemRe = try NSRegularExpression(pattern: #"<item\s[^>]*>"#)
        let ns = opf as NSString
        for m in itemRe.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            if let id = firstMatch(#"\bid="([^"]+)""#, in: tag), let href = firstMatch(#"href="([^"]+)""#, in: tag) {
                manifest[id] = href.removingPercentEncoding ?? href
            }
        }
        let spine = matches(#"<itemref\s[^>]*idref="([^"]+)""#, in: opf)
        let result = NSMutableAttributedString()
        for id in spine {
            guard let href = manifest[id] else { continue }
            let chapter = base.appendingPathComponent(href)
            guard let data = try? Data(contentsOf: chapter),
                  let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                           .characterEncoding: String.Encoding.utf8.rawValue,
                                                                           .baseURL: chapter.deletingLastPathComponent()],
                                                     documentAttributes: nil) else { continue }
            result.append(attr)
            result.append(NSAttributedString(string: "\n\n"))
        }
        if result.length == 0 { throw ClementineError("Nessun capitolo leggibile nell'EPUB") }
        return result
    }

    /// Writes a simple reflowable EPUB 3, one chapter per heading-sized break (or a single chapter).
    static func write(_ text: NSAttributedString, title: String, to out: URL) throws {
        let dir = Workspace.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try fm.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("EPUB"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        // HTML body from the attributed string, keeping only what's inside <body>.
        let htmlData = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                          .excludedElements: ["XML", "DOCTYPE", "meta", "font", "span"]])
        var html = String(decoding: htmlData, as: UTF8.self)
        if let start = html.range(of: "<body>"), let end = html.range(of: "</body>") {
            html = String(html[start.upperBound..<end.lowerBound])
        }
        html = html.replacingOccurrences(of: "<br>", with: "<br/>").replacingOccurrences(of: "&nbsp;", with: "&#160;")
        let t = Workspace.xmlEscape(title)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(t)</title></head><body>\(html)</body></html>
        """.write(to: dir.appendingPathComponent("EPUB/chapter1.xhtml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Indice</title></head><body><nav epub:type="toc" id="toc"><h1>Indice</h1><ol><li><a href="chapter1.xhtml">\(t)</a></li></ol></nav></body></html>
        """.write(to: dir.appendingPathComponent("EPUB/nav.xhtml"), atomically: true, encoding: .utf8)
        let modified = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(t)</dc:title>
            <dc:language>it</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """.write(to: dir.appendingPathComponent("EPUB/package.opf"), atomically: true, encoding: .utf8)
        try Workspace.zipContents(of: dir, to: out, mimetypeFirst: true)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? { matches(pattern, in: s).first }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

// MARK: - Spreadsheets (CSV ⇄ XLSX, no app needed)

enum SheetTools {
    typealias Table = [[String]]

    static func parseCSV(_ text: String) -> Table {
        let firstLine = text.prefix { $0 != "\n" }
        let delimiter: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";"
            : (firstLine.contains("\t") ? "\t" : ",")
        var rows: Table = [], row: [String] = [], field = ""
        var inQuotes = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if it.first == "\u{FEFF}" { it.removeFirst() }
        var i = 0
        while i < it.count {
            let c = it[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < it.count, it[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func csv(_ table: Table, delimiter: String = ",") -> String {
        table.map { row in
            row.map { f in
                f.contains(delimiter) || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: delimiter)
        }.joined(separator: "\n") + "\n"
    }

    static func readXLSX(_ url: URL) throws -> [(name: String, table: Table)] {
        let dir = try Workspace.unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        var shared: [String] = []
        if let sst = try? String(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml"), encoding: .utf8) {
            shared = sst.components(separatedBy: "</si>").dropLast().map { XMLText.values(of: "t", in: $0).joined() }
        }
        let workbook = (try? String(contentsOf: dir.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)) ?? ""
        let names = XMLText.attribute("name", ofTag: "sheet", in: workbook)
        let sheetsDir = dir.appendingPathComponent("xl/worksheets")
        let files = ((try? FileManager.default.contentsOfDirectory(at: sheetsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "xml" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        return files.enumerated().map { i, f in
            let xml = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            return (i < names.count ? names[i] : "Foglio\(i + 1)", parseSheet(xml, shared: shared))
        }
    }

    private static func parseSheet(_ xml: String, shared: [String]) -> Table {
        var table: Table = []
        let cellRe = try! NSRegularExpression(pattern: #"<c\s([^>]*?)(?:/>|>(.*?)</c>)"#, options: [.dotMatchesLineSeparators])
        for rowXML in xml.components(separatedBy: "</row>") {
            guard rowXML.contains("<c") else { continue }
            var row: [String] = []
            let ns = rowXML as NSString
            for m in cellRe.matches(in: rowXML, range: NSRange(location: 0, length: ns.length)) {
                let attrs = ns.substring(with: m.range(at: 1))
                let inner = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
                let ref = attrValue("r", in: attrs) ?? ""
                let type = attrValue("t", in: attrs) ?? "n"
                var value = XMLText.values(of: "v", in: inner).first ?? ""
                if type == "s", let idx = Int(value), idx < shared.count { value = shared[idx] }
                if type == "inlineStr" { value = XMLText.values(of: "t", in: inner).joined() }
                if type == "b" { value = value == "1" ? "VERO" : "FALSO" }
                let col = columnIndex(ref)
                while row.count < col { row.append("") }
                row.append(value)
            }
            table.append(row)
        }
        return table
    }

    private static func attrValue(_ name: String, in attrs: String) -> String? {
        guard let r = attrs.range(of: "\(name)=\""), let end = attrs[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(attrs[r.upperBound..<end])
    }

    private static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(0, n - 1)
    }

    private static func columnName(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func writeXLSX(_ sheets: [(name: String, table: Table)], to out: URL) throws {
        let dir = Workspace.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for sub in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let sheetOverrides = sheets.indices.map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\(sheetOverrides)</Types>
        """.write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        let sheetTags = sheets.enumerated().map { i, s in
            "<sheet name=\"\(Workspace.xmlEscape(String(s.name.prefix(31))))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetTags)</sheets></workbook>
        """.write(to: dir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        let rels = sheets.indices.map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined()
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """.write(to: dir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        for (i, s) in sheets.enumerated() {
            var rows = ""
            for (r, row) in s.table.enumerated() {
                rows += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = columnName(c) + String(r + 1)
                    let number = value.replacingOccurrences(of: ",", with: ".")
                    if Double(number) != nil, !value.hasPrefix("0") || value == "0" || value.hasPrefix("0.") || value.hasPrefix("0,") {
                        rows += "<c r=\"\(ref)\"><v>\(number)</v></c>"
                    } else {
                        rows += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(Workspace.xmlEscape(value))</t></is></c>"
                    }
                }
                rows += "</row>"
            }
            try """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
            """.write(to: dir.appendingPathComponent("xl/worksheets/sheet\(i + 1).xml"), atomically: true, encoding: .utf8)
        }
        try Workspace.zipContents(of: dir, to: out)
    }

    static func loadTables(_ url: URL) throws -> [(name: String, table: Table)] {
        switch url.pathExtension.lowercased() {
        case "csv", "tsv", "txt":
            return [(url.deletingPathExtension().lastPathComponent, parseCSV(try String(contentsOf: url, encoding: .utf8)))]
        case "xlsx":
            return try readXLSX(url)
        default:
            throw ClementineError("Formato di foglio non supportato senza Numbers")
        }
    }

    static func html(_ sheets: [(name: String, table: Table)]) -> String {
        var h = "<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica;font-size:11px}table{border-collapse:collapse;margin-bottom:24px}td{border:1px solid #bbb;padding:3px 6px}tr:first-child td{font-weight:bold;background:#f2f2f2}</style></head><body>"
        for s in sheets {
            h += "<h3>\(Workspace.xmlEscape(s.name))</h3><table>"
            for row in s.table { h += "<tr>" + row.map { "<td>\(Workspace.xmlEscape($0))</td>" }.joined() + "</tr>" }
            h += "</table>"
        }
        return h + "</body></html>"
    }

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let src = url.pathExtension.lowercased()
        let nativeIn = ["csv", "tsv", "xlsx"].contains(src)
        let nativeOut = ["csv", "xlsx", "html", "pdf", "json"].contains(ext)
        guard nativeIn && nativeOut else { return try await OfficeTools.convert(url, to: ext) }
        let sheets = try loadTables(url)
        switch ext {
        case "csv":
            if sheets.count == 1 {
                let out = Output.url(for: url, ext: "csv")
                try csv(sheets[0].table).write(to: out, atomically: true, encoding: .utf8)
                return out
            }
            let folder = Output.folder(for: url, suffix: "-csv")
            for s in sheets {
                try csv(s.table).write(to: folder.appendingPathComponent(s.name + ".csv"), atomically: true, encoding: .utf8)
            }
            return folder
        case "xlsx":
            let out = Output.url(for: url, ext: "xlsx")
            try writeXLSX(sheets, to: out)
            return out
        case "json":
            let out = Output.url(for: url, ext: "json")
            let objects: [[String: String]] = sheets.flatMap { s -> [[String: String]] in
                guard let header = s.table.first else { return [] }
                return s.table.dropFirst().map { row in
                    Dictionary(uniqueKeysWithValues: header.enumerated().map { i, k in (k.isEmpty ? "col\(i + 1)" : k, i < row.count ? row[i] : "") })
                }
            }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out)
            return out
        case "html":
            let out = Output.url(for: url, ext: "html")
            try html(sheets).write(to: out, atomically: true, encoding: .utf8)
            return out
        default:   // pdf
            let attr = try NSAttributedString(data: Data(html(sheets).utf8),
                                              options: [.documentType: NSAttributedString.DocumentType.html,
                                                        .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil)
            let out = Output.url(for: url, ext: "pdf")
            try await MainActor.run { try DocTools.pdf(from: attr, to: out) }
            return out
        }
    }
}

extension XMLText {
    static func attribute(_ name: String, ofTag tag: String, in xml: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)\\s[^>]*\\b\(name)=\"([^\"]*)\"") else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { unescape(ns.substring(with: $0.range(at: 1))) }
    }
}
