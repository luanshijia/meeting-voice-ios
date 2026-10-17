import CoreMedia
import Foundation
import ReplayKit

/// Replacement broadcast extension: system app audio enters LiveKit as its own participant.
final class SampleHandler: RPBroadcastSampleHandler {
    private let fileName = "broadcast-probe.log"
    private var publisher: LiveKitBroadcastPublisher?
    private var appFrames = 0
    private var callbacks = 0
    private var micCallbacks = 0
    private var sampleRate = 0.0
    private var lastStatus = Date.distantPast

    private static let groupCandidates = [
        "group.com.luanshijia.voicememo",
        "group.com.luanshijia.voicememo.458RP2552K",
    ]

    private func log(_ line: String) {
        guard let url = Self.groupCandidates
            .compactMap({ FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) })
            .first?.appendingPathComponent(fileName) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        appFrames = 0
        callbacks = 0
        micCallbacks = 0
        sampleRate = 0
        lastStatus = .distantPast
        log("=== 扩展启动 ===")
        publisher = LiveKitBroadcastPublisher { [weak self] in self?.log($0) }
        publisher?.start()
    }

    override func broadcastPaused() { log("扩展暂停") }
    override func broadcastResumed() { log("扩展恢复") }

    override func broadcastFinished() {
        publisher?.stop()
        publisher = nil
        log("=== 扩展结束; audioApp 回调=\(callbacks) audioMic 回调=\(micCallbacks) 样本=\(appFrames) 时长≈\(seconds())秒 ===")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        if type == .audioMic {
            // 仅计数用于核对系统麦克风开关是否生效；绝不复制或发布，主 App 是唯一麦克风轨。
            micCallbacks += 1
            return
        }
        guard type == .audioApp else { return }
        callbacks += 1
        appFrames += CMSampleBufferGetNumSamples(sampleBuffer)
        if sampleRate == 0,
           let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            sampleRate = asbd.pointee.mSampleRate
        }
        publisher?.append(sampleBuffer)

        let now = Date()
        if now.timeIntervalSince(lastStatus) >= 5 {
            lastStatus = now
            log("计数 回调 audioApp=\(callbacks) audioMic=\(micCallbacks) 样本=\(appFrames) 时长≈\(seconds())秒")
        }
    }

    private func seconds() -> String {
        guard sampleRate > 0 else { return "?" }
        return String(format: "%.1f", Double(appFrames) / sampleRate)
    }
}
