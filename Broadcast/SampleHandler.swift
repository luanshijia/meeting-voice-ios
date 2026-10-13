import ReplayKit
import CoreMedia
import Foundation

/// 探针版广播扩展:刻意【不】依赖 LiveKit —— 探针要把变量压到最少。
/// 它只做三件事,目的都是回答阶段二最要紧的未知:
///   1) 带扩展(appex)的包,免费自签能不能装进手机;
///   2) 扩展进程被系统拉起来后,是否真的收到音频,以及「对方声音(audioApp)」与
///      「我方麦克风(audioMic)」的计数与采样格式(ASBD,含字节序);
///   3) 把结果写进 App Group 共享容器 → 由主 App 显示出来,这样在手机上就能自证。
/// 真实扩展再换成 LiveKit 官方示例的 LKSampleHandler。
final class SampleHandler: RPBroadcastSampleHandler {

    private let groupID = "group.com.luanshijia.meetingvoice"
    private let fileName = "broadcast-probe.log"

    private var counts: [String: Int] = ["audioApp": 0, "audioMic": 0, "video": 0]
    private var bytes: [String: Int] = ["audioApp": 0, "audioMic": 0]
    private var described: Set<String> = []
    private var lastFlush = Date.distantPast

    // MARK: - 往 App Group 里写一行
    private func fileURL() -> URL? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return nil
        }
        return dir.appendingPathComponent(fileName)
    }

    private func log(_ line: String) {
        guard let url = fileURL() else { return }   // App Group 不可用:没法回报,只能不写
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func flush(_ note: String = "") {
        log("计数 audioApp=\(counts["audioApp"]!) audioMic=\(counts["audioMic"]!) video=\(counts["video"]!) "
            + "| 字节 app=\(bytes["audioApp"]!) mic=\(bytes["audioMic"]!) \(note)")
    }

    // MARK: - 生命周期
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log("=== 扩展启动(bundle=\(Bundle.main.bundleIdentifier ?? "?")) App Group=\(fileURL() == nil ? "不可用" : "可用") ===")
        flush()
    }

    override func broadcastPaused() { log("扩展被暂停") }
    override func broadcastResumed() { log("扩展恢复") }

    override func broadcastFinished() {
        flush("(结束)")
        log("=== 扩展结束 ===")
    }

    // MARK: - 音频/视频样本
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            counts["audioApp", default: 0] += 1
            bytes["audioApp", default: 0] += CMSampleBufferGetTotalSampleSize(sampleBuffer)
            describeIfNeeded(sampleBuffer, name: "audioApp")
        case .audioMic:
            counts["audioMic", default: 0] += 1
            bytes["audioMic", default: 0] += CMSampleBufferGetTotalSampleSize(sampleBuffer)
            describeIfNeeded(sampleBuffer, name: "audioMic")
        case .video:
            counts["video", default: 0] += 1
        @unknown default:
            break
        }

        let now = Date()
        if now.timeIntervalSince(lastFlush) >= 5 {
            lastFlush = now
            flush()
        }
    }

    /// 只记第一帧的格式:采样率、声道数、位深、字节序 —— 这四项决定了后续解码怎么写。
    private func describeIfNeeded(_ sampleBuffer: CMSampleBuffer, name: String) {
        guard !described.contains(name),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }
        described.insert(name)
        let bigEndian = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let interleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        log("\(name) 首帧格式: \(Int(asbd.pointee.mSampleRate))Hz \(asbd.pointee.mChannelsPerFrame)声道 "
            + "\(asbd.pointee.mBitsPerChannel)bit \(bigEndian ? "大端" : "小端") 交错=\(interleaved)")
    }
}
