import SwiftUI

/// 站 2 的界面:服务器地址 + 开始/停止 + 滚动字幕。
/// 实时阶段只出文字(不分说话人);会后纪要由家里那侧另跑。
struct ContentView: View {
    @StateObject private var model = SessionModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if let crash = model.crashNote {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("上次崩溃的原因(黑匣子)")
                            .font(.caption).bold()
                        Text(crash)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        if let c = CrashLog.counters {
                            Text("崩溃前计数:" + c).font(.system(size: 11, design: .monospaced))
                        }
                        Button("清空这条") { model.clearCrashNote() }
                            .font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(8)
                } else if let note = model.lastRunNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    TextField("服务器地址", text: $model.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Text(model.audioSeconds > 0 ? String(format: "%.0fs", model.audioSeconds) : "—")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Button {
                    model.toggle()
                } label: {
                    Label(model.isRecording ? "停止" : "开始录音",
                          systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.lines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                            if !model.partial.isEmpty {
                                Text(model.partial)
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("partial")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // 不再每一帧都带动画滚动(20 次/秒的动画滚动是崩溃隐患),改成安安静静跟到底
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
            .padding()
            .navigationTitle("MeetingVoice")
            .overlay(alignment: .bottom) {
                Text("v0.1.1 · build 5 · wss + 自家 CA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
