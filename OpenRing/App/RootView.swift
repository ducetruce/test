import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.hasCompletedOnboarding || !model.isConnected {
                OnboardingView()
            } else {
                TabView {
                    TodayView()
                        .tabItem { Label("Today", systemImage: "circle.circle") }
                    SleepView()
                        .tabItem { Label("Sleep", systemImage: "bed.double") }
                    ActivityView()
                        .tabItem { Label("Activity", systemImage: "figure.walk") }
                    TrendsView()
                        .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .alert(
            "Sync failed",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
