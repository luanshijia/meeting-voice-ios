import Foundation

/// 把「采集 → 推流 → 回传文本」串起来。实时阶段只出文字,不分说话人。
/// build 9:三个数字说真话 —— 录(本地采集)/ 传(本地发出)/ 收(服务端确认收到);
/// 并且靠服务端心跳发现链路"变灰"后强制重建连接。
@MainActor
final class SessionModel: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var isRecording = false
    @Published var status = "未连接"
    @Published var lines: [String] = []
    @Published var partial = ""
    @Published var audioSeconds: Double = 0        // 本地已录
    @Published var uploadedSeconds: Double = 0     // 本地已发出
    @Published var serverSeconds: Double = 0       // 服务端确认收到(唯一可信的数)
    @Published var reconnectCount = 0

    private let capture = AudioCapture()
    private let ws = WSClient()
    private var totalBytes = 0
    private var receivedMsgs = 0
    private var partials = 0
    private var sentFrames = 0
    private var captureBlocks = 0

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "wss://100.64.0.2:8790/stream"

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
                self.uploadedSeconds = Double(self.sentFrames) / 10.0
            }
        }
        ws.onTick = { [weak self] secs, _ in
            Task { @MainActor in self?.serverSeconds = secs }
        }
        ws.onReconnect = { [weak self] n in
            Task { @MainActor in self?.reconnectCount = n }
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
                if self.captureBlocks % 50 == 0 {
                    CrashLog.step("心跳: 录 \(Int(self.audioSeconds))s / 传 \(Int(self.uploadedSeconds))s / 服务端收到 \(Int(self.serverSeconds))s / 重连 \(self.reconnectCount) 次")
                }
            }
        }
        CrashLog.markRunStart()
        CrashLog.markRunEnd()
        CrashLog.step("App 启动完成")
    }

    func toggle() { isRecording ? stop() : start() }

    func resetServerURL() { serverURL = "wss://100.64.0.2:8790/stream" }

    private func start() {
        guard let url = URL(string: serverURL), url.scheme == "wss" || url.scheme == "ws" else {
            status = "服务器地址无效(应形如 wss://100.64.0.2:8790/stream)"
            return
        }
        lines = []
        partial = ""
        totalBytes = 0
        audioSeconds = 0
        uploadedSeconds = 0
        serverSeconds = 0
        receivedMsgs = 0
        partials = 0
        sentFrames = 0
        captureBlocks = 0
        reconnectCount = 0
        CrashLog.markRunStart()
        CrashLog.step("点了开始: 地址有效, 准备连接")
        ws.start(url)
        do {
            try capture.start()
            isRecording = true
            status = "录音中…"
        } catch {
            status = "启动录音失败:\(error.localizedDescription)"
            CrashLog.step("采集启动失败:\(error.localizedDescription)")
            ws.stop()
        }
    }

    private func stop() {
        capture.stop()
        ws.sendControl(["type": "stop"])
        ws.stop()
        isRecording = false
        status = "已停止:录 \(Int(audioSeconds))秒 / 家里收到 \(Int(serverSeconds))秒"
        CrashLog.step("用户点了停止: 录 \(Int(audioSeconds))s, 家里收到 \(Int(serverSeconds))s")
        CrashLog.markRunEnd()
    }

    private func handle(_ raw: String) {
        receivedMsgs += 1
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            status = "录音中…(服务端就绪)"
            CrashLog.step("服务端 ready")
        case "partial":
            partials += 1
            partial = (obj["text"] as? String) ?? ""
        case "final":
            if let t = obj["text"] as? String, !t.isEmpty { lines.append(t) }
            partial = ""
        case "bye":
            if let t = obj["text"] as? String, !t.isEmpty { lines.append(t) }
            partial = ""
            status = "会话结束,已归档:" + ((obj["wav"] as? String) ?? "")
        case "error":
            status = "服务端错误:" + ((obj["message"] as? String) ?? "")
        default:
            break
        }
    }
}
