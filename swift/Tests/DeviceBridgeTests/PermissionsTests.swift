@testable import DeviceBridge
import XCTest

/// A system permission the test answers: `request` waits until `answer`.
@MainActor
private final class FakePermission: Permission {
    var status: PermissionStatus
    var prompts = 0
    private var waiting: [@MainActor (PermissionStatus) -> Void] = []

    init(_ status: PermissionStatus) {
        self.status = status
    }

    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        guard status == .notDetermined else {
            done(status)
            return
        }
        prompts += 1
        waiting.append(done)
    }

    /// The person answers the system prompt.
    func answer(_ status: PermissionStatus) {
        self.status = status
        let all = waiting
        waiting = []
        for done in all { done(status) }
    }
}

/// The ledger's prompt, always answering "always", so these tests reach
/// the system permission.
@MainActor
private final class AllowAll: LedgerPrompter {
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        answer(.always)
    }

    func dismissPermission(_ id: Int) {}
}

/// Kept answers in memory.
@MainActor
final class MemoryLedgerStore: LedgerStore {
    var saved: [LedgerGrant] = []
    func load() -> [LedgerGrant] { saved }
    func save(_ grants: [LedgerGrant]) { saved = grants }
}

@MainActor
private final class Answers {
    var all: [[String: Any]] = []
    var last: [String: Any]? { all.last }
    lazy var reply: ([String: Any]) -> Void = { [unowned self] in self.all.append($0) }
}

@MainActor
final class PermissionsTests: XCTestCase {
    private lazy var allowAll = AllowAll()
    private var runs = 0
    private var cancels = 0
    /// The reply of the last `test.read` that hasn't answered yet.
    private var pendingRead: MethodReply?

    /// A bridge with the `test` namespace's permission, `test.read` (needs
    /// it; answers 42, or waits when `wait` is set) and `test.ticks` (a
    /// stream that needs it).
    private func bridge(_ permission: FakePermission, wait: Bool = false) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = allowAll
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.setNotebook("b.ipynb", for: 2)
        bridge.addPermission("test", permission)
        bridge.addMethod("test.read", permission: "test") { [unowned self] _, reply in
            self.runs += 1
            if wait {
                self.pendingRead = reply
                return { [unowned self] in self.cancels += 1 }
            }
            reply(.success(42))
            return nil
        }
        bridge.addStream("test.ticks", permission: "test") { _, _ in Ticks() }
        return bridge
    }

    private final class Ticks: StreamSource {
        func stop() {}
    }

    private func call(_ bridge: DeviceBridge, _ method: String, id: Int, owner: Int = 1, into answers: Answers) {
        bridge.respond(to: ["id": id, "owner": owner, "method": method, "params": [:]], reply: answers.reply)
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloListsTheTrioAndTheMethods() {
        let bridge = bridge(FakePermission(.authorized))
        let hello = bridge.handle(["id": 1, "method": "hello", "params": [:]])["result"] as? [String: Any]
        let capabilities = hello?["capabilities"] as? [String] ?? []
        for method in ["test.authorizationStatus", "test.requestAuthorization", "test.read", "test.ticks"] {
            XCTAssertTrue(capabilities.contains(method), method)
        }
    }

    func testAuthorizationStatusReadsWithoutPrompting() {
        let permission = FakePermission(.limited)
        let bridge = bridge(permission)
        XCTAssertEqual(bridge.handle(["id": 1, "method": "test.authorizationStatus", "params": [:]])["result"] as? String, "limited")
        XCTAssertEqual(permission.prompts, 0)
    }

    func testRequestAuthorizationAnswersTheStatusAfterThePrompt() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let answers = Answers()
        call(bridge, "test.requestAuthorization", id: 1, into: answers)
        XCTAssertEqual(permission.prompts, 1)
        XCTAssertTrue(answers.all.isEmpty)
        permission.answer(.reducedAccuracy)
        XCTAssertEqual(answers.last?["result"] as? String, "reducedAccuracy")
    }

    func testAMethodAsksLazilyThenRuns() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let answers = Answers()
        call(bridge, "test.read", id: 1, into: answers)
        XCTAssertEqual(runs, 0, "waits on the prompt")
        permission.answer(.authorized)
        XCTAssertEqual(answers.last?["result"] as? Int, 42)
        call(bridge, "test.read", id: 2, into: answers)
        XCTAssertEqual(permission.prompts, 1, "asked once")
        XCTAssertEqual(answers.last?["result"] as? Int, 42)
    }

    func testWithoutAGrantAMethodRejectsDenied() {
        for status in [PermissionStatus.denied, .restricted] {
            let permission = FakePermission(status)
            let bridge = bridge(permission)
            let answers = Answers()
            call(bridge, "test.read", id: 1, into: answers)
            XCTAssertEqual(errorCode(answers.last), "denied")
            XCTAssertEqual(permission.prompts, 0)
        }
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let answers = Answers()
        call(bridge, "test.read", id: 1, into: answers)
        permission.answer(.denied)
        XCTAssertEqual(errorCode(answers.last), "denied")
        XCTAssertEqual(runs, 0)
    }

    func testACancelDuringThePromptRejectsCancelledAndTheLateAnswerIsIgnored() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let answers = Answers()
        call(bridge, "test.read", id: 1, into: answers)
        _ = bridge.handle(["id": 1, "cancel": true])
        XCTAssertEqual(errorCode(answers.last), "cancelled")
        permission.answer(.authorized)
        XCTAssertEqual(answers.all.count, 1)
        XCTAssertEqual(runs, 0, "the late grant doesn't run the call")
        XCTAssertEqual(permission.status, .authorized, "but it counts for the next one")
    }

    func testCallsDuringOnePromptShareIt() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let answers = Answers()
        call(bridge, "test.read", id: 1, into: answers)
        call(bridge, "test.requestAuthorization", id: 2, into: answers)
        call(bridge, "test.read", id: 3, into: answers)
        XCTAssertEqual(permission.prompts, 1)
        permission.answer(.authorized)
        XCTAssertEqual(answers.all.count, 3)
    }

    func testACancelStopsARunningHandler() {
        let bridge = bridge(FakePermission(.authorized), wait: true)
        let answers = Answers()
        call(bridge, "test.read", id: 1, into: answers)
        XCTAssertEqual(runs, 1)
        _ = bridge.handle(["id": 1, "cancel": true])
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(errorCode(answers.last), "cancelled")
        pendingRead?(.success(7))
        XCTAssertEqual(answers.all.count, 1, "a reply after the cancel is ignored")
    }

    func testAHandlersErrorKeepsItsCode() {
        let bridge = bridge(FakePermission(.authorized), wait: true)
        let answers = Answers()
        call(bridge, "test.read", id: 1, into: answers)
        pendingRead?(.failure(DeviceCallError("unavailable", "no sensor")))
        XCTAssertEqual(errorCode(answers.last), "unavailable")
    }

    func testAPermissionedStreamAsksFirst() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let answers = Answers()
        call(bridge, "test.ticks", id: 1, into: answers)
        XCTAssertTrue(answers.all.isEmpty)
        permission.answer(.authorized)
        XCTAssertEqual((answers.last?["result"] as? [String: Any])?["stream"] as? Int, 1)

        let refused = Answers()
        let denied = self.bridge(FakePermission(.denied))
        call(denied, "test.ticks", id: 1, into: refused)
        XCTAssertEqual(errorCode(refused.last), "denied")
    }

    func testAReleaseCancelsItsWaitingCalls() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let first = Answers()
        let second = Answers()
        call(bridge, "test.read", id: 1, owner: 1, into: first)
        call(bridge, "test.read", id: 2, owner: 2, into: second)
        _ = bridge.handle(["owner": 1, "release": true])
        XCTAssertEqual(errorCode(first.last), "cancelled")
        XCTAssertTrue(second.all.isEmpty)
        bridge.dropPage()
        XCTAssertEqual(errorCode(second.last), "cancelled")
    }

    // Ids start over when the page reloads: a step left over from a call
    // dropped with the old page must not answer the new page's call that
    // has the same id.

    func testAfterAReloadTheOldCallsPromptAnswerReachesOnlyTheNewCall() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let old = Answers()
        let new = Answers()
        call(bridge, "test.read", id: 1, into: old)
        bridge.dropPage()
        // The host names the new page's kernel's notebook.
        bridge.setNotebook("a.ipynb", for: 1)
        call(bridge, "test.read", id: 1, into: new)
        permission.answer(.authorized)
        XCTAssertEqual(old.all.count, 1)
        XCTAssertEqual(errorCode(old.last), "cancelled")
        XCTAssertEqual(new.all.count, 1)
        XCTAssertEqual(new.last?["result"] as? Int, 42)
        XCTAssertEqual(runs, 1, "only the new call runs")
    }

    func testAfterAReloadAnOldRequestAuthorizationDoesntAnswerTheNewCall() {
        let permission = FakePermission(.notDetermined)
        let bridge = bridge(permission)
        let old = Answers()
        let new = Answers()
        call(bridge, "test.requestAuthorization", id: 1, into: old)
        bridge.dropPage()
        // The host names the new page's kernel's notebook.
        bridge.setNotebook("a.ipynb", for: 1)
        call(bridge, "test.read", id: 1, into: new)
        permission.answer(.authorized)
        XCTAssertEqual(new.all.count, 1)
        XCTAssertEqual(new.last?["result"] as? Int, 42)
    }

    func testAfterAReloadAnOldHandlersLateReplyIsIgnored() {
        let bridge = bridge(FakePermission(.authorized), wait: true)
        let old = Answers()
        let new = Answers()
        call(bridge, "test.read", id: 1, into: old)
        let oldReply = pendingRead
        bridge.dropPage()
        // The host names the new page's kernel's notebook.
        bridge.setNotebook("a.ipynb", for: 1)
        call(bridge, "test.read", id: 1, into: new)
        oldReply?(.success(7))
        XCTAssertTrue(new.all.isEmpty)
        pendingRead?(.success(8))
        XCTAssertEqual(new.last?["result"] as? Int, 8)
    }

    func testAMethodWhosePermissionIsMissingIsntListed() {
        let bridge = DeviceBridge(clipboard: nil, appVersion: "")
        bridge.addMethod("nope.read", permission: "nope") { _, reply in
            reply(.success(1))
            return nil
        }
        bridge.addStream("nope.watch", permission: "nope") { _, _ in Ticks() }
        bridge.addMethod("free.read") { _, reply in
            reply(.success(1))
            return nil
        }
        XCTAssertFalse(bridge.capabilities.contains("nope.read"))
        XCTAssertFalse(bridge.capabilities.contains("nope.watch"))
        XCTAssertTrue(bridge.capabilities.contains("free.read"))
    }

    func testARemoteKernelCantAsk() {
        let bridge = bridge(FakePermission(.authorized))
        let answers = Answers()
        bridge.respondRemote(to: ["id": 1, "owner": 1, "method": "test.read", "params": [:]], reply: answers.reply)
        XCTAssertEqual(errorCode(answers.last), "unavailable")
        bridge.respondRemote(to: ["id": 2, "owner": 1, "method": "test.requestAuthorization", "params": [:]], reply: answers.reply)
        XCTAssertEqual(errorCode(answers.last), "unavailable")
        let hello = Answers()
        bridge.respondRemote(to: ["id": 3, "owner": 1, "method": "hello", "params": [:]], reply: hello.reply)
        let capabilities = (hello.last?["result"] as? [String: Any])?["capabilities"] as? [String] ?? []
        XCTAssertFalse(capabilities.contains { $0.hasPrefix("test.") })
    }
}
