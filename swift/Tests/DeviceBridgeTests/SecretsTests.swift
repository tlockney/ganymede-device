@testable import DeviceBridge
import XCTest

/// Secrets in memory; `locked` makes every call throw as a keychain does
/// before the first unlock.
@MainActor
final class MemorySecretStore: SecretStore {
    var items: [String: String] = [:]
    var locked = false

    private func open() throws { if locked { throw SecretStoreLocked() } }
    func read(_ account: String) throws -> String? { try open(); return items[account] }
    func write(_ value: String, to account: String) throws { try open(); items[account] = value }
    func delete(_ account: String) throws -> Bool { try open(); return items.removeValue(forKey: account) != nil }
    func accounts() throws -> [String] { try open(); return Array(items.keys) }
}

/// `device.secrets` (docs/phase-3.md, part 2) against a fake keychain.
@MainActor
final class SecretsTests: XCTestCase {
    private var store: MemorySecretStore!
    private var bridge: DeviceBridge!
    private var replies: [[String: Any]] = []
    private var nextID = 1

    override func setUp() async throws {
        store = MemorySecretStore()
        bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.addSecrets(NotebookSecrets(store: store))
        for (owner, notebook) in [(1, "/n/A.ipynb"), (2, "/n/B.ipynb")] {
            bridge.setNotebook(notebook, for: owner)
            bridge.ledger.record(.always, notebook: notebook, capability: "secrets")
        }
    }

    private func call(_ method: String, _ params: [String: Any] = [:], owner: Int = 1) -> [String: Any]? {
        var reply: [String: Any]?
        nextID += 1
        bridge.respond(to: ["id": nextID, "owner": owner, "method": method, "params": params]) { reply = $0 }
        return reply
    }

    private func code(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testANotebookSetsReadsListsAndDeletes() {
        XCTAssertTrue(call("secrets.get", ["name": "github"])?["result"] is NSNull)
        XCTAssertTrue(call("secrets.set", ["name": "github", "value": "tok"])?["result"] is NSNull)
        XCTAssertTrue(call("secrets.set", ["name": "api", "value": "key"])?["result"] is NSNull)
        XCTAssertEqual(call("secrets.get", ["name": "github"])?["result"] as? String, "tok")
        XCTAssertEqual(call("secrets.list")?["result"] as? [String], ["api", "github"])
        XCTAssertEqual(call("secrets.delete", ["name": "github"])?["result"] as? Bool, true)
        XCTAssertEqual(call("secrets.delete", ["name": "github"])?["result"] as? Bool, false)
        XCTAssertEqual(store.items, ["/n/A.ipynb\0api": "key"], "keyed by notebook and name")
    }

    func testASecondNotebookCantSeeIt() {
        _ = call("secrets.set", ["name": "github", "value": "tok"])
        XCTAssertTrue(call("secrets.get", ["name": "github"], owner: 2)?["result"] is NSNull)
        XCTAssertEqual(call("secrets.list", owner: 2)?["result"] as? [String], [])
        XCTAssertEqual(call("secrets.delete", ["name": "github"], owner: 2)?["result"] as? Bool, false)
        XCTAssertEqual(call("secrets.get", ["name": "github"])?["result"] as? String, "tok")
    }

    func testARenameKeepsThem() {
        _ = call("secrets.set", ["name": "github", "value": "tok"])
        bridge.notebookMoved(from: "/n/A.ipynb", to: "/n/C.ipynb")
        XCTAssertEqual(call("secrets.get", ["name": "github"])?["result"] as? String, "tok", "the kernel and its kept answer moved too")
        XCTAssertEqual(store.items, ["/n/C.ipynb\0github": "tok"])
        XCTAssertEqual(NotebookSecrets(store: store).all, [NotebookSecret(notebook: "/n/C.ipynb", name: "github")])
    }

    func testALedgerDenyRejectsDenied() {
        bridge.ledger.record(.deny, notebook: "/n/A.ipynb", capability: "secrets")
        XCTAssertEqual(code(call("secrets.set", ["name": "github", "value": "tok"])), "denied")
        XCTAssertEqual(code(call("secrets.list")), "denied")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(call("secrets.authorizationStatus")?["result"] as? String, "denied")
    }

    func testALockedKeychainIsUnavailable() {
        store.locked = true
        XCTAssertEqual(code(call("secrets.get", ["name": "github"])), "unavailable")
        XCTAssertEqual(NotebookSecrets(store: store).all, [], "Settings shows none rather than failing")
    }

    func testBadNamesAndValuesFail() {
        XCTAssertEqual(code(call("secrets.get", ["name": ""])), "failed")
        XCTAssertEqual(code(call("secrets.get", ["name": String(repeating: "x", count: 129)])), "failed")
        XCTAssertEqual(code(call("secrets.get", ["name": "a\0b"])), "failed")
        XCTAssertEqual(code(call("secrets.set", ["name": "a", "value": 1])), "failed")
        XCTAssertEqual(code(call("secrets.set", ["name": "a", "value": String(repeating: "é", count: 32 * 1024 + 1)])), "failed")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(call("secrets.set", ["name": "a", "value": String(repeating: "x", count: 64 * 1024)])?["result"] is NSNull)
    }

    func testSettingsDeletesANotebooksSecrets() throws {
        _ = call("secrets.set", ["name": "a", "value": "1"])
        _ = call("secrets.set", ["name": "b", "value": "2"])
        _ = call("secrets.set", ["name": "a", "value": "3"], owner: 2)
        let settings = NotebookSecrets(store: store)
        try settings.delete(notebook: "/n/A.ipynb")
        XCTAssertEqual(settings.all, [NotebookSecret(notebook: "/n/B.ipynb", name: "a")])
    }
}
