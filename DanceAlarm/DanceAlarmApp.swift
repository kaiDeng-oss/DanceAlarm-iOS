import SwiftUI

@main
struct DanceAlarmApp: App {

    @StateObject private var store = AlarmStore.shared
    @StateObject private var scheduler = AlarmScheduler.shared
    @StateObject private var coordinator = RingCoordinator.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(scheduler)
                .environmentObject(coordinator)
                .preferredColorScheme(.light)
                .tint(Brand.accent)
        }
        .onChange(of: scenePhase) { phase in
            // 回到前台时重排一遍：系统里的排程可能因为时区变化、系统重启、
            // 或者用户在别处改了设置而失效，重排一次是最省心的自愈方式。
            guard phase == .active else { return }
            Task {
                await scheduler.refreshAuthorization()
                await scheduler.rescheduleAll(store.alarms)
            }
        }
    }
}

struct RootView: View {

    @EnvironmentObject private var store: AlarmStore
    @EnvironmentObject private var scheduler: AlarmScheduler
    @EnvironmentObject private var coordinator: RingCoordinator

    var body: some View {
        HomeView(store: store, scheduler: scheduler)
            .fullScreenCover(item: $coordinator.ringingAlarm) { alarm in
                RingingView(
                    alarm: alarm,
                    onDismiss: { coordinator.finishDance() },
                    onSnooze: { coordinator.snooze() }
                )
            }
            .alert(
                "提示",
                isPresented: Binding(
                    get: { coordinator.notice != nil },
                    set: { if !$0 { coordinator.notice = nil } }
                ),
                presenting: coordinator.notice
            ) { _ in
                Button("知道了", role: .cancel) { coordinator.notice = nil }
            } message: { text in
                Text(text)
            }
    }
}
