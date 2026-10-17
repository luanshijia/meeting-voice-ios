import Foundation
import LiveKit

/// LiveKit 房间的薄封装:连/断、开关麦克风、把收到的文字回调出去。
/// 传输、加密(DTLS-SRTP)、断线重连、ICE 都由 SDK 负责 —— 这正是换到 WebRTC 的目的。
@MainActor
final class VoiceRoom: NSObject {
    private var room: Room?

    var onState: ((String) -> Void)?
    var onNote: ((String) -> Void)?
    /// (类型 partial/final/summary, 说话人, 服务端已识别的音频秒数, 文字, 前面静了多久, 绝对时间戳)
    /// gap 为 nil = 服务端没测出来(比如刚重连);ts 为 0 = 老服务端没给。
    var onTranscript: ((String, String, Double, String, Double?, Double, [String: Any]) -> Void)?
    var onEnded: ((String) -> Void)?

    var isConnected: Bool { room?.connectionState == .connected }

    /// 往房间里发一条自己的数据消息(topic=stt,与 agent 回传同一条通道,可靠送达)。
    /// 用途:「实时总结」按钮点一次 → 请家里立刻出一段总结。
    func send(_ payload: [String: Any]) async {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            // 2.17.0 的 API 是 publish(data:options:);reliable=true 保证这条请求不丢
            try await room.localParticipant.publish(data: data,
                                                    options: DataPublishOptions(topic: "stt", reliable: true))
        } catch {
            onNote?("发消息失败:\(error.localizedDescription)")
        }
    }

    @discardableResult
    func connect(_ cfg: LiveKitConfig) async throws -> Room {
        guard let token = cfg.makeToken() else {
            throw NSError(domain: "VoiceMemo", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "token 参数不合法"])
        }
        let newRoom = Room()
        newRoom.add(delegate: self)
        self.room = newRoom
        onNote?("发起连接 \(cfg.url) 身份=\(cfg.identity)")
        do {
            try await newRoom.connect(url: cfg.url, token: token)
            try await newRoom.localParticipant.setMicrophone(enabled: true)
        } catch {
            // 连上一半失败(例如开麦被拒)也要把这条连接收干净:不留同身份影子
            await newRoom.disconnect()
            if room === newRoom { room = nil }
            throw error
        }
        onState?("已连上房间,麦克风已开")
        onNote?("已连接房间=\(newRoom.name) 参与者=\(newRoom.remoteParticipants.count)")
        return newRoom
    }

    /// 断开指定这一条连接。只清理自己:目标不是当前 `room` 时不动 `self.room`。
    /// 为什么必须传实例:旧连接任务迟到完成时若执行"断开当前房间",会把后来新建的会话断掉。
    func disconnect(_ target: Room) async {
        _ = try? await target.localParticipant.setMicrophone(enabled: false)
        await target.disconnect()
        if room === target { room = nil }
    }

    /// 断开当前连接(兜底入口,正常情况下都走 disconnect(_:))。
    func disconnectCurrent() async {
        guard let room else { return }
        onNote?("主动断开")
        await disconnect(room)
    }
}

extension VoiceRoom: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState,
                          from oldValue: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }   // 旧实例的回调不许改新会话状态
            self.onState?("连接状态:\(Self.describe(state))")
        }
    }

    nonisolated func room(_ room: Room, participant _: RemoteParticipant?, didReceiveData data: Data,
                          forTopic _: String, encryptionType _: EncryptionType) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String, let text = obj["text"] as? String else { return }
            let who = (obj["who"] as? String) ?? "?"
            let audioS = (obj["audio_s"] as? Double) ?? 0
            let gap = obj["gap_s"] as? Double          // JSON null / 老服务端缺字段 → nil
            let ts = (obj["ts"] as? Double) ?? 0
            self.onTranscript?(type, who, audioS, text, gap, ts, obj)
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.onEnded?("连接失败:" + (error?.description ?? "未知"))
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.onEnded?(error.map { "连接断开:" + $0.description } ?? "连接已断开")
        }
    }

    private static func describe(_ s: ConnectionState) -> String {
        switch s {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .disconnected: return "已断开"
        @unknown default: return String(describing: s)
        }
    }
}
