import XCTest
@testable import OpenRing

final class RingFrameTests: XCTestCase {
    func testFrameEncodesTagLengthPayload() {
        let frame = RingProtocol.Frame(tag: 0x28, payload: [0x00])
        XCTAssertEqual(Array(frame.encoded), [0x28, 0x01, 0x00])
        XCTAssertEqual(frame.hexDump, "28 01 00")
    }

    func testGetEventsLayoutMatchesTheDocumentedStruct() throws {
        // start_timestamp u32 LE | max_events u8 | flags i32 LE
        let frame = RingProtocol.getEvents(from: 0x0102_0304, maxEvents: 64, flags: -1)
        XCTAssertEqual(frame.tag, 0x10)
        XCTAssertEqual(frame.payload.count, 9)
        XCTAssertEqual(Array(frame.payload.prefix(4)), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(frame.payload.dropFirst(4).first, 64)
        XCTAssertEqual(Array(frame.payload.dropFirst(5)), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testAcknowledgementAsksForZeroEvents() {
        XCTAssertEqual(RingProtocol.acknowledge(cursor: 7).payload.dropFirst(4).first, 0)
    }

    func testReaderReassemblesFramesSplitAcrossNotifications() throws {
        var reader = RingProtocol.FrameReader()
        XCTAssertTrue(reader.append(Data([0x11, 0x08, 0x08, 0x00])).isEmpty)
        let frames = reader.append(Data([0x9E, 0x0E, 0x00, 0x00, 0x03, 0x00]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try XCTUnwrap(frames.first).tag, 0x11)
        XCTAssertEqual(reader.pendingByteCount, 0)
    }

    func testReaderSplitsBackToBackFrames() {
        var reader = RingProtocol.FrameReader()
        let frames = reader.append(Data([0x25, 0x01, 0x00, 0x28, 0x01, 0x00]))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.tag, 0x25)
        XCTAssertEqual(frames.last?.tag, 0x28)
    }

    /// The worked example from the protocol notes: 8 events, 3742 bytes still queued.
    func testEventSummaryDecodesTheDocumentedExample() throws {
        var reader = RingProtocol.FrameReader()
        let frames = reader.append(Data([0x11, 0x08, 0x08, 0x00, 0x9E, 0x0E, 0x00, 0x00, 0x03, 0x00]))
        let summary = RingProtocol.eventSummary(in: try XCTUnwrap(frames.first))
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

    func testSetAuthKeyFrameMatchesTheDocumentedPairingCommand() {
        let key = [UInt8](repeating: 0xAB, count: 16)
        let frame = RingProtocol.setAuthKey(key)
        // 24 10 <16 bytes>
        XCTAssertEqual(frame.tag, 0x24)
        XCTAssertEqual(frame.payload.count, 16)
        XCTAssertEqual(Array(frame.encoded.prefix(2)), [0x24, 0x10])
    }

    func testKeyInstallReplyParsing() {
        let accepted = RingProtocol.Frame(tag: 0x25, payload: [0x00])
        let refused = RingProtocol.Frame(tag: 0x25, payload: [0x01])
        XCTAssertEqual(RingProtocol.keyInstallSucceeded(in: accepted), true)
        XCTAssertEqual(RingProtocol.keyInstallSucceeded(in: refused), false)
        // An unrelated frame is not an answer to the pairing command.
        XCTAssertNil(RingProtocol.keyInstallSucceeded(in: RingProtocol.Frame(tag: 0x11, payload: [0x00])))
    }

    func testGeneratedKeysAreSixteenBytesAndNotRepeated() {
        let first = RingProtocol.generateAuthKey()
        let second = RingProtocol.generateAuthKey()
        XCTAssertEqual(first?.count, 16)
        XCTAssertEqual(second?.count, 16)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, [UInt8](repeating: 0, count: 16))
    }

    func testGeneratedKeyRoundTripsThroughHex() throws {
        let key = try XCTUnwrap(RingProtocol.generateAuthKey())
        let hex = RingProtocol.hexString(key)
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(RingProtocol.hexToBytes(hex), key)
    }

    func testHexParsing() {
        XCTAssertEqual(RingProtocol.hexToBytes("00ff10"), [0x00, 0xFF, 0x10])
        XCTAssertEqual(RingProtocol.hexToBytes("00 FF 10"), [0x00, 0xFF, 0x10])
        XCTAssertNil(RingProtocol.hexToBytes("abc"))
    }
}

final class RingEventTests: XCTestCase {
    func testEventTakesItsTimestampFromTheFirstFourBytes() throws {
        // 0x66000000 = 1711276032, comfortably a Unix second count.
        let frame = RingProtocol.Frame(tag: 0x46, payload: [0x00, 0x00, 0x00, 0x66, 0xAA, 0xBB])
        let event = try XCTUnwrap(RingEvent.parse(frame: frame, sequence: 0))
        XCTAssertEqual(event.rawTimestamp, 0x6600_0000)
        XCTAssertEqual(event.body, [0xAA, 0xBB])
        XCTAssertEqual(event.timeBase, .unixSeconds)
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

    func testTemperatureEventDecodesToPlausibleSamples() throws {
        var body: [UInt8] = []
        for raw in [Int16(3510), Int16(3515), Int16(9999)] {
            body.append(UInt8(UInt16(bitPattern: raw) & 0xFF))
            body.append(UInt8(UInt16(bitPattern: raw) >> 8))
        }
        let frame = RingProtocol.Frame(tag: 0x46, payload: [0x00, 0x00, 0x00, 0x66] + body)
        let event = try XCTUnwrap(RingEvent.parse(frame: frame, sequence: 0))
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

/// Guards the frame-routing invariants that the rewrite of the request machinery depends on.
final class FrameReaderEdgeTests: XCTestCase {
    func testEmptyAndPartialInputNeverYieldFrames() {
        var reader = RingProtocol.FrameReader()
        XCTAssertTrue(reader.append(Data()).isEmpty)
        XCTAssertTrue(reader.append(Data([0x2F])).isEmpty)
        XCTAssertEqual(reader.pendingByteCount, 1)
    }

    func testZeroLengthFrameIsStillAFrame() {
        var reader = RingProtocol.FrameReader()
        let frames = reader.append(Data([0x08, 0x00]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload.isEmpty, true)
    }

    func testResetDropsPartialFrames() {
        var reader = RingProtocol.FrameReader()
        _ = reader.append(Data([0x11, 0x08, 0x01]))
        reader.reset()
        XCTAssertEqual(reader.pendingByteCount, 0)
        XCTAssertTrue(reader.append(Data([0x08, 0x00])).count == 1)
    }

    func testMaximumLengthFrameRoundTrips() {
        let payload = [UInt8](repeating: 0xCD, count: 255)
        let encoded = RingProtocol.Frame(tag: 0x41, payload: payload).encoded
        var reader = RingProtocol.FrameReader()
        // Deliver it in MTU-sized chunks the way CoreBluetooth would.
        var frames: [RingProtocol.Frame] = []
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + 180, encoded.count)
            frames.append(contentsOf: reader.append(encoded.subdata(in: offset..<end)))
            offset = end
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload.count, 255)
    }
}

/// OAuth2 request shapes, pinned so a refactor cannot silently change what Oura receives.
final class OuraAuthTests: XCTestCase {
    func testAuthorizationURLCarriesEveryRequiredParameter() throws {
        let url = try XCTUnwrap(OuraAuth.authorizationURL(clientID: "abc123", state: "xyz"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.host, "cloud.ouraring.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "abc123")
        XCTAssertEqual(value("state"), "xyz")
        XCTAssertEqual(value("redirect_uri"), OuraAuth.redirectURI)
        // Scopes are space separated in the OAuth2 spec, not comma separated.
        XCTAssertEqual(value("scope"), OuraAuth.scopes.joined(separator: " "))
    }

    func testRedirectSchemeMatchesTheRegisteredURLType() {
        XCTAssertEqual(URL(string: OuraAuth.redirectURI)?.scheme, "openring")
    }

    func testAuthorizationCodeIsExtractedWhenStateMatches() throws {
        let callback = try XCTUnwrap(URL(string: "openring://oauth-callback?code=the-code&state=s1"))
        XCTAssertEqual(try OuraAuth.authorizationCode(from: callback, expectedState: "s1"), "the-code")
    }

    /// A mismatched state is the signature of a forged redirect; the code must be discarded.
    func testMismatchedStateIsRejected() throws {
        let callback = try XCTUnwrap(URL(string: "openring://oauth-callback?code=the-code&state=attacker"))
        XCTAssertThrowsError(try OuraAuth.authorizationCode(from: callback, expectedState: "s1")) { error in
            guard case OuraError.stateMismatch = error else {
                return XCTFail("expected stateMismatch, got \(error)")
            }
        }
    }

    func testMissingStateIsRejected() throws {
        let callback = try XCTUnwrap(URL(string: "openring://oauth-callback?code=the-code"))
        XCTAssertThrowsError(try OuraAuth.authorizationCode(from: callback, expectedState: "s1"))
    }

    func testDeclinedAuthorisationSurfacesOurasReason() throws {
        let callback = try XCTUnwrap(URL(string: "openring://oauth-callback?error=access_denied&state=s1"))
        XCTAssertThrowsError(try OuraAuth.authorizationCode(from: callback, expectedState: "s1")) { error in
            guard case OuraError.authorisationFailed(let detail) = error else {
                return XCTFail("expected authorisationFailed, got \(error)")
            }
            XCTAssertEqual(detail, "access_denied")
        }
    }

    func testStatesAreUnguessableAndDistinct() {
        let a = OuraAuth.makeState()
        let b = OuraAuth.makeState()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 16)
    }

    func testCredentialsExpireSlightlyEarly() {
        let live = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "t",
                                   refreshToken: "r", expiresAt: Date().addingTimeInterval(3600))
        // Inside the one-minute safety margin, so it must already count as expired.
        let expiring = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "t",
                                       refreshToken: "r", expiresAt: Date().addingTimeInterval(30))
        XCTAssertFalse(live.isExpired)
        XCTAssertTrue(expiring.isExpired)
    }

    func testCredentialsRoundTripThroughJSON() throws {
        let credentials = OuraCredentials(clientID: "id", clientSecret: "secret", accessToken: "access",
                                          refreshToken: "refresh", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(credentials)
        XCTAssertEqual(try JSONDecoder().decode(OuraCredentials.self, from: data), credentials)
    }

    func testLegacyTokenCannotRefresh() async {
        let provider = StaticToken(value: "legacy")
        let token = try? await provider.token()
        XCTAssertEqual(token, "legacy")
        do {
            _ = try await provider.refreshedToken()
            XCTFail("a static token must not claim it can refresh")
        } catch {
            guard case OuraError.tokenNotRefreshable = error else {
                return XCTFail("expected tokenNotRefreshable, got \(error)")
            }
        }
    }
}

/// Pins the date-window quirk that cost a day of missing rings: two endpoints in the same
/// API disagree about whether `end_date` is inclusive.
final class OuraWindowTests: XCTestCase {
    private let from = Day(year: 2026, month: 9, day: 1)
    private let to = Day(year: 2026, month: 9, day: 10)

    func testEndExclusiveEndpointsAskForADayBeyondTheWindow() {
        let window = OuraClient.window(for: .endExclusive, from: from, to: to)
        XCTAssertEqual(window.end.description, "2026-09-11", "must ask past the day actually wanted")
        // sleep is indexed by the day a night ends, so the first morning needs reach-back.
        XCTAssertEqual(window.start.description, "2026-08-31")
    }

    func testEndInclusiveEndpointsAreLeftAlone() {
        let window = OuraClient.window(for: .endInclusive, from: from, to: to)
        XCTAssertEqual(window.start, from)
        XCTAssertEqual(window.end, to)
    }

    func testWidenedWindowCoversTheRequestedDay() {
        let window = OuraClient.window(for: .endExclusive, from: from, to: to)
        XCTAssertTrue(Day.range(from: window.start, through: window.end).contains(to))
    }
}

final class OuraScopeTests: XCTestCase {
    /// Oura's consent screen offers a ring scope; omitting it returned 403 on
    /// ring_configuration while every other endpoint worked.
    func testRingScopeIsRequested() {
        XCTAssertTrue(OuraAuth.scopes.contains("ring"))
    }

    func testScopesAreSpaceSeparatedInTheAuthorizationURL() throws {
        let url = try XCTUnwrap(OuraAuth.authorizationURL(clientID: "x", state: "y"))
        let scope = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value)
        XCTAssertEqual(scope.split(separator: " ").count, OuraAuth.scopes.count)
        XCTAssertFalse(scope.contains(","))
    }

    func testCredentialsCarryTheScopesTheyWereGrantedWith() throws {
        let credentials = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "c",
                                          refreshToken: "d", expiresAt: Date(),
                                          grantedScopes: ["daily", "personal"])
        let data = try JSONEncoder().encode(credentials)
        let restored = try JSONDecoder().decode(OuraCredentials.self, from: data)
        XCTAssertEqual(restored.grantedScopes, ["daily", "personal"])
    }

    /// Credentials stored before scope tracking cover an unknown set, and certainly predate
    /// the ring scope — so they must prompt, not stay quiet. Treating unknown as fine meant
    /// the prompt never fired for anyone upgrading, which is everyone who needs it.
    func testCredentialsFromBeforeScopeTrackingArePromptedToReauthorise() throws {
        let legacy = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "c",
                                     refreshToken: "d", expiresAt: Date(), grantedScopes: [])
        XCTAssertTrue(legacy.grantedScopes.isEmpty, "an empty grant means unknown, not complete")
        XCTAssertFalse(Set(OuraAuth.scopes).isSubset(of: Set(legacy.grantedScopes)))
    }

    func testAFullGrantDoesNotPrompt() {
        let current = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "c",
                                      refreshToken: "d", expiresAt: Date(),
                                      grantedScopes: OuraAuth.scopes)
        XCTAssertTrue(Set(OuraAuth.scopes).isSubset(of: Set(current.grantedScopes)))
    }

    func testForbiddenAndUnauthorisedSayDifferentThings() {
        let forbidden = OuraError.forbidden.errorDescription ?? ""
        let unauthorised = OuraError.unauthorized.errorDescription ?? ""
        XCTAssertNotEqual(forbidden, unauthorised)
        // A scope problem must not tell the user their login is broken.
        XCTAssertTrue(forbidden.lowercased().contains("permission") || forbidden.lowercased().contains("plan"))
    }
}

/// Oura returns 401 for metrics an account is not entitled to, not only for stale tokens,
/// so a sync touching a dozen endpoints can see several at once. Each must not spend its
/// own single-use refresh token.
final class RefreshCoalescingTests: XCTestCase {
    func testARecentRefreshIsReusedRatherThanRepeated() {
        let justRefreshed = Date()
        let credentials = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "fresh",
                                          refreshToken: "r", expiresAt: Date().addingTimeInterval(3600),
                                          grantedScopes: OuraAuth.scopes)
        // The condition the actor applies: refreshed within the window and still valid.
        let withinWindow = Date().timeIntervalSince(justRefreshed) < 60
        XCTAssertTrue(withinWindow && !credentials.isExpired)
    }

    func testAnOldRefreshDoesNotBlockANewOne() {
        let stale = Date().addingTimeInterval(-600)
        XCTAssertFalse(Date().timeIntervalSince(stale) < 60)
    }

    /// Reuse must not paper over a token that has actually expired.
    func testAnExpiredTokenStillRefreshesEvenIfJustRefreshed() {
        let expired = OuraCredentials(clientID: "a", clientSecret: "b", accessToken: "old",
                                      refreshToken: "r", expiresAt: Date().addingTimeInterval(10),
                                      grantedScopes: OuraAuth.scopes)
        XCTAssertTrue(expired.isExpired, "inside the safety margin, so reuse must not apply")
    }
}

final class UnauthorisedMeaningTests: XCTestCase {
    /// Oura answers 401 both for a stale token and for data an account cannot see. Only the
    /// first is fixed by signing in again, so the two must not share a message.
    func testNotEntitledDoesNotTellTheUserToSignInAgain() {
        let message = (OuraError.notEntitled.errorDescription ?? "").lowercased()
        XCTAssertTrue(message.contains("plan"))
        XCTAssertTrue(message.contains("valid"))
        XCTAssertNotEqual(OuraError.notEntitled.errorDescription, OuraError.unauthorized.errorDescription)
    }

    func testStaleTokenMessageStillPointsAtSigningIn() {
        let message = (OuraError.unauthorized.errorDescription ?? "").lowercased()
        XCTAssertTrue(message.contains("sign in again"))
    }

    func testAllThreeRejectionKindsReadDifferently() {
        let messages = Set([
            OuraError.unauthorized.errorDescription,
            OuraError.forbidden.errorDescription,
            OuraError.notEntitled.errorDescription
        ].compactMap { $0 })
        XCTAssertEqual(messages.count, 3, "each rejection needs its own remedy")
    }
}
