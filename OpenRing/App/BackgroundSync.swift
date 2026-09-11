import Foundation
import BackgroundTasks

/// Periodic refresh so the morning's night is already downloaded when the app is opened.
/// Deliberately independent of `AppModel`: it writes straight to disk and the UI re-reads
/// on the next foreground.
enum BackgroundSync {
    static let identifier = "com.openring.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        guard let tokens = await AuthResolver.currentProvider() else { return }
        let engine = SyncEngine(store: LocalStore())
        _ = try? await engine.sync(using: tokens)
    }
}
