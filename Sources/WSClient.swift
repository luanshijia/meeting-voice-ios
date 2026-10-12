import Foundation

/// 极薄的 WebSocket 客户端:音频走二进制帧,控制/结果走文本帧(JSON)。
/// 两条实测得来的规矩:
///  1) 只有**握手真的完成**后才发音频(之前在没有完成的情况下一直 send,
///     实测出现"采集 34 秒、发出 0 帧"且随后 SIGABRT);
///  2) 发送串行化(同一时刻只有一个 send 在飞),排队上限 25 帧。
final class WSClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // 显式给 User-Agent,免得 CFNetwork 走"自己拼 UA"那条路
        cfg.httpAdditionalHeaders = ["User-Agent": "MeetingVoice/0.1.2"]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private let sendQueue = DispatchQueue(label: "meetingvoice.ws.send")
    private var backlog: [Data] = []
    private var sending = false
    private var opened = false
    private let maxBacklog = 25
    private var droppedWhileClosed = 0

    var onText: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onSent: ((Int) -> Void)?
    var onNote: ((String) -> Void)?          // 给黑匣子记流水用

    var isOpen: Bool { task != nil }
    var handshakeDone: Bool { opened }

    func connect(_ url: URL) {
        disconnect()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        onState?("连接中…\(url.host ?? "")")
        onNote?("已发起 wss 连接(等握手)")
        listen()
    }

    func disconnect() {
        sendQueue.sync {
            backlog.removeAll()
            sending = false
            opened = false
        }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    /// 握手没完成就直接丢,不往 URLSession 里塞
    func sendAudio(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard self.opened else {
                self.droppedWhileClosed += 1
                if self.droppedWhileClosed % 100 == 1 {
                    self.onNote?("握手未完成,已丢弃 \(self.droppedWhileClosed) 块音频")
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
                self.onState?("连接中断:\(err.localizedDescription)")
                self.onNote?("接收失败:\(err.localizedDescription)")
                self.task = nil
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
    /// 握手真的完成了 —— 从这一刻起才允许发音频
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.opened = true
            self.pumpLocked()
        }
        onState?("握手完成(等待服务端就绪)")
        onNote?("握手完成,子协议=\(proto ?? "无")")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onState?("连接已关闭(\(closeCode.rawValue))")
        onNote?("连接关闭,code=\(closeCode.rawValue)")
        sendQueue.async { [weak self] in self?.opened = false }
        task = nil
    }
}
