import AppKit
import CoreMedia
import CoreVideo
import Foundation
import IOKit.pwr_mgt

/// Ties capture -> encoder -> helper together for one streaming session.
final class StreamController {
    let bridge: HelperBridge
    /// Feed a synthetic moving picture instead of the screen (`--test-pattern`).
    var useTestPattern = false
    /// Latest stats for the menu (main queue).
    var onStats: (([String: Any]) -> Void)?

    private let videoQueue = DispatchQueue(label: "video", qos: .userInteractive)
    private lazy var capture = ScreenCapture(queue: videoQueue)
    private lazy var encoder = VideoEncoder(queue: videoQueue, bitrateKbps: Settings.shared.bitrateKbps, fps: Settings.shared.fps)
    private var testPattern: TestPattern?
    let audioCapture = AudioCapture()
    private let audioEncoder = AudioEncoder()
    private var audioBytes = 0 // guarded by statsLock
    private var statsCount = 0

    private(set) var active = false
    /// Host cursor drawn into the video: on in camera mode, off in menu mode
    /// (the client then shows its own, zero-latency cursor).
    private var showsCursor = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameTime = CFAbsoluteTime(0)
    private var idleTimer: DispatchSourceTimer?
    private var statsTimer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var lastError: String?
    private var screenObserver: NSObjectProtocol?

    // Stats (guarded by statsLock; written from video queue and VT callback thread).
    private let statsLock = NSLock()
    private var capFrames = 0
    private var encFrames = 0
    private var encMsSum = 0.0
    private var encBytes = 0

    init(bridge: HelperBridge) {
        self.bridge = bridge
    }

    // MARK: Session lifecycle (main queue)

    func startSession() {
        guard !active else {
            requestKeyframe()
            return
        }
        active = true
        lastError = nil
        Log.info("session start")
        preventSleep(true)

        encoder.onOutput = { [weak self] out in
            guard let self else { return }
            self.statsLock.lock()
            self.encFrames += 1
            self.encMsSum += out.encodeMs
            self.encBytes += out.annexB.count
            self.statsLock.unlock()
            self.bridge.sendVideo(out.annexB, ptsMicros: out.ptsMicros, keyframe: out.keyframe,
                                  encodeMicros: UInt32(max(0, min(out.encodeMs * 1000, 4e9))))
        }
        capture.onFrame = { [weak self] pb, pts in self?.handleFrame(pb, pts) }
        capture.onError = { [weak self] err in
            DispatchQueue.main.async { self?.captureFailed(err) }
        }

        startSource()
        startAudio()
        startIdleTimer()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.publishStats() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.active, !self.useTestPattern else { return }
            Log.info("screen parameters changed, restarting capture")
            self.startSource()
        }
    }

    func stopSession() {
        guard active else { return }
        active = false
        showsCursor = true
        Log.info("session stop")
        statsTimer?.invalidate()
        statsTimer = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        idleTimer?.cancel()
        idleTimer = nil
        testPattern?.stop()
        testPattern = nil
        audioCapture.stop()
        Task { await capture.stop() }
        videoQueue.async { [weak self] in
            self?.encoder.invalidate()
            self?.lastPixelBuffer = nil
        }
        preventSleep(false)
        onStats?([:])
    }

    func requestKeyframe() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.encoder.requestKeyframe()
            // If the screen is static no new frame may come; re-encode the last one.
            self.videoQueue.asyncAfter(deadline: .now() + 0.05) {
                if CFAbsoluteTimeGetCurrent() - self.lastFrameTime > 0.04 { self.reencodeLast() }
            }
        }
    }

    func setShowsCursor(_ show: Bool) {
        guard show != showsCursor else { return }
        showsCursor = show
        if active && !useTestPattern { capture.setShowsCursor(show, fps: Settings.shared.fps) }
    }

    func setFPS(_ fps: Int) {
        Settings.shared.fps = fps
        videoQueue.async { [weak self] in self?.encoder.setFPS(fps) }
        Log.info("fps -> \(fps)")
        if active && !useTestPattern { startSource() }
    }

    func setBitrate(kbps: Int) {
        Settings.shared.bitrateKbps = kbps
        videoQueue.async { [weak self] in self?.encoder.setBitrate(kbps: kbps) }
        Log.info("bitrate -> \(kbps) kbps")
    }

    // MARK: Audio

    private func startAudio() {
        let enc = audioEncoder
        audioCapture.queue.async { enc.reset() }
        enc.onPacket = { [weak self] packet, samples in
            guard let self else { return }
            self.statsLock.lock()
            self.audioBytes += packet.count
            self.statsLock.unlock()
            let pts = UInt64(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000)
            self.bridge.sendAudio(packet, ptsMicros: pts, samples: UInt16(samples))
        }
        audioCapture.onSamples = { sb in enc.feed(sb) }
        audioCapture.start()
    }

    // MARK: Sources

    private func startSource() {
        if useTestPattern {
            if testPattern == nil {
                let tp = TestPattern(queue: videoQueue, fps: Settings.shared.fps)
                tp.onFrame = { [weak self] pb, pts in self?.handleFrame(pb, pts) }
                tp.start()
                testPattern = tp
            }
            return
        }
        Task { @MainActor in
            do {
                let cursor = showsCursor
                try await capture.start(fps: Settings.shared.fps, showsCursor: cursor)
                lastError = nil
                // The client may have switched mouse mode while capture was starting.
                if showsCursor != cursor { capture.setShowsCursor(showsCursor, fps: Settings.shared.fps) }
            } catch {
                captureFailed(error)
            }
        }
    }

    private func captureFailed(_ error: Error) {
        guard active else { return }
        let ns = error as NSError
        Log.info("capture error: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        if !CGPreflightScreenCaptureAccess() {
            lastError = L("на Маке не выдано разрешение «Запись экрана»", "Screen Recording permission is not granted on the Mac")
        } else {
            lastError = L("захват экрана", "screen capture") + ": \(ns.localizedDescription)"
        }
        publishStats()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.active else { return }
            self.startSource()
        }
    }

    // MARK: Video queue

    private func handleFrame(_ pb: CVPixelBuffer, _ pts: CMTime) {
        lastPixelBuffer = pb
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        statsLock.lock()
        capFrames += 1
        statsLock.unlock()
        encoder.encode(pb, pts: pts)
    }

    private func reencodeLast() {
        guard active, let pb = lastPixelBuffer else { return }
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        encoder.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// ScreenCaptureKit sends nothing while the screen is static. Repeat the last
    /// frame twice a second so the browser keeps a live stream.
    private func startIdleTimer() {
        let t = DispatchSource.makeTimerSource(queue: videoQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if CFAbsoluteTimeGetCurrent() - self.lastFrameTime > 0.5 { self.reencodeLast() }
        }
        t.resume()
        idleTimer = t
    }

    // MARK: Stats & power

    private func publishStats() {
        statsLock.lock()
        let cap = capFrames, enc = encFrames, ms = encMsSum, bytes = encBytes, aBytes = audioBytes
        capFrames = 0; encFrames = 0; encMsSum = 0; encBytes = 0; audioBytes = 0
        statsLock.unlock()
        let audioEnc = audioEncoder
        let peak = audioCapture.queue.sync { audioEnc.takePeak() }
        var st: [String: Any] = [
            "capFps": cap,
            "encFps": enc,
            "encMs": enc > 0 ? (ms / Double(enc) * 10).rounded() / 10 : 0,
            "kbps": bytes * 8 / 1000,
            "targetKbps": Settings.shared.bitrateKbps,
            "w": Int(capture.size.width),
            "h": Int(capture.size.height),
            "audioKbps": aBytes * 8 / 1000,
            "audioPeakDb": peak > 0 ? Int((20 * log10(peak)).rounded()) : -120,
            "audioSrc": audioCapture.capturedNames.isEmpty ? "—" : audioCapture.capturedNames.joined(separator: ", "),
        ]
        if let e = lastError { st["err"] = e }
        statsCount += 1
        if statsCount % 5 == 0 {
            Log.info("audio: \(st["audioSrc"] ?? "—"), \(aBytes * 8 / 1000) kbps, peak \(st["audioPeakDb"] ?? -120) dB")
        }
        bridge.sendStats(st)
        onStats?(st)
    }

    private func preventSleep(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "GameStreamer: streaming" as CFString, &sleepAssertion)
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}

/// Synthetic 1080p NV12 source: moving bars + a frame counter strip, for testing
/// the pipeline without Screen Recording permission.
final class TestPattern {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private let queue: DispatchQueue
    private let fps: Int
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var n = 0
    private let w = 1920, h = 1080

    init(queue: DispatchQueue, fps: Int) {
        self.queue = queue
        self.fps = fps
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        guard let pool else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        let barX = (n * 12) % w
        for row in 0..<h {
            let line = y + row * yStride
            memset(line, Int32(16 + (row * 200 / h)), w)            // vertical gradient
            let bx = (barX + row / 4) % (w - 120)
            memset(line + bx, 235, 120)                               // moving diagonal bar
        }
        // binary frame counter strip at the top: 32 blocks, white = 1
        for bit in 0..<32 {
            let on = (n >> bit) & 1 == 1
            for row in 20..<60 { memset(y + row * yStride + 40 + bit * 56, on ? 235 : 16, 48) }
        }
        for row in 0..<(h / 2) {
            let line = uv + row * uvStride
            for col in stride(from: 0, to: w, by: 2) {
                line[col] = UInt8(128 + (col * 60 / w))
                line[col + 1] = UInt8(128 - (row * 60 / (h / 2)))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        n += 1
        onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
