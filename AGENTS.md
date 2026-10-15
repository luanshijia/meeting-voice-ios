# AGENTS.md — VoiceMemo iOS 客户端(app-ios)

> 本文件给在**本目录**工作的编码代理(Codex / Claude Code / Hermes)。**先读本文件**。
> 家里服务端与工具在**另一个仓库**(上级目录 `..`,即 `voice-memo` 项目根,那里也有一份 AGENTS.md);
> 本仓库只放 iOS 客户端。两边各自独立提交、独立版本。

## 这是什么

录音与实时字幕客户端:从麦克风(或 ReplayKit 广播扩展采到的"对方声音")取音频 →
经 `wss://<家里地址>:7443`(TLS 代理)推到家里的 LiveKit → 实时接收家里的定稿文字并显示。
**App 不做识别、不做纪要**,识别与会后处理全在家里那台 Windows 上完成。

## 工程结构(单一真相源 = `project.yml`)

| 文件 | 作用 |
|---|---|
| `project.yml` | XcodeGen 工程定义。**版本号四处全在这一个文件**:两个 target 各自的 `CFBundleShortVersionString` / `CFBundleVersion` |
| `Sources/ContentView.swift` | 主界面:顶部 5 个按钮(纯文字、5 等分、块高 24、圆角 6);三块固定版式(上 1/10 第一遍 / 中 1/2 第二遍定稿 / 下 4/10 会中提要);贴底状态栏 |
| `Sources/SessionModel.swift` | 会话与状态机:连接、计时、上行切档、服务端消息分发(`final` / `summary` / `sumstatus` / `partial`) |
| `Sources/VoiceRoom.swift` | LiveKit 封装:连接、麦克风、数据通道收发(delegate 把整条 JSON 透传给上层) |
| `Sources/LiveKitConfig.swift` | 连接参数与本地铸 token(HS256);默认值与家里 `livekit-server --dev` 的 devkey/secret 一致 |
| `Sources/BroadcastExtension/` | ReplayKit 广播扩展(线上会议采"对方声音";面对面/只有自己说话时不用) |
| `Sources/NetProbe.swift`、`Sources/RoomsProbe.swift` | 排错探针 |

## 怎么出包(唯一路径:CI)

```bash
# 1) 改版本号:project.yml 里四处(两个 target 各两处)
# 2) 提交并推送 → GitHub Actions 自动 xcodegen + xcodebuild archive → 未签名 IPA
git add -A && git commit -m "..." && git push
# 3) 盯 CI 并把包取到桌面(脚本在服务端仓库)
bash ../tools/ops/vm-watch-ci37.sh <run-id> <标签> <桌面文件名>
```

- 本机**没有 Xcode / Swift 工具链** → **不要在本机尝试编译或跑测试**;编译错误只能靠 CI 暴露(每次约 2~4 分钟,runner 忙时要排队)。
- 本仓库是 **public**;CI 产物是**未签名** IPA,装机走 SideStore 侧载。

## 红线

- **不做识别、不做纪要**:App 只负责采集、推流、显示。
- **主链路(推流 / 字幕 / 断线重连 / 数据协议)的改动要先给方案、经批准再动手**;改完必须真机验证,CI 通过 ≠ 能用。
- **不要把真密钥写进源码**:当前默认值是与家里 `--dev` 配套的**公开**默认值(仅开发用);
  未来改成"向家里请求 token"之后,App 不应再持有任何密钥。
- **界面几何保持一致**:同一排按钮等高同圆角;改文案不要连带改版式。
- 版本号只改 `project.yml`,不要手改生成出来的 `.xcodeproj`。

## 审查时重点看什么

1. `SessionModel` 的 `onTranscript` 分支是否覆盖服务端所有 `type` —— 历史上"所有非 `final` 的都当 partial",会中提要消息踩过这个坑;
2. 断线重连与「录 / 收」两个计数器的一致性(传输落后 >5 秒要变红);
3. `VoiceRoom` 数据通道:可靠发送 + topic;上行消息是否带序号(防重复/乱序);
4. 广播扩展的生命周期与 App Group 共享(`group.com.luanshijia.voicememo`),扩展不能写坏主 App 的共享文件;
5. 有没有把密钥 / 证书 / 大件提交进仓库。

## 已知坑(踩过,别再踩)

- iOS **图标缓存**:换图标后覆盖安装可能仍显示旧图标 → 删 App 重装或重启手机;
- 免费自签 **7 天有效**,装机走 SideStore;设置页 "App Group" 行是否变绿可判断广播扩展是否接通;
- 点「停止」那声「嘟」与橙色指示灯**关不掉**(iOS 限制,Apple 官方口径);
- 同一身份重复连接会被服务端按 `DUPLICATE_IDENTITY` 踢掉 → "停止后立即开始"要等上一次断开落地;
- `gh run download` 的产物解压路径是**相对当前目录** → 脚本里必须先 `cd` 到目标目录,否则静默取不到包。
