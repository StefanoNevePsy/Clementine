import AppKit
import SwiftUI
import CoreImage

// MARK: - Model

enum EditorTab: String, CaseIterable, Identifiable {
    case crop, adjust, annotate, redact, frame
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: return "Ritaglia"
        case .adjust: return "Regola"
        case .annotate: return "Annota"
        case .redact: return "Oscura"
        case .frame: return "Cornice"
        }
    }
}

enum MarkKind: String, CaseIterable, Identifiable {
    case pen, arrow, rect, highlight, text, solid, blur
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pen: return "Penna"
        case .arrow: return "Freccia"
        case .rect: return "Riquadro"
        case .highlight: return "Evidenzia"
        case .text: return "Testo"
        case .solid: return "Pieno"
        case .blur: return "Sfocato"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .solid: return "rectangle.fill"
        case .blur: return "aqi.medium"
        }
    }
}

/// An annotation or redaction, in full-resolution image pixels (origin bottom-left).
struct Mark {
    var kind: MarkKind
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""

    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

struct Adjustments: Equatable {
    var exposure = 0.0      // EV, -2...2
    var contrast = 1.0      // 0.5...1.5
    var saturation = 1.0    // 0...2
    var highlights = 1.0    // 0...1
    var shadows = 0.0       // -1...1
    var warmth = 0.0        // -1...1
    var sharpen = 0.0       // 0...1
    var noise = 0.0         // 0...1
    var grain = 0.0         // 0...1
}

struct FrameStyle: Equatable {
    var padding = 0.0           // fraction of the long side
    var ratio = "Originale"
    var cornerRadius = 0.0      // fraction of the short side
    var shadow = false
    var background = NSColor.white
}

final class EditorModel: ObservableObject {
    let urls: [URL]
    let tabs: [EditorTab]
    /// Custom save handler (used for video redaction / crop). Default saves image files.
    var onSave: ((EditorModel) -> Void)?

    @Published var tab: EditorTab { didSet { render() } }
    @Published var markKind: MarkKind = .arrow
    @Published var color: Color = .red
    @Published var lineWidth: Double = 6
    @Published var adjust = Adjustments() { didSet { render() } }
    @Published var frame = FrameStyle() { didSet { render() } }
    @Published var cropRatio = "Libera"
    @Published private(set) var display: CGImage?

    private(set) var base: CGImage
    private var preview: CGImage
    private(set) var previewScale: CGFloat = 1
    var marks: [Mark] = [] { didSet { render() } }
    var current: Mark? { didSet { render() } }
    var crop: CGRect? { didSet { objectWillChange.send() } }

    var fullSize: CGSize { CGSize(width: base.width, height: base.height) }

    init(urls: [URL], image: CGImage, tabs: [EditorTab] = EditorTab.allCases, initial: EditorTab = .crop) {
        self.urls = urls
        self.tabs = tabs
        self.base = image
        self.preview = image
        self.tab = tabs.contains(initial) ? initial : tabs[0]
        if tabs == [.redact] { markKind = .blur }
        rebuildPreview()
    }

    private func rebuildPreview() {
        let maxSide: CGFloat = 1600
        let s = min(1, maxSide / CGFloat(max(base.width, base.height)))
        previewScale = s
        if s < 1, let small = ImageTools.render(CIImage(cgImage: base).transformed(by: CGAffineTransform(scaleX: s, y: s))) {
            preview = small
        } else {
            preview = base
        }
        render()
    }

    private var renderScheduled = false
    func render() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            let final = self.tab == .frame
            self.display = self.compose(self.preview, scale: self.previewScale, final: final)
        }
    }

    // MARK: Composition

    func compose(_ src: CGImage, scale: CGFloat, final: Bool, adjustments: Bool = true, includeMarks: Bool = true) -> CGImage? {
        var ci = CIImage(cgImage: src)
        if adjustments { ci = apply(adjust, to: ci, scale: scale) }
        guard let adjusted = ImageTools.render(ci) else { return nil }
        let w = adjusted.width, h = adjusted.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(adjusted, in: CGRect(x: 0, y: 0, width: w, height: h))
        if includeMarks {
            for m in marks + (current.map { [$0] } ?? []) { draw(m, in: ctx, scale: scale, source: adjusted) }
        }
        guard var img = ctx.makeImage() else { return nil }
        if final {
            if let c = crop {
                let r = CGRect(x: c.minX * scale, y: c.minY * scale, width: c.width * scale, height: c.height * scale).integral
                // CGImage cropping uses a top-left origin.
                if let cropped = img.cropping(to: CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height)) { img = cropped }
            }
            img = applyFrame(img) ?? img
        }
        return img
    }

    func apply(_ a: Adjustments, to input: CIImage, scale: CGFloat) -> CIImage {
        var ci = input
        let extent = ci.extent
        if a.exposure != 0 { ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.contrast != 1 || a.saturation != 1 {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        }
        if a.highlights != 1 || a.shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": a.highlights, "inputShadowAmount": a.shadows])
        }
        if a.warmth != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 - a.warmth * 2500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if a.noise > 0 {
            ci = ci.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": a.noise * 0.08, "inputSharpness": 0.4])
        }
        if a.sharpen > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpen * 2,
                                                                     kCIInputRadiusKey: max(1, 2.5 * scale)])
        }
        if a.grain > 0 {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: max(1, scale * 1.5), y: max(1, scale * 1.5)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a.grain * 0.6)])
                .cropped(to: extent)
            ci = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: ci])
        }
        return ci.cropped(to: extent)
    }

    private func draw(_ m: Mark, in ctx: CGContext, scale s: CGFloat, source: CGImage) {
        let pts = m.points.map { CGPoint(x: $0.x * s, y: $0.y * s) }
        let rect = CGRect(x: m.rect.minX * s, y: m.rect.minY * s, width: m.rect.width * s, height: m.rect.height * s)
        let lw = max(1, m.width * s * max(CGFloat(base.width), CGFloat(base.height)) / 1600)
        ctx.saveGState()
        ctx.setStrokeColor(m.color.cgColor)
        ctx.setFillColor(m.color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch m.kind {
        case .pen:
            guard let first = pts.first else { break }
            ctx.move(to: first)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .arrow:
            guard let a = pts.first, let b = pts.last, a != b else { break }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(lw * 4, 14 * s)
            ctx.move(to: a)
            ctx.addLine(to: CGPoint(x: b.x - cos(angle) * head * 0.6, y: b.y - sin(angle) * head * 0.6))
            ctx.strokePath()
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7)))
            ctx.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7)))
            ctx.closePath()
            ctx.fillPath()
        case .rect:
            ctx.stroke(rect)
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(m.color.withAlphaComponent(0.4).cgColor)
            ctx.fill(rect)
        case .text:
            guard let p = pts.first, !m.text.isEmpty else { break }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let font = NSFont.systemFont(ofSize: lw * 5, weight: .bold)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = lw / 2
            (m.text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: m.color, .shadow: shadow])
            NSGraphicsContext.restoreGraphicsState()
        case .solid:
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect)
        case .blur:
            guard rect.width > 2, rect.height > 2 else { break }
            let sigma = max(8, max(rect.width, rect.height) / 10)
            let blurred = CIImage(cgImage: source).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(6, sigma / 1.5), kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)])
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: rect)
            if let cg = ImageTools.ciContext.createCGImage(blurred, from: rect) { ctx.draw(cg, in: rect) }
        }
        ctx.restoreGState()
    }

    private func applyFrame(_ img: CGImage) -> CGImage? {
        let f = frame
        guard f.padding > 0 || f.ratio != "Originale" || f.cornerRadius > 0 || f.shadow else { return img }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let pad = f.padding * max(w, h)
        var cw = w + pad * 2, ch = h + pad * 2
        if let r = Self.ratioValue(f.ratio) {
            if cw / ch < r { cw = ch * r } else { ch = cw / r }
        }
        guard let ctx = CGContext(data: nil, width: Int(cw), height: Int(ch), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(f.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        let dest = CGRect(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h)
        let radius = f.cornerRadius * min(w, h)
        let path = CGPath(roundedRect: dest, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if f.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(w, h) * 0.01), blur: max(w, h) * 0.03,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(img, in: dest)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func ratioValue(_ s: String) -> CGFloat? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 2, p[1] > 0 else { return nil }
        return CGFloat(p[0] / p[1])
    }

    // MARK: Editing commands

    var nsColor: NSColor { NSColor(color) }

    func undo() {
        if !marks.isEmpty { marks.removeLast() } else { crop = nil }
    }

    func reset() {
        marks = []
        crop = nil
        adjust = Adjustments()
        frame = FrameStyle()
    }

    /// Rotation and flips bake the current marks into the base image.
    func reorient(_ o: CGImagePropertyOrientation) {
        guard let flattened = compose(base, scale: 1, final: false, adjustments: false),
              let turned = ImageTools.render(CIImage(cgImage: flattened).oriented(o)) else { return }
        base = turned
        marks = []
        crop = nil
        rebuildPreview()
    }

    // MARK: Saving

    func finalImage() -> CGImage? { compose(base, scale: 1, final: true) }

    func save() async throws -> [URL] {
        var outs: [URL] = []
        guard let first = urls.first, let img = finalImage() else { throw ClementineError("Impossibile creare l'immagine modificata") }
        let out = Output.url(for: first, ext: ImageTools.outputExt(for: first), suffix: "-modificata")
        try await ImageTools.write(img, to: out, quality: 0.92)
        outs.append(out)
        // Other selected images get the same crop (as a share of the image), adjustments and frame — not the marks.
        let relativeCrop = crop.map { CGRect(x: $0.minX / fullSize.width, y: $0.minY / fullSize.height,
                                             width: $0.width / fullSize.width, height: $0.height / fullSize.height) }
        for url in urls.dropFirst() {
            let other = try ImageTools.load(url)
            let m = EditorModel(urls: [url], image: other, tabs: tabs)
            m.adjust = adjust
            m.frame = frame
            if let r = relativeCrop {
                m.crop = CGRect(x: r.minX * CGFloat(other.width), y: r.minY * CGFloat(other.height),
                                width: r.width * CGFloat(other.width), height: r.height * CGFloat(other.height))
            }
            guard let result = m.finalImage() else { continue }
            let o = Output.url(for: url, ext: ImageTools.outputExt(for: url), suffix: "-modificata")
            try await ImageTools.write(result, to: o, quality: 0.92)
            outs.append(o)
        }
        return outs
    }
}

// MARK: - Window

final class ImageEditorWindow: NSWindowController, NSWindowDelegate {
    private static var open: [ImageEditorWindow] = []

    @MainActor
    static func show(model: EditorModel, title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        let controller = ImageEditorWindow(window: window)
        window.delegate = controller
        window.contentView = NSHostingView(rootView: EditorView(model: model) { [weak controller] in controller?.close() })
        open.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    @MainActor
    static func open(_ urls: [URL], tab: EditorTab) {
        do {
            let img = try ImageTools.load(urls[0])
            let model = EditorModel(urls: urls, image: img, initial: tab)
            let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) e altre \(urls.count - 1)"
            show(model: model, title: title)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

// MARK: - SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @State private var saving = false

    var body: some View {
        HStack(spacing: 0) {
            EditorCanvasView(model: model)
                .frame(minWidth: 500, minHeight: 400)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.tabs.count > 1 {
                        Picker("", selection: $model.tab) {
                            ForEach(model.tabs) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    switch model.tab {
                    case .crop: cropPanel
                    case .adjust: adjustPanel
                    case .annotate: annotatePanel
                    case .redact: redactPanel
                    case .frame: framePanel
                    }
                    Divider()
                    HStack {
                        Button("Annulla ultimo") { model.undo() }
                        Button("Ripristina") { model.reset() }
                    }
                    HStack {
                        Button { model.reorient(.left) } label: { Image(systemName: "rotate.left") }.help("Ruota a sinistra")
                        Button { model.reorient(.right) } label: { Image(systemName: "rotate.right") }.help("Ruota a destra")
                        Button { model.reorient(.upMirrored) } label: { Image(systemName: "arrow.left.and.right") }.help("Rifletti orizzontalmente")
                        Button { model.reorient(.downMirrored) } label: { Image(systemName: "arrow.up.and.down") }.help("Rifletti verticalmente")
                    }
                    if model.urls.count > 1, model.onSave == nil {
                        Text("Ritaglio, regolazioni e cornice verranno applicati anche alle altre \(model.urls.count - 1) immagini (le annotazioni solo alla prima).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 10)
                    HStack {
                        Button("Chiudi") { close() }
                        Spacer()
                        Button(saving ? "Salvataggio…" : (model.onSave == nil ? "Salva copia" : "Applica")) { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(saving)
                    }
                }
                .padding(16)
            }
            .frame(width: 300)
        }
    }

    private func save() {
        if let custom = model.onSave {
            custom(model)
            close()
            return
        }
        saving = true
        let m = model
        JobCenter.shared.run(title: "Modifica · \(m.urls[0].lastPathComponent)") { _ in try await m.save() }
        close()
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trascina sull'immagine per scegliere l'area. Trascina dentro il riquadro per spostarlo.")
                .font(.caption).foregroundColor(.secondary)
            Picker("Proporzioni", selection: $model.cropRatio) {
                ForEach(["Libera", "1:1", "4:3", "3:2", "16:9", "4:5", "9:16"], id: \.self) { Text($0) }
            }
            if let c = model.crop {
                Text("\(Int(c.width)) × \(Int(c.height)) px").font(.caption.monospacedDigit())
                Button("Togli ritaglio") { model.crop = nil }
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Slider(value: value, in: range)
        }
    }

    private var adjustPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            slider("Esposizione", $model.adjust.exposure, -2...2)
            slider("Contrasto", $model.adjust.contrast, 0.5...1.5)
            slider("Saturazione", $model.adjust.saturation, 0...2)
            slider("Luci", $model.adjust.highlights, 0...1)
            slider("Ombre", $model.adjust.shadows, -1...1)
            slider("Calore", $model.adjust.warmth, -1...1)
            slider("Nitidezza", $model.adjust.sharpen, 0...1)
            slider("Riduzione rumore", $model.adjust.noise, 0...1)
            slider("Grana", $model.adjust.grain, 0...1)
            Button("Azzera regolazioni") { model.adjust = Adjustments() }
        }
    }

    private func kindPicker(_ kinds: [MarkKind]) -> some View {
        HStack {
            ForEach(kinds) { k in
                Button { model.markKind = k } label: {
                    VStack(spacing: 2) {
                        Image(systemName: k.symbol)
                        Text(k.label).font(.caption2)
                    }
                    .frame(width: 50, height: 40)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.markKind == k ? Color.orange.opacity(0.3) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var annotatePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindPicker([.arrow, .rect, .pen, .highlight, .text])
            ColorPicker("Colore", selection: $model.color)
            slider("Spessore", $model.lineWidth, 1...30)
            Text(model.markKind == .text ? "Clicca dove vuoi il testo." : "Trascina sull'immagine per disegnare.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { if ![.arrow, .rect, .pen, .highlight, .text].contains(model.markKind) { model.markKind = .arrow } }
    }

    private var redactPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindPicker([.blur, .solid])
            Text("Disegna un rettangolo sull'area da nascondere. Lo sfocato ammorbidisce i dettagli: per dati sensibili usa Pieno.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { if model.markKind != .solid { model.markKind = .blur } }
    }

    private var framePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Margine", $model.frame.padding, 0...0.3)
            Picker("Formato", selection: $model.frame.ratio) {
                ForEach(["Originale", "1:1", "4:5", "16:9", "9:16", "4:3"], id: \.self) { Text($0) }
            }
            slider("Angoli arrotondati", $model.frame.cornerRadius, 0...0.2)
            Toggle("Ombra", isOn: $model.frame.shadow)
            ColorPicker("Sfondo", selection: Binding(get: { Color(nsColor: model.frame.background) },
                                                     set: { model.frame.background = NSColor($0) }))
        }
    }
}

// MARK: - Canvas

struct EditorCanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> EditorCanvas {
        let v = EditorCanvas()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: EditorCanvas, context: Context) {
        nsView.model = model
        nsView.needsDisplay = true
    }
}

final class EditorCanvas: NSView {
    weak var model: EditorModel?
    private var dragStart: CGPoint?
    private var movingCrop: CGRect?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// Where the full image is drawn inside the view (aspect fit).
    private var imageRect: CGRect {
        guard let m = model else { return .zero }
        let size = m.fullSize
        let inset = bounds.insetBy(dx: 16, dy: 16)
        let s = min(inset.width / size.width, inset.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        guard let m = model else { return p }
        let r = imageRect
        let s = m.fullSize.width / r.width
        let x = min(max((p.x - r.minX) * s, 0), m.fullSize.width)
        let y = min(max((p.y - r.minY) * s, 0), m.fullSize.height)
        return CGPoint(x: x, y: y)
    }

    private func toView(_ r: CGRect) -> CGRect {
        guard let m = model else { return r }
        let ir = imageRect
        let s = ir.width / m.fullSize.width
        return CGRect(x: ir.minX + r.minX * s, y: ir.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, let img = m.display, let ctx = NSGraphicsContext.current?.cgContext else { return }
        if m.tab == .frame {
            // Final preview, including crop and frame.
            let size = CGSize(width: img.width, height: img.height)
            let inset = bounds.insetBy(dx: 16, dy: 16)
            let s = min(inset.width / size.width, inset.height / size.height)
            let r = CGRect(x: inset.midX - size.width * s / 2, y: inset.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
            return
        }
        let r = imageRect
        ctx.interpolationQuality = .high
        ctx.draw(img, in: r)
        if let c = m.crop {
            let vr = toView(c)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addRect(r)
            ctx.addRect(vr)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(vr)
            // Rule-of-thirds guides.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(0.5)
            for i in 1...2 {
                let x = vr.minX + vr.width * CGFloat(i) / 3, y = vr.minY + vr.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: vr.minY)); ctx.addLine(to: CGPoint(x: x, y: vr.maxY))
                ctx.move(to: CGPoint(x: vr.minX, y: y)); ctx.addLine(to: CGPoint(x: vr.maxX, y: y))
            }
            ctx.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let m = model, m.tab != .frame, m.tab != .adjust else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        dragStart = p
        switch m.tab {
        case .crop:
            if let c = m.crop, c.contains(p) { movingCrop = c } else { movingCrop = nil; m.crop = CGRect(origin: p, size: .zero) }
        case .annotate, .redact:
            if m.markKind == .text { return }
            m.current = Mark(kind: m.markKind, points: [p, p], color: m.nsColor, width: CGFloat(m.lineWidth))
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m = model, let start = dragStart else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch m.tab {
        case .crop:
            if let moving = movingCrop {
                var r = moving.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
                r.origin.x = min(max(r.minX, 0), m.fullSize.width - r.width)
                r.origin.y = min(max(r.minY, 0), m.fullSize.height - r.height)
                m.crop = r
            } else {
                var dx = p.x - start.x, dy = p.y - start.y
                if let ratio = EditorModel.ratioValue(m.cropRatio) {
                    let w = max(abs(dx), abs(dy) * ratio)
                    dx = dx < 0 ? -w : w
                    dy = (dy < 0 ? -1 : 1) * w / ratio
                }
                let r = CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
                m.crop = r.intersection(CGRect(origin: .zero, size: m.fullSize))
            }
        case .annotate, .redact:
            guard var cur = m.current else { return }
            if cur.kind == .pen { cur.points.append(p) } else { cur.points = [start, p] }
            m.current = cur
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let m = model else { return }
        defer { dragStart = nil; movingCrop = nil }
        switch m.tab {
        case .crop:
            if let c = m.crop, c.width < 4 || c.height < 4 { m.crop = nil }
        case .annotate, .redact:
            if m.markKind == .text, let start = dragStart {
                if let v = ParamPrompt.ask(title: "Testo", params: [Param(key: "t", label: "Testo da inserire", defaultValue: "")]),
                   let t = v["t"], !t.isEmpty {
                    m.marks.append(Mark(kind: .text, points: [start], color: m.nsColor, width: CGFloat(m.lineWidth), text: t))
                }
                return
            }
            if let cur = m.current {
                let big = cur.kind == .pen ? cur.points.count > 2 : (cur.rect.width > 3 || cur.rect.height > 3)
                if big { m.marks.append(cur) }
                m.current = nil
            }
        default: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { model?.undo() } else { super.keyDown(with: event) }   // delete
    }
}
