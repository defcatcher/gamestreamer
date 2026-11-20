import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the main display with ScreenCaptureKit and hands NV12 frames
/// to `onFrame` on `queue`.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue: DispatchQueue
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private(set) var size = CGSize.zero

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(fps: Int, showsCursor: Bool) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "GameStreamer", code: 1, userInfo: [NSLocalizedDescriptionKey: L("нет дисплея", "no display")])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let w = Int((filter.contentRect.width * scale).rounded())
        let h = Int((filter.contentRect.height * scale).rounded())

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.itur_709
        cfg.queueDepth = 5
        cfg.showsCursor = showsCursor
        cfg.capturesAudio = false
        cfg.scalesToFit = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        size = CGSize(width: w, height: h)
        Log.info("capture started: display \(display.displayID) \(w)x\(h)@\(fps) cursor=\(showsCursor)")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        do { try await s.stopCapture() } catch { Log.info("stopCapture: \(error)") }
        Log.info("capture stopped")
    }

    func setShowsCursor(_ show: Bool, fps: Int) {
        guard let s = stream else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.itur_709
        cfg.queueDepth = 5
        cfg.showsCursor = show
        s.updateConfiguration(cfg) { err in
            if let err { Log.info("updateConfiguration: \(err)") }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = sb.imageBuffer
        else { return }
        onFrame?(pb, sb.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped with error: \(error)")
        if self.stream === stream { self.stream = nil }
        onError?(error)
    }
}
