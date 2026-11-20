import CoreMedia
import QuartzCore
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for latency (Apple low-latency rate control,
/// Constrained Baseline, no frame reordering, real-time).
/// All methods must be called on `queue`.
final class VideoEncoder {
    struct Output {
        let annexB: Data
        let ptsMicros: UInt64
        let keyframe: Bool
        let encodeMs: Double
    }

    let queue: DispatchQueue
    var onOutput: ((Output) -> Void)?

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private(set) var bitrateKbps: Int
    private var fps: Int
    private var forceKeyframe = true
    private var lastPTS = CMTime.zero

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(queue: DispatchQueue, bitrateKbps: Int, fps: Int) {
        self.queue = queue
        self.bitrateKbps = bitrateKbps
        self.fps = fps
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
        width = 0
        height = 0
    }

    func requestKeyframe() { forceKeyframe = true }

    /// New frame rate; the session is recreated on the next frame.
    func setFPS(_ f: Int) {
        guard f != fps else { return }
        fps = f
        invalidate()
    }

    func setBitrate(kbps: Int) {
        bitrateKbps = kbps
        if let s = session { applyBitrate(s) }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts inPTS: CMTime) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || w != width || h != height {
            invalidate()
            guard createSession(width: w, height: h) else { return }
        }
        guard let session else { return }

        // VideoToolbox requires strictly increasing timestamps.
        var pts = inPTS
        if CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        }
        lastPTS = pts

        var props: CFDictionary?
        let key = forceKeyframe
        if key {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }

        let started = CACurrentMediaTime()
        let ptsMicros = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer else {
                if status != noErr { Log.info("encode callback error \(status)") }
                return
            }
            let ms = (CACurrentMediaTime() - started) * 1000
            if let out = Self.toAnnexB(sampleBuffer, ptsMicros: ptsMicros, encodeMs: ms) {
                self.onOutput?(out)
            }
        }
        if status != noErr {
            Log.info("VTCompressionSessionEncodeFrame failed: \(status)")
            if key { forceKeyframe = true }
            if status == kVTInvalidSessionErr { invalidate() }
        }
    }

    // MARK: - Session setup

    private func createSession(width w: Int, height h: Int) -> Bool {
        // GS_ENC_* environment variables are for latency A/B tests only.
        let env = ProcessInfo.processInfo.environment
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        if env["GS_ENC_LLRC"] != "0" { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else {
            Log.info("VTCompressionSessionCreate failed: \(st)")
            return false
        }

        func set(_ key: CFString, _ value: CFTypeRef, _ name: String) {
            let r = VTSessionSetProperty(s, key: key, value: value)
            if r != noErr { Log.info("encoder: \(name) not supported (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        set(kVTCompressionPropertyKey_ProfileLevel,
            env["GS_ENC_PROFILE"] == "high" ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
            "ProfileLevel")
        if let d = env["GS_ENC_MAXDELAY"], let n = Int(d) {
            set(kVTCompressionPropertyKey_MaxFrameDelayCount, n as CFNumber, "MaxFrameDelayCount")
        }
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber, "ExpectedFrameRate")
        // Rare periodic keyframes; loss recovery is driven by PLI from the browser.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 60) as CFNumber, "MaxKeyFrameInterval")
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60 as CFNumber, "MaxKeyFrameIntervalDuration")
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, "PrioritizeEncodingSpeedOverQuality")
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse, "MaximizePowerEfficiency")
        applyBitrate(s)

        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        width = w
        height = h
        forceKeyframe = true
        Log.info("encoder ready: \(w)x\(h)@\(fps) \(bitrateKbps) kbps")
        return true
    }

    private func applyBitrate(_ s: VTCompressionSession) {
        let bps = bitrateKbps * 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Cap bursts at ~1.5x target over 1s so keyframes don't flood the link.
        let limits = [Double(bps) * 1.5 / 8, 1.0] as CFArray
        let r = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        if r != noErr { Log.info("encoder: DataRateLimits not supported (\(r))") }
    }

    // MARK: - AVCC -> Annex-B

    private static func toAnnexB(_ sb: CMSampleBuffer, ptsMicros: UInt64, encodeMs: Double) -> Output? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var keyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        var out = Data()
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            var nalHeaderLen: Int32 = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: startCode)
                    out.append(ptr, count: size)
                }
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else {
            return nil
        }
        out.reserveCapacity(out.count + total + 16)
        var off = 0
        while off + 4 <= total {
            let n = Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            off += 4
            guard n > 0, off + n <= total else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[off..<(off + n)])
            off += n
        }
        return Output(annexB: out, ptsMicros: ptsMicros, keyframe: keyframe, encodeMs: encodeMs)
    }
}
