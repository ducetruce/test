import SwiftUI

@main
struct OpenRingApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.readiness)
                .task {
                    await model.loadFromDisk()
                    model.selectedDay = model.latestDayWithData
                    await model.syncIfStale()
                    BackgroundSync.schedule()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, model.isLoaded else { return }
                    Task {
                        await model.loadFromDisk()
                        await model.syncIfStale()
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundSync.identifier)) {
            await BackgroundSync.run()
            BackgroundSync.schedule()
        }
    }
}
