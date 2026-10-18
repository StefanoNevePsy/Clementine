import AVFoundation
import AppKit

/// Video and audio processing. Uses ffmpeg when available, AVFoundation as a fallback.
enum MediaTools {
    // MARK: Codec presets

    static func encodeArgs(for ext: String, hasVideo: Bool) -> [String] {
        switch ext {
        case "mp4", "m4v", "mov":
            return ["-c:v", "libx264", "-crf", "\(Prefs.videoCRF)", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "mkv":
            return ["-c:v", "libx264", "-crf", "\(Prefs.videoCRF - 1)", "-preset", "medium", "-c:a", "aac", "-b:a", "192k", "-c:s", "copy"]
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv":
            return ["-c:v", "wmv2", "-b:v", "3M", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif":
            return ["-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        default: return []
        }
    }

    // MARK: Conversion

    static func convert(_ url: URL, to ext: String, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: ext)
        if FFmpeg.isAvailable {
            let hasVideo = FFmpeg.hasVideoStream(url)
            try await FFmpeg.run(["-i", url.path] + encodeArgs(for: ext, hasVideo: hasVideo) + [out.path],
                                 duration: FFmpeg.duration(of: url), job: job)
            return out
        }
        // AVFoundation fallback (MP4 / MOV / M4A only).
        let fileType: AVFileType
        let preset: String
        switch ext {
        case "mp4": fileType = .mp4; preset = AVAssetExportPresetHighestQuality
        case "mov": fileType = .mov; preset = AVAssetExportPresetHighestQuality
        case "m4a": fileType = .m4a; preset = AVAssetExportPresetAppleM4A
        default: _ = try FFmpeg.requirePath(); throw ClementineError("Formato non supportato")
        }
        try await export(AVURLAsset(url: url), preset: preset, to: out, type: fileType, job: job)
        return out
    }

    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType,
                       timeRange: CMTimeRange? = nil, job: Job?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ClementineError("Formato non supportato da AVFoundation")
        }
        session.outputURL = out
        session.outputFileType = type
        if let timeRange { session.timeRange = timeRange }
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in job?.report(Double(session.progress)) }
        RunLoop.main.add(timer, forMode: .common)
        await session.export()
        timer.invalidate()
        if session.status != .completed {
            throw session.error ?? ClementineError("Esportazione non riuscita")
        }
    }

    // MARK: Tools

    static func trim(_ url: URL, start: Double, end: Double, job: Job?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, ext: ext, suffix: "-tagliato")
        var args = ["-ss", String(start), "-i", url.path]
        if end > start { args += ["-t", String(end - start)] }
        // Re-encode for frame-accurate cuts.
        args += encodeArgs(for: ext, hasVideo: FFmpeg.hasVideoStream(url)) + [out.path]
        try await FFmpeg.run(args, duration: end > start ? end - start : FFmpeg.duration(of: url), job: job)
        return out
    }

    static func speed(_ url: URL, factor: Double, job: Job?) async throws -> URL {
        guard factor > 0 else { throw ClementineError("Velocità non valida") }
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, ext: ext, suffix: "-x\(factor)")
        // atempo accepts 0.5...2, chain it for larger factors.
        var tempos: [Double] = []
        var f = factor
        while f > 2 { tempos.append(2); f /= 2 }
        while f < 0.5 { tempos.append(0.5); f /= 0.5 }
        tempos.append(f)
        let atempo = tempos.map { "atempo=\($0)" }.joined(separator: ",")
        var args = ["-i", url.path]
        if FFmpeg.hasVideoStream(url) { args += ["-filter:v", "setpts=PTS/\(factor)"] }
        args += ["-filter:a", atempo] + encodeArgs(for: ext, hasVideo: true).filter { $0 != "-vn" } + [out.path]
        let d = FFmpeg.duration(of: url).map { $0 / factor }
        try await FFmpeg.run(args, duration: d, job: job)
        return out
    }

    /// Hits a target size by computing the bitrate from the duration.
    static func compress(_ url: URL, targetMB: Double?, percent: Double?, job: Job?) async throws -> URL {
        guard let duration = FFmpeg.duration(of: url), duration > 0 else {
            throw ClementineError("Impossibile leggere la durata del file")
        }
        let original = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var targetBytes = (targetMB ?? 0) * 1_000_000
        if targetBytes <= 0, let p = percent, p > 0 { targetBytes = original * p / 100 }
        if targetBytes <= 0 { targetBytes = original * 0.5 }
        let totalKbps = targetBytes * 8 / 1000 / duration * 0.95   // leave room for container overhead
        let isVideo = FFmpeg.hasVideoStream(url)
        let ext = isVideo ? "mp4" : (url.pathExtension.lowercased() == "mp3" ? "mp3" : "m4a")
        let out = Output.url(for: url, ext: ext, suffix: "-compresso")

        if isVideo {
            let audioKbps = min(128, max(48, totalKbps * 0.12))
            let videoKbps = max(80, totalKbps - audioKbps)
            // Lower resolution for very low bitrates to keep it watchable.
            let scale = videoKbps < 600 ? ["-vf", "scale=-2:'min(480,ih)'"] : (videoKbps < 1500 ? ["-vf", "scale=-2:'min(720,ih)'"] : [])
            let args = ["-i", url.path, "-c:v", "libx264", "-b:v", "\(Int(videoKbps))k",
                        "-maxrate", "\(Int(videoKbps * 1.3))k", "-bufsize", "\(Int(videoKbps * 2))k",
                        "-preset", "medium", "-pix_fmt", "yuv420p"] + scale +
                ["-c:a", "aac", "-b:a", "\(Int(audioKbps))k", "-movflags", "+faststart", out.path]
            try await FFmpeg.run(args, duration: duration, job: job)
        } else {
            let kbps = max(32, min(320, Int(totalKbps)))
            let codec = ext == "mp3" ? "libmp3lame" : "aac"
            try await FFmpeg.run(["-i", url.path, "-vn", "-c:a", codec, "-b:a", "\(kbps)k", out.path],
                                 duration: duration, job: job)
        }
        return out
    }

    static func resize(_ url: URL, height: Int, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: "mp4", suffix: "-\(height)p")
        try await FFmpeg.run(["-i", url.path, "-vf", "scale=-2:\(height)"] + encodeArgs(for: "mp4", hasVideo: true) + [out.path],
                             duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    static func crop(_ url: URL, ratio: String, job: Job?) async throws -> URL {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw ClementineError("Usa un rapporto come 16:9, 1:1 o 9:16") }
        let r = parts[0] / parts[1]
        let filter = "crop='if(gt(iw/ih,\(r)),ih*\(r),iw)':'if(gt(iw/ih,\(r)),ih,iw/\(r))'"
        let out = Output.url(for: url, ext: "mp4", suffix: "-\(Int(parts[0]))x\(Int(parts[1]))")
        try await FFmpeg.run(["-i", url.path, "-vf", filter + ",scale=trunc(iw/2)*2:trunc(ih/2)*2"] +
                             encodeArgs(for: "mp4", hasVideo: true) + [out.path],
                             duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    static func mute(_ url: URL, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: "-muto")
        try await FFmpeg.run(["-i", url.path, "-c:v", "copy", "-an", out.path], job: job)
        return out
    }

    static func extractAudio(_ url: URL, job: Job?) async throws -> URL {
        try await convert(url, to: "mp3", job: job)
    }

    static func snapshot(_ url: URL, at seconds: Double) async throws -> URL {
        let out = Output.url(for: url, ext: "png", suffix: "-frame")
        if FFmpeg.isAvailable {
            try await FFmpeg.run(["-ss", String(seconds), "-i", url.path, "-frames:v", "1", out.path])
            return out
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        try await ImageTools.write(cg, to: out)
        return out
    }

    static func split(_ url: URL, segmentSeconds: Double, job: Job?) async throws -> [URL] {
        guard segmentSeconds > 0 else { throw ClementineError("Durata del segmento non valida") }
        let folder = Output.folder(for: url, suffix: "-parti")
        let ext = url.pathExtension.lowercased()
        let pattern = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-%03d." + ext).path
        try await FFmpeg.run(["-i", url.path, "-c", "copy", "-map", "0", "-f", "segment",
                              "-segment_time", String(segmentSeconds), "-reset_timestamps", "1", pattern],
                             duration: FFmpeg.duration(of: url), job: job)
        return [folder]
    }

    static func join(_ urls: [URL], job: Job?) async throws -> URL {
        guard urls.count > 1 else { throw ClementineError("Seleziona almeno due file da unire") }
        let isVideo = FFmpeg.hasVideoStream(urls[0])
        let ext = isVideo ? "mp4" : "m4a"
        let out = Output.url(for: urls[0], ext: ext, suffix: "-uniti")
        var args: [String] = []
        for u in urls { args += ["-i", u.path] }
        let n = urls.count
        var filter = ""
        if isVideo {
            // Normalize size/fps so clips from different sources can be concatenated.
            for i in 0..<n {
                filter += "[\(i):v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)];"
                filter += "[\(i):a]aresample=48000[a\(i)];"
            }
            filter += (0..<n).map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(n):v=1:a=1[v][a]"
            args += ["-filter_complex", filter, "-map", "[v]", "-map", "[a]"] + encodeArgs(for: "mp4", hasVideo: true)
        } else {
            filter = (0..<n).map { "[\($0):a]" }.joined() + "concat=n=\(n):v=0:a=1[a]"
            args += ["-filter_complex", filter, "-map", "[a]"] + encodeArgs(for: "m4a", hasVideo: false)
        }
        args.append(out.path)
        let total = urls.compactMap { FFmpeg.duration(of: $0) }.reduce(0, +)
        try await FFmpeg.run(args, duration: total, job: job)
        return out
    }

    static func audioFilter(_ url: URL, filter: String, suffix: String, job: Job?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, ext: ext, suffix: suffix)
        var args = ["-i", url.path, "-af", filter]
        if FFmpeg.hasVideoStream(url) { args += ["-c:v", "copy"] }
        args += audioCodec(for: ext)
        args.append(out.path)
        try await FFmpeg.run(args, duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    /// Replaces a time range with a 1 kHz beep (for censoring words).
    static func bleep(_ url: URL, start: Double, end: Double, job: Job?) async throws -> URL {
        guard end > start else { throw ClementineError("La fine deve essere dopo l'inizio") }
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, ext: ext, suffix: "-bleep")
        let enable = "between(t,\(start),\(end))"
        let filter = "[0:a]volume=enable='\(enable)':volume=0[muted];" +
            "sine=f=1000:d=\(end + 1),volume=0.3,volume=enable='not(\(enable))':volume=0[tone];" +
            "[muted][tone]amix=inputs=2:duration=first:normalize=0[a]"
        var args = ["-i", url.path, "-filter_complex", filter, "-map", "[a]"]
        if FFmpeg.hasVideoStream(url) { args += ["-map", "0:v", "-c:v", "copy"] }
        args += audioCodec(for: ext) + [out.path]
        try await FFmpeg.run(args, duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    static func audioCodec(for ext: String) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "aif", "aiff": return ["-c:a", "pcm_s16be"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libvorbis", "-q:a", "5"]
        case "opus", "webm": return ["-c:a", "libopus", "-b:a", "128k"]
        default: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    static func metadataText(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        var lines: [String] = []
        if let d = try? await asset.load(.duration), d.isNumeric {
            lines.append("Durata: \(String(format: "%.2f", d.seconds)) s")
        }
        if let tracks = try? await asset.load(.tracks) {
            for t in tracks {
                var line = "Traccia \(t.mediaType.rawValue)"
                if let size = try? await t.load(.naturalSize), size != .zero { line += " \(Int(size.width))×\(Int(size.height))" }
                if let rate = try? await t.load(.estimatedDataRate), rate > 0 { line += " \(Int(rate / 1000)) kbps" }
                if let fps = try? await t.load(.nominalFrameRate), fps > 0 { line += " \(String(format: "%.2f", fps)) fps" }
                lines.append(line)
            }
        }
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "?"
                if let v = try? await item.load(.stringValue) { lines.append("\(key): \(v)") }
            }
        }
        return lines.isEmpty ? "Nessun metadato leggibile." : lines.joined(separator: "\n")
    }

    static func stripMetadata(_ url: URL, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: "-senza-metadati")
        try await FFmpeg.run(["-i", url.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1",
                              "-c", "copy", out.path], job: job)
        return out
    }

    static func setTitle(_ url: URL, title: String, artist: String, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: "-modificato")
        var args = ["-i", url.path, "-map", "0", "-c", "copy"]
        if !title.isEmpty { args += ["-metadata", "title=\(title)"] }
        if !artist.isEmpty { args += ["-metadata", "artist=\(artist)"] }
        args.append(out.path)
        try await FFmpeg.run(args, job: job)
        return out
    }
}

// MARK: - Extra tools (visualizer, silence, channels, frames, redaction)

extension MediaTools {
    /// Turns audio into a video with an animated waveform over a color or image background.
    static func visualizer(_ url: URL, style: String, color: String, background: URL?, portrait: Bool, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: "mp4", suffix: "-visualizzazione")
        let (w, h) = portrait ? (1080, 1920) : (1920, 1080)
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        let wave: String
        switch style {
        case "barre": wave = "showfreqs=s=\(w)x\(h / 2):mode=bar:cmode=combined:colors=0x\(hex)"
        case "spettro": wave = "showspectrum=s=\(w)x\(h / 2):mode=combined:color=intensity:slide=scroll"
        default: wave = "showwaves=s=\(w)x\(h / 2):mode=cline:rate=30:colors=0x\(hex)"
        }
        var args: [String]
        let filter: String
        if let bg = background {
            args = ["-loop", "1", "-i", bg.path, "-i", url.path]
            filter = "[0:v]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h)[bg];[1:a]\(wave),format=rgba,colorkey=0x000000:0.1:0.0[w];[bg][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
            args += ["-filter_complex", filter, "-map", "[v]", "-map", "1:a"]
        } else {
            args = ["-f", "lavfi", "-i", "color=c=0x111111:s=\(w)x\(h):r=30", "-i", url.path]
            filter = "[1:a]\(wave),format=rgba,colorkey=0x000000:0.1:0.0[w];[0:v][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
            args += ["-filter_complex", filter, "-map", "[v]", "-map", "1:a"]
        }
        args += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-shortest", out.path]
        try await FFmpeg.run(args, duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    /// Removes silence at the start and end (threshold in dB, e.g. -45).
    static func trimSilence(_ url: URL, thresholdDB: Double, job: Job?) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, ext: ext, suffix: "-senza-silenzi")
        let t = "\(Int(thresholdDB))dB"
        let filter = "silenceremove=start_periods=1:start_threshold=\(t):start_silence=0.1," +
            "areverse,silenceremove=start_periods=1:start_threshold=\(t):start_silence=0.1,areverse"
        var args = ["-i", url.path, "-af", filter]
        if FFmpeg.hasVideoStream(url) { args += ["-vn"] }
        args += audioCodec(for: ext) + [out.path]
        try await FFmpeg.run(args, duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    /// Mono/stereo output with independent left/right volume (percent).
    static func channels(_ url: URL, layout: String, left: Double, right: Double, job: Job?) async throws -> URL {
        let l = max(0, left) / 100, r = max(0, right) / 100
        let filter = layout == "mono"
            ? "pan=mono|c0=\(l * 0.5)*c0+\(r * 0.5)*c1"
            : "aformat=channel_layouts=stereo,pan=stereo|c0=\(l)*c0|c1=\(r)*c1"
        return try await audioFilter(url, filter: filter, suffix: layout == "mono" ? "-mono" : "-canali", job: job)
    }

    /// Saves frames every `interval` seconds (or the listed timestamps) into a folder.
    static func frames(_ url: URL, interval: Double, times: [Double], job: Job?) async throws -> [URL] {
        let folder = Output.folder(for: url, suffix: "-fotogrammi")
        let base = url.deletingPathExtension().lastPathComponent
        if !times.isEmpty {
            for (i, t) in times.enumerated() {
                job?.report(Double(i) / Double(times.count))
                let dest = folder.appendingPathComponent(String(format: "%@ - %03d - %.2fs.png", base, i + 1, t))
                try await FFmpeg.run(["-ss", String(t), "-i", url.path, "-frames:v", "1", dest.path])
            }
        } else {
            let fps = 1 / max(0.04, interval)
            try await FFmpeg.run(["-i", url.path, "-vf", "fps=\(fps)", folder.appendingPathComponent(base + " - %04d.png").path],
                                 duration: FFmpeg.duration(of: url), job: job)
        }
        return [folder]
    }

    /// Splits at the given timestamps into separate clips (re-encoded for exact cuts).
    static func split(_ url: URL, at points: [Double], job: Job?) async throws -> [URL] {
        let sorted = points.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { throw ClementineError("Indica almeno un punto di taglio") }
        let folder = Output.folder(for: url, suffix: "-parti")
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        let bounds = [0] + sorted + [Double.infinity]
        let hasVideo = FFmpeg.hasVideoStream(url)
        for i in 0..<(bounds.count - 1) {
            job?.report(Double(i) / Double(bounds.count - 1), "Parte \(i + 1) di \(bounds.count - 1)")
            var args = ["-ss", String(bounds[i]), "-i", url.path]
            if bounds[i + 1].isFinite { args += ["-t", String(bounds[i + 1] - bounds[i])] }
            args += encodeArgs(for: ext, hasVideo: hasVideo)
            args.append(folder.appendingPathComponent(String(format: "%@-%02d.%@", base, i + 1, ext)).path)
            try await FFmpeg.run(args)
        }
        return [folder]
    }

    /// Hides rectangles (normalized 0...1, origin bottom-left) for the whole video or a time range.
    static func redact(_ url: URL, rects: [(CGRect, Bool)], start: Double, end: Double, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: "mp4", suffix: "-oscurato")
        let enable = end > start ? ":enable='between(t,\(start),\(end))'" : ""
        var chain = "[0:v]null[v0]"
        for (i, item) in rects.enumerated() {
            let (r, solid) = item
            // ffmpeg uses a top-left origin.
            let x = "iw*\(r.minX)", y = "ih*\(1 - r.maxY)", w = "iw*\(r.width)", h = "ih*\(r.height)"
            if solid {
                chain += ";[v\(i)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill\(enable)[v\(i + 1)]"
            } else {
                chain += ";[v\(i)]split[a\(i)][b\(i)];[b\(i)]crop=\(w):\(h):\(x):\(y),boxblur=20:4[blur\(i)];" +
                    "[a\(i)][blur\(i)]overlay=\(x):\(y)\(enable)[v\(i + 1)]"
            }
        }
        let args = ["-i", url.path, "-filter_complex", chain, "-map", "[v\(rects.count)]", "-map", "0:a?",
                    "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "copy", out.path]
        try await FFmpeg.run(args, duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    /// Crop with a rectangle drawn in the editor (normalized, origin bottom-left).
    static func crop(_ url: URL, rect r: CGRect, job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: "mp4", suffix: "-ritagliato")
        let filter = "crop=trunc(iw*\(r.width)/2)*2:trunc(ih*\(r.height)/2)*2:iw*\(r.minX):ih*\(1 - r.maxY)"
        try await FFmpeg.run(["-i", url.path, "-vf", filter] + encodeArgs(for: "mp4", hasVideo: true) + [out.path],
                             duration: FFmpeg.duration(of: url), job: job)
        return out
    }

    /// First frame (at `seconds`) as an image, for the editor.
    static func frameImage(_ url: URL, at seconds: Double) async throws -> CGImage {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await FFmpeg.run(["-ss", String(seconds), "-i", url.path, "-frames:v", "1", tmp.path])
        return try ImageTools.load(tmp)
    }

    static func setTags(_ url: URL, tags: [String: String], job: Job?) async throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: "-modificato")
        var args = ["-i", url.path, "-map", "0", "-c", "copy"]
        for (k, v) in tags.sorted(by: { $0.key < $1.key }) where !v.isEmpty { args += ["-metadata", "\(k)=\(v)"] }
        args.append(out.path)
        try await FFmpeg.run(args, job: job)
        return out
    }
}

extension MediaTools {
    /// Covers several time ranges with a 1 kHz tone.
    static func bleep(_ url: URL, ranges: [TimeRange], job: Job?) async throws -> URL {
        let valid = ranges.filter { $0.end > $0.start }
        guard !valid.isEmpty else { throw ClementineError("Aggiungi almeno un tratto da coprire") }
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, ext: ext, suffix: "-bleep")
        let inside = valid.map { "between(t,\($0.start),\($0.end))" }.joined(separator: "+")
        let total = (FFmpeg.duration(of: url) ?? (valid.map(\.end).max() ?? 0)) + 1
        let filter = "[0:a]volume=enable='\(inside)':volume=0[muted];" +
            "sine=f=1000:d=\(total),volume=0.3,volume=enable='not(\(inside))':volume=0[tone];" +
            "[muted][tone]amix=inputs=2:duration=first:normalize=0[a]"
        var args = ["-i", url.path, "-filter_complex", filter, "-map", "[a]"]
        if FFmpeg.hasVideoStream(url) { args += ["-map", "0:v", "-c:v", "copy"] }
        args += audioCodec(for: ext) + [out.path]
        try await FFmpeg.run(args, duration: FFmpeg.duration(of: url), job: job)
        return out
    }
}
