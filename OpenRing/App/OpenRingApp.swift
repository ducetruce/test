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
                    #if DEBUG
                    // Simulator builds in this project can never carry a real Keychain
                    // entitlement (see CLAUDE.md), so this is the only way to render the
                    // five tabs there at all. Gated on an explicit launch argument, not just
                    // #if DEBUG, so an ordinary debug run still goes through real onboarding.
                    if ProcessInfo.processInfo.arguments.contains("--preview-fixtures") {
                        model.loadPreviewFixtures()
                        return
                    }
                    #endif
                    await model.refreshConnection()
                    await model.loadFromDisk()
                    model.selectedDay = model.latestDayWithData
                    await model.syncIfStale()
                    BackgroundSync.schedule()
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    // Otherwise this fires the instant the scene activates and immediately
                    // undoes loadPreviewFixtures() above: refreshConnection() re-reads the
                    // (absent) real Keychain credential and loadFromDisk() overwrites the
                    // fixture database with whatever (nothing) is actually on disk.
                    if ProcessInfo.processInfo.arguments.contains("--preview-fixtures") { return }
                    #endif
                    guard phase == .active, model.isLoaded else { return }
                    Task {
                        await model.refreshConnection()
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
