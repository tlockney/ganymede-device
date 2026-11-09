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
        let r1 = await call("folders.list")
        let listed = try XCTUnwrap(r1["result"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, [folder["id"] as? String])
        let r2 = await call("folders.list", owner: 2)
        let other = try XCTUnwrap(r2["result"] as? [[String: Any]])
        XCTAssertTrue(other.isEmpty, "another notebook can't see it")

        // Picking it again replaces the grant and keeps its id.
        let r3 = await call("folders.pick")
        let again = try XCTUnwrap(r3["result"] as? [String: Any])
        XCTAssertEqual(again["id"] as? String, folder["id"] as? String)
        XCTAssertEqual(again["writable"] as? Bool, false)
        XCTAssertEqual(store.saved.count, 1)
    }

    func testACancelledPickerIsNull() async {
        picker.folder = nil
        let r4 = await call("folders.pick")
        XCTAssertTrue(r4["result"] is NSNull)
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testAKernelWithNoNotebookCantPick() async {
        let r5 = await call("folders.pick", owner: 3)
        XCTAssertEqual(code(r5), "denied")
        XCTAssertEqual(picker.shown, [], "refused before the picker shows")
    }

    func testEntriesReadWriteAndRemove() async throws {
        let r6 = await pick(write: true)
        let id = try XCTUnwrap(r6)
        let r7 = await call("folders.entries", ["folder": id])
        let entries = try XCTUnwrap(r7["result"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["name"] as? String }, ["a.txt", "sub"])
        XCTAssertEqual(entries.map { $0["kind"] as? String }, ["file", "directory"])
        XCTAssertEqual(entries[0]["size"] as? Int, 2)
        XCTAssertNotNil(entries[0]["modified"] as? String)

        let r8 = await call("folders.read", ["folder": id, "path": "a.txt"])
        XCTAssertEqual(text(r8), "hi")
        let data = ["base64": Data("new".utf8).base64EncodedString()]
        let r9 = await call("folders.write", ["folder": id, "path": "notes/b.txt", "data": data])
        XCTAssertTrue(r9["result"] is NSNull)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes/b.txt"), encoding: .utf8), "new")
        let r10 = await call("folders.remove", ["folder": id, "path": "notes"])
        XCTAssertEqual(code(r10), "failed", "not empty")
        let r11 = await call("folders.remove", ["folder": id, "path": "notes/b.txt"])
        XCTAssertTrue(r11["result"] is NSNull)
        let r12 = await call("folders.remove", ["folder": id, "path": "notes"])
        XCTAssertTrue(r12["result"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path))
        let r13 = await call("folders.read", ["folder": id, "path": "missing.txt"])
        XCTAssertEqual(code(r13), "failed")
        let r14 = await call("folders.read", ["folder": id, "path": "sub"])
        XCTAssertEqual(code(r14), "failed", "a directory")
        let r15 = await call("folders.remove", ["folder": id, "path": "."])
        XCTAssertEqual(code(r15), "denied", "the folder itself")
    }

    func testAReadOnlyFolderRefusesWrites() async throws {
        let r16 = await pick()
        let id = try XCTUnwrap(r16)
        let data = ["base64": Data("x".utf8).base64EncodedString()]
        let r17 = await call("folders.write", ["folder": id, "path": "b.txt", "data": data])
        XCTAssertEqual(code(r17), "denied")
        let r18 = await call("folders.remove", ["folder": id, "path": "a.txt"])
        XCTAssertEqual(code(r18), "denied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testPathsCantLeaveTheFolder() async throws {
        let r19 = await pick(write: true)
        let id = try XCTUnwrap(r19)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        for path in ["../Elsewhere/secret.txt", outside.appendingPathComponent("secret.txt").path, "link/secret.txt", "file-link", "sub/../../Elsewhere"] {
            let r20 = await call("folders.read", ["folder": id, "path": path])
            XCTAssertEqual(code(r20), "denied", path)
        }
        let data = ["base64": Data("x".utf8).base64EncodedString()]
        let r21 = await call("folders.write", ["folder": id, "path": "link/new.txt", "data": data])
        XCTAssertEqual(code(r21), "denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        let r22 = await call("folders.entries", ["folder": id, "path": "link"])
        XCTAssertEqual(code(r22), "denied")
    }

    func testAnotherNotebookCantUseTheFolder() async throws {
        let r23 = await pick()
        let id = try XCTUnwrap(r23)
        let r24 = await call("folders.read", ["folder": id, "path": "a.txt"], owner: 2)
        XCTAssertEqual(code(r24), "denied")
    }

    func testAMoveCarriesTheFolderAndARevokeDropsIt() async throws {
        let r25 = await pick()
        let id = try XCTUnwrap(r25)
        bridge.notebookMoved(from: "/n/a.ipynb", to: "/n/c.ipynb")
        let r26 = await call("folders.read", ["folder": id, "path": "a.txt"])
        XCTAssertEqual(text(r26), "hi")
        XCTAssertEqual(store.saved.first?.notebook, "/n/c.ipynb")
        FolderGrants(store: store).revoke(id)
        let r27 = await call("folders.read", ["folder": id, "path": "a.txt"])
        XCTAssertEqual(code(r27), "denied")
    }

    func testAFolderThatIsGoneFailsAndKeepsItsGrant() async throws {
        let picked = await pick()
        let id = try XCTUnwrap(picked)
        try FileManager.default.removeItem(at: root)
        let reply = await call("folders.entries", ["folder": id])
        XCTAssertEqual(code(reply), "unavailable")
        XCTAssertEqual(store.saved.count, 1, "a drive or share may come back")
    }

    func testAnUnusableBookmarkIsDropped() async throws {
        let picked = await pick()
        let id = try XCTUnwrap(picked)
        let grant = try XCTUnwrap(store.saved.first)
        store.saved = [FolderGrant(id: id, notebook: grant.notebook, name: grant.name, writable: false, bookmark: Data([1, 2, 3]))]
        let reply = await call("folders.entries", ["folder": id])
        XCTAssertEqual(code(reply), "unavailable")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testRemoveAndWriteActOnALinkNotItsTarget() async throws {
        let picked = await pick(write: true)
        let id = try XCTUnwrap(picked)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("latest.txt"), withDestinationURL: root.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("out.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let read = await call("folders.read", ["folder": id, "path": "latest.txt"])
        XCTAssertEqual(text(read), "hi", "a link inside the folder reads through")
        let removed = await call("folders.remove", ["folder": id, "path": "latest.txt"])
        XCTAssertTrue(removed["result"] is NSNull)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path), "the target stays")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("latest.txt").path))
        let data = ["base64": Data("mine".utf8).base64EncodedString()]
        let written = await call("folders.write", ["folder": id, "path": "out.txt", "data": data])
        XCTAssertTrue(written["result"] is NSNull)
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8), "secret", "the link is replaced, not followed")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8), "mine")
    }

    func testEntriesListALinkAsALink() async throws {
        let picked = await pick()
        let id = try XCTUnwrap(picked)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("latest.txt"), withDestinationURL: root.appendingPathComponent("a.txt"))
        let reply = await call("folders.entries", ["folder": id])
        let entries = try XCTUnwrap(reply["result"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["name"] as? String }, ["a.txt", "latest.txt", "sub"])
        XCTAssertEqual(entries[1]["kind"] as? String, "link")
        XCTAssertNil(entries[1]["size"])
    }

    func testANonICloudPlaceholderNameListsAsItself() async throws {
        // Outside iCloud Drive a `.name.icloud` file is just a file: it
        // lists, reads and removes by its own name.
        let picked = await pick(write: true)
        let id = try XCTUnwrap(picked)
        try Data("x".utf8).write(to: root.appendingPathComponent(".c.txt.icloud"))
        let reply = await call("folders.entries", ["folder": id])
        let entries = try XCTUnwrap(reply["result"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["name"] as? String }, [".c.txt.icloud", "a.txt", "sub"])
        XCTAssertEqual(entries[0]["size"] as? Int, 1)
        let missing = await call("folders.remove", ["folder": id, "path": "c.txt"])
        XCTAssertEqual(code(missing), "failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".c.txt.icloud").path))
    }

    func testBadArgumentsFail() async throws {
        let r30 = await pick(write: true)
        let id = try XCTUnwrap(r30)
        let r31 = await call("folders.read", ["folder": id])
        XCTAssertEqual(code(r31), "failed")
        let r32 = await call("folders.read", ["path": "a.txt"])
        XCTAssertEqual(code(r32), "failed")
        let r33 = await call("folders.write", ["folder": id, "path": "b.txt", "data": "plain"])
        XCTAssertEqual(code(r33), "failed")
        let r34 = await call("folders.pick", ["write": "yes"])
        XCTAssertEqual(code(r34), "failed")
    }
}
