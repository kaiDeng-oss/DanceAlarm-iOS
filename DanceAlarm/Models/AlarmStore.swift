import Foundation

/// 闹钟的持久化存储。数据量很小，直接用 UserDefaults 存 JSON —— 不引 SwiftData/CoreData，
/// 省掉模型迁移的麻烦，也让「卸载重装不丢配置」这类边界问题简单可控。
///
/// 与 RingCoordinator 一样刻意不标 `@MainActor`，改为约定所有改动都在主线程发生，
/// 避免不同 Swift 版本对主线程单例引用的检查差异导致编译失败。
final class AlarmStore: ObservableObject {

    static let shared = AlarmStore()

    @Published private(set) var alarms: [Alarm] = []

    private let defaults = UserDefaults.standard
    private let alarmsKey = "dancealarm.alarms.v1"
    private let snoozeKey = "dancealarm.snoozeUsed.v1"

    private init() {
        load()
    }

    // MARK: - 读写

    private func load() {
        guard let data = defaults.data(forKey: alarmsKey) else {
            alarms = []
            return
        }
        alarms = (try? JSONDecoder().decode([Alarm].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        defaults.set(data, forKey: alarmsKey)
    }

    func alarm(id: UUID) -> Alarm? {
        alarms.first { $0.id == id }
    }

    func upsert(_ alarm: Alarm) {
        if let idx = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[idx] = alarm
        } else {
            alarms.append(alarm)
        }
        sortAndPersist()
    }

    func delete(id: UUID) {
        alarms.removeAll { $0.id == id }
        clearSnooze(for: id)
        sortAndPersist()
    }

    func setEnabled(id: UUID, _ enabled: Bool) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[idx].enabled = enabled
        sortAndPersist()
    }

    private func sortAndPersist() {
        alarms.sort { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }
        persist()
    }

    // MARK: - 贪睡次数（按闹钟、按「本次响铃」计）

    private func snoozeMap() -> [String: Int] {
        defaults.dictionary(forKey: snoozeKey) as? [String: Int] ?? [:]
    }

    func snoozeUsed(for id: UUID) -> Int {
        snoozeMap()[id.uuidString] ?? 0
    }

    func bumpSnooze(for id: UUID) {
        var map = snoozeMap()
        map[id.uuidString] = (map[id.uuidString] ?? 0) + 1
        defaults.set(map, forKey: snoozeKey)
    }

    /// 一次响铃流程彻底结束后清零，下次响铃又有完整的贪睡额度
    func clearSnooze(for id: UUID) {
        var map = snoozeMap()
        map.removeValue(forKey: id.uuidString)
        defaults.set(map, forKey: snoozeKey)
    }

    // MARK: - 一次性闹钟

    /// 响过之后：一次性闹钟自动关闭，重复闹钟保持不变
    func consumeOnce(id: UUID) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        if alarms[idx].repeatDays.isEmpty {
            alarms[idx].enabled = false
            sortAndPersist()
        }
    }
}
