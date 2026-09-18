import AVFoundation
import SwiftUI
import UIKit

/// 首页：设置检查卡片 + 闹钟列表
struct HomeView: View {

    @ObservedObject var store: AlarmStore
    @ObservedObject var scheduler: AlarmScheduler

    @State private var creating = false
    @State private var editing: Alarm?
    @State private var tick = 0

    private var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    intro
                    SetupCard(
                        items: setupItems,
                        backendName: scheduler.backendName,
                        isUsingAlarmKit: scheduler.isUsingAlarmKit,
                        lastError: scheduler.lastError,
                        onRefresh: {
                            tick += 1
                            Task { await scheduler.refreshAuthorization() }
                        }
                    )
                    if store.alarms.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.alarms) { alarm in
                            AlarmRow(alarm: alarm) { enabled in
                                store.setEnabled(id: alarm.id, enabled)
                                Task {
                                    if enabled, let updated = store.alarm(id: alarm.id) {
                                        await scheduler.schedule(updated)
                                    } else {
                                        await scheduler.cancel(alarm)
                                    }
                                }
                            } onTap: {
                                editing = alarm
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Brand.page)
            .navigationTitle("跳舞闹钟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $creating) {
                EditAlarmView(
                    original: nil,
                    onSave: { alarm in
                        store.upsert(alarm)
                        Task { await scheduler.schedule(alarm) }
                        creating = false
                    }
                )
            }
            .sheet(item: $editing) { alarm in
                EditAlarmView(
                    original: alarm,
                    onSave: { updated in
                        store.upsert(updated)
                        Task {
                            if updated.enabled {
                                await scheduler.schedule(updated)
                            } else {
                                await scheduler.cancel(updated)
                            }
                            await scheduler.cancelSnoozeAndWait(for: updated)
                        }
                        editing = nil
                    },
                    onDelete: { target in
                        store.delete(id: target.id)
                        Task { await scheduler.cancel(target) }
                        editing = nil
                    }
                )
            }
            .task {
                await scheduler.prepare()
                await scheduler.rescheduleAll(store.alarms)
            }
        }
    }

    // MARK: - 子视图

    private var intro: some View {
        Text("起床必须跳满设定秒数才能关掉闹钟。姿态识别全部跑在手机本地，画面不会上传。")
            .font(.system(size: 13))
            .foregroundStyle(Brand.subText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有闹钟")
                    .font(.system(size: 16, weight: .semibold))
                Text("点右上角 + 新建一个。建议把跳舞秒数设在 30 秒左右 —— 足够让身体彻底清醒，又不至于让人崩溃。")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.subText)
            }
        }
    }

    // MARK: - 设置检查项

    private var setupItems: [SetupItem] {
        // 依赖 tick 以便「重新检查」时重算
        _ = tick
        var items: [SetupItem] = []

        if scheduler.authState != .authorized {
            let denied = scheduler.authState == .denied
            items.append(SetupItem(
                id: "auth",
                title: scheduler.isUsingAlarmKit ? "闹钟权限未开启" : "通知权限未开启",
                desc: scheduler.isUsingAlarmKit
                    ? "没有这个权限，闹钟根本不会响。点这里授权。"
                    : "没有通知权限，闹钟不会响。点这里去系统设置里打开。",
                action: denied ? openSystemSettings : nil,
                isRequest: !denied
            ))
        }

        if !scheduler.isUsingAlarmKit && scheduler.authState == .authorized {
            items.append(SetupItem(
                id: "silent",
                title: "静音时闹钟不会响",
                desc: "你的系统低于 iOS 26，只能用通知方案。请把手机或侧边开关拨到响铃，或在「专注模式」里允许本应用的通知。",
                action: nil,
                isRequest: false
            ))
        }

        if !cameraAuthorized {
            items.append(SetupItem(
                id: "camera",
                title: "缺少相机权限",
                desc: "没有相机就没法检测跳舞，闹钟将无法通过验证。点这里去系统设置里开启。",
                action: openSystemSettings,
                isRequest: false
            ))
        }

        return items
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 设置检查卡片

struct SetupItem: Identifiable {
    let id: String
    let title: String
    let desc: String
    let action: (() -> Void)?
    /// true 表示点一下会直接弹系统授权框，false 表示跳到设置页
    let isRequest: Bool
}

struct SetupCard: View {

    let items: [SetupItem]
    let backendName: String
    let isUsingAlarmKit: Bool
    let lastError: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let lastError {
                CardBox(background: Brand.warnCard) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("出错了")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.warnTitle)
                        Text(lastError)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.subText)
                    }
                }
            }

            if !items.isEmpty {
                CardBox(background: Brand.warnCard) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("为了闹钟能可靠响起来，还有 \(items.count) 项需要设置")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.warnTitle)
                            .padding(.bottom, 10)

                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                handle(item)
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        Text(item.desc)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Brand.subText)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    if item.action != nil || item.isRequest {
                                        Text("去开启 ›")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Brand.accent)
                                    }
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index != items.count - 1 {
                                Divider().overlay(Brand.divider)
                            }
                        }

                        HStack {
                            Button("重新检查", action: onRefresh)
                                .font(.system(size: 14))
                            Spacer()
                            Button("应用设置") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }
                            .font(.system(size: 14))
                        }
                        .padding(.top, 4)
                    }
                }
            }

            CardBox(background: Brand.infoCard) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isUsingAlarmKit ? "闹钟模式：系统级闹钟" : "闹钟模式：本地通知")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.infoTitle)
                    Text(isUsingAlarmKit
                         ? "当前走 AlarmKit（\(backendName)），手机静音或开专注模式都会照常响，锁屏和灵动岛也会显示。"
                         : "当前走 \(backendName)。升级到 iOS 26 后本应用会自动改用系统级闹钟，静音也能响。")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.subText)
                }
            }
        }
    }

    private func handle(_ item: SetupItem) {
        if let action = item.action {
            action()
            return
        }
        guard item.isRequest else { return }
        Task {
            _ = await AlarmScheduler.shared.requestAuthorization()
        }
    }
}

// MARK: - 闹钟行

struct AlarmRow: View {

    let alarm: Alarm
    let onToggle: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        CardBox {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(alarm.timeText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(alarm.enabled ? Color(red: 0.17, green: 0.14, blue: 0.13) : Brand.faint)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.subText)
                    if !alarm.label.isEmpty {
                        Text(alarm.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.faint)
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { alarm.enabled }, set: { onToggle($0) }))
                    .labelsHidden()
                    .tint(Brand.accent)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }

    private var subtitle: String {
        var parts = [alarm.repeatText, "跳 \(alarm.danceSeconds) 秒"]
        if alarm.snoozeEnabled {
            parts.append("可贪睡 \(alarm.maxSnooze) 次")
        }
        return parts.joined(separator: " · ")
    }
}
