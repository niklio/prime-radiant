import XCTest

/// Pairing entry (pivot v3): a fresh launch with no pairing record shows the
/// ignition screen; anywhere-tap opens the pairing sheet with the address
/// field. `-PRResetPairing` clears any persisted pairing so the run is
/// deterministic on a reused simulator.
final class PairingUITests: XCTestCase {

    func testFreshLaunchShowsIgnitionThenPairingSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PRResetPairing"]
        app.launch()

        let wordmark = app.descendants(matching: .any)["ignition.wordmark"].firstMatch
        XCTAssertTrue(
            wordmark.waitForExistence(timeout: 15),
            "ignition screen never appeared on a fresh, unpaired launch")

        // Anywhere-tap wakes the instrument (no buttons on the ignition screen).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        let address = app.descendants(matching: .any)["pairing.address"].firstMatch
        XCTAssertTrue(
            address.waitForExistence(timeout: 8),
            "pairing sheet with the address field did not open on tap")
    }
}
