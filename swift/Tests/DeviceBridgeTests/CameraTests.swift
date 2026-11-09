@testable import DeviceBridge
import XCTest

/// The camera permission, with the system's answer the test sets.
@MainActor
private final class FakeCamera: Permission {
    var status: PermissionStatus
    var prompts = 0
    var answer: PermissionStatus = .authorized

    init(_ status: PermissionStatus) {
        self.status = status
    }

    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        if status == .notDetermined {
            prompts += 1
            status = answer
        }
        done(status)
    }
}

/// Shows nothing: keeps each dialog's answer for the test to give.
@MainActor
private final class Screen: DialogPresenter {
    var shown: [Dialog] = []
    var closed = 0
    private var answers: [(DialogResult) -> Void] = []

    func present(_ dialog: Dialog, on host: DialogHost?, done: @escaping (DialogResult) -> Void) throws -> Close {
        shown.append(dialog)
        answers.append(done)
        return { [weak self] gone in
            self?.closed += 1
            gone()
        }
    }

    func answer(_ result: DialogResult) {
        answers.last?(result)
    }
}

/// The ledger's prompt, with the answer the test sets.
@MainActor
private final class Asking: LedgerPrompter {
    var answer: LedgerAnswer? = .always
    var asked = 0
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        asked += 1
        answer(self.answer)
    }

    func dismissPermission(_ id: Int) {}
}

@MainActor
final class CameraTests: XCTestCase {
    private let prompter = Asking()
    private let screen = Screen()

    private func bridge(_ camera: FakeCamera) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, presenter: screen, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = prompter
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.addCameraCapture(camera)
        return bridge
    }

    private func capture(_ bridge: DeviceBridge, id: Int = 1) -> () -> [String: Any]? {
        var answer: [String: Any]?
        bridge.respond(to: ["id": id, "owner": 1, "method": "camera.capture", "params": [:]]) { answer = $0 }
        return { answer }
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloListsTheCameraOnlyWhereItIs() {
        let camera = bridge(FakeCamera(.authorized)).capabilities
        XCTAssertTrue(camera.contains("camera.capture"))
        XCTAssertTrue(camera.contains("camera.requestAuthorization"))
        #if os(macOS)
        let mac = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        mac.addCameraCapture()
        XCTAssertFalse(mac.capabilities.contains { $0.hasPrefix("camera.") }, "a Mac has no camera screen")
        #endif
    }

    func testTheFirstCaptureAsksThenShowsTheCamera() {
        let camera = FakeCamera(.notDetermined)
        let reply = capture(bridge(camera))
        XCTAssertEqual(prompter.asked, 1)
        XCTAssertEqual(camera.prompts, 1)
        XCTAssertEqual(screen.shown, [.capturePhoto])
        XCTAssertNil(reply())
        screen.answer(.photo(Data([0xFF, 0xD8, 0xFF])))
        XCTAssertEqual((reply()?["result"] as? [String: Any])?["base64"] as? String, "/9j/")
    }

    func testACancelledCameraIsNull() {
        let reply = capture(bridge(FakeCamera(.authorized)))
        screen.answer(.dismissed)
        XCTAssertTrue(reply()?["result"] is NSNull)
    }

    func testASystemDenyRejectsWithoutTheCamera() {
        let camera = FakeCamera(.notDetermined)
        camera.answer = .denied
        XCTAssertEqual(errorCode(capture(bridge(camera))()), "denied")
        XCTAssertEqual(errorCode(capture(bridge(FakeCamera(.restricted)), id: 2)()), "denied")
        XCTAssertEqual(screen.shown, [])
    }

    func testALedgerDenyRejectsWithoutTheSystemPrompt() {
        prompter.answer = .deny
        let camera = FakeCamera(.notDetermined)
        let bridge = bridge(camera)
        XCTAssertEqual(errorCode(capture(bridge)()), "denied")
        XCTAssertEqual(camera.prompts, 0)
        XCTAssertEqual(screen.shown, [])
        XCTAssertEqual(errorCode(capture(bridge, id: 2)()), "denied")
        XCTAssertEqual(prompter.asked, 1, "the deny is kept")
    }

    func testACancelClosesTheCamera() {
        let bridge = bridge(FakeCamera(.authorized))
        let reply = capture(bridge)
        XCTAssertEqual(screen.shown, [.capturePhoto])
        bridge.respond(to: ["id": 1, "owner": 1, "cancel": true]) { _ in }
        XCTAssertEqual(errorCode(reply()), "cancelled")
        XCTAssertEqual(screen.closed, 1)
        screen.answer(.photo(Data([1])))
        XCTAssertEqual(errorCode(reply()), "cancelled", "a late photo is dropped")
    }

    func testAReleaseClosesTheCamera() {
        let bridge = bridge(FakeCamera(.authorized))
        let reply = capture(bridge)
        bridge.respond(to: ["owner": 1, "release": true]) { _ in }
        XCTAssertEqual(errorCode(reply()), "cancelled")
        XCTAssertEqual(screen.closed, 1)
    }

    func testTheCameraQueuesBehindAnotherDialog() {
        let bridge = bridge(FakeCamera(.authorized))
        var alert: [String: Any]?
        bridge.respond(to: ["id": 1, "owner": 1, "method": "ui.alert", "params": ["message": "hi"]]) { alert = $0 }
        let reply = capture(bridge, id: 2)
        XCTAssertEqual(screen.shown, [.alert(title: nil, message: "hi")])
        screen.answer(.ok)
        XCTAssertNotNil(alert)
        XCTAssertEqual(screen.shown.last, .capturePhoto)
        screen.answer(.dismissed)
        XCTAssertTrue(reply()?["result"] is NSNull)
    }
}
