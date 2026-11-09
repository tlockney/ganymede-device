import Foundation
import JavaScriptCore

/// The engine side's id space: every engine context's owners and call ids
/// are below `-engineBase`, apart from the kernel page's (positive) and the
/// remote handler's (negative, above it), so a drop or cancel for one never
/// reaches another.
let engineBase = 1 << 40

/// One JavaScript engine context's link to the bridge, for kernels and
/// scripts with no web view (docs/phase-4.md, part 1). It installs
/// `__ganymedeDevice(message)`, which takes a message as JSON text, in the
/// form `webkitHost()` posts, and resolves with the reply as JSON text;
/// src/host.ts's `installHostDevice` is the engine's preload.
///
/// The context gets an owner of its own. Whatever owner its messages
/// name, this stamps its own on each, and maps its call ids to bridge-wide
/// ones, so code in one context can't reach another's streams, handles,
/// dialogs or ledger answers.
@MainActor
public final class EngineDevice {
    /// This context's owner in the bridge: `setNotebook(_:for:)` keys the
    /// ledger with it.
    public let owner: Int
    private weak var bridge: DeviceBridge?
    private weak var host: DialogHost?
    /// The context's call ids, to the bridge's, while a call is open.
    private var calls: [Int: Int] = [:]
    /// The same for the latest calls that answered, so a cancel that
    /// arrives after the answer still reaches the handle the call opened
    /// (docs/protocol.md, "Handles"). Oldest first; at most `keptAnswers`.
    private var answered: [(engine: Int, bridge: Int)] = []
    private let keptAnswers = 64
    private var released = false

    init(bridge: DeviceBridge, owner: Int, host: DialogHost?) {
        self.bridge = bridge
        self.owner = owner
        self.host = host
    }

    /// Defines `name` (`__ganymedeDevice` by default) in `context`'s global
    /// object. Call it, and evaluate the engine's scripts, on the main
    /// thread.
    public func install(in context: JSContext, name: String = "__ganymedeDevice") {
        let post: @convention(block) (String) -> JSValue = { [weak self] message in
            let context = JSContext.current()!
            return JSValue(newPromiseIn: context) { resolve, _ in
                nonisolated(unsafe) let resolve = resolve
                // The bridge runs on the main thread; an engine evaluating
                // elsewhere gets an error, not a crash.
                guard Thread.isMainThread else {
                    resolve?.call(withArguments: [Self.text(DeviceBridge.error("unavailable", "device calls must come from the main thread"))])
                    return
                }
                MainActor.assumeIsolated {
                    guard let self else {
                        resolve?.call(withArguments: [Self.text(DeviceBridge.error("unavailable", "the device link is gone"))])
                        return
                    }
                    self.respond(to: message) { reply in resolve?.call(withArguments: [reply]) }
                }
            }
        }
        context.setObject(post, forKeyedSubscript: name as NSString)
    }

    /// Answers one message as JSON text, now or later; `reply` is called
    /// once. What `__ganymedeDevice` does, without an engine.
    public func respond(to message: String, reply: @escaping (String) -> Void) {
        guard let bridge, !released else {
            return reply(Self.text(DeviceBridge.error("unavailable", "this engine's device link was released")))
        }
        guard let data = message.data(using: .utf8),
              var call = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return reply(Self.text(DeviceBridge.error("failed", "a device message must be a JSON object")))
        }
        call["owner"] = owner
        if call["release"] as? Bool == true {
            // Dialogs are kept by call id, not owner: close this context's.
            dropCalls(bridge)
            return reply(Self.text(bridge.handle(call)))
        }
        let engineID = DeviceBridge.callID(call["id"])
        if call["cancel"] as? Bool == true {
            guard let engineID, let id = calls[engineID] ?? answered.last(where: { $0.engine == engineID })?.bridge else {
                return reply(Self.text(["result": NSNull()]))
            }
            call["id"] = id
            return reply(Self.text(bridge.handle(call)))
        }
        var id: Int?
        if let engineID {
            id = bridge.nextEngineCall()
            calls[engineID] = id
            call["id"] = id
        } else {
            call.removeValue(forKey: "id")
        }
        bridge.respond(to: call, from: host) { [weak self] answer in
            if let engineID, let id, let self, self.calls[engineID] == id {
                self.calls.removeValue(forKey: engineID)
                self.answered.append((engineID, id))
                if self.answered.count > self.keptAnswers { self.answered.removeFirst() }
            }
            reply(Self.text(answer))
        }
    }

    /// Stops what this context opened (sounds, handles, streams, dialogs)
    /// and forgets its notebook. Later messages fail `unavailable`. Call it
    /// when the context goes away.
    public func release() {
        guard !released, let bridge else { return }
        // First, so a call the cell starts while what it waited on is
        // cancelled (JavaScriptCore can run its `catch` inside our reply)
        // is refused rather than lost.
        released = true
        dropCalls(bridge)
        _ = bridge.handle(["owner": owner, "release": true])
    }

    /// Closes the dialogs this context's open calls showed, which the
    /// bridge keeps by call id rather than owner, and forgets the calls.
    private func dropCalls(_ bridge: DeviceBridge) {
        // Taken first: closing a dialog answers its call, which can start
        // another in the same turn.
        let open = Set(calls.values)
        calls.removeAll()
        answered.removeAll()
        bridge.dialogs.drop { open.contains($0) }
    }

    static func text(_ reply: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(reply),
              let data = try? JSONSerialization.data(withJSONObject: reply),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"{"error":{"code":"failed","message":"the reply can't be sent as JSON"}}"#
        }
        return text
    }
}

extension DeviceBridge {
    /// A link for one engine context, with an owner of its own. `host` is
    /// the view whose window shows its dialogs; a headless run has none
    /// (and no presenter, so dialogs fail).
    public func engineDevice(host: DialogHost? = nil) -> EngineDevice {
        nextEngineOwner += 1
        return EngineDevice(bridge: self, owner: -(engineBase + nextEngineOwner), host: host)
    }

    /// A bridge-wide id for an engine context's call.
    func nextEngineCall() -> Int {
        nextEngineCallID += 1
        return -(engineBase + nextEngineCallID)
    }

    /// Whether `n` (an owner or a call id) belongs to an engine context.
    static func isEngine(_ n: Int) -> Bool { n <= -engineBase }
}
