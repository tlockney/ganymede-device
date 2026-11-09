import Foundation

// The permission core (docs/protocol.md, "Permissions"): one `Permission`
// per capability wraps its framework's status and request. A namespace
// added with `addPermission` answers `<namespace>.authorizationStatus` and
// `<namespace>.requestAuthorization`, and its methods (`addMethod`,
// `addStream` with `permission:`) ask lazily: the first call while the
// status is `notDetermined` shows the system prompt, and anything short of
// a grant rejects `denied`. An interrupt or abort while the prompt is up
// rejects the call `cancelled`; the late answer is ignored.

/// A capability's authorization, as the cell sees it. Partial grants are
/// grants: `limited` (contacts, photos), `writeOnly` (reminders, photos
/// add-only) and `reducedAccuracy` (approximate location).
public enum PermissionStatus: String, Sendable, CaseIterable {
    case notDetermined, denied, restricted, authorized, limited, writeOnly, reducedAccuracy

    /// Whether calls that need the permission may go ahead.
    public var isAuthorized: Bool {
        switch self {
        case .authorized, .limited, .writeOnly, .reducedAccuracy: true
        case .notDetermined, .denied, .restricted: false
        }
    }
}

/// One capability's system (TCC) permission, behind a protocol so tests
/// needn't show a prompt.
@MainActor
public protocol Permission: AnyObject {
    /// The current status, read without prompting.
    var status: PermissionStatus { get }
    /// Shows the system prompt when the status is `notDetermined`, and calls
    /// `done` once with the status after it; otherwise calls `done` with the
    /// status as it is.
    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void)
}

/// What an `addMethod` handler answers with: a value a reply carries, or an
/// error for the cell.
public typealias MethodReply = @MainActor (Result<Any, DeviceCallError>) -> Void

/// Runs one call of a method added with `addMethod`. Reply once. Return a
/// cancel action when the work can be stopped (a prompt, a sensor read),
/// or nil; after a cancel, a reply is ignored.
public typealias MethodHandler = @MainActor (_ params: [String: Any], _ reply: @escaping MethodReply) -> (() -> Void)?

/// Calls that answer later and aren't dialogs: permission requests, and
/// methods added with `addMethod`, while they wait on a prompt or their
/// handler. Each is answered once: by its outcome, or by a cancel.
@MainActor
final class PendingCalls {
    private final class Call {
        let owner: Int
        let reply: ([String: Any]) -> Void
        var cancel: (() -> Void)?

        init(owner: Int, reply: @escaping ([String: Any]) -> Void) {
            self.owner = owner
            self.reply = reply
        }
    }

    private var calls: [Int: Call] = [:]

    /// Tracks call `id`; false when one with that id is already waiting.
    func begin(_ id: Int, owner: Int, reply: @escaping ([String: Any]) -> Void) -> Bool {
        guard calls[id] == nil else { return false }
        calls[id] = Call(owner: owner, reply: reply)
        return true
    }

    /// Whether call `id` still waits (not cancelled, not answered).
    func isWaiting(_ id: Int) -> Bool { calls[id] != nil }

    /// What stops call `id`'s current step, replacing the last one.
    func setCancel(_ id: Int, _ cancel: (() -> Void)?) {
        calls[id]?.cancel = cancel
    }

    /// Answers call `id`, once; ignored after a cancel.
    func answer(_ id: Int, _ reply: [String: Any]) {
        calls.removeValue(forKey: id)?.reply(reply)
    }

    /// Rejects call `id` `cancelled` and stops what it waits on.
    func cancel(_ id: Int) {
        guard let call = calls.removeValue(forKey: id) else { return }
        call.cancel?()
        call.reply(DeviceBridge.error("cancelled", "the call was cancelled"))
    }

    /// Cancels the calls of each owner that `matches`.
    func cancel(owners matches: (Int) -> Bool) {
        for (id, call) in calls where matches(call.owner) {
            cancel(id)
        }
    }
}

/// The system prompts already showing, one per permission, so a second
/// call waits on the same prompt instead of asking again.
@MainActor
final class PermissionRequests {
    private var waiting: [ObjectIdentifier: [@MainActor (PermissionStatus) -> Void]] = [:]

    func request(_ permission: Permission, _ done: @escaping @MainActor (PermissionStatus) -> Void) {
        let key = ObjectIdentifier(permission)
        if waiting[key] != nil {
            waiting[key]?.append(done)
            return
        }
        waiting[key] = [done]
        permission.request { [weak self] status in
            let all = self?.waiting.removeValue(forKey: key) ?? []
            for done in all { done(status) }
        }
    }
}
