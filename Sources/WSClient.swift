import Foundation

/// 极薄的 WebSocket 客户端：音频走二进制帧，控制/结果走文本帧(JSON)。
final class WSClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    var onText: ((String) -> Void)?
    var onState: ((String) -> Void)?

    var isOpen: Bool { task != nil }

    func connect(_ url: URL) {
        disconnect()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        onState?("已连接 \(url.host ?? "")")
        listen()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func sendAudio(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func sendControl(_ dict: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.onState?("连接中断：\(err.localizedDescription)")
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
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onState?("连接已关闭(\(closeCode.rawValue))")
        task = nil
    }
}
