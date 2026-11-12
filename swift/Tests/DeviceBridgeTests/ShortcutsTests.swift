@testable import DeviceBridge
import XCTest

private final class Opener: URLOpener {
    var opened: [URL] = []
    /// What `open(_:completion:)` reports; nil holds the answer back.
    var succeeds: Bool? = true
    func open(_ url: URL, inApp: Bool) { opened.append(url) }
    func open(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        opened.append(url)
        if let succeeds { completion(succeeds) }
    }
}

/// `device.shortcuts.run` (#40): the Shortcuts URL it opens, and the
/// callbacks that answer it.
@MainActor
final class ShortcutsTests: XCTestCase {
    private var opener: Opener!
    private var calls: ShortcutCalls!
    private var bridge: DeviceBridge!
    private var replies: [Int: [String: Any]] = [:]

    override func setUp() async throws {
        opener = Opener()
        calls = ShortcutCalls(callback: URL(string: "ganymede://device-callback/shortcuts")!)
        bridge = DeviceBridge(urlOpener: opener, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.addShortcuts(calls)
        bridge.setNotebook("/n/A.ipynb", for: 1)
        bridge.ledger.record(.always, notebook: "/n/A.ipynb", capability: "shortcuts")
        replies = [:]
    }

    private func run(_ params: [String: Any], id: Int = 1) {
        bridge.respond(to: ["id": id, "owner": 1, "method": "shortcuts.run", "params": params]) { [weak self] in
            self?.replies[id] = $0
        }
    }

    private func code(_ id: Int) -> String? {
        (replies[id]?["error"] as? [String: Any])?["code"] as? String
    }

    /// The callback URL the opened Shortcuts URL names for `outcome`.
    private func callback(_ outcome: String, query: String = "") throws -> URL {
        let opened = try XCTUnwrap(opener.opened.last)
        let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let base = try XCTUnwrap(items.first { $0.name == "x-\(outcome)" }?.value)
        return try XCTUnwrap(URL(string: base + query))
    }

    func testOpensTheShortcutWithItsInputAndAnswersWithItsResult() throws {
        run(["name": "Log it", "input": "a+b & c"])
        let opened = try XCTUnwrap(opener.opened.first)
        XCTAssertEqual(opened.scheme, "shortcuts")
        XCTAssertEqual(opened.host, "x-callback-url")
        XCTAssertEqual(opened.path, "/run-shortcut")
        let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Log it")
        XCTAssertEqual(items.first { $0.name == "input" }?.value, "text")
        XCTAssertEqual(items.first { $0.name == "text" }?.value, "a+b & c")
        XCTAssertFalse(opened.absoluteString.contains("a+b"), "a + is encoded, not left to read as a space")
        XCTAssertNil(replies[1], "waits for the callback")
        XCTAssertTrue(calls.handle(try callback("success", query: "?result=logged%20it")))
        XCTAssertEqual(replies[1]?["result"] as? String, "logged it")
        XCTAssertEqual(calls.waitingCount, 0)
    }

    func testNoInputAndNoOutput() throws {
        run(["name": "Ping"])
        let items = URLComponents(url: try XCTUnwrap(opener.opened.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first { $0.name == "input" })
        XCTAssertTrue(calls.handle(try callback("success")))
        XCTAssertTrue(replies[1]?["result"] is NSNull)
    }

    func testCancelAndErrorReject() throws {
        run(["name": "A"], id: 1)
        XCTAssertTrue(calls.handle(try callback("cancel")))
        XCTAssertEqual(code(1), "cancelled")
        run(["name": "B"], id: 2)
        XCTAssertTrue(calls.handle(try callback("error", query: "?errorMessage=No%20such%20shortcut")))
        XCTAssertEqual(code(2), "failed")
        XCTAssertTrue(((replies[2]?["error"] as? [String: Any])?["message"] as? String)?.contains("No such shortcut") == true)
    }

    func testAnInterruptStopsWaitingAndALateCallbackIsIgnored() throws {
        run(["name": "Slow"])
        let late = try callback("success", query: "?result=late")
        bridge.respond(to: ["id": 1, "owner": 1, "cancel": true]) { _ in }
        XCTAssertEqual(code(1), "cancelled")
        XCTAssertEqual(calls.waitingCount, 0)
        XCTAssertTrue(calls.handle(late), "still ours, so the app does nothing else with it")
        XCTAssertEqual(code(1), "cancelled")
    }

    func testAShortcutsAppThatCantBeOpenedFailsTheCall() throws {
        opener.succeeds = false
        run(["name": "A"])
        XCTAssertEqual(code(1), "unavailable")
        XCTAssertEqual(calls.waitingCount, 0)
    }

    func testAnUnknownOutcomeLeavesTheCallWaiting() throws {
        run(["name": "A"])
        let success = try callback("success", query: "?result=ok")
        let odd = URL(string: success.absoluteString.replacingOccurrences(of: "/success?", with: "/other?"))!
        XCTAssertTrue(calls.handle(odd))
        XCTAssertNil(replies[1])
        XCTAssertTrue(calls.handle(success))
        XCTAssertEqual(replies[1]?["result"] as? String, "ok")
    }

    func testOtherURLsAreNotItsOwn() throws {
        run(["name": "A"])
        XCTAssertFalse(calls.handle(URL(string: "ganymede://open?path=/a.ipynb")!))
        XCTAssertFalse(calls.handle(URL(string: "ganymede://device-callback/other/x/success")!))
        XCTAssertFalse(calls.handle(URL(string: "other://device-callback/shortcuts/x/success")!))
        XCTAssertTrue(calls.handle(URL(string: "ganymede://device-callback/shortcuts/unknown-token/success")!), "a guessed token answers nothing")
        XCTAssertNil(replies[1])
    }

    func testBadArgumentsFailBeforeOpening() {
        run(["name": ""], id: 1)
        run(["name": 3], id: 2)
        run(["name": "A", "input": 4], id: 3)
        run(["name": String(repeating: "x", count: 257)], id: 4)
        XCTAssertEqual([code(1), code(2), code(3), code(4)], ["failed", "failed", "failed", "failed"])
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testNeedsTheLedgerAndIsListed() {
        XCTAssertTrue(bridge.capabilities.contains("shortcuts.run"))
        XCTAssertTrue(bridge.capabilities.contains("shortcuts.authorizationStatus"))
        bridge.setNotebook("/n/B.ipynb", for: 2)
        bridge.respond(to: ["id": 9, "owner": 2, "method": "shortcuts.run", "params": ["name": "A"]]) { [weak self] in
            self?.replies[9] = $0
        }
        XCTAssertEqual(code(9), "denied", "no prompter and no kept answer")
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testNotInAHeadlessRun() {
        let device = bridge.engineDevice(headless: true)
        XCTAssertFalse(device.allows("shortcuts.run"))
    }
}
