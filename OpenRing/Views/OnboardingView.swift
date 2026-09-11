import SwiftUI

/// One-time setup. Oura deprecated personal access tokens in December 2025 and no longer
/// issues them, so the primary path is OAuth2 against an application you register yourself.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var legacyToken = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showingLegacy = false

    private var canConnect: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isWorking
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    registerCard
                    credentialsCard
                    if showingLegacy { legacyCard } else { legacyToggle }
                    privacyCard
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your ring data, on your phone")
                .font(.title2.weight(.semibold))
            Text("OpenRing keeps a full local copy of your Oura data and computes sleep, readiness and activity scores on this device.")
                .foregroundStyle(.secondary)
        }
    }

    private var registerCard: some View {
        SectionCard("1. Register an application", subtitle: "cloud.ouraring.com") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Oura stopped issuing personal access tokens in December 2025, so access now goes through OAuth. Create an application in the Oura developer portal — it takes a minute and is free.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label {
                    Text("Set the redirect URI to exactly:")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                Text(OuraAuth.redirectURI)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Link("Open the Oura developer portal", destination: URL(string: "https://cloud.ouraring.com/oauth/applications")!)
                    .font(.footnote)
            }
        }
    }

    private var credentialsCard: some View {
        SectionCard("2. Paste the application's keys", subtitle: "Stored in the iOS Keychain, never sent anywhere but Oura") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().padding(.trailing, 4) }
                        Text(isWorking ? "Waiting for Oura…" : "Sign in with Oura")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect)

                Text("This opens Oura's own sign-in page. OpenRing never sees your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legacyToggle: some View {
        Button("I already have a personal access token") {
            withAnimation { showingLegacy = true }
        }
        .font(.footnote)
    }

    private var legacyCard: some View {
        SectionCard("Legacy token", subtitle: "For tokens created before December 2025") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Existing personal access tokens still work, but Oura has said they will be switched off and they cannot be refreshed. Use this to get going now, and move to OAuth before then.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("Personal access token", text: $legacyToken)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await useLegacyToken() }
                } label: {
                    Text(isWorking ? "Checking…" : "Use this token")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(legacyToken.isEmpty || isWorking)
            }
        }
    }

    private var privacyCard: some View {
        SectionCard("What you get", subtitle: nil) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Scores computed on-device from your raw sleep, HRV, heart rate and activity data", systemImage: "function")
                Label("Six months of history downloaded on first sync, kept offline", systemImage: "internaldrive")
                Label("No account, no analytics, no server other than Oura's own API", systemImage: "lock")
            }
            .font(.footnote)
        }
    }

    private func connect() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        error = await model.connect(clientID: clientID, clientSecret: clientSecret)
    }

    private func useLegacyToken() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        if let failure = await model.saveLegacyToken(legacyToken) {
            error = failure
            return
        }
        await model.sync(fullHistory: true)
    }
}
