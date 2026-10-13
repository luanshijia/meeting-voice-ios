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

    private let fileName = "broadcast-probe.log"

    /// 与主 App(BroadcastProbe.groupCandidates)保持同一份候选表。
    /// 教训:上一版扩展只试了原组名,结果 App 侧「App Group 可用」而扩展侧打不开(bg=0)
    /// —— 因为 SideStore 重签时注进的组名可能带团队号后缀,两边试的名字不一致就露不出来。
    private static let groupCandidates = ["group.com.luanshijia.meetingvoice",
                                          "group.com.luanshijia.meetingvoice.458RP2552K"]
    private var matchedGroup: String?
    private var groupScanned = false

    // 回信道 ①:App Group 共享文件(主 App 能读,前提是 entitlement 签进去了)。
    // 回信道 ②:https 直接发到家里 7443(证书已信任、端口已放行、不新增端口/不改防火墙/不需要 ATS 豁免)。
    //   为什么加第二条:App Group 能不能签进去在免费自签下不保证,而"扩展能不能连上家里"本身就是
    //   阶段二真扩展的**前提**——这条通道一旦通,阶段二最担心的那件事就不担心了。
    private let reportURL = "https://100.64.0.2:7443/probe"
    private var ticker: DispatchSourceTimer?

    private var counts: [String: Int] = ["audioApp": 0, "audioMic": 0, "video": 0]  // 回调次数
    private var frames: [String: Int] = ["audioApp": 0, "audioMic": 0]             // 真实采样数
    private var rates: [String: Double] = [:]                                      // 采样率:用来把采样数换成秒
    private var described: Set<String> = []
    private var formats: [String: String] = [:]
    private var lastFlush = Date.distantPast

    // MARK: - 往 App Group 里写一行
    private func groupDir() -> URL? {
        if let matchedGroup,
           let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: matchedGroup) {
            return dir
        }
        if groupScanned && matchedGroup == nil { return nil }   // 扫过一遍都没有,不必每次重扫
        for id in Self.groupCandidates {
            if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                matchedGroup = id
                groupScanned = true
                return dir
            }
        }
        groupScanned = true
        return nil
    }

    private func fileURL() -> URL? { groupDir()?.appendingPathComponent(fileName) }

    /// 采样数 ÷ 采样率 = 秒。上一版用 CMSampleBufferGetTotalSampleSize 数字节,对音频 buffer
    /// 恒返回 0(所以日志里一直 bapp=0),改用真实采样数,远端就能直接换算成时长。
    private func seconds(_ name: String) -> String {
        guard let f = frames[name], let r = rates[name], r > 0 else { return "?" }
        return String(format: "%.1f", Double(f) / r)
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
        log("计数 回调 audioApp=\(counts["audioApp"]!) audioMic=\(counts["audioMic"]!) video=\(counts["video"]!) "
            + "| 采样 app=\(frames["audioApp"]!)(≈\(seconds("audioApp"))秒) "
            + "mic=\(frames["audioMic"]!)(≈\(seconds("audioMic"))秒) "
            + "| App Group=\(matchedGroup ?? "不可用") \(note)")
    }

    // MARK: - 回信道 ②:把计数发到家里(每 3 秒一次 + 启动/结束各一次)
    private func report(_ note: String = "") {
        var q = "note=\(note)&app=\(counts["audioApp"]!)&mic=\(counts["audioMic"]!)&vid=\(counts["video"]!)"
        q += "&fapp=\(frames["audioApp"]!)&fmic=\(frames["audioMic"]!)"
        q += "&sapp=\(seconds("audioApp"))&smic=\(seconds("audioMic"))"
        q += "&bg=\(fileURL() == nil ? 0 : 1)&bgid=\(matchedGroup ?? "none")"
        for (k, v) in formats { q += "&fmt_\(k)=\(v)" }
        let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        guard let url = URL(string: "\(reportURL)?\(escaped)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            self?.log("上报 note=\(note) → code=\(code) err=\(err?.localizedDescription ?? "无")")
        }.resume()
    }

    // MARK: - 生命周期
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log("=== 扩展启动(bundle=\(Bundle.main.bundleIdentifier ?? "?") App Group=\(fileURL() == nil ? "不可用" : "可用") ===")
        flush()
        report("start")                                  // 立刻发一次:哪怕零音频,也能证明"扩展活着 + 能连上家里"
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.report("tick") }
        t.resume()
        ticker = t
    }

    override func broadcastPaused() { log("扩展被暂停") }
    override func broadcastResumed() { log("扩展恢复") }

    override func broadcastFinished() {
        report("finish")
        ticker?.cancel()
        ticker = nil
        flush("(结束)")
        log("=== 扩展结束 ===")
    }

    // MARK: - 音频/视频样本
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            counts["audioApp", default: 0] += 1
            frames["audioApp", default: 0] += CMSampleBufferGetNumSamples(sampleBuffer)
            describeIfNeeded(sampleBuffer, name: "audioApp")
        case .audioMic:
            counts["audioMic", default: 0] += 1
            frames["audioMic", default: 0] += CMSampleBufferGetNumSamples(sampleBuffer)
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
        let desc = "\(Int(asbd.pointee.mSampleRate))Hz_\(asbd.pointee.mChannelsPerFrame)ch_"
            + "\(asbd.pointee.mBitsPerChannel)bit_\(bigEndian ? "be" : "le")_il\(interleaved ? 1 : 0)"
        formats[name] = desc
        rates[name] = asbd.pointee.mSampleRate
        log("\(name) 首帧格式: \(Int(asbd.pointee.mSampleRate))Hz \(asbd.pointee.mChannelsPerFrame)声道 "
            + "\(asbd.pointee.mBitsPerChannel)bit \(bigEndian ? "大端" : "小端") 交错=\(interleaved)")
    }
}
