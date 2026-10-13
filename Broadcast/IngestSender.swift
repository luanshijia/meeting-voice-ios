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
    private let url = URL(string: "https://100.64.0.2:7443/ingest")!
    private let log: (String) -> Void
    private let session: URLSession

    private let targetRate: Double = 16000
    private let chunkSeconds: Double = 0.5      // 0.5 秒一块:延迟小,频率也够低

    private var pcm: [Int16] = []
    private var rate: Double = 44100
    private var channels = 2
    private var bigEndian = true
    private var described = false

    private var inFlight = false
    private var sentChunks = 0
    private var sentBytes = 0
    private var droppedChunks = 0
    private var failedUploads = 0
    private var lastError = ""

    init(log: @escaping (String) -> Void) {
        self.log = log
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.httpMaximumConnectionsPerHost = 1     // 串行:别让块在内存里排队堆起来
        session = URLSession(configuration: cfg)
    }

    /// 给探针面板/上报用的一行状态(纯 ASCII,方便放进 URL 和共享文件)
    var status: String {
        "chunks=\(sentChunks),kb=\(sentBytes / 1024),drop=\(droppedChunks),fail=\(failedUploads)\(lastError.isEmpty ? "" : ",err=\(lastError)")"
    }

    func close() {
        flush(final: true)
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
                log("5A 放弃:只处理 16bit,实际 \(bits)bit —— 宁可不上报也不送噪声")
                return
            }
        }
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
            upload(chunk)
        }
    }

    /// 结束时把不够一块的余量也发出去(否则会议最后一句话会丢)
    func flush(final: Bool = false) {
        guard final, !pcm.isEmpty else { return }
        let chunk = pcm
        pcm.removeAll()
        upload(chunk)
    }

    private func upload(_ chunk: [Int16]) {
        guard !inFlight else {           // 上一块还没回来:直接丢掉这块,不让内存堆积
            droppedChunks += 1
            return
        }
        inFlight = true
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let body = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
        session.uploadTask(with: req, from: body) { [weak self] _, resp, err in
            guard let self else { return }
            self.inFlight = false
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let err {
                self.failedUploads += 1
                self.lastError = "net"
                if self.failedUploads <= 3 || self.failedUploads % 20 == 0 {
                    self.log("5A 上报失败(\(self.failedUploads)) code=\(code): \(err.localizedDescription)")
                }
                return
            }
            guard (200..<300).contains(code) else {
                self.failedUploads += 1
                self.lastError = "http\(code)"
                if self.failedUploads <= 3 || self.failedUploads % 20 == 0 {
                    self.log("5A 上报被拒(\(self.failedUploads)) code=\(code)")
                }
                return
            }
            self.sentChunks += 1
            self.sentBytes += body.count
        }.resume()
    }
}
