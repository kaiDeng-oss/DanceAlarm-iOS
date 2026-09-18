import AudioToolbox
import AVFoundation
import Foundation

/// 响铃期间的音频播放与震动。
///
/// 关键点：把 `AVAudioSession` 设成 **`.playback`** 类别。
/// 这是 iOS 上唯一能让 App 合法无视静音开关发声的途径 —— `.ambient` 会跟着静音开关走，
/// `.playback` 不会。所以只要用户进了跳舞界面，铃声就一定响，哪怕手机拨在静音上。
///
/// 顺带把屏幕常亮也一起管了（由界面侧设置 `isIdleTimerDisabled`）。
final class AlarmAudioPlayer {

    private var player: AVAudioPlayer?
    private var vibrationTimer: Timer?

    /// 音频资源缺失时的系统提示音（1005 = 新邮件提示音，够醒目且一定有）
    private let fallbackSoundID: SystemSoundID = 1005

    var isPlaying: Bool { player?.isPlaying ?? false }

    func start() {
        configureSession()

        if let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") {
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1      // 循环播放，直到跳舞达标
                p.volume = 1.0
                p.prepareToPlay()
                p.play()
                player = p
            } catch {
                AudioServicesPlaySystemSound(fallbackSoundID)
            }
        } else {
            // 理论上不会发生（Resources/alarm.wav 会打进包），保底也要能出声
            AudioServicesPlaySystemSound(fallbackSoundID)
        }

        startVibration()
    }

    func stop() {
        player?.stop()
        player = nil
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 配置失败不阻断流程：继续尝试播放，最坏情况只是静音下听不到
        }
    }

    private func startVibration() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}
