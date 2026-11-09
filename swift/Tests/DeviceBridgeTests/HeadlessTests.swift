@testable import DeviceBridge
import XCTest

/// A system permission whose status the test sets.
@MainActor
private final class System: Permission {
    var status = PermissionStatus.authorized
    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) { done(status) }
}

/// A headless engine context (docs/phase-4.md, part 2): only what works
/// without a person.
@MainActor
final class HeadlessTests: XCTestCase {
    private var bridge: DeviceBridge!
    private var system: System!
    private var engine: EngineDevice!

    override func setUp() async throws {
        system = System()
        bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.addPermission("location", system)
        bridge.addMethod("location.current", permission: "location") { _, reply in
            reply(.success("here"))
            return nil
        }
        bridge.addFolders(FolderGrants(store: MemoryFolderStore()))
        engine = bridge.engineDevice(headless: true)
        bridge.setNotebook("/n/Walk.ipynb", for: engine.owner)
    }

    private func send(_ message: [String: Any]) -> [String: Any]? {
        var reply: [String: Any]?
        let text = String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        engine.respond(to: text) { reply = try! JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return reply
    }

    private func capabilities() -> [String] {
        (send(["id": 1, "method": "hello", "params": [:]])?["result"] as? [String: Any])?["capabilities"] as? [String] ?? []
    }

    private func code(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloLeavesOutWhatNeedsAPerson() {
        let list = capabilities()
        XCTAssertTrue(list.contains("location.authorizationStatus"))
        for method in ["ui.alert", "share", "files.pick", "folders.pick", "location.requestAuthorization", "location.current"] {
            XCTAssertFalse(list.contains(method), method)
        }
        XCTAssertTrue(bridge.engineDevice().allows("ui.alert"), "a context with a window may")
    }

    func testAPermissionedMethodNeedsAKeptAlwaysAndTheSystemsGrant() {
        XCTAssertEqual(code(send(["id": 2, "method": "location.current", "params": [:]])), "unavailable")
        bridge.ledger.record(.always, notebook: "/n/Walk.ipynb", capability: "location")
        XCTAssertTrue(capabilities().contains("location.current"))
        XCTAssertEqual(send(["id": 3, "method": "location.current", "params": [:]])?["result"] as? String, "here")
        system.status = .denied
        XCTAssertFalse(capabilities().contains("location.current"))
        XCTAssertEqual(code(send(["id": 4, "method": "location.current", "params": [:]])), "unavailable")
        system.status = .authorized
        bridge.ledger.record(.deny, notebook: "/n/Walk.ipynb", capability: "location")
        XCTAssertEqual(code(send(["id": 5, "method": "location.current", "params": [:]])), "unavailable")
    }

    func testADialogFailsUnavailable() {
        XCTAssertEqual(code(send(["id": 6, "method": "ui.alert", "params": ["message": "hi"]])), "unavailable")
        XCTAssertEqual(code(send(["id": 7, "method": "folders.pick", "params": [:]])), "unavailable")
        XCTAssertEqual(code(send(["id": 8, "method": "location.requestAuthorization", "params": [:]])), "unavailable")
    }
}
