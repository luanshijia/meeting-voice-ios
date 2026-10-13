import SwiftUI

/// 主界面(阶段三最小版):没有大标题、网址收进"设置"、转写按阅读排版。
/// 三个数字:录(本地推流秒数)/ 收(家里已识别的秒数,agent 回传)/ 句(定稿句数)。
struct ContentView: View {
    @StateObject private var model = SessionModel()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            header
            connectButton
            transcript
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                metric("录", model.recordedSeconds, .primary)
                metric("收", model.serverSeconds,
                       (model.recordedSeconds - model.serverSeconds) > 5 ? .red : .green)
                metric("句", Double(model.lines.count), .primary)
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 17))
            }
        }
        .padding(.top, 4)
    }

    private var connectButton: some View {
        Button {
            model.toggle()
        } label: {
            Label(model.isRecording ? "停止" : "开始录音",
                  systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                .frame(maxWidth: .infinity)
                .font(.title3.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .controlSize(.large)
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
                Text(who).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 20))
                .lineSpacing(8)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: -1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.0f", value) : "—")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: 30)
    }
}

/// 设置页:连接参数、黑匣子信息都收在这里,平时主界面干净
struct SettingsSheet: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                ProbeSection()
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
            Text("v0.3.0 · build 12 · 扩展探针")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
