import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// `device.notifications` (docs/protocol.md, "Notifications"): local
// notifications after a delay, over UNUserNotificationCenter. Each
// notification belongs to the notebook that scheduled it: `pending`,
// `cancel` and `cancelAll` see only the calling notebook's. Scheduling
// needs the notifications permission (and the ledger's grant); the rest
// needs only a notebook. The app turns the namespace on with
// `DeviceBridge.addNotifications()`.

/// One notification to schedule.
public struct NotificationRequest: Sendable, Equatable {
    /// The id the cell gets back, and the notification's identifier.
    public let id: String
    public let title: String?
    public let body: String
    /// Seconds from now, more than 0.
    public let delay: TimeInterval
    /// The notebook that scheduled it.
    public let notebook: String

    public init(id: String, title: String?, body: String, delay: TimeInterval, notebook: String) {
        self.id = id
        self.title = title
        self.body = body
        self.delay = delay
        self.notebook = notebook
    }
}

/// A notification scheduled and not yet delivered.
public struct ScheduledNotification: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let body: String
    /// The notebook that scheduled it; nil for one another part of the app scheduled.
    public let notebook: String?
    /// When it is due, when known.
    public let date: Date?

    public init(id: String, title: String?, body: String, notebook: String?, date: Date?) {
        self.id = id
        self.title = title
        self.body = body
        self.notebook = notebook
        self.date = date
    }
}

/// Schedules local notifications, and is their permission, behind a
/// protocol so tests needn't post any.
@MainActor
public protocol NotificationScheduler: Permission {
    /// Schedules `request`; `done` gets nil, or the error for the cell.
    func add(_ request: NotificationRequest, done: @escaping @MainActor (DeviceCallError?) -> Void)
    /// The app's notifications not yet delivered.
    func pending(_ done: @escaping @MainActor ([ScheduledNotification]) -> Void)
    /// Takes these off the schedule.
    func remove(_ ids: [String])
}

/// UNUserNotificationCenter. It reads the status when made and again
/// whenever the app becomes active (the person may have changed it in
/// System Settings), since the framework has no synchronous read. When
/// the app has no notification center delegate, it becomes one so a
/// notebook's notification shows while the app is in front.
@MainActor
public final class SystemNotificationScheduler: NSObject, NotificationScheduler, UNUserNotificationCenterDelegate {
    /// The userInfo key holding the notebook path.
    static let notebookKey = "ganymede.device.notebook"

    public private(set) var status: PermissionStatus = .notDetermined
    private var observer: NSObjectProtocol?

    override public init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        #if os(macOS)
        let active = NSApplication.didBecomeActiveNotification
        #else
        let active = UIApplication.didBecomeActiveNotification
        #endif
        observer = NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh(then done: (@MainActor (PermissionStatus) -> Void)? = nil) {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.status = Self.status(settings.authorizationStatus)
            done?(self.status)
        }
    }

    public func request(_ done: @escaping @MainActor (PermissionStatus) -> Void) {
        Task { @MainActor in
            // Throws only when the app can't ask at all; the status read after says what happened.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            self.refresh(then: done)
        }
    }

    static func status(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        // Provisional notifications go quietly to Notification Center: still a grant.
        case .authorized, .provisional: .authorized
        #if os(iOS)
        case .ephemeral: .authorized
        #endif
        @unknown default: .denied
        }
    }

    public func add(_ request: NotificationRequest, done: @escaping @MainActor (DeviceCallError?) -> Void) {
        let content = UNMutableNotificationContent()
        if let title = request.title { content.title = title }
        content.body = request.body
        content.sound = .default
        content.userInfo = [Self.notebookKey: request.notebook]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: request.delay, repeats: false)
        let note = UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)
        Task { @MainActor in
            do {
                try await UNUserNotificationCenter.current().add(note)
                done(nil)
            } catch let error as UNError where error.code == .notificationsNotAllowed {
                self.refresh()
                done(DeviceCallError("denied", "notifications.schedule: notifications aren't allowed for this app"))
            } catch {
                done(DeviceCallError("failed", "notifications.schedule: \(error.localizedDescription)"))
            }
        }
    }

    public func pending(_ done: @escaping @MainActor ([ScheduledNotification]) -> Void) {
        Task { @MainActor in
            let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            done(requests.map { request in
                ScheduledNotification(
                    id: request.identifier,
                    title: request.content.title.isEmpty ? nil : request.content.title,
                    body: request.content.body,
                    notebook: request.content.userInfo[Self.notebookKey] as? String,
                    date: (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate())
            })
        }
    }

    public func remove(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Shows a notification while the app is in front, which the system
    /// otherwise holds back.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension DeviceBridge {
    /// Turns on `device.notifications`: `hello` lists the trio and
    /// `notifications.schedule`, `pending`, `cancel` and `cancelAll`.
    /// `scheduler` is UNUserNotificationCenter by default.
    public func addNotifications(_ scheduler: NotificationScheduler? = nil) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        let scheduler = scheduler ?? SystemNotificationScheduler()
        addPermission("notifications", scheduler)
        addMethod("notifications.schedule", permission: "notifications", contextHandler: { params, context, reply in
            guard let notebook = context.notebook else {
                reply(.failure(Self.noNotebook("notifications.schedule")))
                return nil
            }
            guard let body = params["body"] as? String, !body.isEmpty else {
                reply(.failure(DeviceCallError("failed", "notifications.schedule needs a body")))
                return nil
            }
            let title = params["title"]
            guard title == nil || title is String else {
                reply(.failure(DeviceCallError("failed", "notifications.schedule: title must be a string")))
                return nil
            }
            guard let delay = (params["delay"] as? NSNumber)?.doubleValue, delay.isFinite, delay > 0 else {
                reply(.failure(DeviceCallError("failed", "notifications.schedule needs a delay in seconds, more than 0")))
                return nil
            }
            let id = UUID().uuidString
            let request = NotificationRequest(id: id, title: title as? String, body: body, delay: delay, notebook: notebook)
            scheduler.add(request) { error in
                if let error {
                    reply(.failure(error))
                } else {
                    reply(.success(id))
                }
            }
            return nil
        })
        addMethod("notifications.pending", contextHandler: { _, context, reply in
            guard let notebook = context.notebook else {
                reply(.failure(Self.noNotebook("notifications.pending")))
                return nil
            }
            scheduler.pending { all in
                reply(.success(all.filter { $0.notebook == notebook }.map(Self.notificationReply)))
            }
            return nil
        })
        addMethod("notifications.cancel", contextHandler: { params, context, reply in
            guard let notebook = context.notebook else {
                reply(.failure(Self.noNotebook("notifications.cancel")))
                return nil
            }
            guard let id = params["id"] as? String else {
                reply(.failure(DeviceCallError("failed", "notifications.cancel needs the id schedule returned")))
                return nil
            }
            scheduler.pending { all in
                // Only this notebook's: another notebook's id cancels nothing.
                if all.contains(where: { $0.id == id && $0.notebook == notebook }) { scheduler.remove([id]) }
                reply(.success(NSNull()))
            }
            return nil
        })
        addMethod("notifications.cancelAll", contextHandler: { _, context, reply in
            guard let notebook = context.notebook else {
                reply(.failure(Self.noNotebook("notifications.cancelAll")))
                return nil
            }
            scheduler.pending { all in
                let ids = all.filter { $0.notebook == notebook }.map(\.id)
                if !ids.isEmpty { scheduler.remove(ids) }
                reply(.success(NSNull()))
            }
            return nil
        })
    }

    private static func noNotebook(_ method: String) -> DeviceCallError {
        DeviceCallError("denied", "\(method): the app hasn't said which notebook this kernel runs")
    }

    private static func notificationReply(_ note: ScheduledNotification) -> [String: Any] {
        var reply: [String: Any] = ["id": note.id, "body": note.body]
        if let title = note.title { reply["title"] = title }
        if let date = note.date { reply["date"] = ISO8601DateFormatter().string(from: date) }
        return reply
    }
}
