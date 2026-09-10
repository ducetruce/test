import SwiftUI

/// One-time setup: paste a personal access token, verify it against Oura, backfill history.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var isChecking = false
    @State private var error: String?
    @FocusState private var tokenFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your ring data, on your phone")
                            .font(.title2.weight(.semibold))
                        Text("OpenRing keeps a full local copy of your Oura data and computes sleep, readiness and activity scores on this device.")
                            .foregroundStyle(.secondary)
                    }

                    SectionCard("1. Create a token", subtitle: "cloud.ouraring.com/personal-access-tokens") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sign in to the Oura web dashboard, open Personal Access Tokens, and create one. It is a long string starting with letters and numbers.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Link("Open the Oura token page", destination: URL(string: "https://cloud.ouraring.com/personal-access-tokens")!)
                                .font(.footnote)
                        }
                    }

                    SectionCard("2. Paste it here", subtitle: "Stored in the iOS Keychain, never sent anywhere else") {
                        VStack(alignment: .leading, spacing: 12) {
                            SecureField("Personal access token", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($tokenFieldFocused)

                            if let error {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }

                            Button {
                                Task { await connect() }
                            } label: {
                                HStack {
                                    if isChecking { ProgressView().padding(.trailing, 4) }
                                    Text(isChecking ? "Checking…" : "Connect and sync")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
                        }
                    }

                    SectionCard("What you get", subtitle: nil) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Scores computed on-device from your raw sleep, HRV, heart rate and activity data", systemImage: "function")
                            Label("Six months of history downloaded on first sync, kept offline", systemImage: "internaldrive")
                            Label("No account, no analytics, no server other than Oura's own API", systemImage: "lock")
                        }
                        .font(.footnote)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { tokenFieldFocused = true }
        }
    }

    private func connect() async {
        isChecking = true
        error = nil
        defer { isChecking = false }

        if let failure = await model.validate(token: token) {
            error = failure
            return
        }
        model.saveToken(token)
        model.hasCompletedOnboarding = true
        await model.sync(fullHistory: true)
    }
}
