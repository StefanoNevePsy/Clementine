import Foundation

/// Thin wrapper around an `ffmpeg` executable (bundled in the app or installed with Homebrew).
enum FFmpeg {
    static let path: String? = {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path { candidates.append(res) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { path != nil }

    static func requirePath() throws -> String {
        guard let path else {
            throw ClementineError("Per questo formato serve ffmpeg. Installalo dal Terminale con: brew install ffmpeg")
        }
        return path
    }

    /// Duration in seconds, read from ffmpeg's banner ("Duration: 00:01:02.33").
    static func duration(of url: URL) -> Double? {
        guard let path else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-i", url.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return parseTime(after: "Duration: ", in: text)
    }

    static func hasVideoStream(_ url: URL) -> Bool {
        guard let path else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-i", url.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return true }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // Cover art in audio files shows up as an attached_pic video stream.
        return text.components(separatedBy: "\n").contains { $0.contains("Video:") && !$0.contains("attached pic") }
    }

    /// Runs ffmpeg with `args` (input/output included). Reports progress against `duration` if known.
    static func run(_ args: [String], duration: Double? = nil, job: Job? = nil) async throws {
        let path = try requirePath()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-hide_banner", "-nostdin", "-y"] + args
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = FileHandle.nullDevice
            var log = ""
            let lock = NSLock()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = String(decoding: h.availableData, as: UTF8.self)
                lock.lock(); log += chunk; if log.count > 20000 { log = String(log.suffix(8000)) }; lock.unlock()
                if let d = duration, d > 0, let t = parseTime(after: "time=", in: chunk, last: true) {
                    job?.report(t / d)
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    lock.lock(); let tail = log.split(separator: "\n").suffix(3).joined(separator: "\n"); lock.unlock()
                    cont.resume(throwing: ClementineError("ffmpeg non è riuscito a convertire il file.\n\(tail)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private static func parseTime(after marker: String, in text: String, last: Bool = false) -> Double? {
        let ranges = text.allRanges(of: marker)
        guard let r = last ? ranges.last : ranges.first else { return nil }
        let rest = text[r.upperBound...].prefix(11)   // HH:MM:SS.xx
        let parts = rest.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2].prefix(5)) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

private extension String {
    func allRanges(of needle: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = startIndex
        while let r = range(of: needle, range: start..<endIndex) {
            result.append(r)
            start = r.upperBound
        }
        return result
    }
}
