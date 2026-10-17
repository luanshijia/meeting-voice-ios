import AVFoundation
import CryptoKit
import Darwin
import Foundation
import LiveKit

/// 丙B-3 可行性探针（2026-10-17）：在**广播扩展进程**里跑一套 LiveKit，自己连房、自己发一路音频。
///
/// 它只回答三个问题，不做业务、不碰现有 5A 链路：
///   ① 扩展进程（系统给的上限约 50 MB）里装得下 SDK 吗？跑起来会不会被系统杀掉？
///   ② 能不能在扩展里 `connect` + 用「手动渲染」把音频轨发出去？
///   ③ 服务端房间里会不会真的多出第二个参与者、第二条音频轨？
///
/// 三个设计取舍（都是有意的）：
///   • 房间名用 `probe-ext`，**不是 `test`** —— 不撞用户真机会话，家里 agent 只订阅 `test`，不会去消费它；
///   • 音频内容先喂**静音** —— 探针验的是「通道能不能成立」，不是音质；接真实系统声是通道成立之后的事；
///   • 只在扩展里加，主 App 一行不改 —— 探针失败就整条分支丢掉，线上零影响。
final class ProbeRoom {
    private let log: (String) -> Void

    private let urlString = "wss://100.64.0.2:7443"
    private let roomName = "probe-ext"
    private let identity = "luan-iphone-replaykit-probe"
    private let apiKey = "devkey"      // 与家里 livekit-server --dev 一致
    private let apiSecret = "secret"

    private var room: Room?
    private var feeder: DispatchSourceTimer?
    private var fedChunks = 0
    private var started = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        log("probe 开始:房间=\(roomName) identity=\(identity)")
        Task { await connectAndPublish() }
    }

    func stop() {
        feeder?.cancel()
        feeder = nil
        let r = room
        room = nil
        log("probe 收尾:共喂 \(fedChunks) 块")
        Task { await r?.disconnect() }
    }

    // MARK: - 连接 + 发轨

    private func connectAndPublish() async {
        guard let token = makeToken() else {
            log("probe 失败:token 造不出来")
            return
        }
        do {
            let r = Room()
            try await r.connect(url: urlString, token: token)
            log("probe 已连上房间")

            // 手动渲染:不访问任何音频设备（扩展里本来也没有可用的麦克风上下文）。
            // 这是把「我们自己喂的 PCM」变成一条音频轨的唯一官方入口。
            do {
                try AudioManager.shared.setManualRenderingMode(true)
                log("probe 手动渲染已开")
            } catch {
                log("probe 手动渲染失败:\(error)")
            }

            try await r.localParticipant.setMicrophone(enabled: true)
            log("probe 音频轨已发布")

            room = r
            startFeeding()
        } catch {
            log("probe 连接失败:\(error)")
        }
    }

    /// 每 20 ms 喂一块静音（48 kHz 单声道 float32，960 帧）。
    /// 目的只是让音频轨持续有数据可发 —— 这样才能观察内存曲线和「会不会被杀」。
    private func startFeeding() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) else { return }
            buffer.frameLength = 960
            if let channel = buffer.floatChannelData {
                memset(channel[0], 0, Int(960) * MemoryLayout<Float>.size)
            }
            AudioManager.shared.mixer.capture(appAudio: buffer)
            self.fedChunks += 1
            if self.fedChunks % 150 == 0 {                     // 每 3 秒一行
                self.log("probe 喂 \(self.fedChunks) 块 · 进程剩余内存 \(Self.availableMB()) MB")
            }
        }
        timer.resume()
        feeder = timer
    }

    // MARK: - 诊断

    /// 进程还能用多少内存（MB）。越接近 0 越危险 —— 扩展被系统杀掉前就在这里露馅。
    private static func availableMB() -> String {
        let bytes = os_proc_available_memory()
        return String(format: "%.1f", Double(bytes) / 1024.0 / 1024.0)
    }

    // MARK: - token（与主 App 的 LiveKitConfig 同一套 HS256，避免扩展依赖主 App target 的代码）

    private func makeToken(ttl: TimeInterval = 4 * 3600) -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "nbf": now - 10,
            "exp": now + Int(ttl),
            "name": identity,
            "video": ["room": roomName, "roomJoin": true, "canPublish": true, "canSubscribe": false],
        ]
        guard let h = Self.jsonB64(header), let p = Self.jsonB64(payload) else { return nil }
        let signing = "\(h).\(p)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signing.utf8),
                                                  using: SymmetricKey(data: Data(apiSecret.utf8)))
        return "\(signing).\(Self.b64(Data(mac)))"
    }

    private static func jsonB64(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return b64(data)
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
