import Foundation

// 信号处理里不能用 UserDefaults(不是异步信号安全的),所以用全局的 fd 和一块字符缓冲
private var gLogFD: Int32 = -1
private var gStepBuf: UnsafeMutablePointer<CChar>?

/// 黑匣子:侧载 App 想翻系统崩溃日志很麻烦,这里自己记下
/// 「上一次崩溃的原因 + 最后一步进度」,下次打开 App 直接显示在界面顶部。
enum CrashLog {
    private static let failureKey = "mv.lastFailure"
    private static let stepKey = "mv.lastStep"
    private static let runKey = "mv.runStartedAt"
    private static let countersKey = "mv.counters"

    private(set) static var previousRunStartedAt: String?
    private(set) static var previousCrashFile: String?

    static var lastFailure: String? { UserDefaults.standard.string(forKey: failureKey) }
    static var lastStep: String? { UserDefaults.standard.string(forKey: stepKey) }
    static var counters: String? { UserDefaults.standard.string(forKey: countersKey) }

    static func clear() {
        [failureKey, stepKey, runKey, countersKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        previousCrashFile = nil
        previousRunStartedAt = nil
        if gLogFD >= 0 { ftruncate(gLogFD, 0) }
    }

    /// 记一步进度:崩了以后能看出最后停在哪
    static func step(_ text: String) {
        let line = "\(stamp()) \(text)"
        UserDefaults.standard.set(line, forKey: stepKey)
        if let buf = gStepBuf {
            line.withCString { cs in
                let n = min(strlen(cs), 500)
                memcpy(buf, cs, n)
                buf[n] = 0
            }
        }
    }

    static func counters(received: Int, sent: Int, partials: Int, frames: Int) {
        UserDefaults.standard.set("收 \(received) 条 / 文本 \(partials) 条 / 发出 \(sent) 帧 / 采集 \(frames) 块",
                                  forKey: countersKey)
    }

    static func markRunStart() { UserDefaults.standard.set(stamp(), forKey: runKey) }
    static func markRunEnd() { UserDefaults.standard.removeObject(forKey: runKey) }

    /// 启动时最先调用:先读上一轮留下的痕迹(读文件必须在 install() 清空之前)
    static func readPreviousRun() {
        previousRunStartedAt = UserDefaults.standard.string(forKey: runKey)
        if let s = try? String(contentsOf: logFileURL, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previousCrashFile = s
        }
    }

    static func install() {
        let fd = open(logFileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 { gLogFD = fd }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
        buf.initialize(repeating: 0, count: 512)
        gStepBuf = buf

        // 1) ObjC 异常(AVAudioEngine 断言、数组越界等走这条)
        NSSetUncaughtExceptionHandler { exc in
            let info = "\(stamp()) NSException \(exc.name.rawValue)\n原因: \(exc.reason ?? "-")\n"
                + exc.callStackSymbols.prefix(20).joined(separator: "\n")
            UserDefaults.standard.set(info, forKey: failureKey)
            UserDefaults.standard.synchronize()
        }

        // 2) 信号(Swift 里最常见的崩溃走这条)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                if gLogFD >= 0 {
                    let a = "\n=== 收到信号 \(s) ===\n最后一步: "
                    a.withCString { _ = write(gLogFD, $0, strlen($0)) }
                    if let b = gStepBuf { _ = write(gLogFD, b, strlen(b)) }
                    let c = "\n"
                    c.withCString { _ = write(gLogFD, $0, strlen($0)) }
                    fsync(gLogFD)
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-crash.txt")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
