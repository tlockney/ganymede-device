@testable import DeviceBridge
import JavaScriptCore
import XCTest

@MainActor
private final class Board: Clipboard {
    var text: String? = "from the Mac"
    func readText() -> String? { text }
    func writeText(_ text: String) { self.text = text }
    func readImage() -> Data? { nil }
    func writeImage(_ data: Data) -> Bool { false }
}

/// Records each dialog; a close counts and finishes at once.
@MainActor
private final class Screen: DialogPresenter {
    var shown = 0
    var closed = 0
    func present(_ dialog: Dialog, on host: DialogHost?, done: @escaping (DialogResult) -> Void) throws -> Close {
        shown += 1
        return { [weak self] gone in
            self?.closed += 1
            gone()
        }
    }
}

@MainActor
final class EngineTests: XCTestCase {
    private var screen: Screen!
    private var bridge: DeviceBridge!

    override func setUp() async throws {
        screen = Screen()
        bridge = DeviceBridge(clipboard: Board(), presenter: screen, appVersion: "1.0")
    }

    /// Sends `message` and returns the reply, parsed, or nil while it waits.
    private func send(_ engine: EngineDevice, _ message: [String: Any]) -> () -> [String: Any]? {
        var reply: [String: Any]?
        let text = String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
        engine.respond(to: text) { reply = try! JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return { reply }
    }

    private func code(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testCallsCrossAsJSONText() {
        let engine = bridge.engineDevice()
        let hello = send(engine, ["id": 1, "owner": 1, "method": "hello", "params": [:]])()
        let capabilities = (hello?["result"] as? [String: Any])?["capabilities"] as? [String]
        XCTAssertTrue(capabilities?.contains("clipboard.readText") == true)
        XCTAssertEqual(send(engine, ["id": 2, "method": "clipboard.readText", "params": [:]])()?["result"] as? String, "from the Mac")
        let bad = String(data: try! JSONSerialization.data(withJSONObject: ["not an object"]), encoding: .utf8)!
        var reply: String?
        engine.respond(to: bad) { reply = $0 }
        XCTAssertTrue(reply?.contains(#""failed""#) == true)
    }

    func testEachContextHasItsOwnOwnerApartFromThePagesAndRemotes() {
        let one = bridge.engineDevice()
        let two = bridge.engineDevice()
        XCTAssertNotEqual(one.owner, two.owner)
        XCTAssertTrue(DeviceBridge.isEngine(one.owner) && DeviceBridge.isEngine(two.owner))
        // The owner a message names is ignored: the context's is used.
        bridge.setNotebook("/n/Page.ipynb", for: 1)
        bridge.setNotebook("/n/Engine.ipynb", for: one.owner)
        _ = send(one, ["id": 1, "owner": 1, "release": true])
        XCTAssertEqual(bridge.ledger.notebook(for: 1), "/n/Page.ipynb", "a context can't release the page's kernel")
        XCTAssertNil(bridge.ledger.notebook(for: one.owner))
    }

    func testSameIdsInTwoContextsAndThePageNameDifferentCalls() {
        let one = bridge.engineDevice()
        let two = bridge.engineDevice()
        let first = send(one, ["id": 1, "method": "ui.alert", "params": ["message": "one"]])
        let second = send(two, ["id": 1, "method": "ui.alert", "params": ["message": "two"]])
        XCTAssertEqual(screen.shown, 1, "the second waits its turn")
        // The page's id 1 and the other context's are not this one.
        _ = bridge.handle(["id": 1, "cancel": true])
        _ = send(two, ["id": 1, "cancel": true])
        XCTAssertEqual(screen.closed, 0)
        XCTAssertEqual(code(second()), "cancelled")
        _ = send(one, ["id": 1, "cancel": true])
        XCTAssertEqual(screen.closed, 1)
        XCTAssertEqual(code(first()), "cancelled")
    }

    func testReleaseClosesWhatTheContextOpenedAndEndsIt() {
        let engine = bridge.engineDevice()
        let open = send(engine, ["id": 1, "method": "ui.alert", "params": ["message": "hi"]])
        bridge.dropRemote()
        bridge.dropPage()
        XCTAssertEqual(screen.closed, 0, "the page's and remote handler's drops leave engines alone")
        engine.release()
        XCTAssertEqual(screen.closed, 1)
        XCTAssertNotNil(open())
        XCTAssertEqual(code(send(engine, ["id": 2, "method": "clipboard.readText", "params": [:]])()), "unavailable")
    }

    func testAReleaseMessageClosesTheContextsDialogs() {
        let engine = bridge.engineDevice()
        let open = send(engine, ["id": 1, "method": "ui.alert", "params": ["message": "hi"]])
        _ = send(engine, ["release": true])
        XCTAssertEqual(screen.closed, 1)
        XCTAssertNotNil(open())
    }

    func testARemoteMessageCantNameTheEngineRange() {
        var reply: [String: Any]?
        bridge.respondRemote(to: ["id": 1, "owner": engineBase + 1, "release": true]) { reply = $0 }
        XCTAssertEqual(code(reply), "failed")
        bridge.respondRemote(to: ["id": engineBase + 1, "cancel": true]) { reply = $0 }
        XCTAssertEqual(code(reply), "failed")
    }

    func testTheEngineFunctionResolvesWithTheReply() async throws {
        let engine = bridge.engineDevice()
        let context = try XCTUnwrap(JSContext())
        engine.install(in: context)
        context.evaluateScript("""
            globalThis.out = null;
            __ganymedeDevice(JSON.stringify({ id: 1, owner: 1, method: "clipboard.readText", params: {} }))
              .then((reply) => { globalThis.out = JSON.parse(reply).result; });
            """)
        XCTAssertNil(context.exception)
        let deadline = Date().addingTimeInterval(5)
        while context.objectForKeyedSubscript("out").isNull, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(context.objectForKeyedSubscript("out").toString(), "from the Mac")
    }
}
