import AVFoundation
import KSPlayer
import MediaPlayer
import SwiftUI
import UIKit

/// MX / SenPlayer 风格的播放界面
///
/// 手势：
/// - 左半屏上下滑：亮度
/// - 右半屏上下滑：音量
/// - 水平滑动：进度
/// - 双击：播放/暂停
/// - 长按：2 倍速，松手恢复
/// - 上下滑动（竖直大幅）：切换上/下一集
/// - 双指捏合：缩放画面
struct PlayerView: UIViewControllerRepresentable {
    /// 整个播放列表，用来做连播和切换
    let playlist: [MediaItem]
    let startIndex: Int

    func makeUIViewController(context: Context) -> MomoPlayerController {
        let vc = MomoPlayerController()
        vc.configure(playlist: playlist, startIndex: startIndex)
        return vc
    }

    func updateUIViewController(_ uiViewController: MomoPlayerController, context: Context) {}
}

final class MomoPlayerController: UIViewController {
    private let playerView = IOSVideoPlayerView()
    private var playlist: [MediaItem] = []
    private var index = 0
    private var current: MediaItem? { playlist.indices.contains(index) ? playlist[index] : nil }

    private var holdingAccess = false
    private var stateTimer: Timer?
    private var saveTimer: Timer?

    private var panStart: CGPoint?
    private var panMode: PanMode = .none
    private var seekStartTime: TimeInterval = 0
    private var baseBrightness: CGFloat = 0
    private var normalRate: Float = 1

    private enum PanMode { case none, brightness, volume, seek, switchMedia }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPlayerView()
        setupGestures()
        setupHUD()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistProgress()
        stateTimer?.invalidate()
        saveTimer?.invalidate()
        playerView.pause()
        releaseAccess()
    }

    private func releaseAccess() {
        if holdingAccess, let url = current?.url {
            url.stopAccessingSecurityScopedResource()
            holdingAccess = false
            Log.event("player", "已释放播放权限")
        }
    }

    // MARK: - 加载

    func configure(playlist: [MediaItem], startIndex: Int) {
        self.playlist = playlist
        self.index = max(0, min(startIndex, playlist.count - 1))
        loadViewIfNeeded()
        load(index: self.index)
    }

    private func load(index: Int) {
        guard playlist.indices.contains(index) else { return }
        releaseAccess()
        self.index = index
        let item = playlist[index]

        Log.event("player", "加载 [\(index + 1)/\(playlist.count)] \(item.url.path)")

        let exists = FileManager.default.fileExists(atPath: item.url.path)
        Log.event("player", "文件存在=\(exists)")

        // 每次加载都独立申请权限，目录那边的 provider 可能已经释放
        holdingAccess = item.url.startAccessingSecurityScopedResource()
        Log.event("player", "startAccessing=\(holdingAccess)")

        guard exists else {
            presentAlert("文件读不到：\(item.name)")
            return
        }

        let options = KSOptions()
        options.hardwareDecode = true
        options.autoSelectEmbedSubtitle = true
        options.registerRemoteControll = true
        // 打开即播
        options.isSeekedAutoPlay = true

        let resource = KSPlayerResource(url: item.url, options: options, name: item.displayName)
        playerView.set(resource: resource)
        title = item.displayName

        // 有历史进度就续播
        if let pos = PlaybackHistory.resumePosition(for: item.url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.playerView.seek(time: pos) { _ in }
                self?.flash("从 \(self?.fmt(pos) ?? "") 继续")
            }
        }

        startStatePolling()
        startProgressSaving()
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
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let loc = g.location(in: view)
        let t = g.translation(in: view)

        switch g.state {
        case .began:
            panStart = loc
            panMode = .none

        case .changed:
            if panMode == .none {
                let dx = abs(t.x), dy = abs(t.y)
                guard max(dx, dy) > 14 else { break }
                if dx > dy * 1.2 {
                    panMode = .seek
                    seekStartTime = playerView.playerLayer?.player.currentPlaybackTime ?? 0
                } else if dy > dx * 1.2 {
                    // 从屏幕边缘大幅竖直滑 = 切换上下集，中间区域 = 亮度/音量
                    if abs(t.y) > 90 {
                        panMode = .switchMedia
                    } else {
                        panMode = loc.x < view.bounds.width / 2 ? .brightness : .volume
                        baseBrightness = UIScreen.main.brightness
                    }
                }
            }

            switch panMode {
            case .seek:
                let total = playerView.playerLayer?.player.duration ?? 0
                guard total > 0 else { break }
                let delta = Double(t.x / view.bounds.width) * total * 0.5
                let target = min(max(seekStartTime + delta, 0), total)
                showHUD("\(fmt(target)) / \(fmt(total))")

            case .brightness:
                let v = min(max(baseBrightness + (-t.y / view.bounds.height), 0.02), 1)
                UIScreen.main.brightness = v
                showHUD(barText("亮度", Float(v)))

            case .volume:
                let cur = AVAudioSession.sharedInstance().outputVolume
                let v = min(max(cur + Float(-t.y / view.bounds.height), 0), 1)
                setSystemVolume(v)
                showHUD(barText("音量", v))

            case .switchMedia:
                if abs(t.y) > 150, !didSwitch {
                    didSwitch = true
                    if t.y < 0 { playNext() } else { playPrev() }
                }

            case .none:
                break
            }

        case .ended, .cancelled:
            if panMode == .seek {
                let total = playerView.playerLayer?.player.duration ?? 0
                if total > 0 {
                    let delta = Double(t.x / view.bounds.width) * total * 0.5
                    let target = min(max(seekStartTime + delta, 0), total)
                    playerView.seek(time: target) { _ in }
                }
            }
            panMode = .none
            panStart = nil
            didSwitch = false
            hideHUD(after: 0.3)

        default:
            break
        }
    }

    private var didSwitch = false

    @objc private func onDoubleTap() {
        guard let p = playerView.playerLayer?.player else { return }
        if p.isPlaying {
            playerView.pause()
            flash("暂停")
        } else {
            playerView.play()
            flash("播放")
        }
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard let p = playerView.playerLayer?.player else { return }
        switch g.state {
        case .began:
            normalRate = p.playbackRate > 0 ? p.playbackRate : 1
            p.playbackRate = 2
            showPersistentHUD("2× 快进")
        case .ended, .cancelled:
            p.playbackRate = normalRate
            hideHUD(after: 0.2)
        default:
            break
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard let layer = playerView.subviews.first else { return }
        if g.state == .changed {
            let s = max(1, min(g.scale, 3))
            layer.transform = CGAffineTransform(scaleX: s, y: s)
        } else if g.state == .ended, g.scale < 1.05 {
            layer.transform = .identity
        }
    }

    // MARK: - 上下一集

    @discardableResult
    func playNext() -> Bool {
        guard index + 1 < playlist.count else {
            flash("已经是最后一个")
            return false
        }
        persistProgress()
        load(index: index + 1)
        flash("下一集")
        return true
    }

    @discardableResult
    func playPrev() -> Bool {
        guard index - 1 >= 0 else {
            flash("已经是第一个")
            return false
        }
        persistProgress()
        load(index: index - 1)
        flash("上一集")
        return true
    }

    // MARK: - 音量

    private lazy var volumeView: MPVolumeView = {
        let v = MPVolumeView(frame: .zero)
        v.showsRouteButton = false
        v.alpha = 0.001
        return v
    }()

    private func setupHUD() {
        view.addSubview(volumeView)
    }

    private func setSystemVolume(_ v: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.async { slider.value = v }
    }

    // MARK: - 状态轮询与进度保存

    private func startStatePolling() {
        stateTimer?.invalidate()
        var last: String?
        var tick = 0

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, let layer = self.playerView.playerLayer else { return }
            tick += 1

            let st = "\(layer.state)"
            if st != last {
                last = st
                Log.event("player", "state → \(st)")
            }

            let playing = layer.player.isPlaying
            if !playing || tick <= 6 {
                let t = layer.player.currentPlaybackTime
                Log.event("player", "playing=\(playing) buffering=\(layer.bufferingProgress)% t=\(String(format: "%.1f", t))")
            } else if tick == 7 {
                Log.event("player", "已开播，停止细节轮询")
                timer.invalidate()
            }

            // 播完自动下一个
            if st.contains("playedToEnd") || st.contains("finished") {
                self.handleFinished()
            }
        }
    }

    private var handlingFinish = false

    private func handleFinished() {
        guard !handlingFinish else { return }
        handlingFinish = true
        persistProgress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if !self.playNext() {
                Log.event("player", "播放列表结束")
            }
            self.handlingFinish = false
        }
    }

    private func startProgressSaving() {
        saveTimer?.invalidate()
        // 每 5 秒存一次进度，切后台或退出时也会存
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.persistProgress()
        }
    }

    private func persistProgress() {
        guard let item = current, let layer = playerView.playerLayer else { return }
        let pos = layer.player.currentPlaybackTime
        let dur = layer.player.duration
        guard dur > 0 else { return }
        PlaybackHistory.save(url: item.url, position: pos, duration: dur)
    }

    // MARK: - HUD

    private lazy var hud: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        l.textAlignment = .center
        l.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        l.layer.cornerRadius = 9
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()

    private var hudTask: DispatchWorkItem?

    private func ensureHUD() {
        guard hud.superview == nil else { return }
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hud.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func showHUD(_ text: String) {
        ensureHUD()
        hud.text = "  \(text)  "
        hud.isHidden = false
        hudTask?.cancel()
    }

    private func showPersistentHUD(_ text: String) {
        ensureHUD()
        hud.text = "  \(text)  "
        hud.isHidden = false
        hudTask?.cancel()
    }

    private func flash(_ text: String) {
        ensureHUD()
        hud.text = "  \(text)  "
        hud.isHidden = false
        let task = DispatchWorkItem { [weak self] in self?.hud.isHidden = true }
        hudTask?.cancel()
        hudTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: task)
    }

    private func hideHUD(after delay: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in self?.hud.isHidden = true }
        hudTask?.cancel()
        hudTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func barText(_ label: String, _ v: Float) -> String {
        let n = Int(v * 10)
        let bar = String(repeating: "█", count: n) + String(repeating: "░", count: 10 - n)
        return "\(label) \(bar) \(Int(v * 100))%"
    }

    private func fmt(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private func presentAlert(_ msg: String) {
        let a = UIAlertController(title: "无法播放", message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    deinit {
        stateTimer?.invalidate()
        saveTimer?.invalidate()
        releaseAccess()
    }
}

extension MomoPlayerController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
