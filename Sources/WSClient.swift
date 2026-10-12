import Foundation

/// 极薄的 WebSocket 客户端:音频走二进制帧,控制/结果走文本帧(JSON)。
/// 三条实测得来的规矩:
///  1) 只有**握手真的完成**后才发音频(否则会出现在未建立的任务上反复 send);
///  2) 发送串行化(同时只有一个 send 在飞),排队上限 25 帧;
///  3) **断线自动重连**:录音中连接掉了就退避重连(2s→3s→4.5s…最多 10s),
///     重连后继续推音频(服务端会另起一个新会话,音频不丢,只是分成多个文件)。
final class WSClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": "MeetingVoice/0.1.3"]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private let sendQueue = DispatchQueue(label: "meetingvoice.ws.send")
    private var backlog: [Data] = []
    private var sending = false
    private var opened = false
    private var droppedWhileClosed = 0
    private let maxBacklog = 25

    // 重连相关
    private var currentURL: URL?
    private var wantStreaming = false        // 模型是否想推流(开始录音 true / 停止 false)
    private var retryCount = 0
    private var openedOnce = false

    var onText: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onSent: ((Int) -> Void)?
    var onNote: ((String) -> Void)?
    var onReconnect: ((Int) -> Void)?        // 累计重连成功次数

    var isOpen: Bool { task != nil }
    var handshakeDone: Bool { opened }

    /// 开始录音时调用(可重复调用做"重连")
    func start(_ url: URL) {
        wantStreaming = true
        currentURL = url
        retryCount = 0
        openedOnce = false
        connectNow()
    }

    /// 用户点停止
    func stop() {
        wantStreaming = false
        closeSocket()
        onState?("已停止")
    }

    private func connectNow() {
        closeSocket()
        guard let url = currentURL else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        onState?("连接中…\(url.host ?? "")")
        onNote?("发起 wss 连接" + (retryCount > 0 ? "(第 \(retryCount) 次重连)" : ""))
        listen()
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

    /// 连接断了:想推流就退避重连;不想就安静结束
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
                    self.onNote?("握手未完成/已断开,已丢弃 \(self.droppedWhileClosed) 块音频")
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
                switch msg {
                case .string(let s):
                    self.onText?(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { self.onText?(s) }
                @unknown default:
                    break
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
        if openedOnce {
            onNote?("重连成功(累计断线 \(retryCount) 次)")
            onReconnect?(retryCount)
        }
        openedOnce = true
        retryCount = 0
        onState?("握手完成(等待服务端就绪)")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onNote?("连接关闭,code=\(closeCode.rawValue)")
        handleDrop("连接关闭 \(closeCode.rawValue)")
    }
}
