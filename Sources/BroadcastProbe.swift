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
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func groupStatus() -> String {
        guard let url = containerURL() else { return "不可用(entitlement 没签进去)" }
        return "可用 → \(url.lastPathComponent)"
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
                BroadcastPickerView()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("点左边的图标 → 选「MeetingVoice 广播」")
                        .font(.system(size: 13))
                    Text("探针不传输音频,只记录扩展有没有收到声音")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
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
            Text("三种失败要分开看:①侧载装不上=免费自签不支持带扩展的包;②App Group 显示不可用=entitlement 没签进去(要在 SideStore 里长按 App 那行做一次 Resign);③可用但日志为空=扩展没被启动或没收到音频。")
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
