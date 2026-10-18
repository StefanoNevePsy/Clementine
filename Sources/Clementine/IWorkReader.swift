import AppKit

/// Native reader for Pages / Keynote / Numbers files, no Apple apps needed.
///
/// iWork documents are ZIP packages whose `Index/*.iwa` files are Snappy-compressed streams of
/// Protobuf "archives". Text lives in TSWP.StorageArchive messages (type 2001, field 3);
/// Numbers cell strings live in TST.TableDataList messages (type 6005).
enum IWorkReader {
    // MARK: Public API

    /// Text paragraphs, body first (Pages), slide by slide (Keynote) or cell strings (Numbers).
    static func text(_ url: URL) throws -> String {
        let (indexDir, cleanup) = try indexFolder(of: url)
        defer { cleanup() }
        // Recursive: Numbers/Keynote tables live in Index/Tables/DataList-*.iwa. Masters and styles are template text.
        let skip = ["MasterSlide", "Template", "Theme", "DocumentStylesheet", "ViewState", "CalculationEngine", "Metadata"]
        let all = (FileManager.default.enumerator(at: indexDir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let files = all
            .filter { url in url.pathExtension == "iwa" && !skip.contains { url.lastPathComponent.hasPrefix($0) } }
            .sorted { order($0) < order($1) }
        guard !files.isEmpty else { throw ClementineError("Questo documento iWork non contiene dati leggibili") }

        let ext = url.pathExtension.lowercased()
        var body: [String] = [], other: [String] = [], cells: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), let stream = try? decompressIWA([UInt8](data)) else { continue }
            for message in archives(in: stream) {
                switch message.type {
                case 2001, 2002, 2003, 2004, 2005:
                    let fields = Protobuf.fields(message.payload)
                    let kind = fields.first { $0.number == 1 }?.varint ?? 0
                    let text = fields.filter { $0.number == 3 }.compactMap { $0.string }.joined()
                    let clean = Self.cleanText(text)
                    guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if kind == 0 { body.append(clean) } else { other.append(clean) }
                case 6005:
                    for entry in Protobuf.fields(message.payload) where entry.number == 3 {
                        guard let bytes = entry.bytes else { continue }
                        if let s = Protobuf.fields(bytes).first(where: { $0.number == 3 })?.string, !s.isEmpty { cells.append(s) }
                    }
                default: continue
                }
            }
        }
        var parts: [String]
        switch ext {
        case "numbers": parts = cells.isEmpty ? body + other : [cells.joined(separator: "\n")] + body + other
        case "key": parts = body + other
        default: parts = body.isEmpty ? other : body + (other.isEmpty ? [] : ["", "— Caselle di testo e note —"] + other)
        }
        let result = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { throw ClementineError("Nessun testo trovato nel documento") }
        return result
    }

    static func attributed(_ url: URL) throws -> NSAttributedString {
        NSAttributedString(string: try text(url), attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    // MARK: Package layout

    /// Modern iWork files are ZIPs containing Index/; older ones are folders with Index.zip or Index/.
    private static func indexFolder(of url: URL) throws -> (URL, () -> Void) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let indexZip = url.appendingPathComponent("Index.zip")
            if FileManager.default.fileExists(atPath: indexZip.path) {
                let dir = try Workspace.unzip(indexZip)
                return (dir.appendingPathComponent("Index"), { try? FileManager.default.removeItem(at: dir) })
            }
            return (url.appendingPathComponent("Index"), {})
        }
        let dir = try Workspace.unzip(url)
        return (dir.appendingPathComponent("Index"), { try? FileManager.default.removeItem(at: dir) })
    }

    /// Document first, then slides/sheets in name order.
    private static func order(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name == "Document.iwa" { return "0" }
        return "1" + name
    }

    private static func cleanText(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x2029, 0x2028, 0x0A, 0x0D: out.append("\n")
            case 0x09: out.append("\t")
            case 0xFFFC, 0x0000...0x0008, 0x000B, 0x000C, 0x000E...0x001F: continue   // attachments & control marks
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: IWA container

    /// An .iwa file is a series of chunks: 0x00, 3-byte little-endian length, raw Snappy data.
    static func decompressIWA(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var pos = 0
        while pos + 4 <= data.count {
            guard data[pos] == 0 else { throw ClementineError("Formato IWA non riconosciuto") }
            let len = Int(data[pos + 1]) | Int(data[pos + 2]) << 8 | Int(data[pos + 3]) << 16
            pos += 4
            guard pos + len <= data.count else { break }
            out += try Snappy.decompress(Array(data[pos..<pos + len]))
            pos += len
        }
        return out
    }

    struct Message { let type: Int; let payload: [UInt8] }

    /// Stream layout: varint length, ArchiveInfo { 1: id, 2: MessageInfo { 1: type, 3: length } }, then payloads.
    static func archives(in stream: [UInt8]) -> [Message] {
        var result: [Message] = []
        var pos = 0
        while pos < stream.count {
            guard let (infoLen, n) = Protobuf.varint(stream, pos) else { break }
            pos += n
            guard infoLen > 0, pos + infoLen <= stream.count else { break }
            let info = Protobuf.fields(Array(stream[pos..<pos + infoLen]))
            pos += infoLen
            for mi in info where mi.number == 2 {
                guard let bytes = mi.bytes else { continue }
                let f = Protobuf.fields(bytes)
                let type = f.first { $0.number == 1 }?.varint ?? 0
                let length = f.first { $0.number == 3 }?.varint ?? 0
                guard length >= 0, pos + length <= stream.count else { return result }
                result.append(Message(type: type, payload: Array(stream[pos..<pos + length])))
                pos += length
            }
        }
        return result
    }
}

// MARK: - Snappy (raw block format)

enum Snappy {
    static func decompress(_ src: [UInt8]) throws -> [UInt8] {
        guard let (expected, n) = Protobuf.varint(src, 0) else { throw ClementineError("Dati Snappy non validi") }
        var out = [UInt8]()
        out.reserveCapacity(expected)
        var pos = n
        func le(_ count: Int) throws -> Int {
            guard pos + count <= src.count else { throw ClementineError("Dati Snappy troncati") }
            var v = 0
            for i in 0..<count { v |= Int(src[pos + i]) << (8 * i) }
            pos += count
            return v
        }
        while pos < src.count {
            let tag = Int(src[pos]); pos += 1
            switch tag & 3 {
            case 0:   // literal
                var len = tag >> 2
                if len >= 60 { len = try le(len - 59) }
                len += 1
                guard pos + len <= src.count else { throw ClementineError("Dati Snappy troncati") }
                out += src[pos..<pos + len]
                pos += len
                continue
            case 1:
                let len = ((tag >> 2) & 7) + 4
                let off = ((tag >> 5) << 8) | (try le(1))
                try copy(&out, off, len)
            case 2:
                try copy(&out, try le(2), (tag >> 2) + 1)
            default:
                try copy(&out, try le(4), (tag >> 2) + 1)
            }
        }
        return out
    }

    private static func copy(_ out: inout [UInt8], _ offset: Int, _ length: Int) throws {
        guard offset > 0, offset <= out.count else { throw ClementineError("Dati Snappy non validi") }
        let start = out.count - offset
        for i in 0..<length { out.append(out[start + i]) }   // may overlap: byte by byte
    }
}

// MARK: - Minimal Protobuf wire-format reader

enum Protobuf {
    struct Field {
        let number: Int
        let varint: Int?
        let bytes: [UInt8]?
        var string: String? { bytes.flatMap { String(bytes: $0, encoding: .utf8) } }
    }

    static func varint(_ b: [UInt8], _ start: Int) -> (Int, Int)? {
        var value = 0, shift = 0, i = start
        while i < b.count, shift < 64 {
            let byte = b[i]
            value |= Int(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (value, i - start) }
            shift += 7
        }
        return nil
    }

    static func fields(_ b: [UInt8]) -> [Field] {
        var result: [Field] = []
        var pos = 0
        while pos < b.count {
            guard let (key, n) = varint(b, pos) else { break }
            pos += n
            let number = key >> 3
            switch key & 7 {
            case 0:
                guard let (v, m) = varint(b, pos) else { return result }
                pos += m
                result.append(Field(number: number, varint: v, bytes: nil))
            case 1: pos += 8
            case 2:
                guard let (len, m) = varint(b, pos) else { return result }
                pos += m
                guard len >= 0, pos + len <= b.count else { return result }
                result.append(Field(number: number, varint: nil, bytes: Array(b[pos..<pos + len])))
                pos += len
            case 5: pos += 4
            default: return result
            }
        }
        return result
    }
}
