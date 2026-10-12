import Foundation
import LiveKit

/// LiveKit 房间的薄封装:连/断、开关麦克风、把收到的文字回调出去。
/// 传输、加密(DTLS-SRTP)、断线重连、ICE 都由 SDK 负责 —— 这正是换到 WebRTC 的目的。
@MainActor
final class VoiceRoom: NSObject {
    private var room: Room?

    var onState: ((String) -> Void)?
    var onNote: ((String) -> Void)?
    /// (类型 partial/final, 说话人, 服务端已识别的音频秒数, 文字)
    var onTranscript: ((String, String, Double, String) -> Void)?
    var onEnded: ((String) -> Void)?

    var isConnected: Bool { room?.connectionState == .connected }

    func connect(_ cfg: LiveKitConfig) async throws {
        guard let token = cfg.makeToken() else {
            throw NSError(domain: "MeetingVoice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "token 参数不合法"])
        }
        let room = Room()
        room.add(delegate: self)
        self.room = room
        onNote?("发起连接 \(cfg.url) 身份=\(cfg.identity)")
        try await room.connect(url: cfg.url, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)
        onState?("已连上房间,麦克风已开")
        onNote?("已连接房间=\(room.name) 参与者=\(room.remoteParticipants.count)")
    }

    func disconnect() async {
        if let room { onNote?("主动断开") }
        _ = try? await room?.localParticipant.setMicrophone(enabled: false)
        await room?.disconnect()
        room = nil
    }
}

extension VoiceRoom: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState,
                          from oldValue: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onState?("连接状态:\(Self.describe(state))")
        }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data,
                          forTopic _: String, encryptionType _: EncryptionType) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String, let text = obj["text"] as? String else { return }
            let who = (obj["who"] as? String) ?? "?"
            let audioS = (obj["audio_s"] as? Double) ?? 0
            self.onTranscript?(type, who, audioS, text)
        }
    }

    nonisolated func room(_: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            self?.onEnded?("连接失败:" + (error?.description ?? "未知"))
        }
    }

    nonisolated func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            self?.onEnded?(error.map { "连接断开:" + $0.description } ?? "连接已断开")
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
