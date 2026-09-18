import Foundation

/// 一个闹钟。
/// - Parameter repeatDays: 重复的星期，1 = 周一 … 7 = 周日；空集合表示「仅响一次」
struct Alarm: Identifiable, Codable, Equatable {

    var id: UUID
    var hour: Int
    var minute: Int
    var label: String
    var repeatDays: Set<Int>
    var enabled: Bool
    var snoozeEnabled: Bool
    var maxSnooze: Int
    var danceSeconds: Int

    init(
        id: UUID = UUID(),
        hour: Int = 7,
        minute: Int = 0,
        label: String = "起床跳舞",
        repeatDays: Set<Int> = [],
        enabled: Bool = true,
        snoozeEnabled: Bool = true,
        maxSnooze: Int = 2,
        danceSeconds: Int = 30
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.label = label
        self.repeatDays = repeatDays
        self.enabled = enabled
        self.snoozeEnabled = snoozeEnabled
        self.maxSnooze = maxSnooze
        self.danceSeconds = danceSeconds
    }

    static let dayNames = ["一", "二", "三", "四", "五", "六", "日"]

    var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var repeatText: String {
        if repeatDays.isEmpty { return "仅一次" }
        if repeatDays.count == 7 { return "每天" }
        if repeatDays == Set(1...5) { return "工作日" }
        if repeatDays == Set([6, 7]) { return "周末" }
        return (1...7).filter { repeatDays.contains($0) }
            .map { Alarm.dayNames[$0 - 1] }
            .joined(separator: " ")
    }

    /// 映射到 Foundation 的星期枚举（AlarmKit / 日历都用它）
    var localeWeekdays: [Locale.Weekday] {
        let table: [Int: Locale.Weekday] = [
            1: .monday, 2: .tuesday, 3: .wednesday, 4: .thursday,
            5: .friday, 6: .saturday, 7: .sunday,
        ]
        return repeatDays.sorted().compactMap { table[$0] }
    }

    /// 下一次响铃的时刻（仅用于「仅一次」闹钟与界面展示）
    func nextFireDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        if repeatDays.isEmpty {
            return calendar.nextDate(
                after: now,
                matching: comps,
                matchingPolicy: .nextTime
            )
        }

        var best: Date?
        for day in repeatDays.sorted() {
            var c = comps
            // Calendar 的 weekday：1 = 周日 … 7 = 周六；我们的 1 = 周一 … 7 = 周日
            c.weekday = day == 7 ? 1 : day + 1
            guard let d = calendar.nextDate(after: now, matching: c, matchingPolicy: .nextTime) else { continue }
            if best == nil || d < best! { best = d }
        }
        return best
    }
}
