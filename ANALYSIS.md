# SenPlayer 6.1.8 逆向分析结论

分析对象：`SenPlayer_6.1.8.ipa`（41MB，arm64）

## 播放内核：双内核并行

| 组件 | 引用次数 | 作用 |
|---|---|---|
| **libmpv** | 964 | 主力播放器，负责绝大多数格式 |
| **KSPlayer** | 771 | 辅助内核（AVPlayer 封装 + FFmpeg 软解兜底） |
| FFmpeg | 100 / avcodec 205 | 编解码 |
| libass | 17 | 字幕渲染 |

关键：`libmpv.framework` 只有 35KB 的壳，真正代码静态链接进主二进制（65MB）。

### 附带的完整多媒体栈

```
libass         字幕渲染（ASS/SSA）
libharfbuzz    复杂文字排版
libfribidi     双向文字
libfreetype    字体光栅化
libfontconfig  字体查找
libdav1d       AV1 软解
libdovi        Dolby Vision
libplacebo     高质量缩放/HDR 色调映射
libshaderc     着色器编译（mpv 的 GPU 渲染）
libsrt         SRT 流传输
libzvbi        图文电视字幕
lcms2          色彩管理
```

## 手势（MX 风格，实测符号表）

```
canGestureBrightness    左侧上下滑调亮度
canGestureVolume        右侧上下滑调音量
canGestureProgress      横向滑动快进/快退
canGestureZoom          双指缩放画面
canGestureResetView     双击复位画面
canGestureSwitchMedia   切换上下集
doubleTapGesture        双击暂停
```

## 文件目录访问

```
UIDocumentPickerViewController                      用户选目录
startAccessingSecurityScopedResource                security-scoped 访问
NSFileCoordinator                                   协调式读写
contentsOfDirectory(atPath:recursive:completion:)   递归枚举（有 recursive 参数）
isUbiquitousItem / NSMetadataUbiquitous*            iCloud 状态处理
```

### 为什么可能只列出部分文件

`contentsOfDirectory(atPath:recursive:)` 是**异步 completion 回调**。若调用方在
回调里分批刷新 UI，或递归过程中被取消，就会表现为「只列出前几个，其余要手动刷新」。

iCloud 目录下未下载到本地的文件（`isUbiquitousItem == true` 且下载状态非
`Downloaded`）通常会被过滤掉，这类文件需要 `startDownloadingUbiquitousItem`
触发下载后才会出现在可用列表里。

## 其他

- Bundle ID: `com.wuziqi.SenPlayer`
- iCloud 容器: `iCloud.com.wuziqi.SenPlayer`
- 界面框架: SwiftUI（bundle 命名遵循 SPM 资源规则）
- 网络: CocoaAsyncSocket、MRDLNA（DLNA 投屏）
- 原包用「轻松签」自签，包内有 `SignedByEsign` 标记

## 本项目（momo-player）的技术选型

参照 SenPlayer 的做法，但按需精简：

| 项 | 选择 | 理由 |
|---|---|---|
| 播放内核 | **KSPlayer**（SPM） | 已含 FFmpeg/libass/Harfbuzz，SenPlayer 也用它 |
| 可选增强 | mpv（后续） | 若 KSPlayer 某些格式不够好，再加一层 |
| UI | SwiftUI | SenPlayer 同款 |
| 构建 | GitHub Actions macos-14 | arm64 runner，产出未签名 IPA |
| 签名 | 用户本地自签 | 不需要把证书放仓库 |
