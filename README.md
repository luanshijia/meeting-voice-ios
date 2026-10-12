# MeetingVoice (iOS)

iPhone 端后台录音 + 推流回家做实时转写的**骨架仓库**,用途只有一个:

> 验证「Windows 上写代码 → GitHub Actions 云端 macOS 编译 → 未签名 .ipa → SideStore 装机」这条通路能不能走通。

**通路走通之前不写真正的业务代码。**

## 结构

| 路径 | 作用 |
|---|---|
| `project.yml` | XcodeGen 工程描述(云端生成 `.xcodeproj`,避免在 Windows 上手写工程文件) |
| `Sources/` | SwiftUI 源码(骨架) |
| `.github/workflows/build-ipa.yml` | 云端构建:生成工程 → 编译 → 打包未签名 `.ipa` → 上传产物 |

## 怎么拿产物

1. 打开本仓库的 **Actions** 页,等 `build-ipa` 跑完(约 2~5 分钟);
2. 点进那次运行,页面底部 **Artifacts** 下载 `MeetingVoice-unsigned-ipa`;
3. 解压得到 `MeetingVoice-unsigned.ipa`;
4. 用 **SideStore** 打开该 `.ipa` 完成签名安装(签名在你的手机上用免费 Apple ID 完成,与本次构建无关)。

## 为什么不用签名

免费 Apple ID 的个人证书 7 天过期,签名放在设备侧由 SideStore 处理最省事;CI 只负责产出可安装的 `.ipa` 外壳。

## 注意

- 仓库设为 **public** 是为了让 macOS runner 的标准机器分钟不计费。
- 部署目标 iOS 17.0;录音相关的后台音频声明(`UIBackgroundModes: audio`)已在 `project.yml` 里预留。
