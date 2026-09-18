import Foundation

/// 闹钟调度总入口。对外只暴露这一层，内部按系统版本选后端：
/// iOS 26+ 用 AlarmKit（能穿透静音），更早的系统退回本地通知。
///
/// 不标 `@MainActor`（理由见 RingCoordinator），实际调用点都在主线程。
final class AlarmScheduler: ObservableObject {

    static let shared = AlarmScheduler()

    /// 贪睡时长（分钟）
    static let snoozeMinutes = 5

    @Published private(set) var authState: AlarmAuthState = .unknown
    @Published private(set) var lastError: String?

    private let backend: AlarmBackend
    private let usesAlarmKit: Bool

    /// 当前走的是不是 AlarmKit 系统闹钟
    var isUsingAlarmKit: Bool { usesAlarmKit }

    /// 给人看的后端名字，显示在权限卡片里
    var backendName: String { backend.displayName }

    private init() {
        #if canImport(AlarmKit) && !DISABLE_ALARMKIT
        if #available(iOS 26.0, *) {
            backend = AlarmKitBackend()
            usesAlarmKit = true
        } else {
            backend = NotificationBackend.shared
            usesAlarmKit = false
        }
        #else
        backend = NotificationBackend.shared
        usesAlarmKit = false
        #endif

        // 通知后端即使不作为主力也要实例化：它同时是通知回调的 delegate。
        // 用户点了「开始跳舞」「再睡 5 分钟」都要靠它把事件转给 RingCoordinator。
        _ = NotificationBackend.shared
    }

    // MARK: - 启动准备

    func prepare() async {
        await refreshAuthorization()
        if usesAlarmKit {
            // 之前可能用过通知方案（比如系统升级前），把残留的通知清掉，避免重复响
            await NotificationBackend.shared.cancelAll()
        }
    }

    // MARK: - 授权

    func refreshAuthorization() async {
        authState = await backend.refreshAuthorization()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        authState = await backend.requestAuthorization()
        return authState == .authorized
    }

    // MARK: - 排程

    func schedule(_ alarm: Alarm) async {
        guard alarm.enabled else {
            await cancel(alarm)
            return
        }
        do {
            try await backend.schedule(alarm)
            lastError = nil
        } catch {
            lastError = "闹钟设置失败：\(error.localizedDescription)"
        }
    }

    func cancel(_ alarm: Alarm) async {
        // 后端的 cancel 实现里已经顺手清掉了这个闹钟的贪睡排程
        await backend.cancel(alarm)
    }

    /// 全量重排。App 启动、闹钟增删改、系统时区变化后都该调一次，
    /// 保证系统里的排程和本地数据永远一致。
    func rescheduleAll(_ alarms: [Alarm]) async {
        for alarm in alarms {
            if alarm.enabled {
                await schedule(alarm)
            } else {
                await backend.cancel(alarm)
            }
        }
    }

    func cancelEverything() async {
        await backend.cancelAll()
    }

    // MARK: - 贪睡

    func scheduleSnooze(for alarm: Alarm, afterMinutes minutes: Int) {
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        Task { await backend.scheduleOneshot(alarm, at: date) }
    }

    func cancelSnooze(for alarm: Alarm) {
        Task { await backend.cancelSnooze(alarm) }
    }

    /// 需要等待完成时用这个（比如刚改完设置，要保证清理干净再返回）
    func cancelSnoozeAndWait(for alarm: Alarm) async {
        await backend.cancelSnooze(alarm)
    }
}
