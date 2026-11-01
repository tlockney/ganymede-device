import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's answer to `device` calls from notebook cells (docs/protocol.md):
/// a WebKit message handler with replies, named `device`. Register it only
/// on the web view that runs kernels, never on one that renders notebook
/// outputs, so outputs can't reach it.
@MainActor
public final class DeviceBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The name `webkitHost()` posts to.
    public static let handlerName = "device"

    private let clipboard: Clipboard
    private let appVersion: String

    public init(
        clipboard: Clipboard? = nil,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    ) {
        // Made here, not as the default argument: defaults are evaluated
        // outside the main actor.
        self.clipboard = clipboard ?? SystemClipboard()
        self.appVersion = appVersion
    }

    /// Adds the bridge to `controller`, in the page's content world.
    public func register(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    public func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // The kernel page has no frames of its own; anything else posting
        // here is not the kernel host.
        guard message.frameInfo.isMainFrame else {
            replyHandler(Self.error("unavailable", "device calls are taken from the kernel page only"), nil)
            return
        }
        replyHandler(handle(message.body), nil)
    }

    /// One message's reply: `{ result }` or `{ error: { code, message } }`.
    public func handle(_ body: Any) -> [String: Any] {
        guard let call = body as? [String: Any] else {
            return Self.error("failed", "a device message must be an object")
        }
        if call["cancel"] as? Bool == true {
            // Nothing this bridge shows can be dismissed yet.
            return ["result": NSNull()]
        }
        guard let method = call["method"] as? String else {
            return Self.error("failed", "a device call needs a method")
        }
        let params = call["params"] as? [String: Any] ?? [:]
        switch method {
        case "hello":
            return ["result": hello()]
        case "clipboard.readText":
            return ["result": clipboard.readText() ?? NSNull()]
        case "clipboard.writeText":
            guard let text = params["text"] as? String else {
                return Self.error("failed", "clipboard.writeText needs a text string")
            }
            clipboard.writeText(text)
            return ["result": NSNull()]
        default:
            return Self.error("unavailable", "\(method) isn't available in this app")
        }
    }

    /// The methods this bridge answers, as `hello` reports them.
    public static let capabilities = ["clipboard.readText", "clipboard.writeText"]

    private func hello() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "platform": Self.platform,
            "appVersion": appVersion,
            "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "capabilities": Self.capabilities,
        ]
    }

    private static var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    private static func error(_ code: String, _ message: String) -> [String: Any] {
        ["error": ["code": code, "message": message]]
    }
}

/// The text clipboard, behind a protocol so tests needn't touch the real one.
@MainActor
public protocol Clipboard {
    func readText() -> String?
    func writeText(_ text: String)
}

/// The system pasteboard.
@MainActor
public struct SystemClipboard: Clipboard {
    public init() {}

    public func readText() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }

    public func writeText(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
