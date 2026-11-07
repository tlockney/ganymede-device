import WebKit

/// The bridge's second handler, for kernels that aren't in the app
/// (docs/protocol.md, "Over a Jupyter comm"): the notebook page answers a
/// remote kernel's comm (`answerDevice` in src/frontend.ts) and posts the
/// calls here. That page also renders notebook outputs, so this handler
/// takes only the remote subset, the methods that need no permission
/// (docs/plan.md, "The remote subset"), and only from the main frame.
extension DeviceBridge {
    /// The name `webkitForward()` posts to.
    public static let remoteHandlerName = "deviceRemote"

    /// What a remote kernel may call: the methods whose `remote` column in
    /// src/support.ts isn't `no`. test/swift.test.ts checks the two agree.
    public static let remoteMethods: Set<String> = [
        "info", "clipboard.readText", "clipboard.writeText", "clipboard.readImage", "clipboard.writeImage",
        "haptics.impact", "haptics.notification", "haptics.selection", "openURL",
        "ui.alert", "ui.confirm", "ui.prompt", "ui.actionSheet", "ui.pickDate",
        "share", "preview", "files.pick", "files.export", "photos.pick", "sound.play",
    ]

    /// Adds the remote handler to `controller`, in the page's content world.
    /// Only main-frame messages for which `allow` is true reach the bridge:
    /// check the page's origin there.
    public func registerRemote(
        in controller: WKUserContentController,
        allow: @escaping @MainActor (WKScriptMessage) -> Bool = { _ in true }
    ) {
        controller.addScriptMessageHandler(
            RemoteHandler(bridge: self, allow: allow), contentWorld: .page, name: Self.remoteHandlerName)
    }

    /// Answers one message from the remote handler, as `respond(to:from:reply:)`
    /// does, but only for the remote subset. Its ids and owners are kept apart
    /// from the kernel page's (both count up from 1), so a cancel from one
    /// page never closes the other's dialog, and a release never stops the
    /// other's sounds. `hello` lists only the remote subset.
    public func respondRemote(to body: Any, from host: DialogHost? = nil, reply: @escaping ([String: Any]) -> Void) {
        guard var call = body as? [String: Any] else {
            reply(Self.error("failed", "a device message must be an object"))
            return
        }
        for key in ["id", "owner"] where call[key] != nil {
            guard let n = Self.callID(call[key]), n > 0 else {
                reply(Self.error("failed", "a remote call's \(key) must be a positive integer"))
                return
            }
            call[key] = -n
        }
        if call["cancel"] as? Bool == true || call["release"] as? Bool == true {
            reply(handle(call))
            return
        }
        guard let method = call["method"] as? String else {
            reply(Self.error("failed", "a device call needs a method"))
            return
        }
        if method == "hello" {
            var answer = handle(call)
            if var hello = answer["result"] as? [String: Any] {
                hello["capabilities"] = capabilities.filter { Self.remoteMethods.contains($0) }
                answer["result"] = hello
            }
            reply(answer)
            return
        }
        guard Self.remoteMethods.contains(method) else {
            reply(Self.error("unavailable", "\(method) isn't available to a remote kernel"))
            return
        }
        respond(to: call, from: host, reply: reply)
    }
}

/// The remote handler. Weak, so the content controller, which keeps its
/// handlers, doesn't keep the bridge.
@MainActor
private final class RemoteHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: DeviceBridge?
    let allow: @MainActor (WKScriptMessage) -> Bool

    init(bridge: DeviceBridge, allow: @escaping @MainActor (WKScriptMessage) -> Bool) {
        self.bridge = bridge
        self.allow = allow
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // Output frames get the page's handlers too; only the page itself
        // may call.
        guard message.frameInfo.isMainFrame, allow(message), let bridge else {
            replyHandler(DeviceBridge.error("unavailable", "device calls are taken from the notebook page only"), nil)
            return
        }
        bridge.respondRemote(to: message.body, from: message.webView) { replyHandler($0, nil) }
    }
}
