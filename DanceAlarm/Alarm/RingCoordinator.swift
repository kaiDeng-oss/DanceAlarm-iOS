import Foundation

/// 响铃会话的协调者。
///
/// 三种入口都会汇聚到这里：
///  1. 用户点通知（NotificationBackend 的 delegate）
///  2. 用户点 AlarmKit 系统闹钟的「停止」按钮（OpenDanceIntent）
///  3. App 已在前台时被唤起
///
/// 用 `@Published` 而不是直接跳转，是因为通知回调可能在界面还没建好时就触发，
/// 状态先落地、界面起来后自己认领，不会丢。
///
/// 刻意不标 `@MainActor`：不同 Swift 版本对「非隔离上下文里引用主线程单例」的处理不一致，
/// 标了容易在别的编译环境里报错。这里改为约定 —— **所有改动都显式派发到主线程**，
/// 保护效果是等价的，同时不吃版本差异。
final class RingCoordinator: ObservableObject {

    static let shared = RingCoordinator()

    /// 非 nil 时界面会全屏弹出跳舞页
    @Published var ringingAlarm: Alarm?

    /// 一次性提示（比如贪睡额度用完）
    @Published var notice: String?

    private init() {}

    func begin(alarmID: UUID) {
        guard let alarm = AlarmStore.shared.alarm(id: alarmID) else {
            notice = "找不到这个闹钟，可能已被删除"
            return
        }
        ringingAlarm = alarm
    }

    func begin(alarm: Alarm) {
        ringingAlarm = alarm
    }

    /// 跳舞达标 → 关闭闹钟
    func finishDance() {
        guard let alarm = ringingAlarm else { return }
        AlarmStore.shared.clearSnooze(for: alarm.id)
        AlarmStore.shared.consumeOnce(id: alarm.id)
        ringingAlarm = nil
    }

    /// 贪睡：扣一次额度，安排 5 分钟后再响
    func snooze() {
        guard let alarm = ringingAlarm else { return }
        let used = AlarmStore.shared.snoozeUsed(for: alarm.id)
        guard alarm.snoozeEnabled, used < alarm.maxSnooze else {
            notice = "贪睡次数已用完，必须跳舞才能关闭"
            return
        }
        AlarmStore.shared.bumpSnooze(for: alarm.id)
        AlarmScheduler.shared.scheduleSnooze(for: alarm, afterMinutes: AlarmScheduler.snoozeMinutes)
        ringingAlarm = nil
    }

    /// 安全阀：相机完全不可用时直接关掉
    func forceDismiss() {
        guard let alarm = ringingAlarm else { return }
        AlarmStore.shared.clearSnooze(for: alarm.id)
        AlarmStore.shared.consumeOnce(id: alarm.id)
        ringingAlarm = nil
    }
}
