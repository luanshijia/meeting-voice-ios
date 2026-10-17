import AVFoundation
import Foundation

/// 5A:把「对方的声音」(ReplayKit 的 `.audioApp`)送回家里。
///
/// 数据流:扩展 ──https POST /ingest──► 家里 7443 的 TLS 代理(5B)──裸 PCM──► agent(5C)
/// 约定:每次 POST 的 body = **16k 单声道 s16le 裸 PCM**;同一条 keep-alive 连接 = 家里那侧的一路流。
///
/// 关键坑(实测,来自我们自己的探针):audioApp 的 ASBD 是
/// **44100Hz / 2声道 / 16bit / 大端 / 交错** —— 必须下混成单声道、重采样到 16k、
/// 并把字节序翻成小端,否则家里解出来是噪声(大端直接当小端读 = 幅度乱跳)。
///
/// 为什么不用官方那套 IPC:官方只能把 App 声音**混进麦克风轨**(分人没了),而且接收侧 API 全是 internal。
/// 我们不碰官方机制,自己发 —— 麦克风那一路由主 App 的 LiveKit 麦克风轨照旧负责。
final class IngestSender {

    /// 家里 TLS 代理上的入口(7443 已放行、证书手机已信任,所以不新增端口、不改防火墙)
    private let url: URL
    private let log: (String) -> Void
    private let session: URLSession

    private let targetRate: Double = 16000
    private let chunkSeconds: Double = 0.5      // 0.5 秒一块:延迟小,频率够低
    private let maxQueued = 6                   // 最多积压 3 秒音频
    private let stallSeconds: TimeInterval = 8  // 一块超过 8 秒没回来 = 判卡住
    private let silenceAfter: TimeInterval = 2  // app 声音停超过这个时间就补静音,保持"一条连续流"
    private let maxSilenceSeconds: Double = 30  // 最多补 30 秒静音;更长的静音就断开,不写空白大文件

    private var pcm: [Int16] = []
    private var queue: [[Int16]] = []
    private var rate: Double = 44100
    private var channels = 2
    private var bigEndian = true
    private var described = false
    private var warnedBits = false

    private var sending = false
    private var token = 0
    private var inFlightSince: Date?
    private var watchdog: DispatchSourceTimer?
    /// 所有状态(队列/计数)只在这条串行队列上改:采集线程、回调线程、看门狗三方绝不并发碰数组
    private let state = DispatchQueue(label: "mv.ingest.state")

    private var sentChunks = 0
    private var sentBytes = 0
    private var droppedChunks = 0
    private var failedUploads = 0
    private var stalls = 0
    private var avgMs = 0
    private var lastError = ""
    private var lastAppAudio = Date.distantPast      // 上一次真的收到 app 声音的时刻
    private var silenceChunks = 0                    // 已经补了多少块静音

    init(log: @escaping (String) -> Void) {
        self.log = log
        let groups = ["group.com.luanshijia.voicememo", "group.com.luanshijia.voicememo.458RP2552K"]
        var device: String?
        for group in groups {
            guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                continue
            }
            device = try? String(contentsOf: dir.appendingPathComponent("device.txt"), encoding: .utf8)
            if device != nil { break }
        }
        let cleanDevice = device?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenDevice = (cleanDevice?.isEmpty == false) ? cleanDevice! : "luan-iphone"
        if cleanDevice?.isEmpty != false {
            log("WARNING[device] App Group device.txt 缺失，使用默认设备名 luan-iphone")
        }
        var components = URLComponents(string: "https://100.64.0.2:7443/ingest")!
        components.queryItems = [URLQueryItem(name: "source", value: "\(chosenDevice)-replaykit")]
        self.url = components.url!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 1     // 串行:到达顺序 = 录音顺序
        session = URLSession(configuration: cfg)
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.state.async { self.checkStallLocked() }
        }
        t.resume()
        watchdog = t
    }

    /// 给探针面板/上报用的一行状态(纯 ASCII,方便放进 URL 和共享文件)
    var status: String {
        "chunks=\(sentChunks),kb=\(sentBytes / 1024),q=\(queue.count),drop=\(droppedChunks),fail=\(failedUploads),ms=\(avgMs),sil=\(silenceChunks)"
            + (lastError.isEmpty ? "" : ",err=\(lastError)")
    }

    func close() {
        flush(final: true)
        watchdog?.cancel()
        watchdog = nil
        session.invalidateAndCancel()
    }

    /// 收到一帧 `.audioApp`
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        if !described {
            described = true
            rate = asbd.pointee.mSampleRate
            channels = max(Int(asbd.pointee.mChannelsPerFrame), 1)
            bigEndian = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
            let bits = Int(asbd.pointee.mBitsPerChannel)
            log("5A 首帧格式: \(Int(rate))Hz \(channels)声道 \(bits)bit \(bigEndian ? "大端" : "小端") → 目标 16k 单声道 s16le")
            if bits != 16 {
                warnedBits = true
                log("5A 放弃:只处理 16bit,实际 \(bits)bit —— 宁可不上报也不送噪声")
            }
        }
        if warnedBits { return }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &ptr) == noErr,
              let base = ptr, length >= 2 else { return }

        let count = length / 2
        let src = UnsafeRawPointer(base).assumingMemoryBound(to: UInt16.self)
        var mono = [Int16](repeating: 0, count: count / channels)
        if channels >= 2 {
            for i in 0..<mono.count {
                let a = Int16(bitPattern: bigEndian ? src[i * channels].byteSwapped : src[i * channels])
                let b = Int16(bitPattern: bigEndian ? src[i * channels + 1].byteSwapped : src[i * channels + 1])
                mono[i] = Int16((Int(a) + Int(b)) / 2)
            }
        } else {
            for i in 0..<mono.count {
                mono[i] = Int16(bitPattern: bigEndian ? src[i].byteSwapped : src[i])
            }
        }
        guard !mono.isEmpty else { return }

        if rate != targetRate {
            let nOut = Int(Double(mono.count) * targetRate / rate)
            guard nOut > 0 else { return }
            var out = [Int16](repeating: 0, count: nOut)
            let step = Double(mono.count - 1) / Double(max(nOut - 1, 1))
            for i in 0..<nOut {
                let x = Double(i) * step
                let i0 = Int(x)
                let i1 = min(i0 + 1, mono.count - 1)
                let f = Float(x - Double(i0))
                out[i] = Int16(Float(mono[i0]) * (1 - f) + Float(mono[i1]) * f)
            }
            mono = out
        }

        pcm.append(contentsOf: mono)
        let need = Int(targetRate * chunkSeconds)
        while pcm.count >= need {
            let chunk = Array(pcm[0..<need])
            pcm.removeFirst(need)
            enqueue(chunk)
        }
    }

    /// 结束时把不够一块的余量也发出去(否则会议最后一句话会丢)
    func flush(final: Bool = false) {
        guard final, !pcm.isEmpty else { return }
        let chunk = pcm
        pcm.removeAll()
        enqueue(chunk)
    }

    private func enqueue(_ chunk: [Int16]) {
        state.async { [weak self] in self?.enqueueLocked(chunk) }
    }

    private func enqueueLocked(_ chunk: [Int16]) {
        lastAppAudio = Date()                     // 真声音到了 → 静音计数归零
        silenceChunks = 0
        guard queue.count < maxQueued else {      // 真积压超了才丢,并留计数
            droppedChunks += 1
            if droppedChunks <= 3 || droppedChunks % 20 == 0 {
                log("5A 积压超过 \(maxQueued) 块,丢弃一块(累计丢 \(droppedChunks))")
            }
            return
        }
        queue.append(chunk)
        pump()
    }

    /// app 声音停了就补静音块,让家里那侧始终是**一条连续流**。
    /// 为什么:实测"有对方声音才发"会把同一个人切成 12 秒 + 7 秒两个文件,
    /// 说话人分段和纪要的连贯性都被打断。补静音后家里只看到一条流,停顿由它自己判断。
    private func maybeSendSilenceLocked() {
        guard lastAppAudio != .distantPast else { return }              // 还没收到过真声音,别先灌静音
        guard Date().timeIntervalSince(lastAppAudio) >= silenceAfter else { return }
        let maxChunks = Int(maxSilenceSeconds / chunkSeconds)
        var n = min(maxQueued - queue.count, 4)                          // 每次最多补 2 秒
        if silenceChunks + n > maxChunks { n = maxChunks - silenceChunks }
        guard n > 0 else { return }
        let need = Int(targetRate * chunkSeconds)
        for _ in 0..<n { queue.append([Int16](repeating: 0, count: need)) }
        silenceChunks += n
        pump()
    }

    private func pump() {                          // 只允许在 state 队列上调用
        guard !sending, !queue.isEmpty else { return }
        sending = true
        token += 1
        let myToken = token
        inFlightSince = Date()
        let chunk = queue.removeFirst()
        let started = Date()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let body = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
        session.uploadTask(with: req, from: body) { [weak self] _, resp, err in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = err?.localizedDescription ?? ""
            self.state.async { self.finish(myToken, bytes: body.count, code: code, err: text, ms: ms) }
        }.resume()
    }

    private func finish(_ myToken: Int, bytes: Int, code: Int, err: String, ms: Int) {
        guard myToken == token else { return }      // 看门狗已作废这块 → 忽略旧回调
        avgMs = avgMs == 0 ? ms : (avgMs * 3 + ms) / 4
        sending = false
        inFlightSince = nil
        if !err.isEmpty {
            failedUploads += 1
            lastError = "net"
            if failedUploads <= 3 || failedUploads % 20 == 0 {
                log("5A 上报失败(\(failedUploads)) code=\(code): \(err)")
            }
        } else if !(200..<300).contains(code) {
            failedUploads += 1
            lastError = "http\(code)"
            if failedUploads <= 3 || failedUploads % 20 == 0 {
                log("5A 上报被拒(\(failedUploads)) code=\(code)")
            }
        } else {
            sentChunks += 1
            sentBytes += bytes
        }
        pump()
    }

    /// 看门狗:一块超过 stallSeconds 还没回来 → 判卡住,作废旧回调,继续发
    private func checkStallLocked() {
        if sending, let since = inFlightSince, Date().timeIntervalSince(since) > stallSeconds {
            stalls += 1
            failedUploads += 1
            lastError = "stall"
            log("5A 上一块超过 \(Int(stallSeconds)) 秒没回来,判卡住并继续发(第 \(stalls) 次)")
            sending = false
            inFlightSince = nil
            token += 1          // 让那个迟迟不回的回调作废
            pump()
        }
        maybeSendSilenceLocked()      // 顺带:app 声音断了就补静音,保持连续流
    }
}
