import DeviceBridge
import XCTest

@MainActor
private final class FakeClipboard: Clipboard {
    var text: String?
    func readText() -> String? { text }
    func writeText(_ text: String) { self.text = text }
}

@MainActor
final class DeviceBridgeTests: XCTestCase {
    private func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloListsTheMethodsItAnswers() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "1.2.3")
        let result = bridge.handle(["id": 1, "method": "hello", "params": [:]])["result"] as? [String: Any]
        XCTAssertEqual(result?["appVersion"] as? String, "1.2.3")
        XCTAssertEqual(result?["capabilities"] as? [String], ["clipboard.readText", "clipboard.writeText"])
        #if os(macOS)
        XCTAssertEqual(result?["platform"] as? String, "macos")
        #endif
        XCTAssertNotNil(result?["osVersion"] as? String)
    }

    func testClipboardRoundTrip() {
        let clipboard = FakeClipboard()
        let bridge = DeviceBridge(clipboard: clipboard, appVersion: "")
        XCTAssertTrue(bridge.handle(["id": 1, "method": "clipboard.readText"])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 2, "method": "clipboard.writeText", "params": ["text": "Io"]])["result"] is NSNull)
        XCTAssertEqual(clipboard.text, "Io")
        XCTAssertEqual(bridge.handle(["id": 3, "method": "clipboard.readText", "params": [:]])["result"] as? String, "Io")
    }

    func testErrorsCarryProtocolCodes() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "")
        XCTAssertEqual(errorCode(bridge.handle(["id": 1, "method": "camera.takePhoto"])), "unavailable")
        XCTAssertEqual(errorCode(bridge.handle(["id": 2, "method": "clipboard.writeText", "params": ["text": 5]])), "failed")
        XCTAssertEqual(errorCode(bridge.handle("nonsense")), "failed")
        XCTAssertEqual(errorCode(bridge.handle(["id": 3])), "failed")
    }

    func testCancelIsAcknowledged() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "")
        XCTAssertNil(bridge.handle(["id": 1, "cancel": true])["error"])
    }
}
