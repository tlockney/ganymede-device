@testable import DeviceBridge
import XCTest

/// The app's prompt: records each ask, and the test answers it.
@MainActor
private final class FakePrompter: LedgerPrompter {
    var asked: [(capability: String, notebook: String, id: Int)] = []
    var dismissed: [Int] = []
    private var answers: [Int: @MainActor (LedgerAnswer?) -> Void] = [:]

    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        asked.append((capability, notebook, id))
        answers[id] = answer
    }

    func dismissPermission(_ id: Int) {
        dismissed.append(id)
        answers[id] = nil
    }

    func answer(_ answer: LedgerAnswer?) {
        guard let last = asked.last, let done = answers.removeValue(forKey: last.id) else { return XCTFail("no prompt up") }
        done(answer)
    }
}

/// A system permission that's already granted, so only the ledger decides.
@MainActor
private final class Granted: Permission {
    var status = PermissionStatus.authorized
    var prompts = 0
    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        prompts += 1
        done(status)
    }
}

@MainActor
private final class Replies {
    var all: [[String: Any]] = []
    var last: [String: Any]? { all.last }
    lazy var reply: ([String: Any]) -> Void = { [unowned self] in self.all.append($0) }
}

@MainActor
final class LedgerTests: XCTestCase {
    private lazy var prompter = FakePrompter()
    private lazy var store = MemoryLedgerStore()
    private lazy var system = Granted()

    private func bridge(prompter: Bool = true) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: store), appVersion: "")
        if prompter { bridge.ledgerPrompter = self.prompter }
        bridge.setNotebook("/notes/walk.ipynb", for: 1)
        bridge.addPermission("location", system)
        bridge.addMethod("location.current", permission: "location") { _, reply in
            reply(.success("here"))
            return nil
        }
        return bridge
    }

    private func call(_ bridge: DeviceBridge, id: Int, owner: Int = 1, _ method: String = "location.current", into replies: Replies) {
        bridge.respond(to: ["id": id, "owner": owner, "method": method, "params": [:]], reply: replies.reply)
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testAFirstCallAsksOnceAndAlwaysIsKept() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        XCTAssertEqual(prompter.asked.count, 1)
        XCTAssertEqual(prompter.asked[0].capability, "location")
        XCTAssertEqual(prompter.asked[0].notebook, "/notes/walk.ipynb")
        XCTAssertTrue(replies.all.isEmpty, "waits on the person")
        prompter.answer(.always)
        XCTAssertEqual(replies.last?["result"] as? String, "here")
        call(bridge, id: 2, into: replies)
        XCTAssertEqual(prompter.asked.count, 1, "not asked again")
        XCTAssertEqual(replies.last?["result"] as? String, "here")
        XCTAssertEqual(store.saved, [LedgerGrant(notebook: "/notes/walk.ipynb", capability: "location", answer: .always)])
    }

    func testDenyIsKeptAndRejectsWithoutTheSystemPrompt() {
        let bridge = bridge()
        let replies = Replies()
        system.status = .notDetermined
        call(bridge, id: 1, into: replies)
        prompter.answer(.deny)
        XCTAssertEqual(errorCode(replies.last), "denied")
        call(bridge, id: 2, into: replies)
        XCTAssertEqual(errorCode(replies.last), "denied")
        XCTAssertEqual(prompter.asked.count, 1)
        XCTAssertEqual(system.prompts, 0, "the system is never asked")
    }

    func testOnceAllowsThisCallOnly() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        prompter.answer(.once)
        XCTAssertEqual(replies.last?["result"] as? String, "here")
        call(bridge, id: 2, into: replies)
        XCTAssertEqual(prompter.asked.count, 2, "asked again")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testDismissingThePromptDeniesAndKeepsNothing() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        prompter.answer(nil)
        XCTAssertEqual(errorCode(replies.last), "denied")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testARevokeTakesEffectOnTheNextCall() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        prompter.answer(.always)
        bridge.ledger.revoke(notebook: "/notes/walk.ipynb", capability: "location")
        XCTAssertTrue(bridge.ledger.grants.isEmpty)
        call(bridge, id: 2, into: replies)
        XCTAssertEqual(prompter.asked.count, 2)
    }

    func testHeadlessRunsUseKeptAnswersAndDenyTheRest() {
        store.saved = [LedgerGrant(notebook: "/notes/walk.ipynb", capability: "location", answer: .always)]
        let bridge = bridge(prompter: false)
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        XCTAssertEqual(replies.last?["result"] as? String, "here", "the kept grant, loaded from the store")
        bridge.setNotebook("/notes/other.ipynb", for: 2)
        call(bridge, id: 2, owner: 2, into: replies)
        XCTAssertEqual(errorCode(replies.last), "denied")
    }

    func testAKernelWithNoNotebookIsDenied() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, owner: 9, into: replies)
        XCTAssertEqual(errorCode(replies.last), "denied")
        XCTAssertTrue(prompter.asked.isEmpty)
    }

    func testACancelDuringThePromptDismissesIt() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        call(bridge, id: 2, into: replies)
        XCTAssertEqual(prompter.asked.count, 1, "both wait on one prompt")
        _ = bridge.handle(["id": 1, "cancel": true])
        XCTAssertEqual(errorCode(replies.last), "cancelled")
        XCTAssertTrue(prompter.dismissed.isEmpty, "call 2 still waits on it")
        _ = bridge.handle(["id": 2, "cancel": true])
        XCTAssertEqual(prompter.dismissed, [prompter.asked[0].id])
        XCTAssertEqual(replies.all.compactMap { errorCode($0) }, ["cancelled", "cancelled"])
    }

    func testAReleaseDismissesItsPrompt() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        _ = bridge.handle(["owner": 1, "release": true])
        XCTAssertEqual(errorCode(replies.last), "cancelled")
        XCTAssertEqual(prompter.dismissed.count, 1)
    }

    func testRequestAuthorizationGoesThroughTheLedger() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, "location.requestAuthorization", into: replies)
        prompter.answer(.deny)
        XCTAssertEqual(replies.last?["result"] as? String, "denied")
        XCTAssertEqual(system.prompts, 0)
    }

    func testARenameKeepsTheGrantsAndTheKernel() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        prompter.answer(.always)
        bridge.notebookMoved(from: "/notes/walk.ipynb", to: "/notes/run.ipynb")
        XCTAssertEqual(bridge.ledger.notebook(for: 1), "/notes/run.ipynb")
        XCTAssertEqual(bridge.ledger.answer(notebook: "/notes/run.ipynb", capability: "location"), .always)
        call(bridge, id: 2, into: replies)
        XCTAssertEqual(prompter.asked.count, 1)
        XCTAssertEqual(replies.last?["result"] as? String, "here")
    }

    func testAReloadForgetsWhichNotebookEachKernelRuns() {
        let bridge = bridge()
        let first = Replies()
        call(bridge, id: 1, into: first)
        prompter.answer(.always)
        XCTAssertEqual(first.last?["result"] as? String, "here")
        // Kernel numbers start over with the page: owner 1 may now run another notebook.
        bridge.dropPage()
        let after = Replies()
        call(bridge, id: 1, into: after)
        XCTAssertEqual(errorCode(after.last), "denied")
        bridge.setNotebook("/notes/walk.ipynb", for: 1)
        bridge.dropAll()
        call(bridge, id: 2, into: after)
        XCTAssertEqual(errorCode(after.last), "denied")
    }

    func testDropRemoteForgetsOnlyRemoteKernels() {
        let bridge = bridge()
        bridge.setNotebook("/notes/remote.ipynb", for: -1)
        bridge.dropRemote()
        XCTAssertNil(bridge.ledger.notebook(for: -1))
        XCTAssertEqual(bridge.ledger.notebook(for: 1), "/notes/walk.ipynb")
    }

    func testARenameOntoOldAnswersReplacesThem() {
        let ledger = PermissionLedger(store: store)
        ledger.record(.always, notebook: "/new.ipynb", capability: "location")
        ledger.record(.always, notebook: "/new.ipynb", capability: "contacts")
        ledger.record(.deny, notebook: "/old.ipynb", capability: "location")
        ledger.move(from: "/old.ipynb", to: "/new.ipynb")
        XCTAssertEqual(ledger.answer(notebook: "/new.ipynb", capability: "location"), .deny)
        XCTAssertEqual(ledger.answer(notebook: "/new.ipynb", capability: "contacts"), .always)
        XCTAssertEqual(ledger.grants.filter { $0.notebook == "/new.ipynb" }.count, 2)
        XCTAssertTrue(ledger.grants.allSatisfy { $0.notebook != "/old.ipynb" })
    }

    func testAnAnswerIsKeptOnceUnderThePathItHasNow() {
        @MainActor final class CountingStore: LedgerStore {
            var saves = 0
            var saved: [LedgerGrant] = []
            func load() -> [LedgerGrant] { saved }
            func save(_ grants: [LedgerGrant]) {
                saves += 1
                saved = grants
            }
        }
        let counting = CountingStore()
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: counting), appVersion: "")
        bridge.ledgerPrompter = prompter
        bridge.setNotebook("/a.ipynb", for: 1)
        bridge.addPermission("location", system)
        bridge.addMethod("location.current", permission: "location") { _, reply in
            reply(.success("here"))
            return nil
        }
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        call(bridge, id: 2, into: replies)
        bridge.notebookMoved(from: "/a.ipynb", to: "/b.ipynb")
        prompter.answer(.deny)
        XCTAssertEqual(counting.saves, 1, "one save for both waiters")
        XCTAssertEqual(bridge.ledger.answer(notebook: "/b.ipynb", capability: "location"), .deny)
        XCTAssertNil(bridge.ledger.answer(notebook: "/a.ipynb", capability: "location"))
    }

    func testAnAnswerIsKeptUnderThePromptsNotebookEvenIfTheKernelNumberIsReused() {
        let bridge = bridge()
        let replies = Replies()
        call(bridge, id: 1, into: replies)
        // The kernel number now runs another notebook (a reload elsewhere
        // reused it) while the prompt for walk.ipynb is still up.
        bridge.setNotebook("/notes/other.ipynb", for: 1)
        prompter.answer(.deny)
        XCTAssertEqual(bridge.ledger.answer(notebook: "/notes/walk.ipynb", capability: "location"), .deny)
        XCTAssertNil(bridge.ledger.answer(notebook: "/notes/other.ipynb", capability: "location"))
    }

    func testDeclarationsListWhatIsStillToAsk() {
        store.saved = [LedgerGrant(notebook: "/n.ipynb", capability: "location", answer: .deny)]
        let bridge = bridge()
        bridge.addPermission("contacts", Granted())
        XCTAssertEqual(
            bridge.undecided(["location", "contacts", "contacts", "bluetooth"], notebook: "/n.ipynb"),
            ["contacts"],
            "location has an answer; bluetooth isn't in this app"
        )
    }

    func testPickersSkipTheLedger() {
        // No notebook and no prompter: a permissioned call would be denied,
        // but methods without a permission never reach the ledger.
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: store), appVersion: "")
        XCTAssertNil(bridge.handle(["id": 1, "owner": 5, "method": "info", "params": [:]])["error"])
        XCTAssertTrue(prompter.asked.isEmpty)
    }

    func testTheUserDefaultsStoreKeepsAlwaysAndDeny() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ganymede.device.ledger.test"))
        defaults.removePersistentDomain(forName: "ganymede.device.ledger.test")
        let store = UserDefaultsLedgerStore(defaults: defaults)
        let grants = [
            LedgerGrant(notebook: "/a.ipynb", capability: "location", answer: .always),
            LedgerGrant(notebook: "/b.ipynb", capability: "contacts", answer: .deny),
        ]
        store.save(grants)
        XCTAssertEqual(store.load(), grants)
        defaults.removePersistentDomain(forName: "ganymede.device.ledger.test")
    }
}
