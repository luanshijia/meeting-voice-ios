import SwiftUI
import UIKit

/// 主界面(阶段三)。
/// 顶部一行四个按钮,颜色当指示灯用:
///   网络 = 能不能连上家里(蓝=通 / 灰=不通或没测)
///   开启 = 录音开关(红=录着)
///   扩展 = 系统直播三态(灰=确定没开播 / 蓝=已开播但没看到麦克风输入,是猜的 / 红=确定收到麦克风输入)
///   设置 = 连接参数、日志排错、黑匣子
/// 下面:滚动字幕占满整屏(2026-10-15:下 1/3 的「实时总结」按用户要求整个删除,
/// 家里那侧也不再生成/推送任何提要 —— 见 notes/HANDOFF.md §12)。
struct ContentView: View {
    @StateObject private var model = SessionModel()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    // 顶部按钮状态
    @State private var netOK: Bool? = nil            // nil = 还没测过
    @State private var broadcastAlive = false        // 扩展写过「=== 扩展启动」且没写「结束」
    @State private var broadcastMicFrames = 0        // 扩展记下的麦克风采样帧数

    var body: some View {
        VStack(spacing: 6) {
            buttonRow                       // 顶部只剩四个按钮(状态行搬到屏幕最下方)
            transcript                      // 提要面板已删 → 字幕铺满整屏
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        // 状态 + 录/收/句 钉在屏幕最下方:占的是系统本来留给 home 指示条的那条空白带,
        // 等于白捡一行高度 —— 上面 2/3 转写和 1/3 总结各多占几十点。
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .task { await refreshLoop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshExt(); await refreshNet() } }
        }
    }

    // MARK: - 顶部四个按钮(一行,等宽)

    private var buttonRow: some View {
        HStack(spacing: 6) {
            netButton
            micModeButton
            recordButton
            extButton
            settingsButton
        }
    }

    /// 网络:只有显示功能。点了当场测一次;启动和回到前台也会自动测。
    private var netButton: some View {
        flatButton(icon: netOK == true ? "wifi" : "wifi.slash", title: "网络",
                   fill: (netOK == true ? Color.blue : Color.gray).opacity(0.18),
                   fg: netOK == true ? Color.blue : Color.gray) {
            Task { await refreshNet() }
        }
    }

    /// 宽谱:点它请系统把「麦克风模式」面板弹出来(App 不能替你设,只能叫面板)。
    /// 底色当状态灯:当前是宽谱 = 实心蓝;其它模式 / 未授权 = 灰(用户口径 2026-10-15)。
    private var micModeButton: some View {
        flatButton(icon: "waveform", title: "宽谱",
                   fill: model.micIsWide ? Color.blue : Color.secondary.opacity(0.25),
                   fg: model.micIsWide ? .white : .primary) {
            model.presentMicModePicker()
        }
    }

    /// 开启 / 停止:切换状态
    private var recordButton: some View {
        flatButton(icon: model.isRecording ? "stop.circle.fill" : "record.circle",
                   title: model.isRecording ? "停止" : "开启",
                   fill: model.isRecording ? Color.red : Color.accentColor,
                   fg: .white) {
            model.toggle()
        }
    }

    /// 扩展:点它调出系统直播选择器。
    /// 三态颜色:灰=确定没开播;蓝=已开播但还没看到麦克风输入(不确定,是猜的);红=确定收到麦克风输入。
    /// 为什么只能猜:系统那个「麦克风」开关的状态 App 读不到(iOS 没给接口),只能靠扩展有没有收到音频反推。
    private var extButton: some View {
        ZStack {
            // 系统组件藏到最底层(1% 透明):它的外观不能改,只负责被下面那个按钮程序触发
            BroadcastPickerView()
                .frame(width: 44, height: 44)
                .opacity(0.01)
            Button {
                BroadcastPickerTrigger.open()
            } label: {
                buttonLabel(icon: "dot.radiowaves.left.and.right", title: extTitle,
                            fg: broadcastAlive ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 7).fill(extFill)
                    )
            }
            .buttonStyle(.plain)                      // 整块底色都算点击区
        }
    }

    /// 整块底色随状态变(用户要求:不要只有边框变色)
    private var extFill: Color {
        if !broadcastAlive { return Color.secondary.opacity(0.25) }  // 灰:确定没开播
        return broadcastMicFrames > 0 ? Color.red : Color.blue       // 红:确定收到麦克风 / 蓝:不确定
    }

    private var extTitle: String {
        if !broadcastAlive { return "扩展" }
        return broadcastMicFrames > 0 ? "扩展·收" : "扩展·?"
    }

    private var settingsButton: some View {
        flatButton(icon: "gearshape", title: "设置",
                   fill: Color.blue.opacity(0.18), fg: .blue) {
            showSettings = true
        }
    }

    /// 四个按钮共用的标签几何:图标 + 小字,块高固定 34(就是「扩展」那块的高度)。
    /// fg:文字/图标颜色,由调用处按状态给(灰/蓝/红/白)。
    private func buttonLabel(icon: String, title: String, fg: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Image(systemName: icon).font(.system(size: 14))
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    /// 自绘的四等分按钮:整块圆角底色、块高与「扩展」完全一致。
    /// 为什么不用系统 .bordered/.borderedProminent:系统会在内容上下各加一圈内边距,
    /// 「网络/开启/设置」比「扩展」高出一截 —— 一行按钮高低不齐还白占屏幕(用户实测反馈)。
    private func flatButton(icon: String, title: String, fill: Color, fg: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            buttonLabel(icon: icon, title: title, fg: fg)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 屏幕最下方一行(状态 + 三个数)

    /// 一行放完全部:左边状态文字、右边「录 12 收 12 句 3」。
    /// 两处细节(用户口径):① 数字不再压成上下两行;② 底色一路铺到屏幕底边(绕开安全区),
    /// 视觉上就是贴着屏幕圆角底边的一道,而不是浮在中间的一条。
    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(model.status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            // 用户口径(2026-10-15):最下一行 = 网络状态 + 麦克风状态 + 录/收/句
            inlineText("网络", netOK == true ? "通" : "断", netOK == true ? .blue : .secondary)
            inlineText("麦克风", model.micModeText, model.micIsWide ? .blue : .secondary)
            inlineMetric("录", model.recordedSeconds, .primary)
            inlineMetric("收", model.serverSeconds,
                         (model.recordedSeconds - model.serverSeconds) > 5 ? .red : .green)
            inlineMetric("句", Double(model.lines.count), .primary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .padding(.bottom, 1)
        .background(
            Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
        )
    }

    /// 「标签 + 短文本」横向排(网络/麦克风这类状态用)
    private func inlineText(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }
        .fixedSize()
    }

    /// 「标签 + 数字」横向排(以前是标签一行、数字一行,占两行高度)
    private func inlineMetric(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.0f", value) : "—")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .fixedSize()
    }

    /// 转写区。渲染规则(用户口径):
    ///   ① 换人就换段 —— 说话人名字只在他换人时出现一次(且屏幕上看不到机器身份,自己那一路显示「我」);
    ///   ② 同一人两段之间静音 ≥2.4 秒 → 把 ~~~ 接在**上一段末尾同一行**(2026-10-15 用户口径:
    ///      以前 ~~~ 单独占一行会切断段落流,现在不要分行);
    ///   ③ 同一人一口气说很久 → 按标点换行(约 100 字一段)。
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(displayRows) { row in
                        paragraph(who: row.who, text: row.text, tail: row.tail, color: .primary)
                            .id(row.id)
                    }
                    if !model.partial.isEmpty {
                        paragraph(who: displayWho(model.partialWho), text: model.partial, color: .blue)
                            .id("partial")
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.partial) { _, newValue in
                guard !newValue.isEmpty else { return }
                proxy.scrollTo("partial", anchor: .bottom)
            }
            .onChange(of: model.lines.count) { _, _ in
                guard let last = displayRows.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - 转写渲染(分人 / 停顿 / 超长换行)

    /// 界面上的一段转写。停顿符号 ~~~ 不再自成一行,而是接在段落末尾(tail)。
    private struct DisplayRow: Identifiable {
        let id: String
        let who: String        // 空 = 同一人接着说,不重复显示说话人
        let text: String
        let tail: String       // 非空 = 这段结束后的停顿标记(~~~)
    }

    /// 静音超过这么久,才在同一人的两段之间显示 ~~~(沿用家里断句阈值 2.4 秒)
    private static let gapThreshold: Double = 2.4

    private var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []
        var prevWho = ""
        for (idx, line) in model.lines.enumerated() {
            let sameSpeaker = (line.who == prevWho)
            if sameSpeaker, let gap = line.gap, gap >= Self.gapThreshold, !rows.isEmpty {
                // ~~~ 接在上一段末尾同一行(不再单独占一行、不再切断段落流)
                let last = rows[rows.count - 1]
                rows[rows.count - 1] = DisplayRow(id: last.id, who: last.who,
                                                  text: last.text, tail: Self.gapLabel(gap))
            }
            rows.append(DisplayRow(id: "line-\(idx)", who: sameSpeaker ? "" : displayWho(line.who),
                                   text: Self.wrap(line.text), tail: ""))
            prevWho = line.who
        }
        return rows
    }

    /// 屏幕上不显示机器身份(用户口径:不要出现 luan-luxin):
    /// 自己那一路(同一身份)显示「我」,扩展那一路本来就是「对方」,其它原样。
    private func displayWho(_ who: String) -> String {
        who.isEmpty ? who : (who == model.identity ? "我" : who)
    }

    /// ~~~ 的文案:超过 30 秒带上时长(用户口径),否则就一个 ~~~。
    private static func gapLabel(_ seconds: Double) -> String {
        guard seconds >= 30 else { return "~~~" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return s == 0 ? "~~~ \(m)分钟" : "~~~ \(m)分\(s)秒"
    }

    /// 同一人一口气说很久时,按标点换行,手机上一眼能读完(约 100 字一段)。
    /// 只插换行符、不拆成多段 —— 视觉上仍是一段话。
    private static func wrap(_ text: String, limit: Int = 100) -> String {
        guard text.count > limit else { return text }
        var out = ""
        var sinceBreak = 0
        for ch in text {
            out.append(ch)
            sinceBreak += 1
            if sinceBreak >= limit {
                out.append("\n")
                sinceBreak = 0
            } else if sinceBreak >= limit - 20, "，。！？；、".contains(ch) {
                out.append("\n")
                sinceBreak = 0
            }
        }
        return out
    }

    private func paragraph(who: String, text: String, tail: String = "", color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !who.isEmpty {
                Text(who).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if tail.isEmpty {
                Text(text)
                    .font(.system(size: 15))          // 用户口径 2026-10-15:字幕字号调小 2 号(17 → 15)
                    .lineSpacing(6)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
            } else {
                // 停顿标记跟在正文尾部同一行,小一号、灰一点
                (Text(text).font(.system(size: 15)).foregroundColor(color)
                 + Text("  " + tail).font(.system(size: 12)).foregroundColor(.secondary))
                    .lineSpacing(6)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 刷新

    private func refreshExt() async {
        broadcastAlive = BroadcastProbe.isBroadcasting()
        broadcastMicFrames = BroadcastProbe.micFramesSeen()
    }

    private func refreshNet() async {
        guard let hp = NetProbe.hostPort(from: model.serverURL) else { netOK = false; return }
        netOK = await NetProbe.check(host: hp.host, port: hp.port)
    }

    private func refreshLoop() async {
        await refreshExt()
        await refreshNet()
        model.refreshMicMode()
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // 每 3 秒看一次扩展状态 + 麦克风模式
            await refreshExt()
            model.refreshMicMode()
            tick += 1
            if tick % 5 == 0 { await refreshNet() }             // 每 15 秒顺手探一次网络
        }
    }
}

/// 设置页:连接参数、黑匣子信息都收在这里,平时主界面干净
struct SettingsSheet: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAt = ""

    var body: some View {
        NavigationStack {
            Form {
                stateSection          // 固定信息(环境 / 身份 / 版本)—— 按用户口径放最上面
                connectionSection     // 固定(可编辑)
                copySection           // 固定(一个按钮)
                ExtLogSection()       // 会长/要滚的全部集中在下面
                stepsSection
                crashSection          // 有才显示
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("wss://100.64.0.2:7443", text: $model.serverURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(.system(size: 14, design: .monospaced))
            TextField("API Key", text: $model.apiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 14, design: .monospaced))
            TextField("API Secret", text: $model.apiSecret)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 14, design: .monospaced))
            Button("恢复默认连接参数") { model.resetToDefaults() }
        } header: {
            Text("连接参数")
        } footer: {
            Text("地址填家里的 TLS 代理 wss://100.64.0.2:7443。开发模式:key/secret 存在 App 内(对应家里的 livekit-server --dev),正式版应改成服务端发 token。")
        }
    }

    /// 排错:一个按钮把「连接参数 + 状态 + 环境 + 扩展日志」一次复制走。
    /// (以前是两个按钮——「复制探针日志」与「复制全套排错信息」,信息还重叠,已并成一个。)
    private var copySection: some View {
        Section {
            Button {
                UIPasteboard.general.string = debugBundle
                copiedAt = "已复制 \(debugBundle.count) 字符(连接参数 + 状态 + 环境 + 扩展日志)"
            } label: {
                Label("复制排错信息", systemImage: "square.and.arrow.up")
            }
            if !copiedAt.isEmpty {
                Text(copiedAt).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("排错")
        } footer: {
            Text("顺序:①「网络」按钮看路通不通;②「扩展」按钮看扩展起没起、麦克风有没有在收(灰/蓝/红三态);③点这里复制,贴回来给我。")
        }
    }

    /// 复制走的内容:一眼能看全「这台手机现在是什么状态」
    private var debugBundle: String {
        """
        server=\(model.serverURL)
        identity=\(model.identity)
        status=\(model.status)
        录=\(Int(model.recordedSeconds)) 收=\(Int(model.serverSeconds)) 句=\(model.lines.count)
        麦克风模式=\(model.micModeText)(宽谱=\(model.micIsWide))
        App Group=\(BroadcastProbe.groupName())
        扩展=\(BroadcastProbe.extensionBundleID)
        version=\(appVersion)

        \(BroadcastProbe.fullLogText())
        """
    }

    @ViewBuilder private var crashSection: some View {
        if let crash = CrashLog.previousCrashFile {
            Section("上次异常(黑匣子文件)") {
                Text(crash).font(.system(size: 11, design: .monospaced))
                Button("清空黑匣子") { CrashLog.clear() }
            }
        } else if let failed = CrashLog.lastFailure {
            Section("上次异常") {
                Text(failed).font(.system(size: 11, design: .monospaced))
                Button("清空黑匣子") { CrashLog.clear() }
            }
        }
    }

    @ViewBuilder private var stepsSection: some View {
        if !model.notes.isEmpty {
            Section("最近步骤") {
                Text(model.notesText).font(.system(size: 10, design: .monospaced))
            }
        }
    }

    // MARK: - 状态段(全固定 → 放设置页最上面)

    private var stateSection: some View {
        Section {
            AppGroupRow()
            ExtensionRow()
            valueRow("身份", model.identity)
            valueRow("版本", appVersion)
        } header: {
            Text("状态")
        }
    }

    /// 值那一列统一款式:等宽小字 + 绿色,与 App Group / 扩展 两行完全一致
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }

    /// 版本从包里读真值(以前写死 "build 12",排查时会误导)
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) · build \(b)"
    }
}

#Preview {
    ContentView()
}
