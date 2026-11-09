import EventKit
import Foundation

// `device.reminders` (docs/protocol.md, "Reminders"): the person's
// reminder lists, over EventKit. Every method needs the reminders
// permission (and the ledger's grant). With write-only access, `add`
// works and the methods that read (`calendars`, `list`, and `complete`,
// `uncomplete` and `delete`, which find the reminder first) reject
// `denied`. No recurrence, alarms or subtasks. The app turns the
// namespace on with `DeviceBridge.addReminders()`.

/// A reminder list.
public struct ReminderCalendar: Equatable, Sendable {
    public let id: String
    public let title: String
    /// Where `add` puts a reminder without a calendar.
    public let isDefault: Bool

    public init(id: String, title: String, isDefault: Bool) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
    }
}

/// One reminder, as cells see it.
public struct ReminderRecord: Equatable, Sendable {
    /// The store's identifier; empty for one not added yet.
    public var id: String
    public var title: String
    public var notes: String?
    /// The due day, with a time when the reminder has one.
    public var due: DateComponents?
    /// 0 for none, 1 (high) to 9 (low).
    public var priority: Int
    public var completed: Bool
    public var completedAt: Date?
    /// The list's id; for `add`, nil for the default list.
    public var calendar: String?

    public init(
        id: String = "", title: String, notes: String? = nil, due: DateComponents? = nil, priority: Int = 0,
        completed: Bool = false, completedAt: Date? = nil, calendar: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.due = due
        self.priority = priority
        self.completed = completed
        self.completedAt = completedAt
        self.calendar = calendar
    }
}

/// The reminders store, and its permission, behind a protocol so tests
/// needn't touch the person's reminders. Each `done` gets the result or
/// the error for the cell.
@MainActor
public protocol ReminderStore: Permission {
    func calendars(_ done: @escaping @MainActor (Result<[ReminderCalendar], DeviceCallError>) -> Void)
    /// The reminders in `calendar` (every list when nil): completed ones,
    /// incomplete ones, or both when `completed` is nil.
    func reminders(
        calendar: String?, completed: Bool?, done: @escaping @MainActor (Result<[ReminderRecord], DeviceCallError>) -> Void)
    /// Adds `reminder` (its `id` and completion are ignored) and answers its id.
    func add(_ reminder: ReminderRecord, done: @escaping @MainActor (Result<String, DeviceCallError>) -> Void)
    /// Marks the reminder `id` completed or not: true, or false when there is none.
    func setCompleted(_ id: String, _ completed: Bool, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void)
    /// Deletes the reminder `id`: true, or false when there is none.
    func delete(_ id: String, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void)
}

/// EventKit.
@MainActor
public final class SystemReminderStore: ReminderStore {
    private let store = EKEventStore()

    public init() {}

    public var status: PermissionStatus {
        Self.status(EKEventStore.authorizationStatus(for: .reminder))
    }

    static func status(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        // Without the usage description the system ends the app instead
        // of asking: answer with the status as it is.
        guard status == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil
        else {
            done(status)
            return
        }
        store.requestFullAccessToReminders { _, _ in
            Task { @MainActor in done(self.status) }
        }
    }

    public func calendars(_ done: @escaping @MainActor (Result<[ReminderCalendar], DeviceCallError>) -> Void) {
        let fallback = store.defaultCalendarForNewReminders()?.calendarIdentifier
        done(.success(store.calendars(for: .reminder).map {
            ReminderCalendar(id: $0.calendarIdentifier, title: $0.title, isDefault: $0.calendarIdentifier == fallback)
        }))
    }

    public func reminders(
        calendar: String?, completed: Bool?, done: @escaping @MainActor (Result<[ReminderRecord], DeviceCallError>) -> Void
    ) {
        var calendars: [EKCalendar]?
        if let calendar {
            guard let found = store.calendar(withIdentifier: calendar), found.allowedEntityTypes.contains(.reminder) else {
                done(.failure(DeviceCallError("failed", "reminders.list: there is no reminder list \(calendar)")))
                return
            }
            calendars = [found]
        }
        let predicate: NSPredicate
        switch completed {
        case true?:
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
        case false?:
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        case nil:
            predicate = store.predicateForReminders(in: calendars)
        }
        store.fetchReminders(matching: predicate) { found in
            // Read here: EKReminder isn't Sendable.
            let records = (found ?? []).map(Self.record)
            Task { @MainActor in done(.success(records)) }
        }
    }

    public func add(_ record: ReminderRecord, done: @escaping @MainActor (Result<String, DeviceCallError>) -> Void) {
        let reminder = EKReminder(eventStore: store)
        reminder.title = record.title
        reminder.notes = record.notes
        reminder.dueDateComponents = record.due
        reminder.priority = record.priority
        if let id = record.calendar {
            guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else {
                done(.failure(DeviceCallError("failed", "reminders.add: there is no reminder list \(id) to add to")))
                return
            }
            reminder.calendar = calendar
        } else {
            guard let calendar = store.defaultCalendarForNewReminders() else {
                done(.failure(DeviceCallError("failed", "reminders.add: there is no default reminder list")))
                return
            }
            reminder.calendar = calendar
        }
        do {
            try store.save(reminder, commit: true)
            done(.success(reminder.calendarItemIdentifier))
        } catch {
            done(.failure(DeviceCallError("failed", "reminders.add: \(error.localizedDescription)")))
        }
    }

    public func setCompleted(_ id: String, _ completed: Bool, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            done(.success(false))
            return
        }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            done(.success(true))
        } catch {
            done(.failure(DeviceCallError("failed", "reminders: \(error.localizedDescription)")))
        }
    }

    public func delete(_ id: String, done: @escaping @MainActor (Result<Bool, DeviceCallError>) -> Void) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            done(.success(false))
            return
        }
        do {
            try store.remove(reminder, commit: true)
            done(.success(true))
        } catch {
            done(.failure(DeviceCallError("failed", "reminders.delete: \(error.localizedDescription)")))
        }
    }

    nonisolated static func record(_ reminder: EKReminder) -> ReminderRecord {
        ReminderRecord(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
            notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 }, due: reminder.dueDateComponents,
            priority: reminder.priority, completed: reminder.isCompleted, completedAt: reminder.completionDate,
            calendar: reminder.calendar?.calendarIdentifier)
    }
}

extension DeviceBridge {
    /// Turns on `device.reminders` and the `reminders` trio. `store` is
    /// EventKit by default. The app needs
    /// `NSRemindersFullAccessUsageDescription` in its Info.plist and, on a
    /// sandboxed Mac, the `com.apple.security.personal-information.calendars`
    /// entitlement.
    public func addReminders(_ store: ReminderStore? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let store = store ?? SystemReminderStore()
        addPermission("reminders", store)
        /// Write-only access may add, not read.
        func reads(_ method: String, reply: MethodReply) -> Bool {
            guard store.status != .writeOnly else {
                reply(.failure(DeviceCallError("denied", "\(method): the app may only add reminders (write-only access)")))
                return false
            }
            return true
        }
        addMethod("reminders.calendars", permission: "reminders") { _, reply in
            guard reads("reminders.calendars", reply: reply) else { return nil }
            store.calendars { result in
                reply(result.map { lists in
                    lists.map { ["id": $0.id, "title": $0.title, "isDefault": $0.isDefault] } as Any
                })
            }
            return nil
        }
        addMethod("reminders.list", permission: "reminders", check: { _ = try Self.reminderListOptions($0) }) { params, reply in
            guard reads("reminders.list", reply: reply),
                  let options = try? Self.reminderListOptions(params) else { return nil }
            store.reminders(calendar: options.calendar, completed: options.completed) { result in
                reply(result.map { $0.map(Self.reminderReply) as Any })
            }
            return nil
        }
        addMethod("reminders.add", permission: "reminders", check: { _ = try Self.newReminder($0) }) { params, reply in
            do {
                store.add(try Self.newReminder(params)) { reply($0.map { $0 as Any }) }
            } catch {
                reply(.failure(error as? DeviceCallError ?? DeviceCallError("failed", "\(error)")))
            }
            return nil
        }
        for (method, completed) in [("reminders.complete", true), ("reminders.uncomplete", false)] {
            addMethod(method, permission: "reminders", check: { _ = try Self.reminderID(method, $0) }) { params, reply in
                guard reads(method, reply: reply) else { return nil }
                store.setCompleted((try? Self.reminderID(method, params)) ?? "", completed) { reply($0.map { $0 as Any }) }
                return nil
            }
        }
        addMethod("reminders.delete", permission: "reminders", check: { _ = try Self.reminderID("reminders.delete", $0) }) { params, reply in
            guard reads("reminders.delete", reply: reply) else { return nil }
            store.delete((try? Self.reminderID("reminders.delete", params)) ?? "") { reply($0.map { $0 as Any }) }
            return nil
        }
    }

    static func reminderID(_ method: String, _ params: [String: Any]) throws -> String {
        guard let id = params["id"] as? String, !id.isEmpty else {
            throw DeviceCallError("failed", "\(method) needs a reminder id")
        }
        return id
    }

    static func reminderListOptions(_ params: [String: Any]) throws -> (calendar: String?, completed: Bool?) {
        var calendar: String?
        if let value = params["calendar"], !(value is NSNull) {
            guard let text = value as? String, !text.isEmpty else {
                throw DeviceCallError("failed", "reminders.list: calendar must be a list id from calendars()")
            }
            calendar = text
        }
        var completed: Bool?
        if let value = params["completed"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw DeviceCallError("failed", "reminders.list: completed must be true or false")
            }
            completed = number.boolValue
        }
        return (calendar, completed)
    }

    /// `reminders.add`'s reminder: a title, and optional notes, due date,
    /// priority and list.
    static func newReminder(_ params: [String: Any]) throws -> ReminderRecord {
        func fail(_ message: String) -> DeviceCallError { DeviceCallError("failed", "reminders.add: \(message)") }
        guard let object = params["reminder"] as? [String: Any] else { throw fail("reminder must be an object") }
        func text(_ key: String) throws -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let text = value as? String else { throw fail("\(key) must be a string") }
            return text.isEmpty ? nil : text
        }
        guard let title = try text("title"), !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw fail("a reminder needs a title")
        }
        var reminder = ReminderRecord(title: title, notes: try text("notes"), calendar: try text("calendar"))
        if let due = try text("due") {
            guard let parts = dueParts(due) else {
                throw fail("due must be a date (YYYY-MM-DD) or an ISO 8601 date and time")
            }
            reminder.due = parts
        }
        if let value = object["priority"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let priority = Int(exactly: number.doubleValue), (0...9).contains(priority)
            else {
                throw fail("priority must be a whole number from 0 (none) to 9")
            }
            reminder.priority = priority
        }
        return reminder
    }

    /// A due day (`YYYY-MM-DD`), or a day and time (ISO 8601) in the
    /// device's time zone.
    static func dueParts(_ text: String) -> DateComponents? {
        if text.count == 10, let day = birthdayParts(text), day.year != nil {
            return day
        }
        guard let date = Dialog.parseDate(text) else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// `YYYY-MM-DD` for a day; ISO 8601 for a day and time.
    static func dueText(_ parts: DateComponents) -> String? {
        if parts.hour != nil {
            var calendar = Calendar.current
            if let zone = parts.timeZone { calendar.timeZone = zone }
            return calendar.date(from: parts).map(Dialog.formatDate)
        }
        return birthdayText(parts)
    }

    /// A reminder as the cell gets it: missing fields left out.
    static func reminderReply(_ reminder: ReminderRecord) -> [String: Any] {
        var reply: [String: Any] = [
            "id": reminder.id, "title": reminder.title, "completed": reminder.completed,
            "calendar": reminder.calendar ?? "",
        ]
        reply["notes"] = reminder.notes
        reply["due"] = reminder.due.flatMap(dueText)
        if reminder.priority != 0 { reply["priority"] = reminder.priority }
        reply["completedAt"] = reminder.completedAt.map(Dialog.formatDate)
        return reply
    }
}
