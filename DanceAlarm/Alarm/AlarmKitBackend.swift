import Foundation

// AlarmKit 需要 iOS 26 SDK。用 canImport 让旧 SDK 自动跳过这段代码，
// 另外留了一个手动开关：在 Target → Build Settings → Other Swift Flags 加
// `-DDISABLE_ALARMKIT` 即可强制退回通知方案（万一这套 API 在你的 Xcode 版本上编译不过）。
#if canImport(AlarmKit) && !DISABLE_ALARMKIT

import AlarmKit
import AppIntents
import SwiftUI

/// 本项目自己有一个 `Alarm` 模型（Models/Alarm.swift），它会**遮蔽** AlarmKit 的同名类型 ——
/// 直接写 `Alarm.Schedule` 会被解析成 `DanceAlarm.Alarm`，编译器报：
///   "'Schedule' is not a member type of struct 'DanceAlarm.Alarm'"
/// 所以凡是要引用系统闹钟类型的地方，必须走 `AlarmKit.Alarm` 全限定名。这里起个别名减少噪音。
/// 必须带 `@available`：`AlarmKit.Alarm` 本身只在 iOS 26+ 可用，
/// 而本工程的部署目标是 iOS 16 —— 少这一行编译器会直接报
/// "'Alarm' is only available in iOS 26.0 or newer"。
@available(iOS 26.0, *)
private typealias SystemAlarm = AlarmKit.Alarm

/// 传给闹钟的附加数据。AlarmMetadata 要求 Decodable / Encodable / Hashable / Sendable，
/// 由编译器自动合成。
@available(iOS 26.0, *)
struct DanceAlarmMetadata: AlarmMetadata {
    var alarmID: String
    var danceSeconds: Int
}

/// 点系统闹钟的「停止」按钮时执行。
///
/// 关键点 `openAppWhenRun = true`：让「停止」直接把 App 拉起来进跳舞界面。
/// 否则用户一按停止就完事了，跳舞这一关形同虚设 —— 这是 AlarmKit 上最容易漏掉的一环。
/// 必须实现 `LiveActivityIntent` 而**不是**普通的 `AppIntent`：
/// AlarmKit 的 `stopIntent` 形参要求类型符合 `LiveActivityIntent`，
/// 用 AppIntent 会报 "argument type 'OpenDanceIntent' does not conform to
/// expected type 'LiveActivityIntent'"。
/// 另外 `LiveActivityIntent.perform()` 本身是 `@MainActor` 隔离的，不必再手动派发。
@available(iOS 26.0, *)
struct OpenDanceIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "起来跳舞"
    static let description = IntentDescription("打开跳舞闹钟，跳满设定秒数才能关闭")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "闹钟 ID")
    var alarmID: String

    init() {
        alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let uuid = UUID(uuidString: alarmID) {
            RingCoordinator.shared.begin(alarmID: uuid)
        }
        return .result()
    }
}

/// AlarmKit 后端：iOS 26+ 的系统级闹钟。
///
/// 相比通知方案的三个决定性优势：
///  1. **穿透静音开关** —— 手机静音也照样响，这是闹钟类应用的生命线；
///  2. **穿透专注模式**，并且会出现在锁屏、灵动岛、以及配对的 Apple Watch 上；
///  3. 停止按钮可以接管，强制拉起跳舞界面。
///
/// 不需要任何苹果审批或特殊 entitlement，只要用户授权即可。
@available(iOS 26.0, *)
final class AlarmKitBackend: AlarmBackend {

    var displayName: String { "AlarmKit 系统闹钟（可穿透静音）" }

    private let manager = AlarmManager.shared
    private let snoozeKeyPrefix = "dancealarm.snoozeAlarm."

    // MARK: - 授权

    func refreshAuthorization() async -> AlarmAuthState {
        Self.map(manager.authorizationState)
    }

    func requestAuthorization() async -> AlarmAuthState {
        do {
            let state = try await manager.requestAuthorization()
            return Self.map(state)
        } catch {
            return .unknown
        }
    }

    private static func map(_ state: AlarmManager.AuthorizationState) -> AlarmAuthState {
        switch state {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    // MARK: - 排程

    func schedule(_ alarm: Alarm) async throws {
        let time = SystemAlarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute)
        let recurrence: SystemAlarm.Schedule.Relative.Recurrence =
            alarm.repeatDays.isEmpty ? .never : .weekly(alarm.localeWeekdays)
        let schedule = SystemAlarm.Schedule.relative(
            SystemAlarm.Schedule.Relative(time: time, repeats: recurrence)
        )

        try await manager.schedule(
            id: alarm.id,
            configuration: configuration(for: alarm, schedule: schedule)
        )
    }

    func scheduleOneshot(_ alarm: Alarm, at date: Date) async {
        // 贪睡用一次性闹钟。刻意换一个 id：复用原 id 会把周期闹钟覆盖掉。
        let snoozeID = UUID()
        UserDefaults.standard.set(snoozeID.uuidString, forKey: snoozeKeyPrefix + alarm.id.uuidString)
        do {
            try await manager.schedule(
                id: snoozeID,
                configuration: configuration(for: alarm, schedule: .fixed(date))
            )
        } catch {
            UserDefaults.standard.removeObject(forKey: snoozeKeyPrefix + alarm.id.uuidString)
        }
    }

    func cancel(_ alarm: Alarm) async {
        await cancelSnooze(alarm)
        try? await manager.cancel(id: alarm.id)
    }

    func cancelSnooze(_ alarm: Alarm) async {
        let key = snoozeKeyPrefix + alarm.id.uuidString
        guard let raw = UserDefaults.standard.string(forKey: key),
              let uuid = UUID(uuidString: raw) else { return }
        try? await manager.cancel(id: uuid)
        UserDefaults.standard.removeObject(forKey: key)
    }

    func cancelAll() async {
        guard let alarms = try? manager.alarms else { return }
        for alarm in alarms {
            try? await manager.cancel(id: alarm.id)
        }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(snoozeKeyPrefix) {
            if let raw = defaults.string(forKey: key), let uuid = UUID(uuidString: raw) {
                try? await manager.cancel(id: uuid)
            }
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - 配置组装

    private func configuration(
        for alarm: Alarm,
        schedule: SystemAlarm.Schedule
    ) -> AlarmManager.AlarmConfiguration<DanceAlarmMetadata> {

        // AlarmButton 没有 `.stopButton` 这类预设成员（这是最初编译失败的报错点），
        // 只能按官方签名自己构造：init(text:textColor:systemImageName:)
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: alarm.label.isEmpty ? "起床跳舞" : alarm.label),
            stopButton: AlarmButton(
                text: "起来跳舞",
                textColor: .white,
                systemImageName: "figure.dance"
            )
        )

        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: DanceAlarmMetadata(
                alarmID: alarm.id.uuidString,
                danceSeconds: alarm.danceSeconds
            ),
            tintColor: Color(red: 1.0, green: 0.42, blue: 0.21)
        )

        return AlarmManager.AlarmConfiguration(
            schedule: schedule,
            attributes: attributes,
            stopIntent: OpenDanceIntent(alarmID: alarm.id.uuidString),
            sound: .default
        )
    }
}

#endif
