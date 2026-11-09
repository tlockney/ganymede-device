import Contacts
import Foundation

// `device.contacts` (docs/protocol.md, "Contacts"): search, read, add and
// delete contacts over the Contacts framework. Every method needs the
// contacts permission (and the ledger's grant). With limited access
// (iPhone and iPad), the framework shows only the contacts the person
// shared with the app. Groups and containers aren't wrapped: `add` puts a
// contact in the default container. The app turns the namespace on with
// `DeviceBridge.addContacts()`.

/// A label and a value, such as a work email.
public struct LabeledValue: Equatable, Sendable {
    /// `home`, `work`, `mobile`, `main`, `iPhone`, `other`, or the
    /// person's own label; nil for none.
    public var label: String?
    public var value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

/// A postal address.
public struct ContactAddress: Equatable, Sendable {
    public var label: String?
    public var street: String?
    public var city: String?
    public var state: String?
    public var postalCode: String?
    public var country: String?

    public init(
        label: String? = nil, street: String? = nil, city: String? = nil, state: String? = nil,
        postalCode: String? = nil, country: String? = nil
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
    }
}

/// One contact, as cells see it: every field but `id` may be missing.
public struct ContactRecord: Equatable, Sendable {
    /// The store's identifier; empty for one not added yet.
    public var id: String
    public var givenName: String?
    public var middleName: String?
    public var familyName: String?
    public var nickname: String?
    public var organization: String?
    public var jobTitle: String?
    public var emails: [LabeledValue]
    public var phones: [LabeledValue]
    public var addresses: [ContactAddress]
    /// Month and day, and the year when known.
    public var birthday: DateComponents?

    public init(
        id: String = "", givenName: String? = nil, middleName: String? = nil, familyName: String? = nil,
        nickname: String? = nil, organization: String? = nil, jobTitle: String? = nil,
        emails: [LabeledValue] = [], phones: [LabeledValue] = [], addresses: [ContactAddress] = [],
        birthday: DateComponents? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.jobTitle = jobTitle
        self.emails = emails
        self.phones = phones
        self.addresses = addresses
        self.birthday = birthday
    }
}

/// The contacts store, and its permission, behind a protocol so tests
/// needn't touch the person's contacts. Each `done` gets the result or
/// the error for the cell.
@MainActor
public protocol ContactStore: Permission {
    /// Contacts whose name matches `query`, or whose email or phone
    /// number does when `query` is one.
    func search(_ query: String, done: @escaping @MainActor (Result<[ContactRecord], DeviceCallError>) -> Void)
    /// The contact with `id`, nil when there is none.
    func contact(_ id: String, done: @escaping @MainActor (Result<ContactRecord?, DeviceCallError>) -> Void)
    func all(_ done: @escaping @MainActor (Result<[ContactRecord], DeviceCallError>) -> Void)
    /// Adds `contact` (its `id` is ignored) and answers its new id.
    func add(_ contact: ContactRecord, done: @escaping @MainActor (Result<String, DeviceCallError>) -> Void)
    /// Deletes the contact with `id`: true, or false when there is none.
    func delete(_ id: String, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void)
}

/// The Contacts framework. Fetches and saves run off the main thread.
@MainActor
public final class SystemContactStore: ContactStore {
    private let store = CNContactStore()
    private let queue = DispatchQueue(label: "ganymede.device.contacts")

    public init() {}

    public var status: PermissionStatus {
        Self.status(CNContactStore.authorizationStatus(for: .contacts))
    }

    static func status(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        #if os(iOS)
        case .limited: .limited
        #endif
        @unknown default: .denied
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        // Without the usage description the system ends the app instead
        // of asking: answer with the status as it is.
        guard status == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
        else {
            done(status)
            return
        }
        store.requestAccess(for: .contacts) { _, _ in
            Task { @MainActor in done(self.status) }
        }
    }

    public func search(_ query: String, done: @escaping @MainActor (Result<[ContactRecord], DeviceCallError>) -> Void) {
        run("contacts.search", done) { store in
            try store.unifiedContacts(matching: Self.predicate(query), keysToFetch: Self.keys).map(Self.record)
        }
    }

    public func contact(_ id: String, done: @escaping @MainActor (Result<ContactRecord?, DeviceCallError>) -> Void) {
        run("contacts.get", done) { store in
            do {
                return Self.record(try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys))
            } catch let error as CNError where error.code == .recordDoesNotExist {
                return nil
            }
        }
    }

    public func all(_ done: @escaping @MainActor (Result<[ContactRecord], DeviceCallError>) -> Void) {
        run("contacts.all", done) { store in
            var all: [ContactRecord] = []
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            request.sortOrder = .userDefault
            try store.enumerateContacts(with: request) { contact, _ in all.append(Self.record(contact)) }
            return all
        }
    }

    public func add(_ contact: ContactRecord, done: @escaping @MainActor (Result<String, DeviceCallError>) -> Void) {
        run("contacts.add", done) { store in
            let new = Self.contact(contact)
            let save = CNSaveRequest()
            save.add(new, toContainerWithIdentifier: nil)
            try store.execute(save)
            return new.identifier
        }
    }

    public func delete(_ id: String, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void) {
        run("contacts.delete", done) { store in
            let found: CNContact
            do {
                found = try store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            } catch let error as CNError where error.code == .recordDoesNotExist {
                return false
            }
            guard let mutable = found.mutableCopy() as? CNMutableContact else { return false }
            let save = CNSaveRequest()
            save.delete(mutable)
            try store.execute(save)
            return true
        }
    }

    /// Runs `work` off the main thread, and answers on it.
    private func run<T: Sendable>(
        _ method: String, _ done: @escaping @MainActor (Result<T, DeviceCallError>) -> Void,
        _ work: @escaping @Sendable (CNContactStore) throws -> T
    ) {
        nonisolated(unsafe) let store = store
        queue.async {
            let result: Result<T, DeviceCallError>
            do {
                result = .success(try work(store))
            } catch {
                result = .failure(DeviceCallError("failed", "\(method): \(error.localizedDescription)"))
            }
            Task { @MainActor in done(result) }
        }
    }

    nonisolated private static var keys: [CNKeyDescriptor] { [
        CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
        CNContactNicknameKey, CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactEmailAddressesKey,
        CNContactPhoneNumbersKey, CNContactPostalAddressesKey, CNContactBirthdayKey,
    ].map { $0 as CNKeyDescriptor } }

    nonisolated static func predicate(_ query: String) -> NSPredicate {
        if query.contains("@") { return CNContact.predicateForContacts(matchingEmailAddress: query) }
        let digits = query.filter(\.isNumber)
        if digits.count >= 3, query.allSatisfy({ $0.isNumber || " +-().".contains($0) }) {
            return CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        }
        return CNContact.predicateForContacts(matchingName: query)
    }

    nonisolated static func record(_ contact: CNContact) -> ContactRecord {
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        return ContactRecord(
            id: contact.identifier,
            givenName: text(contact.givenName),
            middleName: text(contact.middleName),
            familyName: text(contact.familyName),
            nickname: text(contact.nickname),
            organization: text(contact.organizationName),
            jobTitle: text(contact.jobTitle),
            emails: contact.emailAddresses.map { LabeledValue(label: label($0.label), value: $0.value as String) },
            phones: contact.phoneNumbers.map { LabeledValue(label: label($0.label), value: $0.value.stringValue) },
            addresses: contact.postalAddresses.map { item in
                let address = item.value
                return ContactAddress(
                    label: label(item.label), street: text(address.street), city: text(address.city),
                    state: text(address.state), postalCode: text(address.postalCode), country: text(address.country))
            },
            birthday: contact.birthday.map { DateComponents(year: $0.year, month: $0.month, day: $0.day) }
        )
    }

    nonisolated static func contact(_ record: ContactRecord) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = record.givenName ?? ""
        contact.middleName = record.middleName ?? ""
        contact.familyName = record.familyName ?? ""
        contact.nickname = record.nickname ?? ""
        contact.organizationName = record.organization ?? ""
        contact.jobTitle = record.jobTitle ?? ""
        contact.emailAddresses = record.emails.map { CNLabeledValue(label: cnLabel($0.label), value: $0.value as NSString) }
        contact.phoneNumbers = record.phones.map {
            CNLabeledValue(label: cnLabel($0.label), value: CNPhoneNumber(stringValue: $0.value))
        }
        contact.postalAddresses = record.addresses.map { item in
            let address = CNMutablePostalAddress()
            address.street = item.street ?? ""
            address.city = item.city ?? ""
            address.state = item.state ?? ""
            address.postalCode = item.postalCode ?? ""
            address.country = item.country ?? ""
            return CNLabeledValue(label: cnLabel(item.label), value: address as CNPostalAddress)
        }
        contact.birthday = record.birthday
        return contact
    }

    /// The framework's own labels, as plain words.
    nonisolated private static let labels: [(String, String)] = [
        ("home", CNLabelHome), ("work", CNLabelWork), ("other", CNLabelOther), ("school", CNLabelSchool),
        ("mobile", CNLabelPhoneNumberMobile), ("main", CNLabelPhoneNumberMain), ("iPhone", CNLabelPhoneNumberiPhone),
    ]

    nonisolated static func label(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        if let plain = labels.first(where: { $0.1 == label })?.0 { return plain }
        // Another of the framework's labels, such as `_$!<HomeFAX>!$_`:
        // the word inside.
        if label.hasPrefix("_$!<"), label.hasSuffix(">!$_"), label.count > 8 {
            return String(label.dropFirst(4).dropLast(4))
        }
        return label
    }

    nonisolated static func cnLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        return labels.first { $0.0.caseInsensitiveCompare(label) == .orderedSame }?.1 ?? label
    }
}

extension DeviceBridge {
    /// Turns on `device.contacts` and the `contacts` trio. `store` is the
    /// Contacts framework by default. The app needs
    /// `NSContactsUsageDescription` in its Info.plist and, on a sandboxed
    /// Mac, the `com.apple.security.personal-information.addressbook`
    /// entitlement.
    public func addContacts(_ store: ContactStore? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let store = store ?? SystemContactStore()
        addPermission("contacts", store)
        addMethod("contacts.search", permission: "contacts", check: { _ = try Self.contactQuery($0) }) { params, reply in
            store.search((try? Self.contactQuery(params)) ?? "") { reply($0.map { $0.map(Self.contactReply) as Any }) }
            return nil
        }
        addMethod("contacts.get", permission: "contacts", check: { _ = try Self.contactID("contacts.get", $0) }) { params, reply in
            store.contact((try? Self.contactID("contacts.get", params)) ?? "") { result in
                reply(result.map { record -> Any in
                    if let record { return Self.contactReply(record) }
                    return NSNull()
                })
            }
            return nil
        }
        addMethod("contacts.all", permission: "contacts") { _, reply in
            store.all { reply($0.map { $0.map(Self.contactReply) as Any }) }
            return nil
        }
        addMethod("contacts.add", permission: "contacts", check: { _ = try Self.newContact($0) }) { params, reply in
            do {
                store.add(try Self.newContact(params)) { reply($0.map { $0 as Any }) }
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(error)")))
            }
            return nil
        }
        addMethod("contacts.delete", permission: "contacts", check: { _ = try Self.contactID("contacts.delete", $0) }) { params, reply in
            store.delete((try? Self.contactID("contacts.delete", params)) ?? "") { reply($0.map { $0 as Any }) }
            return nil
        }
    }

    static func contactQuery(_ params: [String: Any]) throws -> String {
        guard let query = params["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeviceCallError("failed", "contacts.search needs a query")
        }
        return query
    }

    static func contactID(_ method: String, _ params: [String: Any]) throws -> String {
        guard let id = params["id"] as? String, !id.isEmpty else {
            throw DeviceCallError("failed", "\(method) needs a contact id")
        }
        return id
    }

    /// `contacts.add`'s contact: known fields of the right types, and at
    /// least a name, an organization, an email or a phone number.
    static func newContact(_ params: [String: Any]) throws -> ContactRecord {
        func fail(_ message: String) -> DeviceCallError { DeviceCallError("failed", "contacts.add: \(message)") }
        guard let object = params["contact"] as? [String: Any] else { throw fail("contact must be an object") }
        func text(_ key: String, in object: [String: Any]) throws -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw fail("\(key) must be a string") }
            return text.isEmpty ? nil : text
        }
        func list(_ key: String) throws -> [[String: Any]] {
            guard let value = object[key], !(value is NSNull) else { return [] }
            guard let items = value as? [Any], let objects = items as? [[String: Any]] else {
                throw fail("\(key) must be an array of objects")
            }
            return objects
        }
        func labeled(_ key: String) throws -> [LabeledValue] {
            try list(key).map { item in
                guard let value = try text("value", in: item) else { throw fail("each of \(key) needs a value string") }
                return LabeledValue(label: try text("label", in: item), value: value)
            }
        }
        var contact = ContactRecord(
            givenName: try text("givenName", in: object), middleName: try text("middleName", in: object), familyName: try text("familyName", in: object),
            nickname: try text("nickname", in: object), organization: try text("organization", in: object), jobTitle: try text("jobTitle", in: object),
            emails: try labeled("emails"), phones: try labeled("phones"),
            addresses: try list("addresses").map { item in
                ContactAddress(
                    label: try text("label", in: item), street: try text("street", in: item), city: try text("city", in: item),
                    state: try text("state", in: item), postalCode: try text("postalCode", in: item),
                    country: try text("country", in: item))
            }
        )
        if let birthday = try text("birthday", in: object) {
            guard let parts = birthdayParts(birthday) else { throw fail("birthday must be YYYY-MM-DD, or --MM-DD without a year") }
            contact.birthday = parts
        }
        guard contact.givenName != nil || contact.familyName != nil || contact.nickname != nil
            || contact.organization != nil || !contact.emails.isEmpty || !contact.phones.isEmpty
        else {
            throw fail("a contact needs a name, an organization, an email or a phone number")
        }
        return contact
    }

    /// `YYYY-MM-DD`, or `--MM-DD` for a birthday without a year.
    static func birthdayParts(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        let year: Int?
        let rest: [Substring]
        if parts.count == 4, parts[0].isEmpty, parts[1].isEmpty {
            year = nil
            rest = Array(parts[2...])
        } else if parts.count == 3, parts[0].count == 4, let y = Int(parts[0]) {
            year = y
            rest = Array(parts[1...])
        } else {
            return nil
        }
        guard rest.count == 2, rest.allSatisfy({ $0.count == 2 }),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let month = Int(rest[0]), let day = Int(rest[1])
        else { return nil }
        // A real day: 2023-02-31 isn't one; --02-29 is, in a leap year.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let check = DateComponents(year: year ?? 2000, month: month, day: day)
        guard let date = calendar.date(from: check),
              calendar.dateComponents([.year, .month, .day], from: date) == check
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    static func birthdayText(_ parts: DateComponents) -> String? {
        guard let month = parts.month, let day = parts.day else { return nil }
        let monthDay = String(format: "%02d-%02d", month, day)
        return parts.year.map { String(format: "%04d-", $0) + monthDay } ?? "--" + monthDay
    }

    /// A contact as the cell gets it: missing fields and empty lists left out.
    static func contactReply(_ contact: ContactRecord) -> [String: Any] {
        var reply: [String: Any] = ["id": contact.id]
        let fields: [(String, String?)] = [
            ("givenName", contact.givenName), ("middleName", contact.middleName), ("familyName", contact.familyName),
            ("nickname", contact.nickname), ("organization", contact.organization), ("jobTitle", contact.jobTitle),
        ]
        for (key, value) in fields { reply[key] = value }
        func labeled(_ items: [LabeledValue]) -> [[String: Any]] {
            items.map { item in
                var entry: [String: Any] = ["value": item.value]
                entry["label"] = item.label
                return entry
            }
        }
        if !contact.emails.isEmpty { reply["emails"] = labeled(contact.emails) }
        if !contact.phones.isEmpty { reply["phones"] = labeled(contact.phones) }
        if !contact.addresses.isEmpty {
            reply["addresses"] = contact.addresses.map { address in
                var entry: [String: Any] = [:]
                entry["label"] = address.label
                entry["street"] = address.street
                entry["city"] = address.city
                entry["state"] = address.state
                entry["postalCode"] = address.postalCode
                entry["country"] = address.country
                return entry
            }
        }
        reply["birthday"] = contact.birthday.flatMap(birthdayText)
        return reply
    }
}
