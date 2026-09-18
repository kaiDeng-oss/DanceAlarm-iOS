import Foundation
import UserNotifications

/// 兜底方案：本地通知。
///
/// 为什么需要它：AlarmKit 要 iOS 26 以上，旧系统只能走通知。
///
/// 它的先天短板（这是 iOS 的平台限制，不是实现问题）：
///  - **手机静音或开了专注模式时，通知不会发出声音**，只会亮屏震动。
///    要突破这一点，要么申请苹果的 Critical Alerts 权限（需人工审批，报备理由），
///    要么用 AlarmKit —— 这就是 AlarmKit 存在的意义。
///  - 通知不能从后台直接拉起全屏界面，用户必须点一下才会打开 App。
///
/// 为了尽量弥补「忽略第一条就彻底睡过去」，这里会在闹钟时刻之后再补两条跟随提醒
/// （+1 分钟、+3 分钟），形成连续催促。iOS 对单个 App 最多只保留 64 条待发通知，
/// 所以跟随条数不能无限加。
final class NotificationBackend: NSObject, AlarmBackend {

    static let shared = NotificationBackend()

    /// 闹钟时刻之后额外补发的提醒（分钟）
    static let followUpOffsets = [0, 1, 3]

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "DANCE_ALARM"
    private let idPrefix = "dancealarm.notif."
    private let actionDance = "DANCE_NOW"
    /// 贪睡动作的标识。注册 category 与响应回调两处都要用，所以做成静态常量避免写歪
    private static let snoozeActionIdentifier = "SNOOZE"

    var displayName: String { "本地通知（静音时不响）" }

    private override init() {
        super.init()
        center.delegate = self
        registerCategory()
    }

    private func registerCategory() {
        let danceAction = UNNotificationAction(
            identifier: actionDance,
            title: "开始跳舞",
            options: [.foreground]
        )
        let snoozeAction = UNNotificationAction(
            identifier: Self.snoozeActionIdentifier,
            title: "再睡 5 分钟",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [danceAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - 授权

    func refreshAuthorization() async -> AlarmAuthState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> AlarmAuthState {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    // MARK: - 排程

    func schedule(_ alarm: Alarm) async throws {
        await cancel(alarm)
        for request in makeRequests(alarm: alarm, offsets: Self.followUpOffsets) {
            try await center.add(request)
        }
    }

    func scheduleOneshot(_ alarm: Alarm, at date: Date) async {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let request = makeRequest(alarm: alarm, components: comps, repeats: false, suffix: "snooze")
        try? await center.add(request)
    }

    func cancel(_ alarm: Alarm) async {
        let mine = await pendingIdentifiers()
            .filter { $0.hasPrefix("\(idPrefix)\(alarm.id.uuidString).") }
        center.removePendingNotificationRequests(withIdentifiers: mine)
        center.removeDeliveredNotifications(withIdentifiers: mine)
    }

    func cancelSnooze(_ alarm: Alarm) async {
        let identifier = "\(idPrefix)\(alarm.id.uuidString).snooze"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    private func makeRequests(alarm: Alarm, offsets: [Int]) -> [UNNotificationRequest] {
        var out: [UNNotificationRequest] = []
        let calendar = Calendar.current

        // 一次性闹钟：算出下一个目标时刻，再按分钟偏移展开
        if alarm.repeatDays.isEmpty {
            guard let base = alarm.nextFireDate() else { return [] }
            for (index, offset) in offsets.enumerated() {
                guard
                    let fire = calendar.date(byAdding: .minute, value: offset, to: base),
                    fire > Date()
                else { continue }
                let comps = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fire
                )
                out.append(makeRequest(alarm: alarm, components: comps,
                                       repeats: false, suffix: "once\(index)"))
            }
            return out
        }

        for (index, offset) in offsets.enumerated() {
            let totalMinutes = alarm.hour * 60 + alarm.minute + offset
            // 跨过午夜的跟随提醒直接略过：那样星期几就算错了，宁可少一条也不要错一条
            guard totalMinutes < 24 * 60 else { continue }
            let hour = totalMinutes / 60
            let minute = totalMinutes % 60

            if alarm.repeatDays.count == 7 {
                // 每天都响：省略 weekday 让它按天重复，一条请求就够
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                out.append(makeRequest(alarm: alarm, components: comps,
                                       repeats: true, suffix: "daily\(index)"))
            } else {
                for day in alarm.repeatDays.sorted() {
                    var comps = DateComponents()
                    // Calendar 的 weekday：1 = 周日 … 7 = 周六；我们的 1 = 周一 … 7 = 周日
                    comps.weekday = day == 7 ? 1 : day + 1
                    comps.hour = hour
                    comps.minute = minute
                    comps.second = 0
                    out.append(makeRequest(alarm: alarm, components: comps,
                                           repeats: true, suffix: "w\(day)-\(index)"))
                }
            }
        }
        return out
    }

    private func makeRequest(
        alarm: Alarm,
        components: DateComponents,
        repeats: Bool,
        suffix: String
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "⏰ 起来跳舞"
        let label = alarm.label.isEmpty ? "该起床了" : alarm.label
        content.body = "\(label) · 跳满 \(alarm.danceSeconds) 秒才能关掉"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.wav"))
        content.categoryIdentifier = categoryID
        // 时间敏感：能穿过部分专注模式。没有对应 entitlement 时系统会降级成普通通知，
        // 不会报错，属于「有则更好」的加分项。
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["alarmID": alarm.id.uuidString]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        return UNNotificationRequest(
            identifier: "\(idPrefix)\(alarm.id.uuidString).\(suffix)",
            content: content,
            trigger: trigger
        )
    }
}

// MARK: - 通知回调

extension NotificationBackend: UNUserNotificationCenterDelegate {

    /// App 在前台时也照常显示横幅并播放声音
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let alarmID = (info["alarmID"] as? String).flatMap { UUID(uuidString: $0) }

        if let alarmID {
            switch response.actionIdentifier {
            case Self.snoozeActionIdentifier:
                handleSnooze(alarmID: alarmID)
            default:
                Task { @MainActor in
                    RingCoordinator.shared.begin(alarmID: alarmID)
                }
            }
        }
        completionHandler()
    }

    private func handleSnooze(alarmID: UUID) {
        Task { @MainActor in
            guard let alarm = AlarmStore.shared.alarm(id: alarmID) else { return }
            let used = AlarmStore.shared.snoozeUsed(for: alarmID)
            guard alarm.snoozeEnabled, used < alarm.maxSnooze else { return }
            AlarmStore.shared.bumpSnooze(for: alarmID)
            AlarmScheduler.shared.scheduleSnooze(
                for: alarm, afterMinutes: AlarmScheduler.snoozeMinutes
            )
        }
    }
}
