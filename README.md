# MomoPlayer

iOS 视频播放器，操作方式参考 MX Player / SenPlayer。

## 功能

- 递归扫描所选文件夹，列出全部可播放文件（含子目录）
- 支持 MKV / AVI / TS / FLV / WebM 等容器，ASS/SSA 字幕
- MX 风格手势：
  - 左半屏上下滑 → 亮度
  - 右半屏上下滑 → 音量
  - 水平滑动 → 进度
  - 双击 → 播放/暂停
  - 双指捏合 → 缩放画面
- 后台播放、画中画
- 处理 iCloud 未下载文件（自动触发下载）

## 技术栈

| 组件 | 用途 |
|---|---|
| [KSPlayer](https://github.com/kingslay/KSPlayer) 5.6.2 | 播放内核（AVPlayer + FFmpeg） |
| SwiftUI + UIKit | 界面与手势 |

播放内核选型依据见 [ANALYSIS.md](ANALYSIS.md)：SenPlayer 6.1.8 实际上同时集成了
mpv（964 处符号引用）与 KSPlayer（771 处），本项目先采用 KSPlayer。

## 构建

GitHub Actions 自动构建，产出**未签名 IPA**：

```
Actions → build-ipa → 最新一次运行 → Artifacts → MomoPlayer-ipa
```

## 自己签名

产出的 IPA 未签名，需要在本机用工具签名后安装。

### 方式一：轻松签 / Esign（推荐，iOS 上直接操作）

1. 把 `MomoPlayer-unsigned.ipa` 传到手机
2. 打开轻松签，导入 IPA
3. 选自己的证书签名后安装

### 方式二：Sideloadly / AltStore（需要电脑）

1. 电脑装 Sideloadly
2. 连上 iPhone，拖入 IPA
3. 填 Apple ID，点 Start

**免费 Apple ID 签名 7 天过期**，到期需重新签。付费开发者账号（$99/年）签一次可用 1 年。

### 方式三：自己有 p12 证书

用 `zsign` 或 `codesign` 命令行签名：

```bash
# 解包
unzip MomoPlayer-unsigned.ipa

# 用 zsign 签名
zsign -k cert.p12 -p 密码 -m embedded.mobileprovision \
      -o MomoPlayer-signed.ipa \
      -b com.your.bundleid \
      Payload/MomoPlayer.app
```

注意 Bundle ID 必须与描述文件里的一致。

## 目录结构

```
Sources/MomoPlayer/
├── App.swift                    应用入口
├── Core/
│   ├── MediaItem.swift          媒体数据模型与格式判定
│   └── DirectoryScanner.swift   目录递归扫描（含 security-scoped 与 iCloud 处理）
└── Views/
    ├── LibraryView.swift        文件列表
    ├── DirectoryPicker.swift    系统文件夹选择器
    └── PlayerView.swift         播放界面与手势
```

## 已知限制

- 未做 mpv 内核，个别极端格式可能不如 SenPlayer
- 手势灵敏度是经验值，实际使用中可能要调
- 没做投屏（DLNA）、网盘、Emby 等网络功能
