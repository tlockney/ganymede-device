@testable import DeviceBridge
import XCTest

@MainActor
final class MemoryFolderStore: FolderStore {
    var saved: [FolderGrant] = []
    func load() -> [FolderGrant] { saved }
    func save(_ grants: [FolderGrant]) { saved = grants }
}

/// Answers each folder picker with the folder the test sets, or a cancel.
@MainActor
private final class Picker: DialogPresenter {
    var shown: [Dialog] = []
    var folder: URL?

    func present(_ dialog: Dialog, on host: DialogHost?, done: @escaping (DialogResult) -> Void) throws -> Close {
        shown.append(dialog)
        done(folder.map { .folder($0) } ?? .dismissed)
        return { gone in gone() }
    }
}

@MainActor
final class FoldersTests: XCTestCase {
    private let picker = Picker()
    private let store = MemoryFolderStore()
    private var root: URL!
    private var outside: URL!
    private var bridge: DeviceBridge!
    private var nextID = 1

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
        root = base.appendingPathComponent("Data")
        outside = base.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        picker.folder = root
        bridge = DeviceBridge(clipboard: nil, presenter: picker, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.addFolders(FolderGrants(store: store))
        bridge.setNotebook("/n/a.ipynb", for: 1)
        bridge.setNotebook("/n/b.ipynb", for: 2)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func call(_ method: String, _ params: [String: Any] = [:], owner: Int = 1) async -> [String: Any] {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { done in
            bridge.respond(to: ["id": id, "owner": owner, "method": method, "params": params]) { done.resume(returning: $0) }
        }
    }

    private func pick(write: Bool = false, owner: Int = 1) async -> String? {
        ((await call("folders.pick", ["write": write], owner: owner))["result"] as? [String: Any])?["id"] as? String
    }

    private func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private func text(_ reply: [String: Any]) -> String? {
        ((reply["result"] as? [String: Any])?["base64"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    func testHelloListsFolders() {
        let methods = bridge.capabilities
        for method in ["folders.pick", "folders.list", "folders.entries", "folders.read", "folders.write", "folders.remove"] {
            XCTAssertTrue(methods.contains(method), method)
        }
    }

    func testPickKeepsTheFolderForTheNotebook() async throws {
        let reply = await call("folders.pick", ["write": true])
        let folder = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(folder["name"] as? String, "Data")
        XCTAssertEqual(folder["writable"] as? Bool, true)
        XCTAssertEqual(picker.shown, [.pickFolder(write: true)])
        let listed = try XCTUnwrap((await call("folders.list"))["result"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, [folder["id"] as? String])
        let other = try XCTUnwrap((await call("folders.list", owner: 2))["result"] as? [[String: Any]])
        XCTAssertTrue(other.isEmpty, "another notebook can't see it")

        // Picking it again replaces the grant and keeps its id.
        let again = try XCTUnwrap((await call("folders.pick"))["result"] as? [String: Any])
        XCTAssertEqual(again["id"] as? String, folder["id"] as? String)
        XCTAssertEqual(again["writable"] as? Bool, false)
        XCTAssertEqual(store.saved.count, 1)
    }

    func testACancelledPickerIsNull() async {
        picker.folder = nil
        XCTAssertTrue((await call("folders.pick"))["result"] is NSNull)
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testAKernelWithNoNotebookCantPick() async {
        XCTAssertEqual(code(await call("folders.pick", owner: 3)), "denied")
        XCTAssertEqual(picker.shown, [], "refused before the picker shows")
    }

    func testEntriesReadWriteAndRemove() async throws {
        let id = try XCTUnwrap(await pick(write: true))
        let entries = try XCTUnwrap((await call("folders.entries", ["folder": id]))["result"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["name"] as? String }, ["a.txt", "sub"])
        XCTAssertEqual(entries.map { $0["kind"] as? String }, ["file", "directory"])
        XCTAssertEqual(entries[0]["size"] as? Int, 2)
        XCTAssertNotNil(entries[0]["modified"] as? String)

        XCTAssertEqual(text(await call("folders.read", ["folder": id, "path": "a.txt"])), "hi")
        let data = ["base64": Data("new".utf8).base64EncodedString()]
        XCTAssertTrue((await call("folders.write", ["folder": id, "path": "notes/b.txt", "data": data]))["result"] is NSNull)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes/b.txt"), encoding: .utf8), "new")
        XCTAssertEqual(code(await call("folders.remove", ["folder": id, "path": "notes"])), "failed", "not empty")
        XCTAssertTrue((await call("folders.remove", ["folder": id, "path": "notes/b.txt"]))["result"] is NSNull)
        XCTAssertTrue((await call("folders.remove", ["folder": id, "path": "notes"]))["result"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path))
        XCTAssertEqual(code(await call("folders.read", ["folder": id, "path": "missing.txt"])), "failed")
        XCTAssertEqual(code(await call("folders.read", ["folder": id, "path": "sub"])), "failed", "a directory")
        XCTAssertEqual(code(await call("folders.remove", ["folder": id, "path": "."])), "denied", "the folder itself")
    }

    func testAReadOnlyFolderRefusesWrites() async throws {
        let id = try XCTUnwrap(await pick())
        let data = ["base64": Data("x".utf8).base64EncodedString()]
        XCTAssertEqual(code(await call("folders.write", ["folder": id, "path": "b.txt", "data": data])), "denied")
        XCTAssertEqual(code(await call("folders.remove", ["folder": id, "path": "a.txt"])), "denied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testPathsCantLeaveTheFolder() async throws {
        let id = try XCTUnwrap(await pick(write: true))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        for path in ["../Elsewhere/secret.txt", outside.appendingPathComponent("secret.txt").path, "link/secret.txt", "file-link", "sub/../../Elsewhere"] {
            XCTAssertEqual(code(await call("folders.read", ["folder": id, "path": path])), "denied", path)
        }
        let data = ["base64": Data("x".utf8).base64EncodedString()]
        XCTAssertEqual(code(await call("folders.write", ["folder": id, "path": "link/new.txt", "data": data])), "denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        XCTAssertEqual(code(await call("folders.entries", ["folder": id, "path": "link"])), "denied")
    }

    func testAnotherNotebookCantUseTheFolder() async throws {
        let id = try XCTUnwrap(await pick())
        XCTAssertEqual(code(await call("folders.read", ["folder": id, "path": "a.txt"], owner: 2)), "denied")
    }

    func testAMoveCarriesTheFolderAndARevokeDropsIt() async throws {
        let id = try XCTUnwrap(await pick())
        bridge.notebookMoved(from: "/n/a.ipynb", to: "/n/c.ipynb")
        XCTAssertEqual(text(await call("folders.read", ["folder": id, "path": "a.txt"])), "hi")
        XCTAssertEqual(store.saved.first?.notebook, "/n/c.ipynb")
        FolderGrants(store: store).revoke(id)
        XCTAssertEqual(code(await call("folders.read", ["folder": id, "path": "a.txt"])), "denied")
    }

    func testAFolderThatIsGoneIsDropped() async throws {
        let id = try XCTUnwrap(await pick())
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(code(await call("folders.entries", ["folder": id])), "unavailable")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testBadArgumentsFail() async throws {
        let id = try XCTUnwrap(await pick(write: true))
        XCTAssertEqual(code(await call("folders.read", ["folder": id])), "failed")
        XCTAssertEqual(code(await call("folders.read", ["path": "a.txt"])), "failed")
        XCTAssertEqual(code(await call("folders.write", ["folder": id, "path": "b.txt", "data": "plain"])), "failed")
        XCTAssertEqual(code(await call("folders.pick", ["write": "yes"])), "failed")
    }
}
