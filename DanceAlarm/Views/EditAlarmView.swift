import SwiftUI

/// 新建 / 编辑闹钟
struct EditAlarmView: View {

    let original: Alarm?
    let onSave: (Alarm) -> Void
    let onDelete: ((Alarm) -> Void)?

    @State private var time: Date
    @State private var label: String
    @State private var days: Set<Int>
    @State private var snoozeEnabled: Bool
    @State private var maxSnooze: Int
    @State private var danceSeconds: Int

    private static let danceOptions = [15, 30, 45, 60]

    init(
        original: Alarm?,
        onSave: @escaping (Alarm) -> Void,
        onDelete: ((Alarm) -> Void)? = nil
    ) {
        self.original = original
        self.onSave = onSave
        self.onDelete = onDelete

        let base = original ?? Alarm(hour: 7, minute: 0, repeatDays: Set(1...5), danceSeconds: 30)

        var comps = DateComponents()
        comps.hour = base.hour
        comps.minute = base.minute
        comps.second = 0

        _time = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        _label = State(initialValue: base.label)
        _days = State(initialValue: base.repeatDays)
        _snoozeEnabled = State(initialValue: base.snoozeEnabled)
        _maxSnooze = State(initialValue: base.maxSnooze)
        _danceSeconds = State(initialValue: base.danceSeconds)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(text: "重复")
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { day in
                                DayChip(
                                    text: Alarm.dayNames[day - 1],
                                    selected: days.contains(day)
                                ) {
                                    if days.contains(day) { days.remove(day) } else { days.insert(day) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Text(days.isEmpty
                             ? "未选择 = 只响一次"
                             : "已选：\(days.sorted().map { Alarm.dayNames[$0 - 1] }.joined(separator: " "))")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.faint)
                            .padding(.top, 6)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(text: "跳舞时长（必须跳满才能关闭）")
                        HStack(spacing: 8) {
                            ForEach(Self.danceOptions, id: \.self) { seconds in
                                DayChip(text: "\(seconds) 秒", selected: danceSeconds == seconds) {
                                    danceSeconds = seconds
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle(text: "标签")
                        TextField("起床跳舞", text: $label)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white)
                            )
                    }

                    CardBox {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("允许贪睡")
                                    .font(.system(size: 15, weight: .medium))
                                Text("每次贪睡 \(AlarmScheduler.snoozeMinutes) 分钟，用完就必须跳舞")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.subText)
                            }
                            Spacer(minLength: 0)
                            Toggle("", isOn: $snoozeEnabled)
                                .labelsHidden()
                                .tint(Brand.accent)
                        }
                    }

                    if snoozeEnabled {
                        CardBox {
                            HStack {
                                Text("贪睡次数上限")
                                    .font(.system(size: 14))
                                Spacer()
                                Stepper(
                                    "\(maxSnooze) 次",
                                    value: $maxSnooze,
                                    in: 0...9
                                )
                                .labelsHidden()
                                Text("\(maxSnooze) 次")
                                    .font(.system(size: 14))
                                    .frame(minWidth: 44, alignment: .trailing)
                            }
                        }
                    }

                    Button {
                        onSave(currentAlarm())
                    } label: {
                        Text("保存并启用")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Brand.accent)
                            )
                    }
                    .padding(.top, 4)

                    if let original, let onDelete {
                        Button(role: .destructive) {
                            onDelete(original)
                        } label: {
                            Text("删除这个闹钟")
                                .font(.system(size: 15))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                        }
                    }
                }
                .padding(20)
            }
            .background(Brand.page)
            .navigationTitle(original == nil ? "新建闹钟" : "编辑闹钟")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func currentAlarm() -> Alarm {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let base = original ?? Alarm()
        return Alarm(
            id: base.id,
            hour: comps.hour ?? 7,
            minute: comps.minute ?? 0,
            label: label.isEmpty ? "起床跳舞" : label,
            repeatDays: days,
            enabled: true,
            snoozeEnabled: snoozeEnabled,
            maxSnooze: maxSnooze,
            danceSeconds: danceSeconds
        )
    }
}

/// 圆角选择标签
private struct DayChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : Color.primary)
                .frame(minWidth: 38)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Brand.accent : Color.white)
                )
        }
        .buttonStyle(.plain)
    }
}
