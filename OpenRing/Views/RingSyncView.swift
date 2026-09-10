import SwiftUI
import CoreBluetooth

/// Advanced screen: talk to the ring directly over BLE instead of going through the cloud.
///
/// This path needs the ring's 16-byte auth key, which only exists because the official app
/// generated it during pairing. There is no way to derive it, so the screen is explicit that
/// you must bring your own.
struct RingSyncView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var connection = RingConnection()
    @StateObject private var sync = RingSyncService()

    @State private var keyHex = ""
    @State private var showingLog = false
    @State private var captureURL: URL?

    var body: some View {
        List {
            explainer
            keySection
            deviceSection
            syncSection
            if sync.report.eventsReceived > 0 { reportSection }
            diagnosticsSection
        }
        .navigationTitle("Sync from ring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            keyHex = model.ringKey
            connection.start()
        }
        .onDisappear { connection.stopScanning() }
        .sheet(isPresented: $showingLog) { RingLogView(connection: connection) }
        .sheet(item: Binding(get: { captureURL.map { CaptureFile(url: $0) } }, set: { captureURL = $0?.url })) { file in
            VStack(spacing: 16) {
                Text("Raw event capture")
                    .font(.headline)
                Text("Every frame the ring sent, with tags and timestamps. This is what makes the undocumented event bodies mappable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: file.url) {
                    Label("Share capture", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .presentationDetents([.height(260)])
        }
    }

    // MARK: - Sections

    private var explainer: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("This reads the ring's own history stream over Bluetooth — no cloud, no token.")
                    .font(.footnote)
                Text("It needs the ring's 16-byte auth key. The key is generated when the official Oura app first pairs with the ring and is kept in that app's encrypted database; there is no master key. Extracting it means ADB on a rooted Android device, jailbreak tooling on iOS, or sniffing the pairing exchange.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keySection: some View {
        Section("Auth key") {
            SecureField("32 hex characters", text: $keyHex)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            HStack {
                Text(keyStatus.text)
                    .font(.caption)
                    .foregroundStyle(keyStatus.isValid ? .secondary : .red)
                Spacer()
                Button("Save") { model.saveRingKey(keyHex) }
                    .disabled(!keyStatus.isValid)
            }
        }
    }

    private var keyStatus: (text: String, isValid: Bool) {
        let bytes = RingProtocol.hexToBytes(keyHex)
        if keyHex.isEmpty { return ("Paste the key to enable syncing.", false) }
        guard let bytes else { return ("Not valid hex.", false) }
        guard bytes.count == 16 else { return ("\(bytes.count) bytes — the key must be exactly 16.", false) }
        return ("Valid 16-byte key.", true)
    }

    private var deviceSection: some View {
        Section("Ring") {
            LabeledContent("Status") {
                Text(connection.state.description)
                    .foregroundStyle(.secondary)
            }
            Button {
                connection.startScanning()
            } label: {
                Label("Scan for rings", systemImage: "dot.radiowaves.left.and.right")
            }
            ForEach(connection.discovered, id: \.identifier) { peripheral in
                Button {
                    Task { try? await connection.connect(to: peripheral) }
                } label: {
                    HStack {
                        Text(peripheral.name ?? peripheral.identifier.uuidString)
                        Spacer()
                        if connection.state == .ready || connection.state == .authenticated {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
            if connection.state == .ready || connection.state == .authenticated {
                Button("Disconnect", role: .destructive) { connection.disconnect() }
            }
        }
    }

    private var syncSection: some View {
        Section("History") {
            LabeledContent("Cursor") {
                Text("\(sync.cursor)").foregroundStyle(.secondary).monospacedDigit()
            }
            LabeledContent("Progress") {
                Text(sync.phase.description).foregroundStyle(.secondary)
            }
            Button {
                Task { await sync.sync(using: connection, keyHex: keyHex) }
            } label: {
                Label("Drain history from ring", systemImage: "arrow.down.circle")
            }
            .disabled(!keyStatus.isValid || !(connection.state == .ready || connection.state == .authenticated))

            Button("Reset cursor and start over") { sync.resetCursor() }
                .foregroundStyle(.orange)
        }
    }

    private var reportSection: some View {
        Section("Last drain") {
            LabeledContent("Events") { Text("\(sync.report.eventsReceived)").monospacedDigit().foregroundStyle(.secondary) }
            LabeledContent("Batches") { Text("\(sync.report.batches)").monospacedDigit().foregroundStyle(.secondary) }
            LabeledContent("Decoded samples") { Text("\(sync.report.samples)").monospacedDigit().foregroundStyle(.secondary) }
            if let first = sync.report.firstEvent, let last = sync.report.lastEvent {
                LabeledContent("Covering") {
                    Text("\(Format.dayLabel(Day(date: first))) – \(Format.dayLabel(Day(date: last)))")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(sync.kindCounts) { entry in
                LabeledContent(entry.kind) {
                    Text("\(entry.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                showingLog = true
            } label: {
                Label("Packet log (\(connection.log.count))", systemImage: "list.bullet.rectangle")
            }
            Button {
                Task { captureURL = await sync.exportCapture() }
            } label: {
                Label("Export raw capture", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Task { await sync.clearCapture() }
            } label: {
                Label("Clear capture", systemImage: "trash")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Frame transport, the auth handshake and the cursor loop are implemented from published protocol notes. Most event bodies are not publicly documented, so only temperature, MET and green-LED inter-beat intervals are decoded — everything else is captured raw for mapping later.")
        }
    }
}

private struct CaptureFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct RingLogView: View {
    @ObservedObject var connection: RingConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(connection.log) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.direction.rawValue)
                                .foregroundStyle(colour(for: entry.direction))
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Packet log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Clear") { connection.clearLog() } }
            }
        }
    }

    private func colour(for direction: RingConnection.LogEntry.Direction) -> Color {
        switch direction {
        case .out: return .blue
        case .incoming: return .green
        case .info: return .secondary
        }
    }
}
