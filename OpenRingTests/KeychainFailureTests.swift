import XCTest
import Security
@testable import OpenRing

/// These assert on *meaning*, not wording: a Keychain write fails for several unrelated
/// reasons and only some are the user's to fix. The regression being guarded is a message
/// that told everyone to unlock a device that was never locked.
///
/// Note there is deliberately no round-trip test here. This project builds unsigned — CI
/// passes CODE_SIGNING_ALLOWED=NO, and releases are signed by a third-party service — so any
/// real Keychain write under test returns errSecMissingEntitlement (-34018). Testing the
/// mapping is the part that can actually run.
final class KeychainFailureTests: XCTestCase {
    private func message(for status: OSStatus) -> String {
        OuraError.secureStorageFailed("the Oura application credentials", Keychain.WriteFailure(status: status))
            .localizedDescription
    }

    func testMissingEntitlementDoesNotTellTheUserToUnlockTheDevice() {
        let text = message(for: errSecMissingEntitlement).lowercased()
        XCTAssertFalse(text.contains("unlock"), "a missing entitlement is not fixed by unlocking: \(text)")
    }

    func testMissingEntitlementIsReportedAsABuildProblem() {
        let text = message(for: errSecMissingEntitlement).lowercased()
        XCTAssertTrue(text.contains("entitlement"))
        XCTAssertTrue(text.contains("signing"), "the user should be pointed at the build, not the device")
    }

    func testLockedDeviceStillSaysToUnlock() {
        XCTAssertTrue(message(for: errSecInteractionNotAllowed).lowercased().contains("unlock"))
    }

    func testTheRawStatusIsAlwaysCarriedIntoTheMessage() {
        XCTAssertTrue(message(for: errSecMissingEntitlement).contains("-34018"))
    }

    func testUnrelatedCausesReadDifferently() {
        let causes = [
            errSecMissingEntitlement,
            errSecInteractionNotAllowed,
            errSecAuthFailed,
            errSecParam
        ].map { Keychain.WriteFailure(status: $0).cause }
        XCTAssertEqual(Set(causes).count, causes.count, "distinct causes must not collapse into one message")
    }

    func testAnUnknownStatusStillReportsItsNumber() {
        let text = message(for: -12345)
        XCTAssertTrue(text.contains("-12345"))
    }

    func testValueThatNeverReachedTheKeychainReportsNoStatus() {
        let text = OuraError.secureStorageFailed("the Oura authorization", nil).localizedDescription
        XCTAssertFalse(text.contains("OSStatus"), "there is no status when the write never happened: \(text)")
    }
}
