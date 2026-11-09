@testable import DeviceBridge
import UserNotifications
import XCTest

/// A notification center in memory, with a permission the test sets.
@MainActor
private final class FakeScheduler: NotificationScheduler {
    var status: PermissionStatus
    /// What the system prompt answers.
    var answer: PermissionStatus = .authorized
    var prompts = 0
    var scheduled: [NotificationRequest] = []
    /// Notifications another part of the app scheduled.
    var others: [ScheduledNotification] = []
    var failure: DeviceCallError?

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

    func add(_ request: NotificationRequest, done: @escaping @MainActor (DeviceCallError?) -> Void) {
        if let failure {
            done(failure)
            return
        }
        scheduled.append(request)
        done(nil)
    }

    func pending(_ done: @escaping @MainActor ([ScheduledNotification]) -> Void) {
        done(others + scheduled.map {
            ScheduledNotification(id: $0.id, title: $0.title, body: $0.body, notebook: $0.notebook, date: Date(timeIntervalSince1970: $0.delay))
        })
    }

    func remove(_ ids: [String]) {
        scheduled.removeAll { ids.contains($0.id) }
        others.removeAll { ids.contains($0.id) }
    }
}

/// The ledger's prompt, answering "always".
@MainActor
private final class Always: LedgerPrompter {
    func askPermission(_ capability: String, notebook: String, id: Int, answer: @escaping @MainActor (LedgerAnswer?) -> Void) {
        answer(.always)
    }

    func dismissPermission(_ id: Int) {}
}

@MainActor
final class NotificationsTests: XCTestCase {
    private lazy var always = Always()
    private var nextID = 0

    /// A bridge with notifications; kernel 1 runs a.ipynb, kernel 2 b.ipynb, kernel 3 none.
    private func bridge(_ scheduler: FakeScheduler) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = always
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.setNotebook("b.ipynb", for: 2)
        bridge.addNotifications(scheduler)
        return bridge
    }

    /// One call's reply; the fake answers at once, so it is there on return.
    private func call(_ bridge: DeviceBridge, _ method: String, _ params: [String: Any] = [:], owner: Int = 1) -> [String: Any]? {
        nextID += 1
        var answer: [String: Any]?
        bridge.respond(to: ["id": nextID, "owner": owner, "method": method, "params": params]) { answer = $0 }
        return answer
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    private func schedule(_ bridge: DeviceBridge, _ body: String, owner: Int = 1) -> String? {
        call(bridge, "notifications.schedule", ["body": body, "delay": 60], owner: owner)?["result"] as? String
    }

    func testHelloListsTheNamespace() {
        let bridge = bridge(FakeScheduler(.authorized))
        let hello = bridge.handle(["id": 1, "method": "hello", "params": [:]])["result"] as? [String: Any]
        let capabilities = hello?["capabilities"] as? [String] ?? []
        for method in [
            "notifications.authorizationStatus", "notifications.requestAuthorization", "notifications.schedule",
            "notifications.pending", "notifications.cancel", "notifications.cancelAll",
        ] {
            XCTAssertTrue(capabilities.contains(method), method)
        }
    }

    func testWithoutAddNotificationsTheNamespaceIsAbsent() {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        XCTAssertFalse(bridge.capabilities.contains { $0.hasPrefix("notifications.") })
    }

    func testScheduleAsksThenSchedulesForTheNotebook() throws {
        let scheduler = FakeScheduler(.notDetermined)
        let bridge = bridge(scheduler)
        let reply = call(bridge, "notifications.schedule", ["body": "Drink water", "title": "Break", "delay": 90])
        let id = try XCTUnwrap(reply?["result"] as? String)
        XCTAssertEqual(scheduler.prompts, 1)
        XCTAssertEqual(scheduler.scheduled, [NotificationRequest(id: id, title: "Break", body: "Drink water", delay: 90, notebook: "a.ipynb")])
    }

    func testDeniedPermissionRejectsAndSchedulesNothing() {
        let scheduler = FakeScheduler(.notDetermined)
        scheduler.answer = .denied
        let bridge = bridge(scheduler)
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["body": "x", "delay": 5])), "denied")
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["body": "x", "delay": 5])), "denied")
        XCTAssertEqual(scheduler.prompts, 1)
        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func testBadParamsFail() {
        let scheduler = FakeScheduler(.authorized)
        let bridge = bridge(scheduler)
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["delay": 5])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["body": "", "delay": 5])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["body": "x"])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["body": "x", "delay": 0])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "notifications.schedule", ["body": "x", "delay": 5, "title": 3])), "failed")
        XCTAssertEqual(errorCode(call(bridge, "notifications.cancel", [:])), "failed")
        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func testTheSchedulersErrorReachesTheCell() {
        let scheduler = FakeScheduler(.authorized)
        scheduler.failure = DeviceCallError("denied", "not allowed")
        XCTAssertEqual(errorCode(call(bridge(scheduler), "notifications.schedule", ["body": "x", "delay": 5])), "denied")
    }

    func testPendingListsOnlyTheNotebooksOwn() throws {
        let scheduler = FakeScheduler(.authorized)
        let bridge = bridge(scheduler)
        let mine = try XCTUnwrap(schedule(bridge, "mine"))
        _ = schedule(bridge, "theirs", owner: 2)
        scheduler.others = [ScheduledNotification(id: "app", title: nil, body: "app's own", notebook: nil, date: nil)]
        let pending = try XCTUnwrap(call(bridge, "notifications.pending")?["result"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?["id"] as? String, mine)
        XCTAssertEqual(pending.first?["body"] as? String, "mine")
        XCTAssertNil(pending.first?["title"])
        XCTAssertEqual(pending.first?["date"] as? String, "1970-01-01T00:01:00Z")
    }

    func testCancelReachesOnlyTheNotebooksOwn() throws {
        let scheduler = FakeScheduler(.authorized)
        let bridge = bridge(scheduler)
        let mine = try XCTUnwrap(schedule(bridge, "mine"))
        let theirs = try XCTUnwrap(schedule(bridge, "theirs", owner: 2))
        XCTAssertNotNil(call(bridge, "notifications.cancel", ["id": theirs])?["result"])
        XCTAssertEqual(scheduler.scheduled.map(\.id), [mine, theirs])
        XCTAssertNotNil(call(bridge, "notifications.cancel", ["id": mine])?["result"])
        XCTAssertEqual(scheduler.scheduled.map(\.id), [theirs])
        // Cancelling one that's gone is fine.
        XCTAssertNotNil(call(bridge, "notifications.cancel", ["id": mine])?["result"])
    }

    func testCancelAllLeavesOtherNotebooks() throws {
        let scheduler = FakeScheduler(.authorized)
        let bridge = bridge(scheduler)
        _ = schedule(bridge, "one")
        _ = schedule(bridge, "two")
        let theirs = try XCTUnwrap(schedule(bridge, "theirs", owner: 2))
        scheduler.others = [ScheduledNotification(id: "app", title: nil, body: "app's own", notebook: nil, date: nil)]
        XCTAssertNotNil(call(bridge, "notifications.cancelAll")?["result"])
        XCTAssertEqual(scheduler.scheduled.map(\.id), [theirs])
        XCTAssertEqual(scheduler.others.map(\.id), ["app"])
    }

    func testAKernelWithNoNotebookIsDenied() {
        let scheduler = FakeScheduler(.authorized)
        let bridge = bridge(scheduler)
        for method in ["notifications.schedule", "notifications.pending", "notifications.cancel", "notifications.cancelAll"] {
            XCTAssertEqual(errorCode(call(bridge, method, ["body": "x", "delay": 5, "id": "x"], owner: 3)), "denied", method)
        }
        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func testRemoteKernelsCantReachIt() {
        let bridge = bridge(FakeScheduler(.authorized))
        var answer: [String: Any]?
        bridge.respondRemote(to: ["id": 1, "owner": 1, "method": "notifications.schedule", "params": ["body": "x", "delay": 5]]) { answer = $0 }
        XCTAssertEqual(errorCode(answer), "unavailable")
    }

    func testSystemStatusMapping() {
        XCTAssertEqual(SystemNotificationScheduler.status(.notDetermined), .notDetermined)
        XCTAssertEqual(SystemNotificationScheduler.status(.denied), .denied)
        XCTAssertEqual(SystemNotificationScheduler.status(.authorized), .authorized)
        XCTAssertEqual(SystemNotificationScheduler.status(.provisional), .authorized)
    }
}
