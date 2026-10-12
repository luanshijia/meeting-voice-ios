import Foundation

/// 把「采集 → 推流 → 回传文本」串起来。实时阶段只出文字，不分说话人。
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

    private let capture = AudioCapture()
    private let ws = WSClient()
    private var totalBytes = 0

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "wss://100.64.0.2:8790/stream"
        let ws = self.ws
        ws.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        ws.onState = { [weak self] state in
            Task { @MainActor in self?.status = state }
        }
        capture.onChunk = { [weak self] data in
            guard let self else { return }
            ws.sendAudio(data)          // ws 非 MainActor，后台线程调用安全
            let n = data.count
            Task { @MainActor in
                self.totalBytes += n
                self.audioSeconds = Double(self.totalBytes) / 2 / 16000
            }
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard let url = URL(string: serverURL), url.scheme == "wss" || url.scheme == "ws" else {
            status = "服务器地址无效(应形如 wss://100.64.0.2:8790/stream)"
            return
        }
        lines = []
        partial = ""
        totalBytes = 0
        audioSeconds = 0
        ws.connect(url)
        do {
            try capture.start()
            isRecording = true
            status = "录音中(锁屏继续)"
        } catch {
            status = "启动录音失败：\(error.localizedDescription)"
            ws.disconnect()
        }
    }

    private func stop() {
        capture.stop()
        ws.sendControl(["type": "stop"])
        isRecording = false
        status = "已停止，等服务端归档"
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            status = "服务端就绪，开始说话"
        case "partial":
            partial = (obj["text"] as? String) ?? ""
        case "final":
            if let t = obj["text"] as? String, !t.isEmpty { lines.append(t) }
            partial = ""
        case "bye":
            if let t = obj["text"] as? String, !t.isEmpty { lines.append(t) }
            partial = ""
            let wav = (obj["wav"] as? String) ?? ""
            status = "会话结束，音频已归档：\(wav)"
        case "error":
            status = "服务端错误：" + ((obj["message"] as? String) ?? "")
        default:
            break
        }
    }
}
