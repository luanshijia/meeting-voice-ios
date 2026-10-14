import SwiftUI
import UIKit

/// 主界面(阶段三)。
/// 顶部一行四个按钮,颜色当指示灯用:
///   网络 = 能不能连上家里(蓝=通 / 灰=不通或没测)
///   开启 = 录音开关(红=录着)
///   扩展 = 系统直播三态(灰=确定没开播 / 蓝=已开播但没看到麦克风输入,是猜的 / 红=确定收到麦克风输入)
///   设置 = 连接参数、日志排错、黑匣子
/// 下面:上 2/3 滚动字幕,下 1/3 实时总结(后端待接入,先留位)。
struct ContentView: View {
    @StateObject private var model = SessionModel()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    // 顶部按钮状态
    @State private var netOK: Bool? = nil            // nil = 还没测过
    @State private var broadcastAlive = false        // 扩展写过「=== 扩展启动」且没写「结束」
    @State private var broadcastMicFrames = 0        // 扩展记下的麦克风采样帧数
    @State private var summaryText = ""              // 实时总结(站 4 后端接入前为空)

    var body: some View {
        VStack(spacing: 6) {
            buttonRow
            statusRow
            paneSplit
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
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
            recordButton
            extButton
            settingsButton
        }
    }

    /// 网络:只有显示功能。点了当场测一次;启动和回到前台也会自动测。
    private var netButton: some View {
        Button {
            Task { await refreshNet() }
        } label: {
            buttonLabel(icon: netOK == true ? "wifi" : "wifi.slash", title: "网络")
        }
        .buttonStyle(.bordered)
        .tint(netOK == true ? Color.blue : Color.gray)
    }

    /// 开启 / 停止:切换状态
    private var recordButton: some View {
        Button {
            model.toggle()
        } label: {
            buttonLabel(icon: model.isRecording ? "stop.circle.fill" : "record.circle",
                        title: model.isRecording ? "停止" : "开启")
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? Color.red : Color.accentColor)
    }

    /// 扩展:点它调出系统直播选择器。
    /// 三态颜色:灰=确定没开播;蓝=已开播但还没看到麦克风输入(不确定,是猜的);红=确定收到麦克风输入。
    /// 为什么只能猜:系统那个「麦克风」开关的状态 App 读不到(iOS 没给接口),只能靠扩展有没有收到音频反推。
    private var extButton: some View {
        ZStack {
            buttonLabel(icon: "dot.radiowaves.left.and.right", title: extTitle)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(extColor, lineWidth: 1.5)
                )
            // 系统组件盖在上面:看得见的是我们画的按钮,点得到的是它(它自己会弹选择器)
            BroadcastPickerView()
                .frame(maxWidth: .infinity, minHeight: 34)
                .opacity(0.02)
        }
    }

    private var extTitle: String {
        if !broadcastAlive { return "扩展" }
        return broadcastMicFrames > 0 ? "扩展·收" : "扩展·?"
    }

    private var extColor: Color {
        if !broadcastAlive { return .gray }
        return broadcastMicFrames > 0 ? .red : .blue
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            buttonLabel(icon: "gearshape", title: "设置")
        }
        .buttonStyle(.bordered)
        .tint(.gray)
    }

    private func buttonLabel(icon: String, title: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: icon).font(.system(size: 14))
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    // MARK: - 状态行(短文字 + 三个数)

    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(model.status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                metric("录", model.recordedSeconds, .primary)
                metric("收", model.serverSeconds,
                       (model.recordedSeconds - model.serverSeconds) > 5 ? .red : .green)
                metric("句", Double(model.lines.count), .primary)
            }
        }
    }

    // MARK: - 版面:上 2/3 转写,下 1/3 总结

    private var paneSplit: some View {
        GeometryReader { geo in
            let gap: CGFloat = 8
            let total = geo.size.height
            VStack(spacing: gap) {
                transcript.frame(height: max(90, (total - gap) * 2 / 3))
                summaryPane.frame(height: max(60, (total - gap) / 3))
            }
        }
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("实时总结").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if summaryText.isEmpty {
                    Text("待接入").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(summaryText.isEmpty
                     ? "（这一段以后会显示滚动总结:每 30 秒把新增的转写压成几条要点。总结后端还没接入,先占位。）"
                     : summaryText)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(summaryText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(model.lines.enumerated()), id: \.element.id) { idx, line in
                        paragraph(who: line.who, text: line.text, color: .primary)
                            .id(idx)
                    }
                    if !model.partial.isEmpty {
                        paragraph(who: model.partialWho, text: model.partial, color: .blue)
                            .id("partial")
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.partial) { _, newValue in
                guard !newValue.isEmpty else { return }
                proxy.scrollTo("partial", anchor: .bottom)
            }
            .onChange(of: model.lines.count) { _, newValue in
                guard newValue > 0 else { return }
                proxy.scrollTo(newValue - 1, anchor: .bottom)
            }
        }
    }

    private func paragraph(who: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !who.isEmpty {
                Text(who).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: -1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.0f", value) : "—")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: 28)
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
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // 每 3 秒看一次扩展状态
            await refreshExt()
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
                connectionSection
                ProbeSection()
                logSection
                crashSection
                stepsSection
                versionSection
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
            TextField("ws://100.64.0.2:7880", text: $model.serverURL)
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
            HStack {
                Text("身份").foregroundStyle(.secondary)
                Spacer()
                Text(model.identity).font(.system(size: 13, design: .monospaced))
            }
            Button("恢复默认连接参数") { model.resetToDefaults() }
        } header: {
            Text("连接参数")
        } footer: {
            Text("开发模式:密钥存在 App 内,对应家里 livekit-server --dev。仅内网测试用,正式版应改成服务端发 token。")
        }
    }

    /// 记录日志 + 排错:一键把连接参数和探针日志复制出来,直接贴回来或存档
    private var logSection: some View {
        Section {
            Button {
                let log = BroadcastProbe.fullLogText()
                UIPasteboard.general.string = log
                copiedAt = log.isEmpty ? "没有日志可复制(扩展没启动过?)" : "已复制 \(log.count) 字符"
            } label: {
                Label("复制探针日志", systemImage: "doc.on.doc")
            }
            Button {
                let bundle = """
                server=\(model.serverURL)
                identity=\(model.identity)
                status=\(model.status)
                录=\(Int(model.recordedSeconds)) 收=\(Int(model.serverSeconds)) 句=\(model.lines.count)

                \(BroadcastProbe.fullLogText())
                """
                UIPasteboard.general.string = bundle
                copiedAt = "已复制(连接参数 + 状态 + 日志)"
            } label: {
                Label("复制全套排错信息", systemImage: "square.and.arrow.up")
            }
            if !copiedAt.isEmpty {
                Text(copiedAt).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("日志与排错")
        } footer: {
            Text("排错顺序:①「网络」按钮看路通不通;②「扩展」按钮看扩展起没起、麦克风有没有在收(灰/蓝/红三态);③在这里复制日志贴回来。")
        }
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

    private var versionSection: some View {
        Section {
            // 从包里读真版本,别再写死(以前写死的 "build 12" 会误导排查)
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
