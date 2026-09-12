import Foundation

/// Drives a full history drain: authenticate, prepare the stream, then page events until the
/// ring reports nothing left.
///
/// What this produces today is an honest subset. The frame layer, the auth handshake and the
/// cursor/acknowledgement loop are documented and implemented in full. The *bodies* of most
/// event tags are not publicly documented, so decoded samples cover only the tags with
/// published scaling rules (temperature, MET, green-LED IBI) and everything else is kept
/// byte-for-byte in a capture you can export and map against the same day's cloud data.
@MainActor
final class RingSyncService: ObservableObject {

    struct Report: Codable, Hashable {
        var eventsReceived = 0
        var batches = 0
        var bytesLeft: UInt32 = 0
        var countsByKind: [String: Int] = [:]
        var samples = 0
        var firstEvent: Date?
        var lastEvent: Date?
        var finishedCleanly = false
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case draining(events: Int, bytesLeft: UInt32)
        case finished
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .preparing: return "Preparing stream…"
            case .draining(let events, let bytesLeft):
                return "Draining — \(events) events, \(bytesLeft) bytes left"
            case .finished: return "Finished"
            case .failed(let reason): return reason
            }
        }
    }

    /// Dictionary rows need an identity SwiftUI can use, and a key path cannot address a
    /// tuple element, so counts are surfaced as a proper type.
    struct KindCount: Identifiable, Hashable {
        var kind: String
        var count: Int
        var id: String { kind }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report = Report()

    var kindCounts: [KindCount] {
        report.countsByKind
            .map { KindCount(kind: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private let store: RingCaptureStore
    private let cursorKey = "ringSyncCursor"

    /// Smaller batches than the official app uses: each one checkpoints the cursor, so a
    /// dropped connection costs one batch instead of the whole drain.
    private let batchSize: UInt8 = 64

    /// `nonisolated` so a view can build one in a property initializer.
    nonisolated init(store: RingCaptureStore = RingCaptureStore()) {
        self.store = store
    }

    var cursor: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: cursorKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: cursorKey) }
    }

    func resetCursor() {
        cursor = 0
        report = Report()
    }

    func sync(using connection: RingConnectionType, keyHex: String) async {
        phase = .preparing
        report = Report()
        var drainedEvents: [RingEvent] = []

        do {
            if !connection.isAuthenticated {
                try await connection.authenticate(keyHex: keyHex)
            }

            // Mirror the current app-style history setup. Pace no-response writes so a
            // phone/ring with a small BLE transmit queue is not flooded during setup.
            let setup = [RingProtocol.enableEventStream()]
                + RingProtocol.eventCategorySubscriptions()
                + RingProtocol.appParameterSweep()
                + [RingProtocol.enableAllNotifications(), RingProtocol.syncTime(), RingProtocol.dataFlush()]
            for frame in setup {
                connection.write(frame)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            connection.note("Stream prepared; draining from cursor \(cursor)")

            var sequence = 0
            var guardCounter = 0

            while true {
                // A malformed cursor could otherwise spin forever.
                guardCounter += 1
                if guardCounter > 5000 {
                    connection.note("Stopping: batch limit reached without the ring reporting completion")
                    break
                }

                let batch = try await connection.fetchEventBatch(
                    from: cursor,
                    batchSize: batchSize,
                    startingSequence: sequence
                )
                sequence += batch.events.count
                report.batches += 1
                report.eventsReceived += batch.events.count
                report.bytesLeft = batch.summary.bytesLeft

                // The capture is the source of truth for this experimental path. It must be
                // durable before the bookmark moves or a crash can skip a whole batch. Guarded
                // by RingSyncDurabilityTests: a batch that fails to save must never reach the
                // acknowledgement below.
                try await ingest(batch.events)
                drainedEvents.append(contentsOf: batch.events)
                phase = .draining(events: report.eventsReceived, bytesLeft: batch.summary.bytesLeft)

                // Advance past the newest event we actually decoded, then tell the ring.
                if let newest = batch.events.map(\.rawTimestamp).max() {
                    cursor = newest &+ 1
                    _ = try await connection.send(
                        RingProtocol.acknowledge(cursor: cursor),
                        expecting: { RingProtocol.eventSummary(in: $0) != nil },
                        timeout: 10,
                        describedAs: "cursor acknowledgement"
                    )
                }

                // The summary packet is the only reliable terminator — silence is not.
                if batch.summary.isComplete {
                    report.finishedCleanly = true
                    break
                }
                if batch.events.isEmpty {
                    connection.note("Ring reported \(batch.summary.bytesLeft) bytes left but sent no events; stopping")
                    break
                }
            }

            summariseTimes(in: drainedEvents)
            phase = .finished
        } catch {
            summariseTimes(in: drainedEvents)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection.note("Sync failed: \(message)")
            phase = .failed(message)
        }
    }

    private func ingest(_ events: [RingEvent]) async throws {
        try await store.appendAndSave(events)
        for event in events {
            let kind = RingEventDecoder.kind(for: event.tag)
            report.countsByKind[kind.label, default: 0] += 1
        }
    }

    private func summariseTimes(in events: [RingEvent]) {
        for (event, date) in zip(events, RingEventClock.dates(for: events)) {
            guard let date else { continue }
            report.firstEvent = min(report.firstEvent ?? date, date)
            report.lastEvent = max(report.lastEvent ?? date, date)
            report.samples += RingEventDecoder.samples(from: event, at: date).count
        }
    }

    func exportCapture() async -> URL? {
        await store.exportURL()
    }

    func clearCapture() async {
        await store.reset()
        report = Report()
    }
}

/// Raw event capture, kept separately from the health database. This is the material that
/// makes the remaining tags mappable: pair a capture with the same day's cloud data and the
/// unknown bodies stop being unknown.
actor RingCaptureStore {
    private let fileURL: URL
    private var events: [RingEvent] = []
    private var loaded = false

    init(filename: String = "ring-capture.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OpenRing", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(filename)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = (try? decoder.decode([RingEvent].self, from: data)) ?? []
    }

    /// Atomically checkpoints a batch. The in-memory copy is only replaced after disk has
    /// accepted it, matching the cursor ordering in `RingSyncService`.
    func appendAndSave(_ newEvents: [RingEvent]) throws {
        loadIfNeeded()
        var updated = events
        updated.append(contentsOf: newEvents)
        // A long drain can be tens of thousands of events; cap the capture so it stays
        // exportable and does not grow without bound.
        if updated.count > 200_000 {
            updated.removeFirst(updated.count - 200_000)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
        events = updated
    }

    func save() throws {
        loadIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: fileURL, options: .atomic)
    }

    func exportURL() -> URL? {
        try? save()
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    func reset() {
        events.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    var count: Int {
        loadIfNeeded()
        return events.count
    }
}
