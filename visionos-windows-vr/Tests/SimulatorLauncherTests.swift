import XCTest

final class SimulatorLauncherTests: XCTestCase {
    @MainActor
    func testLauncherBecomesInteractive() throws {
        let app = XCUIApplication()
        app.launch()
        let library = app.buttons["Steam library"]
        XCTAssertTrue(library.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(library.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Simulator launcher"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
