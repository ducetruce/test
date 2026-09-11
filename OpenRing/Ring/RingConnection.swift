import Foundation
import CoreBluetooth

/// BLE transport for the ring: scan, connect, authenticate, and exchange frames.
///
/// The central manager runs on the main queue, so every delegate callback and every
/// `@Published` mutation happens on the main thread without extra hopping. The class is
/// `@MainActor` to make that guarantee explicit; the delegate conformances are marked
/// `@preconcurrency` because CoreBluetooth's protocols predate actor isolation.
@MainActor
final class RingConnection: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case bluetoothUnavailable(String)
        case scanning
        case connecting
        case discovering
        case ready
        case authenticated
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .bluetoothUnavailable(let reason): return reason
            case .scanning: return "Scanning…"
            case .connecting: return "Connecting…"
            case .discovering: return "Discovering services…"
            case .ready: return "Connected"
            case .authenticated: return "Authenticated"
            case .failed(let reason): return reason
            }
        }
    }

    enum RingError: LocalizedError {
        case bluetoothUnavailable(String)
        case notConnected
        case timedOut(String)
        case badKey
        case authenticationRejected
        case unauthorised
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable(let reason): return reason
            case .notConnected: return "Not connected to a ring."
            case .timedOut(let what): return "The ring did not answer: \(what)."
            case .badKey: return "The auth key must be exactly 16 bytes (32 hex characters)."
            case .authenticationRejected: return "The ring rejected the auth key."
            case .unauthorised: return "The ring refused the command — this connection is not authenticated."
            case .protocolError(let detail): return "Unexpected response: \(detail)"
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        var direction: Direction
        var text: String

        enum Direction: String { case out = "→", incoming = "←", info = "•" }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var discovered: [CBPeripheral] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var isAuthenticated = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var reader = RingProtocol.FrameReader()

    /// One outstanding request at a time; the ring answers in order.
    private var pendingMatcher: ((RingProtocol.Frame) -> Bool)?
    private var pendingContinuation: CheckedContinuation<RingProtocol.Frame, Error>?
    /// Frames that arrive while a drain is running are appended here instead of matched.
    private var frameSink: ((RingProtocol.Frame) -> Void)?

    private var connectContinuation: CheckedContinuation<Void, Error>?

    private let serviceUUID = CBUUID(string: RingProtocol.serviceUUID)
    private let writeUUID = CBUUID(string: RingProtocol.writeCharacteristicUUID)
    private let notifyUUID = CBUUID(string: RingProtocol.notifyCharacteristicUUID)

    // MARK: - Lifecycle

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        start()
        guard let central, central.state == .poweredOn else { return }
        discovered.removeAll()
        state = .scanning
        note("Scanning for rings advertising \(serviceUUID.uuidString)")
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func stopScanning() {
        central?.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(to peripheral: CBPeripheral) async throws {
        guard let central else { throw RingError.bluetoothUnavailable("Bluetooth is not ready.") }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        reader.reset()
        state = .connecting
        note("Connecting to \(peripheral.name ?? peripheral.identifier.uuidString)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            central.connect(peripheral)
        }
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        reader.reset()
        isAuthenticated = false
        state = .idle
    }

    // MARK: - Requests

    @discardableResult
    func send(
        _ frame: RingProtocol.Frame,
        expecting matcher: @escaping (RingProtocol.Frame) -> Bool,
        timeout: TimeInterval = 8,
        describedAs description: String
    ) async throws -> RingProtocol.Frame {
        guard let peripheral, let characteristic = writeCharacteristic else { throw RingError.notConnected }
        note(frame.hexDump, direction: .out)

        return try await withThrowingTaskGroup(of: RingProtocol.Frame.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingMatcher = matcher
                    self.pendingContinuation = continuation
                    peripheral.writeValue(frame.encoded, for: characteristic, type: .withoutResponse)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RingError.timedOut(description)
            }
            guard let result = try await group.next() else { throw RingError.timedOut(description) }
            group.cancelAll()
            return result
        }
    }

    /// Fire-and-forget: some setup commands are not acknowledged.
    func write(_ frame: RingProtocol.Frame) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        note(frame.hexDump, direction: .out)
        peripheral.writeValue(frame.encoded, for: characteristic, type: .withoutResponse)
    }

    // MARK: - Authentication

    func authenticate(keyHex: String) async throws {
        guard let key = RingProtocol.hexToBytes(keyHex), key.count == 16 else { throw RingError.badKey }

        let nonceFrame = try await send(
            RingProtocol.requestNonce(),
            expecting: { $0.extendedKind == .nonceReply },
            describedAs: "nonce request"
        )
        guard let nonce = RingProtocol.nonce(in: nonceFrame) else {
            throw RingError.protocolError(nonceFrame.hexDump)
        }
        guard let encrypted = RingProtocol.encryptNonce(nonce, key: key) else { throw RingError.badKey }

        let result = try await send(
            RingProtocol.authenticate(encryptedNonce: encrypted),
            expecting: { $0.extendedKind == .authResult },
            describedAs: "authentication"
        )
        guard RingProtocol.authSucceeded(in: result) == true else { throw RingError.authenticationRejected }

        isAuthenticated = true
        state = .authenticated
        note("Authenticated")
    }

    /// Installs a key on a **factory-reset** ring, claiming it.
    ///
    /// This is one-way: a ring that already carries a key will not take another, and
    /// re-onboarding with the official Oura app replaces this key and locks the app out
    /// until the ring is factory reset again.
    func installAuthKey(keyHex: String) async throws {
        guard let key = RingProtocol.hexToBytes(keyHex), key.count == 16 else { throw RingError.badKey }
        let reply = try await send(
            RingProtocol.setAuthKey(key),
            expecting: { RingProtocol.keyInstallSucceeded(in: $0) != nil },
            describedAs: "key installation"
        )
        guard RingProtocol.keyInstallSucceeded(in: reply) == true else {
            throw RingError.protocolError("the ring refused the key — it is probably not factory reset")
        }
        note("Auth key installed")
    }

    // MARK: - Event drain

    /// Collects event frames until the ring sends its `0x11` summary.
    func fetchEventBatch(
        from cursor: UInt32,
        batchSize: UInt8,
        timeout: TimeInterval = 30,
        startingSequence: Int
    ) async throws -> (events: [RingEvent], summary: RingProtocol.EventSummary) {
        guard let peripheral, let characteristic = writeCharacteristic else { throw RingError.notConnected }

        var collected: [RingEvent] = []
        var sequence = startingSequence

        let summary = try await withThrowingTaskGroup(of: RingProtocol.EventSummary.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RingProtocol.EventSummary, Error>) in
                    var finished = false
                    self.frameSink = { frame in
                        guard !finished else { return }
                        if RingProtocol.isUnauthorised(frame) {
                            finished = true
                            self.frameSink = nil
                            continuation.resume(throwing: RingError.unauthorised)
                            return
                        }
                        if let summary = RingProtocol.eventSummary(in: frame) {
                            finished = true
                            self.frameSink = nil
                            continuation.resume(returning: summary)
                            return
                        }
                        if let event = RingEvent.parse(frame: frame, sequence: sequence) {
                            sequence += 1
                            collected.append(event)
                        }
                    }
                    let request = RingProtocol.getEvents(from: cursor, maxEvents: batchSize)
                    self.note(request.hexDump, direction: .out)
                    peripheral.writeValue(request.encoded, for: characteristic, type: .withoutResponse)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RingError.timedOut("event batch")
            }
            guard let result = try await group.next() else { throw RingError.timedOut("event batch") }
            group.cancelAll()
            return result
        }

        frameSink = nil
        return (collected, summary)
    }

    // MARK: - Logging

    func note(_ text: String, direction: LogEntry.Direction = .info) {
        log.append(LogEntry(direction: direction, text: text))
        // The diagnostics view only ever shows the tail; keep memory bounded on long syncs.
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log.removeAll() }
}

// MARK: - CBCentralManagerDelegate

extension RingConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            note("Bluetooth ready")
            if case .bluetoothUnavailable = state { state = .idle }
        case .poweredOff:
            state = .bluetoothUnavailable("Bluetooth is switched off.")
        case .unauthorized:
            state = .bluetoothUnavailable("OpenRing is not allowed to use Bluetooth. Enable it in Settings.")
        case .unsupported:
            state = .bluetoothUnavailable("This device has no supported Bluetooth radio.")
        default:
            state = .bluetoothUnavailable("Bluetooth is unavailable.")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !discovered.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        discovered.append(peripheral)
        note("Found \(peripheral.name ?? peripheral.identifier.uuidString) at \(RSSI) dBm")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering
        note("Connected, discovering services")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Connection failed."
        state = .failed(message)
        connectContinuation?.resume(throwing: RingError.protocolError(message))
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        note("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        isAuthenticated = false
        state = .idle
        // Fail anything still waiting rather than leaving it hung until timeout.
        pendingContinuation?.resume(throwing: RingError.notConnected)
        pendingContinuation = nil
        pendingMatcher = nil
        frameSink = nil
    }
}

// MARK: - CBPeripheralDelegate

extension RingConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            let message = "The ring did not expose service \(serviceUUID.uuidString)."
            state = .failed(message)
            connectContinuation?.resume(throwing: RingError.protocolError(message))
            connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
            if characteristic.uuid == notifyUUID {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        guard writeCharacteristic != nil, notifyCharacteristic != nil else {
            let message = "The ring is missing the expected characteristics."
            state = .failed(message)
            connectContinuation?.resume(throwing: RingError.protocolError(message))
            connectContinuation = nil
            return
        }
        state = .ready
        note("Ready (MTU \(peripheral.maximumWriteValueLength(for: .withoutResponse)))")
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        for frame in reader.append(data) {
            note(frame.hexDump, direction: .incoming)
            if let sink = frameSink {
                sink(frame)
                continue
            }
            if let matcher = pendingMatcher, matcher(frame) {
                pendingMatcher = nil
                let continuation = pendingContinuation
                pendingContinuation = nil
                continuation?.resume(returning: frame)
            }
        }
    }
}
