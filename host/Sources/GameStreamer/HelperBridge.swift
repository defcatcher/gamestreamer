import CoreMedia
import Foundation

/// Runs the Go helper (Contents/MacOS/gs-helper) and exchanges framed messages
/// with it over stdin/stdout: [type u8][length u32 BE][payload].
final class HelperBridge {
    enum Out: UInt8 { case config = 1, video = 2, audio = 3, stats = 4, toClient = 5 }
    enum In: UInt8 { case event = 1, input = 2 }

    /// Called on the main queue.
    var onEvent: (([String: Any]) -> Void)?
    /// Called on the reader thread (input must not wait for the main queue).
    var onInput: ((Data) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "helper.write", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingVideo = 0
    private var readBuffer = Data()
    private var stopping = false

    func start() {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "gs-helper") else {
            Log.info("gs-helper not found in app bundle")
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = ["--port", String(Settings.shared.port)]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                Log.info("[helper] \(line)")
            }
        }
        readBuffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] proc in
            Log.info("helper exited with status \(proc.terminationStatus)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, !self.stopping else { return }
                self.onEvent?(["t": "disconnected", "reason": "helper restart"])
                self.start()
            }
        }
        do {
            try p.run()
        } catch {
            Log.info("failed to start helper: \(error)")
            return
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        Log.info("helper started, pid \(p.processIdentifier)")
        sendConfig()
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    func sendConfig() {
        let cfg: [String: Any] = ["pin": Settings.shared.pin]
        if let data = try? JSONSerialization.data(withJSONObject: cfg) {
            send(.config, data)
        }
    }

    func sendStats(_ stats: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: stats) {
            send(.stats, data)
        }
    }

    /// JSON message delivered as-is to the viewer's control channel.
    func sendToClient(_ msg: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            send(.toClient, data)
        }
    }

    /// Video: [pts µs u64][flags u8][Annex-B]. Drops delta frames if the helper falls behind.
    /// Wall clock (µs since 1970) minus host clock (CMClock host time, µs).
    private static let wallMinusHostMicros: Double = {
        Date().timeIntervalSince1970 * 1_000_000 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000
    }()

    /// Video: [pts µs u64][flags u8][capture wall-clock µs u64][encode µs u32][Annex-B].
    func sendVideo(_ annexB: Data, ptsMicros: UInt64, keyframe: Bool, encodeMicros: UInt32 = 0) {
        pendingLock.lock()
        if pendingVideo >= 4 && !keyframe {
            pendingLock.unlock()
            return
        }
        pendingVideo += 1
        pendingLock.unlock()

        var payload = Data(capacity: annexB.count + 21)
        var be = ptsMicros.bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
        payload.append(keyframe ? 1 : 0)
        var wall = UInt64(max(0, Double(ptsMicros) + Self.wallMinusHostMicros)).bigEndian
        withUnsafeBytes(of: &wall) { payload.append(contentsOf: $0) }
        var enc = encodeMicros.bigEndian
        withUnsafeBytes(of: &enc) { payload.append(contentsOf: $0) }
        payload.append(annexB)
        send(.video, payload) { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            self.pendingVideo -= 1
            self.pendingLock.unlock()
        }
    }

    /// Audio: [pts µs u64][samples u16][Opus packet].
    func sendAudio(_ packet: Data, ptsMicros: UInt64, samples: UInt16) {
        var payload = Data(capacity: packet.count + 10)
        var be = ptsMicros.bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
        var s = samples.bigEndian
        withUnsafeBytes(of: &s) { payload.append(contentsOf: $0) }
        payload.append(packet)
        send(.audio, payload)
    }

    private func send(_ type: Out, _ payload: Data, completion: (() -> Void)? = nil) {
        writeQueue.async { [weak self] in
            defer { completion?() }
            guard let h = self?.stdinHandle else { return }
            var header = Data(count: 5)
            header[0] = type.rawValue
            let n = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: n) { header.replaceSubrange(1..<5, with: $0) }
            do {
                try h.write(contentsOf: header)
                try h.write(contentsOf: payload)
            } catch {
                // helper died; the termination handler restarts it
            }
        }
    }

    // Runs on the stdout reader thread.
    private func consume(_ data: Data) {
        readBuffer.append(data)
        while readBuffer.count >= 5 {
            let base = readBuffer.startIndex
            let type = readBuffer[base]
            let len = Int(readBuffer[base + 1]) << 24 | Int(readBuffer[base + 2]) << 16
                | Int(readBuffer[base + 3]) << 8 | Int(readBuffer[base + 4])
            guard readBuffer.count >= 5 + len else { break }
            let payload = readBuffer.subdata(in: (base + 5)..<(base + 5 + len))
            readBuffer.removeSubrange(base..<(base + 5 + len))

            switch In(rawValue: type) {
            case .event:
                if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(obj) }
                }
            case .input:
                onInput?(payload)
            case .none:
                Log.info("unknown helper message type \(type)")
            }
        }
    }
}
