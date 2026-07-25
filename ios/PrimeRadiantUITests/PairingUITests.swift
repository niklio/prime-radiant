import XCTest

/// Pairing entry (ux-update §1): a fresh launch with no pairing record shows
/// the ignition screen; anywhere-tap opens the full-screen staged pairing flow
/// (1b — one capsule field over the void, no sheet chrome). `-PRResetPairing`
/// clears any persisted pairing so the run is deterministic on a reused
/// simulator; `-PRDebugPairingState=` renders each stage deterministically.
final class PairingUITests: XCTestCase {

    func testFreshLaunchShowsIgnitionThenAddressScreen() throws {
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
            "the 1b address screen did not open on tap")
    }

    /// The provisioning screen renders the three stage lines from the marker
    /// grammar (1c2) — copy is part of the mock contract.
    func testProvisioningStateRendersTheThreeStageLines() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PRDebugPairingState=provisioning"]
        app.launch()

        let reach = app.descendants(matching: .any)["pairing.stage.reach"].firstMatch
        XCTAssertTrue(reach.waitForExistence(timeout: 15), "stage lines never appeared")
        XCTAssertEqual(reach.label, "reaching the box")
        XCTAssertEqual(
            app.descendants(matching: .any)["pairing.stage.plant"].firstMatch.label,
            "planting the radiant")
        XCTAssertEqual(
            app.descendants(matching: .any)["pairing.stage.wake"].firstMatch.label,
            "waking the engine")
    }

    /// 1b2 is an inline state on the same screen: the one line below the field,
    /// exact copy `the radiant is beyond reach`.
    func testUnreachableStateShowsTheLine() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PRDebugPairingState=unreachable"]
        app.launch()

        let line = app.staticTexts["the radiant is beyond reach"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "unreachable line missing")
        XCTAssertTrue(
            app.descendants(matching: .any)["pairing.address"].firstMatch.exists,
            "the address field must remain — editing it is the retry")
    }
}
