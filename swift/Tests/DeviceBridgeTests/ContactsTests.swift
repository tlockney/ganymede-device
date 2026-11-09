@testable import DeviceBridge
import XCTest

/// Contacts in memory, with the permission the test sets.
@MainActor
private final class FakeContacts: ContactStore {
    var status: PermissionStatus
    var answer: PermissionStatus = .authorized
    var prompts = 0
    var contacts: [ContactRecord] = []
    var failure: DeviceCallError?
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

    func search(_ query: String, done: @escaping @MainActor (Result<[ContactRecord], DeviceCallError>) -> Void) {
        if let failure { return done(.failure(failure)) }
        done(.success(contacts.filter { [$0.givenName, $0.familyName].contains { $0?.localizedCaseInsensitiveContains(query) == true } }))
    }

    func contact(_ id: String, done: @escaping @MainActor (Result<ContactRecord?, DeviceCallError>) -> Void) {
        done(.success(contacts.first { $0.id == id }))
    }

    func all(_ done: @escaping @MainActor (Result<[ContactRecord], DeviceCallError>) -> Void) {
        done(.success(contacts))
    }

    func add(_ contact: ContactRecord, done: @escaping @MainActor (Result<String, DeviceCallError>) -> Void) {
        if let failure { return done(.failure(failure)) }
        next += 1
        var added = contact
        added.id = "c\(next)"
        contacts.append(added)
        done(.success(added.id))
    }

    func delete(_ id: String, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void) {
        let before = contacts.count
        contacts.removeAll { $0.id == id }
        done(.success(contacts.count != before))
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
final class ContactsTests: XCTestCase {
    private let prompter = Asking()
    private var nextID = 0

    private func bridge(_ store: FakeContacts) -> DeviceBridge {
        let bridge = DeviceBridge(clipboard: nil, ledger: PermissionLedger(store: MemoryLedgerStore()), appVersion: "")
        bridge.ledgerPrompter = prompter
        bridge.setNotebook("a.ipynb", for: 1)
        bridge.addContacts(store)
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
        let capabilities = bridge(FakeContacts(.authorized)).capabilities
        for method in ["search", "get", "all", "add", "delete", "authorizationStatus", "requestAuthorization"] {
            XCTAssertTrue(capabilities.contains("contacts.\(method)"), method)
        }
    }

    func testAddSearchGetAndDelete() throws {
        let store = FakeContacts(.notDetermined)
        let bridge = bridge(store)
        let contact: [String: Any] = [
            "givenName": "Ada", "familyName": "Lovelace", "organization": "Analytical",
            "emails": [["label": "work", "value": "ada@example.com"]],
            "phones": [["value": "+44 20 7946 0000"]],
            "addresses": [["label": "home", "city": "London", "country": "UK"]],
            "birthday": "1815-12-10",
        ]
        let id = try XCTUnwrap(call(bridge, "contacts.add", ["contact": contact])?["result"] as? String)
        XCTAssertEqual(store.prompts, 1)
        XCTAssertEqual(prompter.asked, 1)
        XCTAssertEqual(store.contacts.first?.birthday, DateComponents(year: 1815, month: 12, day: 10))

        let found = try XCTUnwrap(call(bridge, "contacts.search", ["query": "ada"])?["result"] as? [[String: Any]])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?["id"] as? String, id)
        XCTAssertEqual(found.first?["birthday"] as? String, "1815-12-10")
        XCTAssertEqual((found.first?["emails"] as? [[String: Any]])?.first?["label"] as? String, "work")
        XCTAssertNil(found.first?["middleName"], "missing fields are left out")
        XCTAssertEqual((found.first?["addresses"] as? [[String: Any]])?.first?["city"] as? String, "London")

        let got = call(bridge, "contacts.get", ["id": id])?["result"] as? [String: Any]
        XCTAssertEqual(got?["familyName"] as? String, "Lovelace")
        XCTAssertEqual((call(bridge, "contacts.all")?["result"] as? [Any])?.count, 1)

        XCTAssertEqual(call(bridge, "contacts.delete", ["id": id])?["result"] as? Bool, true)
        XCTAssertEqual(call(bridge, "contacts.delete", ["id": id])?["result"] as? Bool, false, "already gone")
        XCTAssertTrue(call(bridge, "contacts.get", ["id": id])?["result"] is NSNull)
    }

    func testABirthdayWithoutAYear() throws {
        let store = FakeContacts(.authorized)
        let bridge = bridge(store)
        _ = call(bridge, "contacts.add", ["contact": ["givenName": "B", "birthday": "--02-29"]])
        XCTAssertEqual(store.contacts.first?.birthday, DateComponents(month: 2, day: 29))
        XCTAssertEqual((call(bridge, "contacts.all")?["result"] as? [[String: Any]])?.first?["birthday"] as? String, "--02-29")
    }

    func testBadCallsFailBeforeAnyPrompt() {
        let store = FakeContacts(.notDetermined)
        let bridge = bridge(store)
        for (method, params) in [
            ("contacts.search", [:]),
            ("contacts.search", ["query": "  "]),
            ("contacts.get", ["id": 3]),
            ("contacts.delete", [:]),
            ("contacts.add", [:]),
            ("contacts.add", ["contact": [String: Any]()]),
            ("contacts.add", ["contact": ["givenName": 1]]),
            ("contacts.add", ["contact": ["givenName": "A", "emails": ["a@b.c"]]]),
            ("contacts.add", ["contact": ["givenName": "A", "phones": [["label": "home"]]]]),
            ("contacts.add", ["contact": ["givenName": "A", "birthday": "10/12/1815"]]),
            ("contacts.add", ["contact": ["givenName": "A", "birthday": "1815-13-10"]]),
        ] as [(String, [String: Any])] {
            XCTAssertEqual(errorCode(call(bridge, method, params)), "failed", "\(method) \(params)")
        }
        XCTAssertEqual(store.prompts, 0)
        XCTAssertEqual(prompter.asked, 0)
    }

    func testRefusals() {
        let store = FakeContacts(.notDetermined)
        store.answer = .denied
        XCTAssertEqual(errorCode(call(bridge(store), "contacts.all")), "denied")
        XCTAssertEqual(errorCode(call(bridge(FakeContacts(.restricted)), "contacts.all")), "denied")

        prompter.answer = .deny
        let asked = FakeContacts(.notDetermined)
        XCTAssertEqual(errorCode(call(bridge(asked), "contacts.search", ["query": "a"])), "denied")
        XCTAssertEqual(asked.prompts, 0, "the ledger refuses before the system asks")
    }

    func testLimitedAccessIsAGrant() {
        let store = FakeContacts(.limited)
        store.contacts = [ContactRecord(id: "x", givenName: "Shared")]
        XCTAssertEqual((call(bridge(store), "contacts.all")?["result"] as? [Any])?.count, 1)
    }

    func testAStoreFailureReachesTheCell() {
        let store = FakeContacts(.authorized)
        store.failure = DeviceCallError("failed", "contacts.add: the store is read-only")
        XCTAssertEqual(errorCode(call(bridge(store), "contacts.add", ["contact": ["givenName": "A"]])), "failed")
    }

    func testFrameworkLabelsReadAsPlainWords() {
        XCTAssertEqual(SystemContactStore.label("_$!<Home>!$_"), "home")
        XCTAssertEqual(SystemContactStore.label("Gym"), "Gym")
        XCTAssertNil(SystemContactStore.label(""))
        XCTAssertEqual(SystemContactStore.label(SystemContactStore.cnLabel("Mobile")), "mobile")
        XCTAssertEqual(SystemContactStore.cnLabel("Gym"), "Gym")
    }

    func testTheFrameworksStatusesMap() {
        XCTAssertEqual(SystemContactStore.status(.notDetermined), .notDetermined)
        XCTAssertEqual(SystemContactStore.status(.denied), .denied)
        XCTAssertEqual(SystemContactStore.status(.authorized), .authorized)
    }
}
