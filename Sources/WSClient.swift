import Foundation

/// 极薄的 WebSocket 客户端:音频走二进制帧,控制/结果/心跳走文本帧(JSON)。
///
/// 实测教训(2026-10-12 晚):手机显示"已传 6 秒"、服务端只收到 0.8 秒——
/// 链路中途变"灰"(TCP 连接还在、数据不流动)时,URLSession 会把数据静静吞进缓冲区,
/// 客户端完全察觉不到。所以:
///  * 服务端每 2 秒回一个 tick(带"我实际收到多少秒音频"),这就是心跳也是收据;
///  * 客户端 6 秒收不到 tick、或 6 秒发不出任何数据 → 判定链路死了 → 强制重建连接。
final class WSClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": "MeetingVoice/0.1.4"]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private let sendQueue = DispatchQueue(label: "meetingvoice.ws.send")
    private var backlog: [Data] = []
    private var sending = false
    private var opened = false
    private var droppedWhileClosed = 0
    private let maxBacklog = 25

    private var currentURL: URL?
    private var wantStreaming = false
    private var retryCount = 0
    private var openedOnce = false
    private var lastTickAt = Date()
    private var lastSendAt = Date()
    private var watchdogArmed = false

    var onText: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onSent: ((Int) -> Void)?
    var onNote: ((String) -> Void)?
    var onReconnect: ((Int) -> Void)?
    var onTick: ((Double, Int) -> Void)?      // (服务端已收到的音频秒数, 字节数)

    var isOpen: Bool { task != nil }

    func start(_ url: URL) {
        wantStreaming = true
        currentURL = url
        retryCount = 0
        openedOnce = false
        connectNow()
    }

    func stop() {
        wantStreaming = false
        watchdogArmed = false
        closeSocket()
        onState?("已停止")
    }

    private func connectNow() {
        closeSocket()
        guard let url = currentURL else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        let now = Date()
        lastTickAt = now
        lastSendAt = now
        onState?("连接中…\(url.host ?? "")")
        onNote?("发起 wss 连接" + (retryCount > 0 ? "(第 \(retryCount) 次重连)" : ""))
        listen()
        armWatchdog()
    }

    private func closeSocket() {
        sendQueue.sync {
            backlog.removeAll()
            sending = false
            opened = false
            droppedWhileClosed = 0
        }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// 每 2 秒检查一次:链路是不是"灰"了
    private func armWatchdog() {
        guard !watchdogArmed else { return }
        watchdogArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard self.wantStreaming else { self.watchdogArmed = false; return }
            let silentIn = Date().timeIntervalSince(self.lastTickAt)
            let silentOut = Date().timeIntervalSince(self.lastSendAt)
            if self.opened && (silentIn > 6 || silentOut > 6) {
                self.onNote?("看门狗: 入 \(Int(silentIn))s / 出 \(Int(silentOut))s 无动静 → 强制重连")
                self.onState?("链路卡住(\(Int(max(silentIn, silentOut))) 秒没动静),正在重建连接…")
                self.closeSocket()
                self.retryCount += 1
                self.watchdogArmed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.wantStreaming else { return }
                    self.connectNow()
                }
                return
            }
            self.watchdogArmed = false
            self.armWatchdog()
        }
    }

    private func handleDrop(_ why: String) {
        task = nil
        sendQueue.async { self.opened = false }
        guard wantStreaming else {
            onState?("已停止")
            return
        }
        retryCount += 1
        let delay = min(10.0, 2.0 * pow(1.5, Double(retryCount - 1)))
        onState?("连接已断(\(why)),\(Int(delay)) 秒后重连…")
        onNote?("连接断开:\(why);第 \(retryCount) 次重连将在 \(Int(delay))s 后")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantStreaming else { return }
            self.connectNow()
        }
    }

    /// 握手没完成就直接丢,不往 URLSession 里塞
    func sendAudio(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard self.opened else {
                self.droppedWhileClosed += 1
                if self.droppedWhileClosed % 100 == 1 {
                    self.onNote?("未连接,已丢弃 \(self.droppedWhileClosed) 块音频")
                }
                return
            }
            if self.backlog.count >= self.maxBacklog { self.backlog.removeFirst() }
            self.backlog.append(data)
            self.pumpLocked()
        }
    }

    func sendControl(_ dict: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    /// 只在 sendQueue 上调用
    private func pumpLocked() {
        guard opened, !sending, let t = task, !backlog.isEmpty else { return }
        let d = backlog.removeFirst()
        sending = true
        t.send(.data(d)) { [weak self] err in
            guard let self else { return }
            self.sendQueue.async {
                self.sending = false
                if let err {
                    self.onNote?("发送失败:\(err.localizedDescription)")
                } else {
                    self.onSent?(1)
                    self.lastSendAt = Date()
                }
                self.pumpLocked()
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.onNote?("接收失败:\(err.localizedDescription)")
                self.handleDrop("接收中断")
            case .success(let msg):
                var text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                if let t = text {
                    self.lastTickAt = Date()
                    // 心跳单独处理,不进文字流
                    if t.contains("\"type\": \"tick\"") || t.contains("\"type\":\"tick\"") {
                        if let d = t.data(using: .utf8),
                           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            self.onTick?((o["audio_s"] as? Double) ?? 0, (o["bytes"] as? Int) ?? 0)
                        }
                    } else {
                        self.onText?(t)
                    }
                }
                if self.task != nil { self.listen() }
            }
        }
    }
}

extension WSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.opened = true
            self.pumpLocked()
        }
        lastTickAt = Date()
        lastSendAt = Date()
        if openedOnce {
            onNote?("重连成功(该次录音累计断线 \(retryCount) 次)")
            onReconnect?(retryCount)
        }
        openedOnce = true
        retryCount = 0
        onState?("已连上,开始说话")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onNote?("连接关闭,code=\(closeCode.rawValue)")
        handleDrop("连接关闭 \(closeCode.rawValue)")
    }
}
