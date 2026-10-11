// Needs a paired iPhone simulator running SO101Relay connected to a mock gateway.
// See README "Simulator end-to-end". Skips itself if the robot is not connected.

import XCTest

final class WatchFlowUITests: XCTestCase {
    func testPrimaryButtonStartsCalibrationThenStopHolds() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SO101_SKIP_PERMISSION_PROMPTS"] = "1"
        app.launch()

        let mode = app.staticTexts["mode"]
        let hold = NSPredicate(format: "label == 'HOLD'")
        let connected = expectation(for: hold, evaluatedWith: mode)
        if XCTWaiter.wait(for: [connected], timeout: 15) != .completed {
            throw XCTSkip("robot not connected through the iPhone simulator (mode=\(mode.label))")
        }

        app.buttons["primary"].tap()
        // Agent answers with CALIBRATING; the simulator has no device motion, so it then times out to HOLD.
        let calibrating = expectation(for: NSPredicate(format: "label == 'CALIBRATING'"), evaluatedWith: mode)
        wait(for: [calibrating], timeout: 5)

        app.buttons["stop"].tap()
        let back = expectation(for: hold, evaluatedWith: mode)
        wait(for: [back], timeout: 5)
    }
}
