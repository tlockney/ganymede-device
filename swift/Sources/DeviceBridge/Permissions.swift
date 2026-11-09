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
    /// status as it is. Always call `done`, even when the framework can't
    /// ask (a missing usage description): later calls for the permission
    /// wait on this one.
    func request(_ done: @escaping @MainActor (PermissionStatus) -> Void)
}

/// What an `addMethod` handler answers with: a value a reply carries, or an
/// error for the cell.
public typealias MethodReply = @MainActor (Result<Any, DeviceCallError>) -> Void

/// Runs one call of a method added with `addMethod`. Reply once. Return a
/// cancel action when the work can be stopped (a prompt, a sensor read),
/// or nil; after a cancel, a reply is ignored.
public typealias MethodHandler = @MainActor (_ params: [String: Any], _ reply: @escaping MethodReply) -> (() -> Void)?

/// Who made a call: the kernel (`owner`, its `webkitHost().owner`) and the
/// notebook the host said it runs (`DeviceBridge.setNotebook`), nil when
/// it hasn't said.
public struct CallContext: Sendable, Equatable {
    public let owner: Int
    public let notebook: String?

    public init(owner: Int, notebook: String?) {
        self.owner = owner
        self.notebook = notebook
    }
}

/// A `MethodHandler` that also gets the call's `CallContext`.
public typealias ContextMethodHandler = @MainActor (_ params: [String: Any], _ context: CallContext, _ reply: @escaping MethodReply) -> (() -> Void)?

/// One waiting call: its id, and which call with that id it is.
struct PendingCall: Hashable {
    let id: Int
    let serial: Int
}

/// Calls that answer later and aren't dialogs: permission requests, and
/// methods added with `addMethod`, while they wait on a prompt or their
/// handler. Each is answered once: by its outcome, or by a cancel.
@MainActor
final class PendingCalls {
    private final class Call {
        let owner: Int
        let serial: Int
        let reply: ([String: Any]) -> Void
        var cancel: (() -> Void)?

        init(owner: Int, serial: Int, reply: @escaping ([String: Any]) -> Void) {
            self.owner = owner
            self.serial = serial
            self.reply = reply
        }
    }

    private var calls: [Int: Call] = [:]
    private var serial = 0

    /// Tracks call `id`; nil when one with that id is already waiting.
    /// Steps that answer later hold on to the `PendingCall`, not the id:
    /// ids start over when the page reloads, so a step left over from a
    /// cancelled call must not reach a new call with the same id.
    func begin(_ id: Int, owner: Int, reply: @escaping ([String: Any]) -> Void) -> PendingCall? {
        guard calls[id] == nil else { return nil }
        serial += 1
        calls[id] = Call(owner: owner, serial: serial, reply: reply)
        return PendingCall(id: id, serial: serial)
    }

    private func current(_ call: PendingCall) -> Call? {
        guard let found = calls[call.id], found.serial == call.serial else { return nil }
        return found
    }

    /// Whether `call` still waits (not cancelled, not answered).
    func isWaiting(_ call: PendingCall) -> Bool { current(call) != nil }

    /// What stops `call`'s current step, replacing the last one.
    func setCancel(_ call: PendingCall, _ cancel: (() -> Void)?) {
        current(call)?.cancel = cancel
    }

    /// Answers `call`, once; ignored after a cancel.
    func answer(_ call: PendingCall, _ reply: [String: Any]) {
        guard current(call) != nil else { return }
        calls.removeValue(forKey: call.id)?.reply(reply)
    }

    /// Rejects call `id` `cancelled` and stops what it waits on.
    func cancel(_ id: Int) {
        guard let call = calls.removeValue(forKey: id) else { return }
        call.cancel?()
        call.reply(DeviceBridge.error("cancelled", "the call was cancelled"))
    }

    /// Cancels the calls of each owner that `matches`; their ids.
    @discardableResult
    func cancel(owners matches: (Int) -> Bool) -> [Int] {
        let ids = calls.filter { matches($0.value.owner) }.map { $0.key }
        for id in ids { cancel(id) }
        return ids
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
