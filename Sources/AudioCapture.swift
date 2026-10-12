import AVFoundation

/// 采集麦克风 → 16 kHz / 单声道 / 16-bit PCM,按回调把字节交出去。
/// 后台音频模式来自 Info.plist 的 UIBackgroundModes=audio;锁屏后系统继续喂 tap。
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: true)!
    private let queue = DispatchQueue(label: "meetingvoice.audio")
    private(set) var isRunning = false

    /// 每块 16 kHz 单声道 Int16 数据
    var onChunk: ((Data) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers:不打断别的声音(在线会议时我们只想录,不想静音对方)
        try session.setCategory(.playAndRecord,
                               mode: .default,
                               options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let conv = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风格式不可用(采样率 \(inFormat.sampleRate) / 声道 \(inFormat.channelCount))"])
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // tap 给的 buffer 出了回调就可能被系统复用/回收 —— 必须当场复制一份再拿去做后台转换
            guard let copy = AudioCapture.copyOf(buffer) else { return }
            self.queue.async { self.convertAndEmit(copy) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 把 tap 的 buffer 复制一份(按它自己的常见格式复制)
    private static func copyOf(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard src.frameLength > 0,
              let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        dst.frameLength = src.frameLength
        let ch = Int(src.format.channelCount)
        let frames = Int(src.frameLength)
        if let s = src.floatChannelData, let d = dst.floatChannelData {
            for i in 0..<ch { memcpy(d[i], s[i], frames * MemoryLayout<Float>.size) }
        } else if let s = src.int16ChannelData, let d = dst.int16ChannelData {
            for i in 0..<ch { memcpy(d[i], s[i], frames * MemoryLayout<Int16>.size) }
        } else if let s = src.int32ChannelData, let d = dst.int32ChannelData {
            for i in 0..<ch { memcpy(d[i], s[i], frames * MemoryLayout<Int32>.size) }
        } else {
            return nil
        }
        return dst
    }

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ptr = out.int16ChannelData?[0] else { return }
        onChunk?(Data(bytes: ptr, count: Int(out.frameLength) * 2))
    }
}
