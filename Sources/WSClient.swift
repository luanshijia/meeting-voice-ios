import Foundation
import Network

/// 极薄的 WebSocket 客户端:音频走二进制帧,控制/结果/心跳走文本帧(JSON)。
///
/// 问题背景(2026-10-12 夜实测):手机显示"已传 6 秒",服务端只收到 0.8 秒,不锁屏也一样。
/// 这是长连接在移动网/隧道上的经典故障——链路中途变"灰":TCP 连接还在、数据不流动,
/// 两端都察觉不到。行业标准解法是"应用层心跳 + 主动重连",且**不指望把连接救活,
/// 只保证快速重建、补齐数据**。本实现用了四层:
///
///  1. 协议级 ping/pong(URLSessionWebSocketTask.sendPing,Apple 自带,最便宜);
///     pong 回来 = 链路活。每 3 秒一次。
///  2. 应用层 tick:服务端每 2 秒回"我实际收到你多少秒音频",这是唯一可信的收据。
///  3. NWPathMonitor(Apple 官方):网络路径一变(Wi-Fi↔蜂窝/接口切换)就立刻重建,
///     不等超时——移动网断流多半伴随路径变化。
///  4. 断线期间**音频暂存不丢**(上限 40 秒),连上后按序补发。
final class WSClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": "MeetingVoice/0.1.5"]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private let sendQueue = DispatchQueue(label: "meetingvoice.ws.send")
    private var backlog: [Data] = []          // 待发音频(断线期间继续往里放)
    private var sending = false
    private var opened = false
    private var generation = 0                // 每建一次连接 +1,拦住旧连接的回调
    private let maxBacklog = 400              // 400 × 100ms = 40 秒

    private var currentURL: URL?
    private var wantStreaming = false
    private var retryCount = 0
    private var openedOnce = false
    private var lastTickAt = Date()
    private var lastSendAt = Date()
    private var watchdogArmed = false
    private var pingTimer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()
    private var pathSignature: String?
    private var forcingReconnect = false

    var onText: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onSent: ((Int) -> Void)?
    var onNote: ((String) -> Void)?
    var onReconnect: (() -> Void)?
    var onTick: ((Double, Int) -> Void)?      // (服务端已收到的音频秒数, 字节数)

    override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let sig = "\(path.status) \(path.availableInterfaces.map { $0.name }.joined(separator: "+")) 昂贵=\(path.isExpensive)"
            guard let previous = self.pathSignature else {
                self.pathSignature = sig      // 第一次只是当前状态,不算变化
                return
            }
            guard previous != sig else { return }
            self.pathSignature = sig
            self.onNote?("网络路径变化: \(previous) → \(sig)")
            if self.wantStreaming && self.opened {
                self.forceReconnect("网络路径变化")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "meetingvoice.path"))
    }

    var isOpen: Bool { task != nil }

    func start(_ url: URL) {
        wantStreaming = true
        currentURL = url
        retryCount = 0
        openedOnce = false
        sendQueue.sync { backlog.removeAll() }
        connectNow()
    }

    func stop() {
        wantStreaming = false
        watchdogArmed = false
        stopPingLoop()
        closeSocket(keepBacklog: false)
        onState?("已停止")
    }

    /// 回到前台时立刻验一次(不等下一个心跳周期)
    func verifyNow() {
        guard wantStreaming, opened, let t = task else { return }
        let before = lastTickAt
        var answered = false
        t.sendPing { [weak self] err in
            guard let self else { return }
            if err == nil {
                answered = true
                self.lastTickAt = Date()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.wantStreaming, self.opened else { return }
            if !answered || self.lastTickAt <= before {
                self.onNote?("回前台验活失败 → 强制重连")
                self.forceReconnect("回前台无响应")
            }
        }
    }

    private func connectNow() {
        closeSocket(keepBacklog: true)
        guard let url = currentURL else { return }
        generation += 1
        forcingReconnect = false
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        let now = Date()
        lastTickAt = now
        lastSendAt = now
        onState?("连接中…\(url.host ?? "")")
        onNote?("发起 wss 连接" + (retryCount > 0 ? "(第 \(retryCount) 次重连)" : ""))
        listen()
        startPingLoop()
        armWatchdog()
    }

    private func closeSocket(keepBacklog: Bool) {
        sendQueue.sync {
            if !keepBacklog { backlog.removeAll() }
            sending = false
            opened = false
        }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        stopPingLoop()
    }

    // MARK: - 第 1 层:协议级 ping/pong
    private func startPingLoop() {
        stopPingLoop()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "meetingvoice.ping"))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.wantStreaming, self.opened, let t = self.task else { return }
            t.sendPing { [weak self] err in
                guard let self else { return }
                if err == nil {
                    self.lastTickAt = Date()          // 有 pong = 链路活着
                } else {
                    self.onNote?("ping 失败: \(err!.localizedDescription)")
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: - 看门狗(第 2 层):tick 或数据长时间不动 → 重建
    private func armWatchdog() {
        guard !watchdogArmed else { return }
        watchdogArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard self.wantStreaming else { self.watchdogArmed = false; return }
            let silentIn = Date().timeIntervalSince(self.lastTickAt)
            let silentOut = Date().timeIntervalSince(self.lastSendAt)
            if self.opened && (silentIn > 8 || silentOut > 8) {
                self.onNote?("看门狗: 入 \(Int(silentIn))s / 出 \(Int(silentOut))s 无动静")
                self.forceReconnect("链路卡住 \(Int(max(silentIn, silentOut))) 秒")
                return
            }
            self.watchdogArmed = false
            self.armWatchdog()
        }
    }

    /// 立刻重建连接(所有"发现链路死了"的路径都汇到这里)
    private func forceReconnect(_ why: String) {
        guard wantStreaming, !forcingReconnect else { return }
        forcingReconnect = true
        watchdogArmed = false
        retryCount += 1
        let buffered = sendQueue.sync { backlog.count }
        onState?("链路要重建(\(why)),正在重建连接…")
        onNote?("强制重连: \(why);暂存音频 \(buffered) 块")
        onReconnect?()
        closeSocket(keepBacklog: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.wantStreaming else { return }
            self.connectNow()
        }
    }

    private func handleDrop(_ why: String) {
        task = nil
        stopPingLoop()
        sendQueue.async { self.opened = false }
        guard wantStreaming else {
            onState?("已停止")
            return
        }
        retryCount += 1
        let delay = min(10.0, 2.0 * pow(1.5, Double(retryCount - 1)))
        onState?("连接已断(\(why)),\(Int(delay)) 秒后重连…")
        onNote?("连接断开: \(why);第 \(retryCount) 次重连将在 \(Int(delay))s 后")
        onReconnect?()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantStreaming else { return }
            self.connectNow()
        }
    }

    /// 音频先入队(连不连得上都入),断线期间暂存,连上后按序补发
    func sendAudio(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            if self.backlog.count >= self.maxBacklog {
                self.backlog.removeFirst()          // 超过 40 秒才丢最旧的
            }
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
        let gen = generation
        t.send(.data(d)) { [weak self] err in
            guard let self else { return }
            self.sendQueue.async {
                guard gen == self.generation else { return }   // 旧连接的回调,丢掉
                self.sending = false
                if let err {
                    self.onNote?("发送失败: \(err.localizedDescription)")
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
                self.onNote?("接收失败: \(err.localizedDescription)")
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
            self.pumpLocked()          // 把断线期间暂存的音频补发出去
        }
        lastTickAt = Date()
        lastSendAt = Date()
        let buffered = sendQueue.sync { backlog.count }
        if openedOnce {
            onNote?("重连成功,补发暂存音频 \(buffered) 块")
        }
        openedOnce = true
        retryCount = 0
        onState?("已连上,开始说话" + (buffered > 5 ? "(补发 \(buffered / 10) 秒暂存音频)" : ""))
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onNote?("连接关闭,code=\(closeCode.rawValue)")
        handleDrop("连接关闭 \(closeCode.rawValue)")
    }
}
