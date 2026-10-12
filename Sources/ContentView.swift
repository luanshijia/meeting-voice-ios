import SwiftUI

/// 主界面:没有大标题(省竖屏空间)、网址收进"设置"、转写文字按阅读优化。
/// 右上角三个数字:录(本地采集)/ 传(本地发出)/ 收(服务端确认收到,唯一可信)。
struct ContentView: View {
    @StateObject private var model = SessionModel()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    metric("录", model.audioSeconds, .primary)
                    metric("传", model.uploadedSeconds, .primary)
                    metric("收", model.serverSeconds,
                           (model.uploadedSeconds - model.serverSeconds) > 3 ? .red : .green)
                }

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                }
            }
            .padding(.top, 4)

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

            if model.reconnectCount > 0 {
                Text("本次断线重连 \(model.reconnectCount) 次(音频已续传,可能分多个文件)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 20))
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                        if !model.partial.isEmpty {
                            Text(model.partial)
                                .font(.system(size: 20))
                                .lineSpacing(8)
                                .foregroundStyle(.blue)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
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

/// 设置页:网址、黑匣子信息都收在这里,平时主界面干净
struct SettingsSheet: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址") {
                    TextField("wss://100.64.0.2:8790/stream", text: $model.serverURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.system(size: 15, design: .monospaced))
                    Button("恢复默认地址") { model.resetServerURL() }
                }

                if let crash = CrashLog.previousCrashFile ?? CrashLog.lastFailure {
                    Section("上次异常(黑匣子)") {
                        Text(crash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("清空") { model.clearCrashNote() }
                    }
                }
                if let steps = CrashLog.previousSteps {
                    Section("崩溃前最近步骤") {
                        Text(steps).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let counters = CrashLog.counters {
                    Section("计数") {
                        Text(counters).font(.system(size: 11, design: .monospaced))
                    }
                }
                Section {
                    Text("v0.1.4 · build 9 · wss + 自家 CA")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
