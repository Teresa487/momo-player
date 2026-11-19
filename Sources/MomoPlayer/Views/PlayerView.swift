import AVFoundation
import KSPlayer
import MediaPlayer
import SwiftUI
import UIKit

/// MX / SenPlayer 风格的播放器界面
///
/// 手势布局：
/// - 左半屏上下滑：亮度
/// - 右半屏上下滑：音量
/// - 水平滑：进度
/// - 双击：播放/暂停
/// - 双指捏合：缩放画面
struct PlayerView: UIViewControllerRepresentable {
    let item: MediaItem

    func makeUIViewController(context: Context) -> MomoPlayerController {
        let vc = MomoPlayerController()
        vc.configure(with: item)
        return vc
    }

    func updateUIViewController(_ uiViewController: MomoPlayerController, context: Context) {}
}

/// 用 UIKit 承载，因为手势和 HUD 用 UIKit 写更直接，
/// KSPlayer 的播放层本身也是 UIKit 视图。
final class MomoPlayerController: UIViewController {
    private let playerView = IOSVideoPlayerView()
    private var item: MediaItem?
    private var holdingAccess = false
    private var loggedFirstFrame = false
    private var stateTimer: Timer?

    // 手势进度状态
    private var panStartPoint: CGPoint?
    private var panMode: PanMode = .none
    private var seekStartTime: TimeInterval = 0

    private enum PanMode {
        case none, brightness, volume, seek
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPlayerView()
        setupGestures()
        setupHUD()
        observeSystemVolume()
    }

    func configure(with item: MediaItem) {
        self.item = item
        loadViewIfNeeded()

        Log.event("player", "准备加载: \(item.url.path)")
        let exists = FileManager.default.fileExists(atPath: item.url.path)
        Log.event("player", "文件存在: \(exists)")

        // 播放前必须自己持有权限，扫描阶段那次授权早已释放
        let ok = item.url.startAccessingSecurityScopedResource()
        Log.event("player", "startAccessing = \(ok)")
        holdingAccess = ok

        let options = KSOptions()
        // 优先硬解，失败时 KSPlayer 会自动回退软解
        options.hardwareDecode = true
        // 自动选中内嵌音轨与字幕
        options.autoSelectEmbedSubtitle = true
        // 后台播放需要注册远程控制
        options.registerRemoteControll = true

        // 单文件播放用这个便捷构造即可
        let resource = KSPlayerResource(
            url: item.url,
            options: options,
            name: item.displayName
        )
        playerView.set(resource: resource)
        Log.event("player", "已调用 set(resource:)，等待回调")
        title = item.displayName
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playerView.pause()
        if holdingAccess, let url = item?.url {
            url.stopAccessingSecurityScopedResource()
            holdingAccess = false
            Log.event("player", "已释放播放权限")
        }
    }

    /// 播放状态变化都记一笔，黑屏时能看出卡在哪
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playerView.playerLayer?.player.play()
        Log.event("player", "viewDidAppear，已请求播放")
        startStatePolling()
    }

    /// KSPlayer 的 delegate 协议不是 public，外部无法实现，
    /// 所以用定时轮询把状态和错误打出来。
    private func startStatePolling() {
        stateTimer?.invalidate()
        var lastState: String?
        var tick = 0

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, let layer = self.playerView.playerLayer else { return }
            tick += 1

            let st = "\(layer.state)"
            if st != lastState {
                lastState = st
                Log.event("player", "state → \(st)")
            }

            // isPlaying 在 player 上，不在 layer 上
            let playing = layer.player.isPlaying
            let t = layer.player.currentPlaybackTime

            // 只在还没播起来时记录细节，播起来就安静了
            if !playing || tick <= 6 {
                Log.event(
                    "player",
                    "playing=\(playing) buffering=\(layer.bufferingProgress)% time=\(String(format: "%.1f", t))"
                )
            } else if tick == 7 {
                Log.event("player", "已开始播放，停止细节轮询")
                timer.invalidate()
            }

            // 进入错误态就停
            if st.contains("error") || st.contains("failed") {
                Log.event("player", "进入错误态，停止轮询")
                timer.invalidate()
            }
        }
    }

    deinit {
        stateTimer?.invalidate()
    }

    // MARK: - 播放层

    private func setupPlayerView() {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - 手势

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: view)
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            panStartPoint = location
            panMode = .none

        case .changed:
            if panMode == .none {
                let dx = abs(translation.x)
                let dy = abs(translation.y)
                // 水平位移明显更大就走进度，否则按左右半屏分亮度/音量
                if dx > dy, dx > 12 {
                    panMode = .seek
                    seekStartTime = playerView.playerLayer?.player.currentPlaybackTime ?? 0
                } else if dy > dx, dy > 12 {
                    panMode = location.x < view.bounds.width / 2 ? .brightness : .volume
                }
            }

            switch panMode {
            case .seek:
                let total = playerView.playerLayer?.player.duration ?? 0
                guard total > 0 else { break }
                // 横跨整屏对应总时长的 1/2，滑起来不至于太灵敏
                let delta = Double(translation.x / view.bounds.width) * total * 0.5
                let target = min(max(seekStartTime + delta, 0), total)
                showSeekHUD(target: target, total: total)

            case .brightness:
                let delta = Float(-translation.y / view.bounds.height)
                adjustBrightness(by: delta)

            case .volume:
                let delta = Float(-translation.y / view.bounds.height)
                adjustVolume(by: delta)

            case .none:
                break
            }

        case .ended, .cancelled:
            if panMode == .seek {
                let total = playerView.playerLayer?.player.duration ?? 0
                if total > 0 {
                    let delta = Double(translation.x / view.bounds.width) * total * 0.5
                    let target = min(max(seekStartTime + delta, 0), total)
                    playerView.seek(time: target) { _ in }
                }
            }
            hideHUD()
            panMode = .none
            panStartPoint = nil

        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let layer = playerView.playerLayer else { return }
        let player = layer.player
        if player.isPlaying {
            playerView.pause()
        } else {
            playerView.play()
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // 缩放画面：通过变换播放层实现，双击复位
        guard let layerView = playerView.subviews.first else { return }
        if gesture.state == .changed {
            let scale = max(1.0, min(gesture.scale, 3.0))
            layerView.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    // MARK: - 亮度 / 音量

    private var baseBrightness: CGFloat = UIScreen.main.brightness

    private func adjustBrightness(by delta: Float) {
        let current = UIScreen.main.brightness
        if baseBrightness == 0 { baseBrightness = current }
        let next = min(max(UIScreen.main.brightness + CGFloat(delta), 0.02), 1.0)
        UIScreen.main.brightness = next
        showHUD(systemImage: "sun.max.fill", value: Float(next))
    }

    private let volumeView = MPVolumeView(frame: .zero)

    private func setupHUD() {
        volumeView.showsRouteButton = false
        volumeView.alpha = 0.001
        view.addSubview(volumeView)
    }

    private func adjustVolume(by delta: Float) {
        let current = AVAudioSession.sharedInstance().outputVolume
        let next = min(max(current + delta, 0), 1)
        // 系统音量没有公开的写入 API，只能通过 MPVolumeSlider 设置
        if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            DispatchQueue.main.async {
                slider.value = next
            }
        }
        showHUD(systemImage: next > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill", value: next)
    }

    private func observeSystemVolume() {
        // 音量键改系统音量时，这里不做额外处理，滑动手势已覆盖主要场景
    }

    // MARK: - HUD

    private lazy var hudLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private var hudHideWorkItem: DispatchWorkItem?

    private func showHUD(systemImage: String, value: Float) {
        let bar = String(repeating: "█", count: Int(value * 10))
        let empty = String(repeating: "░", count: 10 - Int(value * 10))
        hudLabel.text = "  \(bar)\(empty)  \(Int(value * 100))%  "
        presentHUD()
    }

    private func showSeekHUD(target: TimeInterval, total: TimeInterval) {
        hudLabel.text = "  \(format(target)) / \(format(total))  "
        presentHUD()
    }

    private func presentHUD() {
        if hudLabel.superview == nil {
            view.addSubview(hudLabel)
            NSLayoutConstraint.activate([
                hudLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hudLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                hudLabel.heightAnchor.constraint(equalToConstant: 40),
            ])
        }
        hudLabel.isHidden = false

        hudHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hudLabel.isHidden = true
        }
        hudHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func hideHUD() {
        hudHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hudLabel.isHidden = true
        }
        hudHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let total = Int(time)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

extension MomoPlayerController: UIGestureRecognizerDelegate {
    /// 同时识别播放层自己的手势，避免互相吞掉
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
