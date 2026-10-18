import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImageTools {
    // MARK: Loading

    static func load(_ url: URL) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) {
            return orientedUp(img, orientation: orientation(of: src))
        }
        // SVG and other formats NSImage understands.
        if let ns = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: ns.size)
            if ns.size.width < 1024, ns.size.width > 0 {   // rasterize vectors at a useful size
                let scale = 2048 / ns.size.width
                rect.size = NSSize(width: ns.size.width * scale, height: ns.size.height * scale)
            }
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return cg }
        }
        throw ClementineError("Impossibile leggere l'immagine \(url.lastPathComponent)")
    }

    private static func orientation(of src: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return props?[kCGImagePropertyOrientation] as? Int ?? 1
    }

    /// Applies EXIF orientation so re-encoded files look right without metadata.
    private static func orientedUp(_ img: CGImage, orientation: Int) -> CGImage {
        guard orientation != 1, let o = CGImagePropertyOrientation(rawValue: UInt32(orientation)) else { return img }
        let ci = CIImage(cgImage: img).oriented(o)
        return render(ci) ?? img
    }

    static let ciContext = CIContext()

    static func render(_ ci: CIImage) -> CGImage? {
        ciContext.createCGImage(ci, from: ci.extent.integral)
    }

    // MARK: Writing

    /// Formats ImageIO can write natively.
    static let nativeTypes: [String: UTType] = [
        "jpg": .jpeg, "png": .png, "heic": .heic, "tiff": .tiff, "bmp": .bmp, "gif": .gif,
    ]

    static func data(_ img: CGImage, ext: String, quality: Double = Prefs.imageQuality) -> Data? {
        guard let type = nativeTypes[ext] else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if ext == "jpg" || ext == "bmp" { opts[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1) }
        CGImageDestinationAddImage(dest, ext == "jpg" ? flattened(img) : img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// JPEG has no alpha: draw on white.
    private static func flattened(_ img: CGImage) -> CGImage {
        guard img.alphaInfo != .none, img.alphaInfo != .noneSkipLast, img.alphaInfo != .noneSkipFirst else { return img }
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx else { return img }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func write(_ img: CGImage, to url: URL, quality: Double = Prefs.imageQuality) async throws {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            try pdf(from: [img], to: url)
            return
        }
        if let d = data(img, ext: ext, quality: quality) {
            try d.write(to: url)
            return
        }
        // WebP / AVIF / ICO: go through a temporary PNG and ffmpeg.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let png = data(img, ext: "png") else { throw ClementineError("Codifica fallita") }
        try png.write(to: tmp)
        let q = Int(quality * 100)
        var args = ["-i", tmp.path]
        switch ext {
        case "webp": args += ["-c:v", "libwebp", "-quality", "\(q)"]
        case "avif": args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(max(10, 63 - q / 2))"]
        case "ico": args += ["-vf", "scale='min(256,iw)':-1"]
        default: break
        }
        args.append(url.path)
        try await FFmpeg.run(args)
    }

    static func pdf(from images: [CGImage], to url: URL) throws {
        var box = CGRect.zero
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ClementineError("Impossibile creare il PDF") }
        for img in images {
            var page = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            ctx.beginPage(mediaBox: &page)
            ctx.draw(img, in: page)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: Operations

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let img = try load(url)
        let out = Output.url(for: url, ext: ext)
        try await write(img, to: out)
        return out
    }

    static func transform(_ url: URL, suffix: String, _ f: (CIImage) -> CIImage) async throws -> URL {
        let img = try load(url)
        guard let result = render(f(CIImage(cgImage: img))) else { throw ClementineError("Elaborazione fallita") }
        let ext = outputExt(for: url)
        let out = Output.url(for: url, ext: ext, suffix: suffix)
        try await write(result, to: out, quality: 0.92)
        return out
    }

    /// Keeps the original format when we can write it, otherwise PNG.
    static func outputExt(for url: URL) -> String {
        var ext = url.pathExtension.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        if ext == "heif" { ext = "heic" }
        if ext == "tif" { ext = "tiff" }
        return nativeTypes[ext] != nil || ext == "webp" ? ext : "png"
    }

    static func resize(_ url: URL, percent: Double?, maxSide: Double?) async throws -> URL {
        let img = try load(url)
        var scale = 1.0
        if let p = percent, p > 0 { scale = p / 100 }
        if let m = maxSide, m > 0 { scale = min(1, m / Double(max(img.width, img.height))) }
        let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let result = render(ci) else { throw ClementineError("Ridimensionamento fallito") }
        let out = Output.url(for: url, ext: outputExt(for: url), suffix: "-\(result.width)x\(result.height)")
        try await write(result, to: out, quality: 0.9)
        return out
    }

    /// Re-encodes to JPEG/HEIC at the highest quality (and, if needed, smallest scale) under `targetKB`.
    static func compress(_ url: URL, targetKB: Double?, percent: Double?) throws -> URL {
        var img = try load(url)
        let original = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        var target = (targetKB ?? 0) * 1024
        if target <= 0, let p = percent, p > 0, original > 0 { target = original * p / 100 }
        if target <= 0 { target = original * 0.5 }
        let ext = url.pathExtension.lowercased() == "heic" ? "heic" : "jpg"

        for _ in 0..<6 {
            var lo = 0.05, hi = 0.95
            var best: Data?
            for _ in 0..<7 {
                let q = (lo + hi) / 2
                guard let d = data(img, ext: ext, quality: q) else { break }
                if Double(d.count) <= target { best = d; lo = q } else { hi = q }
            }
            if let best {
                let out = Output.url(for: url, ext: ext, suffix: "-compresso")
                try best.write(to: out)
                return out
            }
            // Even the lowest quality is too big: shrink the image and retry.
            let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: 0.75, y: 0.75))
            guard let smaller = render(ci) else { break }
            img = smaller
        }
        throw ClementineError("Impossibile raggiungere la dimensione richiesta")
    }

    static func stripMetadata(_ url: URL) async throws -> URL {
        // Re-encoding through CGImage drops EXIF/GPS/IPTC; orientation is already baked in.
        let img = try load(url)
        let out = Output.url(for: url, ext: outputExt(for: url), suffix: "-senza-metadati")
        try await write(img, to: out, quality: 0.95)
        return out
    }

    static func metadataText(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return "Nessun metadato leggibile."
        }
        return describe(props)
    }

    static func describe(_ dict: [String: Any], indent: String = "") -> String {
        dict.keys.sorted().map { key in
            let value = dict[key]!
            if let sub = value as? [String: Any] {
                return "\(indent)\(key):\n" + describe(sub, indent: indent + "  ")
            }
            return "\(indent)\(key): \(value)"
        }.joined(separator: "\n")
    }

    static func readQR(_ url: URL) throws -> String {
        let img = try load(url)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: img).perform([request])
        let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }
        return payloads.isEmpty ? "Nessun codice QR o a barre trovato." : payloads.joined(separator: "\n\n")
    }

    static func ocr(_ url: URL) throws -> String {
        let img = try load(url)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        try VNImageRequestHandler(cgImage: img).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? "Nessun testo riconosciuto." : lines.joined(separator: "\n")
    }

    /// Removes the background using Vision's subject lifting (macOS 14+).
    static func removeBackground(_ url: URL) async throws -> URL {
        guard #available(macOS 14.0, *) else { throw ClementineError("Richiede macOS 14 o successivo") }
        let img = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([request])
        guard let result = request.results?.first else { throw ClementineError("Nessun soggetto trovato") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        guard let cg = render(CIImage(cvPixelBuffer: buffer)) else { throw ClementineError("Elaborazione fallita") }
        let out = Output.url(for: url, ext: "png", suffix: "-senza-sfondo")
        try await write(cg, to: out)
        return out
    }

    static func collage(_ urls: [URL], columns: Int) async throws -> URL {
        let images = try urls.map(load)
        let cols = max(1, columns)
        let cell = 800
        let rows = Int(ceil(Double(images.count) / Double(cols)))
        let gap = 16
        let w = cols * cell + (cols + 1) * gap, h = rows * cell + (rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ClementineError("Memoria insufficiente") }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, img) in images.enumerated() {
            let col = i % cols, row = i / cols
            let s = min(Double(cell) / Double(img.width), Double(cell) / Double(img.height))
            let dw = Double(img.width) * s, dh = Double(img.height) * s
            let x = Double(gap + col * (cell + gap)) + (Double(cell) - dw) / 2
            let y = Double(h - (row + 1) * (cell + gap)) + (Double(cell) - dh) / 2
            ctx.draw(img, in: CGRect(x: x, y: y, width: dw, height: dh))
        }
        guard let result = ctx.makeImage() else { throw ClementineError("Elaborazione fallita") }
        let out = Output.url(for: urls[0], ext: "jpg", suffix: "-collage")
        try await write(result, to: out, quality: 0.9)
        return out
    }
}

// MARK: - Metadata editing (lossless, through ImageIO)

extension ImageTools {
    /// Writes common descriptive fields without re-encoding pixels. Empty values are left unchanged.
    static func editMetadata(_ url: URL, fields: [String: String], removeGPS: Bool) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw ClementineError("Impossibile leggere l'immagine")
        }
        let out = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: "-metadati")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw ClementineError("Formato non scrivibile") }
        let meta = CGImageMetadataCreateMutable()
        func set(_ ns: CFString, _ prefix: CFString, _ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            CGImageMetadataSetValueWithPath(meta, nil, "\(prefix):\(key)" as CFString, value as CFString)
        }
        set(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "title", fields["title"])
        set(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "creator", fields["author"])
        set(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "description", fields["description"])
        set(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "rights", fields["copyright"])
        set(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "subject", fields["keywords"])
        if let date = fields["date"], !date.isEmpty {
            CGImageMetadataSetValueWithPath(meta, nil, "xmp:CreateDate" as CFString, date as CFString)
        }
        var options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        if removeGPS { options[kCGImageMetadataShouldExcludeGPS] = true }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            throw ClementineError("Questo formato non permette di modificare i metadati senza ricodifica")
        }
        return out
    }
}
