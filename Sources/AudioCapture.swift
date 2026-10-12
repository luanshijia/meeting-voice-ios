import AVFoundation

/// 采集麦克风 → 16 kHz / 单声道 / 16-bit PCM。
/// 实测调整:去掉 .allowBluetooth / .defaultToSpeaker —— 只录麦克风,少一类
/// "音频路由/格式变化"的触发源(那类变化会让 AVAudioEngine 的 tap 格式失效并断言崩溃);
/// 同时把路由变化/中断/引擎重启都记进黑匣子,便于定位。
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: true)!
    private let queue = DispatchQueue(label: "meetingvoice.audio")
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    var onChunk: ((Data) -> Void)?
    var onNote: ((String) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        registerObservers()

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let conv = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风格式不可用(采样率 \(inFormat.sampleRate) / 声道 \(inFormat.channelCount))"])
        }
        converter = conv
        onNote?("采集格式: \(Int(inFormat.sampleRate))Hz / \(inFormat.channelCount) 声道")

        input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // tap 给的 buffer 出了回调就可能被复用/回收 —— 必须当场复制
            guard let copy = AudioCapture.copyOf(buffer) else { return }
            self.queue.async { self.convertAndEmit(copy) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        onNote?("采集引擎已启动")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onNote?("采集引擎已停止")
    }

    private func registerObservers() {
        let c = NotificationCenter.default
        observers.append(c.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map { String($0) } ?? "?"
            let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
            self?.onNote?("音频路由变化 reason=\(reason) 输入=\(inputs)")
        })
        observers.append(c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).map { String($0) } ?? "?"
            self?.onNote?("音频中断 type=\(type)")
        })
        observers.append(c.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onNote?("引擎配置变化(采样率/路由被系统改过)")
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

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
