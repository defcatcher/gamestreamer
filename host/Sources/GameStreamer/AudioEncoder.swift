import AudioToolbox
import CoreMedia
import Foundation

/// 48 kHz stereo float PCM -> Opus, 10 ms packets (480 samples), via AudioToolbox.
/// Not thread-safe: call from one queue.
final class AudioEncoder {
    static let frameSamples = 480 // 10 ms

    /// (opus packet, number of samples it covers)
    var onPacket: ((Data, Int) -> Void)?

    private var converter: AudioConverterRef?
    private var fifo: [Float] = []        // interleaved L R L R ...
    private var chunk = [Float](repeating: 0, count: AudioEncoder.frameSamples * 2)
    private var out = [UInt8](repeating: 0, count: 1500)
    private var warnedFormat = false
    /// Peak absolute sample value since the last `takePeak()` (for stats).
    private var peak: Float = 0

    func takePeak() -> Float {
        let p = peak
        peak = 0
        return p
    }

    init(bitrate: UInt32 = 128_000) {
        var inFmt = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSamples), mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let st = AudioConverterNew(&inFmt, &outFmt, &converter)
        if st != noErr {
            Log.info("Opus encoder init failed: \(st)")
            return
        }
        var br = bitrate
        AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate, 4, &br)
        Log.info("Opus encoder ready: 48 kHz stereo, 10 ms, \(bitrate / 1000) kbps")
    }

    deinit {
        if let c = converter { AudioConverterDispose(c) }
    }

    func reset() {
        fifo.removeAll(keepingCapacity: true)
        if let c = converter { AudioConverterReset(c) }
    }

    /// Feed a ScreenCaptureKit audio sample buffer.
    func feed(_ sb: CMSampleBuffer) {
        guard converter != nil,
              let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            if !warnedFormat { warnedFormat = true; Log.info("unexpected audio format: \(asbd)") }
            return
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { ablRaw.deallocate() }
        let abl = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
        else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)

        fifo.reserveCapacity(fifo.count + frames * 2)
        if nonInterleaved {
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
            for i in 0..<frames {
                fifo.append(l[i])
                fifo.append(r[i])
            }
        } else {
            guard let p = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<frames {
                fifo.append(p[i * channels])
                fifo.append(channels > 1 ? p[i * channels + 1] : p[i * channels])
            }
        }

        let need = Self.frameSamples * 2
        let start = max(0, fifo.count - frames * 2)
        for i in start..<fifo.count { peak = max(peak, abs(fifo[i])) }
        var offset = 0
        while fifo.count - offset >= need {
            chunk.withUnsafeMutableBufferPointer { dst in
                fifo.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + offset, count: need)
                }
            }
            offset += need
            encodeChunk()
        }
        if offset > 0 { fifo.removeFirst(offset) }
        // Never let latency pile up if the encoder falls behind.
        if fifo.count > need * 10 { fifo.removeFirst(fifo.count - need * 2) }
    }

    private final class Input {
        var ptr: UnsafeMutableRawPointer?
        var bytes: Int = 0
        var consumed = false
    }

    private func encodeChunk() {
        guard let converter else { return }
        var ioPackets: UInt32 = 1
        var desc = AudioStreamPacketDescription()
        let status: OSStatus = chunk.withUnsafeMutableBytes { pcm in
            out.withUnsafeMutableBytes { ob in
                var outList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(ob.count), mData: ob.baseAddress))
                let input = Input()
                input.ptr = pcm.baseAddress
                input.bytes = pcm.count
                let ctx = Unmanaged.passRetained(input)
                defer { ctx.release() }
                return AudioConverterFillComplexBuffer(converter, { _, ioNumPackets, ioData, _, userData in
                    let inp = Unmanaged<Input>.fromOpaque(userData!).takeUnretainedValue()
                    if inp.consumed {
                        ioNumPackets.pointee = 0
                        return 1 // "no more data for now"
                    }
                    inp.consumed = true
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mData = inp.ptr
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(inp.bytes)
                    ioData.pointee.mBuffers.mNumberChannels = 2
                    ioNumPackets.pointee = UInt32(inp.bytes / 8)
                    return noErr
                }, ctx.toOpaque(), &ioPackets, &outList, &desc)
            }
        }
        guard status == noErr || status == 1, ioPackets > 0, desc.mDataByteSize > 0 else { return }
        let packet = Data(out[Int(desc.mStartOffset)..<Int(desc.mStartOffset) + Int(desc.mDataByteSize)])
        onPacket?(packet, Self.frameSamples)
    }
}
