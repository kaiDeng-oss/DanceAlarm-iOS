import SwiftUI
import UIKit

/// 全屏响铃界面：摄像头对着人做实时姿态识别，累计跳满设定秒数才允许关闭。
///
/// 与安卓版的差异（都是 iOS 平台的硬限制，不是实现取舍）：
///  - iOS 不允许 App 屏蔽音量键，也不允许后台访问摄像头，所以没做「按 Home 后自动顶回前台」
///    这类防赖床手段。这里靠的是：闹钟本身由系统级 AlarmKit 触发（穿透静音），
///    以及进界面后 `.playback` 音频无视静音开关持续响。
///  - 屏幕常亮仍然可以做到，用 `isIdleTimerDisabled`。
struct RingingView: View {

    let alarm: Alarm
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    @StateObject private var camera: CameraPoseController
    @State private var player = AlarmAudioPlayer()

    /// 安全阀计时：相机全程识别不到人超过 45 秒才放行，避免「人还没走到镜头前」被误判
    @State private var escapeElapsed = 0
    @State private var everDetected = false
    @State private var snoozeUsed = 0

    private static let escapeThresholdSec = 45

    init(alarm: Alarm, onDismiss: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        self.alarm = alarm
        self.onDismiss = onDismiss
        self.onSnooze = onSnooze
        _camera = StateObject(
            wrappedValue: CameraPoseController(requiredMs: Int64(alarm.danceSeconds) * 1000)
        )
    }

    private var snapshot: DanceSnapshot? { camera.snapshot }

    private var phase: DancePhase { snapshot?.phase ?? .noPerson }

    private var displayHint: String {
        if let error = camera.cameraError { return error }
        return snapshot?.hint ?? "正在启动摄像头…"
    }

    private var snoozeAllowed: Bool {
        alarm.snoozeEnabled && snoozeUsed < alarm.maxSnooze
    }

    private var showEscapeHatch: Bool {
        !everDetected && escapeElapsed >= Self.escapeThresholdSec
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            SkeletonOverlay(snapshot: camera.snapshot, mirror: true)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                progressRing
                Spacer(minLength: 0)
                footer
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled(true)
        .onAppear(perform: startSession)
        .onDisappear(perform: endSession)
        .task { await escapeWatchdog() }
    }

    // MARK: - 顶部：闹钟信息与实时提示

    private var header: some View {
        VStack(spacing: 6) {
            Text("⏰ <\(alarm.timeText)> 起来跳舞")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(displayHint)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(phase.tint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.62).ignoresSafeArea(edges: .top))
    }

    // MARK: - 中部：进度环

    private var progressRing: some View {
        let progress = CGFloat(snapshot?.progress ?? 0)
        let tint = phase.tint

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 15, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(progress, 0.001))
                .stroke(tint, style: StrokeStyle(lineWidth: 15, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("还差 \(snapshot?.remainingSec ?? alarm.danceSeconds) 秒")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: 190, height: 190)
        .animation(.linear(duration: 0.15), value: progress)
    }

    // MARK: - 底部：强度、参数、贪睡、安全阀

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("舞蹈强度")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                IntensityBar(value: CGFloat(snapshot?.intensity ?? 0), tint: phase.tint)
            }

            Text(String(
                format: "摆幅 %.2f · 活跃关节 %d/8 · 节拍 %.1fHz",
                Double(snapshot?.amplitude ?? 0),
                snapshot?.activeJoints ?? 0,
                Double(snapshot?.beatHz ?? 0)
            ))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))

            Text("累计计时 · 停下就暂停")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))

            if snoozeAllowed {
                Button(action: onSnooze) {
                    Text("再睡 \(AlarmScheduler.snoozeMinutes) 分钟（剩 \(alarm.maxSnooze - snoozeUsed) 次）")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                        )
                }
                .padding(.top, 4)
            }

            if showEscapeHatch {
                Button(action: onDismiss) {
                    Text("摄像头一直识别不到人，点此直接关闭本次闹钟")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.62).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - 会话生命周期

    private func startSession() {
        UIApplication.shared.isIdleTimerDisabled = true
        camera.onCompleted = { onDismiss() }
        camera.start()
        player.start()
        snoozeUsed = AlarmStore.shared.snoozeUsed(for: alarm.id)
    }

    private func endSession() {
        camera.stop()
        player.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func escapeWatchdog() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            escapeElapsed += 1
            if !camera.snapshot.landmarks.isEmpty { everDetected = true }
            let used = AlarmStore.shared.snoozeUsed(for: alarm.id)
            if used != snoozeUsed { snoozeUsed = used }
        }
    }
}

/// 舞蹈强度条
private struct IntensityBar: View {
    let value: CGFloat
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 10)
    }
}
