import Foundation

/// One record from the ring's history-event stream: a tag, a timestamp, and a body whose
/// layout depends on the tag.
struct RingEvent: Codable, Hashable, Identifiable {
    var tag: UInt8
    var rawTimestamp: UInt32
    var body: [UInt8]
    /// Order received — event timestamps are not unique, so this is what makes rows distinct.
    var sequence: Int

    var id: String { "\(sequence)-\(tag)-\(rawTimestamp)" }

    var hexBody: String { body.map { String(format: "%02x", $0) }.joined() }

    /// Event bodies begin with a `u32 LE` timestamp; the epoch is not documented, so this
    /// covers the two plausible readings and reports which one it used.
    enum TimeBase: String, Codable { case unixSeconds, deciseconds, unknown }

    var timeBase: TimeBase {
        if rawTimestamp > 1_000_000_000 { return .unixSeconds }
        if rawTimestamp > 100_000_000 { return .deciseconds }
        return .unknown
    }

    var date: Date? {
        switch timeBase {
        case .unixSeconds: return Date(timeIntervalSince1970: Double(rawTimestamp))
        case .deciseconds: return Date(timeIntervalSince1970: Double(rawTimestamp) / 10)
        case .unknown: return nil
        }
    }

    static func parse(frame: RingProtocol.Frame, sequence: Int) -> RingEvent? {
        guard frame.tag >= 0x41, frame.payload.count >= 4 else { return nil }
        return RingEvent(
            tag: frame.tag,
            rawTimestamp: RingProtocol.readUInt32(frame.payload, at: 0),
            body: Array(frame.payload.dropFirst(4)),
            sequence: sequence
        )
    }
}

/// Which family a tag belongs to.
///
/// The families are documented in `open_oura`'s reversing notes; the per-tag *body layouts*
/// mostly are not, so `RingEventDecoder` only converts the ones with published scaling rules
/// and leaves the rest as captured bytes to be mapped against a known day's cloud data.
enum RingEventKind: String, Codable, CaseIterable {
    case ringStart
    case debug
    case interBeatInterval
    case ppgAmplitude
    case hrvSummary
    case temperature
    case motion
    case spo2
    case sleepStage
    case activityMET
    case scanEnd
    case unknown

    var label: String {
        switch self {
        case .ringStart: return "Ring start"
        case .debug: return "Debug"
        case .interBeatInterval: return "Inter-beat interval"
        case .ppgAmplitude: return "PPG amplitude"
        case .hrvSummary: return "HRV summary"
        case .temperature: return "Temperature"
        case .motion: return "Motion"
        case .spo2: return "Blood oxygen"
        case .sleepStage: return "Sleep stage"
        case .activityMET: return "Activity MET"
        case .scanEnd: return "Scan end"
        case .unknown: return "Unmapped"
        }
    }
}

enum RingEventDecoder {

    /// Documented sampling intervals for batched events, where one event carries N samples
    /// ending at the event timestamp.
    enum Interval {
        static let hrv: TimeInterval = 5 * 60
        static let ambient: TimeInterval = 5 * 60
        static let sleepTemperature: TimeInterval = 30
        static let measurementQuality: TimeInterval = 3 * 60
        static let spo2: TimeInterval = 1
        static let aohr: TimeInterval = 1.92
    }

    static func kind(for tag: UInt8) -> RingEventKind {
        switch tag {
        case 0x41: return .ringStart
        case 0x43: return .debug
        case 0x44, 0x60, 0x6E, 0x71, 0x80: return .interBeatInterval
        case 0x4A, 0x64, 0x68, 0x81: return .ppgAmplitude
        case 0x5D: return .hrvSummary
        case 0x46, 0x69, 0x75: return .temperature
        case 0x47, 0x72: return .motion
        case 0x6F, 0x70, 0x77: return .spo2
        case 0x4B...0x4F, 0x53...0x5A: return .sleepStage
        case 0x50...0x52: return .activityMET
        case 0x83: return .scanEnd
        default: return .unknown
        }
    }

    // MARK: - Documented conversions

    /// Skin temperature is a signed hundredth of a degree Celsius.
    static func temperature(_ raw: Int16) -> Double { Double(raw) / 100 }

    /// MET is byte-packed with a knee at 128: below that each step is 0.1, above it 0.2.
    static func met(_ byte: UInt8) -> Double {
        byte < 128 ? Double(byte) * 0.1 : 12.8 + Double(Int(byte) - 128) * 0.2
    }

    /// Green-LED inter-beat interval (tag 0x80) packs the interval and a quality flag.
    static func greenLEDInterBeatInterval(_ b0: UInt8, _ b1: UInt8) -> (milliseconds: Int, quality: Int) {
        let milliseconds = Int(b1 & 0x07) | (Int(b0) << 3)
        return (milliseconds, Int((b1 >> 3) & 0x03))
    }

    /// Timestamps for a batch of `count` samples ending at `end`, stepping backwards by
    /// `interval` — the documented batching rule.
    static func batchTimestamps(endingAt end: Date, count: Int, interval: TimeInterval) -> [Date] {
        guard count > 0 else { return [] }
        let start = end.addingTimeInterval(-interval * Double(count - 1))
        return (0..<count).map { start.addingTimeInterval(interval * Double($0)) }
    }

    /// Samples this decoder can produce with confidence. Anything not listed here is kept as
    /// raw bytes rather than guessed at.
    static func samples(from event: RingEvent) -> [RingSample] {
        guard let date = event.date else { return [] }
        switch kind(for: event.tag) {
        case .temperature:
            // A run of int16 hundredths-of-a-degree, one every 30 s, ending at the event time.
            let count = event.body.count / 2
            guard count > 0 else { return [] }
            let times = batchTimestamps(endingAt: date, count: count, interval: Interval.sleepTemperature)
            return (0..<count).compactMap { index in
                let value = temperature(RingProtocol.readInt16(event.body, at: index * 2))
                // Skin temperature outside this band is a decode error, not a reading.
                guard value > 10, value < 45, index < times.count else { return nil }
                return RingSample(date: times[index], kind: .temperature, value: value)
            }
        case .activityMET:
            let times = batchTimestamps(endingAt: date, count: event.body.count, interval: 60)
            return zip(times, event.body).map { RingSample(date: $0, kind: .activityMET, value: met($1)) }
        case .interBeatInterval where event.tag == 0x80:
            var samples: [RingSample] = []
            var index = 0
            while index + 1 < event.body.count {
                let decoded = greenLEDInterBeatInterval(event.body[index], event.body[index + 1])
                // Keep only physiologically plausible intervals (30-200 bpm).
                if decoded.milliseconds > 300, decoded.milliseconds < 2000 {
                    samples.append(RingSample(date: date, kind: .interBeatInterval, value: Double(decoded.milliseconds)))
                }
                index += 2
            }
            return samples
        default:
            return []
        }
    }
}

struct RingSample: Codable, Hashable {
    enum Kind: String, Codable { case temperature, activityMET, interBeatInterval }
    var date: Date
    var kind: Kind
    var value: Double
}
