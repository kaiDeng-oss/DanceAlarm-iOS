import Foundation

/// 闹钟授权状态
enum AlarmAuthState {
    case unknown
    case notDetermined
    case authorized
    case denied
}

/// 闹钟后端。iOS 上有两条可用路径：
///  - `AlarmKitBackend`（iOS 26+）：系统级闹钟，**能穿透静音与专注模式**，无需苹果审批
///  - `NotificationBackend`：本地通知，兼容旧系统，但静音时不会响
protocol AlarmBackend: AnyObject {
    var displayName: String { get }
    func refreshAuthorization() async -> AlarmAuthState
    func requestAuthorization() async -> AlarmAuthState
    func schedule(_ alarm: Alarm) async throws
    func cancel(_ alarm: Alarm) async
    func cancelAll() async
    /// 单次延后触发（贪睡用）
    func scheduleOneshot(_ alarm: Alarm, at date: Date) async
    /// 清掉尚未触发的贪睡，避免「已经跳过舞了，5 分钟后又被自己叫醒」
    func cancelSnooze(_ alarm: Alarm) async
}
