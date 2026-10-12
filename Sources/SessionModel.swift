import Foundation

/// 把「采集 → 推流 → 回传文本」串起来。实时阶段只出文字,不分说话人。
@MainActor
final class SessionModel: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var isRecording = false
    @Published var status = "未连接"
    @Published var lines: [String] = []
    @Published var partial = ""
    @Published var audioSeconds: Double = 0
    /// 上一次崩溃的正文(信号/异常)
    @Published var crashNote: String?
    /// 崩溃前最后 30 步流水
    @Published var stepNote: String?
    /// 崩溃前计数
    @Published var counterNote: String?

    private let capture = AudioCapture()
    private let ws = WSClient()
    private var totalBytes = 0
    private var receivedMsgs = 0
    private var partials = 0
    private var sentFrames = 0
    private var captureBlocks = 0

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "wss://100.64.0.2:8790/stream"

        CrashLog.readPreviousRun()
        crashNote = CrashLog.previousCrashFile ?? CrashLog.previousFailure
        stepNote = CrashLog.previousSteps
        counterNote = CrashLog.counters
        if crashNote == nil, stepNote == nil, CrashLog.previousRunStartedAt != nil {
            stepNote = "上次运行(\(CrashLog.previousRunStartedAt ?? "?"))没正常收尾"
        }

        let ws = self.ws
        ws.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        ws.onState = { [weak self] state in
            Task { @MainActor in self?.status = state }
        }
        ws.onSent = { [weak self] n in
            Task { @MainActor in
                guard let self else { return }
                self.sentFrames += n
                self.refreshCounters()
            }
        }
        ws.onNote = { note in CrashLog.step(note) }
        capture.onNote = { note in CrashLog.step(note) }
        capture.onChunk = { [weak self] data in
            guard let self else { return }
            ws.sendAudio(data)
            let n = data.count
            Task { @MainActor in
                self.captureBlocks += 1
                self.totalBytes += n
                self.audioSeconds = Double(self.totalBytes) / 2 / 16000
                if self.captureBlocks % 50 == 0 {          // 约每 5 秒记一次心跳
                    CrashLog.step("心跳: 已录 \(Int(self.audioSeconds))s, 发出 \(self.sentFrames) 帧, 收到 \(self.receivedMsgs) 条")
                }
                self.refreshCounters()
            }
        }
        CrashLog.markRunStart()
        CrashLog.step("App 启动完成")
    }

    func toggle() { isRecording ? stop() : start() }

    private func start() {
        guard let url = URL(string: serverURL), url.scheme == "wss" || url.scheme == "ws" else {
            status = "服务器地址无效(应形如 wss://100.64.0.2:8790/stream)"
            return
        }
        lines = []
        partial = ""
        totalBytes = 0
        audioSeconds = 0
        receivedMsgs = 0
        partials = 0
        sentFrames = 0
        captureBlocks = 0
        CrashLog.markRunStart()
        CrashLog.step("点了开始: 地址有效, 准备连接")
        ws.connect(url)
        do {
            try capture.start()
            isRecording = true
            status = "录音中(等服务器就绪…)"
        } catch {
            status = "启动录音失败:\(error.localizedDescription)"
            CrashLog.step("采集启动失败:\(error.localizedDescription)")
            ws.disconnect()
        }
    }

    private func stop() {
        capture.stop()
        ws.sendControl(["type": "stop"])
        isRecording = false
        status = "已停止,等服务端归档"
        CrashLog.step("用户点了停止")
        CrashLog.markRunEnd()
    }

    private func refreshCounters() {
        CrashLog.counters(received: receivedMsgs, sent: sentFrames, partials: partials, frames: captureBlocks)
    }

    private func handle(_ raw: String) {
        receivedMsgs += 1
        if receivedMsgs <= 5 || receivedMsgs % 50 == 0 {
            CrashLog.step("收到第 \(receivedMsgs) 条: \(raw.prefix(30))")
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            status = "服务端就绪,开始说话"
            CrashLog.step("服务端 ready")
        case "partial":
            partials += 1
            partial = (obj["text"] as? String) ?? ""
        case "final":
            if let t = obj["text"] as? String, !t.isEmpty { lines.append(t) }
            partial = ""
            CrashLog.step("收到 final(累计 \(lines.count) 段)")
        case "bye":
            if let t = obj["text"] as? String, !t.isEmpty { lines.append(t) }
            partial = ""
            status = "会话结束,音频已归档:" + ((obj["wav"] as? String) ?? "")
            CrashLog.step("会话正常结束")
            CrashLog.markRunEnd()
        case "error":
            status = "服务端错误:" + ((obj["message"] as? String) ?? "")
            CrashLog.step("服务端返回错误")
        default:
            break
        }
        refreshCounters()
    }

    func clearCrashNote() {
        CrashLog.clear()
        crashNote = nil
        stepNote = nil
        counterNote = nil
    }
}
