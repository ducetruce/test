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

                if !model.database.lastSyncReports.isEmpty {
                    Section {
                        ForEach(model.database.lastSyncReports) { report in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(report.endpoint)
                                        .font(.system(.footnote, design: .monospaced))
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(report.received) records")
                                            .monospacedDigit()
                                            // Nothing at all is the loudest signal, and used
                                            // to be the quietest: no records meant no date
                                            // line, so no indicator either.
                                            .foregroundStyle(report.returnedNothing ? Color.orange : Color.secondary)
                                        if let newest = report.newestDay {
                                            Text("newest \(newest.description)")
                                                .font(.caption2)
                                                .foregroundStyle(report.missingToday ? Color.orange : Color.secondary)
                                        }
                                    }
                                }
                                if let failure = report.failure {
                                    Text(failure)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } header: {
                        Text("What the last sync returned")
                    } footer: {
                        Text("Per endpoint, over the window that was requested. Orange means either nothing came back at all, or a daily endpoint returned nothing for the most recent day asked for. Workouts, sessions, tags and VO₂ max are not daily, so a gap in those is a quiet week rather than a fault and is never flagged.")
                    }
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

                if let ring = model.database.ringInfo {
                    Section("Ring") {
                        if let battery = ring.batteryPercentage {
                            LabeledContent("Battery") {
                                Text("\(battery)%")
                                    .foregroundStyle(battery < 20 ? .red : .secondary)
                                    .monospacedDigit()
                            }
                        }
                        if let design = ring.design {
                            LabeledContent("Design") { Text(design.capitalized).foregroundStyle(.secondary) }
                        }
                        if let colour = ring.colour {
                            LabeledContent("Colour") { Text(colour.capitalized).foregroundStyle(.secondary) }
                        }
                        if let size = ring.size {
                            LabeledContent("Size") { Text("\(size)").foregroundStyle(.secondary) }
                        }
                        if let hardware = ring.hardwareType {
                            LabeledContent("Model") { Text(hardware.capitalized).foregroundStyle(.secondary) }
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
                    Button("Replace credentials") { showingTokenSheet = true }
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }
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

                Section {
                    Button {
                        Task { exportFile = await model.exportCalibration().map(ExportFile.init) }
                    } label: {
                        Label("Export score comparison (CSV)", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    LabeledContent("Fully scored days") {
                        Text("\(model.completeDayCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Calibration")
                } footer: {
                    Text("One row per day: this app's score, Oura's score for the same day, and the inputs that produced ours. No email, age, weight, height, heart-rate series or bedtimes — only the numbers a curve is fitted against. The first 28 days are skipped because the baselines have not filled yet.")
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
                        Text("Oura no longer issues personal access tokens. This accepts one created before December 2025; otherwise sign out and reconnect with OAuth.")
                    }
                }
            }
            .navigationTitle("Legacy token")
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
                            if let failure = await model.saveLegacyToken(token) {
                                error = failure
                                return
                            }
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
                Text("Scores are computed on this device from the raw measurements your ring records. The contributors follow the ones Oura publishes; the curves are OpenRing's own, fitted against 150 days of your data with a third held back to check they generalise. Held-out agreement with Oura: sleep within 5 points on 88% of days, readiness on 59%, activity on 61%.")
                    .font(.footnote)
            }

            Section("Sleep") {
                explain("Total sleep", "31%", "Rises steeply to about 8 hours, then flat — long nights are not penalised.")
                explain("Deep sleep", "15%", "Share of the night in deep sleep; credit starts earlier than first assumed.")
                explain("REM sleep", "12%", "Share of the night in REM, full credit from about 22%.")
                explain("Restfulness", "12%", "Restless periods per hour; a weaker signal than expected.")
                explain("Latency", "11%", "Minutes to fall asleep; 10–20 is ideal.")
                explain("Timing", "10%", "Midpoint against 03:00 — flat once past an hour, so it mostly marks extremes.")
                explain("Efficiency", "9%", "Time asleep divided by time in bed.")
            }

            Section("Readiness") {
                explain("Previous night", "25%", "Your sleep score for the night just recorded.")
                explain("Resting heart rate", "19%", "Lowest nightly heart rate against your 14-day median; falls off sharply past +4 bpm.")
                explain("HRV balance", "15%", "Last night's average HRV against your 14-day median.")
                explain("Body temperature", "10%", "Deviation from your own temperature baseline.")
                explain("Sleep balance", "12%", "Two-week average sleep against a \(Format.number(engine.sleepNeedHours, decimals: 1))-hour need.")
                explain("Activity balance", "8%", "Last week's training load against your four-week average.")
                explain("Previous day activity", "6%", "How hard yesterday was.")
                explain("Recovery index", "5%", "How early in the night your heart rate bottomed out.")
            }

            Section("Activity") {
                explain("Meet daily targets", "25%", "Active calories against your Oura target.")
                explain("Training volume", "23%", "Weekly medium and high MET-minutes against \(Int(engine.weeklyMETMinuteTarget)).")
                explain("Stay active", "18%", "Hours spent sedentary.")
                explain("Training frequency", "14%", "Days in the last week with 20+ minutes of real activity.")
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
