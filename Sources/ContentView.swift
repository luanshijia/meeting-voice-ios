import SwiftUI

/// 站 2 的界面:服务器地址 + 开始/停止 + 滚动字幕。
/// 顶部那块是"黑匣子":有崩溃就显示崩因 + 崩溃前最后 30 步流水。
struct ContentView: View {
    @StateObject private var model = SessionModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if model.crashNote != nil || model.stepNote != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("上次异常(黑匣子)").font(.caption).bold()
                            Spacer()
                            Button("清空") { model.clearCrashNote() }.font(.caption)
                        }
                        if let c = model.crashNote {
                            Text(c).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                        if let s = model.stepNote {
                            Text("最近步骤:").font(.caption2).foregroundStyle(.secondary)
                            Text(s).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                        if let n = model.counterNote {
                            Text("计数:" + n).font(.system(size: 10, design: .monospaced))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(8)
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
                Text("v0.1.2 · build 7 · wss + 自家 CA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
