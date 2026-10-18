import AppKit
import AVFoundation
import AVKit
import SwiftUI

// MARK: - Model

enum MediaEditMode {
    case trim, bleep, split, frames, speed

    var title: String {
        switch self {
        case .trim: return "Taglia"
        case .bleep: return "Bleep"
        case .split: return "Dividi"
        case .frames: return "Fotogrammi"
        case .speed: return "Velocità"
        }
    }

    var hint: String {
        switch self {
        case .trim: return "Trascina le maniglie arancioni per scegliere la parte da tenere."
        case .bleep: return "Trascina sulla forma d'onda per coprire un tratto con il bip. Trascina un tratto o i suoi bordi per modificarlo, Canc per eliminarlo."
        case .split: return "Clicca sulla timeline per aggiungere un punto di taglio. Trascinalo per spostarlo, Canc per eliminarlo."
        case .frames: return "Clicca sulla timeline per scegliere i fotogrammi da salvare. Canc elimina quello selezionato."
        case .speed: return "Scegli la velocità e ascolta l'anteprima."
        }
    }
}

struct TimeRange: Equatable { var start: Double; var end: Double }

final class MediaEditorModel: ObservableObject {
    let url: URL
    let mode: MediaEditMode
    let isVideo: Bool
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var peaks: [Float] = []
    @Published var thumbnails: [CGImage] = []
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var ranges: [TimeRange] = []
    @Published var markers: [Double] = []
    @Published var selected: Int?
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var speed: Double = 1.5 { didSet { if isPlaying { player.rate = Float(speed) } } }
    @Published var silenceDB: Double = -45
    @Published var status = "Caricamento della forma d'onda…"

    private var timeObserver: Any?
    private var stopAt: Double?

    init(url: URL, mode: MediaEditMode) {
        self.url = url
        self.mode = mode
        self.isVideo = FileKind.of(url) == .video && FFmpeg.hasVideoStream(url)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.playhead = t.seconds.isFinite ? t.seconds : 0
            if let stop = self.stopAt, self.playhead >= stop { self.pause() }
        }
        load()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func load() {
        let url = self.url, isVideo = self.isVideo
        Task.detached(priority: .userInitiated) {
            let d = FFmpeg.duration(of: url) ?? 0
            await MainActor.run {
                self.duration = d
                self.end = d
                if self.mode == .trim { self.start = 0 }
            }
            let peaks = Self.computePeaks(url, bins: 1600)
            await MainActor.run {
                self.peaks = peaks
                self.status = peaks.isEmpty ? "Forma d'onda non disponibile: puoi comunque usare la timeline." : ""
            }
            if isVideo {
                let thumbs = Self.computeThumbnails(url, duration: d, count: 12)
                await MainActor.run { self.thumbnails = thumbs }
            }
        }
    }

    /// Decodes audio to 2 kHz mono floats with ffmpeg and keeps the peak per bin.
    static func computePeaks(_ url: URL, bins: Int) -> [Float] {
        guard let path = FFmpeg.path else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-nostdin", "-i", url.path, "-vn", "-ac", "1", "-ar", "2000", "-f", "f32le", "pipe:1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let count = data.count / 4
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        let per = max(1, count / bins)
        var result: [Float] = []
        result.reserveCapacity(count / per + 1)
        var i = 0
        while i < count {
            var m: Float = 0
            for j in i..<min(i + per, count) { m = max(m, abs(samples[j])) }
            result.append(min(1, m))
            i += per
        }
        return result
    }

    static func computeThumbnails(_ url: URL, duration: Double, count: Int) -> [CGImage] {
        guard duration > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 136)
        var images: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: t, actualTime: nil) { images.append(img) }
        }
        return images
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play(from t: Double? = nil, until stop: Double? = nil) {
        if let t { seek(t) }
        stopAt = stop
        player.rate = mode == .speed ? Float(speed) : 1
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopAt = nil
    }

    func seek(_ t: Double) {
        let clamped = min(max(t, 0), duration)
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playSelection() {
        switch mode {
        case .trim: play(from: start, until: end)
        case .bleep:
            if let i = selected, i < ranges.count { play(from: max(0, ranges[i].start - 1), until: ranges[i].end + 1) } else { play() }
        default: play()
        }
    }

    // MARK: Editing

    /// Moves the trim handles to the first/last sample louder than the threshold.
    func autoTrimSilence() {
        guard !peaks.isEmpty, duration > 0 else { return }
        let threshold = Float(pow(10, silenceDB / 20))
        guard let first = peaks.firstIndex(where: { $0 > threshold }), let last = peaks.lastIndex(where: { $0 > threshold }) else {
            status = "Tutto il file è sotto la soglia: abbassala."
            return
        }
        let per = duration / Double(peaks.count)
        start = max(0, Double(first) * per - 0.05)
        end = min(duration, Double(last + 1) * per + 0.05)
    }

    func addMarkerAtPlayhead() {
        markers.append(playhead)
        markers.sort()
        selected = markers.firstIndex(of: playhead)
    }

    func deleteSelected() {
        guard let i = selected else { return }
        if mode == .bleep, i < ranges.count { ranges.remove(at: i) }
        if mode == .split || mode == .frames, i < markers.count { markers.remove(at: i) }
        selected = nil
    }

    var canSave: Bool {
        switch mode {
        case .trim: return end - start > 0.05
        case .bleep: return !ranges.isEmpty
        case .split, .frames: return !markers.isEmpty
        case .speed: return speed > 0 && speed != 1
        }
    }

    func save() {
        pause()
        let url = self.url
        let title = "\(mode.title) · \(url.lastPathComponent)"
        switch mode {
        case .trim:
            let (s, e) = (start, end)
            JobCenter.shared.run(title: title) { job in [try await MediaTools.trim(url, start: s, end: e, job: job)] }
        case .bleep:
            let r = ranges
            JobCenter.shared.run(title: title) { job in [try await MediaTools.bleep(url, ranges: r, job: job)] }
        case .split:
            let m = markers
            JobCenter.shared.run(title: title) { job in try await MediaTools.split(url, at: m, job: job) }
        case .frames:
            let m = markers
            JobCenter.shared.run(title: title) { job in try await MediaTools.frames(url, interval: 0, times: m, job: job) }
        case .speed:
            let f = speed
            JobCenter.shared.run(title: title) { job in [try await MediaTools.speed(url, factor: f, job: job)] }
        }
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite else { return "0:00.0" }
    let total = max(0, t)
    let m = Int(total) / 60
    let s = total - Double(m * 60)
    return String(format: "%d:%04.1f", m, s)
}

// MARK: - Window

final class MediaEditorWindow: NSWindowController, NSWindowDelegate {
    private static var open: [MediaEditorWindow] = []
    private var model: MediaEditorModel?

    @MainActor
    static func show(_ url: URL, mode: MediaEditMode) {
        guard FFmpeg.isAvailable else {
            NSAlert(error: ClementineError("Questo strumento richiede ffmpeg. Installalo con: brew install ffmpeg")).runModal()
            return
        }
        let model = MediaEditorModel(url: url, mode: mode)
        let height: CGFloat = model.isVideo ? 680 : 380
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(mode.title) · \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.center()
        let controller = MediaEditorWindow(window: window)
        controller.model = model
        window.delegate = controller
        window.contentView = NSHostingView(rootView: MediaEditorView(model: model) { [weak controller] in controller?.close() })
        open.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.pause()
        Self.open.removeAll { $0 === self }
    }
}

// MARK: - SwiftUI

struct MediaEditorView: View {
    @ObservedObject var model: MediaEditorModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if model.isVideo {
                VideoPlayer(player: model.player)
                    .frame(minHeight: 260)
                    .cornerRadius(8)
            }
            TimelineRepresentable(model: model)
                .frame(height: model.isVideo ? 150 : 170)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                    .keyboardShortcut(.space, modifiers: [])
                if model.mode == .trim || model.mode == .bleep {
                    Button("Ascolta selezione") { model.playSelection() }
                }
                Text("\(formatTime(model.playhead)) / \(formatTime(model.duration))").font(.body.monospacedDigit())
                Spacer()
                modeControls
            }
            HStack {
                Text(model.status.isEmpty ? model.mode.hint : model.status)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Chiudi") { close() }
                Button("Salva copia") { model.save(); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var modeControls: some View {
        switch model.mode {
        case .trim:
            Text("Da \(formatTime(model.start)) a \(formatTime(model.end)) · \(formatTime(model.end - model.start))")
                .font(.callout.monospacedDigit())
            Divider().frame(height: 18)
            Text("Soglia \(Int(model.silenceDB)) dB").font(.caption)
            Slider(value: $model.silenceDB, in: -70 ... -20).frame(width: 110)
            Button("Togli silenzi") { model.autoTrimSilence() }
        case .bleep:
            Text("\(model.ranges.count) tratti").font(.callout)
            Button("Bleep al cursore") {
                model.ranges.append(TimeRange(start: model.playhead, end: min(model.duration, model.playhead + 1)))
                model.selected = model.ranges.count - 1
            }
            Button("Bleep su tutto") { model.ranges = [TimeRange(start: 0, end: model.duration)] }
        case .split, .frames:
            Text("\(model.markers.count) \(model.mode == .split ? "tagli" : "fotogrammi")").font(.callout)
            Button("Aggiungi al cursore") { model.addMarkerAtPlayhead() }
            if model.mode == .frames {
                Button("Uno ogni 10 s") {
                    model.markers = stride(from: 0, to: model.duration, by: 10).map { $0 }
                }
            }
        case .speed:
            Picker("", selection: $model.speed) {
                ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            .labelsHidden().frame(width: 90)
            Slider(value: $model.speed, in: 0.25...4).frame(width: 160)
            Text("Durata finale \(formatTime(model.duration / max(model.speed, 0.01)))").font(.callout.monospacedDigit())
        }
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    @ObservedObject var model: MediaEditorModel

    func makeNSView(context: Context) -> TimelineView {
        let v = TimelineView()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: TimelineView, context: Context) {
        nsView.model = model
        nsView.needsDisplay = true
    }
}

// MARK: - Timeline (waveform + thumbnails + handles)

final class TimelineView: NSView {
    weak var model: MediaEditorModel?

    private enum Drag {
        case scrub, trimStart, trimEnd, newRange(Double), moveRange(Int, Double, TimeRange), rangeStart(Int), rangeEnd(Int), marker(Int)
    }
    private var drag: Drag?
    private var downPoint: CGPoint = .zero

    private let ruler: CGFloat = 18
    private let accent = NSColor(calibratedRed: 1, green: 0.54, blue: 0.12, alpha: 1)

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private var track: CGRect { bounds.insetBy(dx: 12, dy: 0).divided(atDistance: ruler, from: .minYEdge).remainder.insetBy(dx: 0, dy: 6) }

    private func x(_ t: Double) -> CGFloat {
        guard let m = model, m.duration > 0 else { return track.minX }
        return track.minX + CGFloat(t / m.duration) * track.width
    }

    private func time(_ x: CGFloat) -> Double {
        guard let m = model, m.duration > 0 else { return 0 }
        return min(max(Double((x - track.minX) / track.width) * m.duration, 0), m.duration)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = track

        // Ruler with ticks.
        if m.duration > 0 {
            let step = niceStep(m.duration)
            var t = 0.0
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            while t <= m.duration {
                let px = x(t)
                NSColor.tertiaryLabelColor.setFill()
                NSRect(x: px, y: ruler - 5, width: 1, height: 5).fill()
                (formatTime(t).replacingOccurrences(of: ".0", with: "") as NSString).draw(at: NSPoint(x: px + 2, y: 2), withAttributes: attrs)
                t += step
            }
        }

        // Thumbnails strip (video).
        var waveRect = r
        if !m.thumbnails.isEmpty {
            let (strip, rest) = r.divided(atDistance: r.height * 0.45, from: .minYEdge)
            waveRect = rest.insetBy(dx: 0, dy: 4)
            let w = strip.width / CGFloat(m.thumbnails.count)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: strip.minY + strip.maxY)
            ctx.scaleBy(x: 1, y: -1)   // CGImage draws bottom-up
            for (i, img) in m.thumbnails.enumerated() {
                let cell = CGRect(x: strip.minX + CGFloat(i) * w, y: strip.minY, width: w, height: strip.height)
                ctx.saveGState()
                ctx.clip(to: cell)
                let s = max(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
                let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
                ctx.draw(img, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }

        // Waveform.
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: waveRect, xRadius: 4, yRadius: 4).fill()
        if !m.peaks.isEmpty {
            let mid = waveRect.midY
            let n = m.peaks.count
            NSColor.secondaryLabelColor.setFill()
            let cols = Int(waveRect.width)
            for c in 0..<max(cols, 1) {
                let i0 = c * n / max(cols, 1), i1 = max(i0 + 1, (c + 1) * n / max(cols, 1))
                var p: Float = 0
                for i in i0..<min(i1, n) { p = max(p, m.peaks[i]) }
                let h = max(1, CGFloat(sqrt(p)) * waveRect.height / 2 * 0.95)
                NSRect(x: waveRect.minX + CGFloat(c), y: mid - h, width: 1, height: h * 2).fill()
            }
        }

        // Mode overlays.
        switch m.mode {
        case .trim:
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSRect(x: r.minX, y: r.minY, width: x(m.start) - r.minX, height: r.height).fill()
            NSRect(x: x(m.end), y: r.minY, width: r.maxX - x(m.end), height: r.height).fill()
            accent.setStroke()
            let sel = NSBezierPath(rect: NSRect(x: x(m.start), y: r.minY + 1, width: x(m.end) - x(m.start), height: r.height - 2))
            sel.lineWidth = 2
            sel.stroke()
            for hx in [x(m.start), x(m.end)] {
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: hx - 5, y: r.midY - 18, width: 10, height: 36), xRadius: 4, yRadius: 4).fill()
            }
        case .bleep:
            for (i, range) in m.ranges.enumerated() {
                let rr = NSRect(x: x(range.start), y: r.minY, width: max(2, x(range.end) - x(range.start)), height: r.height)
                NSColor.systemRed.withAlphaComponent(m.selected == i ? 0.55 : 0.35).setFill()
                rr.fill()
                NSColor.systemRed.setFill()
                NSRect(x: rr.minX, y: r.minY, width: 2, height: r.height).fill()
                NSRect(x: rr.maxX - 2, y: r.minY, width: 2, height: r.height).fill()
            }
        case .split, .frames:
            for (i, t) in m.markers.enumerated() {
                (m.selected == i ? accent : NSColor.systemBlue).setFill()
                NSRect(x: x(t) - 1, y: r.minY, width: 2.5, height: r.height).fill()
                NSBezierPath(ovalIn: NSRect(x: x(t) - 5, y: r.minY - 2, width: 10, height: 10)).fill()
            }
        case .speed: break
        }

        // Playhead.
        NSColor.labelColor.setFill()
        NSRect(x: x(m.playhead) - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        NSBezierPath(ovalIn: NSRect(x: x(m.playhead) - 4, y: ruler - 8, width: 8, height: 8)).fill()
    }

    private func niceStep(_ d: Double) -> Double {
        let target = d / 8
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800] where s >= target { return s }
        return 3600
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let m = model else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        let t = time(p.x)
        let near: (Double) -> Bool = { abs(self.x($0) - p.x) < 8 }

        if p.y < ruler { drag = .scrub; m.seek(t); return }
        switch m.mode {
        case .trim:
            if near(m.start) { drag = .trimStart } else if near(m.end) { drag = .trimEnd } else { drag = .scrub; m.seek(t) }
        case .bleep:
            if let i = m.ranges.firstIndex(where: { near($0.start) }) { drag = .rangeStart(i); m.selected = i }
            else if let i = m.ranges.firstIndex(where: { near($0.end) }) { drag = .rangeEnd(i); m.selected = i }
            else if let i = m.ranges.firstIndex(where: { t >= $0.start && t <= $0.end }) { drag = .moveRange(i, t, m.ranges[i]); m.selected = i }
            else { drag = .newRange(t); m.selected = nil }
        case .split, .frames:
            if let i = m.markers.firstIndex(where: near) { drag = .marker(i); m.selected = i }
            else { m.markers.append(t); m.markers.sort(); m.selected = m.markers.firstIndex(of: t); m.seek(t)
                   if let i = m.selected { drag = .marker(i) } }
        case .speed:
            drag = .scrub; m.seek(t)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m = model, let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = time(p.x)
        switch drag {
        case .scrub: m.seek(t)
        case .trimStart: m.start = min(t, m.end - 0.05); m.seek(m.start)
        case .trimEnd: m.end = max(t, m.start + 0.05); m.seek(m.end)
        case .newRange(let origin):
            guard abs(p.x - downPoint.x) > 3 else { return }
            let range = TimeRange(start: min(origin, t), end: max(origin, t))
            if let i = m.selected, i < m.ranges.count { m.ranges[i] = range } else {
                m.ranges.append(range)
                m.selected = m.ranges.count - 1
            }
        case .moveRange(let i, let origin, let initial):
            let len = initial.end - initial.start
            let s = min(max(initial.start + (t - origin), 0), m.duration - len)
            m.ranges[i] = TimeRange(start: s, end: s + len)
        case .rangeStart(let i): m.ranges[i].start = min(t, m.ranges[i].end - 0.05)
        case .rangeEnd(let i): m.ranges[i].end = max(t, m.ranges[i].start + 0.05)
        case .marker(let i):
            guard i < m.markers.count else { return }
            m.markers[i] = t
            m.seek(t)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let m = model else { return }
        if case .newRange(let origin)? = drag, abs(convert(event.locationInWindow, from: nil).x - downPoint.x) <= 3 {
            m.seek(origin)   // simple click: move the playhead
        }
        if case .marker? = drag {
            let selectedTime = m.selected.flatMap { $0 < m.markers.count ? m.markers[$0] : nil }
            m.markers.sort()
            m.selected = selectedTime.flatMap { m.markers.firstIndex(of: $0) }
        }
        drag = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: model?.deleteSelected(); needsDisplay = true     // delete
        case 49: model?.togglePlay()                                   // space
        case 123: if let m = model { m.seek(m.playhead - 1) }          // ←
        case 124: if let m = model { m.seek(m.playhead + 1) }          // →
        default: super.keyDown(with: event)
        }
    }
}
