import SwiftUI

/// 站 2 的界面:服务器地址 + 开始/停止 + 滚动字幕。
/// 实时阶段只出文字(不分说话人);会后纪要由家里那侧另跑。
struct ContentView: View {
    @StateObject private var model = SessionModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
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
                    .onChange(of: model.partial) { _, _ in
                        withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
                    }
                    .onChange(of: model.lines.count) { _, newValue in
                        guard newValue > 0 else { return }
                        withAnimation { proxy.scrollTo(newValue - 1, anchor: .bottom) }
                    }
                }
            }
            .padding()
            .navigationTitle("MeetingVoice")
        }
    }
}

#Preview {
    ContentView()
}
