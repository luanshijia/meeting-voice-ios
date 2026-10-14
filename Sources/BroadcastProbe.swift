import SwiftUI
import ReplayKit

/// 广播扩展探针(阶段二前置):主 App 侧的读回与启动入口。
/// 它不参与录音链路,只在设置页里回答一个问题:
/// 「带扩展的包装上之后,App Group 能不能用、扩展到底有没有收到音频」。
enum BroadcastProbe {
    static let groupID = "group.com.luanshijia.meetingvoice"
    static let extensionBundleID = "com.luanshijia.meetingvoice.broadcast"
    static let fileName = "broadcast-probe.log"

    /// nil = entitlement 没被签进去(App Group 不可用),这是探针要抓的第一种失败
    /// 同时试几个候选名:免费自签下 SideStore 可能把团队号后缀注进去(实测见过
    /// group.com.SideStore.SideStore.458RP2552K 这种写法),我们把两种都试一遍,并显示命中的是哪个。
    static let groupCandidates = ["group.com.luanshijia.meetingvoice",
                                  "group.com.luanshijia.meetingvoice.458RP2552K"]
    static private(set) var matchedGroup: String?

    static func containerURL() -> URL? {
        if let matchedGroup,
           let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: matchedGroup) {
            return u
        }
        for id in groupCandidates {
            if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                matchedGroup = id
                return u
            }
        }
        return nil
    }

    static func groupStatus() -> String {
        guard containerURL() != nil else {
            return "不可用(试过 \(groupCandidates.count) 个候选名,都没命中)"
        }
        // 显示【命中的组名】而不是容器 UUID —— UUID 看不出 SideStore 到底注进了哪个名字,
        // 而那个名字决定了扩展要试哪个(上一版两边名字不一致,就是 App 绿、扩展打不开的原因)。
        return "可用 → \(matchedGroup ?? "?")"
    }

    static func readLog(maxLines: Int = 60) -> String {
        guard let url = containerURL()?.appendingPathComponent(fileName),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(还没有探针日志:扩展从未启动过,或 App Group 不可用)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func clearLog() {
        guard let url = containerURL()?.appendingPathComponent(fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 直播是否在进行:**只认扩展显式写的标记行**
    /// (启动时 `=== 扩展启动`、收尾时 `=== 扩展结束`),不做任何超时猜测。
    /// 为什么不要"N 秒没写入就算停":实测停顿期间可能整段时间都没有新行
    /// (音频静音超过 30 秒后扩展会按设计关掉那条传输连接,此时扩展仍在直播),
    /// 超时会把正在直播的静音时段误判成已停止 —— 用户实测反馈"没必要",故去掉。
    static func isBroadcasting() -> Bool {
        guard let url = containerURL()?.appendingPathComponent(fileName) else { return false }
        var alive = false
        for line in tailText(url: url, bytes: 8192).split(separator: "\n") {
            if line.contains("=== 扩展启动") { alive = true }
            else if line.contains("=== 扩展结束") { alive = false }
        }
        return alive
    }

    /// 扩展最近一次记下的麦克风采样帧数(>0 = 确实收到麦克风音频)。
    /// 用途:主界面「扩展」按钮变红 —— 只有真拿到麦克风输入,才敢说"麦克风开着"。
    /// 蓝色是留给"已开播但还没看到麦克风输入"的:那是不确定状态,不硬下结论。
    static func micFramesSeen() -> Int {
        guard let url = containerURL()?.appendingPathComponent(fileName) else { return 0 }
        var last = 0
        for line in tailText(url: url, bytes: 16384).split(separator: "\n") where line.contains("计数 回调") {
            guard let marker = line.range(of: "audioMic=") else { continue }
            let digits = line[marker.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits) { last = value }
        }
        return last
    }

    /// 整份探针日志(设置页「复制日志」用),带上限免得把大文件全读进内存
    static func fullLogText(limit: Int = 200_000) -> String {
        guard let url = containerURL()?.appendingPathComponent(fileName),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.count > limit ? String(text.suffix(limit)) : text
    }

    /// 只读文件末尾若干字节,避免直播久了(每 3 秒一行)把整份文件读进内存。
    private static func tailText(url: URL, bytes: UInt64) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > bytes ? size - bytes : 0)
        let data = (try? fh.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 系统的广播启动器:点它 → 系统弹选择器 → 选「MeetingVoice 广播」→ 开始共享。
/// 注意:广播【必须】由用户手动启动,App 不能自动触发(这是 iOS 的硬规则)。
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastProbe.extensionBundleID
        picker.showsMicrophoneButton = true
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct ProbeSection: View {
    @State private var logText = ""
    @State private var refreshedAt = ""

    var body: some View {
        Section {
            HStack {
                Text("App Group")
                Spacer()
                Text(BroadcastProbe.groupStatus())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(BroadcastProbe.containerURL() == nil ? .red : .green)
            }
            HStack {
                Text("扩展")
                Spacer()
                Text(BroadcastProbe.extensionBundleID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("刷新日志") { load() }
                Spacer()
                Button("清空日志") { BroadcastProbe.clearLog(); load() }
                    .foregroundStyle(.red)
            }
            if !refreshedAt.isEmpty {
                Text(refreshedAt).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
        } header: {
            Text("广播扩展探针(阶段二)")
        } footer: {
            Text("三条回信道:①「对方的声音」用 https 每 0.5 秒一块发回家里的 /ingest(5A,这是分人的关键);②App Group 共享文件(主 App 读回日志);③每 3 秒把计数发到家里 /probe(不依赖 App Group 的保底诊断)。三种失败要分开看:①侧载装不上=免费自签不支持带扩展的包;②App Group 显示不可用=entitlement 没被签进来;③可用但日志为空=扩展没被启动或没收到音频。")
        }
        .onAppear { load() }
    }

    private func load() {
        logText = BroadcastProbe.readLog()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        refreshedAt = "读取于 \(f.string(from: Date()))"
    }
}
