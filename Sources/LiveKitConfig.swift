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
    /// 统一显示名(用户口径 2026-10-14):以前每次装都是随机 iphone-1234,
    /// 家里归档与日志里认不出是谁;固定成一个名字,分人、归档、排查都省事。
    static let defaultIdentity = "luan-luxin"

    var url: String
    var apiKey: String
    var apiSecret: String
    var identity: String

    static func load() -> LiveKitConfig {
        let d = UserDefaults.standard
        var id = d.string(forKey: "lk.identity") ?? defaultIdentity
        // 老版本存在手机里的随机名(iphone-1234)或空值 → 迁移成固定名(否则改了默认值也白改,存值优先)
        if id.isEmpty || id.hasPrefix("iphone-") {
            id = defaultIdentity
            d.set(id, forKey: "lk.identity")
        }
        return LiveKitConfig(url: d.string(forKey: "lk.url") ?? defaultURL,
                             apiKey: d.string(forKey: "lk.key") ?? defaultKey,
                             apiSecret: d.string(forKey: "lk.secret") ?? defaultSecret,
                             identity: id)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(url, forKey: "lk.url")
        d.set(apiKey, forKey: "lk.key")
        d.set(apiSecret, forKey: "lk.secret")
        d.set(identity, forKey: "lk.identity")
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
