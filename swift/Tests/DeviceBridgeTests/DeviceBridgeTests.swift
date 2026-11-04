import DeviceBridge
import XCTest

@MainActor
private final class FakeClipboard: Clipboard {
    var text: String?
    func readText() -> String? { text }
    func writeText(_ text: String) { self.text = text }
}

@MainActor
private final class FakeHaptics: Haptics {
    var isAvailable = true
    var played: [String] = []
    func impact(_ style: ImpactStyle) { played.append("impact \(style.rawValue)") }
    func notification(_ type: NotificationFeedback) { played.append("notification \(type.rawValue)") }
    func selection() { played.append("selection") }
}

@MainActor
private final class FakeOpener: URLOpener {
    var opened: [(URL, Bool)] = []
    func open(_ url: URL, inApp: Bool) { opened.append((url, inApp)) }
}

@MainActor
private struct FakeState: DeviceState {
    func current() -> [String: Any] {
        ["isPad": true, "darkMode": false, "locale": "en-US", "screen": ["width": 1180.0, "height": 820.0, "scale": 2.0]]
    }
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
        XCTAssertEqual(
            result?["capabilities"] as? [String],
            ["clipboard.readText", "clipboard.writeText", "info", "openURL"] + (SystemHaptics().isAvailable
                ? ["haptics.impact", "haptics.notification", "haptics.selection"] : [])
        )
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

    func testHelloListsHapticsOnlyWhereThereAreSome() {
        let haptics = FakeHaptics()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), haptics: haptics, appVersion: "")
        XCTAssertTrue(bridge.capabilities.contains("haptics.impact"))
        haptics.isAvailable = false
        XCTAssertFalse(bridge.capabilities.contains("haptics.impact"))
        XCTAssertEqual(errorCode(bridge.handle(["id": 1, "method": "haptics.selection"])), "unavailable")
        XCTAssertEqual(haptics.played, [])
    }

    func testHapticsPlayWhatTheCellAsked() {
        let haptics = FakeHaptics()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), haptics: haptics, appVersion: "")
        XCTAssertTrue(bridge.handle(["id": 1, "method": "haptics.impact", "params": ["style": "heavy"]])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 2, "method": "haptics.impact", "params": [:]])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 3, "method": "haptics.notification", "params": ["type": "error"]])["result"] is NSNull)
        XCTAssertTrue(bridge.handle(["id": 4, "method": "haptics.selection"])["result"] is NSNull)
        XCTAssertEqual(haptics.played, ["impact heavy", "impact medium", "notification error", "selection"])
        XCTAssertEqual(errorCode(bridge.handle(["id": 5, "method": "haptics.impact", "params": ["style": "loud"]])), "failed")
        XCTAssertEqual(errorCode(bridge.handle(["id": 6, "method": "haptics.notification"])), "failed")
    }

    func testOpenURLTakesWebAndMailLinksOnly() {
        let opener = FakeOpener()
        let bridge = DeviceBridge(clipboard: FakeClipboard(), urlOpener: opener, appVersion: "")
        let open = { (url: Any, inApp: Bool?) -> [String: Any] in
            var params: [String: Any] = ["url": url]
            params["inApp"] = inApp
            return bridge.handle(["id": 1, "method": "openURL", "params": params])
        }
        XCTAssertTrue(open("https://deno.com", true)["result"] is NSNull)
        XCTAssertTrue(open("HTTP://example.com", nil)["result"] is NSNull)
        XCTAssertTrue(open("mailto:a@example.com", nil)["result"] is NSNull)
        XCTAssertEqual(opener.opened.map { $0.0.absoluteString }, ["https://deno.com", "HTTP://example.com", "mailto:a@example.com"])
        XCTAssertEqual(opener.opened.map { $0.1 }, [true, false, false])
        for bad: Any in ["file:///etc/passwd", "shortcuts://run-shortcut?name=x", "not a url", 5] {
            XCTAssertEqual(errorCode(open(bad, nil)), "failed", "\(bad)")
        }
        XCTAssertEqual(opener.opened.count, 3)
    }

    func testInfoReportsTheCurrentState() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), state: FakeState(), appVersion: "")
        let result = bridge.handle(["id": 1, "method": "info"])["result"] as? [String: Any]
        XCTAssertEqual(result?["isPad"] as? Bool, true)
        XCTAssertEqual(result?["locale"] as? String, "en-US")
        XCTAssertEqual((result?["screen"] as? [String: Any])?["scale"] as? Double, 2.0)
    }

    func testSystemStateIsPlainValues() throws {
        // What WebKit can carry: the reply must be a property list.
        let state = SystemDeviceState().current()
        XCTAssertNotNil(state["locale"] as? String)
        XCTAssertNotNil(state["darkMode"] as? Bool)
        XCTAssertNotNil(state["isPad"] as? Bool)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(state))
    }

    func testHelloNamesTheModel() {
        let bridge = DeviceBridge(clipboard: FakeClipboard(), appVersion: "")
        let result = bridge.handle(["id": 1, "method": "hello"])["result"] as? [String: Any]
        XCTAssertFalse((result?["model"] as? String ?? "").isEmpty)
    }
}
