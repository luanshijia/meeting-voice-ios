import AVFoundation
import Foundation

/// 一句话转写结果(带说话人 —— agent 是按音轨分轨识别后带上 identity 发回来的)。
struct TranscriptLine: Identifiable {
    let id = UUID()
    let who: String
    let source: String
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
    @Published var partialSource = ""
    @Published var isRecording = false
    /// 当前麦克风模式(只读 —— iOS 不给 App 设置接口;界面只用来看「是不是宽谱」)
    @Published var micModeText = "读取中"
    @Published var micIsWide = false
    @Published var recordedSeconds: Double = 0     // 本地推流时长
    @Published var serverSeconds: Double = 0       // 家里已识别到的音频秒数(agent 回传)

    // ---- 会中滚动提要(方案 v3,2026-10-15)----
    /// 一轮提要 = 一行时间 + 1~3 条短要点(家里只对"新增"出要点,不重写整段)
    struct SummaryItem: Identifiable {
        let id = UUID()
        let clock: String
        let text: String
    }
    @Published var summaries: [SummaryItem] = []
    @Published var sumMode = "auto"                // auto=自动 5 分钟 / manual=手动 10 分钟
    @Published var sumState = "等待提要…"           // 状态区文案:由家里推来的 sumstatus 驱动
    @Published var sumCode = "wait_period"         // 家里给的判定码:no_session/short/quality/busy_*/go
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

    /// 读一次当前麦克风模式。未授权时不碰这个 API(iOS 17 起未授权访问有风险)。
    /// 官方口径:iOS 会按 App 记住用户选过的模式(Apple 支持文档 101993)→ 用户选一次宽谱
    /// 就等于给它定了默认;App 只能读、只能请系统弹面板,不能替用户选。
    func refreshMicMode() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            micModeText = "未授权"; micIsWide = false; return
        }
        let m = AVCaptureDevice.preferredMicrophoneMode
        micIsWide = (m == .wideSpectrum)
        switch m {
        case .standard:       micModeText = "标准"
        case .voiceIsolation: micModeText = "语音突显"
        case .wideSpectrum:   micModeText = "宽谱"
        default:              micModeText = "自动"
        }
    }

    /// 「宽谱」按钮:请系统把麦克风模式选择面板弹出来(选还是用户自己选)。
    /// 面板关掉后再刷一次,按钮颜色立刻跟上。
    func presentMicModePicker() {
        note("点了「宽谱」→ 请系统弹麦克风模式面板")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            refreshMicMode()
        }
    }

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
                            device: LiveKitConfig.defaultDevice)
        cfg.save()
        objectWillChange.send()
    }

    @discardableResult
    func prepareBroadcast() -> Bool {
        do {
            try cfg.prepareBroadcast()
            note("已为 \(cfg.device)-replaykit 准备单独发布权限")
            return true
        } catch {
            note("扩展配置失败: \(error.localizedDescription)")
            return false
        }
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
        room.onTranscript = { [weak self] type, who, audioS, text, gap, ts, raw in
            guard let self else { return }
            switch type {
            case "summary":
                // 会中提要:只追加,不顶走上面的定稿;每条都带手机本地时间(家里的 clock 不一定对得上)
                self.summaries.append(SummaryItem(clock: Self.stamp().prefix(5).description, text: text))
                if self.summaries.count > 60 { self.summaries.removeFirst(self.summaries.count - 60) }
            case "sumstatus":
                // 状态区:家里每 60 秒推一次(哪怕这轮不出提要)—— 显示的是"为什么没出"
                self.sumState = text
                if let m = raw["mode"] as? String, !m.isEmpty { self.sumMode = m }
                if let c = raw["code"] as? String, !c.isEmpty { self.sumCode = c }
            case "final":
                self.serverSeconds = audioS          // 「收」= 家里已识别的音频秒数
                if !text.isEmpty {
                    self.lines.append(TranscriptLine(who: who, source: raw["source"] as? String ?? "",
                                                     text: text, gap: gap, ts: ts))
                }
                self.partial = ""
                self.partialWho = ""
                self.partialSource = ""
            default:
                self.serverSeconds = audioS
                self.partial = text
                self.partialWho = who
                self.partialSource = raw["source"] as? String ?? ""
            }
        }
        // 从 Bundle 读真实版本(以前写死成 v0.2.0(build 11),截图里会误导人)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        note("App 启动,v\(ver)(build \(build), LiveKit)")
    }

    func toggle() { isRecording ? stop() : start() }

    /// 会中提要档位:自动 5 分钟 / 手动 10 分钟(手动更长 —— 在外面要等久一点才抓得到要点)。
    /// 切档 ≠ 立刻出一段:只是把下一次检查的周期换掉。
    /// 状态行不在这里写"已切到…":按钮的选中色已经表达了档位(用户 2026-10-16 指出重复),
    /// 真正的状态由家里每 60 秒推来的 sumstatus 决定。
    func setSumMode(_ m: String) {
        guard m != sumMode else { return }
        sumMode = m
        note("会中提要档位 → \(m == "auto" ? "自动" : "手动")")
        Task { await room.send(["type": "summode", "mode": m]) }
    }

    private func start() {
        lines = []
        partial = ""
        partialWho = ""
        recordedSeconds = 0
        serverSeconds = 0
        summaries = []                      // 新一场:提要列表与状态区都从零开始
        sumState = "等待提要…"
        sumCode = "wait_period"
        status = "连接中…"
        isRecording = true
        let cfg = self.cfg
        Task {
            if let d = pendingDisconnect { await d.value }   // 等上一次断开落地,避免同身份双连
            pendingDisconnect = nil
            do {
                try await room.connect(cfg)
                await room.send(["type": "summode", "mode": self.sumMode])   // 让家里跟上本机档位
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
