import Foundation
import CommonCrypto

/// Wire format for the Oura Gen 3/4/5 BLE protocol.
///
/// The protocol facts here (UUIDs, framing, opcodes, the nonce/AES challenge) come from the
/// public reverse-engineering write-ups in `Th0rgal/open_oura`'s `docs/`. That repository
/// ships no licence, so nothing is copied from it — this is an independent Swift
/// implementation of the documented format.
enum RingProtocol {

    // MARK: - GATT

    static let serviceUUID = "98ED0001-A541-11E4-B6A0-0002A5D5C51B"
    static let writeCharacteristicUUID = "98ED0002-A541-11E4-B6A0-0002A5D5C51B"
    static let notifyCharacteristicUUID = "98ED0003-A541-11E4-B6A0-0002A5D5C51B"

    /// The ring negotiates a 203-byte MTU; frames larger than one notification arrive split
    /// and are reassembled by `FrameReader`.
    static let expectedMTU = 203

    // MARK: - Opcodes

    enum Opcode: UInt8 {
        case firmwareInfo = 0x08
        case battery = 0x0C
        case getEvents = 0x10
        case eventSummary = 0x11
        case syncTime = 0x12
        case bleMode = 0x16
        case productInfo = 0x18
        case notifications = 0x1C
        case userInfo = 0x20
        case setAuthKey = 0x24
        case setAuthKeyReply = 0x25
        case dataFlush = 0x28
        case extended = 0x2F
        case ringMode = 0x31
    }

    /// Sub-commands carried in the first payload byte of an `extended` (0x2F) frame.
    enum Extended: UInt8 {
        case requestNonce = 0x2B
        case nonceReply = 0x2C
        case authenticate = 0x2D
        case authResult = 0x2E
        case error = 0x2F
    }

    // MARK: - Frames

    /// `tag | length | payload`, where length counts payload bytes only.
    struct Frame: Equatable {
        var tag: UInt8
        var payload: [UInt8]

        var encoded: Data {
            precondition(payload.count <= 0xFF, "payload does not fit in a one-byte length")
            return Data([tag, UInt8(payload.count)] + payload)
        }

        /// For 0x2F frames, the sub-command in the first payload byte.
        var extendedKind: Extended? {
            guard tag == Opcode.extended.rawValue, let first = payload.first else { return nil }
            return Extended(rawValue: first)
        }

        var hexDump: String {
            ([tag, UInt8(payload.count)] + payload)
                .map { String(format: "%02x", $0) }
                .joined(separator: " ")
        }
    }

    /// Accumulates BLE notification chunks and yields whole frames.
    struct FrameReader {
        private var buffer: [UInt8] = []

        mutating func append(_ data: Data) -> [Frame] {
            buffer.append(contentsOf: data)
            var frames: [Frame] = []
            while buffer.count >= 2 {
                let length = Int(buffer[1])
                let total = 2 + length
                guard buffer.count >= total else { break }
                frames.append(Frame(tag: buffer[0], payload: Array(buffer[2..<total])))
                buffer.removeFirst(total)
            }
            return frames
        }

        mutating func reset() { buffer.removeAll() }

        var pendingByteCount: Int { buffer.count }
    }

    // MARK: - Requests

    static func firmwareInfo() -> Frame { Frame(tag: Opcode.firmwareInfo.rawValue, payload: []) }

    static func battery() -> Frame { Frame(tag: Opcode.battery.rawValue, payload: []) }

    /// Releases events the ring is still holding in its buffer before a drain.
    static func dataFlush() -> Frame { Frame(tag: Opcode.dataFlush.rawValue, payload: [0x00]) }

    /// Puts the link into event-stream mode.
    static func enableEventStream() -> Frame { Frame(tag: Opcode.bleMode.rawValue, payload: [0x02]) }

    static func enableAllNotifications() -> Frame {
        Frame(tag: Opcode.notifications.rawValue, payload: [0x3F])
    }

    /// `start_timestamp: u32 LE | max_events: u8 | flags: i32 LE`.
    ///
    /// `maxEvents: 0` with `flags: -1` is the acknowledgement form: it advances the ring's
    /// cursor without asking for more data.
    static func getEvents(from cursor: UInt32, maxEvents: UInt8 = 64, flags: Int32 = -1) -> Frame {
        var payload: [UInt8] = []
        payload.append(contentsOf: littleEndian(cursor))
        payload.append(maxEvents)
        payload.append(contentsOf: littleEndian(UInt32(bitPattern: flags)))
        return Frame(tag: Opcode.getEvents.rawValue, payload: payload)
    }

    static func acknowledge(cursor: UInt32) -> Frame {
        getEvents(from: cursor, maxEvents: 0, flags: -1)
    }

    /// `token | unix/256 as u24 LE | 00 00 00 00 | f6`.
    static func syncTime(_ date: Date = Date(), token: UInt8 = 0x09) -> Frame {
        let coarse = UInt32(max(0, date.timeIntervalSince1970) / 256)
        let bytes = littleEndian(coarse)
        return Frame(
            tag: Opcode.syncTime.rawValue,
            payload: [token, bytes[0], bytes[1], bytes[2], 0x00, 0x00, 0x00, 0x00, 0xF6]
        )
    }

    static func requestNonce() -> Frame {
        Frame(tag: Opcode.extended.rawValue, payload: [Extended.requestNonce.rawValue])
    }

    static func authenticate(encryptedNonce: [UInt8]) -> Frame {
        Frame(tag: Opcode.extended.rawValue, payload: [Extended.authenticate.rawValue] + encryptedNonce)
    }

    /// Only accepted by a factory-reset ring — installs a key you generate yourself.
    static func setAuthKey(_ key: [UInt8]) -> Frame {
        Frame(tag: Opcode.setAuthKey.rawValue, payload: key)
    }

    // MARK: - Responses

    /// Reply to `requestNonce`: `2C` followed by a 15-byte nonce.
    static func nonce(in frame: Frame) -> [UInt8]? {
        guard frame.extendedKind == .nonceReply, frame.payload.count >= 16 else { return nil }
        return Array(frame.payload[1..<16])
    }

    /// Reply to `authenticate`: `2E 00` on success, `2E 01` on failure.
    static func authSucceeded(in frame: Frame) -> Bool? {
        guard frame.extendedKind == .authResult, frame.payload.count >= 2 else { return nil }
        return frame.payload[1] == 0x00
    }

    /// The ring answers auth-gated commands with `2F 02 2F 01` when it has a key installed
    /// and the connection has not authenticated.
    static func isUnauthorised(_ frame: Frame) -> Bool {
        frame.extendedKind == .error && frame.payload.count >= 2 && frame.payload[1] == 0x01
    }

    /// Terminator for an event batch: how many events were sent and how much is still queued.
    struct EventSummary: Equatable {
        var eventCount: Int
        var sleepAnalysisProgress: Int
        var bytesLeft: UInt32

        var isComplete: Bool { bytesLeft == 0 }
    }

    static func eventSummary(in frame: Frame) -> EventSummary? {
        guard frame.tag == Opcode.eventSummary.rawValue, let count = frame.payload.first else { return nil }
        let progress = frame.payload.count > 1 ? Int(frame.payload[1]) : 0
        var bytesLeft: UInt32 = 0
        if frame.payload.count >= 6 {
            bytesLeft = readUInt32(frame.payload, at: 2)
        }
        return EventSummary(eventCount: Int(count), sleepAnalysisProgress: progress, bytesLeft: bytesLeft)
    }

    // MARK: - Crypto

    /// The challenge is the 15-byte nonce encrypted with AES-128-ECB and PKCS#7 padding,
    /// which turns it into exactly one 16-byte block.
    static func encryptNonce(_ nonce: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var output = [UInt8](repeating: 0, count: nonce.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
            key, key.count,
            nil,
            nonce, nonce.count,
            &output, output.count,
            &written
        )
        guard status == kCCSuccess, written >= kCCBlockSizeAES128 else { return nil }
        return Array(output[0..<kCCBlockSizeAES128])
    }

    // MARK: - Bytes

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard bytes.count >= offset + 4 else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard bytes.count >= offset + 2 else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func readInt16(_ bytes: [UInt8], at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(bytes, at: offset))
    }

    static func hexToBytes(_ text: String) -> [UInt8]? {
        let cleaned = text.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
