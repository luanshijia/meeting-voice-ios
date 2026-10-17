import SwiftUI
import ReplayKit

/// 广播扩展探针(阶段二前置):主 App 侧的读回与启动入口。
/// 它不参与录音链路,只在设置页里回答一个问题:
/// 「带扩展的包装上之后,App Group 能不能用、扩展到底有没有收到音频」。
enum BroadcastProbe {
    static let groupID = "group.com.luanshijia.voicememo"
    static let extensionBundleID = "com.luanshijia.voicememo.broadcast"
    static let fileName = "broadcast-probe.log"

    /// nil = entitlement 没被签进去(App Group 不可用),这是探针要抓的第一种失败
    /// 同时试几个候选名:免费自签下 SideStore 可能把团队号后缀注进去(实测见过
    /// group.com.SideStore.SideStore.458RP2552K 这种写法),我们把两种都试一遍,并显示命中的是哪个。
    static let groupCandidates = ["group.com.luanshijia.voicememo",
                                  "group.com.luanshijia.voicememo.458RP2552K"]
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

    /// 设置页那一行只显示【组名】:「可用 → 」三个字删掉(用户实测反馈:太占地方),
    /// 可用性交给颜色表达 —— 绿 = 可用,红 = 不可用。
    static func groupName() -> String {
        guard containerURL() != nil else {
            return "不可用(候选名都没命中)"
        }
        return matchedGroup ?? "?"
    }

    /// 读探针日志:**容错解码**(第 4 条,2026-10-17)。
    /// 原来用 `String(contentsOf:encoding:.utf8)` 做整份严格解码 —— 文件里只要有一处非法字节
    /// (扩展写到一半被读、或扩展被系统回收时留下半个汉字)就 `try?` 失败、静默返回 "",
    /// 设置页整块变空白,而且和「压根没有日志」长得一模一样,查不出是哪一种。
    /// 现在与 `tailText` 走同一条路:`String(decoding:as:UTF8.self)`,坏字节变替换符,不再整份丢弃;
    /// 同时把诊断值(字节数 / 行数 / 替换符个数)一并返回,让「读了但内容坏」在界面上看得见。
    static func logSnapshot(maxLines: Int = 60) -> (text: String, bytes: Int, lines: Int, badChars: Int) {
        guard let url = containerURL()?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else {
            return ("", 0, 0, 0)       // 没日志 / App Group 不可用:四值全零,界面据此说明是哪一种
        }
        let text = String(decoding: data, as: UTF8.self)
        let badChars = text.reduce(0) { $1 == "\u{FFFD}" ? $0 + 1 : $0 }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return (all.suffix(maxLines).joined(separator: "\n"), data.count, all.count, badChars)
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

    /// 整份探针日志(设置页「复制排错信息」用),带上限免得把大文件全读进内存
    /// 第 4 条(2026-10-17):这里原来也是严格解码 —— 日志一坏,连排错路径一起哑,故与 readLog 一并改成容错。
    static func fullLogText(limit: Int = 200_000) -> String {
        guard let url = containerURL()?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
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

/// 系统的广播启动器:点它 → 系统弹选择器 → 选「VoiceMemo 广播」→ 开始共享。
/// 注意:广播【必须】由用户手动启动,App 不能自动触发(这是 iOS 的硬规则)。
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastProbe.extensionBundleID
        picker.showsMicrophoneButton = true
        BroadcastPickerTrigger.picker = picker       // 交给 BroadcastPickerTrigger 程序触发
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// 程序化打开系统直播选择器。
/// 为什么要绕这一下:系统只给 RPSystemBroadcastPickerView 这个「自带外观的按钮」,外观不可改。
/// 早先的做法是把它透明地盖在自己画的按钮上 —— build 22 真机实测「点不动」。
/// 现在改成:它藏在最底层(1% 透明),我们自己的按钮调用 open() 去点它内部真正的 UIButton。
enum BroadcastPickerTrigger {
    static weak var picker: RPSystemBroadcastPickerView?
    static func open() {
        guard let picker else { return }
        for sub in picker.subviews {
            if let button = sub as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

struct AppGroupRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("App Group")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(BroadcastProbe.groupName())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(BroadcastProbe.containerURL() == nil ? Color.red : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }
}

/// 扩展那一行:显示 appex 的 bundle id,字体与颜色跟上一行 App Group 完全一致(用户口径)
struct ExtensionRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("扩展")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(BroadcastProbe.extensionBundleID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(BroadcastProbe.containerURL() == nil ? Color.red : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }
}

/// 扩展日志(会长/要滚 → 按用户口径放在设置页下方)。没日志时整块不显示
/// (以前那句「还没有探针日志:扩展从未启动过,或 App Group 不可用」已失效,按要求删掉)
struct ExtLogSection: View {
    @State private var logText = ""
    @State private var logStatus = ""
    @State private var statusWarn = false
    @State private var refreshedAt = ""

    var body: some View {
        Section {
            if !logText.isEmpty {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 240)
            }
            HStack(spacing: 12) {
                Button("刷新") { load() }
                Spacer()
                Button("清空") { BroadcastProbe.clearLog(); load() }
                    .foregroundStyle(.red)
            }
            // 第 4 条(2026-10-17):读完必须说清「读到什么」——
            // 以前读失败与没有日志都表现为这块整块不显示,分不清是哪种,只能靠猜。
            if !logStatus.isEmpty {
                Text(logStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(statusWarn ? Color.orange : Color.secondary)
            }
            if !refreshedAt.isEmpty {
                Text(refreshedAt).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } header: {
            Text("扩展日志")
        } footer: {
            Text("扩展每 3 秒写一行:计数、采样格式、App Group 组名、5A(对方声音)发送状态。主界面「扩展」按钮的三色判断也读这份文件。")
        }
        .onAppear { load() }
    }

    private func load() {
        let snap = BroadcastProbe.logSnapshot()
        logText = snap.text
        if snap.bytes == 0 {
            logStatus = "未读到日志(文件不存在,或 App Group 不可用)"
            statusWarn = true
        } else if snap.badChars > 0 {
            logStatus = "已读 \(snap.lines) 行 · \(snap.bytes) 字节 · \(snap.badChars) 处坏字节(已按替换符显示)"
            statusWarn = true
        } else {
            logStatus = "已读 \(snap.lines) 行 · \(snap.bytes) 字节"
            statusWarn = false
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        refreshedAt = "读取于 \(f.string(from: Date()))"
    }
}
