@testable import DeviceBridge
import XCTest

/// Reminders in memory, with the permission the test sets.
@MainActor
private final class FakeReminders: ReminderStore {
    var status: PermissionStatus
    var answer: PermissionStatus = .authorized
    var prompts = 0
    var lists = [ReminderCalendar(id: "inbox", title: "Reminders", isDefault: true), ReminderCalendar(id: "shop", title: "Shopping", isDefault: false)]
    var reminders: [ReminderRecord] = []
    private var next = 0

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

    func calendars(_ done: @escaping @MainActor (Result<[ReminderCalendar], DeviceCallError>) -> Void) {
        done(.success(lists))
    }

    func reminders(
        calendar: String?, completed: Bool?, done: @escaping @MainActor (Result<[ReminderRecord], DeviceCallError>) -> Void
    ) {
        done(.success(reminders.filter { r in
            (calendar.map { r.calendar == $0 } ?? true) && (completed.map { r.completed == $0 } ?? true)
        }))
    }

    func add(_ reminder: ReminderRecord, done: @escaping @MainActor (Result<String, DeviceCallError>) -> Void) {
        next += 1
        var added = reminder
        added.id = "r\(next)"
        added.calendar = reminder.calendar ?? "inbox"
        reminders.append(added)
        done(.success(added.id))
    }

    func setCompleted(_ id: String, _ completed: Bool, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return done(.success(false)) }
        reminders[index].completed = completed
        reminders[index].completedAt = completed ? Date(timeIntervalSince1970: 0) : nil
        done(.success(true))
    }

    func delete(_ id: String, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void) {
        let before = reminders.count
        reminders.removeAll { $0.id == id }
        done(.success(reminders.count != before))
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
final class RemindersTests: XCTestCase {
    private let prompter = Asking()
    private var nextID = 0

    private func bridge(_ store: FakeReminders) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = prompter
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.addReminders(store)
        return bridge
    }

    private func call(_ bridge: DeviceBridge, _ method: String, _ params: [String: Any] = [:]) -> [String: Any]? {
        nextID += 1
        var answer: [String: Any]?
        bridge.respond(to: ["id": nextID, "owner": 1, "method": method, "params": params]) { answer = $0 }
        return answer
    }

    private func errorCode(_ reply: [String: Any]?) -> String? {
        (reply?["error"] as? [String: Any])?["code"] as? String
    }

    func testHelloListsTheNamespace() {
        let capabilities = bridge(FakeReminders(.authorized)).capabilities
        for method in ["calendars", "list", "add", "complete", "uncomplete", "delete", "authorizationStatus", "requestAuthorization"] {
            XCTAssertTrue(capabilities.contains("reminders.\(method)"), method)
        }
    }

    func testAddListCompleteAndDelete() throws {
        let store = FakeReminders(.notDetermined)
        let bridge = bridge(store)
        let lists = try XCTUnwrap(call(bridge, "reminders.calendars")?["result"] as? [[String: Any]])
        XCTAssertEqual(lists.first?["isDefault"] as? Bool, true)
        XCTAssertEqual(store.prompts, 1)

        let id = try XCTUnwrap(call(bridge, "reminders.add", ["reminder": ["title": "Buy milk", "due": "2026-11-10", "priority": 1]])?["result"] as? String)
        XCTAssertEqual(store.reminders.first?.due, DateComponents(year: 2026, month: 11, day: 10))
        _ = call(bridge, "reminders.add", ["reminder": ["title": "Eggs", "calendar": "shop", "notes": "a dozen"]])

        let open = try XCTUnwrap(call(bridge, "reminders.list", ["completed": false])?["result"] as? [[String: Any]])
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open.first?["due"] as? String, "2026-11-10")
        XCTAssertEqual(open.first?["priority"] as? Int, 1)
        XCTAssertEqual(open.first?["calendar"] as? String, "inbox")
        XCTAssertNil(open.first?["notes"])
        XCTAssertEqual((call(bridge, "reminders.list", ["calendar": "shop"])?["result"] as? [Any])?.count, 1)

        XCTAssertEqual(call(bridge, "reminders.complete", ["id": id])?["result"] as? Bool, true)
        let done = try XCTUnwrap(call(bridge, "reminders.list", ["completed": true])?["result"] as? [[String: Any]])
        XCTAssertEqual(done.map { $0["id"] as? String }, [id])
        XCTAssertEqual(done.first?["completed"] as? Bool, true)
        XCTAssertNotNil(done.first?["completedAt"] as? String)
        XCTAssertEqual(call(bridge, "reminders.uncomplete", ["id": id])?["result"] as? Bool, true)
        XCTAssertEqual((call(bridge, "reminders.list", ["completed": true])?["result"] as? [Any])?.count, 0)

        XCTAssertEqual(call(bridge, "reminders.delete", ["id": id])?["result"] as? Bool, true)
        XCTAssertEqual(call(bridge, "reminders.delete", ["id": id])?["result"] as? Bool, false)
        XCTAssertEqual(call(bridge, "reminders.complete", ["id": id])?["result"] as? Bool, false)
    }

    func testADueTimeRoundTrips() throws {
        let store = FakeReminders(.authorized)
        let bridge = bridge(store)
        _ = call(bridge, "reminders.add", ["reminder": ["title": "Call", "due": "2026-11-10T17:30:00.000Z"]])
        XCTAssertNotNil(store.reminders.first?.due?.hour)
        let listed = call(bridge, "reminders.list")?["result"] as? [[String: Any]]
        let due = try XCTUnwrap(listed?.first?["due"] as? String)
        XCTAssertEqual(Dialog.parseDate(due), Dialog.parseDate("2026-11-10T17:30:00.000Z"))
    }

    func testWriteOnlyAddsButDoesntRead() {
        let store = FakeReminders(.writeOnly)
        let bridge = bridge(store)
        XCTAssertNotNil(call(bridge, "reminders.add", ["reminder": ["title": "x"]])?["result"] as? String)
        XCTAssertEqual(errorCode(call(bridge, "reminders.calendars")), "denied")
        XCTAssertEqual(errorCode(call(bridge, "reminders.list")), "denied")
        XCTAssertEqual(errorCode(call(bridge, "reminders.complete", ["id": "r1"])), "denied")
        XCTAssertEqual(errorCode(call(bridge, "reminders.delete", ["id": "r1"])), "denied")
        XCTAssertEqual(store.reminders.count, 1)
    }

    func testBadCallsFailBeforeAnyPrompt() {
        let store = FakeReminders(.notDetermined)
        let bridge = bridge(store)
        for (method, params) in [
            ("reminders.add", [:]),
            ("reminders.add", ["reminder": ["notes": "no title"]]),
            ("reminders.add", ["reminder": ["title": " "]]),
            ("reminders.add", ["reminder": ["title": "a", "due": "tomorrow"]]),
            ("reminders.add", ["reminder": ["title": "a", "due": "2026-02-30"]]),
            ("reminders.add", ["reminder": ["title": "a", "priority": 10]]),
            ("reminders.add", ["reminder": ["title": "a", "priority": true]]),
            ("reminders.list", ["completed": "yes"]),
            ("reminders.list", ["calendar": 3]),
            ("reminders.complete", [:]),
            ("reminders.uncomplete", ["id": ""]),
            ("reminders.delete", ["id": 1]),
        ] as [(String, [String: Any])] {
            XCTAssertEqual(errorCode(call(bridge, method, params)), "failed", "\(method) \(params)")
        }
        XCTAssertEqual(store.prompts, 0)
        XCTAssertEqual(prompter.asked, 0)
    }

    func testRefusals() {
        let store = FakeReminders(.notDetermined)
        store.answer = .denied
        XCTAssertEqual(errorCode(call(bridge(store), "reminders.list")), "denied")
        prompter.answer = .deny
        let asked = FakeReminders(.notDetermined)
        XCTAssertEqual(errorCode(call(bridge(asked), "reminders.add", ["reminder": ["title": "a"]])), "denied")
        XCTAssertEqual(asked.prompts, 0)
    }

    func testEventKitStatusesMap() {
        XCTAssertEqual(SystemReminderStore.status(.fullAccess), .authorized)
        XCTAssertEqual(SystemReminderStore.status(.writeOnly), .writeOnly)
        XCTAssertEqual(SystemReminderStore.status(.denied), .denied)
    }
}
