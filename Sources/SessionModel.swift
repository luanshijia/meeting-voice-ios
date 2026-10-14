import Foundation

/// 一句话转写结果(带说话人 —— agent 是按音轨分轨识别后带上 identity 发回来的)。
struct TranscriptLine: Identifiable {
    let id = UUID()
    let who: String
    let text: String
    /// 这句话开始前,同一路音频静了多久(秒)。nil = 服务端没测出来(刚重连的第一句)
    var gap: Double? = nil
    /// 服务端定稿的绝对时间(epoch 秒)。0 = 老服务端没给
    var ts: Double = 0
}

@MainActor
final class SessionModel: ObservableObject {
    @Published var status = "未连接"
    @Published var lines: [TranscriptLine] = []
    @Published var partial = ""
    @Published var partialWho = ""
    @Published var isRecording = false
    @Published var recordedSeconds: Double = 0     // 本地推流时长
    @Published var serverSeconds: Double = 0       // 家里已识别到的音频秒数(agent 回传)
    @Published var summary = ""                    // 实时总结正文(agent 推 summary 消息时填)
    @Published var summaryState = "自动更新"        // 总结行右侧小字:自动更新 / 已请求… / 更新于 HH:MM:SS

    /// 「实时总结」按钮:点一次,请家里立刻出一段(站 4 后端已接)。
    func requestSummary() {
        guard isRecording else { return }
        summaryState = "已请求,稍等…"
        note("点了实时总结(请家里出一段)")
        Task { await room.send(["type": "summary_request", "ts": Int(Date().timeIntervalSince1970)]) }
    }

    var serverURL: String {
        get { cfg.url } set { cfg.url = newValue; cfg.save() }
    }
    var apiKey: String {
        get { cfg.apiKey } set { cfg.apiKey = newValue; cfg.save() }
    }
    var apiSecret: String {
        get { cfg.apiSecret } set { cfg.apiSecret = newValue; cfg.save() }
    }
    var identity: String { cfg.identity }

    func note(_ s: String) {
        notes.append("\(Self.stamp()) \(s)")
        if notes.count > 30 { notes.removeFirst() }
        CrashLog.step(s)          // 同步进黑匣子(崩溃时能看到最后几步)
    }
    @Published var notes: [String] = []
    var notesText: String { notes.joined(separator: "\n") }

    func resetToDefaults() {
        cfg = LiveKitConfig(url: LiveKitConfig.defaultURL, apiKey: LiveKitConfig.defaultKey,
                            apiSecret: LiveKitConfig.defaultSecret,
                            identity: LiveKitConfig.defaultIdentity)
        cfg.save()
        objectWillChange.send()
    }

    private var cfg = LiveKitConfig.load()
    private let room = VoiceRoom()
    private var timer: Timer?
    /// 上一次「停止」的断开动作。实测踩过:点停止后立刻再点开始,新旧两条连接同身份并存,
    /// 服务端按 DUPLICATE_IDENTITY 把旧的那条踢掉(01:44:33 就是这么发生的)。
    /// 所以下次连接前必须先等它落地。
    private var pendingDisconnect: Task<Void, Never>?

    init() {
        room.onState = { [weak self] s in self?.status = s }
        room.onNote = { [weak self] s in self?.note(s) }
        room.onEnded = { [weak self] s in
            guard let self else { return }
            self.status = s
            self.stopTimer()
            self.isRecording = false
        }
        room.onTranscript = { [weak self] type, who, audioS, text, gap, ts in
            guard let self else { return }
            self.serverSeconds = audioS          // 「收」= 家里已识别的音频秒数
            if type == "summary" {               // 站 4 后端接上后,agent 会推这个类型过来
                self.summary = text
                self.summaryState = "更新于 \(Self.stamp())"
                return
            }
            if type == "final" {
                if !text.isEmpty {
                    self.lines.append(TranscriptLine(who: who, text: text, gap: gap, ts: ts))
                }
                self.partial = ""
                self.partialWho = ""
            } else {
                self.partial = text
                self.partialWho = who
            }
        }
        // 从 Bundle 读真实版本(以前写死成 v0.2.0(build 11),截图里会误导人)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        note("App 启动,v\(ver)(build \(build), LiveKit)")
    }

    func toggle() { isRecording ? stop() : start() }

    private func start() {
        lines = []
        partial = ""
        partialWho = ""
        recordedSeconds = 0
        serverSeconds = 0
        status = "连接中…"
        isRecording = true
        let cfg = self.cfg
        Task {
            if let d = pendingDisconnect { await d.value }   // 等上一次断开落地,避免同身份双连
            pendingDisconnect = nil
            do {
                try await room.connect(cfg)
                self.startTimer()
            } catch {
                self.note("连接异常:\(error.localizedDescription)")
                self.status = "连接失败:\(error.localizedDescription)"
                self.isRecording = false
            }
        }
    }

    private func stop() {
        stopTimer()
        isRecording = false
        status = "已停止:本地推流 \(Int(recordedSeconds)) 秒,家里已识别 \(Int(serverSeconds)) 秒"
        note("用户停止:推流 \(Int(recordedSeconds))s / 家里识别 \(Int(serverSeconds))s")
        pendingDisconnect = Task { await room.disconnect() }
    }

    private func startTimer() {
        stopTimer()
        recordedSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordedSeconds += 0.5 }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }
}
