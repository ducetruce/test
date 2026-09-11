import SwiftUI
import UniformTypeIdentifiers

private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var exportFile: ExportFile?
    @State private var showingEraseConfirmation = false
    @State private var showingTokenSheet = false
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    LabeledContent("Last sync") {
                        Text(model.lastSync.map { Format.relative($0) } ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Days stored") {
                        Text("\(model.scores.count)")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Label("Sync now", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isSyncing)

                    Button {
                        Task { await model.sync(fullHistory: true) }
                    } label: {
                        Label("Re-download 6 months", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(model.isSyncing)
                }

                if !model.warnings.isEmpty {
                    Section("Last sync notes") {
                        ForEach(model.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Account") {
                    if let info = model.database.personalInfo {
                        if let email = info.email {
                            LabeledContent("Oura account") { Text(email).foregroundStyle(.secondary) }
                        }
                        if let age = info.age {
                            LabeledContent("Age") { Text("\(age)").foregroundStyle(.secondary) }
                        }
                    }
                    Button("Replace access token") { showingTokenSheet = true }
                    Button("Sign out", role: .destructive) { model.signOut() }
                }

                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import Oura data export", systemImage: "square.and.arrow.down")
                    }
                    if let report = model.importReport {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Imported \(report.totalImported) days from \(report.files.count) file(s)")
                                .font(.footnote)
                            if report.skippedExisting > 0 {
                                Text("\(report.skippedExisting) rows already covered by API data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !report.unmappedColumns.isEmpty {
                                Text("Unrecognised columns: \(report.unmappedColumns.sorted().joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text("Request your export at membership.ouraring.com/data-export. No token or membership needed — exported days only fill gaps the API has not already covered.")
                }

                Section {
                    NavigationLink {
                        RingSyncView()
                    } label: {
                        Label("Sync directly from ring", systemImage: "dot.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Reads the ring's history over Bluetooth with no cloud involved. Needs the ring's 16-byte auth key — either extracted from the official app, or one you install yourself on a factory-reset ring.")
                }

                Section("Data") {
                    Button {
                        Task { exportFile = await model.exportData().map(ExportFile.init) }
                    } label: {
                        Label("Export everything as JSON", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        showingEraseConfirmation = true
                    } label: {
                        Label("Erase local data", systemImage: "trash")
                    }
                }

                Section {
                    NavigationLink("How the scores are calculated") { ScoringExplainerView() }
                } footer: {
                    Text("OpenRing is an independent personal project. It is not affiliated with, endorsed by, or supported by Ōura Health Oy, and the scores it shows are its own, not Oura's.")
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $exportFile) { file in
                VStack(spacing: 16) {
                    Text("Your data is ready")
                        .font(.headline)
                    ShareLink(item: file.url) {
                        Label("Share JSON export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .presentationDetents([.height(180)])
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.zip, .commaSeparatedText, .json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await model.importExport(at: url) }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingTokenSheet) {
                TokenEntrySheet()
                    .environmentObject(model)
            }
            .alert("Erase all local data?", isPresented: $showingEraseConfirmation) {
                Button("Erase", role: .destructive) {
                    Task { await model.eraseAllData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your data stays in your Oura account — this only clears the copy on this phone. You can re-download it at any time.")
            }
        }
    }
}

struct TokenEntrySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Personal access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Create one at cloud.ouraring.com/personal-access-tokens.")
                    }
                }
            }
            .navigationTitle("Access token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChecking ? "Checking…" : "Save") {
                        Task {
                            isChecking = true
                            defer { isChecking = false }
                            if let failure = await model.validate(token: token) {
                                error = failure
                                return
                            }
                            model.saveToken(token)
                            dismiss()
                            await model.sync()
                        }
                    }
                    .disabled(token.isEmpty || isChecking)
                }
            }
        }
    }
}

/// Plain-language description of every contributor, so the numbers are never a black box.
struct ScoringExplainerView: View {
    private let engine = ScoreEngine()

    var body: some View {
        List {
            Section {
                Text("Scores are computed on this device from the raw measurements your ring records. They follow the same contributors Oura publishes, but the curves are OpenRing's own, so numbers can differ from the Oura app by a few points.")
                    .font(.footnote)
            }

            Section("Sleep") {
                explain("Total sleep", "22%", "Full credit from about 7 to 9 hours.")
                explain("Restfulness", "14%", "Restless periods per hour of sleep.")
                explain("REM sleep", "14%", "Share of the night in REM, ideal around 20–25%.")
                explain("Deep sleep", "14%", "Share of the night in deep sleep, ideal around 15–20%.")
                explain("Timing", "14%", "How far the midpoint of the night sits from 03:00.")
                explain("Efficiency", "12%", "Time asleep divided by time in bed.")
                explain("Latency", "10%", "Minutes to fall asleep; 10–20 is ideal.")
            }

            Section("Readiness") {
                explain("HRV balance", "20%", "Last night's average HRV against your 14-day median.")
                explain("Resting heart rate", "18%", "Lowest nightly heart rate against your 14-day median.")
                explain("Previous night", "18%", "Your sleep score for the night just recorded.")
                explain("Body temperature", "14%", "Deviation from your own temperature baseline.")
                explain("Sleep balance", "12%", "Two-week average sleep against a \(Format.number(engine.sleepNeedHours, decimals: 1))-hour need.")
                explain("Activity balance", "8%", "Last week's training load against your four-week average.")
                explain("Previous day activity", "5%", "How hard yesterday was.")
                explain("Recovery index", "5%", "How early in the night your heart rate bottomed out.")
            }

            Section("Activity") {
                explain("Meet daily targets", "28%", "Active calories against your Oura target.")
                explain("Stay active", "18%", "Hours spent sedentary.")
                explain("Training volume", "18%", "Weekly medium and high MET-minutes against \(Int(engine.weeklyMETMinuteTarget)).")
                explain("Training frequency", "16%", "Days in the last week with 20+ minutes of real activity.")
                explain("Move every hour", "12%", "Inactivity alerts recorded by the ring.")
                explain("Recovery time", "8%", "Heavy recent training paired with a poor night costs points.")
            }

            Section {
                Text("Missing signals are skipped rather than counted as zero: the remaining contributors are re-weighted so a night without a temperature reading is not punished.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Scoring")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func explain(_ title: String, _ weight: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(weight).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
