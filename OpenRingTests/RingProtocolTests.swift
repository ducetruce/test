import XCTest
@testable import OpenRing

final class RingFrameTests: XCTestCase {
    func testFrameEncodesTagLengthPayload() {
        let frame = RingProtocol.Frame(tag: 0x28, payload: [0x00])
        XCTAssertEqual(Array(frame.encoded), [0x28, 0x01, 0x00])
        XCTAssertEqual(frame.hexDump, "28 01 00")
    }

    func testGetEventsLayoutMatchesTheDocumentedStruct() {
        // start_timestamp u32 LE | max_events u8 | flags i32 LE
        let frame = RingProtocol.getEvents(from: 0x0102_0304, maxEvents: 64, flags: -1)
        XCTAssertEqual(frame.tag, 0x10)
        XCTAssertEqual(frame.payload.count, 9)
        XCTAssertEqual(Array(frame.payload[0..<4]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(frame.payload[4], 64)
        XCTAssertEqual(Array(frame.payload[5..<9]), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testAcknowledgementAsksForZeroEvents() {
        XCTAssertEqual(RingProtocol.acknowledge(cursor: 7).payload[4], 0)
    }

    func testReaderReassemblesFramesSplitAcrossNotifications() {
        var reader = RingProtocol.FrameReader()
        XCTAssertTrue(reader.append(Data([0x11, 0x08, 0x08, 0x00])).isEmpty)
        let frames = reader.append(Data([0x9E, 0x0E, 0x00, 0x00, 0x03, 0x00]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].tag, 0x11)
        XCTAssertEqual(reader.pendingByteCount, 0)
    }

    func testReaderSplitsBackToBackFrames() {
        var reader = RingProtocol.FrameReader()
        let frames = reader.append(Data([0x25, 0x01, 0x00, 0x28, 0x01, 0x00]))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].tag, 0x25)
        XCTAssertEqual(frames[1].tag, 0x28)
    }

    /// The worked example from the protocol notes: 8 events, 3742 bytes still queued.
    func testEventSummaryDecodesTheDocumentedExample() {
        var reader = RingProtocol.FrameReader()
        let frames = reader.append(Data([0x11, 0x08, 0x08, 0x00, 0x9E, 0x0E, 0x00, 0x00, 0x03, 0x00]))
        let summary = RingProtocol.eventSummary(in: try! XCTUnwrap(frames.first))
        XCTAssertEqual(summary?.eventCount, 8)
        XCTAssertEqual(summary?.bytesLeft, 3742)
        XCTAssertEqual(summary?.isComplete, false)
    }

    func testNonceAndAuthResultParsing() {
        let nonceFrame = RingProtocol.Frame(tag: 0x2F, payload: [0x2C] + Array(repeating: 0xAB, count: 15))
        XCTAssertEqual(RingProtocol.nonce(in: nonceFrame)?.count, 15)

        let ok = RingProtocol.Frame(tag: 0x2F, payload: [0x2E, 0x00])
        let rejected = RingProtocol.Frame(tag: 0x2F, payload: [0x2E, 0x01])
        XCTAssertEqual(RingProtocol.authSucceeded(in: ok), true)
        XCTAssertEqual(RingProtocol.authSucceeded(in: rejected), false)

        let denied = RingProtocol.Frame(tag: 0x2F, payload: [0x2F, 0x01])
        XCTAssertTrue(RingProtocol.isUnauthorised(denied))
    }

    func testNonceEncryptionProducesOneAESBlock() {
        let key = [UInt8](repeating: 0x11, count: 16)
        let nonce = [UInt8](repeating: 0x22, count: 15)
        let encrypted = RingProtocol.encryptNonce(nonce, key: key)
        XCTAssertEqual(encrypted?.count, 16)
        // ECB is deterministic, which is what makes the challenge verifiable by the ring.
        XCTAssertEqual(encrypted, RingProtocol.encryptNonce(nonce, key: key))
        XCTAssertNotEqual(encrypted, RingProtocol.encryptNonce(nonce, key: [UInt8](repeating: 0x33, count: 16)))
    }

    func testRejectsKeysThatAreNotSixteenBytes() {
        XCTAssertNil(RingProtocol.encryptNonce([0x00], key: [UInt8](repeating: 0, count: 8)))
    }

    func testHexParsing() {
        XCTAssertEqual(RingProtocol.hexToBytes("00ff10"), [0x00, 0xFF, 0x10])
        XCTAssertEqual(RingProtocol.hexToBytes("00 FF 10"), [0x00, 0xFF, 0x10])
        XCTAssertNil(RingProtocol.hexToBytes("abc"))
    }
}

final class RingEventTests: XCTestCase {
    func testEventTakesItsTimestampFromTheFirstFourBytes() {
        // 0x66000000 = 1711276032, comfortably a Unix second count.
        let frame = RingProtocol.Frame(tag: 0x46, payload: [0x00, 0x00, 0x00, 0x66, 0xAA, 0xBB])
        let event = try? XCTUnwrap(RingEvent.parse(frame: frame, sequence: 0))
        XCTAssertEqual(event?.rawTimestamp, 0x6600_0000)
        XCTAssertEqual(event?.body, [0xAA, 0xBB])
        XCTAssertEqual(event?.timeBase, .unixSeconds)
    }

    func testNonEventFramesAreRejected() {
        XCTAssertNil(RingEvent.parse(frame: RingProtocol.Frame(tag: 0x11, payload: [0, 0, 0, 0]), sequence: 0))
    }

    func testMETScalingHasItsKneeAt128() {
        XCTAssertEqual(RingEventDecoder.met(0), 0, accuracy: 0.0001)
        XCTAssertEqual(RingEventDecoder.met(10), 1.0, accuracy: 0.0001)
        XCTAssertEqual(RingEventDecoder.met(128), 12.8, accuracy: 0.0001)
        XCTAssertEqual(RingEventDecoder.met(138), 14.8, accuracy: 0.0001)
    }

    func testTemperatureIsHundredthsOfADegree() {
        XCTAssertEqual(RingEventDecoder.temperature(3512), 35.12, accuracy: 0.0001)
        XCTAssertEqual(RingEventDecoder.temperature(-25), -0.25, accuracy: 0.0001)
    }

    func testGreenLEDInterBeatIntervalUnpacking() {
        let decoded = RingEventDecoder.greenLEDInterBeatInterval(0x64, 0x0A)
        XCTAssertEqual(decoded.milliseconds, (0x0A & 7) | (0x64 << 3))
        XCTAssertEqual(decoded.quality, (0x0A >> 3) & 3)
    }

    func testBatchTimestampsEndAtTheEventTime() {
        let end = Date(timeIntervalSince1970: 1_000_000)
        let times = RingEventDecoder.batchTimestamps(endingAt: end, count: 3, interval: 30)
        XCTAssertEqual(times.count, 3)
        XCTAssertEqual(times.last, end)
        XCTAssertEqual(times.first, end.addingTimeInterval(-60))
    }

    func testTemperatureEventDecodesToPlausibleSamples() {
        var body: [UInt8] = []
        for raw in [Int16(3510), Int16(3515), Int16(9999)] {
            body.append(UInt8(UInt16(bitPattern: raw) & 0xFF))
            body.append(UInt8(UInt16(bitPattern: raw) >> 8))
        }
        let frame = RingProtocol.Frame(tag: 0x46, payload: [0x00, 0x00, 0x00, 0x66] + body)
        let event = RingEvent.parse(frame: frame, sequence: 0)!
        let samples = RingEventDecoder.samples(from: event)
        // 99.99 °C is a decode error, not a skin temperature, and is dropped.
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.first?.value ?? 0, 35.10, accuracy: 0.001)
    }

    func testTagsMapToFamilies() {
        XCTAssertEqual(RingEventDecoder.kind(for: 0x41), .ringStart)
        XCTAssertEqual(RingEventDecoder.kind(for: 0x5D), .hrvSummary)
        XCTAssertEqual(RingEventDecoder.kind(for: 0x6F), .spo2)
        XCTAssertEqual(RingEventDecoder.kind(for: 0x51), .activityMET)
        XCTAssertEqual(RingEventDecoder.kind(for: 0x02), .unknown)
    }
}
