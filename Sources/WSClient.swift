import Foundation

/// 极薄的 WebSocket 客户端:音频走二进制帧,控制/结果走文本帧(JSON)。
///
/// 发送串行化:同一时刻只允许一个 send 在飞,后面的排队(囤太多就丢最旧的)。
/// 之前是「20 帧/秒直接并发 send」,这是真实的崩溃隐患。
final class WSClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private let sendQueue = DispatchQueue(label: "meetingvoice.ws.send")
    private var backlog: [Data] = []
    private var sending = false
    private let maxBacklog = 25            // 最多囤约 2.5 秒,再多丢最旧的,不让内存无限涨

    var onText: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onSent: ((Int) -> Void)?           // 成功发出的帧数(诊断用)

    var isOpen: Bool { task != nil }

    func connect(_ url: URL) {
        disconnect()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        onState?("连接中…\(url.host ?? "")")   // 说真话:这只是"发起",握手还没完成
        listen()
    }

    func disconnect() {
        sendQueue.sync { backlog.removeAll() }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func sendAudio(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }
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
        guard !sending, let t = task, !backlog.isEmpty else { return }
        let d = backlog.removeFirst()
        sending = true
        t.send(.data(d)) { [weak self] err in
            guard let self else { return }
            self.sendQueue.async {
                self.sending = false
                if err == nil { self.onSent?(1) }
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
    /// 握手真的完成了才有这条 —— 之前那句"已连接"是假的,现在分开了
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        onState?("握手完成(等待服务端就绪)")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onState?("连接已关闭(\(closeCode.rawValue))")
        task = nil
    }
}
