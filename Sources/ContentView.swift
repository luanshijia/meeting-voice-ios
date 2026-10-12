import SwiftUI

/// 站 0b 骨架:只为验证「云端出包 → SideStore 装机」这条通路。
/// 真正的录音 / 推流 / 滚动字幕在站 2 写。
struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("MeetingVoice 骨架")
                .font(.title.bold())

            Text("版本 0.1 · 仅用于验证 CI 出包与装机通路")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                taps += 1
            } label: {
                Text("点我:\(taps)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Text("能装到手机上、能点这个按钮,这站就算过。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

#Preview {
    ContentView()
}
