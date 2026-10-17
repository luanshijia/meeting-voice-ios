import Foundation
import CryptoKit

/// 家里 LiveKit 的连接参数 + 开发用 token 铸造(HS256,与家里 Python 端 make_token 一致)。
///
/// ⚠️ 开发模式:key/secret 直接放在 App 里,对应家里 `livekit-server --dev` 的 devkey/secret。
/// 正式部署要改成"服务端发 token"或"扫码带入 token",不要把长期密钥放进客户端。
struct LiveKitConfig {
    static let defaultURL = "wss://100.64.0.2:7443"   // 经本地 TLS 代理(ATS 要求 wss)
    static let defaultKey = "devkey"
    static let defaultSecret = "secret"
    static let defaultDevice = "luan-iphone"

    var url: String
    var apiKey: String
    var apiSecret: String
    var device: String
    var identity: String { device + "-livekit" }

    static func load() -> LiveKitConfig {
        let d = UserDefaults.standard
        return LiveKitConfig(url: d.string(forKey: "lk.url") ?? defaultURL,
                             apiKey: d.string(forKey: "lk.key") ?? defaultKey,
                             apiSecret: d.string(forKey: "lk.secret") ?? defaultSecret,
                             device: d.string(forKey: "lk.device") ?? defaultDevice)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(url, forKey: "lk.url")
        d.set(apiKey, forKey: "lk.key")
        d.set(apiSecret, forKey: "lk.secret")
        d.set(device, forKey: "lk.device")
    }

    /// 铸 token。返回 nil 表示参数不合法。
    func makeToken(ttl: TimeInterval = 12 * 3600) -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "iss": apiKey, "sub": identity, "nbf": now - 10, "exp": now + Int(ttl), "name": identity,
            "video": ["room": "test", "roomJoin": true, "canPublish": true, "canSubscribe": true],
        ]
        guard let h = Self.json(header), let p = Self.json(payload) else { return nil }
        let signing = "\(h).\(p)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signing.utf8),
                                                  using: SymmetricKey(data: Data(apiSecret.utf8)))
        return "\(signing).\(Self.b64(Data(mac)))"
    }

    private static func json(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return b64(d)
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
